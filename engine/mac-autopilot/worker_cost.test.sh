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

# ---------- fixture：一个 codex --json 实现流、一个 zc 评审流、两条历史票的 legacy 页脚 ----------
# 近窗两条用相对当前时钟的时间戳（gen_dashboard 的 24h 合计按真实 now 截窗）；历史票用固定旧日期。
impl_stamp="$(date -u -d '40 minutes ago' +%Y%m%dT%H%M%S)"
impl_end="$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
review_stamp="$(date -u -d '20 minutes ago' +%Y%m%dT%H%M%S)"
review_end="$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
impl_log="impl-issue-4355-${impl_stamp}Z.worker.log"
review_log="review-77-${review_stamp}Z.worker.log"
{
  echo '{"type":"thread.started","thread_id":"aaaaaaaa-0000-0000-0000-000000000001"}'
  echo '{"type":"turn.completed","usage":{"input_tokens":300000,"cached_input_tokens":100000,"output_tokens":30000}}'
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

jq -n --arg impl "$impl_log" --arg review "$review_log" '{workers:[
 {"pid":0,"log":$impl,"unit":"issue-4355","type":"implement","model":"gpt-6-luna","started":"2026-10-20T11:00:00Z"},
 {"pid":0,"log":$review,"unit":"pr-77","type":"review","model":"glm-5.3","started":"2026-10-20T11:30:00Z"}]}' > "$a/workers.json"
cat > "$a/units.json" <<'JSON'
{"units":[
 {"id":"issue-4355","issue":4355,"stage":"merged","history":[{"stage":"merged","at":"2026-10-20T11:50:00Z"}]},
 {"id":"pr-77","pr":77,"issue":4366,"stage":"merged","history":[{"stage":"merged","at":"2026-10-19T10:00:00Z"}]},
 {"id":"pr-101","pr":101,"issue":4101,"stage":"merged","history":[{"stage":"merged","at":"2026-10-05T10:00:00Z"}]},
 {"id":"pr-102","pr":102,"issue":4102,"stage":"merged","history":[{"stage":"merged","at":"2026-10-04T10:00:00Z"}]}]}
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
# 近窗（7 天）关闭的票：4355 = 330k token（300k 输入 + 30k 输出），4366 = 155k -> p90 = 330k
# 历史票（窗口前 30 天）：200k / 100k -> p50 = p90 = 200k（int(f*2)=1 取较大样本，daily_bound 同约定）
# -> healthy = 300k, unhealthy = 400k -> 330k 落在中间是 WARN
grep -Eq 'per-ticket worker tokens p90.* 330000 .*<=300000.*>=400000.*WARN' <<<"$(row 'per-ticket worker tokens p90')" \
  || fail "per-ticket tokens p90 or its history-derived bounds are wrong: $(row 'per-ticket worker tokens')"
grep -Eq ' 30 .*OK$' <<<"$(row 'per-ticket worker wall minutes p90')" \
  || fail "per-ticket wall p90 wrong: $(row 'per-ticket worker wall minutes')"
jq -e '.ticket_bounds.token == {healthy:300000, unhealthy:400000, samples:2, provisional:true}
  and .ticket_bounds.wall.samples == 2
  and ([.ticket_spend[] | select(.ticket == 4355)][0]
       | .tokens == 330000 and .fresh == 230000 and .wall_min == 30 and .closed_at == "2026-10-20T11:50:00Z" and .open == false)
  and ([.ticket_spend[] | select(.ticket == 4366)][0] | .tokens == 155000)' \
  "$a/node-health.json" >/dev/null || fail "ticket spend or bounds missing from the scorecard: $(jq -c '.ticket_bounds, .ticket_spend' "$a/node-health.json")"
jq -e '.metrics[] | select(.id == "workorders.ticket_tokens_p90")
  | .value == 330000 and .healthy == 300000 and .unhealthy == 400000 and .status == "WARN" and .source != ""' \
  "$a/node-health.json" >/dev/null || fail "ticket tokens metric missing its value, derived bounds or source"
# unit_spend 经共享成本行走 --json 流：旧实现只读页脚时这张票是 0
jq -e '[.work_orders[] | select(.id == "issue-4355")][0].tokens == 330000' "$a/node-health.json" >/dev/null \
  || fail "a --json codex worker's tokens did not reach the work-order spend: $(jq -c '.work_orders' "$a/node-health.json")"

# ---------- gen_dashboard：同一份账进 cost_ledger（单元 / ticket / 阶段 / 后端 / 24h / eval） ----------
export CODEX_SESSIONS_DIR="$fixture/sessions" AGENT_HOME="$agent_home"
export MAC_AUTOPILOT_DASHBOARD_OUTPUT="$a/dashboard.data.js"
PATH="$fixture/bin:$PATH" python3 "$script_dir/gen_dashboard.py" || fail "gen_dashboard failed on the fixture"
dashboard_data="$(sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT")"
jq -e '
  (.cost_ledger.last_24h.runs == 2 and .cost_ledger.last_24h.raw == 485000)
  and ([.cost_ledger.by_unit[] | select(.unit == "issue-4355")][0]
       | .in == 300000 and .out == 30000 and .uncached == 200000 and .wall_min == 30 and .ticket == 4355)
  and ([.cost_ledger.by_unit[] | select(.unit == "pr-77")][0] | .raw == 155000 and .runs == 1)
  and ([.cost_ledger.by_ticket[] | select(.ticket == 4355)][0] | .tokens == 330000)
  and ([.cost_ledger.by_ticket[] | select(.ticket == 4366)][0] | .raw == 155000 and .uncached == 110000)
  and .cost_ledger.by_phase.implement.raw == 330000
  and .cost_ledger.by_phase.review.raw == 155000
  and .cost_ledger.by_backend.codex.raw == 330000
  and .cost_ledger.by_backend.zcode.raw == 155000
  and .cost_ledger.eval.last_24h.tokens == 1000000
  and ([.cost_ledger.eval.labels[] | select(.label == "gold-check")][0].model_wall_seconds == 150.2)
  and ([.cost_ledger.by_unit[] | select(.unit == "101")][0].tokens == 200000)' \
  <<<"$dashboard_data" >/dev/null \
  || fail "cost_ledger missing or wrong: $(jq -c '.cost_ledger | {last_24h, by_unit, by_backend}' <<<"$dashboard_data")"

echo 'worker_cost.test.sh: PASS'
