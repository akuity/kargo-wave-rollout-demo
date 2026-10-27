#!/usr/bin/env bash
# One screen of demo state: every Stage's Freight, latest verification, and health.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
kargo_use >/dev/null

echo "latest release: rollouts-demo:$(release_tag)"
echo
freight=$(freights_json)
order=$(printf '%s\n' "${STAGES[@]}" | jq -R . | jq -s 'to_entries | map({(.value): .key}) | add')
kargo get stages "${KP[@]}" -o json | jq -r --argjson fr "$freight" --argjson ord "$order" '
  def tag($n): ($fr[] | select(.metadata.name == $n) | "\(.images[0].tag) (\(.alias // $n))") // $n;
  [.. | objects | select(.kind == "Stage")] | sort_by($ord[.metadata.name] // 99)[]
  | (.status.freightHistory[0] // {}) as $h
  | [ .metadata.name,
      (($h.items // {} | to_entries[0].value.name) as $n | if $n then tag($n) else "-" end),
      ($h.verificationHistory[0].phase // (if .spec.verification then "-" else "n/a" end)),
      (if .status.currentPromotion then "promoting" else "" end),
      (.status.health.status // "-") ]
  | @tsv' \
  | { printf 'STAGE\tFREIGHT\tVERIFY\tPROMOTION\tHEALTH\n'; cat; } | column -t -s $'\t'
