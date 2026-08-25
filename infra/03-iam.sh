#!/usr/bin/env bash
# Service accounts + Workload Identity Federation (GitHub Actions -> GCP without keys)
set -euo pipefail
source "$(dirname "$0")/00-vars.sh"
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')

bind() {
  # retry: a freshly created service account takes a few seconds to become visible to IAM
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$1" --role="$2" --condition=None -q >/dev/null 2>&1; then
      echo "  $1 -> $2"; return 0
    fi
    sleep 6
  done
  echo "FAILED binding $1 -> $2"; return 1
}

# Runtime identity of every backend VM
ensure gcloud iam service-accounts describe $VM_SA_EMAIL -- \
  gcloud iam service-accounts create $VM_SA --display-name="SureFix VM runtime"
for r in roles/storage.objectAdmin roles/secretmanager.secretAccessor roles/logging.logWriter roles/monitoring.metricWriter roles/cloudsql.client; do
  bind $VM_SA_EMAIL $r
done

# Identity assumed by GitHub Actions through WIF
ensure gcloud iam service-accounts describe $DEPLOYER_SA_EMAIL -- \
  gcloud iam service-accounts create $DEPLOYER_SA --display-name="GitHub Actions deployer"
for r in roles/run.admin roles/iam.serviceAccountUser roles/storage.admin roles/cloudbuild.builds.editor roles/artifactregistry.writer roles/compute.instanceAdmin.v1 roles/serviceusage.serviceUsageConsumer roles/viewer; do
  bind $DEPLOYER_SA_EMAIL $r
done

# Cloud Build (used by `gcloud run deploy --source`) runs as the compute default SA in new projects
COMPUTE_SA="$PROJECT_NUMBER-compute@developer.gserviceaccount.com"
for r in roles/cloudbuild.builds.builder roles/artifactregistry.writer roles/storage.objectAdmin roles/logging.logWriter; do
  bind $COMPUTE_SA $r
done

ensure gcloud iam workload-identity-pools describe github-pool --location=global -- \
  gcloud iam workload-identity-pools create github-pool --location=global --display-name="GitHub Actions"
ensure gcloud iam workload-identity-pools providers describe github-provider --location=global --workload-identity-pool=github-pool -- \
  gcloud iam workload-identity-pools providers create-oidc github-provider --location=global --workload-identity-pool=github-pool \
    --issuer-uri=https://token.actions.githubusercontent.com \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository_owner=='$GITHUB_OWNER'"
gcloud iam service-accounts add-iam-policy-binding $DEPLOYER_SA_EMAIL --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/attribute.repository_owner/$GITHUB_OWNER" -q >/dev/null

echo "WIF_PROVIDER=projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider"
echo "iam done"
