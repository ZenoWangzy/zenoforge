#!/usr/bin/env bash
set -euo pipefail

liveness_dir="$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")"
liveness_helper="$liveness_dir/../hand-codex-liveness.sh"
[ -r "$liveness_helper" ] || liveness_helper="$liveness_dir/hand-codex-liveness.sh"
source "$liveness_helper" || exit 1

AGENT_HOME="${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
NIGHT="${ZF_NIGHT_DIR:-$AGENT_HOME/night}"
agent_lib="$AGENT_HOME/checkout/engine/lib.sh"
[[ -r "$agent_lib" ]] || agent_lib="$liveness_dir/../lib.sh"
[[ -r "$agent_lib" ]] || { echo "brief-addendum: shared agent library missing" >&2; exit 1; }
source "$agent_lib" || exit 1
source "$liveness_dir/hand-agent-watchdog.sh" || exit 1

usage() {
  echo "usage: $0 <name> <file-with-text> [role] | --agent-exited <name> <worktree> <brief> <report>" >&2
  exit 64
}

valid_name() {
  [[ "$1" =~ ^[[:alnum:]_.-]+$ && "$1" != . && "$1" != .. ]]
}

addendum() {
  local name="$1" text_file="$2" role="${3:-${ENQUEUE_ROLE:-}}" brief heading process_args worktree pending report recorded_report resume=0
  valid_name "$name" && [ -r "$text_file" ] || usage
  mkdir -p -- "$NIGHT/briefs" || return 1
  brief="$NIGHT/briefs/$name.md"
  pending="$NIGHT/$name.pending-addenda"
  report="$NIGHT/$name.report"
  recorded_report="$(jq -r '.report // empty' "$NIGHT/hand-registry/$name.json" 2>/dev/null || true)"
  case "$recorded_report" in "~/"*) recorded_report="$HOME/${recorded_report:2}" ;; esac
  [[ -r "$recorded_report" ]] && report="$recorded_report"
  worktree="${ZF_WORKTREE_ROOT:-$HOME/wt}/$name"
  exec 9>>"$NIGHT/$name.addenda.lock"
  flock -x 9 || return 1
  process_args="$(hand_codex_worktrees "${ZF_WORKTREE_ROOT:-$HOME/wt}/")" || { echo "brief-addendum: process check failed" >&2; return 1; }
  heading="## Addendum $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
  [ ! -s "$brief" ] || printf '\n' >> "$brief"
  {
    printf '%s\n' "$heading"
    cat -- "$text_file"
    printf '\n'
  } >> "$brief"
  if awk -v name="$name" '
    { path=$0; sub(/\/$/, "", path); sub(/^.*\//, "", path)
      if (path == name || index(path, name "-") == 1 || index(path, name "_") == 1) found=1 }
    END { exit !found }
  ' <<< "$process_args"; then
    printf '%s\n' "$heading" >> "$pending"
    printf 'brief-addendum: running %s; marked pending\n' "$name"
  else
    printf '%s\n' "$heading" >> "$pending"
    resume=1
  fi
  flock -u 9 || true
  exec 9>&-
  if [ "$resume" = 1 ]; then
    ENQUEUE_ROLE="$role" agent_exited "$name" "$worktree" "$brief" "$report" || return $?
  fi
  printf '%s\n' "$heading"
}

agent_exited() {
  local name="$1" worktree="$2" brief="$3" report="$4" pending heading needs_resume=0
  local recorded_issues resume_issues issue context episode recorded_worktree
  valid_name "$name" || usage
  pending="$NIGHT/$name.pending-addenda"
  [ -s "$pending" ] || return 0
  exec 9>>"$NIGHT/$name.addenda.lock"
  flock -x 9 || return 1
  [ -s "$pending" ] || { flock -u 9 || true; exec 9>&-; return 0; }
  while IFS= read -r heading || [ -n "$heading" ]; do
    [ -n "$heading" ] || continue
    if ! grep -Fq -- "$heading" "$report" 2>/dev/null; then needs_resume=1; break; fi
  done < "$pending"
  if [ "$needs_resume" = 0 ]; then
    rm -f -- "$pending"
    flock -u 9 || true; exec 9>&-
    return 0
  fi
  recorded_issues="$(jq -r '.owned_issues // empty' "$NIGHT/hand-registry/$name.json" 2>/dev/null || true)"
  resume_issues="$(hand_agent_issue_ids_from_brief "$name" "$brief" "${recorded_issues:+$recorded_issues }${ENQUEUE_ISSUES:-}")" || return 1
  if [ -z "$resume_issues" ]; then
    supervisor_inbox_append_once "brief-addendum-no-issue:$name" \
      "brief-addendum-no-issue name=$name brief=$brief report=$report" || return 1
    echo "brief-addendum: no issue recorded for $name; pending addendum retained" >&2
    return 1
  fi
  context="$(awk 'FNR==NR {wanted[$0]=1; next} /^## Addendum / {take=($0 in wanted)} take {print}' "$pending" "$brief")" || return 1
  if grep -q '^LANDING-CONTINUATION ' "$pending"; then
    context+=$'\n'"$(cat "$brief")"$'\n'"$(cat "$report")"
  fi
  [ -n "$context" ] || { echo "brief-addendum: pending text missing in $brief" >&2; return 1; }
  recorded_worktree="$(agent_latest_worktree_for_hand "$REPO_DIR" "$name" "$NIGHT/hand-registry/$name.json" "$report" "$worktree" 0 2>/dev/null || true)"
  if [ -n "$recorded_worktree" ]; then
    worktree="$recorded_worktree"
  elif [ -e "$worktree" ]; then
    supervisor_inbox_append_once "brief-addendum-worktree-unusable:$name" \
      "brief-addendum-worktree-unusable name=$name worktree=$worktree report=$report" || return 1
    echo "brief-addendum: cannot hand off unusable worktree $worktree" >&2
    return 1
  fi
  # If a second addendum arrives after a comment succeeds but before the
  # label transition succeeds, its distinct last heading makes the combined
  # text a new idempotent handoff rather than suppressing the new work.
  episode="$(tail -n 1 "$pending")"
  for issue in $resume_issues; do
    scheduler_requeue_issue "$issue" "former owner $name exited with pending addenda; worktree $worktree, report $report" "" "$context" "$episode" continuation-requeue . "$worktree" || return 1
    if [ "$SCHEDULER_REQUEUE_RESULT" != requeued ]; then
      echo "brief-addendum: issue #$issue is $SCHEDULER_REQUEUE_RESULT; pending addendum retained" >&2
      return 1
    fi
  done
  rm -f -- "$pending"
  flock -u 9 || true; exec 9>&-
  printf 'brief-addendum: requeued %s for scheduler\n' "$resume_issues"
}

case "${1:-}" in
  --agent-exited)
    [ "$#" -eq 5 ] || usage
    shift
    agent_exited "$@"
    ;;
  *)
    [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || usage
    addendum "$@"
    ;;
esac
