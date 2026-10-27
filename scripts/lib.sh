#!/usr/bin/env bash
# Shared helpers for the demo scripts. Source, don't execute.

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$DEMO_ROOT/config.local.env" ]] && source "$DEMO_ROOT/config.local.env"
source "$DEMO_ROOT/config.env"
export DOCKER_CONTEXT
# Two lanes, one Kargo project each: the Kubernetes service and the Lambda function.
WEB_STAGES=(dev qa prod-wave1 prod-wave2-a prod-wave2-b prod-wave2-c
            prod-wave3-a prod-wave3-b prod-wave3-c prod-wave3-d prod-wave3-e)
FN_STAGES=(fn-dev fn-qa fn-prod-eu-west-1 fn-prod-us-east-1 fn-prod-ap-southeast-2)
A=(--org-name "$ORG" --instance-name "$INSTANCE")
KCTX="kind-$CLUSTER"
RENDERED="$DEMO_ROOT/.rendered"
STATE_DIR="$DEMO_ROOT/.state"
DESC="kargo wave rollout demo (temporary)"   # marks instances this demo created

now() { date -u +%H:%M:%SZ; }
log() { echo "[$(now)] $*"; }

# wait_for <timeout-s> <cmd...>: retry cmd every 5s until it succeeds or timeout
wait_for() {
  local timeout="$1"; shift
  local deadline=$(( $(date +%s) + timeout ))
  until "$@" >/dev/null 2>&1; do
    (( $(date +%s) >= deadline )) && { echo "timeout after ${timeout}s: $*" >&2; return 1; }
    sleep 5
  done
}

# retry <n> <cmd...>: the Akuity API sometimes fails a first apply with an internal error.
retry() {
  local n="$1" i; shift
  for (( i = 1; i <= n; i++ )); do "$@" && return 0; sleep 5; done
  return 1
}

# Lane helpers. A lane is `web` or `fn`.
check_lane() { [[ $1 == web || $1 == fn ]] || { echo "unknown lane '$1' (web or fn)" >&2; exit 2; }; }
project_of() { if [[ $1 == fn ]]; then echo "$FN_PROJECT"; else echo "$WEB_PROJECT"; fi; }
warehouse_of() { if [[ $1 == fn ]]; then echo function; else echo app; fi; }
lane_of_stage() { if [[ $1 == fn-* ]]; then echo fn; else echo web; fi; }

# The tag a lane's Warehouse currently admits (set by `make release`).
release_tag() { cat "$STATE_DIR/release-tag-$1" 2>/dev/null || echo "$BASELINE"; }
set_release_tag() { mkdir -p "$STATE_DIR"; echo "$2" > "$STATE_DIR/release-tag-$1"; }

github_token() {
  if [[ -n ${GITHUB_TOKEN:-} ]]; then echo "$GITHUB_TOKEN"
  elif [[ -n ${PAT_PASS_ENTRY:-} ]]; then pass show "$PAT_PASS_ENTRY" | head -1
  else echo "set GITHUB_TOKEN or PAT_PASS_ENTRY (see config.env)" >&2; return 1; fi
}

# Kargo admin password: generated on first use, kept only in .state/ (git-ignored).
admin_password() {
  local f="$STATE_DIR/kargo-admin-password"
  if [[ ! -s $f ]]; then
    mkdir -p "$STATE_DIR"
    (umask 077; openssl rand -base64 24 | tr -d '/+=\n' | head -c 24 > "$f")
  fi
  cat "$f"
}

kargo_host() { akuity kargo instance get "$INSTANCE" --org-name "$ORG" -o json 2>/dev/null | jq -r '.hostname // empty'; }

# kargo_use: point the kargo CLI at this demo's instance. The CLI has one global login, so
# without this a command could act on whatever instance it was last logged into.
kargo_use() {
  local host pw
  host=$(kargo_host)
  [[ -n $host ]] || { echo "Kargo instance $INSTANCE not found in org $ORG (run make up)" >&2; return 1; }
  if [[ "$(kargo config view 2>/dev/null | yq '.apiAddress')" == "https://$host" ]] && kargo get projects >/dev/null 2>&1; then
    return 0
  fi
  pw=$(admin_password)
  echo "kargo CLI: logging in to https://$host (replaces the previous login)" >&2
  login() { kargo login "https://$host" --admin --password "$pw" >/dev/null 2>&1; }
  wait_for 300 login
}

# kargo_apply <file>: one file per call; several -f arguments fail with "not allowed".
kargo_apply() { retry 3 kargo apply -f "$1" >/dev/null; }

freights_json() { kargo get freight --project "$(project_of "$1")" -o json | jq '[.. | objects | select(.kind == "Freight")]'; }

# freight_for_tag <lane> <tag>: name of the lane's Freight carrying rollouts-demo:<tag>, if any
freight_for_tag() {
  freights_json "$1" | jq -r --arg t "$2" '[.[] | select(any(.images[]?; .tag == $t))
    | .metadata.name][0] // empty'
}
has_freight_for_tag() { [[ -n "$(freight_for_tag "$1" "$2")" ]]; }

# current <lane> <stage>: name of the Freight the Stage holds now
current() {
  kargo get stage "$2" --project "$(project_of "$1")" -o json \
    | jq -r '.status.freightHistory[0].items // {} | to_entries[0].value.name // empty'
}
# verified_in <lane> <freight> <stage>
verified_in() {
  kargo get freight --project "$(project_of "$1")" --name "$2" -o json | jq -e --arg s "$3" '.status.verifiedIn[$s]' >/dev/null
}
