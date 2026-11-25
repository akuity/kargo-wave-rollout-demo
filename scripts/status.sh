#!/usr/bin/env bash
# One screen of demo state: every Stage's Freight, the feature flags it carries (web lane),
# latest verification, and health, per lane.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
kargo_use >/dev/null

# flag_map <freight-json>: {freight name: flags that are on at its commit}
flag_map() {
  local name sha out='{}'
  while IFS=$'\t' read -r name sha; do
    [[ -n $sha ]] || continue
    out=$(jq -c --arg n "$name" --arg v "$(flags_at "$sha")" '. + {($n): $v}' <<<"$out")
  done < <(jq -r '.[] | [.metadata.name, (.commits[0].id // "")] | @tsv' <<<"$1")
  echo "$out"
}

table() {
  local lane=$1 order freight flags; shift
  freight=$(freights_json "$lane")
  if [[ $lane == web ]]; then flags=$(flag_map "$freight"); else flags='{}'; fi
  order=$(printf '%s\n' "$@" | jq -R . | jq -s 'to_entries | map({(.value): .key}) | add')
  kargo get stages --project "$(project_of "$lane")" -o json \
    | jq -r --argjson fr "$freight" --argjson ord "$order" --argjson fl "$flags" --arg lane "$lane" '
    def tag($n): ($fr[] | select(.metadata.name == $n) | "\(.images[0].tag) (\(.alias // $n))") // $n;
    [.. | objects | select(.kind == "Stage")] | sort_by($ord[.metadata.name] // 99)[]
    | (.status.freightHistory[0] // {}) as $h
    | ($h.items // {} | to_entries[0].value.name) as $n
    | [ .metadata.name,
        (if $n then tag($n) else "-" end),
        (if $lane == "web" then ($fl[$n // ""] // "-") else empty end),
        ($h.verificationHistory[0].phase // (if .spec.verification then "-" else "n/a" end)),
        (if .status.currentPromotion then "promoting" else "-" end),
        (.status.health.status // "-") ]
    | @tsv' \
    | { if [[ $lane == web ]]; then printf 'STAGE\tFREIGHT\tFLAGS ON\tVERIFY\tPROMOTION\tHEALTH\n'
        else printf 'STAGE\tFREIGHT\tVERIFY\tPROMOTION\tHEALTH\n'; fi; cat; } | column -t -s $'\t'
}

echo "== $WEB_PROJECT (Kubernetes)   latest release: rollouts-demo:$(release_tag web)"
table web "${WEB_STAGES[@]}"
echo
echo "== $FN_PROJECT (Lambda)   latest release: rollouts-demo:$(release_tag fn)"
table fn "${FN_STAGES[@]}"
