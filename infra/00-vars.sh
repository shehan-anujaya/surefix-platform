#!/usr/bin/env bash
# Shared variables for every infra script. Source this first.
# On Git Bash (Windows) call gcloud.cmd with MSYS path conversion off, otherwise args like
# --request-path=/actuator/health get rewritten to C:/Program Files/Git/actuator/health.
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
  GCLOUD_PY="$(cygpath -w "$(dirname "$(command -v gcloud)")/../lib/gcloud.py")"
  gcloud() { MSYS_NO_PATHCONV=1 "${CLOUDSDK_PYTHON:-python}" "$GCLOUD_PY" "$@"; }
  export GCLOUD_PY; export -f gcloud
fi
# winpath <file>: path form gcloud can open (Windows path on Git Bash, unchanged elsewhere)
winpath() { if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then cygpath -m "$1"; else echo "$1"; fi; }
export PROJECT_ID=surefix-eca
export REGION=us-central1
export ZONES=us-central1-a,us-central1-b,us-central1-c
export NETWORK=surefix-vpc
export SUBNET=surefix-subnet
export SUBNET_RANGE=10.10.0.0/20
export ARTIFACT_BUCKET=surefix-eca-artifacts
export EVIDENCE_BUCKET=surefix-eca-evidence
export VM_SA=surefix-vm-sa
export DEPLOYER_SA=surefix-github-deployer
export SQL_INSTANCE=surefix-pg
export SQL_DB=surefix
export SQL_USER=surefix
export FIRESTORE_DB=surefix-db
export FIRESTORE_USER=surefix-app
export DNS_ZONE=surefix-internal
export DNS_DOMAIN=surefix.internal.
export GITHUB_OWNER=shehan-anujaya
export SECRETS_FILE="${SECRETS_FILE:-$HOME/.surefix-secrets.env}"   # local only, never committed
export VM_SA_EMAIL="$VM_SA@$PROJECT_ID.iam.gserviceaccount.com"
export DEPLOYER_SA_EMAIL="$DEPLOYER_SA@$PROJECT_ID.iam.gserviceaccount.com"
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

# ensure <describe-cmd...> -- <create-cmd...>  : create only if describe fails (idempotent re-runs)
ensure() {
  local d=()
  while [ "$1" != "--" ]; do d+=("$1"); shift; done
  shift
  if "${d[@]}" >/dev/null 2>&1; then echo "  exists: ${d[*]:3:2}"; else "$@"; fi
}
