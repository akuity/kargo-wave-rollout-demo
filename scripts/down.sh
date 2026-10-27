#!/usr/bin/env bash
# Delete everything the demo created: Akuity instances and agents, the kind cluster, the
# rendered/* branches and local state. Never deletes the GitHub repo or your token.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
[[ "${1:-}" == "--yes" ]] || { echo "usage: down.sh --yes"; exit 2; }

# Only delete instances this demo created: an existing instance must carry the demo's exact
# description. Skip a kind only when the API says the instance does not exist.
for kind in argocd kargo; do
  if ! out=$(akuity "$kind" instance get "$INSTANCE" --org-name "$ORG" -o json 2>&1); then
    grep -qiE 'not ?found' <<<"$out" && continue
    echo "refusing: cannot read $kind instance $INSTANCE ($out)"; exit 2
  fi
  d=$(jq -r '.description // ""' <<<"$out")
  [[ $d == "$DESC" ]] || { echo "refusing: $kind instance $INSTANCE was not created by this demo (description: '$d')"; exit 2; }
done

akuity kargo agent delete "$CLUSTER" "${A[@]}" 2>/dev/null
akuity argocd cluster delete "$CLUSTER" "${A[@]}" 2>/dev/null

# Agent deletion is asynchronous, and the Argo CD instance cannot go while a Kargo agent is
# still linked to it, so retry each instance until it is gone.
gone() { ! akuity "$1" instance get "$INSTANCE" --org-name "$ORG" >/dev/null 2>&1; }
for kind in kargo argocd; do
  for _ in $(seq 1 20); do
    gone "$kind" && break
    akuity "$kind" instance delete "$INSTANCE" --org-name "$ORG" 2>&1 | tail -1
    sleep 15
  done
  gone "$kind" && echo "$kind instance $INSTANCE deleted" || echo "WARNING: $kind instance $INSTANCE still exists"
done

kind delete cluster --name "$CLUSTER"

# The rendered/<stage> branches Kargo created. Pushed with your own git credentials.
for b in $(git -C "$DEMO_ROOT" ls-remote --heads origin 'rendered/*' | awk '{print $2}'); do
  git -C "$DEMO_ROOT" push -q origin --delete "${b#refs/heads/}" && echo "deleted branch ${b#refs/heads/}"
done
rm -rf "$STATE_DIR" "$RENDERED"
echo "Done."
