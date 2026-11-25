#!/usr/bin/env bash
# release.sh <lane> <tag> [NAME=on|off ...]: make new Freight for rollouts-demo:<tag> appear
# in the lane's Warehouse, as if CI had just published that build. The lane's dev Stage
# picks it up on its own; promote the rest from the Kargo UI (or `make promote`).
#
# Web lane: a Freight is the image tag plus the commit of teams/web-service/app. A tag that
# already has Freight is released again with a new commit (a release marker), so any tag
# can be released as often as you like. Flag arguments change flags.env in that same
# commit: the image and its config ship, and roll back, as one Freight.
# REUSE=1 keeps a tag's existing Freight instead (used by `make up`; no commit, no push).
# Lambda lane: image only, so each tag makes Freight once.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
lane=${1:?usage: release.sh web|fn <tag> [NAME=on|off ...]}; check_lane "$lane"
tag=${2:?usage: release.sh web|fn <tag>   e.g. green, bad-yellow, slow-purple}
shift 2
project=$(project_of "$lane")
marker="$DEMO_ROOT/teams/web-service/app/RELEASE"
flags="$DEMO_ROOT/$FLAGS_FILE"
[[ $lane == fn && $# -gt 0 ]] && { echo "flags are a web lane feature" >&2; exit 2; }
kargo_use

# A new commit is needed for flags, or to release a tag that already has Freight.
commit=false
if [[ $lane == web ]]; then
  if (( $# > 0 )); then commit=true
  elif has_freight_for_tag web "$tag" && [[ ${REUSE:-0} != 1 ]]; then commit=true; fi
fi
if $commit; then
  require_clean "$flags" "$marker"
  restore_on_failure "$flags" "$marker"
  for kv in "$@"; do
    set_flag "$(tr '[:lower:]' '[:upper:]' <<<"${kv%%=*}")" "$(tr '[:upper:]' '[:lower:]' <<<"${kv#*=}")"
  done
fi

[[ $lane == web ]] && preload_image "argoproj/rollouts-demo:$tag"

# Point the Warehouse at the tag before pushing anything, so the new commit can only ever
# be paired with this tag (never the previous release's image).
if $commit || ! has_freight_for_tag "$lane" "$tag"; then
  set_release_tag "$lane" "$tag"
  "$DEMO_ROOT/scripts/render.sh"
  kargo_apply "$RENDERED/$lane/warehouse.yaml"
fi

sha=""
if $commit; then
  printf '# Last release, written by `make release`. Not deployed; each commit here is new Freight.\nrollouts-demo:%s %s\n' \
    "$tag" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker"
  sha=$(publish "release: rollouts-demo:$tag${1:+ with $*}" "$marker" "$flags")
fi

if $commit || ! has_freight_for_tag "$lane" "$tag"; then
  kargo refresh warehouse "$(warehouse_of "$lane")" --project "$project" >/dev/null
  if [[ -n $sha ]]; then
    wait_for 300 has_freight_for_commit "$lane" "$sha" "$tag" || { echo "no Freight for commit $sha"; exit 1; }
  else
    wait_for 300 has_freight_for_tag "$lane" "$tag" || { echo "no Freight for rollouts-demo:$tag (does the tag exist?)"; exit 1; }
  fi
fi
if [[ -n $sha ]]; then f=$(freight_for_commit "$lane" "$sha" "$tag"); else f=$(freight_for_tag "$lane" "$tag"); fi
log "$project: Freight for rollouts-demo:$tag${1:+ + $*} is $(freight_alias "$lane" "$f") ($f)"
if [[ $lane == web ]] && flag_on_at_head CHECKOUT_V2; then
  echo "note: CHECKOUT_V2 is on in main, so every new release carries it. Turn it off with" \
       "\`make flag NAME=CHECKOUT_V2 VALUE=off\` once you're done with it." >&2
fi
