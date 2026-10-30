ingest_active_codex_events() { # 让预算快照包含仍在运行 worker 的已完成 turn，并标出其覆盖未结束
  local w pid log started
  while IFS= read -r w; do
    pid="$(jqf -r '.pid // empty' <<<"$w")"
    [[ "$pid" =~ ^[0-9]+$ ]] && alive "$pid" || continue
    log="$SUP/$(jqf -r '.log // empty' <<<"$w")"
    [[ -n "$log" && -f "$log" ]] || continue
    started="$(jqf -r '.started // empty' <<<"$w")"
    python3 "$USAGE_READER" codex-ingest "$log" "" "$started" "$BUDGET_EVENTS" in-flight \
      >/dev/null 2>&1 || true
  done < <(jqf -c '.workers[]? | select(.harvested != true)' "$WORKERS")
}
update_budget() { # 当日 Codex 用量记录；读不出来写 unavailable 记录并返回 1
  ingest_active_codex_events
  python3 "$USAGE_READER" codex-day "$SESSIONS_DIR" "$TODAY" "$SESSION_TZ" "$A/budget.json" "$A/budget-cache.json" \
    "${CLAUDE_PROJECTS_DIR:-${HOME:-/tmp}/.claude/projects}" "$WT_ROOT"
}
session_file_for_id() { python3 "$USAGE_READER" codex-session-file "$SESSIONS_DIR" "$1"; }

session_usage_for_id() { # cumulative counters plus raw and fresh, or null when unavailable (never zero)
  # 新会话由原生事件库回答（store 未覆盖时回退 rollout 解析，legacy 会话仍走旧路径）
  python3 "$USAGE_READER" codex-session-usage "$SESSIONS_DIR" "$1" "$BUDGET_EVENTS"
}

session_tokens_for_id() {
  session_usage_for_id "$1" | jqf -r 'if .==null then empty else .raw end'
}

session_last_tokens_for_id() { # compatibility: last event increment only; never dispatch accounting
  local session_file
  session_file="$(session_file_for_id "$1")"
  [[ -n "$session_file" ]] || return 0
  python3 - "$session_file" <<'PY'
import json
import sys

total = None
try:
    with open(sys.argv[1], encoding="utf-8", errors="ignore") as source:
        for line in source:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            payload = event.get("payload") or {}
            if event.get("type") != "event_msg" or payload.get("type") != "token_count":
                continue
            usage = (payload.get("info") or {}).get("last_token_usage")
            if not isinstance(usage, dict):
                total = None
                continue
            total = usage.get("total_tokens")
            if total is None:
                # input_tokens already includes cached_input_tokens; do not count cached twice.
                fields = ("input_tokens", "output_tokens")
                if any(key in usage for key in fields):
                    total = sum(int(usage.get(key, 0) or 0) for key in fields)
except OSError:
    pass
if total is not None:
    print(int(total))
PY
}
