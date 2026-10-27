#!/usr/bin/env bash
# promote.sh <stage> [tag]: promote the Freight for <tag> (default: the latest release)
# to <stage>. The same thing QA does from the Kargo UI.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
stage=${1:?usage: promote.sh <stage> [tag]}
tag=${2:-$(release_tag)}
kargo_use
f=$(freight_for_tag "$tag")
[[ -n $f ]] || { echo "no Freight for rollouts-demo:$tag; run make release TAG=$tag first"; exit 1; }
kargo promote "${KP[@]}" --stage "$stage" --freight "$f" >/dev/null
log "promoting rollouts-demo:$tag to $stage"
