#!/usr/bin/env bash
# 终态单元退休（retire_terminal_units / units-archive.json）回归，种子数据复现，不碰任何真实台账：
# 1. 终态单元移入归档、活跃单元留在热台账；退休条件（eval 在途、main-red 未回填、未收割 worker）逐一放行；
# 2. 幂等：重跑不动账；归档先行崩溃窗口（两处同 id）重跑收敛且不丢行；
# 3. write_state 守卫：未归档的 id 仍不可从 units.json 删除（防手滑/坏写入丢单元），已归档的 id 才可以；
# 4. 历史读者合并视图 units_history_doc 与 restore_archived_unit 的复活语义。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/unit-retire"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo/engine/prompts" "$fixture/bin"
export ZF_ROADMAP_TREE_CACHE_FILE="$fixture/roadmap-tree.json"
jq -cn '{roots:[]}' > "$ZF_ROADMAP_TREE_CACHE_FILE"
jq '.auto_merge = false | .advisor = false | .precheck = false | .supervisor_arbiter.enabled = true' "$script_dir/config.template.json" > "$sup/autopi/config.json"
echo '{"units":[]}' > "$sup/autopi/units.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export ZF_CONFIG_ROOT="$fixture/repo/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$ZF_CONFIG_ROOT/prompts/supervisor-arbiter.md"
cp "$script_dir/../prompts/review-contract.md" "$ZF_CONFIG_ROOT/prompts/review-contract.md"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$fixture/repo/engine/prompts/supervisor-arbiter.md"
export CODEX_SESSIONS_DIR="$fixture/sessions"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "unit-retire.test.sh: $*" >&2; exit 1; }
seed_units() { printf '%s\n' "$1" > "$UNITS"; }
count_stage() { jqf --argjson st "$2" '[.units[] | select(.stage as $s | $st | index($s) != null)] | length' "$1"; }

# ---- 1. 终态退休：移档、留活；三类在途依赖逐一挡住并在解除后放行 ----
seed_units '{"units":[
 {"id":"m1","issue":101,"stage":"merged","pr":11,"history":[]},
 {"id":"c1","issue":102,"stage":"closed","history":[]},
 {"id":"l1","issue":103,"stage":"landed","land_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","history":[]},
 {"id":"d1","issue":104,"stage":"done","history":[]},
 {"id":"w1","issue":105,"stage":"wontfix","history":[]},
 {"id":"p1","issue":106,"stage":"parked","history":[]},
 {"id":"b1","issue":107,"stage":"blocked-external","blocked_on":108,"history":[]},
 {"id":"s1","issue":109,"stage":"supervisor-review","history":[]},
 {"id":"r1","issue":110,"stage":"ready-to-merge","pr":12,"history":[]},
 {"id":"e1","issue":111,"stage":"merged","eval_gate":{"status":"pending"},"history":[]},
 {"id":"mr1","issue":112,"stage":"closed","main_red":true,"ci_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","history":[]},
 {"id":"w2","issue":113,"stage":"merged","history":[]}]}'
printf '%s\n' '{"workers":[{"pid":424242,"unit":"w2","type":"eval","log":"x","report":"y","started":"2026-11-04T00:00:00Z","harvested":false}]}' > "$WORKERS"
retire_terminal_units
[[ "$(jqf '.units | length' "$UNITS")" == 7 ]] || fail "the four non-terminal plus three in-flight-blocked units stay; got $(jqf '[.units[].id]' "$UNITS")"
[[ "$(jqf -r '[.units[].id] | sort | join(",")' "$UNITS")" == "b1,e1,mr1,p1,r1,s1,w2" ]] \
  || fail "staying ids must be exactly the non-terminal and in-flight-blocked ones; got $(jqf -c '[.units[].id] | sort' "$UNITS")"
[[ "$(jqf '.units | length' "$UNITS_ARCHIVE")" == 5 ]] || fail "m1/c1/l1/d1/w1 retire on the first pass"
for id in p1 b1 s1 r1; do
  jqf -e --arg id "$id" 'any(.units[]; .id == $id)' "$UNITS" >/dev/null || fail "non-terminal unit $id must stay in the hot ledger"
done
jqf -e --arg id e1 'any(.units[]; .id == $id)' "$UNITS" >/dev/null || fail "terminal unit with a pending eval must stay until the eval finishes"
jqf -e --arg id mr1 'any(.units[]; .id == $id)' "$UNITS" >/dev/null || fail "main-red closed unit without resolved_main_sha/at must stay for the supersede backfill"
jqf -e --arg id w2 'any(.units[]; .id == $id)' "$UNITS" >/dev/null || fail "unit with an unharvested worker must stay until the worker harvests"

# 在途依赖解除：eval 完成、main-red 回填、worker 收割 → 下一次退休放行
set_unit e1 '.eval_gate.status="passed"'
set_unit mr1 '.resolved_main_sha="cccccccccccccccccccccccccccccccccccccccc" | .resolved_main_at="2026-11-04T00:00:00Z"'
jqf '(.workers[] | select(.unit == "w2")) |= (.harvested = true)' "$WORKERS" | write_state "$WORKERS"
retire_terminal_units
[[ "$(jqf '.units | length' "$UNITS")" == 4 ]] || fail "after the in-flight dependencies clear only the non-terminal units stay; got $(jqf '[.units[].id]' "$UNITS")"
jqf -e --argjson t "$UNIT_RETIRE_STAGES" 'all(.units[]; .stage as $s | $t | index($s) == null)' "$UNITS" >/dev/null \
  || fail "no terminal unit may remain in the hot ledger once nothing in-flight blocks it"
[[ "$(jqf '.units | length' "$UNITS_ARCHIVE")" == 8 ]] || fail "archive must hold every retired unit exactly once"

# ---- 2. 幂等与崩溃窗口：两处同 id 重跑收敛，归档不重复、热台账为准 ----
retire_terminal_units
[[ "$(jqf '.units | length' "$UNITS_ARCHIVE")" == 8 ]] || fail "second retirement pass must be a no-op on the archive"
# 模拟「归档已写、热台账没删」的崩溃窗口：把一个已归档单元塞回热台账（内容更旧）
jqf '.units += [{id:"m1",issue:101,stage:"merged",pr:11,history:[]}]' "$UNITS" | write_state "$UNITS"
retire_terminal_units
[[ "$(jqf '[.units[] | select(.id == "m1")] | length' "$UNITS_ARCHIVE")" == 1 ]] \
  || fail "a crash-window duplicate must collapse to one archive row"
[[ "$(jqf '.units | length' "$UNITS")" == 4 ]] || fail "ledger must return to its live-only shape"

# ---- 3. write_state 守卫：未归档的 id 不可删；已归档的 id 才可以 ----
if units_update '.units |= map(select(.id != "b1"))' 2>/dev/null; then
  fail "write_state must refuse deleting a unit id that is not in the archive"
fi
jqf -e --arg id b1 'any(.units[]; .id == $id)' "$UNITS" >/dev/null || fail "refused delete must leave the ledger untouched"
seed_units '{"units":[{"id":"gone","issue":201,"stage":"implement-pending","history":[]},{"id":"stay","issue":202,"stage":"review","history":[]}]}'
printf '%s\n' '{"units":[{"id":"gone","issue":201,"stage":"merged","history":[]}]}' > "$UNITS_ARCHIVE"
units_update '.units |= map(select(.id != "gone"))' || fail "deleting an archived id is the retirement path and must pass the guard"
jqf -e --arg id stay 'any(.units[]; .id == $id)' "$UNITS" >/dev/null || fail "the surviving unit must stay"

# ---- 4. 历史读者视图与复活 ----
seed_units '{"units":[{"id":"live1","issue":301,"stage":"review","history":[]}]}'
printf '%s\n' '{"units":[{"id":"arch1","issue":302,"stage":"merged","pr":33,"history":[{"stage":"merged","result":"x","at":"2026-11-01T00:00:00Z"}]}]}' > "$UNITS_ARCHIVE"
jqf -e --argjson n 302 'any(.units[]; .issue == $n)' <(units_history_doc) >/dev/null \
  || fail "units_history_doc must surface archived units for issue/PR dedupe"
jqf -e --argjson n 301 'any(.units[]; .issue == $n)' <(units_history_doc) >/dev/null \
  || fail "units_history_doc must still surface live units"
# 同 id 两处（崩溃窗口）：合并视图给一行、且以热台账较新内容为准
jqf '.units += [{id:"arch1","issue":302,"stage":"merged","pr":33,"history":[]}]' "$UNITS" | write_state "$UNITS"
[[ "$(jqf '[.units[] | select(.id == "arch1")] | length' <(units_history_doc))" == 1 ]] \
  || fail "history doc keeps one row per id across the crash window"
jqf -e --arg id arch1 'any(.units[]; select(.id == $id) | (.history | length) == 0)' <(units_history_doc) >/dev/null \
  || fail "history doc must prefer the fresher live row"
restore_archived_unit arch1 || fail "restore_archived_unit must be a no-op success when the unit is live"
seed_units '{"units":[{"id":"live1","issue":301,"stage":"review","history":[]}]}'
restore_archived_unit arch1 || fail "restore must bring an archived unit back into the live ledger"
jqf -e --arg id arch1 'any(.units[]; .id == $id)' "$UNITS" >/dev/null || fail "restored unit must be in the hot ledger"

# ---- 5. python 侧共享加载器：合并 + live 优先 + 缺归档容忍 ----
seed_units '{"units":[{"id":"live1","issue":301,"stage":"review","history":[]}]}'
printf '%s\n' '{"units":[{"id":"arch1","issue":302,"stage":"merged","history":[]}]}' > "$UNITS_ARCHIVE"
python3 - "$A" "$script_dir" <<'PY' || fail "python loader must merge live+archive with live precedence"
import sys
sys.path.insert(0, sys.argv[2])
import ledger_history
units = ledger_history.load_units(sys.argv[1])
assert sorted(u["id"] for u in units) == ["arch1", "live1"], units
units = ledger_history.load_units("/nonexistent-runtime")
assert units == [], units
print("ok")
PY

# ---- 6. intake WIP 谓词与交接上限（#371/#372）：退休终态单元不改任何计数、也不改任何非终态阶段计数 ----
seed_units '{"units":[
 {"id":"i1","issue":401,"stage":"implement-pending","history":[]},
 {"id":"i2","issue":402,"stage":"repair-pending","history":[]},
 {"id":"i3","issue":403,"stage":"review","history":[]},
 {"id":"i4","issue":404,"stage":"rereview-pending","supervisor_owned":true,"history":[]},
 {"id":"i5","issue":405,"stage":"implement-pending","footprint_wait_owner":"i1","history":[]},
 {"id":"q1","issue":406,"stage":"ready-to-merge","pr":41,"history":[]},
 {"id":"q2","issue":407,"stage":"landing","pr":42,"history":[]},
 {"id":"p2","issue":408,"stage":"parked","history":[]},
 {"id":"t1","issue":409,"stage":"merged","history":[]},
 {"id":"t2","issue":410,"stage":"closed","history":[]},
 {"id":"t3","issue":411,"stage":"landed","history":[]},
 {"id":"t4","issue":412,"stage":"done","history":[]}]}'
printf '%s\n' '{"workers":[]}' > "$WORKERS"
printf '%s\n' '{"units":[]}' > "$UNITS_ARCHIVE"
intake_counts() { # startable pending | eligible upstream | total upstream (ceiling input) | ready queue | live stage histogram minus terminal
  jqf -c "{
    pending: ([.units[] | select(.stage | test(\"-pending\$\")) $(intake_eligible_filter)] | length),
    upstream: ([.units[] | select(.stage | test(\"^(implement|review|rereview|repair)(-pending)?\$\")) $(intake_eligible_filter)] | length),
    total_upstream: ([.units[] | select(.stage | test(\"^(implement|review|rereview|repair)(-pending)?\$\"))] | length),
    ready_q: ([.units[] | select(.stage==\"ready-to-merge\" or .stage==\"landing\")] | length),
    stages: ([.units[] | select(.stage as \$s | $UNIT_RETIRE_STAGES | index(\$s) | not) | .stage] | group_by(.) | map({(.[0]): length}) | add)
  }" "$UNITS"
}
before="$(intake_counts)"
retire_terminal_units
[[ "$(jqf '.units | length' "$UNITS_ARCHIVE")" == 4 ]] || fail "the four terminal units retire"
[[ "$(intake_counts)" == "$before" ]] || fail "retirement changed an intake count: before=$before after=$(intake_counts)"
[[ "$(jqf -c '.pending' <<<"$before")" == 2 ]] || fail "fixture sanity: footprint waiters and supervisor-owned units do not count as startable pending; got $before"

echo "unit-retire.test.sh: all assertions passed"
