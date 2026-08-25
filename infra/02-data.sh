#!/usr/bin/env bash
# Secret Manager secrets, Cloud SQL (PostgreSQL 17, private IP), Firestore (MongoDB-compatible), Cloud Storage buckets
set -euo pipefail
source "$(dirname "$0")/00-vars.sh"
touch "$SECRETS_FILE"; source "$SECRETS_FILE"

DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -hex 12)}"
ENCRYPT_KEY="${ENCRYPT_KEY:-$(openssl rand -hex 24)}"
MY_IP="$(curl -s https://api.ipify.org)"

add_secret() {
  if gcloud secrets describe "$1" >/dev/null 2>&1; then echo "  exists: secret $1"; return; fi
  gcloud secrets create "$1" --replication-policy=automatic
  printf '%s' "$2" | gcloud secrets versions add "$1" --data-file=-
}
add_secret surefix-db-password "$DB_PASSWORD"
add_secret surefix-encrypt-key "$ENCRYPT_KEY"

# Private services access so Cloud SQL gets a private IP inside our VPC
ensure gcloud compute addresses describe google-managed-services-$NETWORK --global -- \
  gcloud compute addresses create google-managed-services-$NETWORK --global \
    --purpose=VPC_PEERING --prefix-length=16 --network=$NETWORK
gcloud services vpc-peerings list --network=$NETWORK 2>/dev/null | grep -q servicenetworking || \
  gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com \
    --ranges=google-managed-services-$NETWORK --network=$NETWORK

# Cloud SQL - PostgreSQL (relational database for bug-service)
ensure gcloud sql instances describe $SQL_INSTANCE -- \
  gcloud sql instances create $SQL_INSTANCE --database-version=POSTGRES_17 --edition=enterprise \
    --tier=db-f1-micro --region=$REGION --availability-type=zonal --storage-size=10 --storage-type=HDD \
    --network=projects/$PROJECT_ID/global/networks/$NETWORK --assign-ip --authorized-networks=$MY_IP/32 \
    --root-password="$DB_PASSWORD"
ensure gcloud sql databases describe $SQL_DB --instance=$SQL_INSTANCE -- \
  gcloud sql databases create $SQL_DB --instance=$SQL_INSTANCE
gcloud sql users list --instance=$SQL_INSTANCE --format='value(name)' | grep -qx $SQL_USER || \
  gcloud sql users create $SQL_USER --instance=$SQL_INSTANCE --password="$DB_PASSWORD"
SQL_PRIVATE_IP=$(gcloud sql instances describe $SQL_INSTANCE --format='value(ipAddresses[?type=PRIVATE].ipAddress)')
SQL_PUBLIC_IP=$(gcloud sql instances describe $SQL_INSTANCE --format='value(ipAddresses[?type=PRIMARY].ipAddress)')

# Firestore Enterprise with MongoDB compatibility (non-relational database for run-service)
ensure gcloud firestore databases describe --database=$FIRESTORE_DB -- \
  gcloud firestore databases create --database=$FIRESTORE_DB --location=$REGION \
    --edition=enterprise --enable-mongodb-compatible-data-access
FS_UID=$(gcloud firestore databases describe --database=$FIRESTORE_DB --format='value(uid)')
if [ -z "${FIRESTORE_PASSWORD:-}" ]; then
  FIRESTORE_PASSWORD=$(gcloud firestore user-creds create $FIRESTORE_USER --database=$FIRESTORE_DB --format='value(securePassword)')
fi
MONGO_URI="mongodb://$FIRESTORE_USER:$FIRESTORE_PASSWORD@$FS_UID.$REGION.firestore.goog:443/$FIRESTORE_DB?loadBalanced=true&tls=true&authMechanism=SCRAM-SHA-256&retryWrites=false"
# The user credential is an IAM principal: it needs datastore.user to read/write the database
FS_PRINCIPAL=$(gcloud firestore user-creds describe $FIRESTORE_USER --database=$FIRESTORE_DB --format='value(resourceIdentity.principal)')
gcloud projects add-iam-policy-binding $PROJECT_ID --member="$FS_PRINCIPAL" --role=roles/datastore.user --condition=None -q >/dev/null

# Cloud Storage buckets: build artifacts (jars) + evidence files uploaded by evidence-service
for b in $ARTIFACT_BUCKET $EVIDENCE_BUCKET; do
  ensure gcloud storage buckets describe gs://$b -- \
    gcloud storage buckets create gs://$b --location=$REGION --uniform-bucket-level-access
done

cat > "$SECRETS_FILE" <<S
DB_PASSWORD=$DB_PASSWORD
ENCRYPT_KEY=$ENCRYPT_KEY
SQL_PRIVATE_IP=$SQL_PRIVATE_IP
SQL_PUBLIC_IP=$SQL_PUBLIC_IP
FIRESTORE_PASSWORD=$FIRESTORE_PASSWORD
MONGO_URI="$MONGO_URI"
S
echo "data done -> $SECRETS_FILE"
