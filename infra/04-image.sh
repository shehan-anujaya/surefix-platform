#!/usr/bin/env bash
# Build the custom disk image used by every backend instance template.
set -euo pipefail
source "$(dirname "$0")/00-vars.sh"
ZONE=us-central1-a
VM=surefix-image-builder
IMAGE=surefix-base-$(date +%Y%m%d-%H%M)

gcloud compute instances create $VM --zone=$ZONE --machine-type=e2-small \
  --image-family=debian-12 --image-project=debian-cloud \
  --network=$NETWORK --subnet=$SUBNET --no-address \
  --service-account=$VM_SA_EMAIL --scopes=cloud-platform \
  --metadata-from-file=startup-script="$(dirname "$0")/image-builder.sh"

echo "waiting for provisioning to finish..."
until gcloud compute instances get-serial-port-output $VM --zone=$ZONE 2>/dev/null | grep -q SUREFIX_IMAGE_READY; do
  sleep 20; echo -n "."
done
echo
gcloud compute instances stop $VM --zone=$ZONE -q
gcloud compute images create $IMAGE --source-disk=$VM --source-disk-zone=$ZONE --family=surefix-base \
  --description="Debian 12 + Temurin JDK 25 + Node 22 + PM2"
gcloud compute instances delete $VM --zone=$ZONE -q
echo "image done: $IMAGE (family surefix-base)"
