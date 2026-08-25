#!/usr/bin/env bash
# Internal load balancers for Config Server + Eureka, external HTTP load balancer for the API Gateway.
set -euo pipefail
source "$(dirname "$0")/00-vars.sh"

# Internal passthrough load balancers (reach the platform services by stable DNS name from any VM)
for c in config-server:8888 eureka-server:8761; do
  IFS=: read -r name port <<< "$c"
  ensure gcloud compute backend-services describe ilb-$name --region=$REGION -- \
    gcloud compute backend-services create ilb-$name --load-balancing-scheme=internal --protocol=tcp \
      --region=$REGION --health-checks=hc-$name
  gcloud compute backend-services describe ilb-$name --region=$REGION --format='value(backends)' | grep -q mig-$name || \
    gcloud compute backend-services add-backend ilb-$name --region=$REGION \
      --instance-group=mig-$name --instance-group-region=$REGION
  ensure gcloud compute forwarding-rules describe fr-$name --region=$REGION -- \
    gcloud compute forwarding-rules create fr-$name --region=$REGION --load-balancing-scheme=internal \
      --network=$NETWORK --subnet=$SUBNET --address=ip-$name --ports=$port \
      --backend-service=ilb-$name --backend-service-region=$REGION
done

# External HTTP load balancer -> api-gateway MIG (single public entry point of the backend)
ensure gcloud compute addresses describe surefix-gateway-ip --global -- \
  gcloud compute addresses create surefix-gateway-ip --global --ip-version=IPV4
ensure gcloud compute backend-services describe be-api-gateway --global -- \
  gcloud compute backend-services create be-api-gateway --global --protocol=HTTP --port-name=http \
    --health-checks=hc-api-gateway --timeout=60s
gcloud compute backend-services describe be-api-gateway --global --format='value(backends)' | grep -q mig-api-gateway || \
  gcloud compute backend-services add-backend be-api-gateway --global \
    --instance-group=mig-api-gateway --instance-group-region=$REGION --balancing-mode=UTILIZATION
ensure gcloud compute url-maps describe surefix-lb -- \
  gcloud compute url-maps create surefix-lb --default-service=be-api-gateway
ensure gcloud compute target-http-proxies describe surefix-http-proxy -- \
  gcloud compute target-http-proxies create surefix-http-proxy --url-map=surefix-lb
ensure gcloud compute forwarding-rules describe surefix-http-fr --global -- \
  gcloud compute forwarding-rules create surefix-http-fr --global --address=surefix-gateway-ip \
    --target-http-proxy=surefix-http-proxy --ports=80

GATEWAY_IP=$(gcloud compute addresses describe surefix-gateway-ip --global --format='value(address)')
echo "GATEWAY_URL=http://$GATEWAY_IP"
echo "lb done"
