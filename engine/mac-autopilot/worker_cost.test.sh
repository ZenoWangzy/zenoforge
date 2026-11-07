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
jq -e '[.work_orders[] | select(.id == "issue-4355")][0].tokens == 23010000' "$a/node-health.json" >/dev/null \
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
