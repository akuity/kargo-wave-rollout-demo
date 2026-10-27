#!/usr/bin/env bash
# One screen of demo state: every Stage's Freight, latest verification, and health, per lane.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
kargo_use >/dev/null

table() {
  local lane=$1 order freight; shift
  freight=$(freights_json "$lane")
  order=$(printf '%s\n' "$@" | jq -R . | jq -s 'to_entries | map({(.value): .key}) | add')
  kargo get stages --project "$(project_of "$lane")" -o json | jq -r --argjson fr "$freight" --argjson ord "$order" '
    def tag($n): ($fr[] | select(.metadata.name == $n) | "\(.images[0].tag) (\(.alias // $n))") // $n;
    [.. | objects | select(.kind == "Stage")] | sort_by($ord[.metadata.name] // 99)[]
    | (.status.freightHistory[0] // {}) as $h
    | [ .metadata.name,
        (($h.items // {} | to_entries[0].value.name) as $n | if $n then tag($n) else "-" end),
        ($h.verificationHistory[0].phase // (if .spec.verification then "-" else "n/a" end)),
        (if .status.currentPromotion then "promoting" else "-" end),
        (.status.health.status // "-") ]
    | @tsv' \
    | { printf 'STAGE\tFREIGHT\tVERIFY\tPROMOTION\tHEALTH\n'; cat; } | column -t -s $'\t'
}

echo "== $WEB_PROJECT (Kubernetes)   latest release: rollouts-demo:$(release_tag web)"
table web "${WEB_STAGES[@]}"
echo
echo "== $FN_PROJECT (Lambda)   latest release: rollouts-demo:$(release_tag fn)"
table fn "${FN_STAGES[@]}"
