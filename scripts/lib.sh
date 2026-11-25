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

# freight_for_tag <lane> <tag>: name of the lane's newest Freight carrying
# rollouts-demo:<tag>, if any. A tag can have several Freight in the web lane: each
# release of it (and each flag change) comes with a new commit.
freight_for_tag() {
  freights_json "$1" | jq -r --arg t "$2" '[.[] | select(any(.images[]?; .tag == $t))]
    | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}
has_freight_for_tag() { [[ -n "$(freight_for_tag "$1" "$2")" ]]; }

# freight_for_ref <lane> <tag-or-alias>: a Freight alias (e.g. oily-goat) names exactly
# one Freight; otherwise the newest Freight for that tag.
freight_for_ref() {
  local f
  f=$(freights_json "$1" | jq -r --arg a "$2" '[.[] | select(.alias == $a)][0].metadata.name // empty')
  [[ -n $f ]] && echo "$f" || freight_for_tag "$1" "$2"
}

# freight_for_commit <lane> <sha> <tag>: the Freight made from this commit and this tag
freight_for_commit() {
  freights_json "$1" | jq -r --arg c "$2" --arg t "$3" '[.[] | select(any(.commits[]?; .id == $c))
    | select(any(.images[]?; .tag == $t))][0].metadata.name // empty'
}
has_freight_for_commit() { [[ -n "$(freight_for_commit "$@")" ]]; }

freight_alias() { freights_json "$1" | jq -r --arg f "$2" '.[] | select(.metadata.name == $f) | .alias // ""'; }

# preload_image <image>: pull an image onto the kind node, so a registry hiccup can't stall
# a promotion. crictl on the node, because `kind load` fails on multi-arch images.
preload_image() {
  docker exec "$CLUSTER-control-plane" crictl pull "docker.io/$1" >/dev/null 2>&1 \
    || echo "note: could not pre-load $1; the cluster will pull it" >&2
}

# Feature flags for the web lane live in this file; every change is a commit, and so new
# Freight (see `make flag`).
FLAGS_FILE="teams/web-service/app/base/flags.env"

# require_clean <path>...: refuse to start when these files already have uncommitted edits,
# so a flag change or release never commits someone's unrelated work.
require_clean() {
  git -C "$DEMO_ROOT" diff --quiet HEAD -- "$@" \
    || { echo "uncommitted changes in: $*; commit or discard them first" >&2; return 1; }
}

# restore_on_failure <path>...: on a failed exit, put these files back as committed (a file
# that is not in HEAD yet is removed).
restore_files() {
  local p
  for p in "$@"; do
    if git -C "$DEMO_ROOT" cat-file -e "HEAD:${p#"$DEMO_ROOT/"}" 2>/dev/null; then
      git -C "$DEMO_ROOT" checkout -q HEAD -- "$p"
    else
      rm -f -- "$p"
    fi
  done
}
restore_on_failure() {
  local q; q=$(printf "%q " "$@")
  # shellcheck disable=SC2064,SC2154  # expand the paths now; rc is set inside the trap
  trap "rc=\$?; (( rc == 0 )) || restore_files $q; exit \$rc" EXIT
}

# flag_on_at_head <NAME>: true when the flag is on in the committed flags.env
flag_on_at_head() { git -C "$DEMO_ROOT" show "HEAD:$FLAGS_FILE" 2>/dev/null | grep -qx "$1=on"; }

# set_flag <NAME> <on|off>: edit flags.env in place (no commit)
set_flag() {
  local name=$1 value=$2 f="$DEMO_ROOT/$FLAGS_FILE"
  grep -q "^$name=" "$f" || { echo "unknown flag '$name'; flags: $(grep -oE '^[A-Z0-9_]+' "$f" | tr '\n' ' ')" >&2; return 1; }
  [[ $value == on || $value == off ]] || { echo "flag value must be on or off, not '$value'" >&2; return 1; }
  sed -i.bak "s/^$name=.*/$name=$value/" "$f" && rm -f "$f.bak"
}

# flags_at <sha>: the flags that are on at a commit, e.g. "CHECKOUT_V2", or "-"
flags_at() {
  git -C "$DEMO_ROOT" cat-file -e "$1" 2>/dev/null || git -C "$DEMO_ROOT" fetch -q origin main 2>/dev/null || true
  local on
  on=$(git -C "$DEMO_ROOT" show "$1:$FLAGS_FILE" 2>/dev/null | grep -E '^[A-Z0-9_]+=on$' | cut -d= -f1 | paste -sd, -) || true
  echo "${on:--}"
}

# publish <message> <path>...: commit paths on main and push, as if a developer merged a
# change. Prints the new commit's SHA. The Warehouse turns the commit into Freight.
publish() {
  local msg=$1; shift
  [[ "$(git -C "$DEMO_ROOT" rev-parse --abbrev-ref HEAD)" == main ]] \
    || { echo "publish: $DEMO_ROOT is not on main" >&2; return 1; }
  # Each step returns on failure: set -e does not apply inside the $(publish ...) callers use.
  git -C "$DEMO_ROOT" add -- "$@" || return 1
  git -C "$DEMO_ROOT" commit -q -m "$msg" -- "$@" || return 1
  git -C "$DEMO_ROOT" pull -q --rebase --autostash origin main \
    || { echo "publish: pulling origin main failed (offline, no access, or a conflict); check $DEMO_ROOT" >&2; return 1; }
  git -C "$DEMO_ROOT" push -q origin main \
    || { echo "publish: push to origin main failed (push access to GIT_REPO is needed)" >&2; return 1; }
  git -C "$DEMO_ROOT" rev-parse HEAD
}

# current <lane> <stage>: name of the Freight the Stage holds now
current() {
  kargo get stage "$2" --project "$(project_of "$1")" -o json \
    | jq -r '.status.freightHistory[0].items // {} | to_entries[0].value.name // empty'
}
# verified_in <lane> <freight> <stage>
verified_in() {
  kargo get freight --project "$(project_of "$1")" --name "$2" -o json | jq -e --arg s "$3" '.status.verifiedIn[$s]' >/dev/null
}
