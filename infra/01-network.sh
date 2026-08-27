#!/usr/bin/env bash
# VPC network, subnet, firewall rules, Cloud Router, Cloud NAT
set -euo pipefail
source "$(dirname "$0")/00-vars.sh"

ensure gcloud compute networks describe $NETWORK -- \
  gcloud compute networks create $NETWORK --subnet-mode=custom

ensure gcloud compute networks subnets describe $SUBNET --region=$REGION -- \
  gcloud compute networks subnets create $SUBNET --network=$NETWORK --region=$REGION \
    --range=$SUBNET_RANGE --enable-private-ip-google-access

ensure gcloud compute firewall-rules describe $NETWORK-allow-internal -- \
  gcloud compute firewall-rules create $NETWORK-allow-internal --network=$NETWORK \
    --allow=tcp,udp,icmp --source-ranges=$SUBNET_RANGE

# Google health-check probe ranges (used by the load balancers and MIG auto-healing)
ensure gcloud compute firewall-rules describe $NETWORK-allow-health-checks -- \
  gcloud compute firewall-rules create $NETWORK-allow-health-checks --network=$NETWORK \
    --allow=tcp --source-ranges=130.211.0.0/22,35.191.0.0/16

# SSH only through IAP (never a public port 22)
ensure gcloud compute firewall-rules describe $NETWORK-allow-iap-ssh -- \
  gcloud compute firewall-rules create $NETWORK-allow-iap-ssh --network=$NETWORK \
    --allow=tcp:22 --source-ranges=35.235.240.0/20

# The platform VMs are directly reachable for the demo: Eureka dashboard (8761) and the gateway (8080).
# The Config Server port (8888) is deliberately NOT opened - it serves decrypted configuration.
ensure gcloud compute firewall-rules describe $NETWORK-allow-platform-demo -- \
  gcloud compute firewall-rules create $NETWORK-allow-platform-demo --network=$NETWORK \
    --allow=tcp:8080,tcp:8761 --source-ranges=0.0.0.0/0 \
    --target-tags=eureka-server,api-gateway

ensure gcloud compute routers describe surefix-router --region=$REGION -- \
  gcloud compute routers create surefix-router --network=$NETWORK --region=$REGION

ensure gcloud compute routers nats describe surefix-nat --router=surefix-router --region=$REGION -- \
  gcloud compute routers nats create surefix-nat --router=surefix-router --region=$REGION \
    --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges --min-ports-per-vm=1024

echo "network done"
