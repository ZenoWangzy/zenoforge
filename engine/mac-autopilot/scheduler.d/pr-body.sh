declare -F slow_call_yield >/dev/null 2>&1 || source "$(dirname -- "${BASH_SOURCE[0]}")/lock-free-calls.sh"
# PR 正文从实现报告渲染（PR 5650，2026-11-08：报告新增的 ## prior-art 没进正文，下一轮评审白跑）。
# Row 898：gh pr view/gh pr edit 让开台账锁（decide 在锁内、调用在窗口、重取后重校验再写 hash）；
# 本 shell 未持锁时就地调用（合并站与派发路径的锁纪律不一，不得替调用方拿锁）。
PR_BODY_EDIT_OK=false
PR_BODY_VIEW_OK=false
PR_BODY_VIEW_JSON=""
pr_body_edit_collect() { # pr file → PR_BODY_EDIT_OK；台账锁外运行
  PR_BODY_EDIT_OK=false
  gh pr edit "$1" --body-file "$2" >/dev/null 2>&1 && PR_BODY_EDIT_OK=true
  return 0
}
pr_body_view_collect() { # pr → PR_BODY_VIEW_JSON（读取成功但正文为空也是合法正文，与失败分开：PR_BODY_VIEW_OK）；台账锁外运行
  PR_BODY_VIEW_OK=false
  PR_BODY_VIEW_JSON=""
  if PR_BODY_VIEW_JSON="$(gh pr view "$1" --json body -q .body 2>/dev/null)"; then
    PR_BODY_VIEW_OK=true
  else
    PR_BODY_VIEW_JSON=""
  fi
  return 0
}
pr_body_slow() { # fn args… → 持锁时经 slow_call_yield 让锁跑，未持锁时就地跑
  if [[ "${SCHED_LOCK_HELD:-false}" == true ]]; then
    slow_call_yield "${SCHED_LOCK_HOLDER_PHASE:-pr_body_refresh}" "$@"
  else
    "$@" || :
    return 0
  fi
}
pr_body_source() { # issue report-path [unit-json] → the body text before closing keywords are scrubbed
  local report sec
  report="$(head -40 "$2")"
  sec="$(awk -v h="## decision-log" '$0 ~ "^" h "[ \t]*$" { p = 1; print; next } /^## / { p = 0 } p' "$2")"
  if [[ -n "$sec" ]]; then
    report="$(awk '/^## decision-log[[:space:]]*$/{skip=1; next} /^##[[:space:]]/{skip=0} !skip' <<<"$report")"
    report+=$'\n\n'"$sec"
  fi
  printf '%s%s%s' "${1:+Refs #$1

}" "Implemented by the the product autopilot. Implementer report (first lines):

${report}" "$(self_check_verification_body "${3:-}")"
}
pr_body_hash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
pr_body_unit_current() { # id pr → 0 while the unit row still owns this PR (revalidation after a lock-free window)
  jqf -e --arg id "$1" --argjson pr "$2" 'any(.units[]; .id==$id and .pr==$pr)' "$UNITS" >/dev/null
}
pr_body_append_missing() { # unit pr report hash unit-json → a legacy PR (opened before .pr_body_hash) keeps its body; missing report, decision-log, and verification sections are appended
  local body new file h sec added=false missing=false unit="${5:-}"
  pr_body_slow pr_body_view_collect "$2"
  [[ "$PR_BODY_VIEW_OK" == true ]] || return 0
  body="$PR_BODY_VIEW_JSON"
  new="$body"
  for h in root-cause recurrence-guard prior-art decision-log verification; do
    grep -qE "^## $h[[:space:]]*\$" <<<"$body" && continue
    if [[ "$h" == verification ]]; then sec="$(self_check_verification_body "$unit")"; else sec="$(awk -v h="## $h" '$0 ~ "^" h "[ \t]*$" { p = 1; print; next } /^## / { p = 0 } p' "$3")"; fi
    if [[ -n "$sec" ]]; then new+=$'\n\n'"$sec"; added=true; else [[ "$h" == verification ]] || missing=true; fi
  done
  if [[ "$added" == true ]]; then
    file="$(mktemp)" || return 0
    scrub_closing_keywords <<<"$new" > "$file"
    pr_body_slow pr_body_edit_collect "$2" "$file"
    rm -f -- "$file"
    if [[ "$PR_BODY_EDIT_OK" != true ]]; then
      say "unit $1 PR#$2 legacy body append failed; tried again at the next review or land"
    elif pr_body_unit_current "$1" "$2" && set_unit "$1" ".pr_body_hash=$(js "$4")"; then
      say "unit $1 PR#$2 legacy body: appended the sections it lacked from ${3##*/}"
    else
      say "unit $1 PR#$2 legacy body append skipped: the unit changed while the ledger lock was released"
    fi
  elif [[ "$missing" == false ]] && pr_body_unit_current "$1" "$2"; then
    set_unit "$1" ".pr_body_hash=$(js "$4")" # complete as it is: the normal path takes over, one gh read less per pass
  fi
}
pr_body_refresh() { # unit-json → one gh pr edit --body-file when the current report renders a body other than the one stored at open
  local id pr rep src hash stored file
  id="$(jqf -r '.id // empty' <<<"$1")"; pr="$(jqf -r '.pr // empty' <<<"$1")"
  rep="$(jqf -r '.implementation_report // empty' <<<"$1")"; stored="$(jqf -r '.pr_body_hash // empty' <<<"$1")"
  [[ "$pr" =~ ^[0-9]+$ && -n "$rep" ]] || return 0
  [[ "$rep" == /* ]] || rep="$SUP/$rep"
  [[ -s "$rep" ]] || return 0
  src="$(pr_body_source "$(jqf -r '.issue // empty' <<<"$1")" "$rep" "$1")"
  hash="$(pr_body_hash "$src")"
  # No stored hash: the PR opened before the hash existed and its body may carry hand edits, so it is never re-rendered, only completed.
  [[ -n "$stored" ]] || { pr_body_append_missing "$id" "$pr" "$rep" "$hash" "$1"; return 0; }
  [[ "$hash" != "$stored" ]] || return 0
  file="$(mktemp)" || return 0
  scrub_closing_keywords <<<"$src" > "$file"
  pr_body_slow pr_body_edit_collect "$pr" "$file"
  rm -f -- "$file"
  if [[ "$PR_BODY_EDIT_OK" != true ]]; then
    say "unit $id PR#$pr body refresh failed; tried again at the next review or land"
  elif pr_body_unit_current "$id" "$pr" && set_unit "$id" ".pr_body_hash=$(js "$hash")"; then
    say "unit $id PR#$pr body re-rendered from ${rep##*/}"
  else
    say "unit $id PR#$pr body refresh skipped: the unit changed while the ledger lock was released"
  fi
}
