#!/usr/bin/env bash
# Build the whole demo from nothing, or finish a partial build: kind cluster, Akuity
# instances and agents, Kargo admin login, credentials, Argo CD apps and add-ons, the
# Kargo project, and every Stage on the baseline version.
# Requires `akuity login`, OrbStack running, and a GitHub token (see config.env). Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- kind cluster (on $DOCKER_CONTEXT) ----------------------------------------------------
# An amd64 node image on an arm64 host runs emulated and kubeadm times out, so pin the
# host architecture.
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
export DOCKER_DEFAULT_PLATFORM=linux/$arch
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "kind cluster $CLUSTER exists"
else
  docker pull -q --platform "linux/$arch" "$KIND_NODE_IMAGE" >/dev/null
  kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE"
fi

# --- Akuity instances and agents ----------------------------------------------------------
for kind in argocd kargo; do
  if akuity "$kind" instance get "$INSTANCE" --org-name "$ORG" >/dev/null 2>&1; then
    log "$kind instance $INSTANCE exists"
  else
    version=ARGOCD_VERSION; [[ $kind == kargo ]] && version=KARGO_VERSION
    akuity "$kind" instance create "$INSTANCE" --org-name "$ORG" --version "${!version}" --description "$DESC"
  fi
done

configured() { akuity "$1" "$2" get "$3" "${A[@]}" -o json | jq -e '.reconciliationStatus.code == "STATUS_CODE_SUCCESSFUL"' >/dev/null; }

# One self-hosted Kargo agent in the kind cluster, so verification runs next to the
# Prometheus it queries. It is the instance's only agent and its default shard.
akuity kargo agent get "$CLUSTER" "${A[@]}" >/dev/null 2>&1 \
  || akuity kargo agent create "$CLUSTER" "${A[@]}" --self-hosted --akuity-argocd-name "$INSTANCE"
# New agents are configured asynchronously; installing before that finishes times out.
wait_for 900 configured kargo agent "$CLUSTER" || echo "WARNING: Kargo agent $CLUSTER not configured after 900s"
# Make it the default shard before installing: a controller that starts as a non-default
# shard ignores every Stage and Warehouse without a shard label until it restarts.
akuity kargo agent update "$CLUSTER" "${A[@]}" --default-shard >/dev/null
akuity kargo agent install "$CLUSTER" "${A[@]}" --context "$KCTX"
default_controller() {
  kubectl --context "$KCTX" -n akuity logs "deploy/kargo-controller-$CLUSTER" -c controller 2>/dev/null \
    | grep 'Starting Kargo Controller' | tail -1 | grep -q '"defaultController":true'
}
if ! wait_for 300 default_controller; then
  kubectl --context "$KCTX" -n akuity rollout restart "deploy/kargo-controller-$CLUSTER"
  wait_for 300 default_controller || echo "WARNING: Kargo controller is not the default shard; Stages will not reconcile"
fi

akuity argocd cluster get "$CLUSTER" "${A[@]}" >/dev/null 2>&1 || akuity argocd cluster create "$CLUSTER" "${A[@]}"
wait_for 900 configured argocd cluster "$CLUSTER" || echo "WARNING: Argo CD cluster $CLUSTER not configured after 900s"
akuity argocd cluster install-agent "$CLUSTER" "${A[@]}" --context "$KCTX"

# --- Kargo admin login (only the bcrypt hash is sent to the instance) ---------------------
pw=$(admin_password)
cat > "$tmp/admin.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: kargo-cm
data:
  adminAccountEnabled: "true"
  adminAccountTokenTtl: "24h"
---
apiVersion: v1
kind: Secret
metadata:
  name: kargo-secret
stringData:
  adminAccountPasswordHash: '$(htpasswd -nbBC 10 "" "$pw" | tr -d ':\n')'
YAML
retry 3 akuity kargo apply --org-name "$ORG" --name "$INSTANCE" -f "$tmp/admin.yaml"
kargo_use
log "kargo CLI on $(kargo_host)"

# --- Credentials, Argo CD apps and add-ons, Kargo project ---------------------------------
# Read the token only here, so everything above can be built before it exists.
token=$(github_token)
"$DEMO_ROOT/scripts/render.sh"
kargo_apply "$RENDERED/kargo/project.yaml"
cat > "$tmp/argocd-repo.yaml" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: repo-$PROJECT
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: $GIT_REPO
  username: x-access-token
  password: $token
YAML
cat > "$tmp/kargo-git.yaml" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: git-$PROJECT
  namespace: $PROJECT
  labels:
    kargo.akuity.io/cred-type: git
stringData:
  repoURL: $GIT_REPO
  username: x-access-token
  password: $token
YAML
retry 3 akuity argocd apply --org-name "$ORG" --name "$INSTANCE" -f "$tmp/argocd-repo.yaml"
retry 3 akuity kargo apply --org-name "$ORG" --name "$INSTANCE" -f "$tmp/kargo-git.yaml"
retry 3 akuity argocd apply --org-name "$ORG" --name "$INSTANCE" -f "$RENDERED/argocd/"
for f in analysis tasks warehouse stages; do kargo_apply "$RENDERED/kargo/$f.yaml"; done
log "Kargo project $PROJECT applied"

# Verification needs the ingress controller and Prometheus up before the first prod Stage.
addons_ready() {
  kubectl --context "$KCTX" -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=5s &&
  kubectl --context "$KCTX" -n monitoring rollout status deploy/prometheus-server --timeout=5s
}
wait_for 600 addons_ready || { echo "add-ons not ready after 600s; check the Argo CD UI"; exit 1; }
log "ingress-nginx and Prometheus ready"

# --- Every Stage on the baseline ----------------------------------------------------------
if [[ -z "$(current prod-wave3-e)" ]]; then
  "$DEMO_ROOT/scripts/baseline.sh"
fi
"$DEMO_ROOT/scripts/status.sh"
echo
echo "Kargo UI:   https://$(kargo_host)/project/$PROJECT   (user admin, password in .state/kargo-admin-password)"
echo "Argo CD UI: https://$(akuity argocd instance get "$INSTANCE" --org-name "$ORG" -o json | jq -r .hostname)"
