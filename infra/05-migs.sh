#!/usr/bin/env bash
# Zipkin (Cloud Run), reserved internal IPs + private Cloud DNS, health checks, instance templates,
# regional managed instance groups (multi-zone) and autoscalers.
# Prerequisites: 04-image.sh done, jars uploaded with deploy.sh (or the GitHub Actions workflows).
set -euo pipefail
source "$(dirname "$0")/00-vars.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Distributed tracing collector (serverless; VMs reach it through Cloud NAT)
gcloud run services describe zipkin --region=$REGION >/dev/null 2>&1 || \
  gcloud run deploy zipkin --image=openzipkin/zipkin --region=$REGION --port=9411 --memory=512Mi \
    --allow-unauthenticated --min-instances=1 --max-instances=1 -q
ZIPKIN_URL=$(gcloud run services describe zipkin --region=$REGION --format='value(status.url)')

# Stable internal IPs for the platform ILBs + private DNS names
for n in config-server eureka-server; do
  ensure gcloud compute addresses describe ip-$n --region=$REGION -- \
    gcloud compute addresses create ip-$n --region=$REGION --subnet=$SUBNET
done
CONFIG_IP=$(gcloud compute addresses describe ip-config-server --region=$REGION --format='value(address)')
EUREKA_IP=$(gcloud compute addresses describe ip-eureka-server --region=$REGION --format='value(address)')
ensure gcloud dns managed-zones describe $DNS_ZONE -- \
  gcloud dns managed-zones create $DNS_ZONE --dns-name=$DNS_DOMAIN --visibility=private --networks=$NETWORK \
    --description="SureFix internal service names"
for rec in config:$CONFIG_IP eureka:$EUREKA_IP; do
  ensure gcloud dns record-sets describe ${rec%%:*}.$DNS_DOMAIN --zone=$DNS_ZONE --type=A -- \
    gcloud dns record-sets create ${rec%%:*}.$DNS_DOMAIN --zone=$DNS_ZONE --type=A --ttl=60 --rrdatas=${rec#*:}
done
CONFIG_URL=http://config.surefix.internal:8888
EUREKA_URL=http://eureka.surefix.internal:8761/eureka/

# name:port:kind
#   platform = fixed 2 instances across zones, reachable directly (external IP) so the registry and
#              the gateway can be demonstrated per VM
#   service  = autoscaled, private (no external IP) - egress goes through Cloud NAT
COMPONENTS="config-server:8888:platform eureka-server:8761:platform api-gateway:8080:platform bug-service:8081:service run-service:8082:service evidence-service:8083:service"
TEMPLATE_VERSION=${TEMPLATE_VERSION:-v3}
ONLY=${ONLY:-}          # optional: limit the run to one kind (platform|service) or a single component

for c in $COMPONENTS; do
  IFS=: read -r name port kind <<< "$c"
  if [ -n "$ONLY" ] && [ "$ONLY" != "$kind" ] && [ "$ONLY" != "$name" ]; then continue; fi
  addr=()
  if [ "$kind" = service ]; then addr=(--no-address); fi
  size=2
  if [ "$name" = eureka-server ]; then size=3; fi   # one registry peer per zone (DS replicas)
  envfile=$(mktemp)
  {
    echo "SPRING_PROFILES_ACTIVE=gcp"
    echo "EUREKA_URL=$EUREKA_URL"
    echo "ZIPKIN_URL=$ZIPKIN_URL"
    echo "EUREKA_DASHBOARD_URL=http://eureka.surefix.internal:8761"
    [ "$name" != config-server ] && echo "CONFIG_URL=$CONFIG_URL"
    [ "$name" = eureka-server ] && echo "EUREKA_PEER=true"
  } > "$envfile"

  ensure gcloud compute health-checks describe hc-$name -- \
    gcloud compute health-checks create http hc-$name --port=$port --request-path=/actuator/health \
      --check-interval=15s --timeout=10s --healthy-threshold=1 --unhealthy-threshold=5

  ensure gcloud compute instance-templates describe tpl-$name-$TEMPLATE_VERSION -- \
    gcloud compute instance-templates create tpl-$name-$TEMPLATE_VERSION --machine-type=e2-small \
      --image-family=surefix-base --image-project=$PROJECT_ID --boot-disk-size=10GB \
      --network=$NETWORK --subnet=$SUBNET --region=$REGION "${addr[@]}" \
      --service-account=$VM_SA_EMAIL --scopes=cloud-platform --tags=surefix,$name \
      --metadata=component=$name,artifact-bucket=$ARTIFACT_BUCKET \
      --metadata-from-file=startup-script="$(winpath "$HERE/startup.sh")",env="$(winpath "$envfile")"
  rm -f "$envfile"

  if gcloud compute instance-groups managed describe mig-$name --region=$REGION >/dev/null 2>&1; then
    current=$(gcloud compute instance-groups managed describe mig-$name --region=$REGION --format='value(versions[0].instanceTemplate.basename())')
    if [ "$current" = "tpl-$name-$TEMPLATE_VERSION" ]; then
      echo "  exists: mig-$name already on $current"
    else
      echo "  exists: mig-$name (rolling update $current -> tpl-$name-$TEMPLATE_VERSION)"
      gcloud compute instance-groups managed rolling-action start-update mig-$name --region=$REGION \
        --version=template=tpl-$name-$TEMPLATE_VERSION --type=proactive --minimal-action=replace \
        --max-surge=3 --max-unavailable=0
    fi
  else
    gcloud compute instance-groups managed create mig-$name --region=$REGION --zones=$ZONES \
      --template=tpl-$name-$TEMPLATE_VERSION --size=$size --health-check=hc-$name --initial-delay=300
    gcloud compute instance-groups managed set-named-ports mig-$name --region=$REGION --named-ports=http:$port
    if [ "$kind" = service ]; then
      gcloud compute instance-groups managed set-autoscaling mig-$name --region=$REGION \
        --min-num-replicas=2 --max-num-replicas=4 --target-cpu-utilization=0.6 --cool-down-period=180
    fi
  fi
done
echo "migs done"
