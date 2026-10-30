#!/usr/bin/env bash
# hf-release.sh <pr-number> <anchor-issue>: image lane. Waits for the install gate
# (green main CI containing the merge), then runs the one release path (run-release.sh)
# at the merged SHA now, not at the next batch tick. run-release builds only the images
# changed-images.mjs maps from the diff against the deployed SHA, deploys them with the
# SHA tag, and runs drift capture and acceptance, so nothing is patched inside a container.
# Exclusive with every other release: it refuses while any zf-release-* unit is active
# and dispatches under the same shared vecta-release-batch unit, so systemd-run also
# refuses a concurrent batch. The head (sole release scheduler) gets one line on start
# and one on end through the supervisor inbox, the channel run-release already uses.
# If post-deploy acceptance could not run for environment reasons, the hotfix stays
# 未验收 and the hotfix owner (zf-57) is told on the first occurrence -- unlike the
# batch lane's c0d98c310 rule, which waits for a repeat within 3 days.
set -euo pipefail
unset GH_TOKEN
usage() { echo 'usage: hf-release.sh <pr-number> <anchor-issue>' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd); agent=$(cd "$here/.." && pwd)

if [[ $# == 6 && $1 == --report-end && $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ && $4 =~ ^[0-9a-f]{40,64}$ && $5 =~ ^[0-9]+$ && $6 =~ ^[0-9]+$ ]]; then
  pr=$2 anchor=$3 sha=$4 epoch=$5 rc=$6
  source "$agent/lib.sh"
  supervisor_inbox_append hotfix-release "hotfix image-lane release finished pr=#$pr issue=#$anchor sha=$sha exit=$rc" \
    || echo 'hf-release: could not notify supervisor of release end' >&2
  if [ -n "$(env_fault_lines_since env:production-e2e:runner "$epoch")" ]; then
    supervisor_inbox_append hotfix-release "hotfix acceptance not run: production E2E environment fault after deploy of sha=$sha issue=#$anchor owner=zf-57 status=未验收 -- rerun engine/hotfix/hf-release.sh $pr $anchor once the environment is fixed" \
      || echo 'hf-release: could not notify supervisor that acceptance did not run' >&2
  fi
  exit 0
fi
[[ $# == 2 && $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] || usage
pr=$1 anchor=$2
source "$agent/lib.sh"

# The merge is only minutes old here; green main CI containing it takes ~20+ min.
# Waiting here is what keeps hf-merge --image-lane's immediate handoff from leaving
# a merged-but-undeployed PR. On timeout the head and the hotfix owner are told.
wait="${HF_RELEASE_GATE_WAIT_SECONDS:-7200}"
deadline=$(( $(date +%s) + wait ))
until bash "$here/hf-install-gate.sh" "$pr"; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    supervisor_inbox_append hotfix-release "hotfix image-lane release not dispatched pr=#$pr issue=#$anchor reason=install-gate-not-green owner=zf-57 -- merged but undeployed; rerun engine/hotfix/hf-release.sh $pr $anchor" \
      || echo 'hf-release: could not notify supervisor of the undeployed merge' >&2
    echo "hf-release: install gate not green after $((wait / 60)) min; PR #$pr is merged but undeployed" >&2
    exit 1
  fi
  sleep 300
done

# Releases are serialized: head is the sole release scheduler. Refuse while any
# other release unit is active; the shared vecta-release-batch unit name below is
# the backstop for a race in the instant between this check and systemd-run.
active="$(systemctl --user list-units --state=active --no-legend --no-pager "${UNIT_PREFIX_TRANSIENT}-release-*" 2>/dev/null | cut -d' ' -f1 || true)"
if [ -n "$active" ]; then
  units="$(printf '%s ' $active)"
  supervisor_inbox_append hotfix-release "hotfix image-lane release refused pr=#$pr issue=#$anchor reason=release-active units=$units owner=zf-57 -- rerun engine/hotfix/hf-release.sh $pr $anchor when they finish" \
    || echo 'hf-release: could not notify supervisor of the refused start' >&2
  echo "hf-release: refusing to start while another release is active:" >&2
  printf '  %s\n' $active >&2
  exit 1
fi
sha=$(gh pr view "$pr" --json mergeCommit -q .mergeCommit.oid)
[[ "$sha" =~ ^[0-9a-f]{40,64}$ ]] || { echo 'hf-release: cannot read the merged SHA' >&2; exit 1; }
epoch=$(date +%s)
# Same transient unit as issue-pipeline dispatch_release_batch: a running batch makes systemd-run refuse.
# The wrapper reports the end (and any unrun acceptance) once run-release exits.
systemd-run --user --unit ${UNIT_PREFIX_TRANSIENT}-release-batch --collect \
  -E PATH -E https_proxy -E HTTPS_PROXY -E http_proxy -E HTTP_PROXY -E no_proxy -E NO_PROXY -E ALL_PROXY -E NODE_USE_ENV_PROXY \
  -p "RuntimeMaxSec=$((7 * 60 * 60))" \
  bash -c 'rc=0; "$1" "$2" "$3" || rc=$?; "$4" --report-end "$5" "$2" "$3" "$6" "$rc" || true; exit "$rc"' \
  hf-release-end "$agent/run-release.sh" "$anchor" "$sha" "$here/hf-release.sh" "$pr" "$epoch" \
  || { echo "hf-release: could not start ${UNIT_PREFIX_TRANSIENT}-release-batch (another release may have taken the unit); rerun hf-release.sh" >&2; exit 1; }
supervisor_inbox_append hotfix-release "hotfix image-lane release started pr=#$pr issue=#$anchor sha=$sha unit=${UNIT_PREFIX_TRANSIENT}-release-batch" \
  || echo 'hf-release: could not notify supervisor of release start' >&2
