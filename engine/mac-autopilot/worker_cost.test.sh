#!/usr/bin/env bash
# worker_cost.py 从 worker 事件流记账：codex turn.completed / zc result 两种格式、失败切换覆写不重复计数、
# 按单元 / ticket / 阶段 / 后端汇总；gen_dashboard 的 cost_ledger 段与 node_health 的每票 p90 指标读同一份账。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/../.." && pwd -P)"
fail() { echo "worker_cost.test.sh: $*" >&2; exit 1; }
command -v python3 >/dev/null || fail "python3 is required"
command -v jq >/dev/null || fail "jq is required"

python3 "$script_dir/worker_cost.test.py" || fail 'reader fixtures failed'

fixture="$test_env_root/cost"
sup="$fixture/supervisor"
a="$sup/autopi"
repo="$fixture/repo"
agent_home="$fixture/agent"
mkdir -p "$a" "$repo" "$agent_home/eval/gold-check" "$fixture/sessions" "$fixture/bin"

# ---------- fixture：当前票、legacy 页脚，以及一张 cache-split 历史票 ----------
# 近窗两条用相对当前时钟的时间戳（gen_dashboard 的 24h 合计按真实 now 截窗）；历史票用固定旧日期。
impl_stamp="$(date -u -d '40 minutes ago' +%Y%m%dT%H%M%S)"
impl_end="$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
review_stamp="$(date -u -d '20 minutes ago' +%Y%m%dT%H%M%S)"
review_end="$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
impl_log="impl-issue-4355-${impl_stamp}Z.worker.log"
review_log="review-77-${review_stamp}Z.worker.log"
{
  echo '{"type":"thread.started","thread_id":"aaaaaaaa-0000-0000-0000-000000000001"}'
  echo '{"type":"turn.completed","usage":{"input_tokens":23000000,"cached_input_tokens":22310000,"output_tokens":10000}}'
} > "$sup/$impl_log"
touch -d "$impl_end" "$sup/$impl_log"
{
  echo '{"type":"event"}'
  echo '{"type":"result","usage":{"input_tokens":100000,"cache_read_input_tokens":40000,"cache_creation_input_tokens":10000,"output_tokens":5000}}'
} > "$sup/$review_log"
touch -d "$review_end" "$sup/$review_log"
printf 'codex\ntokens used\n200,000\ndone\n' > "$sup/impl-101-20261005T090000Z.worker.log"
touch -d 2026-10-05T09:30:00Z "$sup/impl-101-20261005T090000Z.worker.log"
printf 'codex\ntokens used\n100,000\ndone\n' > "$sup/impl-102-20261004T080000Z.worker.log"
touch -d 2026-10-04T09:00:00Z "$sup/impl-102-20261004T080000Z.worker.log"
cat > "$sup/impl-4103-20261005T090000Z.worker.log" <<'JSON'
{"type":"pipeline.execution","mode":"fresh","model":"gpt-6-luna"}
{"type":"thread.started","thread_id":"bbbbbbbb-0000-0000-0000-000000000001"}
{"type":"turn.completed","usage":{"input_tokens":200000,"cached_input_tokens":150149,"output_tokens":160000}}
JSON
touch -d 2026-10-05T09:10:00Z "$sup/impl-4103-20261005T090000Z.worker.log"

jq -n --arg impl "$impl_log" --arg review "$review_log" '{workers:[
 {"pid":0,"log":$impl,"unit":"issue-4355","type":"implement","model":"gpt-6-luna","started":"2026-10-20T11:00:00Z"},
 {"pid":0,"log":$review,"unit":"pr-77","type":"review","model":"glm-5.3","started":"2026-10-20T11:30:00Z"}]}' > "$a/workers.json"
cat > "$a/units.json" <<'JSON'
{"units":[
 {"id":"issue-4355","issue":4355,"stage":"merged","history":[{"stage":"merged","at":"2026-10-20T11:50:00Z"}]},
 {"id":"pr-77","pr":77,"issue":4366,"stage":"merged","history":[{"stage":"merged","at":"2026-10-19T10:00:00Z"}]},
 {"id":"pr-101","pr":101,"issue":4101,"stage":"ready-to-merge","history":[]},
 {"id":"pr-102","pr":102,"issue":4102,"stage":"ready-to-merge","history":[]},
 {"id":"pr-4103","pr":4103,"issue":4103,"stage":"merged","history":[{"stage":"merged","at":"2026-10-05T09:15:00Z"}]}]}
JSON
cp "$script_dir/config.template.json" "$a/config.json"
: > "$test_env_root/actions-run-cancellations.jsonl"
cat > "$fixture/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'pr list --state merged --limit 30 --json number,mergedAt') echo '[]' ;;
  *) echo '[]' ;;
esac
SH
cat > "$fixture/bin/ssh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fixture/bin/gh" "$fixture/bin/ssh"
mkdir -p "$agent_home/eval/gold-check"
cat > "$agent_home/eval/gold-check/results.json" <<'JSON'
{"version":1,"label":"gold-check","results":[
 {"stage":"implement","tokens":800000,"wallSeconds":120.5,"modelWallSeconds":100.25},
 {"stage":"review","tokens":200000,"wallSeconds":60.0,"modelWallSeconds":50.0}]}
JSON
touch -d "$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)" "$agent_home/eval/gold-check/results.json"

# ---------- node_health：每票 token / 墙钟 p90，阈值取窗口前历史 p50/p90 ----------
export MAC_AUTOPILOT_ROOT="$repo_root" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$a"
out="$(PATH="$fixture/bin:$PATH" python3 "$script_dir/node_health.py" --runtime "$a" \
  --audit "$test_env_root/actions-run-cancellations.jsonl" --hours 5 \
  --now 2026-10-20T12:00:00Z --json "$a/node-health.json")"
row() { grep -F "$1" <<<"$out" | head -1; }
# 近窗（7 天）关闭的票：4355 = 700k fresh（690k uncached input + 10k output），输入缓存率 97%；
# 4366 也有 cache split。窗口前只有 4103 一张 cache-split 历史票：209851 fresh tokens 给出 provisional
# 314776 / 419702 边界，10 分钟 wall 给出 15 / 20；两项都应保留静态边界，近期值仍然健康。
grep -Eq 'per-ticket worker fresh tokens p90.* 700000 .*<=800000.*>=4800000.*OK' <<<"$(row 'per-ticket worker fresh tokens p90')" \
  || fail "per-ticket fresh tokens p90 or its fallback bounds are wrong: $(row 'per-ticket worker fresh tokens p90')"
grep -Eq 'per-ticket worker wall minutes p90.* 30 .*<=38.*>=180.*OK' <<<"$(row 'per-ticket worker wall minutes p90')" \
  || fail "per-ticket wall p90 or static bounds are wrong: $(row 'per-ticket worker wall minutes p90')"
jq -e '.ticket_bounds.token.samples == 1 and .ticket_bounds.token.provisional == true
  and .ticket_bounds.token.healthy == 314776 and .ticket_bounds.token.unhealthy == 419702
  and .ticket_bounds.wall.samples == 1 and .ticket_bounds.wall.provisional == true
  and ([.ticket_spend[] | select(.ticket == 4355)][0]
       | .tokens == 23010000 and .fresh == 700000 and .wall_min == 30 and .closed_at == "2026-10-20T11:50:00Z" and .open == false)
  and ([.ticket_spend[] | select(.ticket == 4103)][0]
       | .fresh == 209851 and .wall_min == 10 and .closed_at == "2026-10-05T09:15:00Z" and .open == false)
  and ([.ticket_spend[] | select(.ticket == 4101)][0] | .fresh == null)
  and ([.ticket_spend[] | select(.ticket == 4366)][0] | .tokens == 155000)' \
  "$a/node-health.json" >/dev/null || fail "ticket spend or bounds missing from the scorecard: $(jq -c '.ticket_bounds, .ticket_spend' "$a/node-health.json")"
jq -e '.metrics[] | select(.id == "workorders.ticket_tokens_p90")
  | .value == 700000 and .healthy == 800000 and .unhealthy == 4800000 and .status == "OK" and .source != ""' \
  "$a/node-health.json" >/dev/null || fail "ticket tokens metric missing its value, static bounds or source"
jq -e '.metrics[] | select(.id == "workorders.ticket_wall_p90")
  | .value == 30 and .healthy == 38 and .unhealthy == 180 and .status == "OK"' \
  "$a/node-health.json" >/dev/null || fail "ticket wall metric did not retain its static bounds"
# unit_spend 经共享成本行走 --json 流：旧实现只读页脚时这张票是 0
jq -e '[.work_orders[] | select(.id == "issue-4355")][0].tokens == 700000' "$a/node-health.json" >/dev/null \
  || fail "a --json codex worker's tokens did not reach the work-order spend: $(jq -c '.work_orders' "$a/node-health.json")"

# ---------- gen_dashboard：同一份账进 cost_ledger（单元 / ticket / 阶段 / 后端 / 24h / eval） ----------
export CODEX_SESSIONS_DIR="$fixture/sessions" AGENT_HOME="$agent_home"
export MAC_AUTOPILOT_DASHBOARD_OUTPUT="$a/dashboard.data.js"
PATH="$fixture/bin:$PATH" python3 "$script_dir/gen_dashboard.py" || fail "gen_dashboard failed on the fixture"
dashboard_data="$(sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT")"
jq -e '
  (.cost_ledger.last_24h.runs == 2 and .cost_ledger.last_24h.raw == 23165000)
  and ([.cost_ledger.by_unit[] | select(.unit == "issue-4355")][0]
       | .in == 23000000 and .out == 10000 and .uncached == 690000 and .wall_min == 30 and .ticket == 4355)
  and ([.cost_ledger.by_unit[] | select(.unit == "pr-77")][0] | .raw == 155000 and .runs == 1)
  and ([.cost_ledger.by_ticket[] | select(.ticket == 4355)][0] | .tokens == 23010000)
  and ([.cost_ledger.by_ticket[] | select(.ticket == 4366)][0] | .raw == 155000 and .uncached == 110000)
  and .cost_ledger.by_phase.implement.raw == 23370000
  and .cost_ledger.by_phase.review.raw == 155000
  and .cost_ledger.by_backend.codex.raw == 23370000
  and .cost_ledger.by_backend.zcode.raw == 155000
  and .cost_ledger.eval.last_24h.tokens == 1000000
  and ([.cost_ledger.eval.labels[] | select(.label == "gold-check")][0].model_wall_seconds == 150.2)
  and ([.cost_ledger.by_unit[] | select(.unit == "101")][0].tokens == 200000)' \
  <<<"$dashboard_data" >/dev/null \
  || fail "cost_ledger missing or wrong: $(jq -c '.cost_ledger | {last_24h, by_unit, by_backend}' <<<"$dashboard_data")"

# ---------- gen_dashboard: 同一 7 天单元窗口的 token 效率 KPI ----------
token_sup="$fixture/token-supervisor"; token_a="$token_sup/autopi"
mkdir -p "$token_a"
cp "$script_dir/config.template.json" "$token_a/config.json"
cat > "$token_a/units.json" <<JSON
{"units":[
 {"id":"issue-7101","issue":7101,"pr":7101,"stage":"merged","history":[{"stage":"review-approve","at":"$impl_end"},{"stage":"merged","at":"$impl_end"}]},
 {"id":"issue-7103","issue":7103,"stage":"closed","history":[{"stage":"issue-closed","at":"$impl_end"}]},
 {"id":"issue-7104","issue":7104,"stage":"merged","history":[{"stage":"merged","at":"$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)"}]}
]}
JSON
cat > "$token_a/units-archive.json" <<JSON
{"units":[{"id":"issue-7102","issue":7102,"pr":7102,"stage":"merged","history":[
 {"stage":"review-request-changes","at":"$review_end"},{"stage":"review-approve","at":"$review_end"},{"stage":"merged","at":"$review_end"}]}]}
JSON
token_logs=()
token_ids=(cccccccc-0000-0000-0000-000000000001 cccccccc-0000-0000-0000-000000000002 cccccccc-0000-0000-0000-000000000003 cccccccc-0000-0000-0000-000000000004 cccccccc-0000-0000-0000-000000000006)
write_token_log() {
  local name="$1" session_id="$2" input="$3" cached="$4" output="$5"
  printf '{"type":"thread.started","thread_id":"%s"}\n{"type":"turn.completed","usage":{"input_tokens":%s,"cached_input_tokens":%s,"output_tokens":%s}}\n' \
    "$session_id" "$input" "$cached" "$output" > "$token_sup/$name"
  token_logs+=("$name")
}
tok_stamp_1="$(date -u -d '40 minutes ago' +%Y%m%dT%H%M%S)"
tok_stamp_2="$(date -u -d '35 minutes ago' +%Y%m%dT%H%M%S)"
tok_stamp_3="$(date -u -d '30 minutes ago' +%Y%m%dT%H%M%S)"
tok_stamp_4="$(date -u -d '25 minutes ago' +%Y%m%dT%H%M%S)"
tok_stamp_5="$(date -u -d '20 minutes ago' +%Y%m%dT%H%M%S)"
tok_stamp_6="$(date -u -d '10 days ago' +%Y%m%dT%H%M%S)"
write_token_log "impl-issue-7101-${tok_stamp_1}Z.worker.log" "${token_ids[0]}" 1000 400 200
write_token_log "impl-issue-7101-fix-${tok_stamp_2}Z.worker.log" "${token_ids[1]}" 500 100 100
write_token_log "impl-7102-${tok_stamp_3}Z.worker.log" "${token_ids[2]}" 2000 500 200
write_token_log "impl-issue-7103-fix-${tok_stamp_4}Z.worker.log" "${token_ids[3]}" 1000 500 100
unmatched_log="impl-unmatched-fixture-${tok_stamp_5}Z.worker.log"
printf 'tokens used\n50\n' > "$token_sup/$unmatched_log"
token_logs+=("$unmatched_log")
write_token_log "impl-issue-7104-${tok_stamp_6}Z.worker.log" "${token_ids[4]}" 9000000 8900000 100000
jq -n --arg a "${token_logs[0]}" --arg b "${token_logs[1]}" --arg c "${token_logs[2]}" \
  --arg d "${token_logs[3]}" --arg e "${token_logs[4]}" --arg f "${token_logs[5]}" \
  '{workers:[
    {pid:0,log:$a,unit:"issue-7101",type:"implement"},
    {pid:0,log:$b,unit:"issue-7101",type:"repair"},
    {pid:0,log:$c,unit:"issue-7102",type:"implement"},
    {pid:0,log:$d,unit:"issue-7103",type:"repair"},
    {pid:0,log:$e,unit:"unmatched-fixture",type:"implement"},
    {pid:0,log:$f,unit:"issue-7104",type:"implement"}]}' > "$token_a/workers.json"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$token_sup" MAC_AUTOPILOT_RUNTIME_DIR="$token_a"
export MAC_AUTOPILOT_DASHBOARD_OUTPUT="$token_a/dashboard.data.js" MAC_AUTOPILOT_COST_CACHE="$token_sup/.cost-cache.json"
token_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PATH="$fixture/bin:$PATH" python3 "$script_dir/node_health.py" --runtime "$token_a" \
  --audit "$test_env_root/actions-run-cancellations.jsonl" --hours 5 --now "$token_now" \
  --json "$token_a/node-health.json" >/dev/null || fail 'node_health failed on token-efficiency fixture'
jq -e '
  ([.metrics[] | select(.id == "efficiency.fresh_tokens_per_merged_7d")][0] | .value == 1500 and .healthy == 800000 and .unhealthy == 4800000 and .source != "")
  and ([.metrics[] | select(.id == "efficiency.unmerged_waste_pct_7d")][0] | (.value - (100 * 1100 / 5100) | abs) < 0.0001 and .healthy == 35 and .unhealthy == 50)
  and ([.metrics[] | select(.id == "efficiency.first_pass_yield_pct_7d")][0] | .value == 50 and .healthy == 65 and .unhealthy == 50)
  and ([.metrics[] | select(.id == "efficiency.repair_phase_pct_7d")][0] | (.value - (100 * 1700 / 5100) | abs) < 0.0001 and .healthy == 30 and .unhealthy == 45)' \
  "$token_a/node-health.json" >/dev/null || fail 'node_health omitted the token-efficiency scorecard rows'
PATH="$fixture/bin:$PATH" python3 "$script_dir/gen_dashboard.py" || fail 'gen_dashboard failed on token-efficiency fixture'
token_dashboard="$(sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT")"
jq -e '
  .summary.token_efficiency.window_days == 7
  and .summary.token_efficiency.merged_units == 2
  and .summary.token_efficiency.merged_fresh_tokens == 3000
  and .summary.token_efficiency.fresh_tokens_per_merged == 1500
  and .summary.token_efficiency.merged_raw_tokens == 4000
  and .summary.token_efficiency.raw_tokens_per_merged == 2000
  and .summary.token_efficiency.waste_tokens == 1100
  and .summary.token_efficiency.window_tokens == 5100
  and ((.summary.token_efficiency.waste_pct - (100 * 1100 / 5100) | abs) < 0.0001)
  and .summary.token_efficiency.first_pass_units == 1
  and .summary.token_efficiency.first_pass_pct == 50
  and .summary.token_efficiency.repair_tokens == 1700
  and ((.summary.token_efficiency.repair_pct - (100 * 1700 / 5100) | abs) < 0.0001)
  and .summary.token_efficiency.unattributed.ledger_keys == 1
  and .summary.token_efficiency.unattributed.tokens == 50
  and .summary.token_efficiency.unattributed.raw_tokens == 50
  and .summary.tokens_per_merged == 1500
  and .summary.tokens_per_merged != (.summary.real_daily_tokens / .summary.merged)' \
  <<<"$token_dashboard" >/dev/null \
  || fail "token-efficiency KPIs did not use the 7-day unit cohort: $(jq -c '.summary | {token_efficiency, tokens_per_merged, real_daily_tokens, merged}' <<<"$token_dashboard")"

# Dashboard aggregation must attach print-mode provider usage before building its ledger/KPIs.
provider_log="impl-issue-7199-$(date -u -d '5 minutes ago' +%Y%m%dT%H%M%S)Z.worker.log"
printf 'ZCode Built-in (skipped)\n' > "$token_sup/$provider_log"
jq --arg log "$provider_log" \
  '.units += [{id:"issue-7199",issue:7199,stage:"implementing",history:[]}]' \
  "$token_a/units.json" > "$token_a/units.json.tmp" && mv "$token_a/units.json.tmp" "$token_a/units.json"
jq --arg log "$provider_log" \
  '.workers += [{pid:0,log:$log,unit:"issue-7199",type:"implement"}]' \
  "$token_a/workers.json" > "$token_a/workers.json.tmp" && mv "$token_a/workers.json.tmp" "$token_a/workers.json"
export MAC_AUTOPILOT_WT_ROOT="$token_sup/wt" ZCODE_DB="$token_a/zcode.sqlite"
python3 - "$ZCODE_DB" "$MAC_AUTOPILOT_WT_ROOT/wt-issue-7199" <<'PY'
import sqlite3, sys
from datetime import datetime, timedelta, timezone
with sqlite3.connect(sys.argv[1]) as con:
    con.execute("create table session (id text, directory text)")
    con.execute("create table turn_usage (session_id text, started_at integer, input_tokens integer, cache_read_input_tokens integer, output_tokens integer, reasoning_tokens integer, cache_creation_input_tokens integer)")
    started = int((datetime.now(timezone.utc) - timedelta(minutes=2)).timestamp() * 1000)
    con.execute("insert into session values ('provider-fixture', ?)", (sys.argv[2],))
    con.execute("insert into turn_usage values ('provider-fixture', ?, 1000, 400, 100, 0, 0)", (started,))
PY
PATH="$fixture/bin:$PATH" python3 "$script_dir/gen_dashboard.py" || fail 'gen_dashboard failed with provider-usage fixture'
token_dashboard="$(sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT")"
jq -e '
  ([.cost_ledger.by_unit[] | select(.unit == "issue-7199")][0]
   | .runs == 1 and .tokens == 1100 and .fresh == 700)
  and .summary.token_efficiency.fresh_tokens_per_merged == 1500' \
  <<<"$token_dashboard" >/dev/null || fail 'dashboard omitted provider-record usage from its cost ledger'

# An unmeasured invocation must make token-based KPIs NO-DATA rather than count as zero.
unknown_log="impl-issue-7105-${tok_stamp_5}Z.worker.log"
printf 'usage unavailable\n' > "$token_sup/$unknown_log"
jq --arg log "$unknown_log" --arg at "$impl_end" \
  '.units += [{id:"issue-7105",issue:7105,stage:"merged",history:[{stage:"merged",at:$at}]}]' \
  "$token_a/units.json" > "$token_a/units.json.tmp" && mv "$token_a/units.json.tmp" "$token_a/units.json"
jq --arg log "$unknown_log" \
  '.workers += [{pid:0,log:$log,unit:"issue-7105",type:"implement"}]' \
  "$token_a/workers.json" > "$token_a/workers.json.tmp" && mv "$token_a/workers.json.tmp" "$token_a/workers.json"
PATH="$fixture/bin:$PATH" python3 "$script_dir/node_health.py" --runtime "$token_a" \
  --audit "$test_env_root/actions-run-cancellations.jsonl" --hours 5 --now "$token_now" \
  --json "$token_a/node-health.json" >/dev/null || fail 'node_health failed with unknown usage in the KPI cohort'
jq -e '
  ([.metrics[] | select(.id == "efficiency.fresh_tokens_per_merged_7d")][0] | .value == null and .status == "NO-DATA")
  and ([.metrics[] | select(.id == "efficiency.unmerged_waste_pct_7d")][0] | .value == null and .status == "NO-DATA")
  and ([.metrics[] | select(.id == "efficiency.first_pass_yield_pct_7d")][0] | .value == 200 / 3)
  and ([.metrics[] | select(.id == "efficiency.repair_phase_pct_7d")][0] | .value == null and .status == "NO-DATA")' \
  "$token_a/node-health.json" >/dev/null || fail 'unknown usage was silently counted as zero in node-health KPIs'
PATH="$fixture/bin:$PATH" python3 "$script_dir/gen_dashboard.py" || fail 'gen_dashboard failed with unknown usage in the KPI cohort'
token_dashboard="$(sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT")"
jq -e '
  .summary.token_efficiency.fresh_tokens_per_merged == null
  and .summary.token_efficiency.merged_fresh_measured_units == 2
  and .summary.token_efficiency.merged_raw_tokens == null
  and .summary.token_efficiency.waste_pct == null
  and .summary.token_efficiency.first_pass_pct == (200 / 3)
  and .summary.token_efficiency.repair_pct == null
  and ([.cost_ledger.by_unit[] | select(.unit == "issue-7105")][0]
       | .unknown_runs == 1 and .tokens == 0)' \
  <<<"$token_dashboard" >/dev/null \
  || fail 'dashboard did not keep unknown usage out of token KPI denominators'

# 每票 fresh p90 无缓存拆分时是 NO-DATA（不是 0，也不是旧的 580k）：票的 run 没有用量记录
nd="$test_env_root/cost-nodata"; nda="$nd/supervisor/autopi"; mkdir -p "$nda"
cat > "$nda/units.json" <<'JSON'
{"units":[{"id":"issue-77","issue":77,"stage":"merged","history":[{"stage":"pr-opened","at":"2026-11-05T09:00:00Z"},{"stage":"merged","at":"2026-11-05T11:00:00Z"}]}]}
JSON
printf 'done\n' > "$nd/supervisor/impl-issue-77-20261105T100000Z.worker.log"
printf 'report\n' > "$nd/supervisor/impl-issue-77-20261105T100000Z.md"
PATH="$fixture/bin:$PATH" python3 "$script_dir/node_health.py" --runtime "$nda" \
  --audit "$test_env_root/actions-run-cancellations.jsonl" --hours 5 \
  --now 2026-11-07T12:00:00Z --json "$nda/node-health.json" >/dev/null
jq -e '.metrics[] | select(.id == "workorders.ticket_tokens_p90")
  | .value == null and .status == "NO-DATA" and (.source | test("NO-DATA"))' "$nda/node-health.json" >/dev/null \
  || fail "a ticket without a cache split must leave ticket tokens NO-DATA: $(jq -c '.metrics[] | select(.id == "workorders.ticket_tokens_p90")' "$nda/node-health.json")"

echo 'worker_cost.test.sh: PASS'
