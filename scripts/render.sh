#!/usr/bin/env bash
# Render the templates from config.env into .rendered/. Only the listed variables are
# substituted, so Kargo's ${{ ... }} expressions pass through untouched.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
WEB_RELEASE_TAG=$(release_tag web) FN_RELEASE_TAG=$(release_tag fn)
export WEB_PROJECT FN_PROJECT CLUSTER GIT_REPO WEB_RELEASE_TAG FN_RELEASE_TAG QA_GROUP DEV_GROUP
vars='${WEB_PROJECT} ${FN_PROJECT} ${CLUSTER} ${GIT_REPO} ${WEB_RELEASE_TAG} ${FN_RELEASE_TAG} ${QA_GROUP} ${DEV_GROUP}'
rm -rf "$RENDERED"; mkdir -p "$RENDERED"/{argocd,platform,web,fn}

# Argo CD: platform add-ons, the Lambda stand-in, one Application per web Stage.
envsubst "$vars" < "$DEMO_ROOT/platform/addons.tpl.yaml" > "$RENDERED/argocd/addons.yaml"
envsubst "$vars" < "$DEMO_ROOT/sim/argocd-app.tpl.yaml" > "$RENDERED/argocd/lambda-sim.yaml"
for STAGE in "${WEB_STAGES[@]}"; do
  export STAGE
  envsubst "$vars \${STAGE}" < "$DEMO_ROOT/teams/web-service/argocd/app.tpl.yaml" > "$RENDERED/argocd/app-$STAGE.yaml"
done

# Kargo resources only; addons.tpl.yaml is Argo CD and is rendered above.
for f in "$DEMO_ROOT"/platform/*.yaml; do [[ $f == *.tpl.yaml ]] || cp "$f" "$RENDERED/platform/"; done
for lane in web fn; do
  dir=web-service; [[ $lane == fn ]] && dir=lambda-service
  for t in "$DEMO_ROOT/teams/$dir"/kargo/*.tpl.yaml; do
    envsubst "$vars" < "$t" > "$RENDERED/$lane/$(basename "$t" .tpl.yaml).yaml"
  done
done
