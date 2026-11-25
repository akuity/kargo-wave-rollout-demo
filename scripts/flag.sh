#!/usr/bin/env bash
# flag.sh <NAME> <on|off>: change one feature flag (teams/web-service/app/base/flags.env)
# and commit it, as a developer would. Kargo makes new Freight from the commit: the
# current release's image with the new flags. dev takes it on its own; promote it through
# qa and prod like any release. If it hurts, verification fails and Kargo rolls the
# Stage back to the previous Freight, flags and all.
#
# A rollback only changes what the Stages run; main still has the flag. Turn it back off
# with this script when you're done, or every later release carries it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
name=$(tr '[:lower:]' '[:upper:]' <<<"${1:?usage: flag.sh <NAME> <on|off>}")
value=$(tr '[:upper:]' '[:lower:]' <<<"${2:?usage: flag.sh <NAME> <on|off>}")
flags="$DEMO_ROOT/$FLAGS_FILE"
kargo_use
require_clean "$flags"
restore_on_failure "$flags"
set_flag "$name" "$value"
git -C "$DEMO_ROOT" diff --quiet -- "$flags" && { echo "$name is already $value"; exit 0; }
# Make sure the Warehouse admits the current release's tag before the commit lands.
tag=$(release_tag web)
"$DEMO_ROOT/scripts/render.sh"
kargo_apply "$RENDERED/web/warehouse.yaml"
sha=$(publish "flags: $name=$value" "$flags")
kargo refresh warehouse "$(warehouse_of web)" --project "$WEB_PROJECT" >/dev/null
wait_for 300 has_freight_for_commit web "$sha" "$tag" || { echo "no Freight for commit $sha"; exit 1; }
f=$(freight_for_commit web "$sha" "$tag")
log "$WEB_PROJECT: Freight for rollouts-demo:$tag + $name=$value is $(freight_alias web "$f") ($f)"
[[ $name == CHECKOUT_V2 && $value == on ]] && \
  echo "note: CHECKOUT_V2 stays on in main after a rollback; \`make flag NAME=CHECKOUT_V2 VALUE=off\` when done." >&2
exit 0
