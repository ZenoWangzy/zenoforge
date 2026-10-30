#!/usr/bin/env bash
# usage_reader.py behind the scheduler: the daily record for a fixture day stays byte-identical, a failed read stays
# "unavailable" (never zero), observed consumption survives a removed log, the resume threshold keeps comparing
# cumulative RAW tokens, and new sessions answer from native exec --json events. Reader-level fixtures (both
# providers) live in usage_reader.test.py.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "usage_reader.test.sh: $*" >&2; exit 1; }

python3 "$script_dir/usage_reader.test.py" || fail 'reader fixtures failed'

fixture="$test_env_root/usage"
sup="$fixture/supervisor"
sessions="$fixture/sessions"
day=2026-10-20
mkdir -p "$sup/autopi/alerts" "$fixture/repo" "$sessions/2026/10/20" "$fixture/threshold/2026/10/20"
cp "$script_dir/config.template.json" "$sup/autopi/config.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
jq -n '{units: [
  {id:"pr-high", stage:"repair-pending", session_ids:{review:"aaaaaaaa-0000-0000-0000-000000000001"}},
  {id:"pr-low",  stage:"repair-pending", session_ids:{review:"aaaaaaaa-0000-0000-0000-000000000002"}}]}' > "$sup/autopi/units.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export CODEX_SESSIONS_DIR="$sessions"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

counters() { # input cached output -> one actual Codex token_count line (cumulative totals, a different last_token_usage)
  jq -cn --argjson i "$1" --argjson c "$2" --argjson o "$3" --arg at "${4:-2026-10-20T12:00:00Z}" \
    '{timestamp:$at,type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{input_tokens:1,cached_input_tokens:0,output_tokens:1,total_tokens:2},total_token_usage:{input_tokens:$i,cached_input_tokens:$c,output_tokens:$o,total_tokens:($i+$o)}}}}'
}

# ---------- resume threshold: cumulative RAW (input + output) against 8M, never fresh ----------
# 9M raw but only 0.3M fresh. A fresh-based limit would resume this session; 464 of 500 eligible fresh review
# dispatches were in that situation, so it must still start fresh.
counters 8950000 8700000 50000 > "$fixture/threshold/2026/10/20/rollout-high-aaaaaaaa-0000-0000-0000-000000000001.jsonl"
counters 7800000 7500000 100000 > "$fixture/threshold/2026/10/20/rollout-low-aaaaaaaa-0000-0000-0000-000000000002.jsonl"
SESSIONS_DIR="$fixture/threshold"
build_codex_command rereview model max pr-high 'incremental repair'
[[ "$CODEX_MODE" == fresh && -z "$CODEX_SESSION_ID" ]] || fail "9M raw / 0.3M fresh session resumed (mode=$CODEX_MODE)"
build_codex_command rereview model max pr-low 'incremental repair'
[[ "$CODEX_MODE" == resume && "$CODEX_SESSION_ID" == aaaaaaaa-0000-0000-0000-000000000002 ]] \
  || fail "7.9M raw session did not resume (mode=$CODEX_MODE)"
SESSIONS_DIR="$sessions"

# ---------- daily meter ----------
# Fixture day 2026-10-20 in America/Los_Angeles (UTC-7): the day starts at 07:00Z.
cross="$sessions/2026/10/20/rollout-cross-11111111-2222-3333-4444-555555555555.jsonl"
running="$sessions/2026/10/20/rollout-running-22222222-3333-4444-5555-666666666666.jsonl"
stale="$sessions/2026/10/19/rollout-stale-33333333-4444-5555-6666-777777777777.jsonl"
mkdir -p "$sessions/2026/10/19"
{
  counters 100 30 20 2026-10-20T06:59:00Z   # the previous local evening: not today's
  counters 150 50 35 2026-10-20T07:01:00Z
  counters 150 50 35 2026-10-20T07:02:00Z
  counters 180 60 40 2026-10-20T07:03:00Z
} > "$cross"
{
  counters 1000 400 100 2026-10-20T20:00:00Z
  counters 3000 2000 500 2026-10-20T20:05:00Z
  printf '{"timestamp":"2026-10-20T20:10:00Z","type":"event_msg","payload":{"type":"token_'   # a running worker's partial last line
} > "$running"
counters 5000 1000 700 2026-10-19T12:00:00Z > "$stale"
touch -d 2026-10-20T21:00:00Z "$cross" "$running"
touch -d 2026-10-19T13:00:00Z "$stale"

TODAY="$day"; SESSION_TZ=America/Los_Angeles
export CLAUDE_PROJECTS_DIR="$fixture/claude-projects"; mkdir -p "$CLAUDE_PROJECTS_DIR"
update_budget >/dev/null || fail 'fixture day was reported unavailable'
# Raw fields keep their meaning; fresh (uncached input + output) and the provider split sit beside them.
expected_record='{"date":"2026-10-20","status":"measured","total":3600,"in":3080,"cached":2030,"out":520,"fresh":1570,"raw":3600,"providers":{"codex":{"fresh":1570,"raw":3600,"in":3080,"cached":2030,"out":520,"sessions":null},"claude":{"fresh":0,"raw":0,"in":0,"cached":0,"out":0,"sessions":0}},"bound":null,"outside_meter":"CTO and supervisor Claude sessions"}'
[[ "$(cat "$sup/autopi/budget.json")" == "$expected_record" ]] || fail "daily record changed: $(cat "$sup/autopi/budget.json")"

# 10-22 shape: 2.09B raw of which little is fresh. Measured days set the bound; a raw-sized day does not alarm, a fresh spike does.
echo '{"2026-10-17":100000,"2026-10-18":120000,"2026-10-19":110000}' > "$sup/autopi/budget-history.json"
update_budget >/dev/null; jq -e '.bound.unhealthy==240000 and .bound.provisional==true' "$sup/autopi/budget.json" >/dev/null || fail "bound not derived: $(cat "$sup/autopi/budget.json")"
STAMP=t; budget_alert_if_needed; [[ ! -s "$sup/autopi/alerts/waste.md" ]] || fail 'healthy fresh day alarmed'
jq '.fresh=900000' "$sup/autopi/budget.json" > "$sup/autopi/budget.tmp" && mv "$sup/autopi/budget.tmp" "$sup/autopi/budget.json"
budget_alert_if_needed; grep -q 'BUDGET-ALERT date=2026-10-20 fresh_tokens=900000' "$sup/autopi/alerts/waste.md" || fail 'fresh spike did not alarm'
rm -f "$sup/autopi/alerts/waste.md"
jq '.status="partial" | .fresh=900000' "$sup/autopi/budget.json" > "$sup/autopi/budget.tmp" && mv "$sup/autopi/budget.tmp" "$sup/autopi/budget.json"
budget_alert_if_needed; grep -q 'BUDGET-ALERT date=2026-10-20 fresh_tokens=900000.*partial-coverage' "$sup/autopi/alerts/waste.md" \
  || fail 'partial lower-bound spike did not identify its coverage'
rm -f "$sup/autopi/budget-history.json" "$sup/autopi/alerts/waste.md"; update_budget >/dev/null

# Consumption already observed survives the completed log being removed.
rm -- "$running"
update_budget >/dev/null || fail 'removed log made the day unavailable'
[[ "$(cat "$sup/autopi/budget.json")" == "$expected_record" ]] || fail "removed log dropped observed consumption: $(cat "$sup/autopi/budget.json")"

# A counter reset inside the day is "unavailable", never a smaller total.
counters 90 30 20 2026-10-20T07:05:00Z >> "$cross"
if update_budget >/dev/null 2>"$fixture/reset.err"; then fail 'counter reset was accepted'; fi
jq -e --arg path "$cross" '.status=="unavailable" and .total==null and .in==null and .cached==null and .out==null
  and (.error | startswith("Cannot account for Codex session file: " + $path + ": "))' "$sup/autopi/budget.json" >/dev/null \
  || fail "reset not recorded as unavailable: $(cat "$sup/autopi/budget.json")"

# ---------- 原生 codex exec --json 事件：新会话由事件库应答，rollout 解析退出新会话活跃路径 ----------
native_store="$fixture/native/budget-events.json"; mkdir -p "$fixture/native" "$fixture/native-sessions/2026/10/20"
# 8M raw 边界（比累计 raw，不比 fresh）：7,999,999 续会话；恰 8,000,000 与 9M raw/0.6M fresh 都冷启动
jq -n '{version:1,sessions:{
  "bbbbbbbb-0000-0000-0000-000000000001":{turns:[{in:8700000,cached:8400000,out:300000,ts:"2026-10-20T12:00:00Z"}],incomplete:false,last_at:"2026-10-20T12:00:00Z"},
  "bbbbbbbb-0000-0000-0000-000000000002":{turns:[{in:7800000,cached:7500000,out:199999,ts:"2026-10-20T12:00:00Z"}],incomplete:false,last_at:"2026-10-20T12:00:00Z"},
  "bbbbbbbb-0000-0000-0000-000000000003":{turns:[{in:7800000,cached:7500000,out:200000,ts:"2026-10-20T12:00:00Z"}],incomplete:false,last_at:"2026-10-20T12:00:00Z"}}}' > "$native_store"
# 事件库已覆盖 001：它 rollout 里的相反计数不得再被解析（新会话不走 rollout 路径）
counters 1000 0 0 > "$fixture/native-sessions/2026/10/20/rollout-x-bbbbbbbb-0000-0000-0000-000000000001.jsonl"
jq -n '{units: [
  {id:"pr-n1",stage:"repair-pending",session_ids:{review:"bbbbbbbb-0000-0000-0000-000000000001"}},
  {id:"pr-n2",stage:"repair-pending",session_ids:{review:"bbbbbbbb-0000-0000-0000-000000000002"}},
  {id:"pr-n3",stage:"repair-pending",session_ids:{review:"bbbbbbbb-0000-0000-0000-000000000003"}}]}' > "$UNITS"
BUDGET_EVENTS="$native_store"
SESSIONS_DIR="$fixture/native-sessions"
build_codex_command rereview model max pr-n1 'incremental repair'
[[ "$CODEX_MODE" == fresh && "${CODEX_COMMAND[*]}" == *' --json '* ]] \
  || fail "9M raw / 0.6M fresh session resumed, or --json missing (mode=$CODEX_MODE cmd=${CODEX_COMMAND[*]})"
build_codex_command rereview model max pr-n2 'incremental repair'
[[ "$CODEX_MODE" == resume && "$(jqf -r .raw <<<"$CODEX_USAGE_START")" == 7999999 ]] \
  || fail "7,999,999 raw session did not resume from the event store (mode=$CODEX_MODE start=$CODEX_USAGE_START)"
build_codex_command rereview model max pr-n3 'incremental repair'
[[ "$CODEX_MODE" == fresh ]] || fail "8,000,000 raw session resumed (mode=$CODEX_MODE)"
# 回收入库：同一 --json 日志交付两遍（含事件内重复），store 里仍然只有一turn
native_log="$fixture/native/worker.jsonl"
{
  echo '{"type":"thread.started","thread_id":"cccccccc-0000-0000-0000-00000000000c"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10}}'
  echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10}}'
} > "$native_log"
python3 "$USAGE_READER" codex-ingest "$native_log" "" "2026-10-20T12:00:00Z" "$native_store"
python3 "$USAGE_READER" codex-ingest "$native_log" "" "2026-10-20T12:00:00Z" "$native_store"
jq -e '.sessions["cccccccc-0000-0000-0000-00000000000c"].turns | length == 1' "$native_store" >/dev/null \
  || fail "repeated turn delivery double-counted: $(cat "$native_store")"
# live worker 事实：容忍 partial final line，fresh=末次累计的新鲜 token
{
  echo '{"type":"thread.started","thread_id":"cccccccc-0000-0000-0000-00000000000c"}'
  echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10}}'
  printf '%s' '{"type":"item.compl'
} > "$fixture/native/live.worker.log"
[[ "$(python3 "$USAGE_READER" codex-stream "$fixture/native/live.worker.log" | jqf -r .fresh)" == 30 ]] \
  || fail "stream fresh of a running worker's log is wrong"
# 被杀的 worker（有 turn.started 无 turn.completed）：codex-stream 标 complete=false，harvest 不得把旁白当最终答复
{
  echo '{"type":"thread.started","thread_id":"cccccccc-0000-0000-0000-00000000000d"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"narration only"}}'
} > "$fixture/native/killed.worker.log"
[[ "$(python3 "$USAGE_READER" codex-stream "$fixture/native/killed.worker.log" | jqf -r '.complete')" == false ]] \
  || fail "a killed worker's stream was reported complete"
[[ -z "$(python3 "$USAGE_READER" codex-stream "$fixture/native/killed.worker.log" | jqf -r 'select(.complete == true) | .message // empty')" ]] \
  || fail "a killed worker's narration would be recovered as its final message"
BUDGET_EVENTS="$A/budget-events.json"
SESSIONS_DIR="$sessions"

# A live worker is ingested before the daily snapshot, even when its latest turn just completed.
{
  counters 100 30 20 2026-10-20T06:59:00Z
  counters 150 50 35 2026-10-20T07:01:00Z
  counters 150 50 35 2026-10-20T07:02:00Z
  counters 180 60 40 2026-10-20T07:03:00Z
} > "$cross"
touch -d 2026-10-20T21:00:00Z "$cross"
active_sid="dddddddd-0000-0000-0000-00000000000d"
active_log="$sup/live.worker.log"
cat > "$active_log" <<JSONL
{"type":"thread.started","thread_id":"$active_sid"}
{"type":"turn.started"}
{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}}
JSONL
jq -n --arg log "$(basename "$active_log")" '{workers:[{pid:424242,type:"implement",log:$log,started:"2026-10-20T12:00:00Z"}]}' > "$WORKERS"
alive() { [[ "$1" == 424242 ]]; }
update_budget >/dev/null || fail 'a live worker made the daily meter unavailable'
jq -e --arg sid "$active_sid" '.status=="partial" and .total==4650 and .incomplete_sessions==[$sid]' \
  "$A/budget.json" >/dev/null || fail "live worker was not marked partial: $(cat "$A/budget.json")"

echo 'usage_reader.test.sh: PASS'
