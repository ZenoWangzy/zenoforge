#!/usr/bin/env bash
# Backlog sweep of ~/wt after run-end cleanup stopped working (2026-10-21/22: it fetched origin first and
# kept every finished tree whenever the proxy stalled; 287 piled up). It applies the run-end gates of
# worktree-lifecycle.sh finish from local refs only:
#   - a tree younger than --min-age-hours (default 2) is left alone: its run may still be starting;
#   - a head with commits no local origin ref holds (and not patch-equivalent to origin/main) is archived
#     to a git bundle under ~/.zenoforge/archive and kept; this sweep never deletes it;
#   - every other tree goes through finish_worktree itself: lock, live owner, hand resume, uncommitted or
#     untracked material, then an ordinary `git worktree remove` and a safe local-branch delete.
# One line per tree: removed|kept <path> <reason>; a count per outcome at the end.
# usage: worktree-backlog-sweep.sh <repo> [--min-age-hours N]
set -euo pipefail

SWEEP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./worktree-lifecycle.sh
source "$SWEEP_DIR/worktree-lifecycle.sh"

sweep_repo="${1:-}"
[ -n "$sweep_repo" ] || { echo "usage: $0 <repo> [--min-age-hours N]" >&2; exit 2; }
shift
min_age_hours=2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --min-age-hours) min_age_hours="${2:?}"; shift 2 ;;
    *) echo "usage: $0 <repo> [--min-age-hours N]" >&2; exit 2 ;;
  esac
done
[[ "$min_age_hours" =~ ^[0-9]+$ ]] || { echo "--min-age-hours must be a whole number" >&2; exit 2; }

REPO="$(git -C "$sweep_repo" rev-parse --show-toplevel)"
REPO_ROOT="$(realpath -e -- "$REPO")"
REPO_NAME="${ZF_GH_REPO:-${ZF_REPO:?ZF_REPO is not set}}"
ARCHIVE_DIR="${AGENT_ARCHIVE:-$AGENT_HOME/archive}"
sweep_root="$(realpath -m -- "$WORKTREE_ROOT")"
cutoff=$(( $(date +%s) - min_age_hours * 3600 ))
declare -A outcome_counts=()

report() {
  local outcome="$1" path="$2" reason="$3"
  printf '%s\t%s\t%s\n' "$outcome" "$path" "$reason"
  outcome_counts["$outcome:${reason%%:*}"]=$(( ${outcome_counts["$outcome:${reason%%:*}"]:-0} + 1 ))
}

archive_unique() {
  local path="$1" branch="$2" head="$3" bundle ref
  bundle="$ARCHIVE_DIR/worktree-$(basename -- "$path")-${head:0:12}.bundle"
  if [ ! -s "$bundle" ]; then
    mkdir -p -- "$ARCHIVE_DIR"
    ref=HEAD
    [ -z "$branch" ] || ref="refs/heads/$branch"
    git -C "$path" bundle create -q "$bundle" "$ref" --not refs/remotes/origin/main >/dev/null 2>&1 \
      || { rm -f -- "$bundle"; return 1; }
  fi
  # The bundle must name the head it was made for.
  git -C "$path" bundle list-heads "$bundle" 2>/dev/null | awk -v h="$head" '$1 == h { found=1 } END { exit !found }' || return 1
  printf '%s\n' "$bundle"
}

records="$(git -C "$REPO" worktree list --porcelain)"
paths=() heads=() branches=()
path="" head="" branch=""
while IFS= read -r line; do
  case "$line" in
    'worktree '*) path="${line#worktree }"; head=""; branch="" ;;
    'HEAD '*) head="${line#HEAD }" ;;
    'branch '*) branch="${line#branch refs/heads/}" ;;
    '')
      [ -n "$path" ] || continue
      if [ "$(dirname -- "$(realpath -m -- "$path")")" = "$sweep_root" ]; then
        paths+=("$path"); heads+=("$head"); branches+=("$branch")
      fi
      path=""
      ;;
  esac
done <<< "$records"$'\n'

for ((i=0; i<${#paths[@]}; i++)); do
  path="${paths[$i]}" head="${heads[$i]}" branch="${branches[$i]}"
  created="$(stat -c %Y -- "$path/.git" 2>/dev/null || true)"
  if [[ "$created" =~ ^[0-9]+$ ]] && (( created > cutoff )); then
    report kept "$path" "younger-than-${min_age_hours}h"
    continue
  fi
  if [ -d "$path" ] && ! head_content_is_preserved "$branch" "$head"; then
    if bundle="$(archive_unique "$path" "$branch" "$head")"; then
      report kept "$path" "unique-commits: archived to $bundle"
    else
      report kept "$path" "unique-commits: bundle failed, left untouched"
    fi
    continue
  fi
  status=0
  messages="$(finish_worktree "$path" 2>&1 >/dev/null)" || status=$?
  if [ "$status" -eq 0 ] && [ ! -e "$path" ]; then
    report removed "$path" "${branch:-detached}"
  else
    reason="$(grep -E '^worktree-lifecycle: kept ' <<< "$messages" | tail -1 | sed -E 's/^worktree-lifecycle: kept [^;]*; ?//')"
    [ -n "$reason" ] || reason="$(tail -1 <<< "$messages" | sed -E 's/^worktree-lifecycle: //')"
    report kept "$path" "${reason:-finish exit $status}"
  fi
done

printf 'summary\t%s\n' "$(for k in "${!outcome_counts[@]}"; do printf '%s=%s\n' "$k" "${outcome_counts[$k]}"; done | sort | paste -sd' ')"
