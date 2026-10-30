#!/usr/bin/env bash
set -euo pipefail
unset GH_TOKEN
# --image-lane moves the gate to after the deploy (#4622): no pre-merge acceptance
# record, and the merged SHA is handed to hf-release.sh immediately, detached --
# an image-lane PR must never sit merged-but-undeployed while the owner waits
# for green main CI. Without the flag the container-patch fallback keeps its
# pre-merge acceptance bar unchanged.
image_lane=0
if [[ $# == 1 && $1 =~ ^[0-9]+$ ]]; then
  pr=$1
elif [[ $# == 3 && $1 == --image-lane && $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]]; then
  image_lane=1 pr=$2 anchor=$3
else
  echo 'usage: hf-merge.sh [--image-lane <anchor-issue>] <pr-number>' >&2
  exit 2
fi
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/../config.sh" # deploy.env: a clean environment still sees the deployment's unit prefix
# Same setting lib.sh resolves; this script runs without sourcing it.
UNIT_PREFIX_TRANSIENT="${ZF_UNIT_PREFIX:-zf}"
info=$(gh pr view "$pr" --json title,labels,state,headRefOid,body,statusCheckRollup)
jq -e '.state == "OPEN" and any(.labels[]; .name == "hotfix")' <<<"$info" >/dev/null || { echo 'hf-merge: open PR with hotfix label required' >&2; exit 1; }
head_sha=$(jq -r '.headRefOid // empty' <<<"$info")
[[ "$head_sha" =~ ^[0-9a-f]{40,64}$ ]] || { echo 'hf-merge: cannot read current PR head SHA' >&2; exit 1; }
if [[ "$image_lane" != 1 ]]; then
  PR_BODY=$(jq -r '.body // ""' <<<"$info") PR_HEAD_SHA="$head_sha" \
    PR_NUMBER="$pr" PR_CHANGED_FILES="$(gh pr view "$pr" --json files -q '.files[].path')" node "$here/validate-acceptance.mjs"
fi

# The aggregate gate is the merge bar. --latest-checks is the shared reader:
# per check name on the current head it drops SKIPPED rows (#4687) and keeps
# the newest run, so an older success cannot hide a newer failure (#4632).
checks=$(node "$here/../ci/pr-required-aggregate.mjs" --latest-checks \
  <<<"$(jq -c '{headRefOid, statusCheckRollup}' <<<"$info")") \
  || { echo 'hf-merge: cannot select current required check results' >&2; exit 1; }

# Required PR checks are the source of truth for both lanes. The container-patch
# fallback additionally requires the dedicated acceptance check, which refreshes
# when the PR body is edited; the image lane proves acceptance after the deploy.
while IFS= read -r check; do
  conclusion=$(jq -r --arg name "$check" \
    '[.statusCheckRollup[]? | select(.name == $name)] | last | .conclusion // empty' <<<"$checks")
  [[ "$conclusion" == SUCCESS ]] || {
    echo "hf-merge: required check '$check' has not passed on the current head" >&2
    exit 1
  }
done < <(jq -r '.required[]' "$here/../mac-autopilot/required-pr-checks.json")

if [[ "$image_lane" != 1 ]]; then
  acceptance_check=$(jq -r \
    '[.statusCheckRollup[]? | select(.name == "Hotfix acceptance evidence")] | last | .conclusion // empty' <<<"$checks")
  [[ "$acceptance_check" == SUCCESS ]] \
    || { echo 'hf-merge: "Hotfix acceptance evidence" has not passed on the current head' >&2; exit 1; }
fi

title=$(jq -r '.title' <<<"$info")
gh pr merge "$pr" --squash --subject "$title [hotfix] (#$pr)" --match-head-commit "$head_sha"

if [[ "$image_lane" == 1 ]]; then
  gate_wait="${HF_RELEASE_GATE_WAIT_SECONDS:-7200}"
  systemd-run --user --unit "${UNIT_PREFIX_TRANSIENT}-hf-release-$pr" --collect \
    -E PATH -E https_proxy -E HTTPS_PROXY -E http_proxy -E HTTP_PROXY -E no_proxy -E NO_PROXY -E ALL_PROXY -E NODE_USE_ENV_PROXY \
    -p WorkingDirectory="$PWD" -p "RuntimeMaxSec=$((gate_wait + 900))" \
    "$here/hf-release.sh" "$pr" "$anchor" || {
      echo "hf-merge: #$pr merged but hf-release could not start; a merged image-lane PR must not stay undeployed -- rerun now:" >&2
      echo "  engine/hotfix/hf-release.sh $pr $anchor" >&2
      exit 1
    }
  echo "hf-merge: #$pr merged; hf-release.sh $pr $anchor waits for green main CI in unit ${UNIT_PREFIX_TRANSIENT}-hf-release-$pr"
fi
