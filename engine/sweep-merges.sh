#!/usr/bin/env bash
# Merge the dedicated revert PR of a failed production deploy, and the
# dedicated revert PR of a bisected red main Postsubmit, once their checks
# are green. The open-agent-PR rescue sweep was removed with the implement
# lane; the merge itself lives in lib.sh (guarded_pr_merge).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
if declare -F agent_reload_init >/dev/null; then agent_reload_init "$0" "$@"; agent_reload_restore; fi

# Product revert PRs use the same green-check/head-pinned merge primitive as
# every other agent PR. GitHub auto-merge is disabled on this repository, so a
# separate --auto request would leave every isolated batch blocked forever.
#
# The main gate is optimistic (#4356): a completed red blocks ordinary PRs
# until Postsubmit is green again. While that red is current, only its exact
# bisect revert PR may pass this helper; its branch, session and git-revert
# trailer must all name the same issue and culprit.
merge_green_revert_pr() { # <pr-row-json> <culprit> <subject-reason> [main-red-sha]
  local row="$1" culprit="$2" reason="$3"
  local red_sha="${4:-}" pr_number branch head checks message issue session current_red
  pr_number="$(jq -r '.number' <<< "$row")"
  [[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
  branch="$(jq -r '.headRefName' <<< "$row")"
  head="$(jq -r '.headRefOid' <<< "$row")"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 0
  [[ "$branch" =~ ^agent/revert-(deploy|main)-([0-9]+)-([0-9a-f]{12})$ ]] || return 0
  issue="${BASH_REMATCH[2]}"
  [ "${BASH_REMATCH[3]}" = "${culprit:0:12}" ] || return 0
  [ "$(jq -r '.isDraft' <<< "$row")" = false ] || return 0
  pr_mergeability_is_safe "$row" || return 0
  checks="$(gh pr checks "$pr_number" --repo "$REPO" --json name,bucket,link 2>/dev/null)" || return 0
  [ "$(pr_checks_outcome "$checks")" = pass ] || return 0
  message="$(gh api "repos/$REPO/git/commits/$head" --jq .message 2>/dev/null)" || return 0
  grep -Fxq "This reverts commit $culprit." <<< "$message" || return 0
  if ! main_merge_clear >/dev/null 2>&1; then
    [[ "$red_sha" =~ ^[0-9a-f]{40}$ ]] || return 0
    current_red="$(jq -r '.head_sha // empty' <<< "$MAIN_RELEASE_RUN_JSON" 2>/dev/null)"
    [ "$current_red" = "$red_sha" ] || return 0
    session="$(main_red_session_read "$red_sha" 2>/dev/null)" || return 0
    jq -e --arg issue "$issue" --arg culprit "$culprit" --arg pr_number "$pr_number" --arg head "$head" \
      '.status == "revert-open" and .culprit == $culprit
        and (.issue | tostring) == $issue and (.revert_pr | tostring) == $pr_number
        and .revert_head == $head' \
      <<< "$session" >/dev/null 2>&1 || return 0
  fi
  guarded_pr_merge "$pr_number" "revert: fix(#$issue) $reason" \
    "This reverts commit $culprit." "$head" || true
}

sweep_deploy_reverts() {
  local failed culprit rows row
  [ -s "$DEPLOY_BLOCKED_FILE" ] && [ -s "$DEPLOY_BLOCKED_FILE-culprit" ] || return 0
  read -r failed culprit < "$DEPLOY_BLOCKED_FILE-culprit" || return 0
  [ "$failed" = "$(cat "$DEPLOY_BLOCKED_FILE")" ] && [[ "$culprit" =~ ^[0-9a-f]{40}$ ]] || return 0
  rows="$(gh pr list --repo "$REPO" --state open --limit 1000 \
    --json number,headRefName,headRefOid,mergeable,mergeStateStatus,isDraft \
    -q '.[] | select(.headRefName | startswith("agent/revert-deploy-"))' | jq -c '.')" || return 0
  while IFS= read -r row; do
    if declare -F agent_reload_checkpoint >/dev/null; then agent_reload_checkpoint; fi
    [ -n "$row" ] || continue
    merge_green_revert_pr "$row" "$culprit" "after failed production deploy"
  done <<< "$rows"
}

# Revert PRs the main-red bisect opened (`agent/revert-main-<issue>-<sha12>`,
# one per session at status revert-open). Merging them is what makes main
# green again after a bisected culprit; the bisect sweep marks the session
# reverted once the PR lands.
sweep_main_red_reverts() {
  local session_file session red_sha culprit issue branch rows row
  [ -d "$MAIN_RED_DIR" ] || return 0
  while IFS= read -r session_file; do
    [ -n "$session_file" ] || continue
    if declare -F agent_reload_checkpoint >/dev/null; then agent_reload_checkpoint; fi
    session="$(jq -r 'select(type == "object" and .status == "revert-open")' "$session_file" 2>/dev/null || true)"
    [ -n "$session" ] || continue
    red_sha="$(jq -r '.red_sha // empty' <<< "$session")"
    culprit="$(jq -r '.culprit // empty' <<< "$session")"
    issue="$(jq -r '.issue // empty' <<< "$session")"
    [[ "$culprit" =~ ^[0-9a-f]{40}$ && "$issue" =~ ^[0-9]+$ ]] || continue
    branch="agent/revert-main-$issue-${culprit:0:12}"
    rows="$(gh pr list --repo "$REPO" --state open --limit 1000 \
      --json number,headRefName,headRefOid,mergeable,mergeStateStatus,isDraft \
      -q ".[] | select(.headRefName == \"$branch\")" | jq -c '.')" || continue
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      merge_green_revert_pr "$row" "$culprit" "after red main Postsubmit" "$red_sha"
    done <<< "$rows"
  done < <(printf '%s\n' "$MAIN_RED_DIR"/*.json)
}
sweep_deploy_reverts
sweep_main_red_reverts
