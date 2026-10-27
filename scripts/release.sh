#!/usr/bin/env bash
# release.sh <lane> <tag>: make Freight for rollouts-demo:<tag> appear in the lane's
# Warehouse, as if CI had just published that build. The lane's dev Stage picks it up on
# its own; promote the rest from the Kargo UI (or `make promote`).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
lane=${1:?usage: release.sh web|fn <tag>}; check_lane "$lane"
tag=${2:?usage: release.sh web|fn <tag>   e.g. green, bad-yellow, slow-purple}
project=$(project_of "$lane")
kargo_use

if [[ $lane == web ]]; then
  # Pre-load the image into the kind node, so a Docker Hub hiccup can't stall a promotion.
  docker pull -q "argoproj/rollouts-demo:$tag" >/dev/null \
    && kind load docker-image --name "$CLUSTER" "argoproj/rollouts-demo:$tag" >/dev/null 2>&1 \
    || echo "note: could not pre-load rollouts-demo:$tag; the cluster will pull it" >&2
fi

if [[ -z "$(freight_for_tag "$lane" "$tag")" ]]; then
  set_release_tag "$lane" "$tag"
  "$DEMO_ROOT/scripts/render.sh"
  kargo_apply "$RENDERED/$lane/warehouse.yaml"
  kargo refresh warehouse "$(warehouse_of "$lane")" --project "$project" >/dev/null
  wait_for 300 has_freight_for_tag "$lane" "$tag" || { echo "no Freight for rollouts-demo:$tag (does the tag exist?)"; exit 1; }
fi
f=$(freight_for_tag "$lane" "$tag")
alias=$(freights_json "$lane" | jq -r --arg f "$f" '.[] | select(.metadata.name == $f) | .alias // ""')
log "$project: Freight for rollouts-demo:$tag is $alias ($f)"
