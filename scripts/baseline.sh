#!/usr/bin/env bash
# Put every Stage on the baseline tag: release it, promote it through qa and prod-wave1
# (the two manual gates), and wait for waves 2 and 3 to follow on their own.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
kargo_use
"$DEMO_ROOT/scripts/release.sh" "$BASELINE"
f=$(freight_for_tag "$BASELINE")

holds() { [[ "$(current "$1")" == "$2" ]]; }
log "waiting for dev to auto-promote"
wait_for 600 holds dev "$f"
up=dev
for s in qa prod-wave1; do
  # Freight is offered downstream only once the upstream Stage has verified it (for a Stage
  # without verification: once its Argo CD app is healthy).
  wait_for 600 verified_in "$f" "$up"
  kargo promote "${KP[@]}" --stage "$s" --freight "$f" >/dev/null
  up=$s
  log "promoted $BASELINE to $s; waiting"
  wait_for 600 holds "$s" "$f"
done
all_wave3() { for s in prod-wave3-{a,b,c,d,e}; do holds "$s" "$f" || return 1; done; }
log "waiting for waves 2 and 3 (each wave verifies for about 2 minutes)"
wait_for 1800 all_wave3
log "baseline $BASELINE is on every Stage"
