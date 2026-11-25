#!/usr/bin/env bash
# promote.sh <stage> [tag-or-alias]: promote Freight to <stage>. A Freight alias (oily-goat)
# picks exactly that Freight; a tag picks its newest Freight; default: the lane's latest
# release. The lane follows from the Stage name (fn-* is the Lambda lane).
# The same thing QA does from the Kargo UI.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
stage=${1:?usage: promote.sh <stage> [tag]}
lane=$(lane_of_stage "$stage")
tag=${2:-$(release_tag "$lane")}
kargo_use
f=$(freight_for_ref "$lane" "$tag")
[[ -n $f ]] || { echo "no Freight for rollouts-demo:$tag; run make release LANE=$lane TAG=$tag first"; exit 1; }

# Kargo offers Freight to a Stage only once an upstream Stage has verified it. Wait for that
# (up to 10 minutes) instead of failing when promote runs right after a release.
upstream=$(kargo get stage "$stage" --project "$(project_of "$lane")" -o json \
  | jq -r '.spec.requestedFreight[0].sources.stages // [] | join(" ")')
available() { local s; for s in $upstream; do verified_in "$lane" "$f" "$s" && return 0; done; return 1; }
if [[ -n $upstream ]] && ! available; then
  log "waiting for $(freight_alias "$lane" "$f") to verify in $upstream before promoting to $stage"
  wait_for 600 available || { echo "$(freight_alias "$lane" "$f") did not verify in $upstream within 10 minutes"; exit 1; }
fi
kargo promote --project "$(project_of "$lane")" --stage "$stage" --freight "$f" >/dev/null
log "promoting $(freight_alias "$lane" "$f") ($tag) to $stage"
