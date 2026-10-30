#!/usr/bin/env bash
set -euo pipefail
unset GH_TOKEN
[[ $# == 1 && $1 =~ ^[0-9]+$ ]] || { echo 'usage: hf-merge.sh <pr-number>' >&2; exit 2; }
pr=$1
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
info=$(gh pr view "$pr" --json title,labels,state,headRefOid,body,statusCheckRollup)
jq -e '.state == "OPEN" and any(.labels[]; .name == "hotfix")' <<<"$info" >/dev/null || { echo 'hf-merge: open PR with hotfix label required' >&2; exit 1; }
head_sha=$(jq -r '.headRefOid // empty' <<<"$info")
[[ "$head_sha" =~ ^[0-9a-f]{40,64}$ ]] || { echo 'hf-merge: cannot read current PR head SHA' >&2; exit 1; }
PR_BODY=$(jq -r '.body // ""' <<<"$info") PR_HEAD_SHA="$head_sha" \
  PR_NUMBER="$pr" PR_CHANGED_FILES="$(gh pr view "$pr" --json files -q '.files[].path')" node "$here/validate-acceptance.mjs"

# The aggregate gate is the merge bar. --latest-checks is the shared reader:
# per check name on the current head it drops SKIPPED rows (#4687) and keeps
# the newest run, so an older success cannot hide a newer failure (#4632).
checks=$(node "$here/../ci/pr-required-aggregate.mjs" --latest-checks \
  <<<"$(jq -c '{headRefOid, statusCheckRollup}' <<<"$info")") \
  || { echo 'hf-merge: cannot select current required check results' >&2; exit 1; }

# Required PR checks are the source of truth for the normal lane. Hotfix merges
# also require the dedicated acceptance check, which refreshes when the PR body
# is edited.
while IFS= read -r check; do
  conclusion=$(jq -r --arg name "$check" \
    '[.statusCheckRollup[]? | select(.name == $name)] | last | .conclusion // empty' <<<"$checks")
  [[ "$conclusion" == SUCCESS ]] || {
    echo "hf-merge: required check '$check' has not passed on the current head" >&2
    exit 1
  }
done < <(jq -r '.required[]' "$here/../mac-autopilot/required-pr-checks.json")

acceptance_check=$(jq -r \
  '[.statusCheckRollup[]? | select(.name == "Hotfix acceptance evidence")] | last | .conclusion // empty' <<<"$checks")
[[ "$acceptance_check" == SUCCESS ]] \
  || { echo 'hf-merge: "Hotfix acceptance evidence" has not passed on the current head' >&2; exit 1; }

title=$(jq -r '.title' <<<"$info")
gh pr merge "$pr" --squash --subject "$title [hotfix] (#$pr)" --match-head-commit "$head_sha"
