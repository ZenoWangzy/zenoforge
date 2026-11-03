#!/usr/bin/env bash
# 旧单元形状回归（11-03 pr-3575 一类，种子数据复现，不碰任何真实台账）：
# 1. 字符串 .cto_rulings 撞上 RULE 的数组追加不再丢整笔更新，旧裁决保留为首个元素；
# 2. set_unit 失败的终局裁决记 NOT applied、裁决文本留在报告文件里、不再照旧记成功；
# 3. 字符串 .ready_since 不再破坏排序读取（旧单元先于更新的数字单元）。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/legacy-unit-shapes"
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
decision_eval_stages() { printf '\n'; }

fail() { echo "legacy-unit-shapes.test.sh: $*" >&2; exit 1; }
seed_units() { printf '%s\n' "$1" > "$UNITS"; }

# ---- 1. 字符串 .cto_rulings 走 RULE：追加成功，旧裁决成为数组首个元素 ----
seed_units '{"units":[{"id":"pr-3575-seed","issue":3575,"stage":"supervisor-review",
  "supervisor_cap_return_stage":"repair-pending","cto_rulings":"CTO 2026-10-21: old string ruling","history":[]}]}'
rep1="$sup/supervise-pr-3575-seed-cap.md"
printf 'REASON: legacy string rulings must append as an array\nEVIDENCE: seeded legacy unit from before the accumulating-array change\nVERDICT: RULE\n' > "$rep1"
# 调度器本体只 set -u：本套件 set -e 会在 set_unit 失败处提前退出，|| true 让断言在两种分支上都跑完。
supervisor_apply_cap_verdict pr-3575-seed "$rep1" RULE || true
jq -e --arg id pr-3575-seed '[.units[] | select(.id==$id)][0]
  | (.cto_rulings | type)=="array" and (.cto_rulings | length)==2
  and .cto_rulings[0]=="CTO 2026-10-21: old string ruling"
  and (.cto_rulings[1] | startswith("Supervisor cap ruling:"))
  and .stage=="repair-pending"
  and any(.history[]; .stage=="supervisor-cap-rule")' "$UNITS" >/dev/null \
  || fail "a RULE on a string cto_rulings unit must land as a 2-element array with history"
# 同一旧形状的读取端：字符串裁决必须进评审提示，而不是让 jqf 迭代失败后被静默丢掉
[[ "$(supervisor_rule '{"id":"x","note":"waiting","cto_rulings":"CTO 2026-10-21: old string ruling"}')" == *'old string ruling'* ]] \
  || fail "supervisor_rule must surface a legacy string cto_rulings entry"

# ---- 2. set_unit 失败的 RULE：记 NOT applied，裁决文本进报告文件，不记成功 ----
: > "$LOG" # 只看本段写下的日志，第 1 段的成功行不参与断言
seed_units '{"units":[{"id":"pr-3576-seed","stage":"supervisor-review",
  "supervisor_cap_return_stage":"repair-pending","supervise_report":"supervise-pr-3576-seed-cap.md","history":[]}]}'
rep2="$sup/supervise-pr-3576-seed-cap.md"
printf 'REASON: forced set_unit failure must not be logged as applied\nEVIDENCE: seeded forced write failure\nVERDICT: RULE\n' > "$rep2"
real_set_unit="$(declare -f set_unit)"
set_unit() { say "set_unit forced failure for legacy-unit-shapes test"; return 1; }
supervisor_apply_cap_verdict pr-3576-seed "$rep2" RULE || true
eval "$real_set_unit"
grep -Fq 'cap triage unit=pr-3576-seed: RULE NOT applied (set_unit failed)' "$LOG" \
  || fail "a failed RULE set_unit must log NOT applied"
if grep -Fq 'RULE -> repair-pending' "$LOG"; then
  fail "a failed RULE set_unit must not be logged as applied"
fi
grep -Fq 'Supervisor cap ruling: forced set_unit failure must not be logged as applied' "$rep2" \
  || fail "a failed RULE set_unit must keep the ruling text in the unit report file"

# ---- 3. 字符串 .ready_since 不破坏 fast_land_candidates 的排序读取 ----
seed_units '{"units":[
  {"id":"legacy-ready","stage":"ready-to-merge","lane":"direct-main","ready_since":"2026-10-21T16:33:38Z"},
  {"id":"modern-ready","stage":"ready-to-merge","lane":"direct-main","ready_since":1793000000}]}'
first="$(fast_land_candidates 10 | head -1 | jq -r .id)"
[[ "$first" == legacy-ready ]] \
  || fail "a string ready_since (older, 2026-10-21) must sort before a newer numeric one, got $first first"

echo 'legacy-unit-shapes.test.sh: all assertions passed'
