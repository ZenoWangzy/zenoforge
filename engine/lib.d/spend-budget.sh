
spend_file_for_day() { echo "$SPEND_DIR/$(date -u -d "@$1" +%Y-%m-%d).log"; }

issue_spend_budget_status() {
  local n="$1" now="${2:-$(date +%s)}" since today yesterday rows="" file contents result status calls tokens
  [[ "$n" =~ ^[1-9][0-9]*$ && "$now" =~ ^[0-9]+$ \
    && "$ISSUE_CALL_BUDGET_THRESHOLD" =~ ^[1-9][0-9]*$ \
    && "$ISSUE_TOKEN_BUDGET_THRESHOLD" =~ ^[1-9][0-9]*$ ]] || return 2
  since=$((now - 86400))
  today="$(spend_file_for_day "$now")"
  yesterday="$(spend_file_for_day "$since")"
  if [ -e "$SPEND_DIR" ] && { [ ! -d "$SPEND_DIR" ] || [ ! -r "$SPEND_DIR" ] || [ ! -x "$SPEND_DIR" ]; }; then
    printf 'unknown\t0\t0\n'
    return 0
  fi
  for file in "$today" "$yesterday"; do
    [ -e "$file" ] || continue
    if [ ! -f "$file" ] || ! contents="$(cat "$file" 2>/dev/null)"; then
      printf 'unknown\t0\t0\n'
      return 0
    fi
    rows+="$contents"$'\n'
  done
  result="$(awk -F '\t' -v issue="$n" -v since="$since" \
    -v call_threshold="$ISSUE_CALL_BUDGET_THRESHOLD" \
    -v token_threshold="$ISSUE_TOKEN_BUDGET_THRESHOLD" '
    function matches(field, issue, rest, count, ids, i) {
      if (field == issue) return 1
      if (substr(field, 1, 6) != "batch:") return 0
      rest = substr(field, 7)
      count = split(rest, ids, ",")
      for (i = 1; i <= count; i++) if (ids[i] == issue) return 1
      return 0
    }
    matches($4, issue) && $1 ~ /^[0-9]+$/ && $1 >= since {
      calls++
      if (NF >= 6 && $6 != "") {
        if ($6 !~ /^[0-9]+$/) bad=1
        else tokens += $6
      }
    }
    END {
      if (bad) print "unknown\t" calls+0 "\t" tokens+0
      else if (calls >= call_threshold || tokens >= token_threshold)
        print "over\t" calls+0 "\t" tokens+0
      else print "clear\t" calls+0 "\t" tokens+0
    }
  ' <<< "$rows")" || return 1
  IFS=$'\t' read -r status calls tokens <<< "$result"
  printf '%s\t%s\t%s\n' "$status" "${calls:-0}" "${tokens:-0}"
}

hold_issue_spend_budget() {
  local n="$1" window_end="$2" edit_label
  local -a edit_args=(--holder issue-spend-budget \
    --release "24-hour spend window ends at $window_end; budget can be checked again then" \
    --expires "$window_end" --kind spend-budget)
  for edit_label in "${ALL_STATE_LABELS[@]}"; do
    [ "$edit_label" = on-hold ] || edit_args+=(--remove-label "$edit_label")
  done
  hold_issue "$n" "${edit_args[@]}" || return 1
  # 2026-10-05: issue 2498, the only frontier of 27 wayfinder tickets, sat in
  # this hold unseen until the maintainer asked. The hold waits on a person, so
  # it rings the supervisor.
  supervisor_inbox_append_once "spend-budget-hold issue=#$n" \
    "spend-budget-hold issue=#$n until=$window_end -- no dispatch before then; hand-dispatch, rehold or let it wait"
}


route_issue_spend_budget() {
  local n="$1" calls="$2" tokens="$3" state prior prior_epoch now_epoch now_at window_end repeat_count
  local risk level route_text marker budget_json hold_status
  [[ "$calls" =~ ^[0-9]+$ && "$tokens" =~ ^[0-9]+$ ]] || return 64
  state="$(state_read "$n")" || return 1
  prior="$(jq -r '.issue_spend_budget.routed_at // empty' <<< "$state")" || return 1
  now_epoch="$(date -u +%s)" || return 1
  repeat_count=0
  if [ -n "$prior" ]; then
    prior_epoch="$(agent_epoch -u "$prior" 2>/dev/null)" || {
      echo "route_issue_spend_budget: invalid prior window for #$n" >&2
      return 1
    }
    if (( now_epoch < prior_epoch + 86400 )); then
      window_end="$(jq -r '.issue_spend_budget.window_end // empty' <<< "$state")" || return 1
      if [ -z "$window_end" ]; then
        window_end="$(date -u -d "@$((prior_epoch + 86400))" +%Y-%m-%dT%H:%M:%SZ)" || return 1
      fi
      if has_label "$n" on-hold; then
        return 0
      else
        hold_status=$?
      fi
      [ "$hold_status" -eq 1 ] || return "$hold_status"
      hold_issue_spend_budget "$n" "$window_end" || return 1
      return 0
    fi
    repeat_count="$(jq -r '(.issue_spend_budget.repeat_count // 0) + 1' <<< "$state")" || return 1
  fi
  now_at="$(date -u -d "@$now_epoch" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  window_end="$(date -u -d "@$((now_epoch + 86400))" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  marker="$ISSUE_SPEND_BUDGET_MARKER issue=$n window=$now_epoch -->"
  if (( repeat_count > 0 )); then
    hold_issue_spend_budget "$n" "$window_end" || return 1
    route_text="预算在前一窗口已触发；本次为重复触发，继续暂停至窗口结束。"
  else
    risk="$(jq -r '.risk_class // empty' <<< "$state")"
    level="$(jq -r '.level // empty' <<< "$state")"
    if [ -n "$risk" ] && [ -n "$level" ] && recut_categorically_oversized "$risk" "$level" \
      && ! jq -e '(.recut_children | type) == "array" and (.recut_children | length > 0)' <<< "$state" >/dev/null 2>&1; then
      route_to_recut "$n" || return 1
      route_text="已转入范围拆分流程。"
    else
      hold_issue_spend_budget "$n" "$window_end" || return 1
      route_text="已暂停自动派发，等待人工处理。"
    fi
  fi
  budget_json="$(jq -cn --arg at "$now_at" --arg time_end "$window_end" \
    --argjson calls "$calls" --argjson tokens "$tokens" --argjson repeat "$repeat_count" \
    '{routed_at:$at,window_end:$time_end,calls:$calls,tokens:$tokens,repeat_count:$repeat,repeated:($repeat > 0)}')" || return 1
  state_merge "$n" ".issue_spend_budget = ((.issue_spend_budget // {}) + $budget_json)" || return 1
  guarded_issue_comment "$n" "$BOT_DISCLAIMER
$marker
24 小时预算已达到上限：$calls 次模型调用（上限 ${ISSUE_CALL_BUDGET_THRESHOLD}），$tokens 个 token（上限 ${ISSUE_TOKEN_BUDGET_THRESHOLD}）。$route_text"
}


# Stop additional phases inside one implement run after its last permitted
# call. The current call is already in the ledger before this is checked.
issue_spend_budget_guard() {
  local n="$1" phase="$2" result status calls tokens
  result="$(issue_spend_budget_status "$n")" || return 1
  IFS=$'\t' read -r status calls tokens <<< "$result"
  case "$status" in
    clear) return 0 ;;
    over)
      route_issue_spend_budget "$n" "$calls" "$tokens" >/dev/null || return 1
      echo "run-implement: #$n reached model-call budget before $phase; stopping this run" >&2
      return 78
      ;;
    *)
      echo "run-implement: #$n spend ledger unreadable before $phase; stopping this run" >&2
      return 79
      ;;
  esac
}


# record_premium_spend <role> <model> <issue> <cost_usd|""> [now] [tokens|""] [note|""]
# One row is one model call, recorded after it returns. The first five fields
# remain the original epoch/role/model/issue/cost contract; tokens is appended
# as field 6 so old readers can continue to read field 4. Optional field 7 is
# an observation such as a web advisor model fallback. A Codex call has no
# invented USD value: its measured token count goes in field 6 instead.
# An unobserved cost is marked in field 5, leaving the token field numeric or
# empty for existing readers. Codex cost stays blank when its token usage exists.
record_premium_spend() {
  local role="$1" model="$2" n="$3" cost="${4:-}" now="${5:-$(date +%s)}" tokens="${6:-}" note="${7:-}" row
  if [ -z "$cost" ] && { [ -z "$tokens" ] || [[ "$model" != codex:* ]]; }; then
    cost=unobservable
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] record_premium_spend $role $model #$n cost=${cost:-?} tokens=${tokens:-?} note=${note:-?}" >&2
    return 0
  fi
  mkdir -p "$SPEND_DIR"
  row="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$now" "$role" "$model" "$n" "$cost" "$tokens")"
  [ -z "$note" ] || row+=$'\t'"$note"
  printf '%s\n' "$row" >> "$(spend_file_for_day "$now")"
}


# model_cost_usd <model call json output> -> total_cost_usd or empty.
model_cost_usd() {
  echo "$1" | jq -r '.total_cost_usd // empty' 2>/dev/null
}
