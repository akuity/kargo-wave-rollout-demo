#!/usr/bin/env bash
# Render the templates from config.env into .rendered/. Only the listed variables are
# substituted, so Kargo's ${{ ... }} expressions pass through untouched.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
RELEASE_TAG=$(release_tag)
export PROJECT CLUSTER GIT_REPO RELEASE_TAG
rm -rf "$RENDERED"; mkdir -p "$RENDERED/argocd" "$RENDERED/kargo"

for STAGE in "${STAGES[@]}"; do
  export STAGE
  envsubst '${PROJECT} ${STAGE} ${CLUSTER} ${GIT_REPO}' \
    < "$DEMO_ROOT/argocd/app.tpl.yaml" > "$RENDERED/argocd/app-$STAGE.yaml"
done
envsubst '${CLUSTER}' < "$DEMO_ROOT/argocd/addons.tpl.yaml" > "$RENDERED/argocd/addons.yaml"
for t in "$DEMO_ROOT"/kargo/*.tpl.yaml; do
  envsubst '${PROJECT} ${GIT_REPO} ${RELEASE_TAG}' < "$t" > "$RENDERED/kargo/$(basename "$t" .tpl.yaml).yaml"
done
