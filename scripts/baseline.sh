#!/usr/bin/env bash
# baseline.sh [web|fn]: put every Stage of a lane (default: both) on the baseline tag.
# Release it, promote it through the two QA gates, and wait for the rest to follow.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
kargo_use

holds() { [[ "$(current "$1" "$2")" == "$3" ]]; }
baseline() {
  local lane=$1 first gates rest f up s
  if [[ $lane == web ]]; then
    first=dev gates=(qa prod-wave1) rest=(prod-wave3-a prod-wave3-b prod-wave3-c prod-wave3-d prod-wave3-e)
  else
    first=fn-dev gates=(fn-qa fn-prod-eu-west-1) rest=(fn-prod-us-east-1 fn-prod-ap-southeast-2)
  fi
  "$DEMO_ROOT/scripts/release.sh" "$lane" "$BASELINE"
  f=$(freight_for_tag "$lane" "$BASELINE")
  log "$lane: waiting for $first to auto-promote"
  wait_for 600 holds "$lane" "$first" "$f"
  up=$first
  for s in "${gates[@]}"; do
    # Freight is offered downstream only once the upstream Stage has verified it (for a
    # Stage without verification: once its promotion, and Argo CD app if any, is healthy).
    wait_for 600 verified_in "$lane" "$f" "$up"
    kargo promote --project "$(project_of "$lane")" --stage "$s" --freight "$f" >/dev/null
    log "$lane: promoted $BASELINE to $s"
    up=$s
  done
  all_rest() { local x; for x in "${rest[@]}"; do holds "$lane" "$x" "$f" || return 1; done; }
  log "$lane: waiting for the remaining prod Stages to follow"
  wait_for 1800 all_rest
  log "$lane: baseline $BASELINE is on every Stage"
}

lanes=("${1:-web}"); [[ -z ${1:-} ]] && lanes=(fn web)
for lane in "${lanes[@]}"; do check_lane "$lane"; baseline "$lane"; done
