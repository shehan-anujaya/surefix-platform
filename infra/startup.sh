#!/bin/bash
# GCE startup script (runs on every boot of every backend VM).
# Downloads the component jar + PM2 config from the artifact bucket and (re)starts it under PM2.
set -euo pipefail
MD=http://metadata.google.internal/computeMetadata/v1/instance/attributes
md() { curl -sf -H "Metadata-Flavor: Google" "$MD/$1"; }

COMPONENT=$(md component)
BUCKET=$(md artifact-bucket)
mkdir -p /opt/surefix /var/log/surefix /etc/surefix

gcloud storage cp "gs://$BUCKET/$COMPONENT/$COMPONENT.jar" /opt/surefix/$COMPONENT.jar
gcloud storage cp "gs://$BUCKET/$COMPONENT/ecosystem.config.js" /opt/surefix/ecosystem.config.js

# Environment for the app: static values from instance metadata + secrets from Secret Manager
md env > /etc/surefix/env
if [ "$COMPONENT" = "config-server" ]; then
  echo "ENCRYPT_KEY=$(gcloud secrets versions access latest --secret=surefix-encrypt-key)" >> /etc/surefix/env
  # Fallback: if a copy of the config git repo exists in the bucket, serve from it instead of GitHub
  if gcloud storage ls "gs://$BUCKET/config-repo/" >/dev/null 2>&1; then
    rm -rf /opt/surefix/config-repo && mkdir -p /opt/surefix/config-repo
    gcloud storage cp -r "gs://$BUCKET/config-repo/*" /opt/surefix/config-repo/
    echo "CONFIG_GIT_URI=file:///opt/surefix/config-repo" >> /etc/surefix/env
  fi
fi
if [ "$COMPONENT" = "eureka-server" ]; then
  # Eureka peers must know each other directly (an ILB would pin replication to one node).
  # Each registry VM publishes its own IP as eureka-<zone>.surefix.internal in the private Cloud DNS zone
  # and replicates to the per-zone names of the other zones.
  ZONE=$(curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
  MYIP=$(hostname -I | awk '{print $1}')
  MYNAME="eureka-$ZONE.surefix.internal"
  if gcloud dns record-sets describe "$MYNAME." --zone=surefix-internal --type=A >/dev/null 2>&1; then
    gcloud dns record-sets update "$MYNAME." --zone=surefix-internal --type=A --ttl=30 --rrdatas="$MYIP"
  else
    gcloud dns record-sets create "$MYNAME." --zone=surefix-internal --type=A --ttl=30 --rrdatas="$MYIP"
  fi
  REGION=${ZONE%-*}
  PEERS=""
  for z in a b c; do PEERS="$PEERS,http://eureka-$REGION-$z.surefix.internal:8761/eureka/"; done
  sed -i '/^EUREKA_URL=/d;/^EUREKA_INSTANCE_HOSTNAME=/d' /etc/surefix/env
  echo "EUREKA_URL=${PEERS#,}" >> /etc/surefix/env
  echo "EUREKA_INSTANCE_HOSTNAME=$MYNAME" >> /etc/surefix/env
fi
chmod 600 /etc/surefix/env
chown -R surefix:surefix /opt/surefix /var/log/surefix /etc/surefix

# Start (or reload) under PM2 and persist the process list so `pm2 resurrect` restores it after a reboot
sudo -u surefix -H bash -c 'set -a; source /etc/surefix/env; set +a; cd /opt/surefix && pm2 startOrReload ecosystem.config.js --update-env && pm2 save'
echo "SUREFIX_STARTED $COMPONENT"
