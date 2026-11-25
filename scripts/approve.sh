#!/usr/bin/env bash
# approve.sh: merge the open pull request Kargo opened for a prod-wave1 deploy, as an
# approver would in GitHub. The waiting promotion then syncs Argo CD and verifies.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
repo=$(sed -E 's#^https://github.com/##; s#\.git$##' <<<"$GIT_REPO")
pr=$(gh pr list -R "$repo" --state open --base rendered/prod-wave1 --json number,title \
  --jq 'sort_by(.number) | last | "\(.number)\t\(.title)"')
[[ -n $pr ]] || { echo "no open PR into rendered/prod-wave1 (promote to prod-wave1 first)"; exit 1; }
log "approving #${pr%%$'\t'*}: ${pr#*$'\t'}"
gh pr merge -R "$repo" "${pr%%$'\t'*}" --merge >/dev/null
log "merged; Kargo syncs prod-wave1 and starts verification"
