#!/usr/bin/env bash
# release.sh <tag>: make Freight for rollouts-demo:<tag> appear, as if CI had just
# published that build. dev picks it up on its own; promote the rest from the Kargo UI
# (or `make promote`).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
tag=${1:?usage: release.sh <tag>   e.g. green, bad-yellow, slow-purple}
kargo_use

# Pre-load the image into the kind node, so a Docker Hub hiccup can't stall a promotion.
docker pull -q "argoproj/rollouts-demo:$tag" >/dev/null \
  && kind load docker-image --name "$CLUSTER" "argoproj/rollouts-demo:$tag" >/dev/null 2>&1 \
  || echo "note: could not pre-load rollouts-demo:$tag; the cluster will pull it" >&2

if [[ -z "$(freight_for_tag "$tag")" ]]; then
  set_release_tag "$tag"
  "$DEMO_ROOT/scripts/render.sh"
  kargo_apply "$RENDERED/kargo/warehouse.yaml"
  kargo refresh warehouse app "${KP[@]}" >/dev/null
  wait_for 300 has_freight_for_tag "$tag" || { echo "no Freight for rollouts-demo:$tag (does the tag exist?)"; exit 1; }
fi
f=$(freight_for_tag "$tag")
alias=$(freights_json | jq -r --arg f "$f" '.[] | select(.metadata.name == $f) | .alias // ""')
log "Freight for rollouts-demo:$tag: $alias ($f)"
