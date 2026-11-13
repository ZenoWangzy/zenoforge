#!/usr/bin/env bash
# the product autopilot scheduler（Mac/WSL 通用）：确定性 timer 驱动的 pipeline 全自动调度。
# 每 tick：回收完成 worker → 状态机推进 → 派发下一环节 → 门禁内自动 merge → 生成 dashboard 数据。
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/../merge-result-check.sh"
source "$HERE/../closing-keywords.sh"
source "$HERE/runtime-env.sh"
if [[ "${AUTOPI_TEST_LIBRARY_ONLY:-false}" != true && -z "${1:-}" && -f "$HERE/engine-canary.sh" ]]; then
  bash "$HERE/engine-canary.sh" tick-begin || :
  trap 'bash "$HERE/engine-canary.sh" tick-complete || :' EXIT
fi
source "$HERE/../verification-plan-runtime.sh"
source "$HERE/config-reconcile.sh"
source "$HERE/../matt-skills.sh"
source "$HERE/../incident-rule.sh"
ENGINE_ROOT="$(cd -- "$HERE/../.." && pwd -P)" # holds .agents/skills and engine/prompts, which read-only Claude reviewers get via --add-dir
# config.sh's pack_file, run in a subshell: config.sh also fills AGENT_HOME, ZF_ENGINE_DIR and ZF_REPO_DIR, and this script
# resolves the engine and the target repo its own way (${ZF_ENGINE_DIR:-$ROOT/engine}), so those must stay unset here.
ROOT="$MAC_AUTOPILOT_ROOT"
SUP="$MAC_AUTOPILOT_SUPERVISOR_DIR"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
SESSIONS_DIR="${CODEX_SESSIONS_DIR:-${CODEX_HOME:-${HOME:-}/.codex}/sessions}"
CODEX_REPAIR_RUNNER="${ZF_ENGINE_DIR:-$ROOT/engine}/codex-repair-run.sh"
[[ -r "$CODEX_REPAIR_RUNNER" ]] || CODEX_REPAIR_RUNNER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/codex-repair-run.sh"
SESSION_TZ="${SESSION_TZ:-America/Los_Angeles}"
TODAY="$(TZ="$SESSION_TZ" date +%Y-%m-%d)"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TAG="$(date -u +%Y%m%dT%H%M%SZ)"
NOW_EPOCH="$(date +%s)"
LOG="$A/scheduler.log"
PAUSE_FILE="${AUTOPILOT_PAUSE_FILE:-${AGENT_HOME:-${HOME:-}/.zenoforge}/PAUSE}"
# 每拍 gh 调用计数（#4725）：48h 审计里 scheduler.log 没有任何 gh 调用数，REST 配额被谁吃掉不可见。
# 函数在本进程（含子 shell）内拦截 gh；计数文件按进程命名，慢阶段让锁期间并行的 refill 不会互相清零。
GH_TICK_CALLS_FILE=""
TICK_INTAKE_READS_FILE=""
TICK_PHASE_DETAILS=""
TICK_PHASES=""
TICK_LOCK_WAIT=0
# 有界并行：#4725 把 gh 全改串行后慢拍从 350s 涨到 636s；后台 gh 最多 GH_PARALLEL 个同时在途，避开二级限流。
GH_PARALLEL="${GH_PARALLEL:-4}"
# 条件请求（GitHub REST best practices，#4725）：周期性 GET 带 If-None-Match，命中 304 不占主限流配额，
# 直接复用上一拍缓存的正文；200 才回正文并更新 ETag。-p 的分页端点首页未变即视为整表未变（列表按 id
# 倒序，成员变动必先体现在首页边界），后续页串行补齐，任一页失败整次判失败不落缓存。失败无输出返回 1，
# 调用方按「本拍不可用」处理，不给坏数据。只包 GET；key 是缓存文件名，调用方自管稳定且不含斜杠。
GH_ETAG_DIR="$A/.gh-etag"
# The scheduler is launched standalone by loop.sh; provide lib.sh's shared helper
# without making the scheduler depend on lib.sh being sourced into its process.
declare -F jq_arg_file >/dev/null 2>&1 || jq_arg_file() {
  local f
  f="$(mktemp)" || return 1
  printf '%s' "$1" > "$f"
  echo "$f"
}
declare -F gh_timeout >/dev/null 2>&1 || source "$HERE/../lib.d/transport.sh"
# Only a real pass satisfies a required name; skipped/neutral/absent rows do not.
# The required names are the always-concluding aggregates (#4484): a gate that legitimately
# does not run is an allowed skip inside the aggregate row, so this guard can no longer sit
# in a permanent "required checks skipped" wait for PRs whose heavy jobs did not start.
declare -F gh_timeout >/dev/null 2>&1 || source "$HERE/../lib.d/transport.sh"
source "$HERE/scheduler.d/core.sh"
ADVISOR_PROVIDER_SCRIPT="$(source "$HERE/../config.sh" && printf '%s' "$ZF_WEB_ADVISOR_PROVIDER_SCRIPT")"
if [[ -z "${MODEL_POLICY_DEFAULT:-}" ]]; then
  MODEL_POLICY_DEFAULT="$(sched_config_file model-policy.default.json 2>/dev/null)" || MODEL_POLICY_DEFAULT="$HERE/../model-policy.default.json"
fi
MODEL_POLICY_FILE="${MODEL_POLICY_FILE:-$AGENT_HOME/model-policy.json}"
CODEX_EXHAUSTED_MARKER_FILE="${CODEX_EXHAUSTED_MARKER_FILE:-$AGENT_HOME/codex-exhausted-until}"
CODEX_PROVIDER_PROBE_REQUIRED_FILE="${CODEX_PROVIDER_PROBE_REQUIRED_FILE:-$CODEX_EXHAUSTED_MARKER_FILE.probe-required}"
CODEX_PROBE_MARKER="${CODEX_PROBE_MARKER:-$AGENT_HOME/codex-probe-passed}"
ZCODE_EXHAUSTED_MARKER_FILE="${ZCODE_EXHAUSTED_MARKER_FILE:-$AGENT_HOME/zcode-exhausted-until}"
CLAUDE_EXHAUSTED_MARKER_FILE="${CLAUDE_EXHAUSTED_MARKER_FILE:-$AGENT_HOME/claude-exhausted-until}"
ZCODE_PROVIDER_CONFIG_FILE="${ZCODE_PROVIDER_CONFIG_FILE:-$HOME/.zcode/v2/provider_config.json}"
source "$HERE/../lib.d/codex-budget.sh"
source "$HERE/../lib.d/model-policy.sh"
source "$HERE/../lib.d/model-policy-fallback.sh"; model_policy_default_fallback "$HERE/../model-policy.default.json"
declare -F codex_probe_ok >/dev/null 2>&1 || codex_probe_ok() { [[ -f "$CODEX_PROBE_MARKER" ]]; }
if [[ -z "${REQUIRED_PR_CHECKS_FILE:-}" ]]; then
  REQUIRED_PR_CHECKS_FILE="$(ZF_REPO_DIR="${ZF_REPO_DIR:-$MAC_AUTOPILOT_ROOT}" \
    ZF_ENGINE_DIR="${ZF_ENGINE_DIR:-$ENGINE_ROOT}" sched_config_file mac-autopilot/required-pr-checks.json)" \
    || REQUIRED_PR_CHECKS_FILE="$HERE/required-pr-checks.json"
fi
source "$HERE/scheduler.d/reports.sh"
source "$HERE/review-contract.sh"
source "$HERE/scheduler.d/units.sh"
source "$HERE/scheduler.d/dead-park-salvage.sh"
source "$HERE/scheduler.d/worker-outcomes.sh"
source "$HERE/scheduler.d/usage-sessions.sh"
source "$HERE/scheduler.d/models.sh"
source "$HERE/scheduler.d/worker-command.sh"
source "$HERE/scheduler.d/worker-scope.sh"
source "$HERE/scheduler.d/clones.sh"
source "$HERE/scheduler.d/dispatch.sh"
source "$HERE/scheduler.d/lib-bridge.sh"
source "$HERE/scheduler.d/footprint.sh"
source "$HERE/scheduler.d/self-check.sh"
source "$HERE/scheduler.d/evals-arbiter.sh"
source "$HERE/scheduler.d/supervisor-arbiter.sh"
source "$HERE/scheduler.d/size-recuts.sh"
source "$HERE/scheduler.d/review-rules.sh"
source "$HERE/scheduler.d/land-lane.sh"
source "$HERE/scheduler.d/dependencies-fresh.sh"
source "$HERE/scheduler.d/dependencies.sh"
source "$HERE/scheduler.d/dependencies-history.sh"
source "$HERE/scheduler.d/size-admission.sh"
source "$HERE/scheduler.d/harvest-workers.sh"
source "$HERE/scheduler.d/stop-loss.sh"
source "$HERE/scheduler.d/dispatch-queue.sh"
source "$HERE/scheduler.d/ci-status.sh"
source "$HERE/scheduler.d/ci-admission.sh"
source "$HERE/scheduler.d/harvest-station.sh"
source "$HERE/scheduler.d/existing-walk-station.sh"
source "$HERE/scheduler.d/release-deps-station.sh"
source "$HERE/scheduler.d/merge-prep.sh"
source "$HERE/scheduler.d/merge-lane.sh"
source "$HERE/scheduler.d/conflict-resolve.sh"
source "$HERE/scheduler.d/engine-batch-land.sh"
source "$HERE/scheduler.d/merge-tree-sweep.sh"
source "$HERE/scheduler.d/cleanup.sh"
source "$HERE/scheduler.d/acceptance.sh"
source "$HERE/scheduler.d/intake-steps.sh"
source "$HERE/scheduler.d/intake-index.sh"
source "$HERE/scheduler.d/intake.sh"
source "$HERE/scheduler.d/intake-author.sh"
source "$HERE/scheduler.d/recut-reopen.sh"
source "$HERE/scheduler.d/park-label-sweep.sh"
source "$HERE/scheduler.d/orphan-prs.sh"
source "$HERE/scheduler.d/health-release.sh"
source "$HERE/scheduler.d/locks-views.sh"
mkdir -p "$A/alerts"

if [[ "${AUTOPI_TEST_LIBRARY_ONLY:-false}" != true && "${1:-}" != --views && "${1:-}" != --refill && "${1:-}" != --ci-admission && "${1:-}" != --merge && "${1:-}" != --harvest-station && "${1:-}" != --existing-walk && "${1:-}" != --release-deps && "${1:-}" != --rule && "${1:-}" != --size-waiver-check ]]; then
  if ! reconcile_event="$(reconcile_runtime_config "$(sched_config_file mac-autopilot/config.template.json)" "$A/config.json" "${ZF_ENGINE_DIR:-$ROOT/engine}/lib.sh")"; then
    say "config-reconcile failed; tick stopped before reading config"
    exit 1
  fi
  [[ -z "$reconcile_event" ]] || say "$reconcile_event"
fi
CFG="$(cat "$A/config.json")"
ISSUE_INTAKE_REMOTE_READ_CAP="$(jqf -r '.issue_intake.remote_reads_per_tick // 24' <<<"$CFG")"
[[ "$ISSUE_INTAKE_REMOTE_READ_CAP" =~ ^[0-9]+$ ]] || ISSUE_INTAKE_REMOTE_READ_CAP=24
warn_forbidden_model_config
INCIDENT_LABELS="$(incident_labels_from_config "$CFG")"
INCIDENT_RULE="$(incident_rule_text)"
UNITS="$A/units.json"; WORKERS="$A/workers.json"
# 终态单元的退休归档（retire_terminal_units）：只增不删；历史读者经 units_history_doc 合并读取。
UNITS_ARCHIVE="${UNITS_ARCHIVE:-$A/units-archive.json}"
[[ -f "$UNITS_ARCHIVE" ]] || printf '{"units":[]}\n' > "$UNITS_ARCHIVE"
[[ -f "$WORKERS" ]] || echo '{"workers":[]}' > "$WORKERS"
MAX="$(jqf -r .max_workers <<<"$CFG")"
DISPATCH_PRIORITY_ORDER="$(jqf -c '.dispatch_priority_order // ["hotfix", "opt", "normal"]' <<<"$CFG")"
DISPATCH_FIRST_ISSUES="$(jqf -c 'if (.dispatch_first_issues | type) == "array" then .dispatch_first_issues else [] end' <<<"$CFG")"
IMPLEMENT_CAP="$(jqf -r '.implement_cap // 99' <<<"$CFG")"
log_reliability_breach
BUDGET="$(jqf -r .daily_token_budget <<<"$CFG")"
[[ "$BUDGET" =~ ^[0-9]+$ ]] || BUDGET=0
FOCUS_MODE="$(jqf -r '.focus_mode // "all"' <<<"$CFG")"
# zf-ab 裁决（10-29）：append-registry 类热点文件（多数情况下只追加的注册表）对 implement 放行并行；
# 名单以配置为单一事实源（config.template.json 每拍 reconcile 进 runtime config）。
SHARED_APPEND="$(jqf -c '.footprint_mutex.shared_append // []' <<<"$CFG")"
# 默认关：早期 stale-base 路由只在 ticket 11 的回放确认零误判后由配置打开
STALE_BASE_ROUTING="$(jqf -r '.stale_base_routing // false' <<<"$CFG")"
BUDGET_METER="$(jqf -r '.budget_meter // "sessions_dir"' <<<"$CFG")"
# 用量表连续扫描失败达到此次数时写 BUDGET-ALERT（仍派发）；成功扫描清零。
BUDGET_METER_FAIL_THRESHOLD="$(jqf -r '.budget_meter_fail_threshold // 3' <<<"$CFG")"
[[ "$BUDGET_METER_FAIL_THRESHOLD" =~ ^[1-9][0-9]*$ ]] || BUDGET_METER_FAIL_THRESHOLD=3
WT_ROOT="$(jqf -r '.worktree_root // empty' <<<"$CFG")"
WT_ROOT="${WT_ROOT:-${AGENT_HOME:-${HOME:-/tmp}/.zenoforge}/autopilot-wt}"
LOOP_BREAKER_ROUNDS="$(jqf -r '.loop_breaker_rounds // 5' <<<"$CFG")"
# 终身返工上限：supervisor-requeue 会给 loop_rounds 重新记数，但不重置这个总数（pr-3863 被重排 4 次，20 轮修复、10.5M token）。
LOOP_TOTAL_ROUNDS="$(jqf -r '.loop_total_rounds // 8' <<<"$CFG")"
# 尺寸准入（10-22 R2）：超过 N 改动行的实现不开评审，连同数字转 supervisor 重切（大 PR 占 36.3%，
# Anthropic 观察到 >1000 行的 PR 多数有 findings）。文档、生成物、锁文件与测试快照不计入。
SIZE_ADMISSION_LINES="$(jqf -r '.size_admission_lines // 800' <<<"$CFG")"
# 止损预算（#4363）：每张 ticket 自最近一次 supervisor 裁决起最多 N 轮（implement 加 repair，含自修复重派，
# 每次 write-start 记一轮）或 4h 墙钟；第 4 轮不再派发——原票自动 on-hold 附原因，单元转 supervisor（#4369 terra 裁决）。
TICKET_ROUND_BUDGET="$(jqf -r '.ticket_round_budget // 3' <<<"$CFG")"
# 230: above every landed implement session in the 7 days to 2026-10-31 (max 218); discarded ones ran 281-336.
IMPLEMENT_COMMAND_CAP="$(jqf -r '.implement_command_cap // 230' <<<"$CFG")"
[[ "$IMPLEMENT_COMMAND_CAP" =~ ^[0-9]+$ ]] || IMPLEMENT_COMMAND_CAP=230
TICKET_WALL_BUDGET_SECONDS="$(( $(jqf -r '.ticket_wall_budget_minutes // 240' <<<"$CFG") * 60 ))"
# Lifetime fresh-token lines per unit (uncached input + output, as workorder_cost.unit_spend counts them): the soft line parks the unit
# for one arbiter decision that may refill it once, the hard line parks it for good (three units passed 1.2M: 2.41M, 1.44M, 1.23M).
TOKEN_PARK_SOFT_TOKENS="$(jqf -r '.token_park_soft_tokens // 1200000' <<<"$CFG")"
[[ "$TOKEN_PARK_SOFT_TOKENS" =~ ^[0-9]+$ ]] || TOKEN_PARK_SOFT_TOKENS=1200000
TOKEN_PARK_HARD_TOKENS="$(jqf -r '.token_park_hard_tokens // 2400000' <<<"$CFG")"
[[ "$TOKEN_PARK_HARD_TOKENS" =~ ^[0-9]+$ ]] || TOKEN_PARK_HARD_TOKENS=2400000
# 工单 token/分钟/轮数是仪表盘指标（workorder_cost.py，node_health 用），不是停单开关（#4486：
# #4053 把 raw-token bug 线当硬停，96% 是缓存读取、按生命周期累计、事后才停，36 次误停正常单）。
MAX_NO_OUTPUT="$(jqf -r '.waste.max_no_output // 2' <<<"$CFG")"
# Per-command output cap in KB for every worker backend (lib.d/worker-output-cap.sh); bin/luna and bin/zc read the same variable.
WORKER_OUTPUT_CAP_KB="$(jqf -r '.waste.tool_output_cap_kb // 64' <<<"$CFG")"
export WORKER_OUTPUT_CAP_KB
# f12（#4369）：supervisor-review 由 terra 裁决 worker 接管；eval 门槛（恒选 requeue 参照 + 零危险 approve）达标前默认关。
SUPERVISOR_ARBITER="$(jqf -r 'if .supervisor_arbiter.enabled == true then "true" else "false" end' <<<"$CFG")"
SUPERVISOR_ARBITER_PROFILE="$(jqf -r '.supervisor_arbiter.profile // "terra"' <<<"$CFG")"
SUPERVISOR_NEEDS_INFO_PER_TICK="$(jqf -r '.supervisor_arbiter.needs_info_per_tick // 3' <<<"$CFG")"
SUPERVISOR_CAP_TRIAGE="$(jqf -r 'if .supervisor_arbiter.cap_triage == false then "false" else "true" end' <<<"$CFG")"
SUPERVISOR_CAP_TRIAGE_PER_TICK="$(jqf -r '.supervisor_arbiter.cap_triage_per_tick // 3' <<<"$CFG")"
[[ "$SUPERVISOR_CAP_TRIAGE_PER_TICK" =~ ^[0-9]+$ ]] || SUPERVISOR_CAP_TRIAGE_PER_TICK=3
# 一次一个时 42 个 supervisor-review 要排 3.5 h（10-28 解除 PAUSE 后实测）；裁决只读、轻量，按名额并发。
SUPERVISOR_ARBITER_MAX="$(jqf -r '.supervisor_arbiter.max_in_flight // 4' <<<"$CFG")"
SUPERVISOR_ARBITER_DAILY_MAX="$(jqf -r '.supervisor_arbiter.daily_max_per_unit // 6' <<<"$CFG")"
[[ "$SUPERVISOR_ARBITER_DAILY_MAX" =~ ^[0-9]+$ ]] || SUPERVISOR_ARBITER_DAILY_MAX=6
# 终身仲裁上限：按整份历史数 supervisor-arbiter 事件（supervisor-arbiter-round 轮标记会清零轮计数，挡不住循环）。
# 触顶由调度器当拍给默认决定（supervisor_cap_default），不再派模型，也不问人。
SUPERVISOR_ARBITER_UNIT_CAP="$(jqf -r '.supervisor_arbiter.unit_cap // 4' <<<"$CFG")"
[[ "$SUPERVISOR_ARBITER_UNIT_CAP" =~ ^[0-9]+$ ]] || SUPERVISOR_ARBITER_UNIT_CAP=4
CODEX_CREDITS_ROLES="$(jqf -r '(.models.codex_credits.roles // []) | join(" ")' <<<"$CFG")"
CODEX_CREDITS_CAP="$(jqf -r '.models.codex_credits.cap // empty' <<<"$CFG")"
CODEX_CREDITS_START_BALANCE="$(jqf -r '.models.codex_credits.start_balance // empty' <<<"$CFG")"
FOCUS_SKIPPED=()
MAIN_HEAD=""
if [[ "$FOCUS_MODE" != "all" && "$FOCUS_MODE" != "release" ]]; then
  echo "unsupported focus_mode=$FOCUS_MODE (expected all or release)" >&2
  exit 2
fi
SHA_RE='^[0-9a-f]{40}$'
# worker 的 bash -lc 会 source the operator's development.env，里面的 GH_TOKEN 已失效（2026-10-20 实测 401，
# 13 次评审因读不到 issue 给了 BLOCK）。~/.profile 与 ~/.bashrc 在看到这个标记时 unset GH_TOKEN，gh 走钥匙串登录。
export ZF_AUTOPILOT_WORKER=1
SESSION_RE='^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$'

# codex 正常结束时在最后一个 "tokens used" 与数字之后打印最终回复。

LIVE_WORKER_CACHE_UNTIL=0
LIVE_WORKER_CACHE_TOTAL=0
declare -A LIVE_WORKER_CACHE_TYPES=()

USAGE_READER="$HERE/usage_reader.py"  # 当前 tick 固定的代码版本
BUDGET_EVENTS="$A/budget-events.json"  # 原生 codex turn 事件（provider/session/turn 幂等键）；codex-day 按同一路径推导

if [[ "$BUDGET_METER" != "sessions_dir" ]]; then
  echo "unsupported budget_meter=$BUDGET_METER (only sessions_dir is supported)" >&2
  exit 2
fi
if [[ "${1:-}" == "--update-budget-only" ]]; then
  update_budget
  exit $?
fi


# ---------- 模型选择与提供方冷却 ----------
# 会话/用量上限、模型满载是提供方的暂时状态，不是 worker 缺陷：该提供方冷却 30 分钟，
# 期间该角色改用 models.<role>_fallback（若配置且其提供方未冷却），都不可用则不派发。
COOLDOWN="$A/cooldown.json"
CODEX_EXHAUSTED_MARKER_FILE="${CODEX_EXHAUSTED_MARKER_FILE:-$AGENT_HOME/codex-exhausted-until}"
ZCODE_EXHAUSTED_MARKER_FILE="${ZCODE_EXHAUSTED_MARKER_FILE:-$AGENT_HOME/zcode-exhausted-until}"
CLAUDE_EXHAUSTED_MARKER_FILE="${CLAUDE_EXHAUSTED_MARKER_FILE:-$AGENT_HOME/claude-exhausted-until}"
WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE="${WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE:-$AGENT_HOME/web-advisor-provider-exhausted-until}"
source "$HERE/../lib.d/codex-budget.sh"
SCHED_MODEL_POLICY_FILE="$(sched_config_file model-policy.default.json 2>/dev/null || true)"
[[ -r "$SCHED_MODEL_POLICY_FILE" ]] || SCHED_MODEL_POLICY_FILE="$ENGINE_ROOT/engine/model-policy.default.json"
SCHED_MODEL_POLICY_JSON="$(cat "$SCHED_MODEL_POLICY_FILE" 2>/dev/null || echo '{}')"
# 只认提供方错误行的措辞，且只看日志尾部：worker 日志里满是代码/文档/测试输出（曾因技能说明里的
# "an overloaded word" 误判整个 codex 冷却 30 分钟）。
PROVIDER_LIMIT_RE='hit your (session|usage) limit|^ERROR: .*(at capacity|rate limit|usage limit|overloaded|quota)|overloaded_error|rate_limit_error|429 Too Many Requests'
# 无产出死亡的死因辨认（11-03：两个评审单元 3 次死亡只留下 "died without a report"，死因——claude CLI
# 的 Bun 运行时 SIGABRT、主机线程上限 EAGAIN——全在 worker 日志里没人读，supervisor 拿到的是零信息理由）。
# 同样只认措辞、只扫日志尾部：start-limit 是 worker 根本没跑起来（主机瞬时容量，不是单元失败）；
# oom 是内存打尽/整组被杀（单元太胖，按尺寸止损重切而不是继续压死 worker）。
WORKER_START_LIMIT_RE='(thread: EAGAIN|process or thread limit|pids limit)'
WORKER_OOM_RE='(out of memory|cannot allocate memory|oom-kill|memory cgroup)'
# 末条错误行匹配：退出码/信号之外再留一行人类可读死因（截 200 字符入库）。只认错误措辞，
# 不收 Aborted/Killed 这类 bash 作业消息——信号已有 signal= 字段，别让作业消息盖掉真正的错误行。
WORKER_DEATH_ERROR_RE='error:|panic\(|has crashed|fatal|EAGAIN|out of memory|cannot allocate'

worker_death_of() { # log-path → compact JSON {rc,signal,error,at}（fields may be absent）
  local lg="$1" rc="" sig="" err="" exit_file="${1}.pipeline-exit"
  rc="$(jq -r '.rc // empty' "$exit_file" 2>/dev/null || true)"
  if ! [[ "$rc" =~ ^[0-9]+$ ]]; then
    # Read older logs that carried the footer in the merged provider stream.
    rc="$(jq -Rsc '[split("\n")[] | fromjson? | select(.type=="pipeline.exit") | .rc] | last // empty' "$lg" 2>/dev/null || true)"
  fi
  if ! [[ "$rc" =~ ^[0-9]+$ ]]; then
    case "$(tail -n 80 "$lg" 2>/dev/null | grep -aoE 'Aborted|Segmentation fault|Killed|Terminated' | tail -1 || true)" in
      Aborted) rc=134 ;;
      'Segmentation fault') rc=139 ;;
      Killed) rc=137 ;;
      Terminated) rc=143 ;;
    esac
  fi
  if [[ "$rc" =~ ^[0-9]+$ ]] && (( rc > 128 )); then sig="$(kill -l "$((rc - 128))" 2>/dev/null || true)"; fi
  err="$(tail -n 80 "$lg" 2>/dev/null | grep -aiE "$WORKER_DEATH_ERROR_RE" | tail -1 | tr -d '\r' | cut -c1-200 || true)"
  jq -cn --argjson rc "${rc:-null}" --arg signal "${sig:-}" --arg error "${err:-}" --arg at "$STAMP" \
    '(if $rc == null then {} else {rc:$rc} end) + (if $signal == "" then {} else {signal:$signal} end) + (if $error == "" then {} else {error:$error} end) + {at:$at}'
}

worker_death_summary() { # death-json → compact text for history and supervisor reason
  local d="$1" rc sig err out
  rc="$(jqf -r '.rc // "unknown"' <<<"$d")"; sig="$(jqf -r '.signal // empty' <<<"$d")"; err="$(jqf -r '.error // empty' <<<"$d")"
  out="rc=$rc"
  if [[ -n "$sig" ]]; then out+=" signal=$sig"; fi
  if [[ -n "$err" ]]; then out+=" error: $err"; fi
  printf '%s' "$out"
}

handle_worker_death() { # worker-json unit type log-path → diagnose and route a no-report worker exit
  local w="$1" unit="$2" wtype="$3" lg="$4" death death_summary death_sig death_class death_tail worker_provider no_output
  death="$(worker_death_of "$lg")"
  death_summary="$(worker_death_summary "$death")"
  death_sig="$(jqf -r '.signal // empty' <<<"$death")"
  death_tail="$(tail -n 80 "$lg" 2>/dev/null || true)"
  death_class=""
  if grep -aqE "$WORKER_START_LIMIT_RE" <<<"$death_tail"; then
    death_class=start-limit
  elif [[ "$death_sig" == KILL ]] || grep -aqiE "$WORKER_OOM_RE" <<<"$death_tail"; then
    death_class=oom-kill
  fi
  if [[ "$death_class" == start-limit ]]; then
    worker_provider="$(jqf -r '.provider // empty' <<<"$w")"
    [[ -n "$worker_provider" ]] || worker_provider="$(provider_of "$(jqf -r '.model // ""' <<<"$w")")"
    start_cooldown "$worker_provider" "worker start failed (host thread/process limit) unit=$unit $death_summary"
    set_unit "$unit" "$(hist worker-start-failed "$death_summary") | .worker_death=$death"
    say "worker start failed unit=$unit provider=$worker_provider $death_summary"
    if [[ "$(unit_retries "$unit" worker-start-failed)" =~ ^[0-9]+$ ]] \
      && (( $(unit_retries "$unit" worker-start-failed) >= MAX_NO_OUTPUT )); then
      to_supervisor "$unit" "$(unit_retries "$unit" worker-start-failed) workers in a row could not even start (host thread/process limit), last log $(basename "$lg"); $death_summary"
    fi
    return 0
  fi
  echo "[$STAMP] WASTE zero-output worker pid=$(jqf -r '.pid // 0' <<<"$w") unit=$unit log=$(basename "$lg") $death_summary" >> "$A/alerts/waste.md"
  say "WASTE zero-output pid=$(jqf -r '.pid // 0' <<<"$w") unit=$unit $death_summary"
  set_unit "$unit" "$(hist worker-no-output "$wtype $death_summary") | .worker_death=$death"
  no_output="$(jqf -r --arg id "$unit" '[.units[] | select(.id==$id) | (.history // []) | map(select(.stage=="worker-no-output")) | length][0] // 0' "$UNITS")"
  if [[ "$(unit_field "$unit" '.self_fix_active // false')" != true && "$no_output" =~ ^[0-9]+$ ]] && (( no_output >= MAX_NO_OUTPUT )); then
    if [[ "$death_class" == oom-kill ]] && [[ "$(unit_field "$unit" '.issue // empty')" =~ ^[1-9][0-9]*$ ]] \
      && scheduler_recut_route "$(unit_field "$unit" '.issue')" "$(jq -cn --arg unit "$unit" --arg log "$(basename "$lg")" --argjson death "$death" '{kind:"worker-oom-death",unit:$unit,log:$log,death:$death}')" \
      && scheduler_issue_state "$(unit_field "$unit" '.issue')" | jq -e '.state == "needs-recut"' >/dev/null; then
      set_unit "$unit" "$(hist_blocked worker-oom-recut '' worker-oom "$death_summary") | .stage=\"blocked-external\" | .size_recut_pending=true"
      say "unit=$unit worker died $death_summary -> needs-recut"
    elif [[ "$wtype" =~ ^(review|rereview|repair|implement)$ && "$(unit_retries "$unit" fresh-session-retry)" == 0 ]]; then
      set_unit "$unit" "$(hist fresh-session-retry "$no_output deaths") | .session_ids={} | .sessions={} | .session_id=null | .stage=\"${wtype}-pending\""
      say "unit=$unit: $no_output workers died -> one fresh-session retry"
    else
      to_supervisor "$unit" "$no_output workers died without a report, fresh session too (last log $(basename "$lg")); $death_summary"
    fi
  fi
}

# Claude 评审 worker 的只读工具白名单（--permission-mode dontAsk：白名单外一律拒绝）。
CLAUDE_REVIEW_TOOLS="Read,Grep,Glob,Bash(cd:*),Bash(pwd),Bash(git fetch:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git rev-parse:*),Bash(git merge-base:*),Bash(git ls-remote:*),Bash(git status:*),Bash(git ls-files:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr checks:*),Bash(gh issue view:*),Bash(head:*),Bash(tail:*),Bash(wc:*),Bash(cat:*),Bash(ls:*),Bash(grep:*),Bash(rg:*),Bash(jq:*),Bash(sort:*),Bash(uniq:*),Bash(pnpm:*),Bash(npx vitest:*),Bash(node --test:*),Bash(bash *.test.sh)"

# codex 默认 shell 环境策略会剥掉 HTTP(S)_PROXY：本网络无代理连不上 GitHub，worker 的 fetch/push/gh 全部超时（L44）。
# inherit=all 保留代理变量；codex 内置的 *KEY*/*SECRET*/*TOKEN* 排除仍然生效。
CODEX_ENV_ARGS=(-c shell_environment_policy.inherit=all)

# ---------- worker 规则（提示模块）：按 提供方 × 车道 × worker 类型 追加到 worker 提示 ----------
# 接口 worker_rules <单元 JSON> <类型> <提供方> → 片段（可为空）。build_codex_command 在决定提供方的唯一一处调用它，
# 冷启动与复审带规则；修复续会话只发送新失败。
# 终端等待与大文件规则只给 codex worker（含 codex 评审回退）：claude 评审的工具白名单没有区间读取和终端等待，
# 写了只会招来被拒的调用。堵的失败：19,466 次 stdin 写入占原始 token 的 23.4%。
WORKER_POLL_RULE='
【终端等待】等后台命令（测试、构建、长脚本）时，write_stdin 的 yield_time_ms 取工具允许的最大值（不低于 30000），一次等到有输出或命令结束；预计 10 秒内结束的命令直接前台运行，不放后台。不要每隔几秒发一次空输入去轮询——每次轮询都会把整个上下文重发一遍。'
WORKER_LARGE_FILE_RULE='
【大文件】超过约 20 KB 的文件先用 rg -n 或 grep -n 定位，再用 sed -n "起,止p" 只读那一段区间，不整份读入；本会话已经读过的文件不要重读。'
# 文档读取范围规则只给产品车道的 implement/repair：pipeline-system、direct-main、main-red、hot-patch 单元被评审按
# 流水线契约文档判定（maintainer 裁决：阶段必须与流水线文档一致），评审也照旧读项目规则，它们都不豁免。
# 堵的失败：被跳过的文档里独有的规则，成了评审打回理由。豁免只覆盖项目指令的路由表，硬性边界原文随规则附上。
# 唯一维护的文档清单（用途|仓库相对路径）：重构搬文件只改这里；worker-rules-lanes.test.sh 逐条核对它们存在且被 git 跟踪。
# 提示按用途称呼文档，不写项目指令的标题（标题会被重构改名）。
# 清单现在经配置缝读取：目标配置根（或迁移期的 pack）的 mac-autopilot/worker-docs.json（skipped_docs、on_demand_docs、boundary_selectors）；
# 两处都没有时三个清单都为空，也不附读取范围规则。文件损坏时 jqf 把原因记进 scheduler.log。
WORKER_DOCS_FILE="$(sched_config_file mac-autopilot/worker-docs.json)" || WORKER_DOCS_FILE=/dev/null
mapfile -t WORKER_SKIPPED_DOCS < <(jqf -r '.skipped_docs[]?' "$WORKER_DOCS_FILE")
mapfile -t WORKER_ON_DEMAND_DOCS < <(jqf -r '.on_demand_docs[]?' "$WORKER_DOCS_FILE")
WORKER_READ_SCOPE_RULE="
【文档读取范围】调度器已在本提示里给出任务入口与交付命令，不要顺着项目路由表去读这些：$(worker_docs_text "${WORKER_SKIPPED_DOCS[@]}")。分支交付预检只运行上面交付文字里写的脚本，不读它的说明文档；带 --publish-topic 的预检自己负责推送，不要再单独接一条 git push（输出经管道时会掩盖预检失败）。项目指令里与本任务有关的硬性边界已原文附在下面，不必为它翻路由表。$(worker_docs_text "${WORKER_ON_DEMAND_DOCS[@]}")与目标包自己的 CLAUDE.md，只在改动触及该领域时读相关条目；教训只经教训目录定位，不全量读。"
# 项目指令里的硬性边界：每次装配提示时从 $ROOT/CLAUDE.md 取原文，这里不存副本。按义务关键词选行（同一行须全部出现），
# 不按标题（标题会被重构改名）：租户隔离/RBAC/可信确认/事务/幂等/审计/不伪造未知金额、不弹桌面窗口（xdg-open）、不做过度防御。
# worker-rules-lanes.test.sh 读真实的 CLAUDE.md，核对每组关键词恰好命中一行。
mapfile -t PRODUCT_BOUNDARY_SELECTORS < <(jqf -r '.boundary_selectors[]?' "$WORKER_DOCS_FILE") # 同一份 worker-docs.json
PRODUCT_LANE_SKILLS="$(sched_config_file mac-autopilot/product-lane-skills.txt)" || PRODUCT_LANE_SKILLS="$HERE/product-lane-skills.txt"

# #4190/#4192/#4193 wrote the same 8k-line hook concurrently. Triage already
# persists expected_paths; use its existing selector and overlap predicate, not
# a second package/path matcher. The common library stays in a subshell.
SCHEDULER_AGENT_LIB="${ZF_ENGINE_DIR:-$ROOT/engine}/lib.sh"
if [[ ! -r "$SCHEDULER_AGENT_LIB" ]]; then
  SCHEDULER_AGENT_LIB="${ZF_EXECUTION_MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}/lib.sh"
fi
# Definition-only lib modules that per-item subshells source instead of lib.sh (see lib-bridge.sh).
SCHEDULER_SCOPE_LIB_DIR="${SCHEDULER_AGENT_LIB%/lib.sh}/lib.d"
AGENT_HOME="${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
source "${SCHEDULER_AGENT_LIB%/lib.sh}/coord.sh"
declare -A TICK_FOOTPRINT_CACHE=() TICK_CHECK_SCOPE_SOURCE=() TICK_CHECK_SCOPE=() TICK_OLD_SCOPE=() TICK_HOTSPOT_COUNTS=()
TICK_ACTIVE_FOOTPRINTS='[]'
TICK_ACTIVE_FOOTPRINTS_VALID=false
TICK_FOOTPRINT_PREFLIGHT_STATUS=not-started
TICK_FOOTPRINT_CONFLICT_VALID=false
TICK_FOOTPRINT_COMPARED_ACTIVE=''
TICK_DISPATCH_LOCAL_REFILL=false
declare -A TICK_FOOTPRINT_PREFLIGHT_CONFLICT=()
# Footprint orders candidates and never refuses one: only the dispatch walk's first pass sets DEFER=true, and what
# it defers starts in the second pass if a slot is still free.
TICK_FOOTPRINT_DEFER=false
declare -A TICK_FOOTPRINT_DEFERRED=()
declare -A TICK_FOOTPRINT_DEFER_DETAIL=()
declare -a TICK_FOOTPRINT_PREFLIGHT_IDS=()

# #4621（维护者 2026-10-29 严格优先级 hotfix > opt > 普通 pipeline）：bin/luna、bin/zc 的门在 run 等待时写
# $LUNA_SLOTS/wait-<prio>-<pid>。产品 PR worker 让位给 hotfix/opt；direct-main opt worker 只让位给 hotfix；已运行的不动。
# 门口的 run 进门、文件消失后下一拍恢复派发；wrapper 已退出的旧文件不挡派发，顺手清掉。
LUNA_SLOTS="${LUNA_SLOTS:-${ZF_SCRATCH_ROOT:-${WORKER_SCRATCH_ROOT:-${HOME:-/tmp}/.zenoforge/scratch}}/tmp/luna-slots}"
ARBITER_RULE='
【仲裁评审】本单元已多轮返工未收敛（或修复者认为发现不成立、未推新提交）。请按正式评审契约完成一次完整复核，并将作者处置作为逐条复核的输入。'
HOTPATCH_REVIEW_RULE='
【生产热修回迁】本 PR 的补丁已在生产运行，`cihost release-drift-carried.tsv` 提供对应生产状态证据。请将它作为固定点之外的背景材料；正式契约仍决定 finding attribution 与 verdict。（CTO 裁决 2026-10-20）'
# supervisor 对单元的裁决（.note 以 CTO 开头）要进 worker 提示：只写在台账里时评审照样按旧理由 BLOCK，
# 单元又回到 supervisor（2026-10-20 issue-2536 裁决"epic 不是前置"后评审再次 BLOCKED-ON #2535）。
# 裁决累积在 .cto_rulings：.note 会被后来的备注覆盖，旧裁决随之丢失（2026-10-21 issue-2536 改派定点修复时
# 覆盖了"#2535 是 epic"，评审第三次 BLOCKED-ON #2535）。

# 非产品快车道（2026-10-19 CTO 裁决）：PR 改动全是非产品路径 → lane=direct-main，优先派发，
# 批准后由 land worker 压成 [skip ci] 提交经 land-direct-main.sh 直落 main（不走 PR CI 等待与合并车道）。
POLICY_SCRIPT="${AUTOPILOT_POLICY_SCRIPT:-$ROOT/scripts/branch-delivery-policy.mjs}"
declare -A DEP_DELIVERED_CACHE=()

# ---------- 1c. 卡住任务处置（#4371）：消费 f8（#4366）的在制品年龄信号 ----------
# 检测归 f8：flow.wip_age_stage_p90_hours 越过阈值（UNHEALTHY）时，scorecard 的
# flow.wip_age[].oldest 列出各超龄阶段的单元。本阶段只消费这个信号，不做第二套年龄检测：
# 对超龄单元的活 worker 取进展指纹（事件流字节数 + 工作克隆 HEAD/跟踪与未跟踪文件内容），
# 两拍间隔（≥stuck_confirm_minutes）指纹不变 = 无进展 → 停掉 worker 及其后端进程（进程组 TERM，必要时 KILL）并
# requeue；同一单元第 2 次卡住不再 requeue，走 #4363（f6）的止损路由（hold.sh on-hold +
# supervisor 裁决）。指纹一直在变的长任务不会被停（取代旧的 90 分钟盲杀）。
STUCK_CONFIRM_MINUTES="$(jqf -r '.waste.stuck_confirm_minutes // 10' <<<"$CFG")"
# A live ZCode worker whose log ends in its turn error and has been quiet this long is hung, not working.
ZCODE_TURN_FAILED_QUIET_SECONDS="$(jqf -r '.waste.zcode_turn_failed_quiet_seconds // 60' <<<"$CFG")"
[[ "$ZCODE_TURN_FAILED_QUIET_SECONDS" =~ ^[0-9]+$ ]] || ZCODE_TURN_FAILED_QUIET_SECONDS=60
ADVISOR_ROUNDS="$(jqf -r '.advisor_rounds // 3' <<<"$CFG")"
# The advisor loop is an optional target-config module, then pack fallback. Without it, the final rejection routes to arbiter review.
_advisor_unit_loop="$(sched_config_file mac-autopilot/advisor-unit-loop.sh)" && source "$_advisor_unit_loop"
declare -F advisor_launch >/dev/null || advisor_launch() { # unit-json total-rounds
  local id decision
  id="$(jqf -r .id <<<"$1")"
  decision="$(decision_entry 'Route to one arbiter review' 'no advisor configured' "$2 review rejections; no advisor is installed" '["Return to ordinary repair without independent review"]' scheduler)"
  set_unit "$id" "$(hist arbiter-review "no advisor configured at round $2" "$decision") | .advisor_round=$2 | .arbiter=true | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
  say "no advisor configured; unit=$id round=$2 routed to arbiter-review"
}

CI_INFRA_RERUNS=3
CI_INFRA_STEP_RE='^(Set up job|Seed cold workspace|Configure git proxy|Run actions/checkout@v4|Ensure CI runner has capacity)'

# 只有"取消"、没有失败的检查不是代码结论：多为流水线自己取消的（评审中推迟 CI、打回时
# cancel_branch_runs、bell 去重；热修优先挡板退役前也在其中，#4625）。以前它和失败一样消耗唯一的重跑额度，第二次再被取消就作废批准、派 repair
# （pr-2609 已批准的 21a072c91 没有任何失败 job，2026-10-21 14:30 仍被判"重跑后仍红"送去修复，L64）。
CI_CANCEL_RERUNS=3
# 聚合 job 因上游被取消而红（needs.<job>.result 为 cancelled）：失败的检查只有 "Pipeline suites" 聚合 job，且同一工作流的
# 其余 job（scope / focused / full 分片）没有失败、至少一个被取消。任何真实失败的 job 或缺数据都不命中，走原有红路径。
# 不改聚合 job 去跳过必需检查：GitHub 把跳过的必需检查记为通过，会放过没跑的 suites。

# ---------- 门控 draft 单元（draft-ci 09-12）----------
# 调度器自己的 agent/issue-* PR 以 draft 创建并带 agent/ci-gated 标签；批准且占到 CI 名额的 head 才 `gh pr ready`
# （ready 事件是 PR workflow 的触发器），head 不再会合并（repair 派出、评审打回、失去名额或批准）就退回 draft。
# 共享真相是 GitHub 上的标签与按 head 绑定的两个 commit status（agent/ci-approved success、agent/ci-waiting pending）；
# 台账 .approved_sha 是单机权威，.gated 只是台账里的镜像。名额排序沿用 ci_admission 的同一个 top-K。
GATED_LABEL="agent/ci-gated"
GATED_BRANCH_RE='^agent/issue-'
# #4484：接管的外部分支 PR（fix/、ci/、hotfix/、agent/auto-issue-*…）不满足重活 job 的
# agent/issue- 前缀条件，必需检查永远 skipped。pipeline-ci 标签是「这个 PR 归流水线管、要跑重活」
# 的唯一标记：CI 条件读它（labeled 事件触发），合并车道给非 agent 分支的批准 head 补它。
PIPELINE_CI_LABEL="pipeline-ci"
PIPELINE_CI_LABEL_READY=0
declare -gA GATED_OF=() GATED_SLOT=() READIED_PRS=()
GATED_CENSUS_LOADED=false
GATED_LABEL_READY=0

# 一拍一次的 open PR census：number、head、mergeability、draft、分支、标题、标签、正文与检查汇总。合并车道、门控、孤儿 PR、新 PR 登记与超龄 PR 生命周期读同一份；
# 读失败或格式错就是"不可用"（返回 1），调用方本拍不据此决策。自己改了 PR（ready/draft/标签/创建/关闭/合并）后清空，下次用到再读。
TICK_PRS=""
TICK_PR_CHECK_CENSUS=""
declare -gA TICK_PR_STATE=()

# 一拍一次的 hotfix issue census（#4615）：PR 漏打 hotfix 标签时，从关联 issue 继承热修身份。
# register_new_issues 预读配置指定的热修 issue 列表；PR 判定复用这份结果，不为每个 PR 单独查 API。
TICK_HOTFIX_ISSUES='[]'
TICK_HOTFIX_ISSUES_LOADED=false

# supervisor-owned 标记本拍是否被推迟（ci_hotfix_branches 读不到）：可能有热修车道单元无法标记，
# 一切会动手的阶段（派发、快车道、CI 准入、合并车道、supervisor 裁决）整拍跳过（fail-closed）。
TICK_SUPERVISOR_MARKING_DEFERRED=false

# 未完成的 run 要按状态取：gh run list 只回最近创建的 300 个，而重跑保留原创建时间——10:43 创建、第 3 次重跑
# 排队的 run 不在窗口里，准入看不见它，它照样排在热修前面（L71）。
# 优先挡板（热修排队时取消普通 PR run）已退役（#4625）：它取消的只是排队 job，换不来 runner；
# 放行重跑又把自己取消的 run 排回热修前面，10-29 一个热修日触发 18 轮、47 个不同 run 被记 "ci hold"。
# 热修优先级由统一准入承担：ready 先行（ci_ready_hotfix_gated）、三类取消都豁免热修、WIP 名额只放行有空闲 runner 的量。
TICK_UNFINISHED=""
TICK_UNFINISHED_LOADED=false
TICK_UNFINISHED_IN_PROGRESS_OK=false
TICK_UNFINISHED_ALL_OK=false
declare -A CI_RUN_JOBS_CACHE=()

# CI 在制品上限（看板 WIP / Little 定律，L77）：98 个就绪 PR × 约 6 个 workflow = 130 个 run 排在约 8 个 PR runner 前，
# GitHub 按先来先服务交错跑，每个 PR 都要等整个队列跑空才全绿；hold 每次放行又把它们排回队尾。10-21 23:42 就绪 98 个、
# 全绿 0 个、5 小时合并 3 个。每拍放行槽位按在线 PR runner 减去这些 runner 上的 in-progress job 计算，按 main-red > opt（.ci_priority）> normal 排序。
# 已放行的单元不重复占用空闲槽；其余等待单元还没有 job 在跑的 run 取消、记 .ci_wip_wait，空出 runner 后按就绪顺序补上，只补被取消的 job。
# 非产品 PR（只改流水线/CI/文档）不排产品 CI 的队（maintainer 10-22：[...]
# ）：它们多是在给约束扩容（#4044 Mac runner），排队等于自己挡自己。
NONPRODUCT_PATHS_RE='^(scripts|lessons|docs|ops|[.]agents|[.]trellis|[.]github)/|^[^/]+[.]md$'

# Pipeline-suites 首红：并行跑本机复现（detached，tick 不等它）和 GitHub 原生 rerun。复现证明「父提交过、候选败」才回退；
# 回退走 revert_squash_merge（main 的历史是幂等记录，push 的非快进拒绝是唯一并发控制）。其余情形保持原路径。
MAIN_RED_DIR="$A/main-red"

# main 的 Pipeline suites run 每个慢 tick 只列一次；逐提交的结论从同一份结果取，不再一提交一次 gh run list。
# 读失败也记为本拍已尝试，suites_run_for 无输出 = 没有结论，门禁照旧保持关闭。
# 不再后台预取，首次使用时同步取一次（#4725）。
MAIN_SUITES_RUNS=""
MAIN_SUITES_RUNS_LOADED=false

# ---------- 4z. M5 生效即验收（#4495/#4501）：直落单等登记的生产事件才关票 ----------
# pipeline-system 票的验收块是 issue 正文 ```json 围栏里带 acceptance 数组的对象，至少一项
# id=live-event，通过 event 字段或登记表 acceptance_item_ids 绑定到登记机制。
# 派发时把验收块存进 unit 记录；direct-main 落地后不立即关票（stage=awaiting-live-event），
# 观测到该机制晚于落地时间的事件行才关票（评论附证据行），超过该机制的沉默上限转 supervisor；
# 关票前对比存档的验收块，worker 改过验收项就拒绝关票。
MECH_REGISTRY_FILE="$(sched_mechanism_registry)" || { MECH_REGISTRY_FILE=""; say "mechanism registry unavailable: live-event acceptance cannot resolve a mechanism this tick"; }

# 孤儿 PR 对账（2026-10-20：159 个 open PR 里 120 个不在台账，其中 100 个是 agent 做出来的）：
# register_new_prs 只看最新 15 个，register_new_issues 又跳过已有 open PR 的 issue，于是老 PR 永远没人评审、
# 它的 issue 也永远不会重做（每日早报的两个前置 #2699/#3740 就卡在这里）。每 ORPHAN_CHECK_SECONDS（默认 1800）：
# agent/issue-N 分支的 PR，issue 已关或台账里已有同 issue 的另一单元 → 关 PR（已被取代）；否则收进台账评审，
# 每次最多 ORPHAN_REGISTER_MAX（默认 3）个，挡着别的单元的前置优先。非 agent 分支只计数（orphan-prs.count）。
# 集成测试左移：worker clone 经 runtime-env.sh 的 PGTEST_URL 连本机测试库，push 前能跑集成测试。以前它们第一次跑
# 是在批准后的 CI 上（批准后 CI 红会触发大量返工）。测试库不可用时照样 push，绝不卡交付。
INTEGRATION_RULE="改动涉及集成测试（*.integration.test.*、tests/integration/、迁移）时，push 前用本机测试库定向跑：RUN_INTEGRATION=1 npx vitest run <受影响的集成测试文件> --no-file-parallelism --maxWorkers=1（PGTEST_URL 已指向本机 Postgres，每个文件自建临时库；只跑受影响文件，不跑整包）。测试库连不上或 MemAvailable 低于 3 GiB 就跳过，在报告里写明，照常 push 交给 PR CI。"
# 优化类 ticket 先核实前提（#4370）：曾有几张先实现后才发现前提不成立，白耗数小时，
# 且其测量窗口跨过了已上线的机制。eval 侧同一条规则在 prompts/implement-contract.md。
OPT_PREMISE_RULE='
优化类 ticket（声称浪费、延迟或竞态并给了量化数字）：第一步用现有数据复现这些数字——issue 自带的证据、账本、本 checkout 的文件与 git 历史，不发新的外部请求；测量窗口从被测机制最后一次改动之后开始（用 git log 定位），窗口跨过该改动测的是旧机制。把测到的数字和算法写进报告。复现不了就不实现：报告第一行写 OBSOLETE: <测到的数字、窗口、数据来源>，数据来源写 file:line、commit 或 run 链接，流水线据此关单；测不出数字不算 OBSOLETE。复现了就带着测量结果实现，它就是验收对比的基线。'
# 风险类路径的 blast-radius 证明（#4787，pstack blast-radius）：auth、RLS、账本、迁移的 implement 交付要说出安全所依赖的那一个事实，
# 并用真实函数的运行输出证明它。非风险类不要求。评审侧同一条规则在 prompts/review-contract.md，契约在 prompts/implement-contract.md。
BLAST_RADIUS_RULE="
风险类路径：先跑 node engine/risk-class.mjs --json origin/main...HEAD，输出 [] 则本条不适用；有命中则报告必须含 ## blast-radius 一节，按 $(pstack_skill_md blast-radius) 写：安全所依赖的那一个事实；受影响的调用方/面（附列出它们的命令和真实输出）；第 4 级证明（写一个小脚本调用真实函数，失败即报错，附脚本路径、命令和真实输出，不接受只指行号或推演）；合并前最便宜的复现。做不到第 4 级就写 unproven 并说明原因。"
HOTPATCH_HINT='发布阻断：这个 PR 的补丁已作为热修跑在生产上（cihost /srv/app/release-drift-carried.tsv），但没合进 main，所有 Example 发布都因此停住。先 git merge origin/main 解决冲突：冲突时以生产已验证的行为为准，同时保留 main 上的后续修复；保持改动最小，补/修回归测试，推送。'

# ---------- 旧 PR 生命周期（#4360）：超龄/深度落后的 agent PR 自动三分类 ----------
# agent PR（agent/* 与 hand/* 分支）超过 7 天或落后 main 超过 300 个提交就分类，理由写进 PR 评论：
#   已在 main（patch-id 等价，或合并后与 main 树一致）→ 关闭 PR；
#   已过时（改动文件在 main 上已全部删除）→ 关闭 PR；与 main 合并冲突只说明 main 动了，不说明意图过时，归「仍需要」；
#   仍需要 → 按原意图开新 ticket（带原 PR 链接与意图摘要，ready-for-agent），原 ticket 开着会被新票取代，
#   旧 PR 关闭。台账里有该 PR 的单元一并 closed。人手分支（fix/、ci/、hotfix/）不归流水线管，不动。
# 判定全用本地 git（一次批量 fetch 所有候选分支），不调模型；原 ticket 已关闭的 PR 不再承载活意图，直接关闭。
AGED_PR_AGE_SECONDS=$((7 * 24 * 3600))
AGED_PR_BEHIND_COMMITS=300

# 记录每拍各阶段耗时（秒），tick done 行只列 ≥5s 的阶段：一拍 6–7 分钟时看不出慢在哪（L60）。
TICK_PHASES=""
TICK_LOCK_WAIT=0

# ---------- tick 互斥：同一时刻只允许一个 scheduler 写台账 ----------
SCHED_LOCK="$A/.scheduler.lock"
SCHED_LOCK_HELD=false

# ---------- 派生视图：体检评分、看板渲染 ----------
# 它们只读快照与台账，不参与任何单元决策：拍末起一个分离的进程去跑，拍不等它们（看板一次约 40 秒）。上一轮视图没跑完就让它跑完、本轮跳过。
VIEWS_LOCK="$A/.views.lock"
# ci_admission as its own station (ci_station_tick): its own lock, so a pass never waits on the tick or the refill.
CI_STATION_LOCK="$A/.ci-station.lock"
# The harvest group as its own station (harvest_station_tick, scheduler.d/harvest-station.sh): its own lock, the ledger lock one worker at a time.
HARVEST_STATION_LOCK="$A/.harvest-station.lock"
# The intake existing walk as its own station (existing_walk_tick, scheduler.d/existing-walk-station.sh): its own lock, the ledger lock per write.
EXISTING_WALK_LOCK="$A/.existing-walk-station.lock"
# The dependency release as its own station (release_deps_station_tick, scheduler.d/release-deps-station.sh): its own lock, the ledger lock per write.
RELEASE_DEPS_STATION_LOCK="$A/.release-deps-station.lock"

# 补派循环入口（#4628）：loop.sh 与慢 tick 并行检查本地台账，30 秒一次或发现新退出的 worker 时触发。
# 慢阶段只在等待 GitHub 时让出同一 SCHED_LOCK；补派本地收割 direct-main 实现结果，另每次最多收割 2 个已结束且带报告的 PR 车道 implement/review/rereview/repair worker（释放槽位，有少量 GitHub 调用）、回收孤儿记录，
# 并收已结束的后台门（self_check_harvest / precheck_harvest，纯本地读写，不占 gh 配额）——否则自检早已
# 结束的单元要空等下一次慢拍才派评审（2026-11-03 03:12Z 起空槽 0-2/8 干等 20 分钟）；
# 当可启动 pending 少于空槽时先收 issue，再派发 implement/repair/review/rereview-pending。新候选优先复用慢拍缓存，
# 缓存失效时最多查询一个标签；实现派发只读本地台账，PR 修复、评审或复审按需读取一次共享 PR census。
# land/eval/supervise、OBSOLETE、无报告的 worker 收割与 PR 注册仍由慢 tick 处理。
# A tick runs for minutes after its one PAUSE check at the start, so acting phases look again.
paused_midrun() {
  refill_stopped && return 0 # a refused ledger lock wait ended this refill (already logged once)
  [[ -e "$PAUSE_FILE" ]] || return 1
  say "$1 stopped: paused by $PAUSE_FILE"
}
run_issue_intake_phases() {
  local rc=0
  # A live station walks the existing units; the tick then only primes the census the new-issue walk reads and loads the rows the station walked.
  if existing_walk_fresh; then intake_census_prime; existing_walked_load; else phase register_new_issues 1 || rc=$?; fi
  phase register_new_issues || rc=$?
  return "$rc"
}
run_refill_intake_dispatch_phases() {
  # Dispatch first: a refill exists to fill free slots, and 8 of the 33 refill kills of 2026-11-06/07 died in the merge pass that
  # used to run in front of it, so those refills dispatched nothing. The merge pass and intake run on the time left.
  step_timed dep_snapshot dep_delivered_snapshot # release_dependency_blocks fills this on a full tick; the body gate reads it on both
  step_timed record_run_spend record_run_spend || : # the gate in dispatch_pending reads spend_runs; a refill used to dispatch on whatever the last full tick left
  phase dispatch_pending true
  paused_midrun "refill merge" || { phase refill_merge_pass; tick_prs_changed; } # a merge changes the PRs intake reads next
  INTAKE_ADDED=0
  phase register_new_issues 0 true || say "refill intake failed; continuing to dispatch"
  # A pass started this late meets the 300s kill, and the next refill dispatches what intake added.
  (( INTAKE_ADDED == 0 || SECONDS >= ${AUTOPI_REFILL_LIMIT_SECONDS:-300} - 60 )) || phase dispatch_pending true
}
refill_tick() {
  local TICK_LOCAL_REFILL=true refill_log_offset=0 live metrics
  cd "$ROOT" || { echo "scheduler: root $ROOT unavailable" >&2; return 1; }
  refill_log_offset="$(cat "$A/.refill-dispatch-log-offset" 2>/dev/null || true)"
  if [[ ! "$refill_log_offset" =~ ^[0-9]+$ ]]; then
    [[ -f "$LOG" ]] && refill_log_offset="$(wc -c < "$LOG")"
  fi
  acquire_scheduler_lock || return 75
  rm -f -- "$A/.refill-stop" # left by a refill that was killed after a refused lock wait
  if ! step_timed state_schema state_schema_ok; then
    say "state schema invalid; refill stopped before external actions"
    echo "[$STAMP] invalid units/workers schema; supervisor recovery required" >> "$A/alerts/state.md"
    return 2
  fi
  tick_gh_calls_begin
  tick_roadmap_cache_begin
  MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)"
  phase harvest_workers true
  step_timed coord_reap coord_reap_expired || say "claim expiry sweep incomplete; unreadable claims remain fail-closed"
  step_timed coord_systemd coord_reconcile_systemd_workers || say "issue-pipeline claim reconciliation incomplete; unknown claims remain fail-closed"
  step_timed coord_scheduler coord_reconcile_scheduler_workers
  # 与慢拍同序：门收割先于 dispatch_pending，本拍收完本拍就派评审；harvest 类阶段要求补派同跑
  # （scheduler.test.sh refill_harvest_coverage），缺一个就是又一类「空等慢拍」回归。
  phase self_check_harvest
  phase precheck_harvest
  phase recover_orphans
  if [[ -e "$PAUSE_FILE" ]]; then
    say "refill paused by $PAUSE_FILE: no dispatch"
  else
    # 补派进程看不到慢拍的标记结果：自己先跑 supervisor-owned 标记（开关关时不发任何 GitHub 请求），
    # 分类不可用就本拍不派发——未标记的热修车道单元不能由补派抢走。可启动 pending 少于空槽时先收 issue，
    # 复用慢拍候选缓存；缓存过期时补派最多查询一个候选标签，并受 issue_intake.refill_max 限制。
    phase mark_supervisor_owned_units
    phase release_session_pr_units
    if supervisor_marking_deferred; then
      say "refill dispatch held: supervisor-owned marking deferred"
    else
      phase_yield_lock_batch run_refill_intake_dispatch_phases
    fi
  fi
  local gh_calls; gh_calls="$(tick_gh_calls_count)"
  say "tick-phases kind=refill secs=$SECONDS gh_calls=$gh_calls lock_wait=$TICK_LOCK_WAIT phases=${TICK_PHASE_DETAILS:-none}"
  tick_roadmap_cache_end
  rm -f -- "$GH_TICK_CALLS_FILE" 2>/dev/null || :
  rm -f -- "$TICK_INTAKE_READS_FILE" "$TICK_INTAKE_READS_FILE.lock" "$TICK_INTAKE_READS_FILE.reached" 2>/dev/null || :
  GH_TICK_CALLS_FILE=""
  TICK_INTAKE_READS_FILE=""
  live="$(live_workers)"
  metrics="$(refill_dispatch_metrics "$refill_log_offset" "$live")" \
    || metrics='free_slots=unknown pending=unknown skips=footprint:unknown,handoff:unknown,memory:unknown'
  say "refill done live=$live $metrics secs=$SECONDS ended=$(date -u +%H:%M:%SZ) gh_calls=$gh_calls${TICK_PHASES:+ slow:$TICK_PHASES}"
}

main() {
  local views_mode=dashboard gh_calls=0 tick_harvests=false
  cd "$ROOT" || { echo "scheduler: root $ROOT unavailable" >&2; return 1; }
  acquire_scheduler_lock || { echo "[$STAMP] scheduler tick skipped: another tick holds $SCHED_LOCK" >> "$LOG"; return 0; }
  if ! state_schema_ok; then
    say "state schema invalid; tick stopped before external actions"
    echo "[$STAMP] invalid units/workers schema; supervisor recovery required" >> "$A/alerts/state.md"
    return 2
  fi
  tick_gh_calls_begin
  tick_roadmap_cache_begin
  # No lock yield here: a refill that took the lock in this window held it for its first phases, then queued behind the tick's opening
  # (harvest_workers and the phases after it hold the lock for minutes). 9 of the 37 refills that started within 12s of a tick start were killed.
  phase tick_prs_prime
  phase_mark opening # steps before the first phase; a name left by the last tick or by lock_wait must not stand for them
  rotate_logs
  if update_budget >/dev/null; then
    budget_meter_scan ok
    budget_alert_if_needed
  else
    budget_meter_scan fail
    say "budget meter scan failed; dispatch continues"
  fi
  if git -C "$ROOT" fetch -q origin main 2>/dev/null; then
    MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)"
  fi
  : > "$A/.tick-phases" # loop.sh reads this and .tick-phase when it kills this tick
  harvest_station_fresh || tick_harvests=true # a live station harvests; an older loop.sh without it, or a stuck station, leaves this to the tick
  if [[ "$tick_harvests" == true ]]; then
    phase harvest_workers
    phase_mark coord_sweeps
    coord_reap_expired || say "claim expiry sweep incomplete; unreadable claims remain fail-closed"
    coord_reconcile_systemd_workers || say "issue-pipeline claim reconciliation incomplete; unknown claims remain fail-closed"
    coord_reconcile_scheduler_workers
  fi
  phase reconcile_size_recuts
  if [[ "$tick_harvests" == true ]]; then
    phase self_check_harvest
    phase precheck_harvest
    phase recover_orphans
  fi
  phase recover_orphan_landing
  phase live_event_watch
  if [[ -e "$PAUSE_FILE" ]]; then
    # 用户的后端 Codex 暂停开关：保留回收、验证与发布列车，不派发、不合并。
    say "paused by $PAUSE_FILE: harvest and release train only, no dispatch or merge"
    phase run_release_train
  else
    # 每慢拍一次终态退休（持锁、纯本地）：先把 600+ 终态单元移出热台账，本拍后续的 intake /
    # dispatch / CI 准入 / 合并车道就不用再为它们付每笔 2 秒的整文件读写。PAUSE 期间不动台账。
    phase retire_terminal_units
    phase stuck_worker_disposition
    release_deps_tick_phase
    phase_yield_lock_batch run_issue_intake_phases
    phase retire_landed_pr_units
    phase supersede_resolved_main_red_units
    # supervisor-owned 标记必须先于任何会动手的阶段（派发、快车道、CI 准入、合并车道）落进台账。
    phase mark_supervisor_owned_units
    phase release_session_pr_units
    if supervisor_marking_deferred; then
      # 分类不可用：可能有热修车道单元本拍无法标记，派发、快车道、CI 准入、合并车道与 supervisor
      # 裁决整拍跳过；登记与生命周期照常，分类恢复的下一拍补标记后恢复推进。
      say "acting phases held: supervisor-owned marking deferred"
    else
      record_run_spend || :  # a plain call: phase() primes the PR cache first, which dispatch_pending does itself
      phase_yield_lock dispatch_pending
      if ! paused_midrun "acting phases"; then
        phase_yield_lock dispatch_supervisor_arbiters
        phase dispatch_prompt_evals
        phase fast_land_lane
        tick_prs_changed # Dispatched workers can push while earlier phases run.
        ci_station_fresh || phase_yield_lock ci_admission # a live station admits; an older loop.sh without it leaves this to the tick
        merge_station_fresh || phase_yield_lock run_merge_lane # a live merge station merges; an older loop.sh without it leaves this to the tick
      fi
    fi
    phase register_new_prs
    phase reconcile_orphan_prs
    phase aged_pr_lifecycle
    phase run_release_train
    phase stage_slo_watch
    phase footprint_hog_alert
    views_mode=full
  fi
  # Views and the snapshot come before cleanup: a slow worktree walk under load used to eat the tick and lose them (2026-11-07).
  # The closing steps write no ledger row except cleanup's one workers trim, which takes the lock itself. Measured 2026-11-07 16:14-16:16Z:
  # the tick held the lock for 128s here (cleanup_tick alone 88s) and a refill's ledger writes waited behind it.
  release_scheduler_lock
  phase_mark flush_focus_alert
  flush_focus_alert
  phase_mark publish_pr_run_snapshot
  publish_pr_run_snapshot
  phase_mark launch_views
  launch_views "$views_mode"
  phase_mark cleanup_tick
  cleanup_tick
  gh_calls="$(tick_gh_calls_count)"
  say "tick-phases kind=full secs=$SECONDS gh_calls=$gh_calls lock_wait=$TICK_LOCK_WAIT phases=${TICK_PHASE_DETAILS:-none}"
  tick_roadmap_cache_end
  rm -f -- "$GH_TICK_CALLS_FILE" 2>/dev/null || :
  rm -f -- "$TICK_INTAKE_READS_FILE" "$TICK_INTAKE_READS_FILE.lock" "$TICK_INTAKE_READS_FILE.reached" 2>/dev/null || :
  GH_TICK_CALLS_FILE=""
  TICK_INTAKE_READS_FILE=""
  local tick_skips; tick_skips="$(dispatch_skip_summary)"
  say "tick done units=$(jqf '.units | length' "$UNITS") live=$(live_workers) secs=$SECONDS ended=$(date -u +%H:%M:%SZ) gh_calls=$gh_calls${TICK_PHASES:+ slow:$TICK_PHASES}${tick_skips:+ skips=$tick_skips}"
}

if [[ "${AUTOPI_TEST_LIBRARY_ONLY:-false}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi
case "${1:-}" in
  --views) views_entry "${2:-dashboard}" ;;
  --refill) refill_tick ;;
  --ci-admission) SCHED_STATION=true; ci_station_tick ;;
  --merge) SCHED_STATION=true; merge_entry ;;
  --harvest-station) SCHED_STATION=true; harvest_station_tick ;;
  --existing-walk) SCHED_STATION=true; existing_walk_tick ;;
  --release-deps) release_deps_station_tick ;;
  --unretire) UNIT_RETIRE_DISABLED=true; acquire_scheduler_lock_wait; unretire_all_units; unretire_rc=$?; release_scheduler_lock; exit "$unretire_rc" ;; # back out retirement; set UNIT_RETIRE_DISABLED or revert before the next tick
  --size-waiver-check) size_waiver_range_check "${2:-}" ;; # hold.sh --rule --size-waiver: refuse a bad max_lines before any hold is released
  --rule) rule_entry "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" ;; # hold.sh --rule: record the supervisor ruling that refills the stop-loss budget
  *) main "$@" ;;
esac
