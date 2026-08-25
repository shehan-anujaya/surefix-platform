#!/usr/bin/env bash
# Build one component, upload jar + PM2 config to the artifact bucket, optionally roll the MIG.
#   ./deploy.sh <path-to-component> [--replace]
set -euo pipefail
source "$(dirname "$0")/00-vars.sh"
DIR="$1"; NAME=$(basename "$DIR")
( cd "$DIR" && mvn -q -DskipTests package )
gcloud storage cp "$DIR/target/$NAME.jar" "gs://$ARTIFACT_BUCKET/$NAME/$NAME.jar"
gcloud storage cp "$DIR/ecosystem.config.js" "gs://$ARTIFACT_BUCKET/$NAME/ecosystem.config.js"
echo "uploaded gs://$ARTIFACT_BUCKET/$NAME/"
if [ "${2:-}" = "--replace" ]; then
  gcloud compute instance-groups managed rolling-action replace mig-$NAME --region=$REGION --max-surge=3 --max-unavailable=0
  echo "rolling replace started for mig-$NAME"
fi
