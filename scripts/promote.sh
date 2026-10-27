#!/usr/bin/env bash
# promote.sh <stage> [tag]: promote the Freight for <tag> (default: the lane's latest
# release) to <stage>. The lane follows from the Stage name (fn-* is the Lambda lane).
# The same thing QA does from the Kargo UI.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
stage=${1:?usage: promote.sh <stage> [tag]}
lane=$(lane_of_stage "$stage")
tag=${2:-$(release_tag "$lane")}
kargo_use
f=$(freight_for_tag "$lane" "$tag")
[[ -n $f ]] || { echo "no Freight for rollouts-demo:$tag; run make release LANE=$lane TAG=$tag first"; exit 1; }
kargo promote --project "$(project_of "$lane")" --stage "$stage" --freight "$f" >/dev/null
log "promoting rollouts-demo:$tag to $stage"
