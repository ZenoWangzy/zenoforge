#!/usr/bin/env bash
# the product autopilot scheduler（Mac/WSL 通用）：确定性 timer 驱动的 pipeline 全自动调度。
# 每 tick：回收完成 worker → 状态机推进 → 派发下一环节 → 门禁内自动 merge → 生成 dashboard 数据。
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/../closing-keywords.sh"
source "$HERE/runtime-env.sh"
source "$HERE/../verification-plan-runtime.sh"
source "$HERE/config-reconcile.sh"
source "$HERE/../matt-skills.sh"
ENGINE_ROOT="$(cd -- "$HERE/../.." && pwd -P)" # holds .agents/skills and engine/prompts, which read-only Claude reviewers get via --add-dir
REQUIRED_PR_CHECKS_FILE="${REQUIRED_PR_CHECKS_FILE:-$HERE/required-pr-checks.json}"
ROOT="$MAC_AUTOPILOT_ROOT"
SUP="$MAC_AUTOPILOT_SUPERVISOR_DIR"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
SESSIONS_DIR="${CODEX_SESSIONS_DIR:-${CODEX_HOME:-${HOME:-}/.codex}/sessions}"
CODEX_REPAIR_RUNNER="$ROOT/engine/codex-repair-run.sh"
[[ -r "$CODEX_REPAIR_RUNNER" ]] || CODEX_REPAIR_RUNNER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/codex-repair-run.sh"
SESSION_TZ="${SESSION_TZ:-America/Los_Angeles}"
TODAY="$(TZ="$SESSION_TZ" date +%Y-%m-%d)"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TAG="$(date -u +%Y%m%dT%H%M%SZ)"
NOW_EPOCH="$(date +%s)"
LOG="$A/scheduler.log"
PAUSE_FILE="${AUTOPILOT_PAUSE_FILE:-${HOME:-}/.zenoforge/PAUSE}"
say() { echo "[$STAMP] $*" >> "$LOG"; }
jqf() { jq "$@" 2>/dev/null; }
js() { jq -cn --arg v "$1" '$v'; }  # 任意文本 → jq 字符串字面量，供拼入 set_unit 表达式
# The scheduler is launched standalone by loop.sh; provide lib.sh's shared helper
# without making the scheduler depend on lib.sh being sourced into its process.
declare -F jq_arg_file >/dev/null 2>&1 || jq_arg_file() {
  local f
  f="$(mktemp)" || return 1
  printf '%s' "$1" > "$f"
  echo "$f"
}
# Only a real pass satisfies a required name; skipped/neutral/absent rows do not.
# The required names are the always-concluding aggregates (#4484): a gate that legitimately
# does not run is an allowed skip inside the aggregate row, so this guard can no longer sit
# in a permanent "required checks skipped" wait for PRs whose heavy jobs did not start.
required_checks_without_pass() {
  # `gh pr checks` bucket and same-name de-dup semantics differ on old gh; an older gh never merges.
  local min have ready_at="${2:-}"
  min="$(jq -r '.min_gh_version // empty' "$REQUIRED_PR_CHECKS_FILE" 2>/dev/null)"
  if [[ -n "$min" ]]; then
    have="$(command gh --version 2>/dev/null | awk 'NR==1 {print $3}')"
    if [[ -z "$have" || "$(printf '%s\n%s\n' "$min" "$have" | sort -V | head -1)" != "$min" ]]; then
      echo "gh ${have:-unavailable} is older than required $min"; return 0
    fi
  fi
  jq -r --arg ready_at "$ready_at" --slurpfile policy "$REQUIRED_PR_CHECKS_FILE" '
    def time_key:
      try (capture("^(?<seconds>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<fraction>\\.[0-9]+)?Z$") as $time
        | [$time.seconds, (($time.fraction // "") | sub("^\\."; "") | . + "000000000" | .[0:9])])
      catch null;
    def passed($name): any(.[]; .name == $name and .bucket == "pass"
      and ($ready_at == "" or (
        (.started_at | time_key) as $started
        | ($ready_at | time_key) as $ready
        | $started != null and $ready != null and $started >= $ready
      )));
    . as $checks | $policy[0] as $p |
    [$p.required[] | . as $name | select($checks | passed($name) | not)] | unique | join(", ")
  ' <<< "$1" 2>/dev/null || echo "required-pr-checks.json unreadable"
}
mkdir -p "$A/alerts"

if [[ "${AUTOPI_TEST_LIBRARY_ONLY:-false}" != true && "${1:-}" != --views && "${1:-}" != --refill ]]; then
  if ! reconcile_event="$(reconcile_runtime_config "$HERE/config.template.json" "$A/config.json" "$ROOT/engine/lib.sh")"; then
    say "config-reconcile failed; tick stopped before reading config"
    exit 1
  fi
  [[ -z "$reconcile_event" ]] || say "$reconcile_event"
fi
CFG="$(cat "$A/config.json")"
UNITS="$A/units.json"; WORKERS="$A/workers.json"
[[ -f "$WORKERS" ]] || echo '{"workers":[]}' > "$WORKERS"
MAX="$(jqf -r .max_workers <<<"$CFG")"
DISPATCH_PRIORITY_ORDER="$(jqf -c '.dispatch_priority_order // ["hotfix", "opt", "normal"]' <<<"$CFG")"
IMPLEMENT_CAP="$(jqf -r '.implement_cap // 99' <<<"$CFG")"
BUDGET="$(jqf -r .daily_token_budget <<<"$CFG")"
[[ "$BUDGET" =~ ^[0-9]+$ ]] || BUDGET=0
FOCUS_MODE="$(jqf -r '.focus_mode // "all"' <<<"$CFG")"
# 默认关：早期 stale-base 路由只在 ticket 11 的回放确认零误判后由配置打开
STALE_BASE_ROUTING="$(jqf -r '.stale_base_routing // false' <<<"$CFG")"
BUDGET_METER="$(jqf -r '.budget_meter // "sessions_dir"' <<<"$CFG")"
WT_ROOT="$(jqf -r '.worktree_root // empty' <<<"$CFG")"
WT_ROOT="${WT_ROOT:-${HOME:-/tmp}/.zenoforge/autopilot-wt}"
LOOP_BREAKER_ROUNDS="$(jqf -r '.loop_breaker_rounds // 5' <<<"$CFG")"
# 终身返工上限：supervisor-requeue 会给 loop_rounds 重新记数，但不重置这个总数（pr-3863 被重排 4 次，20 轮修复、10.5M token）。
LOOP_TOTAL_ROUNDS="$(jqf -r '.loop_total_rounds // 8' <<<"$CFG")"
# 尺寸准入（10-22 R2）：超过 N 改动行的实现不开评审，连同数字转 supervisor 重切（大 PR 占 36.3%，
# Anthropic 观察到 >1000 行的 PR 多数有 findings）。文档、生成物、锁文件与测试快照不计入。
SIZE_ADMISSION_LINES="$(jqf -r '.size_admission_lines // 800' <<<"$CFG")"
# 止损预算（#4363）：每张 ticket 自最近一次 supervisor 裁决起最多 N 轮（implement 加 repair，含自修复重派，
# 每次 write-start 记一轮）或 4h 墙钟；第 4 轮不再派发——原票自动 on-hold 附原因，单元转 supervisor（#4369 terra 裁决）。
TICKET_ROUND_BUDGET="$(jqf -r '.ticket_round_budget // 3' <<<"$CFG")"
TICKET_WALL_BUDGET_SECONDS="$(( $(jqf -r '.ticket_wall_budget_minutes // 240' <<<"$CFG") * 60 ))"
# 工单 token/分钟/轮数是仪表盘指标（workorder_cost.py，node_health 用），不是停单开关（#4486：
# #4053 把 raw-token bug 线当硬停，96% 是缓存读取、按生命周期累计、事后才停，36 次误停正常单）。
MAX_NO_OUTPUT="$(jqf -r '.waste.max_no_output // 2' <<<"$CFG")"
# f12（#4369）：supervisor-review 由 terra 裁决 worker 接管；eval 门槛（恒选 requeue 参照 + 零危险 approve）达标前默认关。
SUPERVISOR_ARBITER="$(jqf -r 'if .supervisor_arbiter.enabled == true then "true" else "false" end' <<<"$CFG")"
SUPERVISOR_ARBITER_PROFILE="$(jqf -r '.supervisor_arbiter.profile // "terra"' <<<"$CFG")"
SUPERVISOR_NEEDS_INFO_PER_TICK="$(jqf -r '.supervisor_arbiter.needs_info_per_tick // 3' <<<"$CFG")"
# 一次一个时 42 个 supervisor-review 要排 3.5 h（10-28 解除 PAUSE 后实测）；裁决只读、轻量，按名额并发。
SUPERVISOR_ARBITER_MAX="$(jqf -r '.supervisor_arbiter.max_in_flight // 4' <<<"$CFG")"
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
final_message_of() { awk '/^tokens used$/{getline; buf=""; f=1; next} f{buf=buf $0 "\n"} END{printf "%s", buf}' "$1" 2>/dev/null; }
tokens_of() { awk '/tokens used/{getline; if (match($0, /[0-9][0-9,]*/)) { n=substr($0, RSTART, RLENGTH); gsub(/,/, "", n); print n }; exit}' "$1" 2>/dev/null; }

write_state() { # 用法: jqf ... "$1" | write_state "$1"   stdin=新内容 $1=目标文件
  local dst="$1" _t valid=false; _t="$(mktemp "${dst}.tmp.XXXXXX")" || return 1
  cat > "$_t"
  if [[ "$dst" == "$UNITS" ]]; then
    # No units are deleted by this scheduler. Clone cleanup and worker-ledger
    # trimming below remain legitimate; neither may erase registered unit IDs.
    # -s: a state file must be exactly one document. A top-level comma in a hand edit (10-29 06:32Z) wrote three
    # concatenated copies; per-document -e accepted every later write and each copy drifted apart.
    jq -e -s --slurpfile old "$dst" 'length==1 and (.[0] |
      type=="object" and (.units|type)=="array"
      and all(.units[]; type=="object" and (.id|type)=="string" and (.id|length)>0 and (.stage|type)=="string")
      and ([.units[].id]|length)==([.units[].id]|unique|length)
      and (($old[0].units|map(.id)) - [.units[].id] | length)==0)
    ' "$_t" >/dev/null 2>&1 && valid=true
  elif [[ "$dst" == "$WORKERS" ]]; then
    jq -e -s 'length==1 and (.[0] | type=="object" and (.workers|type)=="array"
      and all(.workers[]; type=="object" and (.pid|type)=="number" and .pid>0 and (.unit|type)=="string"))' \
      "$_t" >/dev/null 2>&1 && valid=true
  else
    jq -e -s 'length==1 and (.[0]|type=="object")' "$_t" >/dev/null 2>&1 && valid=true
  fi
  if [[ -s "$_t" && "$valid" == true ]]; then
    cp "$dst" "$dst.bak" 2>/dev/null || true
    mv "$_t" "$dst"
    if [[ "$dst" == "$WORKERS" ]]; then LIVE_WORKER_CACHE_UNTIL=0; fi
    return 0
  else
    rm -f "$_t"; say "write_state guard: invalid shape or missing unit IDs for $dst, keep old"
    return 1
  fi
}

# 评审结论只认整行 `VERDICT: X`；旧报告别名规范化为 review-contract.md 的 verdict。
verdict_of() {
  local found findings
  found="$(grep -E '^[[:space:]>#*-]*(\*\*)?VERDICT:[[:space:]]*(READY|NOT_READY|INPUT_INCOMPLETE|APPROVE|REQUEST-CHANGES|BLOCK)(\*\*)?[[:space:]]*$' "$1" 2>/dev/null \
    | grep -oE 'READY|NOT_READY|INPUT_INCOMPLETE|APPROVE|REQUEST-CHANGES|BLOCK' \
    | sed -e 's/^APPROVE$/READY/' -e 's/^REQUEST-CHANGES$/NOT_READY/' -e 's/^BLOCK$/INPUT_INCOMPLETE/' | sort -u)"
  if [[ -n "$found" ]]; then
    [[ "$(wc -l <<<"$found")" -eq 1 ]] && { printf '%s' "$found"; return 0; }
    return 1
  fi
  # 10-28：约 1/5 的评审写「## Verdict」标题、下一行裸写 NOT_READY，缺 `VERDICT:` 前缀，被当成无结论重跑。
  found="$(awk 'h && NF { gsub(/[*`]/, ""); if ($0 ~ /^[[:space:]]*(READY|NOT_READY|INPUT_INCOMPLETE)[[:space:]]*$/) print $1; exit }
    /^#+[[:space:]]*Verdict[[:space:]]*$/ { h = 1 }' "$1" 2>/dev/null)"
  if [[ -n "$found" ]]; then
    [[ "$(wc -l <<<"$found")" -eq 1 ]] && { printf '%s' "$found"; return 0; }
    return 1
  fi
  findings="$(findings_block_of "$1")" || return 1
  jqf -e 'any(.findings[]; .status=="open" and (.severity=="P0" or .severity=="P1"))' <<<"$findings" >/dev/null 2>&1 \
    && printf 'NOT_READY'
}

verification_plan_for_state() { # checkout state-json → advisory feature plan from declared paths
  local checkout="$1" state="$2" entry_surface expected_paths
  entry_surface="$(jqf -r '.entry_surface // empty' <<<"$state")"
  expected_paths="$(jqf -c '[.expected_paths[]?] | unique' <<<"$state")"
  build_verification_intent_plan_json "$checkout" "$HERE/.." "$entry_surface" "$expected_paths"
}

verification_plan_brief() { # plan-json → worker-facing structured feature evidence
  jq -c '
    {
      feature_ids:(.matched_features // []),
      unmapped_paths:(.unmapped_paths // []),
      plan_status:(.status // "unavailable"),
      verify_command:(if ((.matched_features // []) | length) > 0
        then "node scripts/e2e/acceptance-regression/verify-feature.mjs --feature \((.matched_features // []) | join(",")) --target <base-url> --json"
        else null end)
    }
  ' <<<"$1"
}

# review-contract.md owns the review-findings object. Legacy arrays remain readable for reports already on disk.
findings_block_of() { # report → stdout: {findings:[...],dispositions:[...]}
  local raw
  raw="$(awk '/^```review-findings[[:space:]]*$/{on=1;buf="";last="";next} on&&/^```[[:space:]]*$/{last=buf;on=0;next} on{buf=buf $0 "\n"} END{printf "%s", last}' "$1" 2>/dev/null)"
  [[ -n "${raw//[[:space:]]/}" ]] || return 1
  jq -ce '
    def finding($legacy): type=="object"
      and (.id|type)=="string" and (.id|length)>0
      and (.severity|IN("P0","P1","P2","P3"))
      and (.file|type)=="string" and (.file|length)>0
      and (.line|type)=="number" and .line==(.line|floor) and .line>0
      and (.status|IN("open","resolved","inherited"))
      and ((has("introduced_by")|not and $legacy) or (.introduced_by|IN("candidate","pre_existing","unknown")))
      and ((has("base_evidence")|not and $legacy) or ((.base_evidence|type)=="string" and (.base_evidence|test("\\S"))))
      and (if $legacy then true else keys==["base_evidence","file","id","introduced_by","line","rule","severity","status","summary"] end)
      and ((has("rule")|not) or (.rule|type)=="string")
      and ((has("summary")|not) or (.summary|type)=="string")
      and (if $legacy then true else (.rule|length)>0 and (.summary|length)>0 end);
    def normalized_finding: {id,severity,file,line,rule:(.rule // null),status,summary:(.summary // null),introduced_by:(.introduced_by // null),base_evidence:(.base_evidence // null)};
    def disposition: type=="object" and (.id|type)=="string" and (.id|length)>0
      and (.disposition|IN("fixed","disproved","intentional","out-of-scope"))
      and (.reason|type)=="string" and (.reason|test("\\S")) and (.reason|test("^[^\\r\\n]+$"))
      and keys==["disposition","id","reason"];
    if type=="array" and all(.[]; finding(true)) then
      {findings:map(normalized_finding),dispositions:[],legacy:true}
    elif type=="object" and keys==["dispositions","findings"] and (.findings|type)=="array" and (.dispositions|type)=="array"
      and all(.findings[]; finding(false)) and all(.dispositions[]; disposition)
      and (([.findings[].id] | length)==([.findings[].id] | unique | length))
      and (([.dispositions[].id] | length)==([.dispositions[].id] | unique | length)) then
      {findings:(.findings|map(normalized_finding)),dispositions:.dispositions,legacy:false}
    else empty end' <<<"$raw" 2>/dev/null
}
# Actionable blocking findings provide a concrete target for the repair worker.
review_findings_hint_update() { # report → jq update fragment for open P0/P1 findings
  local findings hint
  findings="$(findings_block_of "$1")" || return 0
  hint="$(jqf -r '[.findings[] | select(.status=="open" and (.severity=="P0" or .severity=="P1"))
    | "\(.id) \(.file):\(.line) — \(.summary // .id)"] | join("\n")' <<<"$findings")"
  [[ -n "$hint" ]] || return 0
  printf ' | .repair_hint=%s' "$(js "$hint")"
}
# 一次打回在 .review_findings 里追加一条：round 是它在 history 里的第几次打回，findings 只含阻断级（P0/P1，
# 含 resolved 状态，由复发规则排除）；块缺失或畸形记 block=missing（node_health 的 review.findings_missing_pct 数它）。
# 不写 history：顾问触发读 history 的最后一条是否为 review-request-changes。
review_findings_update() { # report-path report-name → set_unit 表达式片段（以 " | " 开头）
  local rec block
  if block="$(findings_block_of "$1")"; then
    rec="$(jq -c '{block:"ok", findings:[.findings[] | select(.severity=="P0" or .severity=="P1")], all_findings:.findings, dispositions:[]}' <<<"$block")"
  else
    rec='{"block":"missing","findings":[],"dispositions":[]}'
  fi
  printf ' | .review_findings = ((.review_findings // []) + [{round:((.history // []) | map(select(.stage=="review-request-changes")) | length), at:%s, report:%s} + %s])' \
    "$(js "$STAMP")" "$(js "$2")" "$rec"
}

review_dispositions_update() { # repair-report → attach author dispositions to the latest finding record
  local block record
  if block="$(findings_block_of "$1")" && [[ "$(jqf -r '.legacy // false' <<<"$block")" == false ]]; then
      record="$(jq -c --argjson expected "$(jqf -c '[.review_findings[-1] | (.all_findings // .findings // [])[]?.id] | sort' <<<"$2")" '
      .dispositions as $d | {disposition_block:(if ([$d[].id] | sort)==$expected then "ok" else "incomplete" end),dispositions:$d}' <<<"$block")"
  else
    record='{"disposition_block":"missing","dispositions":[]}'
  fi
  printf ' | .review_findings = ((.review_findings // []) as $r | if ($r|length)==0 then $r else $r[0:-1] + [($r[-1] + %s)] end)' "$record"
}

review_dispositions_context() { # unit-json → persisted author dispositions for targeted re-review
  jqf -r '(.review_findings // [] | last) as $latest
    | if $latest == null then empty
      elif $latest.disposition_block == "ok" then
        "\nAuthor dispositions from unit history (re-review these IDs; do not repeat the original debate):\n" +
        ([$latest.dispositions[] | "- \(.id): \(.disposition) — \(.reason)"] | join("\n"))
      elif $latest.disposition_block == "incomplete" then "\nAuthor dispositions from unit history are incomplete; re-review the listed findings and identify any missing ID."
      elif $latest.disposition_block == "missing" then "\nThe repair report did not record author dispositions; use the prior findings and current diff."
      else empty end' <<<"$1"
}

# 改动文件扫描：首次打回之后，每次返工与复审都按此前的阻断发现类别（rule + 一句话）检查本 PR 全部改动文件，不只被点名的文件。
# 顾问裁决/仲裁评审之后重新计类别；没有打回过的单元不带这一段。输出为提示片段，无类别时为空。
sweep_rule() { # unit-json [head-sha]
  local classes
  classes="$(jqf -r '(.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage | IN("advisor-ruling","arbiter-review")) | .key] | max // -1) as $i
    | ([$h[:($i + 1)][] | select(.stage=="review-request-changes")] | length) as $k
    | [(.review_findings // [])[] | select(.block=="ok" and .round > $k) | .findings[] | select((.severity=="P0" or .severity=="P1") and .status!="resolved")
        | "- [\(.rule // "?")] \(.summary // .id)（\(.file):\(.line)）"] | unique | .[]' <<<"$1" 2>/dev/null)"
  [[ -n "$classes" ]] || return 0
  printf '\n改动文件扫描（此前打回过）：下列是此前的阻断发现类别。对本 PR 全部改动文件（git diff --name-only origin/main...HEAD；以 head %s 为准，不限于被点名的文件）逐类搜同类实例，一并处理或在报告里逐类写出：是否又发现更多同类实例、各几处（发现块里新实例用同一 rule 记 open）。\n%s\n' "${2:-当前 head}" "$classes"
}

# PID 存活且确为 codex 进程（防 PID 复用把无关进程当活 worker）。
alive() { ps -p "$1" -o args= 2>/dev/null | grep -Eq 'codex|claude|land-pr\.sh|precheck\.sh|decision-gate\.mjs'; }

set_unit() { # id jq_update_expression（.stage=... 等，可用 | 连接）
  local own_lock=false rc=0
  if [[ "${SCHED_LOCK_HELD:-false}" != true ]]; then
    acquire_scheduler_lock_wait || return 1
    own_lock=true
  fi
  jqf --arg id "$1" "(.units[] |= (if .id==\$id then ($2) else . end))" "$UNITS" | write_state "$UNITS" || rc=$?
  if [[ "$own_lock" == true ]]; then release_scheduler_lock; fi
  return "$rc"
}
units_update() { # jq args; transactionally update the unit ledger under the shared scheduler lock
  local own_lock=false rc=0
  if [[ "${SCHED_LOCK_HELD:-false}" != true ]]; then
    acquire_scheduler_lock_wait || return 1
    own_lock=true
  fi
  jqf "$@" "$UNITS" | write_state "$UNITS" || rc=$?
  if [[ "$own_lock" == true ]]; then release_scheduler_lock; fi
  return "$rc"
}
unit_field() { jqf -r --arg id "$1" "[.units[] | select(.id==\$id) | ($2 // empty)][0] // empty" "$UNITS"; }
unit_retries() { # unit stage → 历史里该 stage 出现次数
  jqf -r --arg id "$1" --arg st "$2" '[.units[] | select(.id==$id) | (.history // [])[] | select(.stage==$st)] | length' "$UNITS"
}
hist() {
  local entry
  entry="$(jqf -cn --arg stage "$1" --arg result "${2:-}" --arg at "$STAMP" --argjson decision "${3:-null}" \
    '{stage:$stage,result:$result,at:$at} + (if $decision == null then {} else {decision:$decision} end)')"
  echo ".history += [$entry]"
}
decision_entry() { # decision why evidence rejected-json owner -> history decision object
  jqf -cn --arg decision "$1" --arg why "$2" --arg evidence "$3" --argjson rejected "$4" --arg owner "$5" \
    '{decision:$decision,why:$why,evidence:$evidence,rejected:$rejected,owner:$owner}'
}
to_supervisor() { # id note：升级到 supervisor；第 3 次不再升级，直接 needs-info（#4369）
  local decision
  if [[ -n "${3:-}" ]]; then
    decision="$(decision_entry "$3" "$4" "$5" "$6" scheduler)"
  else
    decision="$(decision_entry 'Hand off to supervisor' "$2" "$2" '["Continue automated handling"]' scheduler)"
  fi
  set_unit "$1" "$(hist supervisor-escalated "$2" "$decision") | .stage=\"supervisor-review\" | .note=$(js "$2")"
  say "supervisor-review unit=$1: $2"
  cancel_unit_runs "$1" "parked for the supervisor"
  if (( $(supervisor_entries "$1") >= 3 )); then
    supervisor_budget_park "$1" "third entry into supervisor-review; arbitration cap is 2 (#4369)"
  fi
}

# #4369：supervisor-review 不再等人。第 1、2 次升级派一个裁决 worker（terra，见 dispatch_supervisor_arbiters）；
# 用尽后 needs-info 是唯一回到人的出口。entries 数两种历史标记：to_supervisor 的 supervisor-escalated
# 与合并车道门禁直接写的 supervisor-review（2288/2315 一带）。
# 人工交接（"handed to <session> ..."）不是失败，不计数：10-28 解除 PAUSE 后它们让 4 个单元直接触顶转 needs-info。
supervisor_entries() { # id → 该单元进入 supervisor-review 的历史次数
  jqf -r --arg id "$1" '[.units[] | select(.id==$id) | (.history // [])[] | select((.stage=="supervisor-escalated" or .stage=="supervisor-review") and ((.result // "") | startswith("handed to ") | not))] | length' "$UNITS"
}

supervisor_needs_info_question() { # unit-json → 没有裁决报告时的模板澄清问题
  local reasons
  reasons="$(jqf -r '[(.history // [])[] | select(.stage=="supervisor-escalated" or .stage=="supervisor-review") | .result // empty] | .[-3:] | map(select(length > 0)) | join("；")' <<<"$1" | head -c 600)"
  printf '工作单元 %s 多次升级到工厂 supervisor 后仍无法自动裁决（最近原因：%s）。请给出一个决定：按什么方向继续、搁置，还是关闭？' \
    "$(jqf -r .id <<<"$1")" "${reasons:-记录里没有升级原因}"
}

# 预算用尽是流程问题，不是需求问题：10-28 解除 PAUSE 后它向维护者发了 6 个「继续、搁置还是关闭」的通用问题，
# 每个都由 agent 自己就能定（已合入、有待修 P1、交接人不在）。只有裁决 worker 判定的 needs-info 才问人。
supervisor_budget_park() { # id evidence → parked，留给 supervisor，不发评论
  local id="$1" evidence="$2" decision="${3:-null}" reason="${4:-supervisor budget exhausted}" stage="${5:-supervisor-budget-park}" note
  note="$(js "$reason: $evidence")"
  set_unit "$id" "$(hist "$stage" "$evidence" "$decision") | .stage=\"parked\" | .note=$note"
  say "supervisor budget-park unit=$1: $2"
}

# 轮数或墙钟止损已用尽且仍没有 PR：交给 recut 拆成可交付的子票。
# 走 lib.sh 唯一的 needs-recut 入口 route_to_recut；有未提交、stash 或未推送改动时不关单元，照旧 park。
supervisor_budget_recut() { # id evidence → 无 PR 时 issue 转 needs-recut、单元 closed；否则 park
  local id="$1" evidence="$2" decision="${3:-null}" park_reason="${4:-supervisor budget exhausted}"
  local recut_reason="${5:-ticket stop-loss reached}" park_stage="${6:-supervisor-budget-park}" recut_stage="${7:-supervisor-budget-recut}"
  local issue pr err note
  issue="$(unit_field "$id" '.issue // empty')"; pr="$(unit_field "$id" '.pr // empty')"
  local d
  for d in "$WT_ROOT/wt-$id" "/tmp/wt-$id"; do # cleanup_tick 删的两个位置；stash 是 ensure_clone 收起的未提交进度
    if [[ -d "$d" ]] && { [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]] || [[ -n "$(git -C "$d" stash list 2>/dev/null)" ]] \
        || [[ -z "$(git -C "$d" branch -r --contains HEAD 2>/dev/null)" ]]; }; then
      supervisor_budget_park "$id" "$evidence (worktree has unpushed work; not sent to recut)" "$decision" "$park_reason" "$park_stage"; return 0
    fi
  done
  [[ -z "$pr" ]] || { supervisor_budget_park "$id" "$evidence (unit already has PR #$pr)" "$decision" "$park_reason" "$park_stage"; return 0; }
  [[ "$issue" =~ ^[0-9]+$ ]] || { supervisor_budget_park "$id" "$evidence" "$decision" "$park_reason" "$park_stage"; return 0; }
  if ! err="$(scheduler_route_to_recut "$issue" 2>&1 >/dev/null)"; then
    supervisor_budget_park "$id" "$evidence (recut route failed: ${err:0:200})" "$decision" "$park_reason" "$park_stage"; return 0
  fi
  note="$(js "$recut_reason without a PR; issue #$issue sent to recut: $evidence")"
  set_unit "$id" "$(hist "$recut_stage" "$evidence" "$decision") | .stage=\"closed\" | .note=$note"
  say "supervisor budget-recut unit=$id issue=#$issue: $evidence"
}

supervisor_needs_info() { # id question evidence —— needs-info：给提需求的人发一个澄清问题并打标签（唯一回到人的出口）
  local id="$1" question="$2" evidence="$3" issue pr decision posted=no
  issue="$(unit_field "$id" '.issue // empty')"; pr="$(unit_field "$id" '.pr // empty')"
  if [[ "$issue" =~ ^[0-9]+$ ]]; then
    if ! scheduler_issue_transition_allowed "$issue" needs-info supervisor-needs-info; then
      decision="$(decision_entry 'Needs-info transition unavailable' "issue #$issue cannot transition to needs-info from its current state" "$evidence" '["Post the question without the needs-info label"]' supervisor)"
      set_unit "$id" "$(hist supervisor-park "needs-info transition unavailable for issue #$issue" "$decision") | .stage=\"parked\" | .note=$(js "needs-info question not posted: issue #$issue cannot transition to needs-info")"
      say "supervisor needs-info unit=$id not posted=issue #$issue transition unavailable"
      return 0
    fi
    if gh issue comment "$issue" --body "工厂 supervisor 需要澄清：$question" >/dev/null 2>&1; then
      if ! scheduler_issue_transition "$issue" needs-info supervisor-needs-info; then
        posted="issue #$issue (question posted; needs-info transition failed)"
      else
        posted="issue #$issue"
      fi
    fi
  elif [[ "$pr" =~ ^[0-9]+$ ]] && gh pr comment "$pr" --body "工厂 supervisor 需要澄清：$question" >/dev/null 2>&1; then
    posted="PR #$pr"
  fi
  [[ "$posted" != no ]] || echo "[$STAMP] NEEDS-INFO-UNDELIVERED unit=$id no reachable issue/PR, question not posted: $question" >> "$A/alerts/state.md"
  decision="$(decision_entry 'Ask the requester one clarifying question' "$question" "$evidence" '["Escalate again without asking", "Arbitrate without the missing fact"]' supervisor)"
  set_unit "$id" "$(hist supervisor-needs-info "$question" "$decision") | .stage=\"needs-human\" | .note=$(js "needs-info: $question")"
  say "supervisor needs-info unit=$id posted=$posted"
}
# 被打回、BLOCK 或转人工的 PR head 不会原样合并：它排队中的 CI 先取消，runner 让给就绪与热修 PR
# （2026-10-20 22:42：112 个排队 job 里 46 个属于评审打回/转人工的单元，热修回迁 CI 排了 2 小时）。
# 热修单元不取消（BLOCK 后会原 head 重评）；之后被批准的 head 由合并车道重跑被取消的 run（ci_red）。
cancel_unit_runs() { # id reason
  local pr branch
  [[ "$(unit_field "$1" '.hotpatch // false')" == true ]] && return 0
  pr="$(unit_field "$1" '.pr // empty')"; [[ "$pr" =~ ^[0-9]+$ ]] || return 0
  branch="$(pr_view "$pr" headRefName)"
  cancel_branch_runs "$branch" "$2"
}

LIVE_WORKER_CACHE_UNTIL=0
LIVE_WORKER_CACHE_TOTAL=0
declare -A LIVE_WORKER_CACHE_TYPES=()
refresh_live_worker_cache() {
  local pid type
  LIVE_WORKER_CACHE_TOTAL=0; LIVE_WORKER_CACHE_TYPES=()
  while IFS=$'\t' read -r pid type; do
    [[ "$pid" =~ ^[0-9]+$ ]] && alive "$pid" || continue
    LIVE_WORKER_CACHE_TOTAL=$((LIVE_WORKER_CACHE_TOTAL + 1))
    LIVE_WORKER_CACHE_TYPES["$type"]=$((${LIVE_WORKER_CACHE_TYPES[$type]:-0} + 1))
  done < <(jqf -r '.workers[] | select(.harvested != true) | "\(.pid)\t\(.type)"' "$WORKERS")
  LIVE_WORKER_CACHE_UNTIL=$((SECONDS + 10))
}
live_by_type() {
  local n=0 type
  (( SECONDS < LIVE_WORKER_CACHE_UNTIL )) || refresh_live_worker_cache
  for type in "${!LIVE_WORKER_CACHE_TYPES[@]}"; do
    [[ "$type" =~ ^($1)$ ]] && n=$((n + LIVE_WORKER_CACHE_TYPES[$type]))
  done
  echo "$n"
}
live_workers() {
  (( SECONDS < LIVE_WORKER_CACHE_UNTIL )) || refresh_live_worker_cache
  echo "$LIVE_WORKER_CACHE_TOTAL"
}

USAGE_READER="$HERE/usage_reader.py"  # 当前 tick 固定的代码版本
BUDGET_EVENTS="$A/budget-events.json"  # 原生 codex turn 事件（provider/session/turn 幂等键）；codex-day 按同一路径推导
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

if [[ "$BUDGET_METER" != "sessions_dir" ]]; then
  echo "unsupported budget_meter=$BUDGET_METER (only sessions_dir is supported)" >&2
  exit 2
fi
if [[ "${1:-}" == "--update-budget-only" ]]; then
  update_budget
  exit $?
fi

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

unit_is_critical() {
  jqf -r 'if .critical == true then "true" else "false" end' <<<"$1"
}

has_critical_label() {
  jqf -e 'map(ascii_downcase) | index("critical") != null' <<<"${1:-[]}" >/dev/null
}

flush_focus_alert() {
  ((${#FOCUS_SKIPPED[@]} > 0)) || return 0
  local ids="" id candidate seen state="$A/focus-alert-state.json" last_ids last_epoch now
  local -a unique=()
  for id in "${FOCUS_SKIPPED[@]}"; do
    seen=false
    for candidate in ${unique[@]+"${unique[@]}"}; do [[ "$candidate" == "$id" ]] && seen=true; done
    [[ "$seen" == true ]] || unique+=("$id")
  done
  ids="$(printf '%s\n' "${unique[@]}" | LC_ALL=C sort | awk 'BEGIN{ORS=","}{print}')"
  ids="${ids%,}"
  now="${NOW_EPOCH:-$(date +%s)}"
  last_ids=""
  last_epoch=0
  if [[ -f "$state" ]]; then
    last_ids="$(jqf -r '.ids // empty' "$state" 2>/dev/null || true)"
    last_epoch="$(jqf -r '.epoch // 0' "$state" 2>/dev/null || true)"
  fi
  [[ "$last_epoch" =~ ^[0-9]+$ ]] || last_epoch=0
  if [[ "$ids" == "$last_ids" ]] && (( now - last_epoch < 1800 )); then return 0; fi
  echo "[$STAMP] focus: ${#unique[@]} units queued ($ids)" >> "$A/alerts/focus.md"
  jqf -cn --arg ids "$ids" --argjson epoch "$now" '{ids:$ids,epoch:$epoch}' > "$state.tmp" \
    && mv "$state.tmp" "$state"
}

# 会话按角色分开复用（L18 + 评审独立性）：rereview 只续评审会话，repair 只续修复会话。
session_role() { case "$1" in review|rereview) echo review ;; *) echo repair ;; esac; }

# ---------- 模型选择与提供方冷却 ----------
# 会话/用量上限、模型满载是提供方的暂时状态，不是 worker 缺陷：该提供方冷却 30 分钟，
# 期间该角色改用 models.<role>_fallback（若配置且其提供方未冷却），都不可用则不派发。
COOLDOWN="$A/cooldown.json"
# 只认提供方错误行的措辞，且只看日志尾部：worker 日志里满是代码/文档/测试输出（曾因技能说明里的
# "an overloaded word" 误判整个 codex 冷却 30 分钟）。
PROVIDER_LIMIT_RE='hit your (session|usage) limit|^ERROR: .*(at capacity|rate limit|usage limit|overloaded|quota)|overloaded_error|rate_limit_error|429 Too Many Requests'
provider_of() { [[ "$1" == claude-* ]] && echo claude || echo codex; }
cooling() { # provider → 成功(0) 表示仍在冷却
  local until; until="$(jqf -r --arg p "$1" '.[$p] // 0' "$COOLDOWN" 2>/dev/null)"
  [[ "$until" =~ ^[0-9]+$ ]] && (( until > NOW_EPOCH ))
}
start_cooldown() { # provider reason
  # 账号会话/用量上限按小时重置，冷却 30 分钟；模型满载/过载/429 是几分钟的瞬时状态，冷却 5 分钟
  # （10-22 一次 luna "at capacity" 让全部 codex worker 停了 30 分钟）。
  local min=30
  [[ "$2" =~ (hit\ your|usage\ limit|quota) ]] || min=5
  [[ -f "$COOLDOWN" ]] || echo '{}' > "$COOLDOWN"
  jqf --arg p "$1" --argjson u "$((NOW_EPOCH + min * 60))" '.[$p]=$u' "$COOLDOWN" | write_state "$COOLDOWN"
  echo "[$STAMP] PROVIDER-COOLDOWN provider=$1 ${min}min: $2" >> "$A/alerts/waste.md"
  say "provider $1 cooling down ${min}min: $2"
}
pick() { # role [unit-json] → PICK_MODEL/PICK_EFFORT；主模型提供方冷却时用 <role>_fallback；都不可用返回 1
  # 带 hotfix 标签的单元先用 models.<role>_hotfix（维护者 2026-10-29：生产热修单都给 terra high 做）。
  local key m keys=("$1" "$1_fallback")
  jqf -e 'any(.labels[]?; . == "hotfix")' <<<"${2:-"{}"}" >/dev/null 2>&1 && keys=("$1_hotfix" "${keys[@]}")
  for key in "${keys[@]}"; do
    m="$(jqf -r --arg k "$key" '.models[$k][0] // empty' <<<"$CFG")"
    [[ -n "$m" ]] || continue
    cooling "$(provider_of "$m")" && continue
    PICK_MODEL="$m"; PICK_EFFORT="$(jqf -r --arg k "$key" '.models[$k][1] // empty' <<<"$CFG")"
    return 0
  done
  say "no $1 model available (provider cooldown)"
  return 1
}

# Claude 评审 worker 的只读工具白名单（--permission-mode dontAsk：白名单外一律拒绝）。
CLAUDE_REVIEW_TOOLS="Read,Grep,Glob,Bash(cd:*),Bash(pwd),Bash(git fetch:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git rev-parse:*),Bash(git merge-base:*),Bash(git ls-remote:*),Bash(git status:*),Bash(git ls-files:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr checks:*),Bash(gh issue view:*),Bash(head:*),Bash(tail:*),Bash(wc:*),Bash(cat:*),Bash(ls:*),Bash(grep:*),Bash(rg:*),Bash(jq:*),Bash(sort:*),Bash(uniq:*)"

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
# 项目文档清单（用途|仓库相对路径），按项目填写；留空则不附读取范围规则，worker 照旧读项目指令。
# 例：'issue 跟踪文档|docs/issue-tracker.md'
WORKER_SKIPPED_DOCS=()
WORKER_ON_DEMAND_DOCS=()
worker_docs_text() { # 清单项（用途|路径）… → 用途（路径）、用途（路径）
  local entry out="" sep=""
  for entry in "$@"; do out+="${sep}${entry%%|*}（${entry#*|}）"; sep="、"; done
  printf '%s' "$out"
}
WORKER_READ_SCOPE_RULE="
【文档读取范围】调度器已在本提示里给出任务入口与交付命令，不要顺着项目路由表去读这些：$(worker_docs_text ${WORKER_SKIPPED_DOCS[@]+"${WORKER_SKIPPED_DOCS[@]}"})。分支交付预检只运行上面交付文字里写的脚本，不读它的说明文档；带 --publish-topic 的预检自己负责推送，不要再单独接一条 git push（输出经管道时会掩盖预检失败）。项目指令里与本任务有关的硬性边界已原文附在下面，不必为它翻路由表。$(worker_docs_text ${WORKER_ON_DEMAND_DOCS[@]+"${WORKER_ON_DEMAND_DOCS[@]}"})与目标包自己的 CLAUDE.md，只在改动触及该领域时读相关条目；教训只经教训目录定位，不全量读。"
# 项目指令里的硬性边界：每次装配提示时从目标仓库的 AGENTS.md（没有则 CLAUDE.md）取原文，这里不存副本。按关键词选行
# （同一行须全部出现，'|' 分隔），按项目填写；留空则不附读取范围规则。例：'tenant|isolation'
PRODUCT_BOUNDARY_SELECTORS=()
product_boundary_rule() { # 整块取得才输出；指令文件缺失或被改写到某组关键词消失，就什么都不输出并返回 1
  local kws lines block="" doc="$ROOT/AGENTS.md"
  (( ${#PRODUCT_BOUNDARY_SELECTORS[@]} )) || return 1
  [[ -f "$doc" ]] || doc="$ROOT/CLAUDE.md"
  for kws in "${PRODUCT_BOUNDARY_SELECTORS[@]}"; do
    lines="$(awk -v kws="$kws" 'BEGIN { n = split(kws, k, "|") }
      { for (i = 1; i <= n; i++) if (index($0, k[i]) == 0) next; print }' "$doc" 2>/dev/null)"
    [[ -n "$lines" ]] || return 1
    block+=$'\n'"$lines"
  done
  printf '\n【项目指令原文（硬性边界；路由表可以不读，这几条不能丢）】%s' "$block"
}
unit_lane_class() { # unit-json → product|pipeline-system|direct-main|main-red|hot-patch|unknown
  # pipeline-system 单元走 direct-main；NEEDS-PR 转到 PR 车道后仍是 pipeline-system。台账里没有的单元按 unknown 处理。
  jqf -r 'if (.id // null) == null then "unknown"
    elif .main_red == true then "main-red"
    elif .hotpatch == true then "hot-patch"
    elif .lane == "direct-main" then "direct-main"
    elif any((.history // [])[]?; .stage == "needs-pr") then "pipeline-system"
    elif .lane == "pr" then "product"
    else "unknown" end' <<<"$1"
}
worker_rules() { # unit-json type provider
  [[ "$3" == codex ]] || return 0
  printf '%s%s' "$WORKER_POLL_RULE" "$WORKER_LARGE_FILE_RULE"
  if [[ "$(unit_lane_class "$1")" == product && ( "$2" == implement || "$2" == repair ) ]]; then
    # 读取范围规则说"硬性边界已附在下面"：边界块取不到就不豁免路由表，worker 照旧读项目指令。
    local boundary
    if boundary="$(product_boundary_rule)"; then printf '%s%s' "$WORKER_READ_SCOPE_RULE" "$boundary"; fi
  fi
}

# models.<role> = [model, effort, service_tier?]；model 以 claude- 开头走 claude CLI，否则走 codex。
build_codex_command() { # type model effort unit cold-prompt [new-failure]
  local type="$1" model="$2" effort="$3" unit="$4" prompt="$5" failure="${6-$5}" session_id="" usage prompt_arg role tier self_fix prior
  local -a tier_args=()
  CODEX_MODE=fresh
  CODEX_SESSION_ID=""
  CODEX_PATH_REASON=initial
  WORKER_STDOUT_REPORT=0
  CODEX_USAGE_START='{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0}'
  prompt+="$(worker_rules "$(jqf -c --arg id "$unit" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")" "$type" "$(provider_of "$model")")"
  prompt_arg="$prompt"
  self_fix="$(unit_field "$unit" '.self_fix_active // false')"
  if [[ "$model" == claude-* ]]; then
    # Claude 评审只读：报告作为最终回答输出，由 dispatch 成功后落盘（不给写文件权限）。
    # --strict-mcp-config：不加载用户级 MCP 服务器（4 个评审曾拉起 426 个进程、2.5 GB 内存，且 chrome-devtools 会碰用户浏览器）。
    WORKER_STDOUT_REPORT=1
    CODEX_USAGE_START=null  # Claude is not measured by Codex cumulative counters.
    # 用户级 PreToolUse hook（rtk）把 git log/diff 改写成 rtk git …，白名单不匹配，dontAsk 全拒：评审 worker 不加载 hook。
    CODEX_COMMAND=(claude -p "$prompt_arg
（本次运行无写文件权限：把完整报告正文作为最终回答输出，调度器会原样落盘到上述报告路径。
当前目录就是评审目录：git 命令直接写「git diff ...」，不要加「-C <dir>」「--no-pager」，也不要「cd ... &&」（这些形式不匹配白名单会被拒）。可用命令（白名单外一律被拒）：git diff/log/show/fetch/rev-parse/merge-base/ls-files、gh pr view/diff/checks、gh issue view、head/tail/wc/cat/ls/grep/rg/jq/sort；优先用 Read/Grep 工具读代码。当前目录已是评审目录，直接执行单条命令即可。一条命令被拒只说明其中某一段不在白名单，不代表 Bash 不可用：拆成单条白名单命令重试，不要据此判定 INPUT_INCOMPLETE。）" \
      --settings '{"disableAllHooks":true}' --add-dir "$ENGINE_ROOT" \
      --model "$model" --effort "$effort" --permission-mode dontAsk --strict-mcp-config \
      --tools "Read,Grep,Glob,Bash" --allowedTools "$CLAUDE_REVIEW_TOOLS")
    return 0
  fi
  tier="$(jqf -r --arg m "$model" '[.models[] | select(.[0]==$m) | .[2] // empty][0] // empty' <<<"$CFG")"
  [[ -n "$tier" ]] && tier_args=(--config "service_tier=\"$tier\"")
  # Persistent implementer sessions: never add --ephemeral here.
  CODEX_FRESH_COMMAND=(codex exec -m "$model" -c "model_reasoning_effort=$effort" ${tier_args[@]+"${tier_args[@]}"} "${CODEX_ENV_ARGS[@]}" \
    -s danger-full-access --json "$prompt_arg")
  if [[ "$type" == repair ]]; then
    prior="$(unit_field "$unit" '.sessions.repair // {}')"
    session_id="$(jqf -r '.id // empty' <<<"$prior")"
    CODEX_PATH_REASON=no-recorded-session
    if [[ "$session_id" =~ $SESSION_RE ]]; then
      if [[ "$(jqf -r '.provider // empty' <<<"$prior")" != codex ]]; then
        CODEX_PATH_REASON=provider-changed
      elif [[ "$(jqf -r '.model // empty' <<<"$prior")" != "$model" ]]; then
        CODEX_PATH_REASON=model-changed
      elif [[ -z "$(session_file_for_id "$session_id")" ]]; then
        CODEX_PATH_REASON=session-files-missing
      elif [[ -z "$failure" ]]; then
        CODEX_PATH_REASON=no-new-failure
      elif [[ "$self_fix" != true ]] && ! { usage="$(session_tokens_for_id "$session_id")"; [[ "$usage" =~ ^[0-9]+$ ]] && (( usage < 8000000 )); }; then
        # Same cumulative-raw cutoff as rereview (a repair chain keeps growing one session); a self-fix always continues.
        CODEX_PATH_REASON=session-too-large
      else
        CODEX_MODE=resume
        CODEX_PATH_REASON=same-provider-model
        CODEX_SESSION_ID="$session_id"
        CODEX_USAGE_START="$(session_usage_for_id "$session_id")"
        CODEX_COMMAND=(codex exec -s danger-full-access resume "$session_id" -m "$model" \
          -c "model_reasoning_effort=$effort" ${tier_args[@]+"${tier_args[@]}"} "${CODEX_ENV_ARGS[@]}" --json "$failure")
        return 0
      fi
    fi
  fi
  if [[ "$type" == "rereview" ]]; then
    role="$(session_role "$type")"
    session_id="$(jqf -r --arg id "$unit" --arg role "$role" '[.units[] | select(.id==$id) | .session_ids[$role] // empty][0] // empty' "$UNITS")"
    if [[ "$session_id" =~ $SESSION_RE ]]; then
      local snapshot; snapshot="$(session_usage_for_id "$session_id")"
      usage="$(jqf -r 'if .==null then empty else .raw end' <<<"$snapshot")"
      # 阈值比累计 raw（input+output），不比 fresh：9M raw 而 fresh 只有 0.3M 的会话仍要冷启动；按 fresh 比会让
      # 500 个可续的修复派发里 464 个改成续会话。
      if [[ "$self_fix" == true ]] || { [[ "$usage" =~ ^[0-9]+$ ]] && (( usage < 8000000 )); }; then
        CODEX_MODE=resume
        CODEX_SESSION_ID="$session_id"
        CODEX_USAGE_START="$snapshot"
        prompt_arg="继续沿用本会话已有上下文，仅处理本次增量任务，不重读未变化背景：$prompt"
        CODEX_COMMAND=(codex exec -s danger-full-access resume "$session_id" -m "$model" \
          -c "model_reasoning_effort=$effort" ${tier_args[@]+"${tier_args[@]}"} "${CODEX_ENV_ARGS[@]}" --json "$prompt_arg")
        return 0
      fi
    fi
  fi
  # A deterministic self-fix must never silently switch to a fresh worker.
  [[ "$self_fix" == true ]] && return 1
  # --json（两种模式一致）：stdout 变为 JSONL 事件流（thread.started / turn.completed 用量），worker 日志即事件源，
  # 回收时由 usage_reader 落进原生事件库；人类可读输出只在非 --json 模式存在，legacy 日志的页脚解析保留给旧 worker。
  CODEX_COMMAND=("${CODEX_FRESH_COMMAND[@]}")
}

# 每个单元独占一个隔离 clone（L8：worker 不进主 checkout）；clone 放磁盘而非 tmpfs /tmp。
# branch 为空 → detached 于最新 origin/main；require_remote=1 时分支必须已在 origin（repair）。
# 目标提交在调度器自己的对象库里就从 $ROOT 取，没有或对不上才走 GitHub；worker clone 的 origin 仍是 GitHub URL。
fetch_local_first() { # dir ref-in-ROOT dest-ref-in-dir want-sha
  local dir="$1" src="$2" dest="$3" want="$4"
  [[ "$want" =~ $SHA_RE ]] || return 1
  [[ "$(git -C "$ROOT" rev-parse -q --verify "$src^{commit}" 2>/dev/null)" == "$want" ]] || return 1
  git -C "$dir" fetch -q --no-tags "$ROOT" "+$src:$dest" 2>/dev/null \
    && [[ "$(git -C "$dir" rev-parse -q --verify "$dest^{commit}" 2>/dev/null)" == "$want" ]]
}
PRODUCT_LANE_SKILLS="$HERE/product-lane-skills.txt"
product_lane_sparse() { # dir（git clone --sparse 之后）：工作树 = 全部文件 减去 .agents/skills/ 下不在固定清单里的技能（git 2.47 非 cone 模式）
  { printf '/*\n!/.agents/skills/*\n'; sed -n 's|^\(\.agents/skills/[^#[:space:]]*\)$|/\1/|p' "$PRODUCT_LANE_SKILLS"; } \
    | git -C "$1" sparse-checkout set --no-cone --stdin
}
ensure_clone() { # id [branch] [require_remote] [branch-head-sha] [base-branch] [base-sha] [local-only]
  local id="$1" branch="${2:-}" require_remote="${3:-0}" want="${4:-}" base_branch="${5:-}" base_sha="${6:-}" local_only="${7:-false}" dir="$WT_ROOT/wt-$1" origin_url fresh=0 base_ref branch_ref_ok=0 branch_head
  origin_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || return 1
  if [[ ! -d "$dir/.git" ]]; then
    # 产品车道的新 clone 只留固定技能清单：技能列表占每次调用静态前缀的 16%，13-16 个技能之外从不被碰。
    # 只在创建时决定、之后绝不改动活 clone，续会话因此不会丢历史里点名的技能。
    local sparse=()
    [[ "$(unit_lane_class "$(jqf -c --arg id "$id" '.units[] | select(.id==$id)' "$UNITS" 2>/dev/null)")" == product ]] \
      && grep -q '^\.agents/skills/' "$PRODUCT_LANE_SKILLS" 2>/dev/null && sparse=(--sparse)
    mkdir -p "$WT_ROOT" && git clone -q ${sparse[@]+"${sparse[@]}"} "$ROOT" "$dir" && git -C "$dir" remote set-url origin "$origin_url" \
      && { [[ -z "${sparse[*]:-}" ]] || product_lane_sparse "$dir"; } \
      || { rm -rf -- "$dir"; return 1; }
    fresh=1
  fi
  # A shallow scheduler checkout makes a local worker clone unable to prove that the prior
  # reviewed head is an ancestor of the repaired head; targeted re-review then falls back to a
  # full review. Restore history only for shallow worker clones; if unavailable, full review is safe.
  if [[ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null)" == true ]]; then
    git -C "$dir" fetch -q --unshallow "$ROOT" 2>/dev/null || true
    if [[ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null)" == true ]]; then
      [[ "$local_only" != true ]] || return 1
      git -C "$dir" fetch -q --unshallow origin 2>/dev/null || true
    fi
  fi
  if [[ "$local_only" == true ]]; then
    fetch_local_first "$dir" refs/remotes/origin/main refs/remotes/origin/main "$MAIN_HEAD" || return 1
  else
    fetch_local_first "$dir" refs/remotes/origin/main refs/remotes/origin/main "$MAIN_HEAD" \
      || git -C "$dir" fetch -q origin main || return 1
  fi
  if (( ! fresh )) && [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
    git -C "$dir" stash push -u -q -m "autopilot: kept before redispatch $STAMP" || return 1
  fi
  if [[ -n "$base_branch" ]]; then
    [[ "$base_sha" =~ $SHA_RE ]] || return 1
    base_ref="refs/remotes/origin/$base_branch"
    if [[ "$local_only" == true ]]; then
      fetch_local_first "$dir" "$base_ref" "$base_ref" "$base_sha" || return 1
    else
      fetch_local_first "$dir" "$base_ref" "$base_ref" "$base_sha" \
        || git -C "$dir" fetch -q origin "+refs/heads/$base_branch:$base_ref" 2>/dev/null || return 1
    fi
    [[ "$(git -C "$dir" rev-parse -q --verify "$base_ref^{commit}" 2>/dev/null)" == "$base_sha" ]] || return 1
  fi
  if [[ -z "$branch" ]]; then
    git -C "$dir" checkout -q --detach refs/remotes/origin/main || return 1
  else
    if [[ "$local_only" == true ]]; then
      branch_head="$(git -C "$ROOT" rev-parse -q --verify "refs/remotes/origin/$branch^{commit}" 2>/dev/null || true)"
      if [[ "$branch_head" =~ $SHA_RE && ( -z "$want" || "$branch_head" == "$want" ) ]] \
        && fetch_local_first "$dir" "refs/remotes/origin/$branch" "refs/remotes/origin/$branch" "$branch_head"; then
        branch_ref_ok=1
      fi
    elif fetch_local_first "$dir" "refs/remotes/origin/$branch" "refs/remotes/origin/$branch" "$want" \
      || git -C "$dir" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null; then
      branch_ref_ok=1
    fi
    if (( branch_ref_ok )); then
      # 本地分支领先 origin（上一轮已提交未推送）时保留它；分叉时先留备份 ref 再对齐 origin，提交不丢。
      if git -C "$dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null \
        && git -C "$dir" merge-base --is-ancestor "refs/remotes/origin/$branch" "refs/heads/$branch"; then
        git -C "$dir" checkout -q "$branch" || return 1
      else
        git -C "$dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null \
          && git -C "$dir" update-ref "refs/autopilot-kept/$branch-$TAG" "refs/heads/$branch"
        git -C "$dir" checkout -q -B "$branch" "refs/remotes/origin/$branch" || return 1
      fi
    elif [[ "$require_remote" == 1 ]]; then
      return 1
    elif git -C "$dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
      # 从未 push 的本地分支（无 PR 的直落单元）：保留它的本地提交，不重置回 main。
      git -C "$dir" checkout -q "$branch" || return 1
    elif [[ -n "$base_branch" ]]; then
      git -C "$dir" checkout -q -B "$branch" "$base_ref" || return 1
    else
      git -C "$dir" checkout -q -B "$branch" refs/remotes/origin/main || return 1
    fi
  fi
  printf '%s' "$dir"
}

# Transfer the exited owner's committed and uncommitted work into the normal
# isolated scheduler clone; never mutate or remove the original worktree.
handoff_worktree_clone() { # id branch old-worktree old-head dirty [require-remote] [rescued-ref] [rescued-sha] [stack-ref] [stack-sha]
  local id="$1" branch="$2" old_tree="$3" old_head="$4" dirty="$5" require_remote="${6:-0}" old_ref="${7:-}" rescue_sha="${8:-$4}" dir patch files current path handoff_head status=0
  local stack_ref="${9:-}" stack_sha="${10:-}"
  local heads=( "$old_head" )
  [[ "$old_head" =~ $SHA_RE ]] || return 1
  dir="$(ensure_clone "$id" "$branch" "$require_remote")" || return 1
  if [[ -n "$old_tree" || -z "$old_ref" || "$old_head" != "$rescue_sha" ]]; then
    git -C "$dir" fetch -q "$ROOT" "$old_head" || return 1
  fi
  if [[ -n "$old_ref" ]]; then
    [[ "$rescue_sha" =~ $SHA_RE ]] || return 1
    fetch_local_first "$dir" "refs/remotes/origin/$old_ref" "refs/remotes/origin/$old_ref" "$rescue_sha" \
      || git -C "$dir" fetch -q origin "+refs/heads/$old_ref:refs/remotes/origin/$old_ref" || return 1
    [[ "$(git -C "$dir" rev-parse --verify "refs/remotes/origin/$old_ref^{commit}")" == "$rescue_sha" ]] || return 1
    [[ "$rescue_sha" == "$old_head" ]] || heads+=( "$rescue_sha" )
  fi
  if [[ -n "$stack_ref" ]]; then
    [[ "$stack_sha" =~ $SHA_RE ]] || return 1
    fetch_local_first "$dir" "refs/remotes/origin/$stack_ref" "refs/remotes/origin/$stack_ref" "$stack_sha" \
      || git -C "$dir" fetch -q origin "+refs/heads/$stack_ref:refs/remotes/origin/$stack_ref" || return 1
    [[ "$(git -C "$dir" rev-parse --verify "refs/remotes/origin/$stack_ref^{commit}")" == "$stack_sha" ]] || return 1
    heads+=( "$stack_sha" )
  fi
  for handoff_head in "${heads[@]}"; do
    current="$(git -C "$dir" rev-parse --verify HEAD)" || return 1
    if git -C "$dir" merge-base --is-ancestor "$handoff_head" "$current"; then
      : # The branch already contains this handoff commit.
    elif git -C "$dir" merge-base --is-ancestor "$current" "$handoff_head"; then
      git -C "$dir" checkout -q -B "$branch" "$handoff_head" || return 1
    else
      # Keep the existing branch, owner commit and rescue when they diverge.
      if ! git -C "$dir" -c user.name=zenoforge-agent -c user.email=zenoforge-agent@users.noreply.github.com merge -q --no-edit "$handoff_head"; then
        git -C "$dir" merge --abort >/dev/null 2>&1 || true
        return 73
      fi
    fi
  done
  if [[ "$dirty" == true ]]; then
    [[ -d "$old_tree" && "$(git -C "$old_tree" rev-parse --verify HEAD 2>/dev/null)" == "$old_head" ]] || return 73
    patch="$(mktemp)" || return 1
    files="$(mktemp)" || { rm -f "$patch"; return 1; }
    git -C "$old_tree" diff --binary HEAD > "$patch" || status=$?
    if (( status == 0 )) && [[ -s "$patch" ]]; then git -C "$dir" apply --binary "$patch" || status=73; fi
    if (( status == 0 )); then git -C "$old_tree" ls-files --others --exclude-standard -z > "$files" || status=$?; fi
    if (( status == 0 )) && [[ -s "$files" ]]; then
      while IFS= read -r -d '' path; do
        if [[ -e "$dir/$path" || -L "$dir/$path" ]]; then
          say "handoff unit=$id: untracked owner file conflicts with $path in scheduler clone"
          status=73
          break
        fi
      done < "$files"
      if (( status == 0 )); then
        (set -o pipefail; tar -C "$old_tree" --null -T "$files" -cf - | tar -C "$dir" -xf -) || status=73
      fi
    fi
    # Anchor the exact dirty and untracked content in history before a worker
    # can report success. An unrelated push must not make it disappear.
    if (( status == 0 )); then git -C "$dir" add -u || status=$?; fi
    if (( status == 0 )) && [[ -s "$files" ]]; then
      git -C "$dir" --literal-pathspecs add -f --pathspec-from-file="$files" --pathspec-file-nul || status=$?
    fi
    rm -f "$patch" "$files"
    (( status == 0 )) || return "$status"
    if ! git -C "$dir" diff --cached --quiet; then
      git -C "$dir" -c user.name=zenoforge-agent -c user.email=zenoforge-agent@users.noreply.github.com \
        commit -q -m "preserve handoff work for $id" -m 'Co-Authored-By: Codex <codex@openai.com>' || return 1
    fi
  fi
  printf '%s' "$dir"
}

record_handoff_integration() { # unit clone observed-PR-head
  local id="$1" dir="$2" original="$3" sha
  sha="$(git -C "$dir" rev-parse --verify HEAD)" || return 1
  [[ "$sha" =~ $SHA_RE ]] || return 1
  [[ -z "$original" || "$original" =~ $SHA_RE ]] || return 1
  set_unit "$id" ".handoff_integration_sha=$(js "$sha") | .handoff_original_pr_head=$(js "$original") | .handoff_delivery_verified_sha=null | if .handoff_worktree_sha != null then .handoff_worktree_applied=true else . end | if .handoff_start_ref != null then .handoff_start_applied=true else . end"
}

resume_handoff_integration() { # unit clone: preserve the recorded snapshot if the PR moved
  local id="$1" dir="$2" sha
  sha="$(unit_field "$id" '.handoff_integration_sha // empty')"
  [[ -n "$sha" ]] || return 0
  git -C "$dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null && return 0
  if git -C "$dir" -c user.name=zenoforge-agent -c user.email=zenoforge-agent@users.noreply.github.com merge -q --no-edit "$sha"; then return 0; fi
  git -C "$dir" merge --abort >/dev/null 2>&1 || true
  to_supervisor "$id" "handoff snapshot conflicts with the updated branch; inspect the preserved work"
  return 1
}

verify_handoff_delivery() { # unit PR branch reviewed-candidate
  local id="$1" pr="$2" branch="$3" candidate="$4" integrated original dirty dir
  integrated="$(unit_field "$id" '.handoff_integration_sha // empty')"
  [[ -n "$integrated" ]] || return 0
  [[ "$(unit_field "$id" '.handoff_delivery_verified_sha // empty')" != "$candidate" ]] || return 0
  original="$(unit_field "$id" '.handoff_original_pr_head // empty')"
  dirty="$(unit_field "$id" '.handoff_worktree_dirty // false')"
  dir="$WT_ROOT/wt-$id"
  if [[ "$dirty" == true && -n "$original" && "$candidate" == "$original" ]]; then
    to_supervisor "$id" "handoff repair did not deliver the preserved uncommitted work"
    return 1
  fi
  if [[ "$pr" =~ ^[0-9]+$ ]]; then
    git -C "$dir" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || return 1
  fi
  if ! git -C "$dir" merge-base --is-ancestor "$integrated" "$candidate" 2>/dev/null; then
    to_supervisor "$id" "handoff repair did not deliver the preserved commit history"
    return 1
  fi
  set_unit "$id" ".handoff_delivery_verified_sha=$(js "$candidate")"
}

# 评审 clone 检出被评审的 PR head：评审读的就是要合并的代码，diff 走本地 git，不依赖网络 API。
checkout_pr_head() { # dir pr candidate-sha observed-pr-head（candidate 可以是该 head 的本地修复后代）
  [[ -z "$2" ]] && { git -C "$1" checkout -q --detach "$3"; return; }
  local fetched_head
  git -C "$1" fetch -q origin "refs/pull/$2/head" \
    && fetched_head="$(git -C "$1" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)" \
    && [[ "$fetched_head" == "$4" ]] \
    && git -C "$1" checkout -q --detach "$3"
}

dispatch() { # type model effort unit log report prompt [sha] [workdir] [pr-head] [new-failure]
  local type="${1:-}" model="${2:-}" effort="${3:-}" unit="${4:-}" log="${5:-}" report="${6:-}" prompt="${7:-}" sha="${8:-}" workdir="${9:-$ROOT}" pr_head="${10:-}" pid cache_fresh=false cache_until="$LIVE_WORKER_CACHE_UNTIL"
  local -a launcher=() worker_env=()
  (( SECONDS < LIVE_WORKER_CACHE_UNTIL )) && cache_fresh=true
  if [[ "$(unit_field "$unit" '.lane // empty')" == direct-main ]]; then
    worker_env=(env ZF_NON_PRODUCT_UNIT=1 "ZF_PIPELINE_UNIT=$unit" \
      "PATH=$ROOT/engine/non-product-test-shim:$PATH")
  fi
  # setsid：worker 自成进程组，超时可整组终止（含 codex 子进程）。
  command -v setsid >/dev/null 2>&1 && launcher=(setsid)
  build_codex_command "$type" "$model" "$effort" "$unit" "$prompt" "${11-$prompt}" || return 1
  if [[ "${WORKER_STDOUT_REPORT:-0}" == 1 ]]; then
    # stdout 即报告：只有成功退出且非空才落盘，失败/中断不会留下可被回收的半截报告。
    (cd "$workdir" && GIT_PAGER=cat PAGER=cat exec ${worker_env[@]+"${worker_env[@]}"} ${launcher[@]+"${launcher[@]}"} bash -c 'out="$1"; shift; "$@" > "$out.partial" && [ -s "$out.partial" ] && mv -f "$out.partial" "$out"' \
      autopilot-worker "$SUP/$report" "${CODEX_COMMAND[@]}") > "$SUP/$log" 2>&1 < /dev/null &
  elif [[ "$type" == repair && "$CODEX_MODE" == resume ]]; then
    (cd "$workdir" && exec ${worker_env[@]+"${worker_env[@]}"} ${launcher[@]+"${launcher[@]}"} bash "$CODEX_REPAIR_RUNNER" "$SUP/$log" "$CODEX_SESSION_ID" \
      "${#CODEX_FRESH_COMMAND[@]}" "${CODEX_FRESH_COMMAND[@]}" "${CODEX_COMMAND[@]}") > "$SUP/$log" 2>&1 < /dev/null &
  else
    (cd "$workdir" && jq -cn --arg mode "$CODEX_MODE" --arg reason "$CODEX_PATH_REASON" \
      '{type:"pipeline.execution",mode:$mode,reason:$reason}' && exec ${worker_env[@]+"${worker_env[@]}"} ${launcher[@]+"${launcher[@]}"} "${CODEX_COMMAND[@]}") > "$SUP/$log" 2>&1 < /dev/null &
  fi
  pid=$!
  local w; w="$(jqf -cn --argjson pid "${pid:-0}" --arg unit "$unit" --arg type "$type" --arg log "$log" --arg report "$report" --arg at "$STAMP" --arg mode "$CODEX_MODE" --arg session_id "$CODEX_SESSION_ID" --arg sha "$sha" --arg pr_head "$pr_head" --arg workdir "$workdir" --arg model "$model" --argjson usage_start "$CODEX_USAGE_START" \
    '{pid:$pid,unit:$unit,type:$type,log:$log,report:$report,started:$at,mode:$mode,session_id:$session_id,sha:$sha,pr_head:$pr_head,workdir:$workdir,model:$model,token_usage_start:$usage_start}')"
  jqf --argjson w "$w" '.workers += [$w]' "$WORKERS" | write_state "$WORKERS"
  if [[ "$cache_fresh" == true ]] && (( SECONDS < cache_until )) && alive "$pid"; then
    LIVE_WORKER_CACHE_TOTAL=$((LIVE_WORKER_CACHE_TOTAL + 1))
    LIVE_WORKER_CACHE_TYPES["$type"]=$((${LIVE_WORKER_CACHE_TYPES[$type]:-0} + 1))
    LIVE_WORKER_CACHE_UNTIL=$((SECONDS + 10))
  fi
  say "dispatch mode=$CODEX_MODE reason=$CODEX_PATH_REASON pid=$pid type=$type unit=$unit"
}

critical_pending_count() {
  jqf '[.units[] | select(.critical==true) | select(.stage=="implement-pending" or .stage=="review-pending" or .stage=="repair-pending" or .stage=="rereview-pending")] | length' "$UNITS" 2>/dev/null || echo 0
}

# #4190/#4192/#4193 wrote the same 8k-line hook concurrently. Triage already
# persists expected_paths; use its existing selector and overlap predicate, not
# a second package/path matcher. The common library stays in a subshell.
SCHEDULER_AGENT_LIB="$ROOT/engine/lib.sh"
if [[ ! -r "$SCHEDULER_AGENT_LIB" ]]; then
  SCHEDULER_AGENT_LIB="${ZF_EXECUTION_MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}/lib.sh"
fi
scheduler_jq_arg_file() (
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  jq_arg_file "$1"
)
scheduler_issue_intake_parent_reason() (
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCHEDULER_AGENT_LIB" || return 2
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"
  issue_intake_parent_reason "$@"
)
scheduler_jq_arg_file() (
  REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCHEDULER_AGENT_LIB" || return 1
  jq_arg_file "$1"
)
scheduler_issue_transition() ( # issue stage reason：通过 lib.sh 的唯一 stage-label writer
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"
  issue_transition "$@"
)
scheduler_route_to_recut() ( # issue：lib.sh 的唯一 needs-recut 入口
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"
  # on-hold 或 pipeline-system 的 issue 不会落到 needs-recut：只有真进了 recut 队列才算成功。
  route_to_recut "$1" || return 1
  [[ "$(state_read "$1" | jq -r '.state // empty')" == needs-recut ]] || { echo "issue #$1 routed to $(state_read "$1" | jq -r '.state // "unknown"'), not needs-recut" >&2; return 1; }
)
scheduler_issue_transition_allowed() ( # issue stage reason：先验证当前持久状态能否完成 label 转移
  local issue="$1" to="$2" reason="$3" before from
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  before="$(state_read "$issue")" || return 1
  from="$(jqf -r '.state // "untracked"' <<<"$before")" || return 1
  if [[ "$to" == needs-info ]] && jqf -e '.tracker_parent == true or .state == "tracker"' <<<"$before" >/dev/null 2>&1; then
    return 1
  fi
  issue_transition_allowed "$from" "$to" "$reason"
)
scheduler_conclude_merged_pr() ( # issue pr：合入即写发布状态（#4515 单一事实源）
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"

  conclude_merged_run "$1" "$2" "PR #$2 was merged by the autopilot merge lane. Waiting on Postsubmit validate before release."
)
scheduler_issue_state() (
  local f lock_fd
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  f="$(state_file "$1")" || return 1
  # issue_transition writes state before the label and rolls back on failure.
  # Defer reconciliation while that transaction is in progress.
  mkdir -p "$STATE_DIR" || return 1
  exec {lock_fd}>"$f.lock" || return 1
  flock -sn "$lock_fd" || return 1
  state_read "$1"
)
scheduler_size_recut_active() (
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 0
  stage_unit_active recut "$1"
)
scheduler_size_recut() ( # issue lines limit unit branch head → one durable recut route
  local preserved_gh="" evidence
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"
  evidence="$(jq -cn --argjson lines "$2" --argjson limit "$3" --arg unit "$4" --arg branch "$5" --arg head "$6" '{kind:"size-admission",lines:$lines,limit:$limit,unit:$unit,branch:$branch,head:$head}')"
  route_to_recut "$1" "" "$evidence" || return 1
  state_read "$1" | jq -e '.state == "needs-recut" and .size_admission.lines > .size_admission.limit' >/dev/null
)
scheduler_footprint() (
  local u="$1" state issue actual
  if [[ "$(jq -r '.footprint_source // empty' <<<"$u")" == pr-diff ]] \
    && jq -e '(.footprint | type) == "array"' <<<"$u" >/dev/null; then
    jq -c '.footprint' <<<"$u"; return
  fi
  # Older units kept the triage package prediction beside #4510's write-end
  # record. Once a worker has produced a PR diff, that actual file set is the
  # scope for its next repair and for other units checking the active worker.
  actual="$(jq -r '[.history[]? | select(.stage=="write-end") | .result] | last // empty' <<<"$u")"
  if jq -e 'type == "array"' <<<"$actual" >/dev/null 2>&1; then
    jq -c . <<<"$actual"; return
  fi
  if jq -e 'has("footprint")' <<<"$u" >/dev/null; then jq -c '.footprint' <<<"$u"; return; fi
  REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$SCHEDULER_AGENT_LIB" || return 1
  issue="$(jq -r '.issue // empty' <<<"$u")"
  state="$(cat "$STATE_DIR/$issue.json" 2>/dev/null)"; [[ -n "$state" ]] || state='{}'
  if jq -e '(.footprint // []) | length > 0' <<<"$u" >/dev/null; then
    jq -c '.footprint' <<<"$u"
  elif jq -e '([.expected_paths[]?, .expected_packages[]?] | length) > 0' <<<"$state" >/dev/null; then
    selection_scope_json <<<"$state"
  else
    issue_change_surface_json "$u" "$(jq -r '.task // ""' <<<"$u")" '[]'
  fi
)
# #4488: 预测足迹挡不住在跑 worker 越界写共享文件（collisions_per_day=97，全是真实并发写）。
# 派发检查把在跑 unit 的 worktree 里已发生的改动（已提交 + 未提交 + 未跟踪）并进它的足迹。
live_writes_union() { # workdir scope_json -> scope ∪ 实际已写路径；workdir 不可读时退回预测
  local wd="$1" scope="$2" live base
  if [[ -n "$wd" && -d "$wd" ]]; then
    base="$(git -C "$wd" merge-base origin/main HEAD 2>/dev/null || true)"
    live="$(
      {
        if [[ -n "$base" ]]; then
          timeout --kill-after=1s 3s git -C "$wd" diff --no-renames --name-only -z "$base" || true
        else
          timeout --kill-after=1s 3s git -C "$wd" diff --no-renames --name-only -z HEAD || true
        fi
        timeout --kill-after=1s 3s git -C "$wd" ls-files --others --exclude-standard -z || true
      } | jq -Rsc '[splits("\u0000") | select(length>0)]'
    )"
    scope="$(jq -cn --argjson scope "$scope" --argjson live "$live" '($scope + $live) | unique')"
  fi
  printf '%s\n' "$scope"
}
resolve_active_footprints() { # active-unit JSON array → fresh live scopes; scan worktrees concurrently, persist ledger changes once
  local active="$1" scan_dir other file scope workdir rows updates resolved rc=0 index=0 pid
  local -a pids=()
  scan_dir="$(mktemp -d)" || return 1
  while IFS= read -r other; do
    [[ -n "$other" ]] || continue
    file="$scan_dir/$index.json"
    {
      local other_scope other_workdir
      other_scope="$(scheduler_footprint "$other")" || exit 1
      other_workdir="$(jq -r '.live_workdir // empty' <<<"$other")"
      other_scope="$(live_writes_union "$other_workdir" "$other_scope")" || exit 1
      jq -cn --argjson unit "$other" --argjson scope "$other_scope" \
        '$unit + {resolved_footprint:$scope}' > "$file"
    } &
    pids+=("$!")
    index=$((index + 1))
  done < <(jq -c '.[]' <<<"$active")
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  if (( rc != 0 )); then rm -rf -- "$scan_dir"; return 1; fi
  rows="$(cat "$scan_dir"/*.json | jqf -cs '.')" || { rm -rf -- "$scan_dir"; return 1; }
  updates="$(jqf -c '[.[] | select((.footprint // []) != .resolved_footprint) | {id, footprint:.resolved_footprint}]' <<<"$rows")" \
    || { rm -rf -- "$scan_dir"; return 1; }
  if jqf -e 'length > 0' <<<"$updates" >/dev/null; then
    units_update --argjson updates "$updates" \
      '.units |= map(. as $unit
        | ([$updates[] | select(.id == $unit.id)][0] // null) as $update
        | if $update == null then . else .footprint = $update.footprint end)' \
      || { rm -rf -- "$scan_dir"; return 1; }
  fi
  resolved="$(jqf -c 'map(. + {footprint:.resolved_footprint} | del(.resolved_footprint, .live_workdir))' <<<"$rows")" \
    || { rm -rf -- "$scan_dir"; return 1; }
  rm -rf -- "$scan_dir"
  printf '%s\n' "$resolved"
}
declare -A TICK_FOOTPRINT_CACHE=()
# #4488 第二轮（spec #4495 的类级解法）：预测足迹本身也看不准，共享测试文件和
# 运行时热点是和历史共同修改耦合的。派发检查前把窗口内与预测文件同提交
# 出现过的热点文件（每提交每文件计一次，共同修改 ≥2 次，取次数前 12）并进
# 待派发 unit 的检查范围；命中在跑 worker 就先排队。扩展只在检查时计算，
# 不写进 .footprint——活跃足迹仍是 #4510 的预测 ∪ 实际写入，避免逐 tick 累积。
hotspot_log() { # 窗口内提交的文件分组清单，每 scheduler 进程取一次
  if [[ -z "${HOTSPOT_LOG:-}" ]]; then
    HOTSPOT_LOG="$(timeout --kill-after=1s 4s git -C "$ROOT" log --since=30.days --no-merges --no-renames --name-only --format=%x01 2>/dev/null || true)"
  fi
  printf '%s' "$HOTSPOT_LOG"
}
hotspot_expand() { # scope_json -> scope ∪ 共同修改热点；历史读不出来时退回原足迹
  local scope="$1" added
  added="$(hotspot_log | jq -Rsc --argjson scope "$scope" '
    def in_scope: . as $f | any($scope[]; . as $s | $s == $f or ($f | startswith($s + "/")));
    [ split("\u0001")[]
      | split("\n") | map(select(length > 0)) | unique
      | select(length > 1 and length <= 40)
      | select(any(.[]; in_scope))
      | .[] | select(in_scope | not)
    ] | group_by(.) | map(select(length >= 2) | {f: .[0], n: length})
      | sort_by(-.n) | .[:12] | map(.f) | unique
  ' 2>/dev/null || true)"
  if [[ -n "$added" && "$added" != '[]' ]]; then
    scope="$(jq -cn --argjson scope "$scope" --argjson add "$added" '($scope + $add) | unique')"
  fi
  printf '%s\n' "$scope"
}
footprint_room() {
  local id="$1" u="${2:-}" scope active conflict check_scope
  # f9 kill switch（M2 故障注入 #4498）：footprint_mutex.enabled=false 跳过互斥。
  # 关掉后不再产生 "footprint wait" 事件，mechanism.silent 会在登记的沉默上限内报出。
  [[ "$(jqf -r 'if .footprint_mutex.enabled == false then "false" else "true" end' <<<"$CFG")" == true ]] || return 0
  [[ -n "$u" ]] || u="$(jqf -c --arg id "$id" '.units[] | select(.id==$id)' "$UNITS")"
  scope="$(scheduler_footprint "$u")" || return 1
  if [[ -n "${TICK_FOOTPRINT_CACHE[$id]+cached}" ]]; then
    [[ "${TICK_FOOTPRINT_CACHE[$id]}" == "$scope" ]] || set_unit "$id" ".footprint=$scope"
  else
    [[ "$(jqf -c '.footprint // []' <<<"$u")" == "$scope" ]] || set_unit "$id" ".footprint=$scope"
  fi
  TICK_FOOTPRINT_CACHE["$id"]="$scope"
  active="$(jqf -c --arg id "$id" --slurpfile w "$WORKERS" '
    [.units[] | select(.id!=$id) | . as $u
      | select(any($w[0].workers[]; .unit==$u.id and .harvested!=true and (.type | IN("implement","repair"))))
      | . + {live_workdir: ([$w[0].workers[] | select(.unit==$u.id and .harvested!=true and (.type | IN("implement","repair"))) | .workdir] | first)}]' "$UNITS")"
  [[ "$active" == '[]' ]] && return 0
  active="$(resolve_active_footprints "$active")" || return 1
  check_scope="$(hotspot_expand "$scope")"
  conflict="$(
    REPO_DIR="$ROOT" MODEL_POLICY_SOURCE_CHECK_ONLY=1
    source "$SCHEDULER_AGENT_LIB" || exit 2
    while read -r other; do
      if expected_packages_collide "$check_scope" "$(jq -c '.footprint' <<<"$other")"; then
        jq -r '.id' <<<"$other"; break
      fi
    done < <(jq -c '.[]' <<<"$active")
  )" || return 1
  if [[ -n "$conflict" ]]; then
    say "footprint wait unit=$id owner=$conflict"
    return 1
  fi
}

# The Stop-hook pattern without an LLM: use the Touched packages job's selector.
# No workspace package in the diff means no package gate, not a new repo gate.
# The heavy install/build/test steps default to cihost through the pipeline's
# single remote execution entry; ZF_SELF_CHECK_LOCAL=1 is the operator
# escape hatch while cihost is under maintenance.
test_evidence_has_pass() {
  python3 "$HERE/test-evidence.py" has "$SUP/test-evidence.jsonl" "$1" "$2"
}
test_evidence_record_pass() {
  python3 "$HERE/test-evidence.py" record "$SUP/test-evidence.jsonl" "$1" "$2" "$3" \
    || say "test evidence not persisted tree=$1 target=$2 source=$3"
}
self_check_run() (
  set -o pipefail
  local dir="$1" sha="$2" lane="${3:-}" pr_base="${4:-}" base paths pkg targets test_targets cached_tests tree selection selection_dir selection_log manifest part changed_helpers=0 rc=0 marker target
  local entry="${ZF_CIHOST_EXEC:-$ROOT/engine/cihost-exec.py}"
  local step_s="${SELF_CHECK_STEP_TIMEOUT:-900}" srg
  local delegate_tests=0
  local -a builds=()
  cd "$dir" || return 1
  tree="$(git rev-parse "$sha^{tree}")" || return 1
  base="$(git merge-base origin/main "$sha")" || return 1
  # CI preserves candidate edits and backfills the remaining helpers from main.
  # Never execute a candidate helper on the controller: use the isolated cihost
  # checkout, where the full candidate module environment is available.
  for part in scripts/ci/touched-package-selection.mjs engine/authenticated-origin-contract-packages.mjs; do
    if [[ -f "$dir/$part" ]] && ! git diff --quiet "$base" "$sha" -- "$part"; then changed_helpers=1; fi
  done
  if (( changed_helpers )); then
    selection_log="$(mktemp "${TMPDIR:-/tmp}/self-check-selection.XXXXXX")" || return 1
    if "$entry" "$dir" -- bash -c '
      set -e
      for part in scripts/ci/touched-package-selection.mjs engine/authenticated-origin-contract-packages.mjs; do
        if [[ ! -f "$part" ]] || git diff --quiet "$1" "$2" -- "$part"; then
          mkdir -p "$(dirname "$part")"
          git show "refs/remotes/origin/main:$part" > "$part"
        fi
      done
      if selected="$(timeout -k 10 "$3" node --experimental-strip-types scripts/ci/touched-package-selection.mjs --repo "$PWD" --base "$1" --head "$2")"; then :
      else
        status=$?; (( status != 124 )) || echo "self-check: package selector timed out after ${3}s"
        exit "$status"
      fi
      printf "ZF_PACKAGE_SELECTION %s\n" "$(printf %s "$selected" | base64 -w0)"' self-check-selector "$base" "$sha" "$step_s" > "$selection_log" 2>&1; then
      selection="$(sed -n 's/^ZF_PACKAGE_SELECTION //p' "$selection_log" | tail -1 | base64 -d)"
      sed '/^ZF_PACKAGE_SELECTION /d' "$selection_log"
      rm -f "$selection_log"
      [[ -n "$selection" ]] || return 1
    else
      rc=$?; cat "$selection_log"; rm -f "$selection_log"; return "$rc"
    fi
  else
    selection_dir="$(mktemp -d "${TMPDIR:-/tmp}/self-check-selector.XXXXXX")" || return 1
    mkdir -p "$selection_dir/scripts/ci" "$selection_dir/engine" || { rm -rf "$selection_dir"; return 1; }
    for part in scripts/ci/touched-package-selection.mjs engine/authenticated-origin-contract-packages.mjs; do
      command git -C "$ROOT" show "refs/remotes/origin/main:$part" > "$selection_dir/$part" \
        || { rm -rf "$selection_dir"; return 1; }
    done
    selection="$(node --experimental-strip-types "$selection_dir/scripts/ci/touched-package-selection.mjs" --repo "$dir" --base "$base" --head "$sha")" \
      || { rm -rf "$selection_dir"; return 1; }
    rm -rf "$selection_dir"
  fi
  if [[ "$(jq '.rootNames | length' <<<"$selection")" == 0 ]]; then echo 'self-check: no workspace package touched'; return 0; fi
  targets="$(jq -r '.affectedNames[]' <<<"$selection")" || return 1
  test_targets=""
  while IFS= read -r paths; do
    # Selection from candidate code may be untrusted: read manifests only from
    # the candidate Git tree, never from an arbitrary controller filesystem path.
    manifest="$(command git -C "$dir" show "$sha:$paths/package.json")" || return 1
    if [[ -n "$(jq -r '.scripts.test // empty' <<<"$manifest")" ]]; then
      test_targets+="$(jq -r '.name' <<<"$manifest")"$'\n'
    fi
  done < <(jq -r '.affectedPaths[]' <<<"$selection")
  [[ -n "$targets" ]] || return 1
  [[ "$lane" == pr && "$pr_base" == main ]] && delegate_tests=1
  while read -r pkg; do builds+=(--filter "$pkg..."); done <<<"$targets"
  cached_tests=""
  while read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if (( ! delegate_tests )) && test_evidence_has_pass "$tree" "test:$pkg"; then cached_tests+="$pkg"$'\n'; fi
  done <<<"$test_targets"
  echo "self-check head=$sha tree=$tree base=$base affected=$targets"
  # Every step is bounded: a hung test becomes a red result, not a unit stuck in review-pending.
  if [[ "${ZF_SELF_CHECK_LOCAL:-}" != 1 ]]; then
    local builds_arg="" remote_output
    for pkg in "${builds[@]}"; do builds_arg+=" $pkg"; done
    remote_output="$(mktemp "${TMPDIR:-/tmp}/self-check-evidence.XXXXXX")" || return 1
    if "$entry" "$dir" -- bash -c '
      set -o pipefail
      export VITEST_MAX_WORKERS=2 VITEST_MAX_FORKS=2 VITEST_MAX_THREADS=2 VITEST_MIN_FORKS=1
      export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 BASE_SHA="$1"
      step_s="$6" tree="$7" delegate_tests="$8"
      rc=0
      # shellcheck disable=SC2086
      timeout -k 10 "$step_s" pnpm $2 --workspace-concurrency=2 --if-present run build || { srg=$?; rc=1; (( srg != 124 )) || echo "self-check: build timed out after ${step_s}s"; }
      for paths in typecheck test lint; do
        while read -r pkg; do
          if [[ "$paths" == test ]] && grep -Fxq "$pkg" <<<"$4"; then
            if (( delegate_tests )); then
              echo "self-check: test $pkg delegated to Touched packages PR gate tree=$tree"
              continue
            fi
            if grep -Fxq "$pkg" <<<"$5"; then
              echo "self-check: test $pkg reused tree=$tree"
              continue
            fi
          fi
          echo "self-check: $paths $pkg"
          if timeout -k 10 "$step_s" pnpm --filter "$pkg" --if-present run "$paths"; then
            if [[ "$paths" == test ]] && grep -Fxq "$pkg" <<<"$4"; then echo "ZF_TEST_EVIDENCE_PASS test:$pkg"; fi
          else
            srg=$?; rc=1; (( srg != 124 )) || echo "self-check: $paths $pkg timed out after ${step_s}s"
          fi
        done <<<"$3"
      done
      exit "$rc"' self-check "$base" "$builds_arg" "$targets" "$test_targets" "$cached_tests" "$step_s" "$tree" "$delegate_tests" \
      | tee "$remote_output"; then
      rc=0
    else
      rc=$?
    fi
    while IFS= read -r marker; do
      [[ "$marker" == 'ZF_TEST_EVIDENCE_PASS test:'* ]] || continue
      target="${marker#ZF_TEST_EVIDENCE_PASS }"
      pkg="${target#test:}"
      grep -Fxq "$pkg" <<<"$test_targets" && test_evidence_record_pass "$tree" "$target" self-check
    done < "$remote_output"
    rm -f "$remote_output"
    return "$rc"
  fi
  export VITEST_MAX_WORKERS=2 VITEST_MAX_FORKS=2 VITEST_MAX_THREADS=2 VITEST_MIN_FORKS=1
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 BASE_SHA="$base"
  timeout 900 pnpm install --frozen-lockfile --offline || timeout 900 pnpm install --frozen-lockfile || return 1
  timeout -k 10 "$step_s" pnpm "${builds[@]}" --workspace-concurrency=2 --if-present run build || { srg=$?; rc=1; (( srg != 124 )) || echo "self-check: build timed out after ${step_s}s"; }
  for paths in typecheck test lint; do
    while read -r pkg; do
      if [[ "$paths" == test ]] && grep -Fxq "$pkg" <<<"$test_targets"; then
        if (( delegate_tests )); then
          echo "self-check: test $pkg delegated to Touched packages PR gate tree=$tree"
          continue
        fi
        if test_evidence_has_pass "$tree" "test:$pkg"; then
          echo "self-check: test $pkg reused tree=$tree"
          continue
        fi
      fi
      echo "self-check: $paths $pkg"
      if timeout -k 10 "$step_s" pnpm --filter "$pkg" --if-present run "$paths"; then
        if [[ "$paths" == test ]] && grep -Fxq "$pkg" <<<"$test_targets"; then test_evidence_record_pass "$tree" "test:$pkg" self-check; fi
      else
        srg=$?; rc=1; (( srg != 124 )) || echo "self-check: $paths $pkg timed out after ${step_s}s"
      fi
    done <<<"$targets"
  done
  return "$rc"
)

pid_start() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; } # start ticks: tells a reused pid from the gate
self_check_before_review() { # unit sha clone; false means wait for the gate/self-fix
  local id="$1" sha="$2" dir="$3" out result pid rc lane pr_base=""
  lane="$(unit_field "$id" '.lane // empty')"
  if [[ "$lane" == pr ]]; then
    pr_base="$(pr_view "$(unit_field "$id" '.pr // empty')" baseRefName)" || pr_base=""
  fi
  if [[ "$(unit_field "$id" .self_check_sha)" == "$sha" && -n "$(unit_field "$id" .self_check_status)" \
      && "$(unit_field "$id" '.self_check_lane // empty')" == "$lane" \
      && "$(unit_field "$id" '.self_check_base // empty')" == "$pr_base" ]]; then return 0; fi
  out="$SUP/self-check-$id-$sha-$(unit_field "$id" '.self_check_fixes // 0')-$TAG.log"; result="$out.result"
  (
    if self_check_run "$dir" "$sha" "$lane" "$pr_base"; then printf 'pass\n' > "$result"
    else
      rc=$?
      # 75 (cihost admission queue) and 125 (transfer/setup) are not verdicts.
      if (( rc == 75 || rc == 125 )); then printf 'defer\n' > "$result"; else printf 'red\n' > "$result"; fi
    fi
  ) > "$out" 2>&1 < /dev/null &
  pid=$!
  set_unit "$id" ".self_check_pid=$pid | .self_check_start=$(js "$(pid_start "$pid")") | .self_check_sha=$(js "$sha") | .self_check_lane=$(js "$lane") | .self_check_base=$(js "$pr_base") | .self_check_status=null | .self_check_output=$(js "$out") | .self_check_workdir=$(js "$dir") | .self_check_return_stage=.stage"
  say "self-check pid=$pid unit=$id head=$sha (before review)"
  return 1
}
self_check_harvest() {
  local id pid out start status fixes sid model
  while IFS=$'\t' read -r id pid out start; do
    if [[ ! -s "$out.result" ]]; then
      if kill -0 "$pid" 2>/dev/null && { [[ -z "$start" || "$(pid_start "$pid")" == "$start" ]]; }; then continue; fi
      # Gate died (reboot, SIGKILL) before any verdict: the check never failed, so run it again.
      say "self-check interrupted without a result unit=$id: rerun"
      set_unit "$id" "$(hist self-check-interrupted "$out") | del(.self_check_pid, .self_check_start, .self_check_sha, .self_check_status)"
      continue
    fi
    status="$(cat "$out.result")"
    if [[ "$status" == defer ]]; then
      say "self-check deferred unit=$id: cihost admission or setup; rerun next tick"
      set_unit "$id" "$(hist self-check-deferred "$out") | del(.self_check_pid, .self_check_start, .self_check_sha, .self_check_status)"
      continue
    fi
    set_unit "$id" "$(hist "self-check-$status" "$out") | del(.self_check_pid, .self_check_start) | .self_check_status=$(js "$status")"
    [[ "$status" == red ]] || continue
    fixes="$(unit_field "$id" '.self_check_fixes // 0')"
    sid="$(unit_field "$id" '.session_ids.repair')"; model="$(unit_field "$id" .implement_model)"
    if (( fixes < 2 )) && [[ "$sid" =~ $SESSION_RE && -n "$model" && "$model" != claude-* ]]; then
      set_unit "$id" '.self_fix_pending=true'
    else
      say "self-check red unit=$id: normal review with failure attached (fixes=$fixes, original session=${sid:-unavailable})"
    fi
  done < <(jqf -r '.units[] | select(.self_check_pid!=null) | [.id,.self_check_pid,.self_check_output,(.self_check_start // "")] | @tsv' "$UNITS")
}
self_fix_dispatch() { # unit JSON; same session, model, branch and workdir
  local u="$1" id dir branch out rep prompt model effort deliver key failure
  id="$(jqf -r .id <<<"$u")"
  room_for "$id" repair "$u" || return 1
  model="$(jqf -r .implement_model <<<"$u")"; effort="$(jqf -r .implement_effort <<<"$u")"
  cooling "$(provider_of "$model")" && return 1
  dir="$(jqf -r .self_check_workdir <<<"$u")"; branch="$(jqf -r .branch <<<"$u")"
  git -C "$dir" checkout -q "$branch" || return 1
  out="$(jqf -r .self_check_output <<<"$u")"; key="$(jqf -r '.pr // .id' <<<"$u")"
  rep="impl-${key}-selfcheck$(( $(jqf -r '.self_check_fixes // 0' <<<"$u") + 1 ))-fix-${TAG}.md"
  if [[ "$(jqf -r .lane <<<"$u")" == direct-main ]]; then
    deliver="node scripts/branch-delivery-preflight.mjs --mode commit 通过后在原分支提交，不 push。"
  else
    deliver="node scripts/branch-delivery-preflight.mjs --mode push --publish-topic，通过后交付原分支。"
  fi
  failure="实现后的确定性自检失败。完整输出：$out
$(tail -100 "$out")"
  prompt="实现后的确定性自检失败，尚未派出评审。这是原实现会话的自修复，保持原任务范围，修复下列失败，不弱化断言。$failure
在当前隔离 clone $dir、原分支 $branch 修复；$deliver 禁止 merge PR、部署或修改 GitHub 状态。把修复和验证证据写到 $SUP/$rep，然后结束，流水线会重跑同一自检。
$(matt_method_rule "$dir")"
  set_unit "$id" '.self_fix_active=true'
  if dispatch_if_room "$id" repair repair "${rep%.md}.worker.log" "$rep" "$model" "$effort" "$prompt" "" "$dir" "" "$failure" "$u"; then
    set_unit "$id" "$(hist self-fix-dispatched) | .self_fix_pending=false | .self_check_fixes=((.self_check_fixes // 0)+1)"
  else
    set_unit "$id" '.self_fix_active=false'
    return 1
  fi
}

# #4621（维护者 2026-10-29 严格优先级 hotfix > opt > 普通 pipeline）：bin/luna、bin/zc 的门在 run 等待时写
# $LUNA_SLOTS/wait-<prio>-<pid>。产品 PR worker 让位给 hotfix/opt；direct-main opt worker 只让位给 hotfix；已运行的不动。
# 门口的 run 进门、文件消失后下一拍恢复派发；wrapper 已退出的旧文件不挡派发，顺手清掉。
LUNA_SLOTS="${LUNA_SLOTS:-${HOME:-/tmp}/.zenoforge/scratch/tmp/luna-slots}"
unit_dispatch_priority() { # unit-json → hotfix|opt|normal
  if [[ "$(jqf -r '.hotpatch // false' <<<"$1")" == true ]]; then printf 'hotfix\n'
  elif [[ "$(jqf -r '.lane // empty' <<<"$1")" == direct-main ]]; then printf 'opt\n'
  else printf 'normal\n'; fi
}
higher_priority_waiting() { # priority → higher-priority live waiter (stdout); always drops stale files
  local priority="$1" f pid name hotfix="" opt=""
  for f in "$LUNA_SLOTS"/wait-hotfix-* "$LUNA_SLOTS"/wait-opt-*; do
    [[ -e "$f" ]] || continue
    pid="${f##*-}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      name="${f##*/}"
      case "$name" in
        wait-hotfix-*) [[ -n "$hotfix" ]] || hotfix="$name" ;;
        wait-opt-*) [[ -n "$opt" ]] || opt="$name" ;;
      esac
    else
      rm -f -- "$f"
    fi
  done
  case "$priority" in
    hotfix) return 1 ;;
    opt) [[ -n "$hotfix" ]] && { printf '%s\n' "$hotfix"; return 0; } ;;
    *)
      [[ -n "$hotfix" ]] && { printf '%s\n' "$hotfix"; return 0; }
      [[ -n "$opt" ]] && { printf '%s\n' "$opt"; return 0; }
      ;;
  esac
  return 1
}

room_for() { # unit-id type [unit-json]：焦点与并发检查（先于 clone/gh 调用，满载时不做无用功）
  local u="${3:-}" priority waiter cur impl_cap n_impl
  [[ -n "$u" ]] || u="$(jqf -c --arg id "$1" '.units[] | select(.id==$id)' "$UNITS")"
  if [[ "$2" == review || "$2" == rereview ]]; then
    jqf -e '(.self_check_pid // null)==null and (.self_fix_pending // false)!=true' <<<"$u" >/dev/null || return 1
  fi
  if [[ "$FOCUS_MODE" == "release" && "$(unit_is_critical "$u")" != "true" && "$(critical_pending_count)" -gt 0 ]]; then
    FOCUS_SKIPPED+=("$1")
    say "skip dispatch unit=$1 focus=release critical=false"
    return 1
  fi
  priority="$(unit_dispatch_priority "$u")"
  if waiter="$(higher_priority_waiting "$priority")"; then
    say "skip dispatch unit=$1 priority=$priority (higher-priority run waiting at luna/zc gate: $waiter)"
    return 1
  fi
  cur="$(live_workers)"
  if (( cur >= MAX )); then say "skip dispatch unit=$1 (capacity $cur/$MAX)"; return 1; fi
  impl_cap="$IMPLEMENT_CAP"
  if [[ "$2" == "implement" || "$2" == "repair" ]]; then
    footprint_room "$1" "$u" || return 1
    n_impl=$(live_by_type "implement|repair")
    if (( n_impl >= impl_cap )); then say "skip dispatch unit=$1 (implement at cap $n_impl/$impl_cap)"; return 1; fi
  fi
}

dispatch_if_room() { # unit stage type log report model effort prompt [sha] [workdir] [pr-head] [new-failure] [unit-json]
  room_for "$1" "$3" "${13:-}" || return 1
  local prompt="$8"
  if [[ "$3" == review || "$3" == rereview ]] && [[ "${9:-}" =~ $SHA_RE ]]; then
    self_check_before_review "$1" "$9" "${10:-$ROOT}" || return 1
    local check_output; check_output="$(unit_field "$1" .self_check_output)"
    prompt+="
流水线确定性自检（当前 head $9）：$(unit_field "$1" .self_check_status)。完整输出 $check_output
$(tail -80 "$check_output" 2>/dev/null)"
  fi
  dispatch "$3" "$6" "$7" "$1" "$4" "$5" "$prompt" "${9:-}" "${10:-}" "${11:-}" "${12-$prompt}" || return 1
  if [[ "$3" == review || "$3" == rereview ]]; then set_unit "$1" '.self_check_fixes=0'; fi
  if [[ "$3" == implement || "$3" == repair ]]; then
    set_unit "$1" "$(STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)" hist write-start "$(unit_field "$1" '.footprint // []')") | .implement_model=$(js "$6") | .implement_effort=$(js "$7")"
  fi
  local extra=""
  [[ "${9:-}" =~ $SHA_RE ]] && extra=" | .review_sha=\"$9\""
  if [[ ( "$3" == implement || "$3" == repair ) && -n "$(unit_field "$1" '.handoff_start_ref // empty')" ]]; then
    extra+=' | .handoff_start_applied=true'
  fi
  if [[ "$3" == implement || "$3" == repair ]] && [[ -n "$(unit_field "$1" '.handoff_worktree_sha // empty')" ]]; then
    extra+=' | .handoff_worktree_applied=true'
  fi
  set_unit "$1" ".stage=\"$2\"$extra"
}

budget_alert_if_needed() { # 信息性告警：新鲜 token（Codex+worker Claude）超过上限才记一行，从不阻断派发
  local fresh bound provisional coverage
  fresh="$(jqf -r '.fresh // 0' "$A/budget.json")"; bound="$(jqf -r '.bound.unhealthy // 0' "$A/budget.json")"
  provisional="$(jqf -r 'if .bound.provisional then " provisional" else "" end' "$A/budget.json")"
  coverage="$(jqf -r 'if .status == "partial" then " partial-coverage" else "" end' "$A/budget.json")"
  [[ "$fresh" =~ ^[0-9]+$ && "$bound" =~ ^[0-9]+$ ]] || return 0
  if (( bound > 0 && fresh > bound )) && ! grep -Fq "BUDGET-ALERT date=$TODAY" "$A/alerts/waste.md" 2>/dev/null; then
    echo "[$STAMP] BUDGET-ALERT date=$TODAY fresh_tokens=$fresh bound=$bound$provisional$coverage (dispatch continues)" >> "$A/alerts/waste.md"
  fi
}

# 评审方法 = Matt 的 code-review 技能（Standards / Spec 两轴）；verdict 行与 review-findings schema 只认 review-contract.md。
REVIEW_CONTRACT_MD="$ENGINE_ROOT/engine/prompts/review-contract.md"
review_contract_rule() { # checkout → 评审、复审、修复三类 prompt 共用的契约句
  printf '评审方法按 Matt 的 code-review 技能（%s）：Standards 与 Spec 两轴分别审、分别报告，不合并不重排，两轴都由你在本会话内自己跑完，不派 sub-agent。verdict 行、review-findings schema 与 author-disposition schema 以 %s 为准（与技能不一致处以它为准）。' \
    "$(matt_skill_md code-review "${1:-.}")" "$REVIEW_CONTRACT_MD"
}
# 实现、修复、自修复 worker 共用的方法句：Matt 的 implement + tdd；缺陷、红 CI、评审发现走 diagnosing-bugs。
matt_method_rule() { # checkout → METHOD 段
  printf 'METHOD（Matt skills）：按 implement 技能（%s）做事，用 tdd 技能（%s）一次一个垂直切片红-绿推进；修缺陷、红 CI 或评审发现时，先按 diagnosing-bugs 技能（%s）造出一条能复现它的红色反馈回路，再改代码。无人可问：技能里要你询问用户、等确认或派 sub-agent 的步骤一律跳过，自己按证据决定；不要自己跑 code-review，流水线会另派独立评审。' \
    "$(matt_skill_md implement "${1:-.}")" "$(matt_skill_md tdd "${1:-.}")" "$(matt_skill_md diagnosing-bugs "${1:-.}")"
}

decision_eval_stages_for_paths() { # newline-delimited paths → affected eval stages
  local path stage
  local -A affected=()
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      engine/prompts/triage.*) affected[triage]=1; affected[end-to-end]=1 ;;
      engine/prompts/advisor*) affected[advisor]=1; affected[end-to-end]=1 ;;
      engine/prompts/implement-contract.md) affected[implement]=1; affected[end-to-end]=1 ;;
      engine/prompts/review-contract.md|.agents/skills/code-review/*|engine/mac-autopilot/review-contract.sh)
        affected[review]=1; affected[end-to-end]=1 ;;
      .agents/skills/triage/*|.agents/skills/ask-matt/*) affected[triage]=1; affected[end-to-end]=1 ;;
      .agents/skills/implement/*|.agents/skills/tdd/*|.agents/skills/diagnosing-bugs/*) affected[implement]=1; affected[end-to-end]=1 ;;
      .agents/skills/to-tickets/*|.agents/skills/to-spec/*) affected[end-to-end]=1 ;;
      engine/prompts/recut.*|engine/prompts/guarded-recut-hand.md)
        affected[end-to-end]=1 ;;
      engine/prompts/supervisor-arbiter.md)
        affected[supervisor]=1 ;;
      engine/prompts/*|engine/model-policy.default.json)
        affected[triage]=1; affected[advisor]=1; affected[implement]=1; affected[review]=1; affected[end-to-end]=1 ;;
    esac
  done <<<"$1"
  for stage in triage advisor implement review supervisor end-to-end; do
    [[ -n "${affected[$stage]:-}" ]] && printf '%s ' "$stage"
  done
  printf '\n'
}

decision_eval_stages() { # repo candidate-sha → affected stages; failure means the diff could not be read
  local paths
  paths="$(git -C "$1" diff --no-renames --name-only "origin/main...$2" 2>/dev/null)" || return 1
  decision_eval_stages_for_paths "$paths"
}

accepted_eval_label() {
  local label
  label="$(cat "$A/eval-accepted-label" 2>/dev/null || true)"
  [[ -n "$label" ]] || label=baseline
  printf '%s\n' "$label"
}

harvest_prompt_eval() { # worker JSON; report status is produced by eval/decision-gate.mjs
  # #4656（裁决 architecture-ships-evals-alongside）：eval 是并行报告任务。结果只记录 SHA/标签/证据，
  # 不改交付状态；回归升级 supervisor 仲裁后续，基础设施错误原地重试。
  local w="$1" unit pid report gate status sha gate_sha baseline label detail decision evidence tree
  unit="$(jqf -r '.unit' <<<"$w")"; pid="$(jqf -r '.pid' <<<"$w")"
  report="$(jqf -r '.report' <<<"$w")"; gate="$SUP/$report"
  [[ -s "$gate" ]] || {
    detail="evaluation process exited without report $report"
    set_unit "$unit" "$(hist eval-error "$detail") | .eval_gate.status=\"pending\" | .eval_gate.error=$(js "$detail")"
    say "eval worker pid=$pid unit=$unit: $detail; retry next tick"
    jqf --argjson pid "$pid" --arg finished "$STAMP" \
      '(.workers[] |= (if .pid==$pid and .type=="eval" and .harvested!=true then .harvested=true | .finished_at=$finished else . end))' "$WORKERS" | write_state "$WORKERS"
    return 0
  }
  gate="$(jqf -c . "$gate")" || gate='{}'
  status="$(jqf -r '.status // "error"' <<<"$gate")"
  sha="$(jqf -r '.sha // empty' <<<"$w")"
  gate_sha="$(unit_field "$unit" '.eval_gate.sha // empty')"
  baseline="$(jqf -r '.baseline // empty' <<<"$gate")"
  label="$(jqf -r '.label // empty' <<<"$gate")"
  tree="$(jqf -r '.tree // empty' <<<"$gate")"
  if [[ "$status" == error ]]; then
    detail="$(jqf -r '.error // "evaluation runner failed"' <<<"$gate")"
    set_unit "$unit" "$(hist eval-error "$detail") | .eval_gate.status=\"pending\" | .eval_gate.error=$(js "$detail")"
    say "eval worker pid=$pid unit=$unit: $detail; retry next tick"
  elif [[ "$status" == passed || "$status" == failed ]]; then
    if [[ "$sha" != "$gate_sha" ]]; then
      # 这份报告属于已被新一轮评审替换的旧 gate：只按其 SHA 记档，不碰现行 gate。
      set_unit "$unit" "$(hist eval-stale "report $report covers superseded sha $sha; current gate sha ${gate_sha:-none}")"
      say "eval result stale unit=$unit: report $report covers superseded sha $sha"
    elif [[ "$status" == passed ]]; then
      local accepted_tmp
      accepted_tmp="$A/.eval-accepted-label.$$"
      if ! printf '%s\n' "$label" > "$accepted_tmp" || ! mv -f "$accepted_tmp" "$A/eval-accepted-label"; then
        rm -f "$accepted_tmp"
        detail="could not persist accepted evaluation label $label"
        set_unit "$unit" "$(hist eval-error "$detail") | .eval_gate.status=\"pending\" | .eval_gate.error=$(js "$detail")"
        say "eval worker pid=$pid unit=$unit: $detail; retry next tick"
      else
        evidence="sha=$sha label=$label baseline=$baseline tree=$tree stages=$(jqf -r '.stages | join(",")' <<<"$gate") regressions=none critical_failures=none report=$report"
        decision="$(decision_entry 'Record eval report alongside the delivered change' 'the eval has no pass-to-fail regression and all introduced-incident review cases pass' "$evidence" '["Hold architecture delivery until the eval passes"]' scheduler)"
        set_unit "$unit" "$(hist eval-pass "$evidence" "$decision") | .eval_gate.status=\"passed\" | .eval_gate.baseline=$(js "$baseline")"
        say "eval passed unit=$unit label=$label baseline=$baseline; delivery not gated"
      fi
    else
      local regressions critical
      regressions="$(jqf -r 'if (.regressions|length)==0 then "none" else (.regressions|join(", ")) end' <<<"$gate")"
      critical="$(jqf -r 'if (.criticalFailures|length)==0 then "none" else (.criticalFailures|join(", ")) end' <<<"$gate")"
      detail="eval label=$label regressed against $baseline on sha $sha: regressions=$regressions; critical_failures=$critical; evidence=$report"
      evidence="sha=$sha label=$label baseline=$baseline tree=$tree regressions=$regressions critical_failures=$critical report=$report"
      decision="$(decision_entry 'Escalate the eval regression on a delivered architecture change' 'the eval found a pass-to-fail regression or an introduced-incident review case failed after delivery proceeded' "$evidence" '["Re-gate architecture delivery on the eval"]' scheduler)"
      set_unit "$unit" "$(hist eval-regression "$detail" "$decision") | .eval_gate.status=\"failed\""
      say "eval failed unit=$unit label=$label baseline=$baseline; delivery unaffected, escalated"
      to_supervisor "$unit" "已交付架构改动的 eval 报告出现回归：$detail" \
        'Escalate the eval regression on a delivered architecture change' \
        'the eval found a regression after the architecture change shipped; evals report alongside and never gate (#4656)' \
        "$evidence" '["Re-gate architecture delivery on the eval"]'
    fi
  else
    detail="unknown eval result status $status in $report"
    set_unit "$unit" "$(hist eval-error "$detail") | .eval_gate.status=\"pending\" | .eval_gate.error=$(js "$detail")"
    say "eval worker pid=$pid unit=$unit: $detail; retry next tick"
  fi
  jqf --argjson pid "$pid" --arg finished "$STAMP" \
    '(.workers[] |= (if .pid==$pid and .type=="eval" and .harvested!=true then .harvested=true | .finished_at=$finished else . end))' "$WORKERS" | write_state "$WORKERS"
}

dispatch_prompt_evals() {
  # #4656：按 .eval_gate.status==pending 派发，不再依赖 eval-pending 阶段（交付可能在 eval 完成前合并/落地）。
  local u id workdir sha tree label baseline stages report log pid worker active safe_id detail launcher=()
  active="$(jqf '[.workers[] | select(.type=="eval" and .harvested!=true)] | length' "$WORKERS")"
  (( active == 0 )) || return 0
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    id="$(jqf -r '.id' <<<"$u")"
    # 已交付（merged/landed 或带 merge/land SHA）的单元照跑报告；从未交付就关闭的单元不再测一棵没落地的树。
    if jqf -e '(.stage | IN("merged","landed")) | not' <<<"$u" >/dev/null \
       && jqf -e '(.stage | IN("closed","wontfix","duplicate")) and (.merge_sha // .land_sha // null) == null
                  and ([(.history // [])[] | select(.stage == "merged" or .stage == "landed")] | length) == 0' <<<"$u" >/dev/null; then
      set_unit "$id" "$(hist eval-skipped "unit closed without delivery; its tree never shipped") | .eval_gate.status=\"skipped\""
      say "eval skipped unit=$id: closed without delivery"
      continue
    fi
    workdir="$(jqf -r '.eval_gate.workdir // empty' <<<"$u")"
    sha="$(jqf -r '.eval_gate.sha // empty' <<<"$u")"
    tree="$(jqf -r '.eval_gate.tree // empty' <<<"$u")"
    stages="$(jqf -r '.eval_gate.stages | join(",")' <<<"$u")"
    [[ -n "$workdir" && -n "$sha" && -n "$stages" ]] || continue
    if [[ ! -d "$workdir" ]]; then
      # eval 工作目录缺失：eval 侧单独失败（历史 + 告警），不影响交付，也不静默空转。
      detail="eval workdir $workdir is gone"
      set_unit "$id" "$(hist eval-error "$detail") | .eval_gate.status=\"error\" | .eval_gate.error=$(js "$detail")"
      echo "[$STAMP] eval unit=$id error=workdir-missing" >> "$A/alerts/events.md"
      say "eval failed unit=$id: $detail"
      continue
    fi
    if [[ -z "$tree" ]]; then
      if ! tree="$(git -C "$workdir" rev-parse "$sha^{tree}" 2>/dev/null)" || [[ -z "$tree" ]]; then
        detail="eval workdir $workdir cannot resolve $sha"
        set_unit "$id" "$(hist eval-error "$detail") | .eval_gate.status=\"error\" | .eval_gate.error=$(js "$detail")"
        echo "[$STAMP] eval unit=$id error=workdir-missing" >> "$A/alerts/events.md"
        say "eval failed unit=$id: $detail"
        continue
      fi
      label="gate-$tree"
      set_unit "$id" ".eval_gate.tree=$(js "$tree") | .eval_gate.label=$(js "$label")"
    fi
    # eval 工作流缺失同样单独失败：不静默跳过，也不阻塞架构交付。
    if [[ ! -f "$ROOT/engine/eval/decision-gate.mjs" ]]; then
      detail="eval workflow missing: engine/eval/decision-gate.mjs"
      set_unit "$id" "$(hist eval-error "$detail") | .eval_gate.status=\"error\" | .eval_gate.error=$(js "$detail")"
      echo "[$STAMP] eval unit=$id error=workflow-missing" >> "$A/alerts/events.md"
      say "eval failed unit=$id: $detail"
      continue
    fi
    (( $(live_workers) < MAX )) || { say "eval pending unit=$id: worker capacity full"; return 0; }
    label="gate-$tree"
    baseline="$(accepted_eval_label)"
    safe_id="$(tr -c 'A-Za-z0-9._-' '-' <<<"$id" | sed 's/-$//')"
    report="eval-gate-${safe_id}-${tree}.json"
    log="eval-gate-${safe_id}-${tree}.log"
    rm -f "$SUP/$report"
    set_unit "$id" ".eval_gate.tree=$(js "$tree") | .eval_gate.label=$(js "$label") | .eval_gate.report=$(js "$report")"
    command -v setsid >/dev/null 2>&1 && launcher=(setsid)
    (
      cd "$workdir" || exit 1
      exec ${launcher[@]+"${launcher[@]}"} timeout -k 30 14400 node "$ROOT/engine/eval/decision-gate.mjs" \
        --repo "$workdir" --sha "$sha" --tree "$tree" --stages "$stages" \
        --baseline "$baseline" --label "$label" --concurrency 3 --output "$SUP/$report"
    ) > "$SUP/$log" 2>&1 < /dev/null &
    pid=$!
    worker="$(jqf -cn --argjson pid "$pid" --arg unit "$id" --arg log "$log" --arg report "$report" \
      --arg at "$STAMP" --arg sha "$sha" --arg workdir "$workdir" --arg label "$label" --arg baseline "$baseline" \
      '{pid:$pid,unit:$unit,type:"eval",log:$log,report:$report,started:$at,sha:$sha,workdir:$workdir,eval_label:$label,eval_baseline:$baseline}')"
    jqf --argjson worker "$worker" '.workers += [$worker]' "$WORKERS" | write_state "$WORKERS"
    set_unit "$id" ".eval_gate.status=\"running\" | .eval_gate.label=$(js "$label") | .eval_gate.baseline=$(js "$baseline") | .eval_gate.report=$(js "$report")"
    say "eval dispatched pid=$pid unit=$id label=$label baseline=$baseline stages=$stages"
    return 0
  done < <(jqf -c '.units[] | select((.eval_gate.status // "") == "pending" and (.hold_handoff_waiting // false) == false)' "$UNITS")
}

# ---------- f12（#4369）：supervisor-review 的自动裁决 ----------
# 升级记录按冻结形状交给裁决 worker（terra profile，与 eval supervisor 用例同一 prompt 与输入形状）；
# 输出六动作之一：requeue/approve/park/close/reroute/needs-info。每单元最多裁 2 次，之后 needs-info。
supervisor_arbiter_input() { # unit-json → 冻结记录 JSON（escalationReason/unitHistory/reviewFindings/ciEvidence）
  local u="$1" report_name report_body report_at truncated=false
  report_name="$(jqf -r '.review_report // empty' <<<"$u")"
  report_body=""
  if [[ -n "$report_name" && -s "$SUP/$report_name" ]]; then
    report_body="$(head -c 8000 "$SUP/$report_name")"
    (( $(wc -c < "$SUP/$report_name") > 8000 )) && truncated=true
  fi
  report_at="$(jqf -r '[(.history // [])[] | select(.stage | test("^review")) | .at] | last // empty' <<<"$u")"
  jqf -c --arg asof "$STAMP" --arg report "$report_name" --arg report_at "$report_at" --arg body "$report_body" --argjson truncated "$truncated" '
    {
      asOf: $asof,
      unitId: .id,
      escalationReason: (
        ([(.history // [])[] | select(.stage == "supervisor-escalated" or .stage == "supervisor-review")] | last) as $e
        | {at: ($e.at // $asof), stage: ($e.stage // "supervisor-escalated"),
           reason: ($e.result // .note // "unknown escalation reason"), isExplicitEscalation: true}
      ),
      unitHistory: [(.history // [])[] | {stage, at, result}],
      reviewFindings: (if ($body | length) > 0
        then {available: true, reportAt: $report_at, reportFile: $report, report: $body, truncated: $truncated}
        else {available: false, reportFile: $report, report: "", truncated: false} end),
      ciEvidence: [(.history // [])[] | select((.stage | test("^ci-")) or .stage == "merge-reverted") | {stage, at, result}],
      handoff: {worktree: .handoff_worktree, worktreeSha: .handoff_worktree_sha, rescuedRef: .handoff_start_ref, rescuedSha: .handoff_start_sha}
    }' <<<"$u"
}

dispatch_supervisor_arbiters() { # supervisor-review 单元各派一个裁决 worker；在途上限 SUPERVISOR_ARBITER_MAX，两轮上限
  [[ "$SUPERVISOR_ARBITER" == true ]] || return 0
  local prompt_file="$ROOT/engine/prompts/supervisor-arbiter.md"
  [[ -r "$prompt_file" ]] || prompt_file="$HERE/../prompts/supervisor-arbiter.md"
  [[ -r "$prompt_file" ]] || return 0
  local u id report log q pid w converted=0 arbi_runs entries in_flight arbiter_input judge_input judge_output judge_answer judge_confidence judge_ready judge_rollout_ready event_id judge_metadata
  in_flight="$(jqf -r '[.workers[] | select(.type=="supervise" and .harvested != true)] | length' "$WORKERS")"
  (( in_flight < SUPERVISOR_ARBITER_MAX )) || return 0
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    id="$(jqf -r .id <<<"$u")"
    jqf -e --arg id "$id" 'any(.workers[]; .type=="supervise" and .harvested != true and .unit==$id)' "$WORKERS" >/dev/null && continue
    arbi_runs="$(jqf -r '[(.history // [])[] | select(.stage=="supervisor-arbiter")] | length' <<<"$u")"
    entries="$(supervisor_entries "$id")"
    if (( arbi_runs >= 2 || entries >= 3 )); then
      # 裁决预算或升级次数用尽：不再派、不再等，停到 parked 给 supervisor（每 tick 限量）。
      (( converted < SUPERVISOR_NEEDS_INFO_PER_TICK )) || { say "supervisor budget park capped at $SUPERVISOR_NEEDS_INFO_PER_TICK this tick"; return 0; }
      supervisor_budget_park "$id" "arbitration budget exhausted for $id (runs=$arbi_runs entries=$entries)" && converted=$((converted + 1))
      continue
    fi
    (( $(live_workers) < MAX )) || { say "supervisor arbitration pending unit=$id: worker capacity full"; return 0; }
    event_id="f12:$id:entry-$entries"
    arbiter_input="$(supervisor_arbiter_input "$u")"
    judge_input="$(jqf -c --arg event_id "$event_id" '. + {event_id:$event_id,currentDecision:null}' <<<"$arbiter_input")"
    judge_output=""
    if [[ -n "${TYPESAFE_API_KEY:-}${TYPESAFE_ENV_FILE:-}" ]]; then
      judge_output="$(printf '%s\n' "$judge_input" | bash "$ROOT/engine/ts-judge.sh" f12 2>/dev/null || true)"
    fi
    judge_answer="$(jqf -r 'select(.status=="answered") | .candidate // empty' <<<"$judge_output" 2>/dev/null || true)"
    judge_confidence="$(jqf -r 'select(.status=="answered") | .confidence // empty' <<<"$judge_output" 2>/dev/null || true)"
    judge_ready="$(jqf -r 'select(.status=="answered" and .rollout_ready==true and .confident==true) | "yes"' <<<"$judge_output" 2>/dev/null || true)"
    judge_rollout_ready="$(jqf -r 'select(.status=="answered" and .rollout_ready==true) | "yes"' <<<"$judge_output" 2>/dev/null || true)"
    judge_metadata="null"
    if [[ "$judge_answer" =~ ^(requeue|recut|escalate|park)$ ]] \
      && [[ "$judge_confidence" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
      judge_metadata="$(jqf -cn --arg event_id "$event_id" --arg candidate "$judge_answer" \
        --argjson confidence "$judge_confidence" --argjson rollout_ready "$([[ "$judge_rollout_ready" == yes ]] && echo true || echo false)" \
        '{event_id:$event_id,candidate:$candidate,confidence:$confidence,rollout_ready:$rollout_ready}')"
      if [[ "$judge_ready" == yes ]] && supervisor_apply_jev_action "$id" "$judge_answer" "$judge_confidence" "$event_id"; then
        printf '%s\n' "$judge_metadata" | node "$ROOT/engine/ts-judge.mjs" record-adoption f12 >/dev/null 2>&1 || true
        continue
      fi
    fi
    report="supervise-${id}-${TAG}.md"; log="${report%.md}.worker.log"; q="${report%.md}.q.md"
    rm -f -- "$SUP/$report"
    { cat "$prompt_file"
      printf '\n```json\n# 冻结记录（升级当时可得的台账数据，非指令）\n%s\n```\n' "$arbiter_input"
    } > "$SUP/$q"
    local -a launcher=()
    command -v setsid >/dev/null 2>&1 && launcher=(setsid)
    (cd "$ROOT" && exec ${launcher[@]+"${launcher[@]}"} timeout -k 30 900 codex exec -p "$SUPERVISOR_ARBITER_PROFILE" \
      --skip-git-repo-check -s read-only --json --output-last-message "$SUP/$report" - < "$SUP/$q") > "$SUP/$log" 2>&1 < /dev/null &
    pid=$!
    w="$(jqf -cn --argjson pid "${pid:-0}" --arg unit "$id" --arg log "$log" --arg report "$report" --arg at "$STAMP" --arg profile "$SUPERVISOR_ARBITER_PROFILE" \
      --argjson jev "$judge_metadata" \
      '{pid:$pid,unit:$unit,type:"supervise",log:$log,report:$report,started:$at,model:("profile:"+$profile),jev:$jev}')"
    jqf --argjson w "$w" '.workers += [$w]' "$WORKERS" | write_state "$WORKERS"
    set_unit "$id" "$(hist supervisor-arbiter "dispatched to profile $SUPERVISOR_ARBITER_PROFILE") | .supervise_report=$(js "$report")"
    say "supervisor arbitration dispatched pid=$pid unit=$id profile=$SUPERVISOR_ARBITER_PROFILE"
    in_flight=$((in_flight + 1))
    (( in_flight < SUPERVISOR_ARBITER_MAX )) || return 0
  done < <(jqf -c '.units[] | select(.stage=="supervisor-review" and (.hold_handoff_waiting // false) == false)' "$UNITS")
}

supervisor_action_of() { # report-path → 唯一 ACTION 行的动作名；无法判定返回 1
  local found
  found="$(grep -hoE '^[[:space:]]*ACTION:[[:space:]]*(requeue|approve|park|close|reroute|needs-info)[[:space:]]*$' "$1" 2>/dev/null \
    | tr -d '[:space:]' | sed 's/^ACTION://' | sort -u)"
  [[ -n "$found" && "$(grep -c . <<<"$found")" == 1 ]] || return 1
  printf '%s' "$found"
}

supervisor_section_of() { # report-path section（如 GUIDANCE）→ 冒号后同行内容 + 后续行，到下一节为止
  awk -v p="$2" '
    BEGIN { prefix = p ":" }
    index($0, prefix) == 1 { line = substr($0, length(prefix) + 1); sub(/^[[:space:]]+/, "", line); if (line != "") print line; f = 1; next }
    f && /^(ACTION|REASON|EVIDENCE|REJECTED|GUIDANCE|QUESTION):/ {exit}
    f {print}' "$1" 2>/dev/null
}

supervisor_requeue_unit() { # id action guidance decision —— requeue/reroute 落地：选一个工作环节放回去
  local id="$1" action="$2" guidance="$3" decision="$4" u target extra=""
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  if jqf -e 'any((.history // [])[]?; (.stage | test("^review")) or .stage == "repair-delivered" or .stage == "delivered")' <<<"$u" >/dev/null \
     && { [[ "$(jqf -r '.pr // empty' <<<"$u")" =~ ^[0-9]+$ ]] \
       || { [[ "$(jqf -r '.lane // empty' <<<"$u")" == direct-main ]] && [[ -n "$(jqf -r '.branch // empty' <<<"$u")" ]]; } }; then
    target="repair-pending"
    extra=" | .repair_hint=$(js "$guidance")"
  elif [[ -n "$(jqf -r '.task // empty' <<<"$u")" && -n "$(jqf -r '.branch // empty' <<<"$u")" ]]; then
    target="implement-pending"
    extra=" | .task += ($(js "

supervisor 裁决（$action）后重排：$guidance"))"
  else
    # 没有可放回的工作环节：搁置并留原因，不猜。
    set_unit "$id" "$(hist supervisor-park "requeue target missing: no review history and no task/branch" "$decision") | .stage=\"parked\" | .note=$(js "requeue had no work stage to return to")"
    say "supervisor arbitration unit=$id: $action has no work stage -> parked"
    return 0
  fi
  [[ "$action" == reroute ]] && extra=" | del(.blocked_on) | .reviewed_sha=null | .reviewed_pr_head=null$extra"
  set_unit "$id" "$(hist "supervisor-$action" "$guidance" "$decision") | .stage=\"$target\"$extra"
  say "supervisor arbitration unit=$id: $action -> $target"
}

reconcile_size_recuts() {
  local u id issue state hold_note reconcile_note
  while IFS= read -r u; do
    id="$(jqf -r .id <<<"$u")"; issue="$(jqf -r '.issue // empty' <<<"$u")"
    state="$(scheduler_issue_state "$issue")" || continue
    if jqf -e '.state == "tracker" or (.state == "released" and (has("recut_children") or .tracker_parent == true)) or (.state == "concluded" and .run.outcome == "duplicate" and .closed_by_pipeline == true)' <<<"$state" >/dev/null; then
      set_unit "$id" "$(hist size-recut-completed "issue #$issue became a tracker or a closed duplicate") | .stage=\"closed\" | .note=null | del(.size_recut_pending)"
      say "unit $id recut completed; parent is a tracker or closed duplicate"
    elif jqf -e '.state == "on-hold" or .hold != null' <<<"$state" >/dev/null; then
      hold_note="issue #$issue recut is on hold"
      if [[ "$(jqf -r '.note // ""' <<<"$u")" != "$hold_note" ]]; then
        set_unit "$id" "$(hist size-recut-held "$hold_note") | .stage=\"parked\" | .note=$(js "$hold_note")"
      fi
    elif jqf -e '.state == "ready-for-agent"' <<<"$state" >/dev/null; then
      # Refusal, advisor recovery, and release-hold all requeue through the
      # shared issue state machine. Resume the existing unit, not a duplicate.
      set_unit "$id" "$(hist size-recut-resumed "issue #$issue returned to implementation") | .stage=\"implement-pending\" | .note=null | del(.size_recut_pending)"
    elif jqf -e '.state == "needs-recut" and (has("recut_children") or has("recut_refused_at"))' <<<"$state" >/dev/null; then
      # A label-write failure can leave a completed marker in the active
      # queue, whose prefilter will never dispatch it again. Park until the
      # issue state and label are reconciled; automated unit requeue alone
      # would allow the parent to race its already-created children.
      reconcile_note="issue #$issue needs state/label reconciliation before this unit can resume"
      if ! scheduler_size_recut_active "$issue" && [[ "$(jqf -r '.note // ""' <<<"$u")" != "$reconcile_note" ]]; then
        set_unit "$id" "$(hist size-recut-reconcile "issue #$issue has a completed marker but remains needs-recut") | .stage=\"parked\" | .note=$(js "$reconcile_note")"
        echo "[$STAMP] size-recut issue=#$issue action=parked reason=state-label-reconciliation-required" >> "$A/alerts/events.md"
        say "unit $id parked for issue #$issue recut state/label reconciliation"
      fi
    fi
  done < <(jqf -c '.units[] | select((.stage=="blocked-external" or .stage=="parked") and .size_recut_pending==true)' "$UNITS")
}

supervisor_apply_action() { # id action report-path —— 六动作落地，决定/理由/证据/否掉选项写进单元
  local id="$1" action="$2" rep="$3" reason rejected evidence decision guidance question u reviewed_sha reviewed_pr_head pr
  reason="$(supervisor_section_of "$rep" REASON | head -c 2000)"
  rejected="$(jqf -cn --arg text "$(supervisor_section_of "$rep" REJECTED | head -c 1000)" '[$text]')"
  evidence="supervisor arbitration report $(basename "$rep")"
  decision="$(decision_entry "Supervisor arbitration: $action" "${reason:-action $action}" "$evidence" "$rejected" supervisor)"
  case "$action" in
    requeue|reroute)
      guidance="$(supervisor_section_of "$rep" GUIDANCE | head -c 4000)"
      [[ -n "${guidance//[[:space:]]/}" ]] || guidance="$reason"
      supervisor_requeue_unit "$id" "$action" "$guidance" "$decision" ;;
    approve)
      u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
      # f11 基线实测 2 次危险 approve（记录里有 main-red/回滚证据仍 approve）：确定性挡板，不靠 prompt 自律。
      if jqf -e '(.handoff_worktree_sha != null and .handoff_worktree_applied != true) or (.handoff_start_sha != null and .handoff_start_applied != true) or (.handoff_integration_sha != null and .handoff_delivery_verified_sha == null)' <<<"$u" >/dev/null; then
        set_unit "$id" "$(hist supervisor-park "approve refused: preserved handoff work has not been transferred" "$decision") | .stage=\"parked\" | .note=$(js "approve refused: preserved handoff work has not been transferred")"
        say "supervisor arbitration unit=$id: approve refused until the handoff is transferred -> parked"
      elif [[ "$(jqf -r '.main_red // false' <<<"$u")" == true ]] \
         || jqf -e '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage=="review-approve") | .key] | max // -1) as $i | any($h[($i + 1):][]; .stage == "merge-reverted")' <<<"$u" >/dev/null; then
        set_unit "$id" "$(hist supervisor-park "approve refused: record shows main-red or post-approval revert evidence" "$decision") | .stage=\"parked\" | .note=$(js "approve refused by the main-red/revert guard")"
        say "supervisor arbitration unit=$id: approve refused by the main-red/revert guard -> parked"
      else
        reviewed_sha="$(jqf -r '.reviewed_sha // empty' <<<"$u")"; reviewed_pr_head="$(jqf -r '.reviewed_pr_head // empty' <<<"$u")"
        if [[ "$reviewed_sha" =~ $SHA_RE && "$reviewed_pr_head" =~ $SHA_RE ]]; then
          set_unit "$id" "$(hist supervisor-approve "$reviewed_sha" "$decision") | .approved_sha=$(js "$reviewed_sha") | .ready_since=(.ready_since // $NOW_EPOCH) | .stage=\"ready-to-merge\""
          post_approved_status "$id" "$reviewed_pr_head"
          say "supervisor arbitration unit=$id: approve -> ready-to-merge at $reviewed_sha"
        else
          # 没有已评审的 head 对：不盲批，交给一次完整评审绑定 head 后再合并。
          set_unit "$id" "$(hist supervisor-approve "no reviewed head pair; routed to a fresh review" "$decision") | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
          say "supervisor arbitration unit=$id: approve without a reviewed head -> fresh review"
        fi
      fi ;;
    park)
      set_unit "$id" "$(hist supervisor-park "$reason" "$decision") | .stage=\"parked\" | .note=$(js "${reason:-parked by supervisor arbitration}")"
      say "supervisor arbitration unit=$id: park" ;;
    close)
      pr="$(unit_field "$id" '.pr // empty')"
      if [[ "$pr" =~ ^[0-9]+$ ]]; then
        gh pr close "$pr" --comment "Autopilot supervisor arbitration: ${reason:-the unit outcome is resolved elsewhere}" >/dev/null 2>&1 \
          || say "supervisor arbitration unit=$id: could not close PR #$pr"
      fi
      set_unit "$id" "$(hist supervisor-close "$reason" "$decision") | .stage=\"closed\""
      say "supervisor arbitration unit=$id: close" ;;
    needs-info)
      question="$(supervisor_section_of "$rep" QUESTION | head -c 1000)"
      [[ -n "${question//[[:space:]]/}" ]] || question="$reason"
      supervisor_needs_info "$id" "$question" "$evidence" ;;
  esac
}

supervisor_apply_jev_action() { # id action confidence event-id → mature, confident Jev decision
  local id="$1" action="$2" confidence="$3" event_id="$4" u reason evidence decision question note
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  reason="Jev selected $action with confidence $confidence after the shadow sample"
  evidence="jev-latest f12 event=$event_id"
  decision="$(decision_entry "TypeSafe Jev: $action" "$reason" "$evidence" '[]' typesafe)"
  case "$action" in
    requeue) supervisor_requeue_unit "$id" requeue "$reason" "$decision" ;;
    recut) supervisor_budget_recut "$id" "$reason (jev-latest f12 event=$event_id)" "$decision" \
      "Jev recut deferred" "Jev arbitration recut" supervisor-park supervisor-jev-recut ;;
    escalate)
      question="$(supervisor_needs_info_question "$u")"
      supervisor_needs_info "$id" "$question" "$evidence" ;;
    park)
      note="$(js "$reason")"
      set_unit "$id" "$(hist supervisor-park "$reason" "$decision") | .stage=\"parked\" | .note=$note"
      say "supervisor arbitration unit=$id: Jev park" ;;
    *) return 1 ;;
  esac
}

supervisor_record_jev_comparison() { # worker-json terra-action → shadow comparison
  local worker="$1" action="$2" jev event_id candidate confidence rollout_ready baseline input
  jev="$(jqf -c '.jev // empty' <<<"$worker")"
  [[ -n "$jev" && "$jev" != null ]] || return 0
  event_id="$(jqf -r '.event_id // empty' <<<"$jev")"
  candidate="$(jqf -r '.candidate // empty' <<<"$jev")"
  confidence="$(jqf -r '.confidence // empty' <<<"$jev")"
  rollout_ready="$(jqf -r '.rollout_ready == true' <<<"$jev")"
  [[ -n "$event_id" && -n "$candidate" && "$confidence" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || return 0
  case "$action" in
    requeue|reroute) baseline=requeue ;;
    needs-info) baseline=escalate ;;
    park) baseline=park ;;
    *) baseline="other:$action" ;;
  esac
  input="$(jqf -cn --arg event_id "$event_id" --arg candidate "$candidate" --arg current "$baseline" \
    --argjson confidence "$confidence" --argjson force_shadow "$([[ "$rollout_ready" == true ]] && echo false || echo true)" \
    '{event_id:$event_id,candidate:$candidate,currentDecision:$current,confidence:$confidence,force_shadow:$force_shadow}')"
  printf '%s\n' "$input" | node "$ROOT/engine/ts-judge.mjs" record f12 >/dev/null 2>&1 || true
}

harvest_supervisor_arbiter() { # worker JSON：回收裁决报告并落地动作；无报告/无 ACTION 行也算消耗一次预算
  local w="$1" unit pid report log action stream tk session_id
  unit="$(jqf -r .unit <<<"$w")"; pid="$(jqf -r .pid <<<"$w")"; report="$(jqf -r .report <<<"$w")"; log="$SUP/$(jqf -r .log <<<"$w")"
  stream="$(python3 "$USAGE_READER" codex-stream "$log" 2>/dev/null || true)"
  tk="$(jqf -r '.fresh // empty' <<<"$stream")"
  [[ "$tk" =~ ^[0-9]+$ ]] && set_unit "$unit" ".tokens = ((.tokens // 0) + $tk)"
  session_id="$(jqf -r '.session_id // empty' <<<"$stream")"
  python3 "$USAGE_READER" codex-ingest "$log" "$session_id" "$(jqf -r .started <<<"$w")" "$BUDGET_EVENTS" >/dev/null 2>&1 || true
  if [[ ! -s "$SUP/$report" ]]; then
    set_unit "$unit" "$(hist supervisor-arbiter-no-output "$(tail -c 200 "$log" 2>/dev/null | tr '\n' ' ')")"
    say "supervisor arbitration unit=$unit: worker produced no report"
  else
    if action="$(supervisor_action_of "$SUP/$report")"; then
      say "supervisor arbitration unit=$unit action=$action"
      supervisor_record_jev_comparison "$w" "$action"
      supervisor_apply_action "$unit" "$action" "$SUP/$report"
    else
      set_unit "$unit" "$(hist supervisor-arbiter-invalid "$(head -c 200 "$SUP/$report" | tr '\n' ' ')")"
      say "supervisor arbitration unit=$unit: no single ACTION line in $report"
    fi
  fi
  jqf --argjson pid "$pid" --arg finished "$STAMP" \
    '(.workers[] |= (if .pid==$pid and .type=="supervise" and .harvested!=true then .harvested=true | .finished_at=$finished else . end))' "$WORKERS" | write_state "$WORKERS"
}
ARBITER_RULE='
【仲裁评审】本单元已多轮返工未收敛（或修复者认为发现不成立、未推新提交）。请按正式评审契约完成一次完整复核，并将作者处置作为逐条复核的输入。'
HOTPATCH_REVIEW_RULE='
【生产热修回迁】本 PR 的补丁已在生产运行，`cihost release-drift-carried.tsv` 提供对应生产状态证据。请将它作为固定点之外的背景材料；正式契约仍决定 finding attribution 与 verdict。（CTO 裁决 2026-10-20）'
# supervisor 对单元的裁决（.note 以 CTO 开头）要进 worker 提示：只写在台账里时评审照样按旧理由 BLOCK，
# 单元又回到 supervisor（2026-10-20 issue-2536 裁决"epic 不是前置"后评审再次 BLOCKED-ON #2535）。
# 裁决累积在 .cto_rulings：.note 会被后来的备注覆盖，旧裁决随之丢失（2026-10-21 issue-2536 改派定点修复时
# 覆盖了"#2535 是 epic"，评审第三次 BLOCKED-ON #2535）。
supervisor_rule() {
  local note r
  note="$(jqf -r '.note // ""' <<<"$1")"
  [[ "$note" == CTO* ]] && printf '\n【supervisor 裁决（必须遵守，不得据此 BLOCK 或打回）】%s' "$note"
  while IFS= read -r r; do
    [[ -n "$r" && "$r" != "$note" ]] && printf '\n【supervisor 裁决（必须遵守，不得据此 BLOCK 或打回）】%s' "$r"
  done < <(jqf -r '(.cto_rulings // [])[]' <<<"$1")
  return 0
}
decision_scope() { # unit-json -> prior decisions in history, for the next implementation worker
  local decisions
  decisions="$(jqf -r '[(.history // [])[] | select(.decision != null) |
    "- \(.at // "") [\(.decision.owner // "")] \(.decision.decision // "")\n  Why: \(.decision.why // "")\n  Evidence: \(.decision.evidence // "")\n  Rejected: \((.decision.rejected // []) | if type == "array" then join(", ") else tostring end)"] | join("\n")' <<<"$1")"
  [[ -n "$decisions" ]] || return 0
  printf 'Decided earlier (do not reopen without new evidence):\n%s' "$decisions"
}
hotpatch_rule() { [[ "$(jqf -r '.hotpatch // false' <<<"$1")" == true ]] && printf '%s' "$HOTPATCH_REVIEW_RULE"; return 0; }
arbiter_rule() { [[ "$(jqf -r '.arbiter // false' <<<"$1")" == true ]] && printf '%s' "$ARBITER_RULE"; return 0; }
risk_class_safety_rule() { # checkout → safety prompt for risk classes found by the repository classifier
  local checkout="$1" hits classes paths
  [[ -n "$checkout" && -d "$checkout" ]] || return 0
  hits="$(cd "$checkout" && node "$HERE/../risk-class.mjs" --json origin/main...HEAD 2>/dev/null)" || return 0
  classes="$(jq -r '[.[].kind] | unique | join(", ")' <<<"$hits" 2>/dev/null)"
  [[ -n "$classes" ]] || return 0
  paths="$(jq -r '.[] | "- \(.kind): \(.path)"' <<<"$hits")"
  printf '\nRisk-class paths from the existing classifier (%s):\n%s\n' "$classes" "$paths"
}
lane_rule() { # lane sha
  [[ "$1" == direct-main ]] || return 0
  printf '%s' "
本单元走非产品快车道（direct-main）：评审对象是本 clone 当前检出的提交 $2，它可能只在本地、尚未推到 PR 或根本没有 PR（非产品改动不开 PR、不推 topic），GitHub 上的 PR head、PR diff 与 CI 状态因此不同步属正常——diff 以本地 git 为准，不用 gh pr diff。批准后流水线把它压成一个提交经 land-direct-main.sh 直落 main（落地时跑 focused 检查，suites 在落地后跑）。PR head 不同步、无 CI run、交付路径都不是阻断理由。"
}
subject_of() { # pr issue → 评审/修复对象的称呼（无 PR 的直落单元用 issue 或单元 id）
  if [[ -n "$1" ]]; then printf 'PR #%s' "$1"; elif [[ -n "$2" ]]; then printf 'issue #%s 的本地实现（无 PR）' "$2"; else printf '本地实现（无 PR）'; fi
}
review_prompt() { # pr-or-subject title sha report [lane] [checkout]
  local subject="$1"; [[ "$subject" =~ ^[0-9]+$ ]] && subject="PR #$subject"
  printf '%s' "你是 the product 流水线的独立代码评审 subagent，只读【增量评审】（diff-scoped，不做全库漫游）。当前目录是隔离 clone，已检出被评审提交（detached），origin/main 为最新 main；本地 diff：git diff origin/main...HEAD。评审 ${subject}（$2）fixed head $3：
评审面：① diff（merge-base..head）与关联 issue 验收条件逐条对照；② 变更文件的直接 import/依赖闭包；③ 只读边界下可核实的测试与行为证据。
请完整读取并遵守正式评审契约，按其要求评审与交付。$(review_contract_rule "${6:-.}")
效率纪律：不重述代码内容；不展开未变更文件的细节；低风险样式性改动一行带过。目标 15-25 分钟内交付。
只读边界：不编辑/commit/push/merge/评论。报告写到 $SUP/$4。落盘后交付完即结束。$(risk_class_safety_rule "${6:-}")$(lane_rule "${5:-}" "$3")"
}

pr_view() { gh pr view "$1" --json "$2" --jq ".$2" 2>/dev/null; }
tick_pr_head() { # PR → head SHA from this tick's open-PR census, with a direct fallback for a census miss
  local pr="$1" prs head
  prs="$(tick_prs 2>/dev/null || true)"
  if [[ -n "$prs" ]]; then
    head="$(jqf -r --argjson p "$pr" '[.[] | select(.number == $p) | .headRefOid][0] // empty' <<<"$prs")"
  fi
  [[ "$head" =~ $SHA_RE ]] || head="$(pr_view "$pr" headRefOid)" || return 1
  [[ "$head" =~ $SHA_RE ]] || return 1
  printf '%s\n' "$head"
}

# 非产品快车道（2026-10-19 CTO 裁决）：PR 改动全是非产品路径 → lane=direct-main，优先派发，
# 批准后由 land worker 压成 [skip ci] 提交经 land-direct-main.sh 直落 main（不走 PR CI 等待与合并车道）。
POLICY_SCRIPT="${AUTOPILOT_POLICY_SCRIPT:-$ROOT/scripts/branch-delivery-policy.mjs}"
classify_lane() { # pr → direct-main|pr（取不到文件列表返回 1）
  local files json verdict
  # The REST file list includes previous_filename for renames; both sides must be classified.
  # gh refuses --slurp together with --jq (exit 1 before any request): from 10-20 every call failed, 506 a hour on
  # 10-22, and no unit got a lane, so non-product PRs never took the direct-main lane. --jq runs per page instead.
  files="$(gh api --paginate "repos/{owner}/{repo}/pulls/$1/files" \
    --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null)" || return 1
  json="$(jq -Rsc 'split("\n") | map(select(length > 0))' <<<"$files")" || return 1
  [[ "$json" != '[]' ]] || return 1
  verdict="$(node "$POLICY_SCRIPT" --classify-path-set - <<<"$json" 2>/dev/null)" || return 1
  [[ "$verdict" == eligible ]] && echo direct-main || echo pr
}
lane_policy_blob() { git -C "$ROOT" rev-parse "HEAD:${POLICY_SCRIPT#"$ROOT"/}" 2>/dev/null || echo unknown; }
fast_land_candidates() { # → 快车道要看的 ready-to-merge 单元（每行一个 JSON）
  # 记成 pr 车道但分类策略已变的单元也要进来，让 ensure_lane 重分；只取 lane != pr 时它们永远留在产品车道
  # （10-22：94 个待合并单元里 35 个策略过期，其中 4 个非产品 PR 一直排 CI 名额）。
  jqf -c --arg p "$(lane_policy_blob)" '[.units[] | select(.stage=="ready-to-merge" and (.hold_handoff_waiting // false) == false
      and ((.pr // null) != null or (.lane // "") == "direct-main")
      and ((.lane // "") != "pr" or (.lane_policy // "") != $p))] | sort_by(.ready_since // 0) | .[]' "$UNITS"
}
ensure_lane() { # id pr → 打印并记录 lane
  # 分类随策略文件变：pr 车道的单元在 branch-delivery-policy.mjs 改动后重分一次（10-22 R1 把 workflow 划进直落 main，
  # 之前被记成 pr 的 #4044 若不重分会永远走产品 PR 车道）。direct-main 不回退：PR 新增产品路径会在派发前被拒。
  local lane policy; lane="$(unit_field "$1" .lane)"
  policy="$(lane_policy_blob)"
  if [[ -z "$lane" || ( "$lane" == pr && "$(unit_field "$1" '.lane_policy // empty')" != "$policy" ) ]]; then
    lane="$(classify_lane "$2")" || return 1
    set_unit "$1" ".lane=\"$lane\" | .lane_policy=\"$policy\""
  fi
  printf '%s' "$lane"
}
# 评审目标绑定一对 SHA：远端 PR head 是审核时观察到的基线，候选 SHA 可以是该 head 的本地修复后代。
unit_review_target() { # id pr lane branch → <pr-head> <candidate-sha>
  local pr_head local_head dir="$WT_ROOT/wt-$1"
  if [[ -z "$2" ]]; then
    # 无 PR 的直落单元：候选是本地分支 head，基线是它与 main 的分叉点（批准绑定这一对）。
    [[ "$3" == direct-main && -n "$4" && -d "$dir/.git" ]] || return 1
    local_head="$(git -C "$dir" rev-parse -q --verify "refs/heads/$4" 2>/dev/null)"
    pr_head="$(git -C "$dir" merge-base refs/remotes/origin/main "$local_head" 2>/dev/null)"
    [[ "$local_head" =~ $SHA_RE && "$pr_head" =~ $SHA_RE && "$local_head" != "$pr_head" ]] || return 1
    printf '%s %s' "$pr_head" "$local_head"; return 0
  fi
  pr_head="$(tick_pr_head "$2")" || return 1
  if [[ "$3" == direct-main && -n "$4" && -d "$dir/.git" ]]; then
    local_head="$(git -C "$dir" rev-parse -q --verify "refs/heads/$4" 2>/dev/null)"
    if [[ "$local_head" =~ $SHA_RE && "$local_head" != "$pr_head" ]] \
      && git -C "$dir" merge-base --is-ancestor "$pr_head" "$local_head" 2>/dev/null; then
      printf '%s %s' "$pr_head" "$local_head"; return 0
    fi
  fi
  printf '%s %s' "$pr_head" "$pr_head"
}
unit_head() { # id pr lane branch → candidate SHA (compatibility helper)
  local target
  target="$(unit_review_target "$1" "$2" "$3" "$4")" || return 1
  printf '%s' "${target#* }"
}

launch_land() { # id pr sha title report log workdir reviewed-pr-head [issue]
  local pid w
  (cd "$7" && exec setsid bash "$HERE/land-pr.sh" "$7" "$2" "$3" "$4" "$SUP/$5" "$8" "${9:-}") > "$SUP/$6" 2>&1 < /dev/null &
  pid=$!
  w="$(jqf -cn --argjson pid "$pid" --arg unit "$1" --arg log "$6" --arg report "$5" --arg at "$STAMP" --arg sha "$3" --arg pr_head "$8" --arg workdir "$7" \
    '{pid:$pid,unit:$unit,type:"land",log:$log,report:$report,started:$at,sha:$sha,pr_head:$pr_head,workdir:$workdir,model:"none"}')"
  jqf --argjson w "$w" '.workers += [$w]' "$WORKERS" | write_state "$WORKERS"
  say "dispatch land pid=$pid unit=$1 PR#${2:-none} sha=$3"
}
fast_land_lane() { # 一次只落一个；与产品合并门禁无关（land-direct-main 自带 focused 检查与锁）
  local u id pr approved target head candidate reviewed_pr_head title wt rep
  [[ "$(jqf -r .auto_merge <<<"$CFG")" == "true" ]] || return 0
  jqf -e 'any(.units[]; .stage=="landing")' "$UNITS" >/dev/null && return 0
  while read -r u; do
    id="$(jqf -r .id <<<"$u")"; pr="$(jqf -r '.pr // empty' <<<"$u")"; approved="$(jqf -r '.approved_sha // empty' <<<"$u")"
    [[ "$(ensure_lane "$id" "$pr")" == direct-main ]] || continue
    target="$(unit_review_target "$id" "$pr" direct-main "$(jqf -r '.branch // empty' <<<"$u")")" || {
      set_unit "$id" "$(hist approval-stale 'current PR head unavailable') | .approved_sha=null | .stage=\"rereview-pending\""
      continue
    }
    read -r head candidate <<<"$target"
    reviewed_pr_head="$(jqf -r '.reviewed_pr_head // empty' <<<"$u")"
    if [[ ! "$approved" =~ $SHA_RE || ! "$reviewed_pr_head" =~ $SHA_RE \
      || "$head" != "$reviewed_pr_head" || "$candidate" != "$approved" ]]; then
      set_unit "$id" "$(hist approval-stale "approved=${approved:-none} reviewed-pr-head=${reviewed_pr_head:-none} current-pr-head=$head candidate=$candidate") | .approved_sha=null | .stage=\"rereview-pending\""
      continue
    fi
    wt="$(ensure_clone "$id")" || { say "fast-land unit=$id: clone unavailable"; continue; }
    title="$(jqf -r '.title // ""' <<<"$u")"; rep="land-${pr:-$id}-${TAG}.md"
    launch_land "$id" "$pr" "$approved" "$title" "$rep" "${rep%.md}.worker.log" "$wt" "$reviewed_pr_head" "$(jqf -r '.issue // empty' <<<"$u")"
    set_unit "$id" "$(hist land-issued "${pr:+PR#$pr }$approved") | .stage=\"landing\""
    return 0
  done < <(fast_land_candidates)
}

# 无 PR 的直落实现：本地提交 → 评审本地提交 → 直落 main；OBSOLETE 直接结案，NEEDS-PR 转人工开 PR。
harvest_prless_implement() { # unit report-path [local-only]
  local first issue branch dir local_head
  first="$(grep -m1 -v '^[[:space:]]*$' "$2" 2>/dev/null)"
  issue="$(unit_field "$1" .issue)"; branch="$(unit_field "$1" .branch)"; dir="$WT_ROOT/wt-$1"
  local dep; dep="$(blocked_on_of "$2")"
  [[ -n "$dep" ]] && { park_blocked "$1" "$dep"; return 0; }
  case "$first" in
    OBSOLETE:*)
      [[ "${3:-false}" != true ]] || return 1
      [[ -n "$issue" ]] && gh issue close "$issue" --comment "Autopilot: no change needed on current main. ${first}" >/dev/null 2>&1
      set_unit "$1" "$(hist obsolete "$first") | .stage=\"closed\""
      say "unit $1 obsolete: $first"; return 0 ;;
    NEEDS-PR:*)
      # 要改产品或工作流路径：转 PR 车道重做（PR 车道可以改这些路径，CI 与评审照常把关）。
      set_unit "$1" "$(hist needs-pr "$first") | .lane=\"pr\" | .branch=\"agent/${issue:+issue-}${issue:-$1}\" | .task += ($(js "

上一轮在直落车道判断：${first}。本轮走 PR 车道，可以改产品/工作流路径。")) | .stage=\"implement-pending\""
      say "unit $1 needs a PR -> PR lane"; return 0 ;;
  esac
  local_head="$(git -C "$dir" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null)"
  if [[ "$local_head" =~ $SHA_RE ]] && [[ -n "$(git -C "$dir" rev-list -n1 "refs/remotes/origin/main..$local_head" 2>/dev/null)" ]]; then
    set_unit "$1" "$(hist delivered "local commit $local_head") | .stage=\"review-pending\""
    say "unit $1 implemented locally at $local_head -> review-pending"
  elif [[ "$(unit_retries "$1" implement-no-commit)" == 0 ]]; then
    set_unit "$1" "$(hist implement-no-commit "$(basename "$2")") | .task += $(js "

上一轮交付了报告但分支 ${branch} 上没有本地提交：本轮必须在该分支提交改动（或按协议写 OBSOLETE:/NEEDS-PR:）。") | .stage=\"implement-pending\""
  else
    to_supervisor "$1" "implement delivered no local commit on $branch twice (report $(basename "$2"))"
  fi
}

# 依赖链（2026-10-20：#3680–#3686 是同一张日报的串行票，前置未交付时 worker 正确地拒绝动手）：
# 报告写 BLOCKED-ON #N → 单元停在 blocked-external（不占开发产能），前置单元合并/落地或 issue 关闭后自动回到 implement-pending。
# 前 12 行认宽松写法；协议标记 `BLOCKED-ON: #N` 全文都认（#3469 评审把它写在第 16 行，被当成无前置的阻塞升级）。
# Issue-body dependency dispatch contract: docs/agents/issue-pipeline.md#autopilot-issue-body-dependencies (#4485).
blocked_on_of() {
  { head -12 "$1" | grep -oiE 'BLOCKED[- ]?(ON|BY)[^0-9#]{0,12}#?[0-9]+'; grep -oE 'BLOCKED-ON:[[:space:]]*#[0-9]+' "$1"; } 2>/dev/null \
    | grep -oE '[0-9]+$' | head -1
}
park_blocked() { # unit dep
  # 生产热修回迁不等前置（代码已在线）：第一次退回按热修规则重评，第二次交 supervisor（pr-3596 被 #3145 挡住）。
  if [[ "$(unit_field "$1" '.hotpatch // false')" == true ]]; then
    if jqf -e --arg id "$1" 'any(.units[]; .id == $id and any(.history[]?; .stage == "hotpatch-not-blocked"))' "$UNITS" >/dev/null; then
      to_supervisor "$1" "hot-patch forward-port blocked on #$2 twice"
    else
      set_unit "$1" "$(hist hotpatch-not-blocked "#$2") | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
      say "unit $1 is a production hot-patch forward-port; predecessor #$2 does not block it -> fresh review"
    fi
    return 0
  fi
  set_unit "$1" "$(hist blocked-on "#$2") | .blocked_on=$2 | .note=$(js "waiting for predecessor #$2") | .stage=\"blocked-external\""
  say "unit $1 blocked on predecessor #$2"
}
# 正文 `## Blocked by` 只认小节内的 issue 引用；小节外的 #N 不算前置（#4485 正文自己就引用了 #4384/#4486）。
blocked_by_ids_from_body() { # stdin: issue body → references within its Blocked by section
  awk 'tolower($0) ~ /^#+[[:space:]]*blocked[[:space:]]+by([[:space:]:]|$)/{s=1;next} s && /^#/{s=0} s' \
    | grep -oE '#[0-9]+' | tr -d '#' | awk '!p[$0]++' || true
}
issue_body_blocked_by() { # stdin: saved task text → refs from its issue-body section
  local task body
  task="$(cat)"
  body="$(awk '/^--- issue 正文（任务数据）---$/{b=1;next} /^--- 正文结束 ---$/{b=0} b' <<<"$task")"
  blocked_by_ids_from_body <<<"$body"
}
unit_body_blockers() { # unit-json → stored full-body IDs, or fallback IDs from older task text
  if jqf -e '(.body_blocked_by | type)=="array"' <<<"$1" >/dev/null; then
    jqf -r '.body_blocked_by[] | select(type=="number")' <<<"$1"
  else
    issue_body_blocked_by <<<"$(jqf -r '.task // ""' <<<"$1")"
  fi
}
declare -A DEP_DELIVERED_CACHE=()
dep_delivered_in_ledger() { # release_dependency_blocks 从台账建一次快照，避免每个 blocker 重读全文件
  [[ "${DEP_DELIVERED_CACHE[$1]:-}" == 1 ]]
}
# 正文依赖状态由 release_dependency_blocks 按 DEP_CHECK_SECONDS 批量缓存；派发门禁只读缓存，不逐单元调用 GitHub。
dep_cache_info() { # predecessor issue → cached {state,labels} or {}
  jqf -c --arg d "$1" '.states[$d] // {}' "$A/dep-check.cache.json" 2>/dev/null || echo '{}'
}
unit_body_declares_dependency() { # unit predecessor-issue → true when the issue body explicitly names this prerequisite
  unit_body_blockers "$1" | grep -Fxq "$2"
}
blocking_body_dependency() { # unit-json → first predecessor not yet delivered/cleared by the local cache
  local dep info state labels
  while read -r dep; do
    [[ "$dep" =~ ^[0-9]+$ ]] || continue
    dep_delivered_in_ledger "$dep" && continue
    info="$(dep_cache_info "$dep")"
    state="$(jqf -r '.state // empty' <<<"$info")"
    [[ "$state" == CLOSED || "$state" == MERGED ]] && continue
    labels="$(jqf -r '.labels // ""' <<<"$info")"
    [[ "$state" == OPEN && ",$labels," =~ ,roadmap(-epic|-theme)?, ]] && continue
    printf '%s' "$dep"; return 0
  done < <(unit_body_blockers "$1")
  return 1
}
park_if_body_blocked() { # unit-json → 0 当按正文前置停住（不派发）
  local id dep
  id="$(jqf -r .id <<<"$1")"
  dep="$(blocking_body_dependency "$1")" || return 1
  park_blocked "$id" "$dep"
}
# 前置状态每 DEP_CHECK_SECONDS（默认 600）向 GitHub 刷新一次，同一前置每拍只查一次：逐单元 gh issue view
# 让这一步占了一拍 58 秒（2026-10-20，42 个 blocked 单元）。台账内可判定的（已交付、互等）仍每拍处理。
# 一拍 500–660 秒，600 秒的刷新几乎每拍都到期；逐个前置 gh issue view（39 个）一拍 60 秒（10-21 09:10）。
# 改成一次 GraphQL 批量查；issueOrPullRequest 让前置是 PR 号时也能判（gh issue view 对 PR 号失败，永远放不开）。
dep_states() { # issue/PR 号… → 每行 "号<TAB>STATE<TAB>标签,…"；一次 GraphQL 调用
  (( $# > 0 )) || return 0
  local q="" d
  for d in "$@"; do
    q+=" i$d: issueOrPullRequest(number: $d) { ... on Issue { state labels(first: 30) { nodes { name } } } ... on PullRequest { state labels(first: 30) { nodes { name } } } }"
    q+=" p$d: pullRequests(headRefName: \"agent/issue-$d\", states: MERGED, first: 1) { totalCount }"
  done
  # issue 要到发布后才关（close-after-release）：只看 issue 状态，前置合并了后继还要多等一整个发布周期
  # （10-22 #3122/#3431 已合并、后继仍停着）。流水线的实现分支是 agent/issue-N：它的 PR 合并即交付。
  gh api graphql -F owner='{owner}' -F name='{repo}' -f query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {$q } }" \
    --jq '.data.repository | . as $r | to_entries[] | select((.key | startswith("i")) and .value != null) | .key[1:] as $d
      | "\($d)\t\(if ($r["p" + $d].totalCount // 0) > 0 then "MERGED" else .value.state end)\t\([.value.labels.nodes[].name] | join(","))\t\(.value.state)"' 2>/dev/null
}
stack_pilot_label() { jqf -r 'if .stacking.enabled == false then "" else (.stacking.pilot_label // "stack-pilot") end' <<<"$CFG"; }
unit_has_stack_pilot() { # unit-json
  local label; label="$(stack_pilot_label)"
  [[ -n "$label" ]] && jqf -e --arg label "$label" 'any(.labels[]?; if type=="string" then .==$label else .name==$label end)' <<<"$1" >/dev/null 2>&1
}
stack_approved_dependency() { # dependent unit-id issue-number unit-json; 0 when an approved local predecessor releases this pilot unit
  local child="$1" dep="$2" unit="${3:-}" predecessor pr_number approved head state snapshot prs
  [[ -n "$unit" ]] || unit="$(jqf -c --arg id "$child" '.units[] | select(.id==$id)' "$UNITS")"
  unit_has_stack_pilot "$unit" || return 1
  jqf -e '.lane=="pr"' <<<"$unit" >/dev/null || return 1
  jqf -e '(.stacked_on // null)==null' <<<"$unit" >/dev/null || return 1
  predecessor="$(jqf -c --argjson dep "$dep" '.units[] | select(.issue==$dep and .stage=="ready-to-merge"
    and .lane=="pr" and (.pr | type)=="number" and (.branch | type)=="string" and (.branch|length)>0
    and (.approved_sha | type)=="string" and (.approved_sha|test("^[0-9a-f]{40}$"))
    and .reviewed_pr_head==.approved_sha)' "$UNITS")"
  [[ -n "$predecessor" ]] || return 1
  pr_number="$(jqf -r .pr <<<"$predecessor")"; approved="$(jqf -r .approved_sha <<<"$predecessor")"
  prs="$(tick_prs 2>/dev/null)" || prs='[]'
  snapshot="$(jqf -c --argjson pr_number "$pr_number" '[.[] | select(.number==$pr_number) | {headRefOid}] | .[0] // empty' <<<"$prs")"
  if [[ -n "$snapshot" ]]; then
    state=OPEN; head="$(jqf -r '.headRefOid // empty' <<<"$snapshot")"
  else
    snapshot="$(gh pr view "$pr_number" --json state,headRefOid 2>/dev/null)" || return 1
    state="$(jqf -r '.state // empty' <<<"$snapshot")"; head="$(jqf -r '.headRefOid // empty' <<<"$snapshot")"
  fi
  [[ "$state" == OPEN && "$head" == "$approved" ]] || return 1
  stack_initial_branch "$child" "$(jqf -r .branch <<<"$predecessor")" "$approved" || {
    say "unit $child remains waiting: could not base its branch on $(jqf -r .id <<<"$predecessor")@$approved"
    return 1
  }
  set_unit "$child" "$(hist stacked_on "$(jqf -r .id <<<"$predecessor")@$approved") | .stacked_on=$(js "$(jqf -r .id <<<"$predecessor")@$approved") | .stacked_on_unit=$(js "$(jqf -r .id <<<"$predecessor")") | .stacked_on_sha=$(js "$approved") | .stacked_on_branch=$(js "$(jqf -r .branch <<<"$predecessor")") | .stage=\"implement-pending\""
  say "unit $child stacked on $(jqf -r .id <<<"$predecessor")@$approved"
  return 0
}
release_dependency_blocks() {
  local id dep issue info state labels gh_due=1 last decision dep_results dep_states_json dep_cache_file dep_cache u
  local blocker_issue pair_key
  local -a deps=() unique_deps=()
  local -A DEP_BLOCKED_PAIR_COUNTS=()
  DEP_DELIVERED_CACHE=()
  while IFS= read -r dep; do
    [[ "$dep" =~ ^[0-9]+$ ]] && DEP_DELIVERED_CACHE["$dep"]=1
  done < <(jqf -r '.units[] | select(.stage | IN("merged","landed","awaiting-live-event"))
    | ((.issue | select(type == "number")),
       (if ((.branch // "") | test("^agent/issue-[0-9]+$")) then (.branch | sub("^agent/issue-"; "") | tonumber) else empty end))' "$UNITS")
  while IFS=$'\t' read -r blocker_issue dep; do
    [[ "$blocker_issue" =~ ^[0-9]+$ && "$dep" =~ ^[0-9]+$ ]] || continue
    pair_key="$blocker_issue:$dep"
    DEP_BLOCKED_PAIR_COUNTS["$pair_key"]=$((${DEP_BLOCKED_PAIR_COUNTS[$pair_key]:-0} + 1))
  done < <(jqf -r '.units[] | select(.stage=="blocked-external" and .blocked_on != null and (.issue | type)=="number") | [.issue,.blocked_on] | @tsv' "$UNITS")
  dep_cache_file="$A/dep-check.cache.json"
  last="$(cat "$A/dep-check.epoch" 2>/dev/null)"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - last < ${DEP_CHECK_SECONDS:-600} )); then gh_due=0; else echo "$NOW_EPOCH" > "$A/dep-check.epoch"; fi
  if (( gh_due )); then
    while IFS= read -r dep; do
      [[ "$dep" =~ ^[0-9]+$ ]] || continue
      dep_delivered_in_ledger "$dep" || deps+=("$dep")
    done < <(jqf -r '[.units[] | select(.stage=="blocked-external" and .blocked_on != null) | .blocked_on | numbers] | unique | .[]' "$UNITS")
    while IFS= read -r u; do
      while IFS= read -r dep; do
        [[ "$dep" =~ ^[0-9]+$ ]] || continue
        dep_delivered_in_ledger "$dep" || deps+=("$dep")
      done < <(unit_body_blockers "$u")
    done < <(jqf -c '.units[] | select(.stage=="implement-pending" or (.stage=="repair-pending" and .hold_handoff_episode != null))' "$UNITS")
    if (( ${#deps[@]} > 0 )); then
      while IFS= read -r dep; do [[ -n "$dep" ]] && unique_deps+=("$dep"); done \
        < <(printf '%s\n' "${deps[@]}" | sort -n -u)
      dep_results="$(dep_states "${unique_deps[@]}" 2>/dev/null || true)"
      dep_states_json="$(printf '%s\n' "$dep_results" | jqf -Rn '
        [inputs | split("\t") | select(length >= 2 and .[0] != "" and .[1] != "")]
        | map({key:.[0],value:{state:.[1],labels:(.[2] // ""),issue_state:(.[3] // "")}}) | from_entries')"
    else
      dep_states_json='{}'
    fi
    jqf -cn --argjson epoch "$NOW_EPOCH" --argjson states "$dep_states_json" \
      '{epoch:$epoch,states:$states}' > "$dep_cache_file.tmp" && mv "$dep_cache_file.tmp" "$dep_cache_file"
  fi
  dep_cache="$(jqf -c 'if (.states|type)=="object" then .states else {} end' "$dep_cache_file" 2>/dev/null || echo '{}')"
  while IFS= read -r u; do
    id="$(jqf -r '.id' <<<"$u")"; dep="$(jqf -r '.blocked_on' <<<"$u")"; issue="$(jqf -r '.issue // empty' <<<"$u")"
    [[ "$dep" =~ ^[0-9]+$ ]] || continue
    if jqf -e '.size_recut_pending==true' <<<"$u" >/dev/null; then continue; fi
    if jqf -e '.stacked_on != null and .stacked_on_released != true' <<<"$u" >/dev/null \
        && ! unit_body_declares_dependency "$u" "$dep"; then continue; fi
    if dep_delivered_in_ledger "$dep"; then
      dep_blocker_forget "$issue" "$dep"
      unblock_unit "$id" "#$dep delivered"; continue
    fi
    # 两个单元互相等对方（2026-10-20 #2743↔#3330）：放开这一个，另一个继续等它交付。
    pair_key="$dep:$issue"
    if [[ "$issue" =~ ^[0-9]+$ && "${DEP_BLOCKED_PAIR_COUNTS[$pair_key]:-0}" =~ ^[1-9][0-9]*$ ]]; then
      dep_blocker_forget "$issue" "$dep"
      unblock_unit "$id" "#$dep waits on #$issue: dependency cycle broken here"; continue
    fi
    info="$(jqf -c --arg d "$dep" '.[$d] // empty' <<<"$dep_cache")"; [[ -n "$info" ]] || continue
    state="$(jqf -r '.state // empty' <<<"$info")"; labels="$(jqf -r '.labels // ""' <<<"$info")"
    if (( gh_due )) && [[ "$state" == OPEN ]] && ! unit_body_declares_dependency "$u" "$dep" \
        && stack_approved_dependency "$id" "$dep" "$u"; then continue; fi
    if [[ "$state" == CLOSED || "$state" == MERGED ]]; then
      dep_blocker_forget "$issue" "$dep"
      unblock_unit "$id" "#$dep delivered"; continue
    fi
    # 路线图 epic/主题是伞形 issue，永远不会"交付"；停在它上面就是永远停（2026-10-20 六个单元）。放开一次，
    # 同一个 epic 第二次停住就交给 supervisor。
    if [[ ",$labels," =~ ,roadmap(-epic|-theme)?, ]]; then
      if jqf -e --arg id "$id" --arg r "#$dep" 'any(.units[]; .id == $id and any(.history[]?; .stage == "epic-not-predecessor" and .result == $r))' "$UNITS" >/dev/null; then
        dep_blocker_forget "$issue" "$dep"
        decision="$(decision_entry 'Hand off repeated roadmap block to supervisor' 'the same roadmap epic blocked this unit twice' "history contains repeated epic-not-predecessor events for #$dep" '["Keep waiting for the roadmap epic to close"]' scheduler)"
        set_unit "$id" "$(hist supervisor-escalated "parked twice on roadmap epic #$dep" "$decision") | del(.blocked_on) | .note=$(js "parked twice on roadmap epic #$dep: decide scope") | .stage=\"supervisor-review\""
        say "unit $id escalated: parked twice on roadmap epic #$dep"
      else
        dep_blocker_forget "$issue" "$dep"
        set_unit "$id" "$(hist epic-not-predecessor "#$dep") | del(.blocked_on) | .note=$(js "#$dep is a roadmap epic, not a predecessor: implement this slice") | .stage=(if .blocked_resume_stage == \"repair-pending\" then \"repair-pending\" elif .pr != null then \"review-pending\" else \"implement-pending\" end) | del(.blocked_resume_stage)"
        say "unit $id released: #$dep is a roadmap epic, not a predecessor"
      fi
    fi
  done < <(jqf -c '.units[] | select(.stage=="blocked-external" and .blocked_on != null)' "$UNITS")
  # 停在 blocked-external 却没有前置号的单元没有任何机制会放开它（issue-2536）：交 supervisor。
  for id in $(jqf -r '.units[] | select(.stage=="blocked-external" and .blocked_on == null and .size_recut_pending != true) | .id' "$UNITS"); do
    to_supervisor "$id" "blocked-external without a predecessor: nothing can release it"
  done
  if (( gh_due )); then reconcile_stacked_units; fi
}
dep_blocker_forget() { # dynamic local map: keep mutual-cycle checks current as units leave blocked-external
  local key="$1:$2" count
  count="${DEP_BLOCKED_PAIR_COUNTS[$key]:-0}"
  if (( count > 1 )); then
    DEP_BLOCKED_PAIR_COUNTS["$key"]=$((count - 1))
  else
    unset "DEP_BLOCKED_PAIR_COUNTS[$key]"
  fi
}
unblock_unit() { # unit reason
  set_unit "$1" "$(hist unblocked "$2") | del(.blocked_on) | .note=null | .stage=(if .blocked_resume_stage == \"repair-pending\" then \"repair-pending\" elif .pr != null then \"review-pending\" else \"implement-pending\" end) | del(.blocked_resume_stage)"
  say "unit $1 unblocked: $2"
}

stack_initial_branch() { # unit base-branch base-sha; rebase existing implementation work onto a newly approved predecessor
  local id="$1" branch base_sha="$3" remote_head wt base_ref child_head fork_sha child_count pr
  branch="$(unit_field "$id" .branch)"
  [[ -n "$branch" && "$base_sha" =~ $SHA_RE ]] || return 1
  remote_head="$(git -C "$ROOT" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ "$remote_head" =~ $SHA_RE ]]; then
    wt="$(ensure_clone "$id" "$branch" 1 "$remote_head" "$2" "$base_sha")" || return 1
  else
    wt="$(ensure_clone "$id" "$branch" 0 "" "$2" "$base_sha")" || return 1
  fi
  base_ref="refs/remotes/origin/$2"
  child_head="$(git -C "$wt" rev-parse -q --verify "refs/heads/$branch^{commit}" 2>/dev/null)" || return 1
  if ! git -C "$wt" merge-base --is-ancestor "$base_sha" "$child_head" 2>/dev/null; then
    fork_sha="$(git -C "$wt" merge-base "$child_head" "$base_ref" 2>/dev/null)" || return 1
    child_count="$(git -C "$wt" rev-list --count "$fork_sha..$branch" 2>/dev/null)" || return 1
    if [[ "$child_count" == 0 ]]; then
      git -C "$wt" checkout -q "$branch" && git -C "$wt" reset --hard "$base_ref" >/dev/null || return 1
    else
      git -C "$wt" rebase --onto "$base_ref" "$fork_sha" "$branch" >/dev/null 2>&1 || {
        git -C "$wt" rebase --abort >/dev/null 2>&1 || :
        return 1
      }
    fi
  fi
  child_head="$(git -C "$wt" rev-parse "refs/heads/$branch^{commit}")" || return 1
  if [[ "$remote_head" =~ $SHA_RE ]]; then
    if [[ "$child_head" != "$remote_head" ]]; then
      git -C "$wt" push -q --force-with-lease="refs/heads/$branch:$remote_head" origin "$branch" || return 1
    fi
  elif [[ "$child_head" != "$base_sha" ]]; then
    git -C "$wt" push -q -u origin "$branch" || return 1
  fi
  pr="$(unit_field "$id" '.pr // empty')"
  if [[ "$pr" =~ ^[0-9]+$ ]]; then gh pr edit "$pr" --base "$2" >/dev/null 2>&1 || return 1; fi
}

restack_branch() { # unit base-branch base-sha; rebase only this unit's commits and publish against the observed child head
  local id="$1" branch="$2" base_sha="$3" old_base old_base_branch pr remote_head wt base_ref child_head child_count
  branch="$(unit_field "$id" .branch)"; old_base="$(unit_field "$id" '.stacked_on_sha // empty')"
  old_base_branch="$(unit_field "$id" '.stacked_on_branch // empty')"; pr="$(unit_field "$id" '.pr // empty')"
  [[ "$branch" ]] && [[ "$base_sha" =~ $SHA_RE ]] && [[ "$old_base" =~ $SHA_RE ]] || return 1
  remote_head="$(git -C "$ROOT" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ "$remote_head" =~ $SHA_RE ]]; then
    wt="$(ensure_clone "$id" "$branch" 1 "$remote_head" "$2" "$base_sha")" || return 1
  else
    wt="$(ensure_clone "$id" "$branch" 0 "" "$2" "$base_sha")" || return 1
  fi
  base_ref="refs/remotes/origin/$2"
  child_head="$(git -C "$wt" rev-parse -q --verify "refs/heads/$branch^{commit}" 2>/dev/null)" || return 1
  if git -C "$wt" merge-base --is-ancestor "$old_base" "$child_head" 2>/dev/null; then
    child_count="$(git -C "$wt" rev-list --count "$old_base..$branch" 2>/dev/null)" || return 1
    if [[ "$child_count" == 0 ]]; then
      git -C "$wt" checkout -q "$branch" && git -C "$wt" reset --hard "$base_ref" >/dev/null || return 1
    else
      git -C "$wt" rebase --onto "$base_ref" "$old_base" "$branch" >/dev/null 2>&1 || {
        git -C "$wt" rebase --abort >/dev/null 2>&1 || :
        return 1
      }
    fi
  elif ! git -C "$wt" merge-base --is-ancestor "$base_ref" "$child_head" 2>/dev/null; then
    return 1
  fi
  if [[ "$remote_head" =~ $SHA_RE ]]; then
    git -C "$wt" push -q --force-with-lease="refs/heads/$branch:$remote_head" origin "$branch" || return 1
  else
    git -C "$wt" push -q -u origin "$branch" || return 1
  fi
  if [[ -n "$pr" && "$old_base_branch" != "$2" ]]; then gh pr edit "$pr" --base "$2" >/dev/null 2>&1 || return 1; fi
}

reconcile_stacked_units() {
  local child id dep parent parent_id parent_pr parent_branch parent_stage parent_approved parent_reviewed parent_state parent_head parent_snapshot dep_info prs
  local child_stage old_stack issue_state
  prs="$(tick_prs 2>/dev/null)" || prs='[]'
  while IFS= read -r child; do
    id="$(jqf -r .id <<<"$child")"; dep="$(jqf -r '.blocked_on // empty' <<<"$child")"
    parent_id="$(jqf -r '.stacked_on_unit // empty' <<<"$child")"
    parent="$(jqf -c --arg id "$parent_id" '.units[] | select(.id==$id)' "$UNITS")"
    [[ -n "$dep" && -n "$parent" ]] || continue
    parent_pr="$(jqf -r '.pr // empty' <<<"$parent")"; parent_branch="$(jqf -r '.branch // empty' <<<"$parent")"
    parent_stage="$(jqf -r .stage <<<"$parent")"; parent_approved="$(jqf -r '.approved_sha // empty' <<<"$parent")"
    parent_reviewed="$(jqf -r '.reviewed_pr_head // empty' <<<"$parent")"
    child_stage="$(jqf -r .stage <<<"$child")"; old_stack="$(jqf -r '.stacked_on_sha // empty' <<<"$child")"
    [[ "$(jqf -r '.size_recut_pending // false' <<<"$child")" == true ]] && continue
    # A worker owns the clone while running. A size escalation owns the unit
    # afterward: restacking must not silently send it back to review (#4482).
    case "$child_stage" in implement|review|repair|rereview|supervisor-review|parked) continue ;; esac
    [[ "$parent_pr" =~ ^[0-9]+$ && -n "$parent_branch" ]] || continue
    parent_snapshot="$(jqf -c --argjson pr "$parent_pr" '[.[] | select(.number==$pr) | {headRefOid}] | .[0] // empty' <<<"$prs")"
    if [[ -n "$parent_snapshot" ]]; then
      parent_state=OPEN
      parent_head="$(jqf -r '.headRefOid // empty' <<<"$parent_snapshot")"
    else
      parent_state="$(pr_view "$parent_pr" state)"
      parent_head=""
    fi
    case "$parent_state" in
      CLOSED)
        set_unit "$id" "$(hist stack-waiting predecessor-PR-$parent_pr-closed) | .stage=\"blocked-external\""
        say "unit $id waits: stacked predecessor PR #$parent_pr closed"
        continue ;;
      MERGED)
        dep_info="$(dep_cache_info "$dep")"
        issue_state="$(jqf -r '.issue_state // empty' <<<"$dep_info")"
        [[ -n "$issue_state" ]] || issue_state="$(gh issue view "$dep" --json state --jq .state 2>/dev/null)"
        [[ "$issue_state" == CLOSED && "$MAIN_HEAD" =~ $SHA_RE ]] || {
          [[ "$child_stage" == blocked-external ]] || set_unit "$id" "$(hist stack-waiting predecessor-PR-$parent_pr-merged-waiting-for-release) | .stage=\"blocked-external\""
          continue
        }
        if ! restack_branch "$id" main "$MAIN_HEAD"; then
          say "unit $id remains stacked: could not restack on main $MAIN_HEAD"
          continue
        fi
        set_unit "$id" "$(hist stack-released main@$MAIN_HEAD-after-predecessor-release) | .stacked_on_released=true | .stacked_on_branch=\"main\" | .stacked_on_sha=$(js "$MAIN_HEAD") | del(.blocked_on) | .approved_sha=null | .reviewed_sha=null | .reviewed_pr_head=null | .stage=(if .pr != null then \"review-pending\" else \"implement-pending\" end)"
        say "unit $id restacked on main@$MAIN_HEAD after predecessor release"
        continue ;;
      OPEN) ;;
      *)
        [[ "$child_stage" == blocked-external ]] || set_unit "$id" "$(hist stack-waiting predecessor-PR-$parent_pr-state-$parent_state) | .stage=\"blocked-external\""
        continue ;;
    esac
    [[ "$parent_head" =~ $SHA_RE ]] || parent_head="$(pr_view "$parent_pr" headRefOid)"
    [[ "$parent_head" =~ $SHA_RE ]] || continue
    if [[ "$parent_head" != "$old_stack" ]]; then
      if ! restack_branch "$id" "$parent_branch" "$parent_head"; then
        say "unit $id remains stacked: could not restack on $parent_id@$parent_head"
        continue
      fi
      set_unit "$id" "$(hist stacked_on $parent_id@$parent_head) | .stacked_on=$(js "$parent_id@$parent_head") | .stacked_on_sha=$(js "$parent_head") | .stacked_on_branch=$(js "$parent_branch") | .approved_sha=null | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"blocked-external\""
      child_stage=blocked-external
      say "unit $id restacked on $parent_id@$parent_head"
    fi
    parent="$(jqf -c --arg id "$parent_id" '.units[] | select(.id==$id)' "$UNITS")"
    parent_stage="$(jqf -r .stage <<<"$parent")"; parent_approved="$(jqf -r '.approved_sha // empty' <<<"$parent")"
    parent_reviewed="$(jqf -r '.reviewed_pr_head // empty' <<<"$parent")"
    if [[ "$parent_stage" == ready-to-merge && "$parent_approved" == "$parent_head" && "$parent_reviewed" == "$parent_head" ]]; then
      if [[ "$child_stage" == blocked-external ]]; then
        set_unit "$id" "$(hist stack-resumed $parent_id@$parent_head-approved) | .stage=(if .pr != null then \"review-pending\" else \"implement-pending\" end)"
        say "unit $id resumed on approved predecessor $parent_id@$parent_head"
      fi
    elif [[ "$child_stage" != blocked-external ]]; then
      set_unit "$id" "$(hist stack-waiting predecessor-$parent_id-not-approved-at-$parent_head) | .stage=\"blocked-external\""
      say "unit $id waits: predecessor $parent_id is not approved at $parent_head"
    fi
  done < <(jqf -c '.units[] | select(.stacked_on != null and .stacked_on_released != true)' "$UNITS")
}

# 尺寸准入的计数：分支相对 PR 基线（普通 PR 为 main，堆叠 PR 为父分支）的代码加删行数；文档、生成物、锁文件与测试快照不计，
# 避免这些内容单独变大就触发重切。数不出来（clone 丢了、fetch 失败）返回空，不挡评审。
changed_lines_of() { # dir branch base-branch → 行数或空
  local base base_branch="${3:-main}"
  git -C "$1" fetch -q origin "+refs/heads/$base_branch:refs/remotes/origin/$base_branch" "+refs/heads/$2:refs/remotes/origin/$2" 2>/dev/null || return 0
  base="$(git -C "$1" merge-base "refs/remotes/origin/$base_branch" "refs/remotes/origin/$2" 2>/dev/null)" || return 0
  git -C "$1" diff --numstat "$base" "refs/remotes/origin/$2" 2>/dev/null \
    | awk -F'\t' '$3 !~ /(^|\/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$/ && $3 !~ /^(docs|lessons|\.trellis)\// && $3 !~ /(^|\/)[^/]+\.md$/ && $3 !~ /(^|\/)(__snapshots__|generated|dist|build|coverage)(\/|$)/ && $3 !~ /(^|\/)[^/]*\.generated\.[^/]+$/ && $3 !~ /\.snap$/ { n += $1 + $2 } END { print n }'
}
changed_files_of() { # dir branch base-branch → actual diff paths as JSON
  local base
  base="$(git -C "$1" merge-base "refs/remotes/origin/$3" "refs/remotes/origin/$2" 2>/dev/null)" || return 0
  [[ -n "$base" ]] || return 0
  (set -o pipefail; git -C "$1" diff --no-renames --name-only -z "$base" "refs/remotes/origin/$2" 2>/dev/null \
    | jqf -Rsc '[splits("\u0000") | select(length > 0)]')
}

# 尺寸准入在开 PR、派已有 PR 的 implement/repair 前和每次 repair/self-fix 交付后复查。
# repair-pending 的超线 PR 先走现有 needs-recut 通道，不占 worker；同一 head 已拒过或不能路由时转 supervisor。
# repair/self-fix 仍需复查新 head（#4482：PR #4396 从 611 增到 1090、#4403 从 796 增到 1063）。返回 1 = 已升级。
size_admission_recheck() { # unit dir branch context [initial-head]
  local lines base_branch issue head="${5:-}" files
  [[ -n "$2" && -n "$3" ]] || return 0
  base_branch="$(unit_field "$1" '.stacked_on_branch // "main"')"
  lines="$(changed_lines_of "$2" "$3" "$base_branch")"
  [[ "$lines" =~ ^[0-9]+$ ]] || return 0
  files="$(changed_files_of "$2" "$3" "$base_branch")"
  if jqf -e 'type == "array"' <<<"$files" >/dev/null 2>&1; then
    set_unit "$1" ".footprint=$files | .footprint_source=\"pr-diff\""
  fi
  (( lines > SIZE_ADMISSION_LINES )) || return 0
  issue="$(unit_field "$1" '.issue // empty')"
  if [[ "$head" =~ $SHA_RE && "$issue" =~ ^[0-9]+$ ]] \
    && ! jqf -e --arg id "$1" --arg head "$head" 'any(.units[] | select(.id==$id) | .history[]?; .stage=="size-recut" and (.result | contains("head="+$head)))' "$UNITS" >/dev/null \
    && scheduler_size_recut "$issue" "$lines" "$SIZE_ADMISSION_LINES" "$1" "$3" "$head"; then
    set_unit "$1" "$(hist size-recut "issue #$issue: $lines lines exceed $SIZE_ADMISSION_LINES; head=$head") | .stage=\"blocked-external\" | .size_recut_pending=true"
    say "unit $1 size admission routed issue #$issue to recut"
    return 1
  fi
  to_supervisor "$1" "size admission: ${lines} changed lines $4 exceed the ${SIZE_ADMISSION_LINES}-line limit (documentation, generated files, lockfiles, and snapshots excluded): re-scope or split before review" \
    'Request recut or split before review' 'changed lines exceed the size admission limit' \
    "${lines} changed lines $4 exceed ${SIZE_ADMISSION_LINES}-line limit" \
    '["Open PR for review without recutting"]'
  return 1
}
pre_dispatch_pr_admission() { # unit branch PR context → prepared clone; nonzero means defer or recut
  local id="$1" branch="$2" pr="$3" context="$4" head dir
  head="$(tick_pr_head "$pr")" || return 1
  dir="$(ensure_clone "$id" "$branch" 1 "$head")" || { say "$context unit=$id: PR branch unavailable"; return 1; }
  size_admission_recheck "$id" "$dir" "$branch" "$context" "$head" || return 1
  printf '%s\n' "$dir"
}

# 产品 issue 的实现：worker 推分支，流水线开 PR（Refs #N）→ 进评审；OBSOLETE 直接结案。
harvest_pr_implement() { # unit report-path
  local first issue branch dir head title pr out base
  first="$(grep -m1 -v '^[[:space:]]*$' "$2" 2>/dev/null)"
  issue="$(unit_field "$1" .issue)"; branch="$(unit_field "$1" .branch)"; dir="$WT_ROOT/wt-$1"
  local dep; dep="$(blocked_on_of "$2")"
  [[ -n "$dep" ]] && { park_blocked "$1" "$dep"; return 0; }
  if [[ "$first" == OBSOLETE:* ]]; then
    [[ -n "$issue" ]] && gh issue close "$issue" --comment "Autopilot: no change needed on current main. ${first}" >/dev/null 2>&1
    set_unit "$1" "$(hist obsolete "$first") | .stage=\"closed\""
    say "unit $1 obsolete: $first"; return 0
  fi
  head="$(git -C "$dir" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ ! "$head" =~ $SHA_RE ]]; then
    if [[ "$(unit_retries "$1" implement-no-push)" == 0 ]]; then
      set_unit "$1" "$(hist implement-no-push "$(basename "$2")") | .task += $(js "

上一轮交付了报告但 origin 上没有分支 ${branch}：本轮必须通过 push preflight 并 push 该分支（或按协议写 OBSOLETE:）。") | .stage=\"implement-pending\""
    else
      to_supervisor "$1" "implement pushed no branch $branch twice (report $(basename "$2"))"
    fi
    return 0
  fi
  size_admission_recheck "$1" "$dir" "$branch" "on $branch" "$head" || return 0
  title="$(unit_field "$1" .title)"
  base="$(unit_field "$1" '.stacked_on_branch // "main"')"
  scheduler_pr_open "$branch" "${title:-$1}${issue:+ (#$issue)}" "${issue:+Refs #$issue

}Implemented by the the product autopilot. Implementer report (first lines):

$(head -40 "$2")" "$base"
  pr="$SCHED_PR_NUM"; out="$SCHED_PR_OUT"
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    to_supervisor "$1" "could not open a PR for $branch: ${out:0:200}"; return 0
  fi
  set_unit "$1" "$(hist pr-opened "PR#$pr $head") | .pr=$pr | .lane=\"pr\" | .stage=\"review-pending\"$([[ "$branch" =~ $GATED_BRANCH_RE ]] && printf ' | .gated=true')"
  say "unit $1 implemented on $branch -> PR#$pr review-pending"
  # SPLIT 交付（#4482）：尺寸契约在派发简报里前置后，worker 交第一个可独立交付切片 +
  # SPLIT 首行声明剩余范围；切片 PR 进评审的同时，剩余范围落成续作票（needs-triage，
  # 重新量尺寸），不再丢失也不再把原票整票重派。幂等：一个 unit 只建一张（.split_followup）。
  if [[ "$first" == SPLIT:* && -z "$(unit_field "$1" '.split_followup // empty')" ]]; then
    split_followup_issue "$1" "$issue" "$pr" "$first" "$2"
  fi
}

# SPLIT 交付的续作票（#4482）：worker 按尺寸准入只交付了第一个可独立交付切片，报告首行
# SPLIT: <剩余范围一句话>。剩余范围需要一张自己的票承载——生而 needs-triage，走正常分诊
# （含行数估算），不会再被整票派发。创建失败记 supervisor inbox，单元保持评审队列。
split_followup_issue() { # unit issue pr split-line report-path
  local unit="$1" issue="$2" pr="$3" first="$4" rep="$5" remainder body url num
  remainder="$(printf '%s' "$first" | sed -E 's/^SPLIT:[[:space:]]*//')"
  body="## Parent

由 #$issue 按尺寸准入拆分出的续作票：第一个可独立交付切片在 PR #$pr 送评审，本票承接剩余范围，会走正常的分诊流程（含行数估算），不跳过分诊。

## 剩余范围

$remainder

## 切片交付说明（worker 报告）

$(head -n 200 "$rep" 2>/dev/null)"
  url="$(gh issue create --title "$(unit_field "$unit" .title)（续作自 #$issue）" --body "$body" --label needs-triage --parent "$issue" 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    num="${url##*/}"
    set_unit "$unit" "$(hist split-followup "issue #$num: $remainder") | .split_followup=$num"
    say "unit $unit split delivery: remainder #$num filed; slice in PR #$pr"
  else
    # 切片 PR 已在评审，失败只报 supervisor inbox，不把单元踢出评审队列；剩余范围仍在 worker 报告与 PR 描述里。
    ( source "$SCHEDULER_AGENT_LIB" && supervisor_inbox_append_once "split-followup-failed:$unit" "split 续作票创建失败 unit=$unit 原票 #$issue 切片 PR #$pr：剩余范围见报告 $(basename "$rep")" ) >/dev/null 2>&1 \
      || say "unit $unit split followup create failed; remainder in $(basename "$rep")"
  fi
}

# ---------- 1. 回收（按 worker.type 分类推进） ----------
harvest_workers() { # [local-only]: fast refill only completes direct-main implement workers without GitHub effects
  local local_only="${1:-false}" w pid unit wtype report rep lg session_id tk v msg wmode wsha wprhead role dispatch_usage_count session_usage_count usage_end usage_start accounting started s mins no_output pgid limit_hit stream decision
  while read -r w; do
    [[ "$(jqf -r '.harvested // false' <<<"$w")" == "true" ]] && continue
    pid="$(jqf -r .pid <<<"$w")"; unit="$(jqf -r .unit <<<"$w")"; wtype="$(jqf -r .type <<<"$w")"
    report="$(jqf -r .report <<<"$w")"; rep="$SUP/$report"; lg="$SUP/$(jqf -r .log <<<"$w")"
    if [[ "$local_only" == true ]]; then
      [[ "$wtype" == implement && "$(unit_field "$unit" '.lane // empty')" == direct-main ]] || continue
      # OBSOLETE closes the GitHub issue; leave it for the slow tick to deliver that side effect.
      [[ "$(grep -m1 -v '^[[:space:]]*$' "$rep" 2>/dev/null)" != OBSOLETE:* ]] || continue
    fi
    if [[ "$wtype" == eval ]]; then
      alive "$pid" && continue
      harvest_prompt_eval "$w"
      continue
    fi
    if [[ "$wtype" == supervise ]]; then
      alive "$pid" && continue
      harvest_supervisor_arbiter "$w"
      continue
    fi
    # --json 日志：末次累计 turn.completed 的新鲜 token（旧页脚 blended 口径一致）；legacy 日志退回页脚
    stream="$(python3 "$USAGE_READER" codex-stream "$lg" 2>/dev/null || true)"
    tk="$(jqf -r '.fresh // empty' <<<"$stream")"
    [[ "$tk" =~ ^[0-9]+$ ]] || tk="$(tokens_of "$lg")"
    [[ "$tk" =~ ^[0-9]+$ ]] || tk=""  # 读不出来就是 unavailable，不当 0
    if alive "$pid"; then
      started="$(jqf -r .started <<<"$w")"
      s="$(ap_iso_epoch "$started")"; [[ "$s" =~ ^[0-9]+$ ]] || s="$NOW_EPOCH"
      mins=$(( (NOW_EPOCH - s) / 60 ))
      if (( mins > $(jqf -r '.waste.slow_worker_minutes // 60' <<<"$CFG") )); then
        echo "[$STAMP] SLOW worker pid=$pid unit=$unit ${mins}min" >> "$A/alerts/waste.md"
      fi
      # 运行多久本身不触发停止（会误杀有进展的长任务）：停止决策在 stuck_worker_disposition，
      # 由 f8 的在制品年龄信号加进展指纹驱动（#4371）。
      if [[ -n "$tk" ]] && (( tk > $(jqf -r '.waste.burn_tokens_no_output // 800000' <<<"$CFG") )); then
        echo "[$STAMP] BURN worker pid=$pid unit=$unit tokens=$tk no-output" >> "$A/alerts/waste.md"
      fi
      continue
    fi

    # --json 日志先取事件流自身的 session id（thread.started）；legacy 日志退回页脚 grep，再退回台账（resume 派发时已知）
    local execution
    execution="$(jq -Rsc '[split("\n")[] | fromjson? | select(.type=="pipeline.execution")] | last // {}' "$lg" 2>/dev/null)"
    if [[ "$(jqf -r '.reason // empty' <<<"$execution")" == resume-startup-failed ]]; then
      w="$(jqf '.mode="fresh" | .session_id="" | .token_usage_start={input_tokens:0,cached_input_tokens:0,output_tokens:0}' <<<"$w")"
      say "repair fallback unit=$unit mode=fresh reason=resume-startup-failed"
    fi
    session_id="$(jqf -r '.session_id // empty' <<<"$stream")"
    [[ "$session_id" =~ $SESSION_RE ]] || session_id="$(grep -m1 -Eo 'session id: [[:xdigit:]-]{36}' "$lg" 2>/dev/null | sed 's/^session id: //' || true)"
    [[ "$session_id" =~ $SESSION_RE ]] || session_id="$(jqf -r '.session_id // empty' <<<"$w")"
    [[ "$session_id" =~ $SESSION_RE ]] || session_id=""
    # Persist every run, including runs without a report. Review has its own slot.
    if [[ -n "$session_id" && "$wtype" =~ ^(implement|repair|review|rereview)$ ]]; then
      role="$(session_role "$wtype")"
      local session_model session_provider session_record
      session_model="$(jqf -r '.model // empty' <<<"$w")"
      session_provider="$(provider_of "$session_model")"
      session_record="$(jqf -cn --arg id "$session_id" --arg provider "$session_provider" --arg model "$session_model" '{id:$id,provider:$provider,model:$model}')"
      set_unit "$unit" ".session_id=$(js "$session_id") | .session_ids[\"$role\"]=$(js "$session_id") | .sessions[\"$role\"]=$session_record"
    fi
    # 原生 turn 事件入库（provider/session/turn 幂等键，重复交付/重扫不重复计数）；legacy 日志无事件，no-op
    python3 "$USAGE_READER" codex-ingest "$lg" "$session_id" "$(jqf -r '.started // empty' <<<"$w")" "$BUDGET_EVENTS" >/dev/null 2>&1 || true
    if [[ ! -s "$rep" && "$rep" == *-r-* && -s "${rep/-r-/-}" ]]; then
      # 复审 worker 偶尔把报告写成 review-N-<TAG>.md（丢了 -r-）：pr-3972 两次 APPROVE 因此被当成无产出死亡。
      mv -f -- "${rep/-r-/-}" "$rep" && say "report for unit=$unit was written as $(basename "${rep/-r-/-}"); moved to $report"
    fi
    if [[ ! -s "$rep" ]]; then
      msg="$(final_message_of "$lg")"
      # --json 日志没有页脚：只有全部 turn 都收到 turn.completed 的日志，最后的 agent_message 才是最终答复；
      # 被杀/中断的 worker 只剩旁白，不能当报告（否则绕过无产出计数、重试与限额冷却）
      [[ -n "${msg//[[:space:]]/}" ]] || msg="$(jqf -r 'select(.complete == true) | .message // empty' <<<"$stream")"
      if [[ -n "${msg//[[:space:]]/}" ]]; then
        # 正常结束却没写报告文件：13/83 次"无产出"其实带着结论（issue-2593 BLOCKED-ON 被当死亡重跑）。
        printf '%s\n' "$msg" > "$rep" && say "report for unit=$unit missing; recovered the worker's final message into $report"
      fi
    fi
    usage_end="$(session_usage_for_id "$session_id")"
    usage_start="$(jqf -c '.token_usage_start // null' <<<"$w")"
    accounting="$(jqf -cn --argjson start "$usage_start" --argjson end "$usage_end" \
      --arg mode "$(jqf -r '.mode // "fresh"' <<<"$w")" --arg before "$(jqf -r '.session_id // empty' <<<"$w")" --arg after "$session_id" '
      def valid: type=="object" and all(.input_tokens,.cached_input_tokens,.output_tokens; type=="number" and .>=0);
      (if ($start|valid|not) then "missing-baseline"
       elif $mode=="resume" and $before!=$after then "session-changed"
       elif ($end|valid|not) then "missing-end"
       elif any(["input_tokens","cached_input_tokens","output_tokens"][]; $end[.] < $start[.]) then "counter-reset"
       else "measured" end) as $status |
      {token_accounting:$status,token_usage_end:$end,dispatch_tokens:
        (if $status=="measured" then ($end.input_tokens - $start.input_tokens + $end.output_tokens - $start.output_tokens) else null end)}
    ')"
    accounting="$(jqf --arg sid "$session_id" --arg mode "$(jqf -r '.mode // "fresh"' <<<"$w")" \
      --arg reason "$(jqf -r '.reason // empty' <<<"$execution")" '. + {session_id:$sid,mode:$mode,execution_reason:$reason}' <<<"$accounting")"
    if [[ "$(jqf -r '.reason // empty' <<<"$execution")" == resume-startup-failed ]]; then
      accounting="$(jqf --arg sid "$(jqf -r '.resume_session_id // empty' <<<"$execution")" '.resume_session_id=$sid' <<<"$accounting")"
    fi
    dispatch_usage_count="$(jqf -r '.dispatch_tokens // "unknown"' <<<"$accounting")"
    session_usage_count="$(jqf -r 'if .==null then "unknown" else .input_tokens + .output_tokens end' <<<"$usage_end")"
    if [[ "$dispatch_usage_count" =~ ^[0-9]+$ ]]; then
      set_unit "$unit" ".tokens = ((.tokens // 0) + $dispatch_usage_count)"
    fi
    if [[ "$wtype" == implement || "$wtype" == repair ]]; then
      local actual paths_dir
      paths_dir="$(jqf -r '.workdir // empty' <<<"$w")"
      actual="$(git -C "$paths_dir" diff --name-only origin/main...HEAD 2>/dev/null | jq -Rsc 'split("\n") | map(select(length>0))')"
      set_unit "$unit" "$(STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)" hist write-end "$actual") | .footprint=((.footprint // []) + $actual | unique)"
    fi
    if [[ -s "$rep" ]]; then
      v="$(verdict_of "$rep")"
      wmode="$(jqf -r '.mode // "fresh"' <<<"$w")"
      wsha="$(jqf -r '.sha // empty' <<<"$w")"; [[ "$wsha" =~ $SHA_RE ]] || wsha=""
      wprhead="$(jqf -r '.pr_head // empty' <<<"$w")"; [[ "$wprhead" =~ $SHA_RE ]] || wprhead=""
      say "harvest unit=$unit type=$wtype verdict=${v:-none} mode=$wmode tokens=${tk:-unavailable} session_id=${session_id:-none} session_tokens=$dispatch_usage_count session_total_tokens=$session_usage_count"
      case "$wtype" in
        review|rereview)
          local reviewed=".reviewed_sha=$(js "$wsha") | .reviewed_pr_head=$(js "$wprhead") | .review_report=$(js "$report")"
          case "$v" in
            READY)
              # 同时保留审核候选与当时观察到的 GitHub PR head；旧 worker 缺失 PR head 时拒绝批准。
              if [[ "$wprhead" =~ $SHA_RE ]]; then
                local eval_stages eval_reason eval_workdir eval_tree eval_label eval_report eval_safe_id eval_stages_json eval_gate
                eval_workdir="$(jqf -r '.workdir // empty' <<<"$w")"
                eval_reason=""
                if eval_stages="$(decision_eval_stages "$eval_workdir" "$wsha")"; then
                  :
                else
                  eval_stages='triage advisor implement review end-to-end'
                  eval_reason='candidate diff unavailable; eval reports every stage'
                fi
                if [[ -n "${eval_stages//[[:space:]]/}" ]]; then
                  eval_tree="$(git -C "$eval_workdir" rev-parse "$wsha^{tree}" 2>/dev/null)" || eval_tree=""
                  if [[ -z "$eval_tree" ]]; then
                    eval_stages='triage advisor implement review end-to-end'
                    eval_reason='candidate tree unavailable; eval reports every stage'
                  fi
                  eval_safe_id="$(tr -c 'A-Za-z0-9._-' '-' <<<"$unit" | sed 's/-$//')"
                  eval_label=""
                  eval_report="eval-gate-${eval_safe_id}-${eval_tree:-pending}.json"
                  [[ -n "$eval_tree" ]] && eval_label="gate-$eval_tree"
                  eval_stages_json="$(jqf -cn --arg stages "$eval_stages" '$stages | split(" ") | map(select(length>0))')"
                  eval_gate="$(jqf -cn --arg sha "$wsha" --arg pr_head "$wprhead" --arg tree "$eval_tree" \
                    --arg label "$eval_label" --arg workdir "$eval_workdir" --arg report "$eval_report" \
                    --arg reason "$eval_reason" --argjson stages "$eval_stages_json" \
                    '{status:"pending",sha:$sha,pr_head:$pr_head,tree:$tree,label:$label,workdir:$workdir,report:$report,stages:$stages} + (if $reason=="" then {} else {reason:$reason} end)')"
                  # #4656（裁决 architecture-ships-evals-alongside）：架构面改动照常批准进 ready-to-merge，
                  # eval_gate 只是并行报告任务的派发凭据，不是交付前置。
                  set_unit "$unit" "$(hist review-approve "$wsha") | $reviewed | .approved_sha=$(js "$wsha") | .ready_since=(.ready_since // $NOW_EPOCH) | .eval_gate=$eval_gate | .stage=\"ready-to-merge\""
                  post_approved_status "$unit" "$wprhead"
                  say "review approved unit=$unit sha=$wsha; eval reporting stages=$(tr ' ' ',' <<<"${eval_stages% }") runs alongside delivery"
                else
                  set_unit "$unit" "$(hist review-approve "$wsha") | $reviewed | .approved_sha=$(js "$wsha") | .ready_since=(.ready_since // $NOW_EPOCH) | del(.eval_gate) | .stage=\"ready-to-merge\""
                  post_approved_status "$unit" "$wprhead"
                fi
              else
                set_unit "$unit" "$reviewed | .approved_sha=null"
                to_supervisor "$unit" "review worker $report did not record the observed PR head"
              fi ;;
            NOT_READY)
              set_unit "$unit" "$(hist review-request-changes "$wsha") | $reviewed | .approved_sha=null | .stage=\"repair-pending\"$(review_findings_update "$rep" "$report")$(review_findings_hint_update "$rep") | .author_dispositions_pending=true"
              cancel_unit_runs "$unit" "review requested changes; head will change" ;;
            INPUT_INCOMPLETE)
              set_unit "$unit" "$(hist review-block "$wsha") | $reviewed | .approved_sha=null | .blocked_main_sha=$(js "$MAIN_HEAD") | .stage=\"blocked-external\""
              local bdep; bdep="$(blocked_on_of "$rep")"
              [[ -n "$bdep" ]] && set_unit "$unit" ".blocked_on=$bdep | .note=$(js "waiting for predecessor #$bdep")"
              cancel_unit_runs "$unit" "review blocked" ;;
            *)
              set_unit "$unit" "$reviewed | .approved_sha=null"
              if [[ "$(unit_retries "$unit" verdict-missing)" == 0 ]]; then
                set_unit "$unit" "$(hist verdict-missing "$report") | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
              else
                to_supervisor "$unit" "review report $report has no single VERDICT line (twice)"
              fi ;;
          esac ;;
        repair)
          if [[ "$(unit_field "$unit" '.self_fix_active // false')" == true ]]; then
            set_unit "$unit" "$(hist self-fix-delivered) | .self_fix_active=false | .self_fix_pending=false | .self_check_sha=null | .self_check_status=null | .stage=.self_check_return_stage"
          else
            local current_unit disposition_update
            if [[ "$(unit_field "$unit" '.author_dispositions_pending // false')" == true ]]; then
              current_unit="$(jqf -c --arg id "$unit" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
              disposition_update="$(review_dispositions_update "$rep" "$current_unit")"
            else
              disposition_update=""
            fi
            set_unit "$unit" "$(hist repair-delivered) $disposition_update | .repair_hint=null | (.stage=\"rereview-pending\")"
            set_unit "$unit" ".author_dispositions_pending=false"
          fi
          # f6 复查（#4482）：repair/self-fix 推的新 head 重新过尺寸准入；超线同样转 supervisor 拆分
          local recheck_dir recheck_branch
          recheck_dir="$(jqf -r '.workdir // empty' <<<"$w")"; recheck_branch="$(unit_field "$unit" '.branch // empty')"
          if [[ "$(unit_field "$unit" '.lane // "pr"')" != direct-main ]] && [[ "$(unit_field "$unit" '.pr // empty')" =~ ^[0-9]+$ ]]; then
            size_admission_recheck "$unit" "$recheck_dir" "$recheck_branch" "on $recheck_branch after repair" || :
          fi ;;
        land)
          local land_result; land_result="$(head -1 "$rep")"
          case "$land_result" in
            LANDED-HEAD-MOVED*)
                     local landed_sha moved_head
                     read -r _ landed_sha moved_head <<<"$land_result"
                     set_unit "$unit" "$(hist land-head-moved "$land_result") | .land_sha=$(js "$landed_sha") | .approved_sha=null | .land_pr_head=$(js "$moved_head") | .stage=\"rereview-pending\""
                     echo "[$STAMP] fast-landed-with-new-head unit=$unit $land_result" >> "$A/alerts/events.md" ;;
            LANDED*) set_unit "$unit" "$(hist landed "$land_result") | .stage=\"landed\" | .land_sha=$(js "${land_result#LANDED }")"
                     local land_issue; land_issue="$(unit_field "$unit" .issue)"
                     # M5（#4501）：验收块带 live-event 项的票不立即关票，转等待生产事件（live_event_watch）
                     if [[ -n "$land_issue" && -z "$(unit_field "$unit" .pr)" ]] \
                       && landed_live_event_wait "$unit" "$land_issue" "${land_result#LANDED }"; then
                       gh issue close "$land_issue" --comment "Landed on main as ${land_result#LANDED } through the autopilot direct-main lane (reviewed local commit, no PR)." >/dev/null 2>&1
                     fi
                     echo "[$STAMP] fast-landed unit=$unit $land_result" >> "$A/alerts/merge.md" ;;
            *"not eligible"*)
              if [[ -z "$(unit_field "$unit" .pr)" ]]; then to_supervisor "$unit" "NEEDS-PR: $land_result"
              else set_unit "$unit" "$(hist land-refused "$land_result") | .lane=\"pr\" | .stage=\"ready-to-merge\""; fi ;;
            *"head moved"*) set_unit "$unit" "$(hist land-refused "$land_result") | .approved_sha=null | .stage=\"rereview-pending\"" ;;
            FAILED\ POST-LAND*)
              local landed_sha="${land_result##* }"
              if [[ "$landed_sha" =~ $SHA_RE ]]; then
                set_unit "$unit" "$(hist land-post-step-failed "$land_result") | .land_sha=$(js "$landed_sha") | .approved_sha=null"
              fi
              to_supervisor "$unit" "直落 main 已完成但 PR 后续处理失败：${land_result}。详情见 $SUP/${report}.land.log。"
              echo "[$STAMP] post-land follow-up failed unit=$unit $land_result" >> "$A/alerts/events.md"
              ;;
            *"push-failed"*|*"fetch"*|*"clone"*)
              # 传输类失败：同一批准 head 重试一次，再失败转人工
              if [[ "$(jqf -r --arg id "$unit" '[.units[] | select(.id==$id) | (.history // [])[] | select(.stage=="land-retry")] | length' "$UNITS")" == 0 ]]; then
                set_unit "$unit" "$(hist land-retry "$land_result") | .stage=\"ready-to-merge\""
              else
                to_supervisor "$unit" "fast land failed twice: $land_result (log ${report}.land.log)"
              fi ;;
            *) # 冲突、预检失败、落地卡死：改动本身要修，交给 repair 并附落地日志
               set_unit "$unit" "$(hist land-failed "$land_result") | .approved_sha=null | .repair_hint=$(js "直落 main 失败：${land_result}。落地日志 $SUP/${report}.land.log；与 main 冲突就 merge origin/main 解决；检查失败或卡死就修复根因并补回归测试。") | .stage=\"repair-pending\"" ;;
          esac ;;
        implement|triage)
          if [[ "$wtype" == implement && -z "$(unit_field "$unit" .pr)" && "$(unit_field "$unit" .lane)" == direct-main ]]; then
            harvest_prless_implement "$unit" "$rep" "$local_only"
          elif [[ "$wtype" == implement && -z "$(unit_field "$unit" .pr)" && "$(unit_field "$unit" .lane)" == pr ]]; then
            harvest_pr_implement "$unit" "$rep"
          else
            decision="$(decision_entry 'Hand off delivered worker result to supervisor' 'the current unit state has no automatic delivery transition' "$report" '["Advance the unit without supervisor handling"]' scheduler)"
            set_unit "$unit" "$(hist delivered "" "$decision") | (.stage=\"supervisor-review\")"
            echo "[$STAMP] IMPL-DELIVERED unit=$unit report=$(basename "$rep")" >> "$A/alerts/events.md"
          fi ;;
      esac
    else
      limit_hit="$( { tail -n 40 "$lg"; cat "$rep.partial"; } 2>/dev/null | grep -m1 -oiE "$PROVIDER_LIMIT_RE" || true)"
      rm -f -- "$rep.partial"
      if [[ -n "$limit_hit" ]]; then
        # 提供方上限：冷却该提供方，不计入无产出、不算失败回合；单元留在原 stage 由孤儿自愈回到 pending。
        start_cooldown "$(provider_of "$(jqf -r '.model // ""' <<<"$w")")" "$limit_hit (unit=$unit)"
        set_unit "$unit" "$(hist worker-provider-limit "$limit_hit")"
        jqf --argjson accounting "$accounting" --arg finished "$STAMP" "(.workers[] |= (if .pid==$pid and .unit==\"$unit\" and .harvested != true then (. += \$accounting | .harvested=true | .finished_at=\$finished) else . end))" "$WORKERS" | write_state "$WORKERS"
        continue
      fi
      echo "[$STAMP] WASTE zero-output worker pid=$pid unit=$unit log=$(basename "$lg")" >> "$A/alerts/waste.md"
      say "WASTE zero-output pid=$pid unit=$unit"
      # L9：无产出死亡计数；到上限转人工，不再无限重派。
      set_unit "$unit" "$(hist worker-no-output "$wtype")"
      no_output="$(jqf -r --arg id "$unit" '[.units[] | select(.id==$id) | (.history // []) | map(select(.stage=="worker-no-output")) | length][0] // 0' "$UNITS")"
      if [[ "$(unit_field "$unit" '.self_fix_active // false')" != true && "$no_output" =~ ^[0-9]+$ ]] && (( no_output >= MAX_NO_OUTPUT )); then
        if [[ "$wtype" =~ ^(review|rereview|repair|implement)$ && "$(unit_retries "$unit" fresh-session-retry)" == 0 ]]; then
          # 续接的会话可能已坏（上下文爆、提供方会话失效）：丢掉会话 ID 再试一次全新会话。
          set_unit "$unit" "$(hist fresh-session-retry "$no_output deaths") | .session_ids={} | .sessions={} | .session_id=null | .stage=\"${wtype}-pending\""
          say "unit=$unit: $no_output workers died -> one fresh-session retry"
        else
          to_supervisor "$unit" "$no_output workers died without a report, fresh session too (last log $(basename "$lg"))"
        fi
      fi
    fi
    jqf --argjson accounting "$accounting" --arg finished "$STAMP" "(.workers[] |= (if .pid==$pid and .unit==\"$unit\" and .harvested != true then (. += \$accounting | .harvested=true | .finished_at=\$finished) else . end))" "$WORKERS" | write_state "$WORKERS"
  done < <(jqf -c '.workers[]' "$WORKERS")
}

# ---------- 1b. 孤儿自愈：worker stage 无未收割 worker 记录时回对应 pending ----------
# 只看记录、不看进程：worker 在 harvest_workers 判活之后、本阶段之前退出（中间隔几十秒），按进程判会再派一个，
# 下一拍又收割原报告，同一单元两条评审/修复链并行（pr-2350 01:30、热修 pr-3588 02:44）。死了未收割的记录交给下一拍收割。
recover_orphans() {
  local id st
  while read -r id st; do
    [[ -z "$id" ]] && continue
    if [[ "$(jqf -r --arg u "$id" '[.workers[] | select(.unit==$u and .harvested != true)] | length' "$WORKERS")" == 0 ]]; then
      if [[ "$(unit_field "$id" '.self_fix_active // false')" == true ]]; then
        set_unit "$id" '.self_fix_active=false | .self_fix_pending=false | .stage=.self_check_return_stage'
      else
        set_unit "$id" ".stage=\"${st}-pending\""
      fi
      say "orphan-recover unit=$id ${st} -> ${st}-pending"
    fi
  done < <(jqf -r '.units[] | select(.stage=="review" or .stage=="rereview" or .stage=="repair" or .stage=="implement") | "\(.id) \(.stage)"' "$UNITS")
}

# ---------- 1c. 卡住任务处置（#4371）：消费 f8（#4366）的在制品年龄信号 ----------
# 检测归 f8：flow.wip_age_stage_p90_hours 越过阈值（UNHEALTHY）时，scorecard 的
# flow.wip_age[].oldest 列出各超龄阶段的单元。本阶段只消费这个信号，不做第二套年龄检测：
# 对超龄单元的活 worker 取进展指纹（事件流字节数 + 工作克隆 HEAD/跟踪与未跟踪文件内容），
# 两拍间隔（≥stuck_confirm_minutes）指纹不变 = 无进展 → 停掉 worker 及其后端进程（进程组 TERM，必要时 KILL）并
# requeue；同一单元第 2 次卡住不再 requeue，走 #4363（f6）的止损路由（hold.sh on-hold +
# supervisor 裁决）。指纹一直在变的长任务不会被停（取代旧的 90 分钟盲杀）。
STUCK_CONFIRM_MINUTES="$(jqf -r '.waste.stuck_confirm_minutes // 10' <<<"$CFG")"
stuck_worker_progress_fp() { # worker-json → "<log字节>|<HEAD>|<工作区内容指纹>"
  local wd lg size head dirty path
  wd="$(jqf -r '.workdir // ""' <<<"$1")"; lg="$SUP/$(jqf -r .log <<<"$1")"
  size="$(stat -c %s "$lg" 2>/dev/null || echo 0)"
  if { [[ -d "$wd/.git" ]] || [[ -f "$wd/.git" ]]; }; then
    head="$(git -C "$wd" rev-parse HEAD 2>/dev/null || echo none)"
    dirty="$(
      {
        git -C "$wd" diff --binary HEAD -- 2>/dev/null || true
        while IFS= read -r -d '' path; do
          printf '\0%s\0' "$path"
          git -C "$wd" diff --no-index --binary /dev/null "$path" 2>/dev/null || true
        done < <(git -C "$wd" ls-files --others --exclude-standard -z 2>/dev/null)
      } | cksum | awk '{print $1 ":" $2}'
    )"
  else
    head=nogit; dirty=nogit
  fi
  printf '%s|%s|%s' "$size" "$head" "$dirty"
}
stuck_worker_stop() { # pid; dispatch() gives model workers their own process group via setsid
  local pid="$1" pgid
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [[ "$pgid" == "$pid" ]]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    for _ in {1..10}; do
      kill -0 -- "-$pid" 2>/dev/null || return 0
      sleep 0.1
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..10}; do
      alive "$pid" || return 0
      sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
}
stuck_worker_disposition() {
  local scorecard="$A/node-health.json" bound offenders id w pid wtype probe fp held kills next issue hold_cli hold_ok
  local signal_active=0 named_count=0 live_count=0 killed_count=0
  local first_seen=0 progress=0 unchanged_window=0 unchanged_confirmed=0 no_live_worker=0 action
  offenders=""
  # 消费 f8 的信号：只有 UNHEALTHY 的越阈值信号才点名单元；信号健康/未跑时名单为空，
  # 本拍只做残留探针清理，不碰任何 worker。
  if [[ -s "$scorecard" ]] \
     && [[ "$(jqf -r '[.metrics[] | select(.id=="flow.wip_age_stage_p90_hours")][0].status // ""' "$scorecard")" == UNHEALTHY ]]; then
    signal_active=1
    bound="$(jqf -r '[.metrics[] | select(.id=="flow.wip_age_stage_p90_hours")][0].unhealthy // 12' "$scorecard")"
    if [[ "$bound" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      offenders="$(jqf -r --argjson bound "$bound" '[.flow.wip_age[]? | select((.p90_hours // 0) >= $bound) | .oldest[]?.id] | unique | join(" ")' "$scorecard")"
    fi
  fi
  for id in $offenders; do
    named_count=$((named_count + 1))
    w="$(jqf -c --arg unit "$id" '[.workers[] | select(.unit==$unit and .harvested != true)] | sort_by(.started) | last // empty' "$WORKERS")"
    if [[ -z "$w" ]]; then
      no_live_worker=$((no_live_worker + 1))
      continue
    fi
    pid="$(jqf -r .pid <<<"$w")"; wtype="$(jqf -r .type <<<"$w")"
    if ! [[ "$wtype" =~ ^(implement|repair|review|rereview|land)$ ]] || ! alive "$pid"; then
      no_live_worker=$((no_live_worker + 1))
      continue
    fi
    live_count=$((live_count + 1))
    probe="$(unit_field "$id" '.stuck_probe // empty')"
    fp="$(stuck_worker_progress_fp "$w")"
    if [[ -n "$probe" && "$(jqf -r .fp <<<"$probe")" == "$fp" ]]; then
      held=$(( NOW_EPOCH - $(ap_iso_epoch "$(jqf -r .at <<<"$probe")") ))
      if (( held < STUCK_CONFIRM_MINUTES * 60 )); then
        unchanged_window=$((unchanged_window + 1))
        continue
      fi
      unchanged_confirmed=$((unchanged_confirmed + 1))
      stuck_worker_stop "$pid"
      killed_count=$((killed_count + 1))
      jqf --argjson pid "$pid" --arg unit "$id" --arg finished "$STAMP" \
        '(.workers[] |= (if .pid==$pid and .unit==$unit and .harvested != true then (.harvested=true | .finished_at=$finished | .stuck_killed=true) else . end))' \
        "$WORKERS" | write_state "$WORKERS"
      kills=$(( $(unit_retries "$id" stuck-killed) + 1 ))
      if (( kills >= 2 )); then
        # 第 2 次卡住走 #4363（f6）的止损路由：原票经 hold.sh 自动 on-hold（24h）附原因，
        # 单元转 supervisor 裁决（#4369）；裁决后重新给满额度。
        issue="$(unit_field "$id" '.issue // empty')"
        hold_ok=1
        if [[ -n "$issue" ]]; then
          hold_cli="$ROOT/engine/hold.sh"
          [[ -r "$hold_cli" ]] || hold_cli="$HERE/../hold.sh"
          if ! bash "$hold_cli" --hold "$issue" --holder scheduler-stop-loss \
            --release 'supervisor rules on the stuck stop-loss escalation; requeue or approve refills the budget' \
            --expires 24h --kind stop-loss >/dev/null 2>&1; then
            hold_ok=0
            echo "[$STAMP] STUCK-HOLD-FAILED unit=$id issue=$issue episode=$kills" >> "$A/alerts/events.md"
            say "STUCK-HOLD-FAILED unit=$id issue=$issue episode=$kills"
          else
            gh issue comment "$issue" --body "卡住止损（#4371→#4363）：这张票的单元 $id 第 $kills 次无进展卡住，worker 已停止；自动搁置（on-hold，24h 后未裁决自动恢复），单元转 supervisor 裁决。" >/dev/null 2>&1 || true
          fi
        else
          hold_ok=0
          echo "[$STAMP] STUCK-HOLD-FAILED unit=$id issue=missing episode=$kills" >> "$A/alerts/events.md"
        fi
        if (( hold_ok )); then
          to_supervisor "$id" "stuck stop-loss: episode $kills with no progress; the issue is held on-hold" \
            'Held after the second no-progress stuck episode; supervisor decides rescope, split, or requeue' \
            'the unit was stopped twice with an unchanged progress fingerprint (f8 wip-age signal)' \
            "stuck episodes: $kills, last one no-progress $((held/60))min" \
            '["Requeue another worker round at the same scope"]'
        else
          to_supervisor "$id" "stuck stop-loss: episode $kills with no progress; hold could not be applied" \
            'The unit is parked for supervisor arbitration; apply the issue hold before resuming it' \
            'the unit was stopped twice with an unchanged progress fingerprint (f8 wip-age signal)' \
            "stuck episodes: $kills, last one no-progress $((held/60))min" \
            '["Requeue another worker round at the same scope"]'
        fi
        set_unit "$id" "$(hist stuck-killed "no progress $((held/60))min; episode $kills") | $(hist stuck-stoploss "episode $kills") | del(.stuck_probe)"
        echo "[$STAMP] STUCK-STOPLOSS unit=$id pid=$pid type=$wtype episode=$kills no-progress=$((held/60))min" >> "$A/alerts/events.md"
        say "STUCK-STOPLOSS unit=$id pid=$pid episode=$kills"
      else
        if [[ "$wtype" == land ]]; then next="ready-to-merge"; else next="${wtype}-pending"; fi
        set_unit "$id" "$(hist stuck-killed "no progress $((held/60))min; episode $kills") | .stage=\"$next\" | del(.stuck_probe)"
        echo "[$STAMP] STUCK-KILL unit=$id pid=$pid type=$wtype → $next (f8 wip-age, no progress $((held/60))min)" >> "$A/alerts/events.md"
        say "STUCK-KILL pid=$pid unit=$id type=$wtype → $next"
      fi
    elif [[ -z "$probe" || "$(jqf -r .fp <<<"$probe")" != "$fp" ]]; then
      # 有进展（指纹变了）或首次探测：刷新探针时间戳，长任务因此不会被停。
      if [[ -z "$probe" ]]; then first_seen=$((first_seen + 1)); else progress=$((progress + 1)); fi
      set_unit "$id" ".stuck_probe={at:\"$STAMP\",fp:$(js "$fp")}"
    fi
  done
  # 信号恢复或单元离开超龄名单：清掉旧探针，下一次卡住从新指纹起算。
  for id in $(jqf -r '.units[] | select(.stuck_probe != null) | .id' "$UNITS"); do
    case " $offenders " in *" $id "*) ;; *) set_unit "$id" 'del(.stuck_probe)' ;; esac
  done
  if (( signal_active )); then
    action=no-kill
    (( killed_count == 0 )) || action=kill
    say "STUCK-DECISION named=$named_count live=$live_count fingerprint=first-seen:$first_seen,progress:$progress,unchanged-window:$unchanged_window,unchanged-confirmed:$unchanged_confirmed,no-live-worker:$no_live_worker action=$action killed=$killed_count"
  fi
}

recover_orphan_landing() { # landing 无活 land worker（被杀/重启）→ 回 ready-to-merge 重试
  local id wp has_live
  for id in $(jqf -r '.units[] | select(.stage=="landing") | .id' "$UNITS"); do
    has_live=false
    for wp in $(jqf -r --arg u "$id" '.workers[] | select(.unit==$u and .harvested != true) | .pid' "$WORKERS"); do
      alive "$wp" && has_live=true && break
    done
    [[ "$has_live" == true ]] || { set_unit "$id" '.stage="ready-to-merge"'; say "orphan-recover unit=$id landing -> ready-to-merge"; }
  done
}

# 失败回合数：只数返工/阻断/回退/无产出，不数正常推进（批准、合并不算）。
loop_rounds() { # 只数最近一次 supervisor 裁决（requeue/approve）或仲裁之后的失败回合（裁决后重新给满额度）
  # supervisor-approve 以前不算：issue-3560 获批后 CI 测试红转 repair，旧的 5 轮被重算，没修就直接转人工（05:13）。
  jqf -r '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage | IN("supervisor-requeue","supervisor-approve","arbiter-review")) | .key] | max // -1) as $i | [$h[($i + 1):][] | select(.stage=="review-request-changes" or .stage=="review-block" or .stage=="merge-reverted" or .stage=="worker-no-output")] | length' <<<"$1"
}

# 止损预算（#4363）：自最近一次裁决（supervisor requeue/approve 或顾问裁决）起，
# 已花费的 implement/repair 轮数（每个 write-start 一轮）与第一轮至今的墙钟。裁决重置预算，
# 让既有顾问收敛通道完整跑完；没有任何裁决拦得住的单元才止损转 supervisor。
# 预算内输出空；超轮数输出 "rounds N of B"，超墙钟输出 "wall Xmin of Ymin after N rounds"。
ticket_budget_reason() { # unit-json
  jqf -r --argjson round_budget "$TICKET_ROUND_BUDGET" --argjson wall_budget "$TICKET_WALL_BUDGET_SECONDS" --argjson now "$NOW_EPOCH" '
    (.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage | IN("supervisor-requeue","supervisor-approve","advisor-ruling")) | .key] | max // -1) as $ruling
    | [$h[($ruling + 1):][] | select(.stage == "write-start")] as $rounds
    | if ($rounds | length) >= $round_budget
      then "rounds \($rounds | length) of \($round_budget)"
      else ($rounds | map(.at // empty) | first) as $first
      | select($first != null)
      | (($first | sub("\\.[0-9]+"; "") | fromdateiso8601) as $t
        | select($now - $t > $wall_budget)
        | "wall \((($now - $t) / 60) | floor)min of \(($wall_budget / 60) | floor)min after \($rounds | length) rounds")
      end' <<<"$1" 2>/dev/null
}

# ---------- 2. 派发（焦点与并发；预算只告警） ----------
# 新 worker slot 按 main-red、热修回迁、critical 的现有紧急度排序；其后按配置 tier，再按环节。
# 2026-10-20 三个热修回迁在 review-pending 等了 56 分钟，名额被新收的孤儿 PR 先拿走（L62）。
dispatch_order() {
  jqf -c --argjson priority_order "$DISPATCH_PRIORITY_ORDER" '
    .units
    | map(select(.stage | test("-pending$")))
    | sort_by([
        (if .main_red == true then 0 else 1 end),
        (if .hotpatch == true then 0 else 1 end),
        (if .critical == true then 0 else 1 end),
        ((if .hotpatch == true then "hotfix" elif (.lane // "") == "direct-main" then "opt" else "normal" end) as $tier
          | ($priority_order | index($tier) // ($priority_order | length))),
        (if .stage == "repair-pending" or .stage == "rereview-pending" then 0 elif .stage == "review-pending" then 1 elif .stage == "implement-pending" then 2 else 3 end),
        (.id // "")
      ])[]
  ' "$UNITS"
}
# 合并后验证失败被 revert 的单元回到 repair，但原 PR 已是 MERGED：GitHub 不再把分支新提交挂到它上面，repair 推了也
# 显示"head 未变"，单元在 repair-no-push / 仲裁评审里空转到升级（2026-10-21 issue-3451 / #4009 空转 4 小时）。
# repair 交付后用同一分支开新 PR（已有 open PR 就沿用），评审与 CI 在新 PR 上进行。
reopen_reverted_pr() { # unit old-pr
  local branch issue title out pr
  branch="$(unit_field "$1" .branch)"; issue="$(unit_field "$1" '.issue // empty')"
  [[ -n "$branch" ]] || { to_supervisor "$1" "merge of #$2 was reverted but the unit has no branch to re-deliver"; return 0; }
  title="$(unit_field "$1" .title)"
  scheduler_pr_open "$branch" "${title:-$1}${issue:+ (#$issue)}" "${issue:+Refs #$issue

}Re-delivery of #$2: its squash merge was reverted on main after post-merge verification failed. This PR carries the same branch with the repair on top."
  pr="$SCHED_PR_NUM"
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then say "unit=$1 re-delivery PR for reverted #$2 not created yet (branch $branch)"; return 0; fi
  set_unit "$1" "$(hist pr-reopened "#$2 -> #$pr after merge revert") | .pr=$pr | del(.reopen_pr) | .reviewed_sha=null | .reviewed_pr_head=null$([[ "$branch" =~ $GATED_BRANCH_RE ]] && printf ' | .gated=true')"
  say "unit=$1 merge of #$2 was reverted -> re-delivered as PR #$pr"
}
approved_ci_repair_unchanged() { # unit-json head pr-head
  jqf -e --arg sha "$2" --arg pr_head "$3" '
    (.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage | IN("review-approve", "review-request-changes", "review-block")) | .key] | max // -1) as $last_review
    | .reviewed_sha == $sha and .reviewed_pr_head == $pr_head
      and $last_review >= 0 and $h[$last_review].stage == "review-approve" and $h[$last_review].result == $sha
      and $h[-1].stage == "repair-delivered"
      and any($h[($last_review + 1):][]; .stage == "ci-test-red" or .stage == "ci-red")
  ' <<<"$1" >/dev/null
}
# Advisor step of the review loop: after advisor_rounds rejections (default 3) the next repair round is replaced by one
# independent ruling. This distribution ships no advisor, so that step goes straight to the existing arbiter review
# (arbiter-review): no further repair round, no human queue. One arbiter review per count; the count restarts from it.
ADVISOR_ROUNDS="$(jqf -r '.advisor_rounds // 3' <<<"$CFG")"
advisor_launch() { # unit-json total-rounds
  local id decision
  id="$(jqf -r .id <<<"$1")"
  decision="$(decision_entry 'Route to one arbiter review' 'no advisor configured' "$2 review rejections; no advisor is installed" '["Return to ordinary repair without independent review"]' scheduler)"
  set_unit "$id" "$(hist arbiter-review "no advisor configured at round $2" "$decision") | .advisor_round=$2 | .arbiter=true | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
  say "no advisor configured; unit=$id round=$2 routed to arbiter-review"
}
repair_failure_prompt() { # unit-json review-report -> only this repair's failure evidence
  local u="$1" report="$2" hint pr checks name link job
  hint="$(jqf -r '.repair_hint // empty' <<<"$u")"
  [[ -z "$hint" ]] || printf '%s\n' "$hint"
  case "$(jqf -r '.history[-1].stage // empty' <<<"$u")" in
    ci-red|ci-test-red)
      pr="$(jqf -r '.pr // empty' <<<"$u")"
      checks="$(unset GH_TOKEN; gh pr checks "$pr" --json name,bucket,link 2>/dev/null)" || true
      checks="$(node "$HERE/../ci/pr-required-aggregate.mjs" --latest-checks <<<"$checks" 2>/dev/null)" || checks='[]'
      while IFS=$'\t' read -r name link; do
        job="${link##*/job/}"; [[ "$job" =~ ^[0-9]+$ ]] || continue
        printf '\nFailing CI check: %s\n%s\n' "$name" "$link"
        (unset GH_TOKEN; gh api "repos/{owner}/{repo}/actions/jobs/$job" \
          --jq '.steps[]? | select(.conclusion=="failure") | "Failing CI step: " + .name' 2>/dev/null)
        (unset GH_TOKEN; gh api --allow-escape-sequences "repos/{owner}/{repo}/actions/jobs/$job/logs" 2>/dev/null) | tail -80
      done < <(jqf -r '.[] | select(.bucket=="fail") | [.name,.link] | @tsv' <<<"$checks")
      ;;
    *)
      # Review findings come with the hint too (a hotpatch unit carries a hint and then gets REQUEST-CHANGES).
      if [[ -n "$report" && -r "$SUP/$report" ]]; then
        [[ -z "$hint" ]] || printf '\n评审报告 %s：\n' "$report"
        cat -- "$SUP/$report"
      elif [[ -z "$hint" ]]; then
        return 1
      fi
      ;;
  esac
  return 0
}

dispatch_pending() {
  local local_refill="${1:-false}" u id stage rounds total since allowed branch title pr_num rep wt prompt failure sha pr_head target prev_sha prev_pr_head prev_report task lane hint deliver issue key subject prless stack_branch stack_sha resume_branch resume_sha decision budget hold_cli handoff_status handoff_original
  while read -r u; do
    id="$(jqf -r .id <<<"$u")"; stage="$(jqf -r .stage <<<"$u")"
    # The independent refill controller only starts implementation workers from local ledger data.
    # Repair, review, rerun, and supervisor transitions need GitHub or a slower gate and stay on the slow tick.
    [[ "$local_refill" != true || "$stage" == implement-pending ]] || continue
    [[ "$(jqf -r '.hold_handoff_waiting // false' <<<"$u")" != false ]] && continue
    [[ -n "$(jqf -r '.advisor_pid // empty' <<<"$u")" ]] && continue
    if [[ "$(jqf -r '.self_fix_pending // false' <<<"$u")" == true ]]; then
      [[ "$local_refill" != true ]] || continue
      self_fix_dispatch "$u" || true
      continue
    fi
    # 止损预算（#4363）：第 4 轮（implement 加 repair）或超 4h 墙钟不再派发——
    # 原票经 hold.sh（on-hold 的唯一写入口，带 24h 过期的 durable hold 记录）自动搁置并评论附原因，
    # 单元转 supervisor（#4369 terra 裁决）；裁决后重新给满额度。
    if [[ "$stage" == implement-pending || "$stage" == repair-pending ]]; then
      budget="$(ticket_budget_reason "$u")"
      if [[ -n "$budget" ]]; then
        [[ "$local_refill" != true ]] || continue
        issue="$(jqf -r '.issue // empty' <<<"$u")"
        pr="$(jqf -r '.pr // empty' <<<"$u")"
        if [[ "$issue" =~ ^[0-9]+$ && -z "$pr" ]]; then
          supervisor_budget_recut "$id" "ticket stop-loss budget: $budget"
          continue
        fi
        if [[ -n "$issue" ]]; then
          hold_cli="$ROOT/engine/hold.sh"
          [[ -r "$hold_cli" ]] || hold_cli="$HERE/../hold.sh"
          bash "$hold_cli" --hold "$issue" --holder scheduler-stop-loss \
            --release 'supervisor rules on the stop-loss escalation; requeue or approve refills the budget' \
            --expires 24h --kind stop-loss >/dev/null 2>&1 || true
          gh issue comment "$issue" --body "止损预算（#4363）：这张票自最近一次裁决起已用 $budget，自动搁置（on-hold，24h 后未裁决自动恢复），停止下一轮自动派发。单元 $id 已转 supervisor 裁决；supervisor requeue/approve 后预算重新给满。" >/dev/null 2>&1 || true
        fi
        to_supervisor "$id" "stop-loss: $budget since the last supervisor ruling; the issue is held on-hold" \
          'Held at the per-ticket stop-loss budget; supervisor decides rescope, split, or requeue' \
          'the per-ticket round and wall-clock budget was reached' \
          "budget of $TICKET_ROUND_BUDGET rounds (implement+repair) or $((TICKET_WALL_BUDGET_SECONDS / 60)) minutes exceeded: $budget" \
          '["Dispatch another implement/repair round at the same scope"]'
        continue
      fi
    fi
    if [[ "$stage" == repair-pending || "$stage" == rereview-pending ]]; then
      total="$(jqf -r '[(.history // [])[] | select(.stage=="review-request-changes")] | length' <<<"$u")"
      # 顾问裁决或仲裁评审之后重新数打回：从那次事件起算满 ADVISOR_ROUNDS 次才再问。
      since="$(jqf -r '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage | IN("advisor-ruling","arbiter-review")) | .key] | max // -1) as $i | [$h[($i + 1):][] | select(.stage=="review-request-changes")] | length' <<<"$u")"
      if [[ "$stage" == repair-pending ]] && (( since >= ADVISOR_ROUNDS )) && (( total > $(jqf -r '.advisor_round // 0' <<<"$u") )) \
        && [[ "$(jqf -r 'if .advisor == false then "off" else "on" end' <<<"$CFG")" == on ]] && [[ "$(jqf -r '.history[-1].stage // ""' <<<"$u")" =~ ^review-request-changes$ ]]; then
        jqf -e 'any(.units[]; .advisor_pid != null)' "$UNITS" >/dev/null || advisor_launch "$u" "$total"
        continue
      fi
      allowed="$(jqf -r --argjson d "$LOOP_TOTAL_ROUNDS" '.loop_total_allowed // $d' <<<"$u")"
      if (( total >= allowed )); then
        # 不收敛不是再修一轮能解决的：交 supervisor 拆票或重定范围；裁决后再给 4 轮额度。
        set_unit "$id" ".loop_total_allowed=$((total + 4))"
        to_supervisor "$id" "non-converging: $total request-changes rounds in total; re-scope or split the issue instead of another repair" \
          'Request supervisor rescope or split' 'the lifetime review-rejection allowance was reached' \
          "$total request-changes rounds; lifetime allowance $allowed" '["Dispatch another repair without rescoping"]'
        continue
      fi
    fi
    rounds="$(loop_rounds "$u")"
    if [[ "${rounds:-0}" =~ ^[0-9]+$ ]] && (( rounds >= LOOP_BREAKER_ROUNDS )); then
      [[ "$local_refill" != true ]] || continue
      # 先给一次仲裁评审（全新视角、只认阻断级）；仲裁后仍不收敛才转人工。
      if (( $(jqf -r '[(.history // [])[] | select(.stage=="arbiter-review")] | length' <<<"$u") == 0 )); then
        decision="$(decision_entry 'Route to one arbiter review' 'review loop reached breaker threshold' "$rounds failed rounds; no prior arbiter review" '["Dispatch another ordinary repair"]' scheduler)"
        set_unit "$id" "$(hist arbiter-review "loop-breaker: $rounds failed rounds" "$decision") | .arbiter=true | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
        say "loop-breaker unit=$id: $rounds rounds -> one arbiter review"
      else
        to_supervisor "$id" "loop-breaker: $rounds failed rounds after an arbiter review" \
          'Stop automated repair and escalate to supervisor' 'loop breaker reached again after one arbiter review' \
          "$rounds failed rounds after an arbiter review" '["Dispatch another repair or arbiter review"]'
      fi
      continue
    fi
    title="$(jqf -r '.title // ""' <<<"$u")"; pr_num="$(jqf -r '.pr // empty' <<<"$u")"
    issue="$(jqf -r '.issue // empty' <<<"$u")"; lane="$(jqf -r '.lane // empty' <<<"$u")"
    key="${pr_num:-$id}"; subject="$(subject_of "$pr_num" "$issue")"
    prless=0; [[ -z "$pr_num" && "$lane" == direct-main ]] && prless=1
    case "$stage" in
      repair-pending)
        [[ -n "$pr_num" || "$prless" == 1 ]] || { to_supervisor "$id" "repair-pending without a PR"; continue; }
        if [[ -n "$(jqf -r '.hold_handoff_episode // empty' <<<"$u")" ]] && park_if_body_blocked "$u"; then
          [[ "$(unit_field "$id" .stage)" != blocked-external ]] || set_unit "$id" '.blocked_resume_stage="repair-pending"'
          continue
        fi
        branch="$(jqf -r '.branch // empty' <<<"$u")"
        if [[ -z "$branch" && -n "$pr_num" ]]; then
          branch="$(pr_view "$pr_num" headRefName)"
          [[ -n "$branch" ]] && set_unit "$id" ".branch=$(js "$branch")"
        fi
        [[ -n "$branch" ]] || { say "repair-pending unit=$id: PR branch unavailable"; continue; }
        wt=""
        if [[ "$pr_num" =~ ^[0-9]+$ && "$lane" != direct-main ]]; then
          wt="$(pre_dispatch_pr_admission "$id" "$branch" "$pr_num" "repair-pending before dispatch")" || continue
        fi
        room_for "$id" repair "$u" || continue
        pick implement "$u" || continue
        prev_report="$(jqf -r '.review_report // empty' <<<"$u")"
        [[ -n "$prev_report" ]] || prev_report="$(cd "$SUP" && ls -t "review-${key}-"*.md 2>/dev/null | grep -v worker | head -1)"
        [[ -n "$prev_report" || -n "$(jqf -r '.repair_hint // empty' <<<"$u")" ]] || { to_supervisor "$id" "repair-pending without a review report"; continue; }
        handoff_original=""
        if [[ -n "$pr_num" ]] && { [[ -n "$(jqf -r '.handoff_worktree_sha // empty' <<<"$u")" && "$(jqf -r '.handoff_worktree_applied // false' <<<"$u")" != true ]] || [[ -n "$(jqf -r '.handoff_start_ref // empty' <<<"$u")" && "$(jqf -r '.handoff_start_applied // false' <<<"$u")" != true ]]; }; then
          handoff_original="$(pr_view "$pr_num" headRefOid)" || continue
          [[ "$handoff_original" =~ $SHA_RE ]] || continue
        fi
        if [[ -n "$(jqf -r '.handoff_worktree_sha // empty' <<<"$u")" && "$(jqf -r '.handoff_worktree_applied // false' <<<"$u")" != true ]]; then
          handoff_status=0
          wt="$(handoff_worktree_clone "$id" "$branch" "$(jqf -r '.handoff_worktree // empty' <<<"$u")" "$(jqf -r '.handoff_worktree_sha' <<<"$u")" "$(jqf -r '.handoff_worktree_dirty // false' <<<"$u")" "$((1 - prless))" "$(jqf -r '.handoff_start_ref // empty' <<<"$u")" "$(jqf -r '.handoff_start_sha // empty' <<<"$u")" "$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_branch // empty end' <<<"$u")" "$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_sha // empty end' <<<"$u")")" || handoff_status=$?
          if (( handoff_status != 0 )); then
            if (( handoff_status == 73 )); then to_supervisor "$id" "handoff conflicts with the existing branch; inspect the preserved owner worktree and PR"; else say "repair-pending unit=$id: previous worktree unavailable"; fi
            continue
          fi
          record_handoff_integration "$id" "$wt" "$handoff_original" || continue
        elif [[ -n "$(jqf -r '.handoff_start_ref // empty' <<<"$u")" && "$(jqf -r '.handoff_start_applied // false' <<<"$u")" != true ]]; then
          handoff_status=0
          wt="$(handoff_worktree_clone "$id" "$branch" "" "$(jqf -r '.handoff_start_sha' <<<"$u")" false "$((1 - prless))" "$(jqf -r '.handoff_start_ref' <<<"$u")" "$(jqf -r '.handoff_start_sha' <<<"$u")" "$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_branch // empty end' <<<"$u")" "$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_sha // empty end' <<<"$u")")" || handoff_status=$?
          if (( handoff_status != 0 )); then
            if (( handoff_status == 73 )); then to_supervisor "$id" "rescued handoff conflicts with the existing branch; inspect the preserved rescue and PR"; else say "repair-pending unit=$id: rescued ref unavailable"; fi
            continue
          fi
          record_handoff_integration "$id" "$wt" "$handoff_original" || continue
        else
          if [[ -z "$wt" ]]; then
            wt="$(ensure_clone "$id" "$branch" "$((1 - prless))" "$([[ -n "$pr_num" ]] && pr_view "$pr_num" headRefOid)")" || { say "repair-pending unit=$id: clone/branch $branch unavailable"; continue; }
          fi
        fi
        resume_handoff_integration "$id" "$wt" || continue
        rep="impl-${key}-fix-${TAG}.md"
        failure="$(repair_failure_prompt "$u" "$prev_report")" || { to_supervisor "$id" "repair-pending: cannot read the failure evidence ($prev_report)"; continue; }
        hint="$(jqf -r '.repair_hint // empty' <<<"$u")"
        [[ -n "$hint" ]] && hint="
本轮额外阻断（优先处理；评审报告若已 READY，只需处理这一条）：$hint"
        if [[ "$lane" == direct-main ]]; then
          deliver="node scripts/branch-delivery-preflight.mjs --mode commit 通过后在本地分支 ${branch} 提交即可，【不要 push】：这是非产品快车道，复审通过后流水线会把它压成一个提交经 land-direct-main.sh 直落 main。提交信息不要带 [skip ci]。"
        else
          deliver="node scripts/branch-delivery-preflight.mjs --mode push --publish-topic 通过后 push 到 origin ${branch}（绝不推 main、不 force）。"
        fi
        prompt="你是 the product 流水线的实现 subagent，修复 ${subject} 的评审阻断发现。当前目录是隔离 clone：$wt（分支 ${branch}，已同步 origin）。
$(matt_method_rule "$wt")
0. 先看 git stash list：若有「autopilot: kept before redispatch」，那是上一轮未推送的修复，先 git stash pop 恢复并在其基础上继续。
0b. 先合入最新 main：git merge --no-edit origin/main（不 rebase、不 force；有冲突按两边意图解决）。push preflight 的 freshness 门禁拒绝落后 main 过多的分支，不合就永远推不上。
1. 读评审报告 $SUP/${prev_report}，逐条处理其中的阻断发现（${title}）。不得为凑绿弱化断言。按缺陷类别修，不按单点修：每条发现先归纳成一类问题（例：单位码被显示名覆盖、幂等键缺字段），在本 PR 全部改动里搜出同类位置一并处理，每一类补一条回归测试；只修被点名的那一行，下一轮评审会在同类的另一处再打回。${hint}
1b. 修复报告必须按 $REVIEW_CONTRACT_MD 中的 author-disposition schema，为上一轮每个 finding ID 记录处置和一行理由；复审会从单元历史读取这些处置。
2. 补/改回归测试，定向跑受影响测试与 typecheck 全绿。${INTEGRATION_RULE}
3. ${deliver}
   若本地分支已有上一轮未推送的提交（git log origin/${branch}..HEAD 非空），在其基础上继续，不要重做。
4. 禁止：动主 checkout、合并 PR（gh pr merge）、改 GitHub 状态、部署。0b 的 git merge origin/main 不在此列。
5. 修复说明（改动、验证输出摘要、push SHA 或本地提交 SHA）写到 $SUP/${rep}，交付完即结束。
$(decision_scope "$u")"
        dispatch_if_room "$id" "repair" "repair" "${rep%.md}.worker.log" "$rep" \
          "$PICK_MODEL" "$PICK_EFFORT" "$prompt$(sweep_rule "$u")$(supervisor_rule "$u")" "" "$wt" "" "$failure" "$u" && [[ -n "$pr_num" ]] && repair_demote "$id" "$pr_num" "$branch"
        true ;;
      rereview-pending)
        [[ -n "$pr_num" || "$prless" == 1 ]] || { to_supervisor "$id" "rereview-pending without a PR"; continue; }
        if [[ "$(jqf -r '.reopen_pr // false' <<<"$u")" == true ]]; then reopen_reverted_pr "$id" "$pr_num"; continue; fi
        room_for "$id" rereview "$u" || continue
        pick review || continue
        target="$(unit_review_target "$id" "$pr_num" "$lane" "$(jqf -r '.branch // empty' <<<"$u")")" || continue
        read -r pr_head sha <<<"$target"
        [[ "$sha" =~ $SHA_RE ]] || continue
        verify_handoff_delivery "$id" "$pr_num" "$(jqf -r '.branch // empty' <<<"$u")" "$sha" || continue
        prev_sha="$(jqf -r '.reviewed_sha // empty' <<<"$u")"
        prev_pr_head="$(jqf -r '.reviewed_pr_head // empty' <<<"$u")"
        if [[ "$prev_sha" == "$sha" && "$prev_pr_head" == "$pr_head" ]]; then
          if [[ "$pr_num" =~ ^[0-9]+$ ]] && approved_ci_repair_unchanged "$u" "$sha" "$pr_head"; then
            # Repair returned the exact approved head after a CI red: reuse the existing unit-row retry budget,
            # and mark this head rerun so the merge lane does not spend an uncounted first retry.
            local k n=0 r failed_runs rerun_failed=0
            k="$(unit_field "$id" '.ci_infra_reruns // 0')"; [[ "$k" =~ ^[0-9]+$ ]] || k=0
            if (( k < CI_INFRA_RERUNS )); then
              failed_runs="$(gh run list --commit "$sha" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure" or .conclusion=="cancelled") | .databaseId' 2>/dev/null)" \
                || { to_supervisor "$id" "could not list failed CI runs for unchanged approved head $sha"; continue; }
              [[ -n "$failed_runs" ]] || { to_supervisor "$id" "no failed CI run found for unchanged approved head $sha"; continue; }
              for r in $failed_runs; do
                if gh run rerun "$r" --failed >/dev/null 2>&1; then n=$((n+1)); else rerun_failed=1; fi
              done
              (( n > 0 && rerun_failed == 0 )) || { to_supervisor "$id" "GitHub rejected a failed-run rerun for unchanged approved head $sha"; continue; }
              set_unit "$id" "$(hist ci-repair-rerun "unchanged approved head $sha; rerun $((k+1))/$CI_INFRA_RERUNS") | .ci_infra_reruns=$((k+1)) | .ci_rerun_sha=$(js "$sha") | .approved_sha=$(js "$sha") | .stage=\"ready-to-merge\""
              say "repair-no-push unit=$id: approved head $sha unchanged after CI failure -> reran $n failed run(s), retry $((k+1))/$CI_INFRA_RERUNS"
            else
              to_supervisor "$id" "approved head $sha remained unchanged after $k bounded CI reruns"
            fi
            continue
          fi
          # repair 交付了报告却没推出新 head（多为 GitHub 间歇断连，改动留在 clone/stash）：自动重试 repair 两次再转人工。
          if [[ "$(jqf -r '(.history // [])[-1].stage // ""' <<<"$u")" == repair-delivered ]] \
            && (( $(jqf -r '[(.history // [])[] | select(.stage=="repair-no-push")] | length' <<<"$u") < 2 )); then
            set_unit "$id" "$(hist repair-no-push "head $sha unchanged after repair") | .stage=\"repair-pending\""
            say "repair-no-push unit=$id: head $sha unchanged after repair -> retry repair"
            continue
          fi
          # 修复者两次都没推新提交，多半认为评审发现不成立：先做一次仲裁评审，仍不收敛才转人工。
          if (( $(jqf -r '[(.history // [])[] | select(.stage=="arbiter-review")] | length' <<<"$u") == 0 )); then
            decision="$(decision_entry 'Route to one arbiter review' 'repair returned without a new commit' "head $sha unchanged since last review" '["Dispatch another repair without independent review"]' scheduler)"
            set_unit "$id" "$(hist arbiter-review "head $sha unchanged since last review" "$decision") | .arbiter=true | .reviewed_sha=null | .reviewed_pr_head=null"
            say "head unchanged unit=$id -> one arbiter review"
          else
            to_supervisor "$id" "head $sha unchanged since last review after an arbiter review"
          fi
          continue
        fi
        wt="$(ensure_clone "$id")" || { say "rereview-pending unit=$id: clone unavailable"; continue; }
        checkout_pr_head "$wt" "$pr_num" "$sha" "$pr_head" || { say "rereview-pending unit=$id: PR head $sha unavailable"; continue; }
        prev_report="$(jqf -r '.review_report // empty' <<<"$u")"
        # 增量复审的前提是上轮 head 是当前 head 的真祖先（prev..sha 即修复增量）。PR head 随每次修复推送而变，
        # 不能用"PR head 未变"当前提：7c38abda0 那样判定后，2026-10-20 起 PR 车道零增量复审，每轮都是重新抽样的全量评审，
        # 每轮挖出新发现、永不收敛（L63）。rebase/force-push（不再是祖先）或候选未变才回落到完整评审。
        if [[ ! "$prev_sha" =~ $SHA_RE || -z "$prev_report" || "$prev_sha" == "$sha" ]] \
          || ! git -C "$wt" merge-base --is-ancestor "$prev_sha" "$sha" 2>/dev/null; then
          # 没有可核销的上一轮基线：做一次完整评审，不允许空 diff 的"增量复审"放行。
          rep="review-${key}-${TAG}.md"
          prompt="$(review_prompt "$subject" "$title" "$sha" "$rep" "$lane" "$wt")$(sweep_rule "$u" "$sha")$(arbiter_rule "$u")$(hotpatch_rule "$u")$(supervisor_rule "$u")"
        dispatch_if_room "$id" "review" "review" "${rep%.md}.worker.log" "$rep" \
            "$PICK_MODEL" "$PICK_EFFORT" "$prompt" "$sha" "$wt" "$pr_head" "$prompt" "$u" || true
          continue
        fi
        rep="review-${key}-r-${TAG}.md"
        prompt="你是 the product 流水线的独立代码评审 subagent，只读增量复审。当前目录是隔离 clone，已检出 PR 当前 head（detached），origin/main 为最新 main。
复审 ${subject}（${title}）当前 head ${sha}，上轮 head ${prev_sha}。按正式契约中的 Targeted re-review 流程，仅检查 ${prev_sha}..${sha} 的 PR 增量及其直接依赖闭包；报告写到 $SUP/${rep}。
读取上轮报告 $SUP/${prev_report} 和单元历史中的作者处置，再按处置逐条核验。$(review_contract_rule "$wt")
只读边界：不编辑/commit/push/merge/评论。$(review_dispositions_context "$u")$(risk_class_safety_rule "$wt")$(lane_rule "$lane" "$sha")$(sweep_rule "$u" "$sha")$(hotpatch_rule "$u")$(supervisor_rule "$u")"
        dispatch_if_room "$id" "rereview" "rereview" "${rep%.md}.worker.log" "$rep" \
          "$PICK_MODEL" "$PICK_EFFORT" "$prompt" "$sha" "$wt" "$pr_head" "$prompt" "$u" || true ;;
      review-pending)
        [[ -n "$pr_num" || "$prless" == 1 ]] || continue
        room_for "$id" review "$u" || continue
        pick review || continue
        target="$(unit_review_target "$id" "$pr_num" "$lane" "$(jqf -r '.branch // empty' <<<"$u")")" || continue
        read -r pr_head sha <<<"$target"
        [[ "$sha" =~ $SHA_RE ]] || continue
        verify_handoff_delivery "$id" "$pr_num" "$(jqf -r '.branch // empty' <<<"$u")" "$sha" || continue
        wt="$(ensure_clone "$id")" || { say "review-pending unit=$id: clone unavailable"; continue; }
        checkout_pr_head "$wt" "$pr_num" "$sha" "$pr_head" || { say "review-pending unit=$id: PR head $sha unavailable"; continue; }
        rep="review-${key}-${TAG}.md"
        prompt="$(review_prompt "$subject" "$title" "$sha" "$rep" "$lane" "$wt")$(arbiter_rule "$u")$(hotpatch_rule "$u")$(supervisor_rule "$u")"
        dispatch_if_room "$id" "review" "review" "${rep%.md}.worker.log" "$rep" \
          "$PICK_MODEL" "$PICK_EFFORT" "$prompt" "$sha" "$wt" "$pr_head" "$prompt" "$u" || true ;;
      implement-pending)
        task="$(jqf -r '.task // empty' <<<"$u")"; branch="$(jqf -r '.branch // ""' <<<"$u")"
        [[ -z "$task" ]] && { say "implement-pending unit=$id has no .task; supervisor required"; continue; }
        [[ -z "$branch" ]] && { say "implement-pending unit=$id has no .branch; supervisor required"; continue; }
        wt=""
        if [[ "$local_refill" == true ]]; then
          [[ -z "$(blocking_body_dependency "$u")" ]] || continue
          if [[ -n "$(jqf -r '.handoff_worktree_sha // empty' <<<"$u")" && "$(jqf -r '.handoff_worktree_applied // false' <<<"$u")" != true ]] \
            || [[ -n "$(jqf -r '.handoff_start_ref // empty' <<<"$u")" && "$(jqf -r '.handoff_start_applied // false' <<<"$u")" != true ]]; then
            continue
          fi
        else
          park_if_body_blocked "$u" && continue
        fi
        if [[ "$local_refill" != true && "$pr_num" =~ ^[0-9]+$ && "$lane" != direct-main ]]; then
          wt="$(pre_dispatch_pr_admission "$id" "$branch" "$pr_num" "implement-pending before dispatch")" || continue
        fi
        room_for "$id" implement "$u" || continue
        pick implement "$u" || continue
        stack_branch="$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_branch // empty end' <<<"$u")"; stack_sha="$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_sha // empty end' <<<"$u")"
        resume_branch="$(jqf -r '.handoff_start_ref // empty' <<<"$u")"; resume_sha="$(jqf -r '.handoff_start_sha // empty' <<<"$u")"
        if [[ -n "$(jqf -r '.handoff_worktree_sha // empty' <<<"$u")" && "$(jqf -r '.handoff_worktree_applied // false' <<<"$u")" != true ]]; then
          handoff_status=0
          wt="$(handoff_worktree_clone "$id" "$branch" "$(jqf -r '.handoff_worktree // empty' <<<"$u")" "$(jqf -r '.handoff_worktree_sha' <<<"$u")" "$(jqf -r '.handoff_worktree_dirty // false' <<<"$u")" 0 "$(jqf -r '.handoff_start_ref // empty' <<<"$u")" "$(jqf -r '.handoff_start_sha // empty' <<<"$u")" "$stack_branch" "$stack_sha")" || handoff_status=$?
          if (( handoff_status != 0 )); then
            if (( handoff_status == 73 )); then to_supervisor "$id" "handoff conflicts with the existing branch; inspect the preserved owner worktree and PR"; else say "implement-pending unit=$id: previous worktree unavailable"; fi
            continue
          fi
          record_handoff_integration "$id" "$wt" "" || continue
        elif [[ -n "$resume_branch" && "$resume_sha" =~ $SHA_RE && "$(jqf -r '.handoff_start_applied // false' <<<"$u")" != true ]]; then
          handoff_status=0
          wt="$(handoff_worktree_clone "$id" "$branch" "" "$resume_sha" false 0 "$resume_branch" "$resume_sha" "$stack_branch" "$stack_sha")" || handoff_status=$?
          if (( handoff_status != 0 )); then
            if (( handoff_status == 73 )); then to_supervisor "$id" "rescued handoff conflicts with the stacked branch; inspect both histories"; else say "implement-pending unit=$id: rescued checkout unavailable"; fi
            continue
          fi
          record_handoff_integration "$id" "$wt" "" || continue
        elif [[ -n "$stack_branch" && -n "$stack_sha" ]]; then
          if [[ -z "$wt" ]]; then
            if [[ "$local_refill" == true ]]; then
              wt="$(ensure_clone "$id" "$branch" 0 "" "$stack_branch" "$stack_sha" true)" || { say "implement-pending unit=$id: stacked clone unavailable"; continue; }
            else
              wt="$(ensure_clone "$id" "$branch" 0 "" "$stack_branch" "$stack_sha")" || { say "implement-pending unit=$id: stacked clone unavailable"; continue; }
            fi
          fi
        else
          if [[ -z "$wt" ]]; then
            if [[ "$local_refill" == true ]]; then
              wt="$(ensure_clone "$id" "$branch" 0 "" "" "" true)" || { say "implement-pending unit=$id: clone unavailable"; continue; }
            else
              wt="$(ensure_clone "$id" "$branch")" || { say "implement-pending unit=$id: clone unavailable"; continue; }
            fi
          fi
        fi
        resume_handoff_integration "$id" "$wt" || continue
        rep="impl-${id}-${TAG}.md"
        set_unit "$id" ".report=$(js "$rep")"
        if [[ "$lane" == direct-main ]]; then
          deliver="ACCEPTANCE：
先确认问题在当前 main 上仍存在：已被修复或不再适用就不改代码，报告第一行写 OBSOLETE: <证据>。${OPT_PREMISE_RULE}
VERIFY：
本地定向验证全绿；node scripts/branch-delivery-preflight.mjs --mode commit 通过后在本地分支 ${branch} 提交（提交信息不带 [skip ci]）——这是非产品快车道，评审通过后流水线把它压成一个提交经 land-direct-main.sh 直落 main。
FORBIDDEN：
只改非产品路径（scripts/、lessons/、docs/、.agents/ 等）；修复必须改产品代码（packages/、apps/、services/）或 .github/workflows 时不要改，报告第一行写 NEEDS-PR: <原因>。不要 push、不开 PR；禁止 merge PR/部署/改 GitHub 状态。
REPORT：
产出说明写到 $SUP/${rep}（根因、改动、验证输出摘要、本地提交 SHA）。交付完即结束。"
        else
          deliver="ACCEPTANCE：
先确认问题在当前 main 上仍存在：已被修复或不再适用就不改代码，报告第一行写 OBSOLETE: <证据>。否则修根因并补回归测试。${OPT_PREMISE_RULE}
尺寸准入：${branch} 相对 main 的改动合计（Markdown/文档、生成物、锁文件、测试快照不计入）不超过 ${SIZE_ADMISSION_LINES} 行，push 前用 git diff --numstat origin/main...HEAD 自查。整张票放不进限额时不要硬塞：只实现第一个可独立交付的完整切片（含必要测试），报告第一行改写 SPLIT: <剩余范围一句话>，剩余工作由流水线另开续作票承接；不要为压行数砍掉切片必需的测试。
VERIFY：
本地定向验证全绿；${INTEGRATION_RULE}node scripts/branch-delivery-preflight.mjs --mode push --publish-topic 通过后 push 分支 ${branch} 到 origin。
FORBIDDEN：
不 push main、不 force、不开 PR——流水线会开 PR 并派评审；禁止 merge PR/部署/改 GitHub 状态。
REPORT：
产出说明写到 $SUP/${rep}（根因、改动、验证输出摘要、push SHA；SPLIT 时写清已交付切片的边界和剩余范围）。交付完即结束。"
        fi
        feature_issue="$(jqf -r '.issue // empty' <<<"$u")"
        feature_state='{}'
        if [[ -n "$feature_issue" && -n "${STATE_DIR:-}" ]]; then
          feature_state="$(cat "$STATE_DIR/$feature_issue.json" 2>/dev/null)"
          [[ -n "$feature_state" ]] || feature_state='{}'
        fi
        feature_plan="$(verification_plan_for_state "$wt" "$feature_state")"
        feature_brief="$(verification_plan_brief "$feature_plan")"
        prompt="GOAL：
$task

SCOPE：
issue 写明的前置 issue 尚未交付（仍 open、没有已合并的修复）时不要改代码，报告第一行写 BLOCKED-ON: #<前置 issue 号>，流水线会在前置交付后重派。路线图 epic/主题（roadmap-epic、roadmap-theme、roadmap 标签的伞形 issue）不是前置：不要对它写 BLOCKED-ON，直接实现本 issue 自己的切片。
当前目录是隔离 clone：$wt（分支 ${branch}，基于最新 main 或该分支已有的进度）。若 git stash list 有「autopilot: kept before redispatch」，是上一轮未提交的进度，先 git stash pop 恢复。
$(decision_scope "$u")
$(matt_method_rule "$wt")
Feature verification plan (advisory, from ticket-declared paths): $feature_brief
After implementation, refresh IDs from the actual changed paths with node engine/verification-plan.mjs --root . --base origin/main --head HEAD. Run node scripts/e2e/acceptance-regression/verify-feature.mjs --feature <IDs> --target <base-url> --json only when a candidate target already serves this build. Record the JSON output path. If no candidate target exists, say so; do not build a local stack. This is worker evidence, not a merge gate.

$deliver"
        dispatch_if_room "$id" "implement" "implement" "${rep%.md}.worker.log" "$rep" \
          "$PICK_MODEL" "$PICK_EFFORT" "$prompt" "" "$wt" "" "$prompt" "$u" || true ;;
    esac
  done < <(dispatch_order)
}

CI_INFRA_RERUNS=3
CI_INFRA_STEP_RE='^(Set up job|Seed cold workspace|Configure git proxy|Run actions/checkout@v4|Ensure CI runner has capacity)'
ci_failed_steps() { # head -> failed step names of the head's failed runs
  local r
  for r in $(gh run list --commit "$1" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure") | .databaseId' 2>/dev/null); do
    gh api "repos/{owner}/{repo}/actions/runs/$r/jobs" --jq '.jobs[] | select(.conclusion=="failure") | .steps[] | select(.conclusion=="failure") | .name' 2>/dev/null
  done
}
ci_infra_red() { # head -> 0 when every failed step is a runner-environment step
  local steps; steps="$(ci_failed_steps "$1")"
  [[ -n "$steps" ]] && ! grep -qvE "$CI_INFRA_STEP_RE" <<<"$steps"
}

ci_unit_facts() { # id head → 早期测试红路径已为同一 head 解析过的事实；换了 head 就不沿用
  [[ "$(unit_field "$1" .ci_facts_head)" == "$2" ]] && unit_field "$1" .ci_facts
  return 0
}

# 所有 update-branch 都走这一个封装：expected_head_sha 钉住观察到的 head，GitHub 在 head 已变时返回 422，不会更新陌生提交。
ci_update_branch() { # pr head
  gh api -X PUT "repos/{owner}/{repo}/pulls/$1/update-branch" -f "expected_head_sha=$2" >/dev/null 2>&1
}

ci_red() { # id pr head names：同一 head 首次红只重跑失败的 run（多为 runner 抖动），重跑后仍红才派 repair
  local r n=0
  if [[ "$(unit_field "$1" .ci_rerun_sha)" != "$3" ]] && pr_behind_main "$2" "$3" && [[ "$(pr_view "$2" mergeable)" == MERGEABLE ]]; then
    # 落后 main 的红多半是旧 base 的红（2026-10-19：main 自身 suites 红，5 个就绪 PR 跟着红）：服务端合入 main 再跑，
    # 不在旧 base 上重跑、不派 LLM 修复；干净合并的新 head 沿用原批准（approval_carries）。
    if ci_update_branch "$2" "$3"; then
      set_unit "$1" "$(hist ci-red-update-branch "$4") | .ci_rerun_sha=$(js "$3")"
      say "merge skipped PR#$2 (checks red on a stale base: $4) -> update-branch"
      return 0
    fi
  fi
  if [[ "$(unit_field "$1" .ci_deferred_sha)" == "$3" ]]; then
    for r in $(gh run list --commit "$3" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure" or .conclusion=="cancelled") | .databaseId' 2>/dev/null); do
      gh run rerun "$r" --failed >/dev/null 2>&1 && n=$((n+1))
    done
    set_unit "$1" "$(hist ci-deferred-start "$4") | del(.ci_deferred_sha)"
    say "merge skipped PR#$2 (approved head; CI deferred during review) -> started $n run(s)"
    return 0
  fi
  if [[ "$(unit_field "$1" .ci_rerun_sha)" != "$3" ]]; then
    for r in $(gh run list --commit "$3" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure" or .conclusion=="cancelled") | .databaseId' 2>/dev/null); do
      gh run rerun "$r" --failed >/dev/null 2>&1 && n=$((n+1))
    done
    set_unit "$1" "$(hist ci-red-rerun "$4") | .ci_rerun_sha=$(js "$3")"
    say "merge skipped PR#$2 (checks red: $4) -> reran $n failed run(s) once"
    return 0
  fi
  if ci_infra_red "$3"; then
    # runner 环境步骤红（磁盘/容量门、Set up job、checkout 前准备）不是代码结论：不作废批准、不派 LLM 修复，
    # 再重跑；同一 head 连红 CI_INFRA_RERUNS 次交给 supervisor 修 runner（2026-10-20 cihost /data 90% 满，
    # 磁盘门把 PR CI 全拦红，已批准单元被送去 repair 又丢批准）。
    local k decision; k="$(unit_field "$1" '.ci_infra_reruns // 0')"; [[ "$k" =~ ^[0-9]+$ ]] || k=0
    echo "[$STAMP] RUNNER-INFRA-RED PR#$2 head=$3 steps: $(ci_failed_steps "$3" | sort -u | paste -sd ';') (rerun $((k+1))/$CI_INFRA_RERUNS)" >> "$A/alerts/gate.md"
    if (( k < CI_INFRA_RERUNS )); then
      for r in $(gh run list --commit "$3" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure" or .conclusion=="cancelled") | .databaseId' 2>/dev/null); do
        gh run rerun "$r" --failed >/dev/null 2>&1 && n=$((n+1))
      done
      set_unit "$1" "$(hist ci-infra-red "$4") | .ci_infra_reruns=$((k+1))"
      say "merge skipped PR#$2 (runner environment failure, not the code: $4) -> reran $n run(s), approval kept"
    else
      decision="$(decision_entry 'Stop CI retries and escalate runner failure to supervisor' 'runner environment failure persisted after the retry budget' "head $3 after $k reruns: $4" '["Dispatch a code repair for the runner failure"]' scheduler)"
      set_unit "$1" "$(hist supervisor-review "runner environment failure on head $3 after $k reruns: $4" "$decision") | .stage=\"supervisor-review\""
      say "merge skipped PR#$2 (runner environment failure persists: $4) -> supervisor-review"
    fi
    return 0
  fi
  set_unit "$1" "$(hist ci-red "$4") | .approved_sha=null | .repair_hint=$(js "PR head $3 的必需检查重跑后仍失败：$4。用 gh pr checks $2 与 gh run view <run-id> --log-failed 定位；失败的是集成测试就先在本机测试库复现（RUN_INTEGRATION=1 npx vitest run <文件>，PGTEST_URL 已配好），修到本地绿再 push；本 PR 引起的就修并补回归测试；确属与本 PR 无关的环境故障就不改代码，在报告里写明证据。$(ci_fact_hint "$3" "$(ci_unit_facts "$1" "$3")")") | .stage=\"repair-pending\""
  say "merge skipped PR#$2 (checks still red after rerun: $4) -> repair-pending"
}

# 只有"取消"、没有失败的检查不是代码结论：多为流水线自己取消的（评审中推迟 CI、打回时
# cancel_branch_runs、bell 去重；热修优先挡板退役前也在其中，#4625）。以前它和失败一样消耗唯一的重跑额度，第二次再被取消就作废批准、派 repair
# （pr-2609 已批准的 21a072c91 没有任何失败 job，2026-10-21 14:30 仍被判"重跑后仍红"送去修复，L64）。
CI_CANCEL_RERUNS=3
# 聚合 job 因上游被取消而红（needs.<job>.result 为 cancelled）：失败的检查只有 "Pipeline suites" 聚合 job，且同一工作流的
# 其余 job（scope / focused / full 分片）没有失败、至少一个被取消。任何真实失败的 job 或缺数据都不命中，走原有红路径。
# 不改聚合 job 去跳过必需检查：GitHub 把跳过的必需检查记为通过，会放过没跑的 suites。
ci_cancelled_upstream() { # checks_json
  jqf -e '([.[] | select(.bucket == "fail") | .name] == ["Pipeline suites"])
    and any(.[]; (.name == "Select pipeline-suite scope" or (.name | startswith("Pipeline suites "))) and .bucket == "cancel")' <<<"$1" >/dev/null
}

ci_cancelled() { # id pr head names [upstream]：只重启被取消的 job，不动批准与重跑额度；同一 head 第 CI_CANCEL_RERUNS 次后交 supervisor；upstream=1 时 run 结论是聚合 job 的 failure
  local r n=0 k up="${5:-}" decision
  k=0; [[ "$(unit_field "$1" .ci_cancel_head)" == "$3" ]] && k="$(unit_field "$1" .ci_cancel_reruns)"
  [[ "$k" =~ ^[0-9]+$ ]] || k=0
  if (( k >= CI_CANCEL_RERUNS )); then
    decision="$(decision_entry 'Stop CI retries and escalate repeated cancellation to supervisor' 'CI checks remained cancelled after the retry budget' "head $3 after $k restarts: $4" '["Treat cancellation as a code failure and dispatch repair"]' scheduler)"
    set_unit "$1" "$(hist supervisor-review "checks keep getting cancelled on head $3 after $k restarts: $4" "$decision") | .stage=\"supervisor-review\""
    say "merge skipped PR#$2 (checks cancelled again after $k restarts: $4) -> supervisor-review"
    return 0
  fi
  local sel='.conclusion=="cancelled"'; [[ -n "$up" ]] && sel='.conclusion=="cancelled" or .conclusion=="failure"'
  for r in $(gh run list --commit "$3" --json databaseId,conclusion --jq ".[] | select($sel) | .databaseId" 2>/dev/null); do
    gh run rerun "$r" --failed >/dev/null 2>&1 && n=$((n+1))
  done
  set_unit "$1" "$(hist ci-cancelled-restart "$4") | .ci_cancel_head=$(js "$3") | .ci_cancel_reruns=$((k+1))"
  say "merge skipped PR#$2 (checks cancelled, not failed: $4) -> restarted $n run(s), approval and rerun credit kept"
}

# 停线（Jidoka）：失败 job 的日志里已有测试断言失败（vitest FAIL / AssertionError / TAP not ok），就是确定性的代码结论。
# 以前要等其余检查全部跑完、再整体重跑一次才派修复：热修 #3860 04:15 测试已红，按旧路径约 2 小时后才会开始修（L62）。
ci_test_red_checks() { # checks_json → 第一行：失败日志含测试失败的检查名（逗号分隔，没有则空）；其后每行是该检查日志里 vitest 标记行的结构化事实
  local name link job hits="" log facts=""
  log="$(mktemp)"
  while IFS=$'\t' read -r name link; do
    job="${link##*/job/}"; [[ "$job" =~ ^[0-9]+$ ]] || continue
    # Dagger 里的 vitest 输出带 ANSI 颜色（ESC[41m FAIL ESC[49m），不去色就匹配不到：热修 #3860 的确定性测试红
    # 三次被当成"旧 base 的红"走 update-branch，每次多耗一整轮 CI（L75）。
    # 一次日志抓取同时给出红判定和 scripts/ci/vitest-fail-facts.mjs 打印的标记行；没有标记行的检查不解析、保持通用提示。
    gh api --allow-escape-sequences "repos/{owner}/{repo}/actions/jobs/$job/logs" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$log"
    grep -qaE ' FAIL  .* > |AssertionError|not ok [0-9]+ -' "$log" || continue
    hits="${hits:+$hits, }$name"
    facts="${facts}$(grep -a -m1 -oE 'ZENOFORGE-FAIL-FACTS \{.*' "$log" | sed 's/^ZENOFORGE-FAIL-FACTS //')"$'\n'
    # run-ci-suites.sh 已为每个失败的 engine 套件打印 "[pipeline suites] FAILED suite=<path>"；同一次抓取里取出，供分诊用
    facts="${facts}$(grep -a -oE '^\[pipeline suites\] FAILED suite=[^ ]+' "$log" | sed 's/.*suite=//' | jq -Rsc 'split("\n") | map(select(. != "")) | select(length > 0) | {pipelineSuites: .}' 2>/dev/null)"$'\n'
  done < <(jqf -r '.[] | select(.bucket == "fail") | [.name, (.link // "")] | @tsv' <<<"$1")
  rm -f "$log"
  printf '%s\n' "$hits"
  printf '%s' "$facts" | grep -a '^{' || true
}

# 分诊（只出结论，不路由、不写台账）：stale-base / attributable / unknown。失败套件取自 ci_test_red_checks 的事实，
# 改动面取自 GitHub compare 的不可变 SHA 对（PR 自己相对合并基点的改动 + main 自合并基点以来的改动），映射只用
# engine/failure-triage.mjs 里复用的 pipeline-suites-scope.mjs；结果按 SHA 对落盘，同一对不再请求。
ci_compare_cached() { # base head file：SHA 对不可变，已落盘就不再请求
  [[ -s "$3" ]] && return 0
  if gh api "repos/{owner}/{repo}/compare/$1...$2" > "$3.tmp" 2>/dev/null; then mv "$3.tmp" "$3"; else rm -f "$3.tmp"; return 1; fi
}
ci_triage() { # head facts → verdict
  local suites cmp mb prf mainf behind complete=false cache="$A/triage-cache" k
  suites="$(jq -sc '[.[] | ((.pipelineSuites // [])[], ((.suites // [])[] | .file))] | unique' <<<"$2" 2>/dev/null)" || { echo unknown; return 0; }
  [[ -n "$suites" && "$suites" != "[]" && -n "$MAIN_HEAD" ]] || { echo unknown; return 0; }
  mkdir -p "$cache"
  k="$cache/$MAIN_HEAD...$1.json"
  ci_compare_cached "$MAIN_HEAD" "$1" "$k" || { echo unknown; return 0; }
  mb="$(jqf -r '.merge_base_commit.sha // empty' "$k")"; behind="$(jqf -r '.behind_by // 0' "$k")"
  [[ "$mb" =~ $SHA_RE ]] || { echo unknown; return 0; }
  prf="$(jqf -c '[.files[]?.filename]' "$k")"
  k="$cache/$mb...$MAIN_HEAD.json"
  ci_compare_cached "$mb" "$MAIN_HEAD" "$k" || { echo unknown; return 0; }
  mainf="$(jqf -c '[.files[]?.filename]' "$k")"
  # compare 最多返回 300 个文件；达到上限就不完整，按 unknown 处理
  jq -e -n --argjson a "$prf" --argjson b "$mainf" '($a | length) < 300 and ($b | length) < 300' >/dev/null 2>&1 && complete=true
  jq -nc --argjson s "$suites" --argjson a "$prf" --argjson b "$mainf" --argjson n "${behind:-0}" --argjson c "$complete" \
    '{suites: $s, prFiles: $a, mainFiles: $b, behind: $n, complete: $c}' \
    | node "$ROOT/engine/failure-triage.mjs" 2>/dev/null || echo unknown
}

# 早期 stale-base 路由：开关开、判定 stale-base、非热修/非关键单元、同一 unit 同一套件还没走过这一跳时，
# 用一次服务端 update-branch 代替 LLM 修复；批准沿用仍只走 approval_carries。第二次同套件 stale-base 落到修复。
# hop 记在台账行 .stale_hops（套件路径列表）。返回 0 = 已更新分支，调用方不再派修复。
ci_stale_base_hop() { # id pr head facts
  [[ "$STALE_BASE_ROUTING" == true ]] || return 1
  [[ "$(unit_field "$1" '.hotpatch // false')" != true && "$(unit_field "$1" '.critical // false')" != true ]] || return 1
  [[ "$(ci_triage "$3" "$4")" == stale-base ]] || return 1
  local suites; suites="$(jq -sc '[.[] | ((.pipelineSuites // [])[])] | unique' <<<"$4" 2>/dev/null)"
  [[ -n "$suites" && "$suites" != "[]" ]] || return 1
  jq -e --argjson s "$suites" --arg id "$1" '[.units[] | select(.id == $id) | (.stale_hops // [])[]] as $h | all($s[]; . as $x | $h | index($x) | not)' "$UNITS" >/dev/null 2>&1 || return 1
  [[ "$(pr_view "$2" mergeable)" == MERGEABLE ]] || return 1
  ci_update_branch "$2" "$3" || return 1
  set_unit "$1" "$(hist ci-stale-base-update "suites $suites") | .stale_hops = ((.stale_hops // []) + $suites | unique) | .ci_rerun_sha=$(js "$3")"
  say "merge skipped PR#$2 (stale-base failure in $suites) -> update-branch at $3, no repair"
}

# 失败套件与断言事实 → 修复提示片段。facts 是标记行 JSON（每行一个）；PR 改动面只用本地 git（head 对象不在就不说），
# 不推导 import 闭包：只比对 diff 是否触及失败文件或其所在包目录。
ci_fact_hint() { # head facts
  [[ -n "$2" ]] || return 0
  local changed="" txt
  git -C "$ROOT" cat-file -e "$1^{commit}" 2>/dev/null && changed="$(git -C "$ROOT" diff --name-only "origin/main...$1" 2>/dev/null)"
  txt="$(jq -r --arg changed "$changed" --argjson known "$([[ -n "$changed" ]] && echo true || echo false)" '
    (.suites // [])[] | . as $s
    | ($s.file | split("/") | if (.[0] == "packages" or .[0] == "apps") and length > 2 then .[0:2] | join("/") else (.[0:-1] | join("/")) end) as $pkg
    | (if $known then (if ($changed | split("\n") | any(. == $s.file or startswith($pkg + "/"))) then "本 PR diff 触及该套件或其所在目录" else "本 PR diff 未触及该套件所在目录" end) else "" end) as $rel
    | "\($s.file)" + (if $rel != "" then "（\($rel)）" else "" end) + ": "
      + ([$s.tests[] | "\(.name)" + (if .line then " @\(.line)" else "" end) + (if .msg != "" then " — \(.msg)" else "" end)] | join("; "))
      + (if $s.more > 0 then "; 另 \($s.more) 项" else "" end)' <<<"$2" 2>/dev/null | head -c 1500)"
  [[ -n "$txt" ]] && printf ' 失败套件与断言（来自 Vitest 结构化报告）：%s。' "$(paste -sd'|' <<<"$txt")"
  return 0
}

# 12 个 runner 被 PR CI 占满时 main 验证 run 要排队 50 分钟（2026-10-20）。马上会被新 head 取代的 PR run
# （修复已派出）和快车道根本不用的 PR run 先取消，把 runner 让给 main 验证和就绪 PR。
cancel_branch_runs() { # branch reason：reason 里第一个 ';' 之前的部分是写进审计日志的稳定原因
  local r n=0
  [[ -n "$1" ]] || return 0
  for r in $(gh run list --branch "$1" --limit 20 --json databaseId,status,event --jq '.[] | select(.status != "completed" and .event == "pull_request") | .databaseId' 2>/dev/null); do
    ZF_CANCEL_REASON="${2%%;*}" bash "$ROOT/engine/night/main-ci-recovery.sh" cancel-run "$r" >/dev/null 2>&1 && n=$((n+1))
  done
  (( n > 0 )) && say "cancelled $n PR run(s) on $1 ($2)"
  return 0
}

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
ensure_pipeline_ci_label() { # 首次使用前建一次标签；已存在时 GitHub 回 422，忽略
  (( PIPELINE_CI_LABEL_READY )) && return 0
  gh api "repos/{owner}/{repo}/labels" -f name="$PIPELINE_CI_LABEL" -f color=0e8a16 \
    -f description="Pipeline-owned PR: the heavy PR gates run for this branch" >/dev/null 2>&1 || true
  PIPELINE_CI_LABEL_READY=1
}
declare -gA GATED_OF=() GATED_SLOT=() READIED_PRS=()
GATED_CENSUS_LOADED=false
GATED_LABEL_READY=0
ensure_gated_label() { # 首次使用前建一次标签；已存在时 GitHub 回 422，忽略
  (( GATED_LABEL_READY )) && return 0
  gh api "repos/{owner}/{repo}/labels" -f name="$GATED_LABEL" -f color=5319e7 \
    -f description="CI starts only when the scheduler marks the PR ready" >/dev/null 2>&1 || true
  GATED_LABEL_READY=1
}
gated_status() { # sha state context description：按 head 绑定的共享状态
  gh api "repos/{owner}/{repo}/statuses/$1" -f state="$2" -f context="$3" -f description="$4" >/dev/null 2>&1
}
approved_status_on() { # head → 该 head 上有 agent/ci-approved success
  gh api "repos/{owner}/{repo}/commits/$1/status" \
    --jq '[.statuses[]? | select(.context == "agent/ci-approved" and .state == "success")] | length' 2>/dev/null | grep -qx '[1-9][0-9]*'
}
post_approved_status() { # unit sha：PR 车道的批准写成共享状态，其他主机和合并车道的消息读它
  [[ "$2" =~ $SHA_RE ]] || return 0
  [[ -n "$(unit_field "$1" '.pr // empty')" && "$(unit_field "$1" '.lane // empty')" != direct-main ]] || return 0
  gated_status "$2" success agent/ci-approved "approved by the reviewer" || say "unit=$1 could not write agent/ci-approved on ${2:0:9}"
  return 0
}
merge_ref_converts() { # pr → PR 合并引用里的 workflow 已含 converted_to_draft（服务端并发组会取消在跑的 run）
  gh api -X GET "repos/{owner}/{repo}/contents/.github/workflows/pipeline-suites.yml" -f ref="refs/pull/$1/merge" --jq .content 2>/dev/null \
    | base64 -d 2>/dev/null | grep -q converted_to_draft
}
gated_demote_pr() { # pr branch reason：退回 draft；只有合并引用还没有 converted_to_draft 时才补一次带审计的取消
  gh pr ready "$1" --undo >/dev/null 2>&1 || return 1
  tick_prs_set_draft "$1" true
  if [[ -n "${GATED_OF[$2]:-}" ]]; then
    local gated_pr gated_draft gated_head
    read -r gated_pr gated_draft gated_head <<<"${GATED_OF[$2]}"
    GATED_OF["$2"]="$gated_pr true $gated_head"
  fi
  merge_ref_converts "$1" || cancel_branch_runs "$2" "$3"
  return 0
}
gated_flag_pr() { # pr → 给 PR 加门控标签
  ensure_gated_label
  gh pr edit "$1" --add-label "$GATED_LABEL" >/dev/null 2>&1 || return 1
  tick_prs_add_label "$1" "$GATED_LABEL"
}
repair_demote() { # unit pr branch：repair 派出成功后，门控 PR 和符合条件的旧 agent PR 退回 draft，其余保持原来的审计取消
  local reason="repair dispatched; head will change"
  if [[ "$3" =~ $GATED_BRANCH_RE && "$(unit_field "$1" '.hotpatch // false')" != true && "$(unit_field "$1" '.lane // empty')" != direct-main ]] \
    && gated_flag_pr "$2"; then
    set_unit "$1" '.gated=true'
    gated_demote_pr "$2" "$3" "$reason" && return 0
  fi
  cancel_branch_runs "$3" "$reason"
}
scheduler_pr_open() { # branch title body [base] → SCHED_PR_NUM / SCHED_PR_OUT；agent/issue-* 以 draft + 门控标签创建，已有 open 的非 draft PR 就退回 draft 并加标签
  local row pr draft gate=0 title body base="${4:-main}"
  SCHED_PR_NUM=""; SCHED_PR_OUT=""
  [[ "$1" =~ $GATED_BRANCH_RE ]] && gate=1
  row="$(gh pr list --head "$1" --state open --json number,isDraft --jq '.[0] | select(. != null) | "\(.number) \(.isDraft)"' 2>/dev/null)"
  read -r pr draft <<<"$row"
  if [[ "$pr" =~ ^[0-9]+$ ]]; then
    if [[ "$base" != main ]] && ! SCHED_PR_OUT="$(gh pr edit "$pr" --base "$base" 2>&1)"; then
      SCHED_PR_NUM=""; return 0
    fi
    if (( gate )) && [[ "$draft" == false ]] && gated_flag_pr "$pr"; then gated_demote_pr "$pr" "$1" "ci deferred; PR adopted as draft" || true; fi
    SCHED_PR_NUM="$pr"; return 0
  fi
  title="$(scrub_closing_keywords <<<"$2")"
  body="$(scrub_closing_keywords <<<"$3")"
  tick_prs_changed
  if (( gate )); then
    ensure_gated_label
    SCHED_PR_OUT="$(gh pr create --draft --label "$GATED_LABEL" --base "$base" --head "$1" --title "$title" --body "$body" 2>&1)"
  else
    SCHED_PR_OUT="$(gh pr create --base "$base" --head "$1" --title "$title" --body "$body" 2>&1)"
  fi
  SCHED_PR_NUM="$(grep -oE '/pull/[0-9]+' <<<"$SCHED_PR_OUT" | grep -oE '[0-9]+$' | tail -1)"
}
gated_load() { # 一次 open PR 列表读出带门控标签的 PR；读失败或格式错就保持为空，本拍不翻任何 PR
  local listing br pr draft head
  GATED_OF=(); GATED_CENSUS_LOADED=false
  listing="$(tick_prs)" || return 1
  jqf -e 'type == "array"' <<<"$listing" >/dev/null || return 1
  while IFS=$'\t' read -r br pr draft head; do
    [[ -n "$br" && "$pr" =~ ^[0-9]+$ && "$head" =~ $SHA_RE ]] && GATED_OF["$br"]="$pr $draft $head"
  done < <(jqf -r --arg l "$GATED_LABEL" '.[] | select(any(.labels[]?; .name == $l)) | [.headRefName, .number, .isDraft, .headRefOid] | @tsv' <<<"$listing")
  GATED_CENSUS_LOADED=true
  return 0
}
gated_ready() { # id branch approved_head：批准的 head 占到名额（或属于豁免类）才 ready；head 对不上不翻，已 ready 的退回 draft
  local pr draft ghead ready_sha ready_at
  read -r pr draft ghead <<<"${GATED_OF[$2]:-}"
  [[ -n "$pr" ]] || return 0
  GATED_SLOT["$2"]=1
  if [[ "$draft" == false ]] && jqf -e --arg branch "$2" 'index($branch) != null' <<<"${CI_HOTFIX_BRANCHES:-[]}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$ghead" != "$3" ]]; then
    [[ "$draft" == false ]] && gated_demote_pr "$pr" "$2" "ci deferred; approval no longer on the live head" \
      && say "gated unit=$1 PR#$pr demoted: approved ${3:0:9} is not the live head ${ghead:0:9}"
    return 0
  fi
  if [[ "$draft" == false ]]; then
    ready_sha="$(unit_field "$1" '.ci_ready_sha // empty')"
    ready_at="$(unit_field "$1" '.ci_ready_at // empty')"
    [[ "$ready_sha" == "$3" && -n "$ready_at" ]] && return 0
    gated_demote_pr "$pr" "$2" "ci deferred; refreshing ready-event evidence" || return 0
    draft=true
  fi
  approved_status_on "$3" || gated_status "$3" success agent/ci-approved "approved by the reviewer" || return 0
  ready_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh pr ready "$pr" >/dev/null 2>&1 || return 0
  tick_prs_set_draft "$pr" false
  GATED_OF["$2"]="$pr false $ghead"
  READIED_PRS["$pr"]=1
  [[ "$(unit_field "$1" '.ci_wip_wait // empty')" == "$3" ]] && gated_status "$3" success agent/ci-waiting "CI slot granted"
  set_unit "$1" "$(hist ci-ready "PR#$pr readied on ${3:0:9}") | .ci_ready_sha=$(js "$3") | .ci_ready_at=$(js "$ready_at") | del(.ci_wip_wait) | del(.ci_cancel_reruns)"
  say "gated unit=$1 PR#$pr readied on ${3:0:9}"
}
gated_wait() { # id branch approved_head：没占到名额的门控 PR 留在 draft 并挂共享 waiting 状态；已 ready 的被挤出名额就退回 draft
  local pr draft ghead
  read -r pr draft ghead <<<"${GATED_OF[$2]:-}"
  [[ -n "$pr" && "$ghead" == "$3" ]] || return 0
  [[ "$(unit_field "$1" '.ci_wip_wait // empty')" == "$3" ]] || gated_status "$3" pending agent/ci-waiting "waiting for a CI slot"
  if [[ "$draft" == false ]] && gated_demote_pr "$pr" "$2" "ci wip; displaced from its CI slot"; then
    say "gated unit=$1 PR#$pr demoted: lost its CI slot"
  fi
  return 0
}
gated_ready_exempt() { # 热修（含关联 issue 分类）与非产品 PR 不占产品 CI 名额；其余批准 PR 进入统一排序
  local id br head
  while IFS=$'\t' read -r id br head; do
    [[ -n "$id" ]] || continue
    gated_ready "$id" "$br" "$head"
  done < <(jqf -r --argjson hotfix "${CI_HOTFIX_BRANCHES:-[]}" '.units[] | select(.stage == "ready-to-merge" and (.hold_handoff_waiting // false) == false and (.pr // null) != null and (.lane // "") != "direct-main"
      and ((.hotpatch // false) == true or .product_paths == false or ((.branch // "") as $br | $hotfix | index($br) != null))
      and (.branch // "") != "" and (.approved_sha // "") != "") | [.id, .branch, .approved_sha] | @tsv' "$UNITS")
}
ci_ready_hotfix_gated() { # 先触发门控热修的 ready 事件，让它先进入 runner 队列
  local id br head
  GATED_OF=(); GATED_SLOT=()
  gated_load || return 0
  while IFS=$'\t' read -r id br head; do
    [[ -n "$id" ]] || continue
    gated_ready "$id" "$br" "$head"
  done < <(jqf -r --argjson hotfix "${CI_HOTFIX_BRANCHES:-[]}" '.units[] | select(.stage == "ready-to-merge" and (.hold_handoff_waiting // false) == false and (.pr // null) != null
      and (.lane // "") != "direct-main" and ((.branch // "") as $br | $hotfix | index($br) != null)
      and (.branch // "") != "" and (.approved_sha // "") != "") | [.id, .branch, .approved_sha] | @tsv' "$UNITS")
}
gated_demote_unapproved() { # 门控 PR 已 ready 但单元不在 ready-to-merge/合并中（评审、返工、阻塞）：批准已失效，退回 draft
  local id br stage pr draft ghead
  while IFS=$'\t' read -r id br stage; do
    [[ -n "$id" && -n "${GATED_OF[$br]:-}" && -z "${GATED_SLOT[$br]:-}" ]] || continue
    read -r pr draft ghead <<<"${GATED_OF[$br]}"
    [[ "$draft" == false ]] || continue
    if gated_demote_pr "$pr" "$br" "ci deferred; head is in $stage without an approval"; then
      say "gated unit=$id PR#$pr demoted: approval gone ($stage)"
    fi
  done < <(jqf -r --argjson hotfix "${CI_HOTFIX_BRANCHES:-[]}" '.units[] | select((.hold_handoff_waiting // false) == false and (.pr // null) != null and (.hotpatch // false) != true
      and ((.branch // "") as $br | $hotfix | index($br) == null) and (.branch // "") != ""
      and (.stage | IN("review-pending", "review", "rereview-pending", "rereview", "repair-pending", "repair", "blocked-external"))) | [.id, .branch, .stage] | @tsv' "$UNITS")
}

# 一拍一次的 open PR census：number、head、draft、分支、标题、标签、正文与检查汇总。合并车道、门控、孤儿 PR、新 PR 登记读同一份；
# 读失败或格式错就是"不可用"（返回 1），调用方本拍不据此决策。自己改了 PR（ready/draft/标签/创建/关闭/合并）后清空，下次用到再读。
TICK_PRS=""
declare -gA TICK_PR_STATE=()
tick_prs() {
  [[ -n "$TICK_PRS" ]] || TICK_PRS="$(gh pr list --state open --limit 300 --json number,headRefOid,headRefName,isDraft,title,labels,body,statusCheckRollup 2>/dev/null)" || { TICK_PRS=""; return 1; }
  jqf -e 'type == "array"' <<<"$TICK_PRS" >/dev/null || { TICK_PRS=""; return 1; }
  printf '%s' "$TICK_PRS"
}
tick_prs_changed() { TICK_PRS=""; }
tick_prs_set_draft() { # PR ready/draft writes do not change its census identity or checks
  [[ -n "$TICK_PRS" ]] || return 0
  local updated
  updated="$(jqf --argjson pr "$1" --argjson draft "$2" 'map(if .number==$pr then .isDraft=$draft else . end)' <<<"$TICK_PRS")" || { TICK_PRS=""; return 0; }
  TICK_PRS="$updated"
}
tick_prs_add_label() { # mirror a successful label write in the current tick's PR census
  [[ -n "$TICK_PRS" ]] || return 0
  local updated
  updated="$(jqf --argjson pr "$1" --arg label "$2" 'map(if .number==$pr then .labels=((.labels // []) + [{name:$label}] | unique_by(.name)) else . end)' <<<"$TICK_PRS")" || { TICK_PRS=""; return 0; }
  TICK_PRS="$updated"
}
ci_hotfix_branches() { # → 当前 open PR 中由 #4615 分类器识别的热修分支
  local prs label prefixes hot
  prs="$(tick_prs)" || return 1
  label="$(hotfix_lane_label)"
  prefixes="$(hotfix_lane_branch_prefixes | jqf -Rsc 'split("\n") | map(select(length > 0))')"
  hot='[]'
  hotfix_issue_numbers >/dev/null && hot="$TICK_HOTFIX_ISSUES"
  jqf -c --arg label "$label" --argjson prefixes "$prefixes" --argjson hot "$hot" '
    [.[] as $pr
      | ([($pr.headRefName // "") | match("^agent/issue-(hf-)?([0-9]+)(-|$)").captures[1].string | tonumber]
          + [($pr.body // "") | match("(?im)^[[:space:]]*[-*]?[[:space:]]*refs[[:space:]:]+#([0-9]+)"; "g").captures[0].string | tonumber]
          | unique) as $linked
      | select(($pr.headRefName // "") != "" and (any($pr.labels[]?; .name == $label)
          or any($prefixes[]; . as $prefix | ($pr.headRefName // "") | startswith($prefix))
          or any($linked[]; . as $n | $hot | index($n) != null)))
      | $pr.headRefName] | unique
  ' <<<"$prs"
}

# 一拍一次的 hotfix issue census（#4615）：PR 漏打 hotfix 标签时，从关联 issue 继承热修身份。
# register_new_issues 预读配置指定的热修 issue 列表；PR 判定复用这份结果，不为每个 PR 单独查 API。
TICK_HOTFIX_ISSUES='[]'
TICK_HOTFIX_ISSUES_LOADED=false
hotfix_lane_label() { jqf -r '.hotfix_lane.label // "hotfix"' <<<"$CFG"; }
hotfix_lane_branch_prefixes() { jqf -r '.hotfix_lane.branch_prefixes[]? // empty' <<<"$CFG"; }
hotfix_issue_numbers() {
  local label rows
  if [[ "$TICK_HOTFIX_ISSUES_LOADED" != true ]]; then
    TICK_HOTFIX_ISSUES_LOADED=true
    label="$(hotfix_lane_label)"
    rows="$(gh issue list --state open --label "$label" --limit 200 --json number,labels 2>/dev/null)" || return 1
    if ! TICK_HOTFIX_ISSUES="$(jqf -c --arg label "$label" '
      if type != "array" then error("invalid issue census")
      else [.[] | select(any(.labels[]?; .name == $label)) | .number] end
    ' <<<"$rows")"; then TICK_HOTFIX_ISSUES='[]'; return 1; fi
  fi
  jqf -e 'type == "array"' <<<"${TICK_HOTFIX_ISSUES:-[]}" >/dev/null || return 1
  printf '%s' "$TICK_HOTFIX_ISSUES"
}

# PR 已在 GitHub 合并/关闭（如 10-27 手工批量落地），台账却还在工作环节：派活前先收掉。
# 10-28 #4039/#4040 已合并，仍各被派了两轮 repair 与两次裁决。只查不在本拍 open 列表里的单元，每拍有上限。
retire_landed_pr_units() {
  local prs open id pr state n=0
  prs="$(tick_prs)" || return 0
  open="$(jqf -c '[.[].number]' <<<"$prs")"
  while IFS=$'\t' read -r id pr; do
    [[ -n "$id" ]] || continue
    (( n < ${RETIRE_PR_CHECK_MAX:-10} )) || break
    n=$((n + 1))
    state="$(pr_view "$pr" state)"
    [[ -n "$state" ]] && TICK_PR_STATE["$pr"]="$state"
    [[ "$state" == MERGED || "$state" == CLOSED ]] || continue
    [[ "$state" == MERGED ]] && state=merged || state=closed
    set_unit "$id" "$(hist pr-"$state" "PR $state outside the pipeline") | .stage=\"$state\""
    say "unit=$id PR#$pr already $state on GitHub; retired before dispatch"
  done < <(jqf -r --argjson open "$open" '.units[]
    | select((.pr | type) == "number" and (.stage | test("^(closed|landed|merged|done|parked|needs-human)$") | not)
      and (.hold_handoff_waiting // false) == false
      and (.pr as $p | $open | index($p)) == null)
    | [.id, (.pr | tostring)] | @tsv' "$UNITS")
}

# CI 只花在会合并的 head 上（约束理论：瓶颈不做无用功）。CI 是交付瓶颈（10-21 一天批准 110、合并 17），而评审
# 打回率约 43%：repair 一推就跑整套 PR CI，同时评审在审——10-20 07:00 起 39% 的 PR CI 时长花在从未获批的 head 上。
# 评审中的非热修单元，PR run 里没有 job 在跑的就取消（零浪费），记 .ci_deferred_sha；获批进合并车道后由 ci_red 起跑，
# 这次起跑不占"首红重跑一次"的额度。热修照常并行跑，交付时延优先。
ci_cancel_run_once() { # run-id reason：一个 tick 中同一个 run 只接受准入控制器选中的一次取消
  local run="$1"
  [[ -z "${CI_ADMISSION_CANCELLED[$run]:-}" ]] || return 1
  ZF_CANCEL_REASON="$2" bash "$ROOT/engine/night/main-ci-recovery.sh" cancel-run "$run" >/dev/null 2>&1 || return 1
  CI_ADMISSION_CANCELLED["$run"]=1
}

ci_defer_unapproved() {
  # 一次批量取未结束的 PR run 再按分支对上单元：逐分支 gh run list 让这一步占了一拍 44–97 秒（10-21 09:10）。
  local id br sha r st jobs n=0
  local -a jobs_to_load=()
  local -A unit_of=()
  while IFS=$'\t' read -r id br; do [[ -n "$br" ]] && unit_of["$br"]="$id"; done \
    < <(jqf -r --argjson hot "${CI_HOTFIX_BRANCHES:-[]}" '.units[] | select((.hold_handoff_waiting // false) == false and (.hotpatch // false) != true
      and ((.branch // "") as $br | $hot | index($br) == null)
      and (.stage | IN("review","review-pending","rereview","rereview-pending")) and (.branch // "") != "") | [.id, .branch] | @tsv' "$UNITS")
  (( ${#unit_of[@]} > 0 )) || return 0
  while IFS=$'\t' read -r r sha st br; do
    [[ "$st" != queued && -n "${unit_of[$br]:-}" ]] && jobs_to_load+=("$r")
  done < <(unfinished_runs | jqf -r '.[] | select(.event == "pull_request") | [.databaseId, .headSha, .status, .headBranch] | @tsv' 2>/dev/null)
  ci_jobs_prefetch "${jobs_to_load[@]}" || :
  while IFS=$'\t' read -r r sha st br; do
    [[ -n "$r" && -n "${unit_of[$br]:-}" ]] || continue
    if [[ "$st" != queued ]]; then
      jobs="$(ci_jobs_status "$r")" || continue
      jqf -e 'all(.[]; . != "in_progress")' <<<"$jobs" >/dev/null 2>&1 || continue
    fi
    ci_cancel_run_once "$r" "ci deferred" || continue
    n=$((n+1)); set_unit "${unit_of[$br]}" ".ci_deferred_sha=$(js "$sha")"
  done < <(unfinished_runs | jqf -r '.[] | select(.event == "pull_request") | [.databaseId, .headSha, .status, .headBranch] | @tsv' 2>/dev/null)
  (( n > 0 )) && say "ci deferred: cancelled $n PR run(s) on heads still in review (CI starts on approval)"
  return 0
}

# 未完成的 run 要按状态取：gh run list 只回最近创建的 300 个，而重跑保留原创建时间——10:43 创建、第 3 次重跑
# 排队的 run 不在窗口里，准入看不见它，它照样排在热修前面（L71）。
# 优先挡板（热修排队时取消普通 PR run）已退役（#4625）：它取消的只是排队 job，换不来 runner；
# 放行重跑又把自己取消的 run 排回热修前面，10-29 一个热修日触发 18 轮、47 个不同 run 被记 "ci hold"。
# 热修优先级由统一准入承担：ready 先行（ci_ready_hotfix_gated）、三类取消都豁免热修、WIP 名额只放行有空闲 runner 的量。
TICK_UNFINISHED=""
TICK_UNFINISHED_LOADED=false
TICK_UNFINISHED_IN_PROGRESS_OK=false
TICK_UNFINISHED_ALL_OK=false
unfinished_runs() { # → 状态为 queued/in_progress/pending/waiting 的 run（与 gh run list 同字段）；一拍只取一次
  local st tmpdir pid
  local -a pids=()
  [[ "$TICK_UNFINISHED_LOADED" == true ]] && { printf '%s' "$TICK_UNFINISHED"; return 0; }
  tmpdir="$(mktemp -d)" || return 1
  for st in queued in_progress pending waiting; do
    { if gh api --paginate "repos/{owner}/{repo}/actions/runs?status=$st&per_page=100" \
        --jq '.workflow_runs[] | {databaseId: .id, status: .status, event: .event, headBranch: .head_branch, headSha: .head_sha, workflowName: .name, createdAt: .created_at}' >"$tmpdir/$st" 2>/dev/null; then
        touch "$tmpdir/$st.ok"
      fi; } &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || :; done
  TICK_UNFINISHED="$(cat "$tmpdir"/* | jqf -s 'unique_by(.databaseId)')"
  [[ -e "$tmpdir/in_progress.ok" ]] && TICK_UNFINISHED_IN_PROGRESS_OK=true
  if [[ -e "$tmpdir/queued.ok" && -e "$tmpdir/pending.ok" && -e "$tmpdir/waiting.ok" && -e "$tmpdir/in_progress.ok" ]]; then
    TICK_UNFINISHED_ALL_OK=true
  fi
  rm -rf -- "$tmpdir"
  TICK_UNFINISHED_LOADED=true
  printf '%s' "$TICK_UNFINISHED"
}
declare -A CI_RUN_JOBS_CACHE=()
ci_jobs_batch_wait() { # called by ci_jobs_prefetch; local arrays share Bash's dynamic scope
  local i id
  for i in "${!job_pids[@]}"; do
    wait "${job_pids[$i]}" || :
    id="${job_ids[$i]}"
    [[ -s "$job_dir/$id" ]] && CI_RUN_JOBS_CACHE["$id"]="$(cat "$job_dir/$id")"
  done
  job_pids=(); job_ids=()
}
ci_jobs_prefetch() { # parallelize and share full per-run job snapshots within this tick
  local id job_dir
  local -a job_ids=() job_pids=()
  (( $# > 0 )) || return 0
  job_dir="$(mktemp -d)" || return 1
  for id in "$@"; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    [[ -n "${CI_RUN_JOBS_CACHE[$id]+cached}" ]] && continue
    { gh api "repos/{owner}/{repo}/actions/runs/$id/jobs?per_page=100" --jq '[.jobs[] | {status, runner_id}]' >"$job_dir/$id" 2>/dev/null || :; } &
    job_ids+=("$id"); job_pids+=("$!")
    (( ${#job_pids[@]} < 8 )) || ci_jobs_batch_wait
  done
  (( ${#job_pids[@]} == 0 )) || ci_jobs_batch_wait
  rm -rf -- "$job_dir"
}
ci_jobs_data() { # run id → one tick's full job snapshot, or a fresh read if it was not prefetched
  local jobs
  if [[ -n "${CI_RUN_JOBS_CACHE[$1]+cached}" ]]; then
    printf '%s' "${CI_RUN_JOBS_CACHE[$1]}"
    return 0
  fi
  jobs="$(gh api "repos/{owner}/{repo}/actions/runs/$1/jobs?per_page=100" --jq '[.jobs[] | {status, runner_id}]' 2>/dev/null)" || return 1
  CI_RUN_JOBS_CACHE["$1"]="$jobs"
  printf '%s' "$jobs"
}
ci_jobs_status() { ci_jobs_data "$1" | jqf '[.[] | .status]'; }
ci_jobs_active_runner_ids() { ci_jobs_data "$1" | jqf -r '.[] | select(.status == "in_progress") | .runner_id // empty'; }
ci_pr_free_slots() { # → online PR-capable runners minus runners with a job already assigned
  local runner_busy runner_busy_json runner_count active
  runner_busy="$(gh api --paginate "repos/{owner}/{repo}/actions/runners?per_page=100" \
    --jq '.runners[] | select(.status == "online" and any(.labels[]; .name | IN("cihost-ci","cihost-ci-light","cihost-ci-priority","zf-suites"))) | .busy' 2>/dev/null)" || return 1
  runner_busy_json="$(jqf -s '.' <<<"$runner_busy")" || return 1
  runner_count="$(jqf -r 'length' <<<"$runner_busy_json")"
  active="$(jqf '[.[] | select(. == true)] | length' <<<"$runner_busy_json")"
  if (( runner_count > active )); then
    printf '%s\n' "$((runner_count - active))"
  else
    printf '0\n'
  fi
}

# CI 在制品上限（看板 WIP / Little 定律，L77）：98 个就绪 PR × 约 6 个 workflow = 130 个 run 排在约 8 个 PR runner 前，
# GitHub 按先来先服务交错跑，每个 PR 都要等整个队列跑空才全绿；hold 每次放行又把它们排回队尾。10-21 23:42 就绪 98 个、
# 全绿 0 个、5 小时合并 3 个。每拍放行槽位按在线 PR runner 减去这些 runner 上的 in-progress job 计算，按 main-red > opt（.ci_priority）> normal 排序。
# 已放行的单元不重复占用空闲槽；其余等待单元还没有 job 在跑的 run 取消、记 .ci_wip_wait，空出 runner 后按就绪顺序补上，只补被取消的 job。
# 非产品 PR（只改流水线/CI/文档）不排产品 CI 的队（maintainer 10-22：[...]
# ）：它们多是在给约束扩容（#4044 Mac runner），排队等于自己挡自己。
NONPRODUCT_PATHS_RE='^(scripts|lessons|docs|ops|[.]agents|[.]trellis|[.]github)/|^[^/]+[.]md$'
mark_product_paths() { # 就绪单元第一次见到时查一次 PR 文件，记 .product_paths（true/false）
  local id pr files query_dir pid product updates='{}'
  local -a ids=() pids=()
  query_dir="$(mktemp -d)" || return 0
  while IFS=$'\t' read -r id pr; do
    [[ -n "$id" && "$pr" =~ ^[0-9]+$ ]] || continue
    ids+=("$id")
    { gh pr view "$pr" --json files --jq '.files[].path' >"$query_dir/$id" 2>/dev/null || :; } &
    pids+=("$!")
    if (( ${#pids[@]} >= 8 )); then
      for pid in "${pids[@]}"; do wait "$pid" || :; done
      pids=()
    fi
  done < <(jqf -r '.units[] | select(.stage == "ready-to-merge" and (.pr // null) != null and .product_paths == null) | [.id, .pr] | @tsv' "$UNITS" | head -"${PRODUCT_PATHS_PER_TICK:-20}")
  for pid in "${pids[@]}"; do wait "$pid" || :; done
  for id in "${ids[@]}"; do
    files="$(cat "$query_dir/$id" 2>/dev/null)"
    [[ -n "$files" ]] || continue
    if grep -vqE "$NONPRODUCT_PATHS_RE" <<<"$files"; then product=true; else product=false; fi
    updates="$(jqf --arg id "$id" --argjson product "$product" '. + {($id):$product}' <<<"$updates")"
  done
  rm -rf -- "$query_dir"
  [[ "$updates" == '{}' ]] || units_update --argjson paths "$updates" \
    '.units |= map(.id as $id | if .stage == "ready-to-merge" and .product_paths == null and $paths[$id] != null then .product_paths=$paths[$id] else . end)'
}
# 本机预检（precheck.sh）：等名额的单元先在本机跑 PR 自己改动的测试，PASS/SKIP 才给 CI 名额，FAIL 直接返工。
# 10-22：批准后 CI 红 14/14 是 PR 自己改动的测试文件；12 小时 CI 判红 69 次、合并 12 次，每次红白等名额 + 45–60 分钟。
# 一次只跑一个（独立 clone wt-precheck，内存守卫在脚本里），已在跑 CI 的单元不受影响。
precheck_harvest() {
  local id pid head out first fails
  while IFS=$'\t' read -r id pid head; do
    alive "$pid" && continue
    out="$SUP/precheck-$id.out"; first="$(head -1 "$out" 2>/dev/null)"
    case "$first" in
      "PRECHECK: FAIL"*)
        fails="$(sed -n '2,12p' "$out" 2>/dev/null)"
        set_unit "$id" "$(hist precheck-red "${first#PRECHECK: }") | del(.precheck_pid) | del(.ci_wip_wait) | .approved_sha=null | .repair_hint=$(js "批准后本机预检（未占 CI 名额）：PR 自己改动的测试在本机失败。${fails} 完整输出 $out。本机用 PGTEST_URL 复现（RUN_INTEGRATION=1 npx vitest run <文件>），修根因并补回归测试后 push。") | .stage=\"repair-pending\""
        say "precheck red unit=$id head=${head:0:9} -> repair-pending without spending a CI slot" ;;
      *)
        set_unit "$id" "$(hist precheck "${first:-PRECHECK: SKIP no output}") | del(.precheck_pid) | .precheck_sha=$(js "$head")"
        say "precheck unit=$id head=${head:0:9}: ${first:-PRECHECK: SKIP no output}" ;;
    esac
  done < <(jqf -r '.units[] | select(.precheck_pid != null) | [.id, .precheck_pid, (.precheck_head // "")] | @tsv' "$UNITS")
}
precheck_launch() { # id pr head
  local dir pid
  dir="$(ensure_clone precheck)" || return 1
  (cd "$dir" && exec setsid bash "$HERE/precheck.sh" "$dir" "$2" "$3") > "$SUP/precheck-$1.out" 2>&1 < /dev/null &
  pid=$!
  set_unit "$1" ".precheck_pid=$pid | .precheck_head=$(js "$3")"
  say "precheck pid=$pid unit=$1 PR#$2 head=${3:0:9}"
}
# 占到名额之前先同步：落后 main 且 mergeable 干净的 head 走已有的 update-branch（批准随后由 approval_carries 沿用），
# 每个 head 只试一次；真冲突转 repair，不消耗 CI 运行，名额让给下一个就绪单元。mergeability 或 head 数据未知不做任何转移。
# 返回 0 = 单元已转移（调用方不占名额），1 = 照常占名额。
slot_sync() { # id head
  local pr state
  pr="$(unit_field "$1" .pr)"; [[ "$pr" =~ ^[0-9]+$ && "$2" =~ $SHA_RE ]] || return 1
  [[ "$(unit_field "$1" '.slot_sync_sha // empty')" != "$2" ]] || return 1
  pr_behind_main "$pr" "$2" || return 1
  state="$(pr_view "$pr" mergeable)"
  case "$state" in
    MERGEABLE)
      set_unit "$1" ".slot_sync_sha=$(js "$2")" || :
      ci_update_branch "$pr" "$2" || return 1
      set_unit "$1" "$(hist slot-sync "PR#$pr behind main; update-branch at $2 before the CI slot")"
      say "slot sync PR#$pr: behind main, update-branch requested before CI starts"
      return 0 ;;
    CONFLICTING)
      set_unit "$1" ".slot_sync_sha=$(js "$2")" || :
      merge_conflict_to_repair "$1" "$pr" "conflicts with main before its CI slot" "PR 与最新 main 冲突，占 CI 名额前发现。git merge --no-edit origin/main，按两边意图解决冲突，跑受影响测试，推送。" "$2"
      return 0 ;;
  esac
  return 1
}

ci_assign_wip() {
  local wip k=0 id br head r st jobs n=0 started=0 pre_id="" precheck_on gated gdraft ghead
  local detail_started detail_elapsed
  local -a jobs_to_load=()
  precheck_on="$(jqf -r 'if .precheck == false then 0 else 1 end' <<<"$CFG")"
  detail_started=$SECONDS
  mark_product_paths
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "ci admission detail product_path_lookup=${detail_elapsed}s"
  (( precheck_on )) && precheck_harvest
  wip="$(ci_pr_free_slots)" || { say "ci wip: PR runner capacity unavailable; admission skipped"; return 0; }
  local -A wait_of=() gwait_of=()
  GATED_SLOT=()
  if jqf -e 'any(.units[]; .stage == "ready-to-merge" and (.pr // null) != null)' "$UNITS" >/dev/null; then
    if [[ "$GATED_CENSUS_LOADED" != true ]]; then
      gated_load || say "ci wip: gated PR listing unavailable; no draft/ready flips this pass"
    fi
  else
    GATED_OF=()
  fi
  if (( ${#GATED_OF[@]} > 0 )); then
    gated_ready_exempt
  fi
  while IFS=$'\t' read -r id br head; do
    [[ -n "$id" ]] || continue
    gated=0; gdraft=false
    if [[ -n "${GATED_OF[$br]:-}" ]]; then
      gated=1; read -r _ gdraft ghead <<<"${GATED_OF[$br]}"
      [[ "$ghead" == "$head" ]] || continue
      if [[ "$gdraft" == false && "$(unit_field "$id" '.ci_ready_sha // empty')" == "$head" && -n "$(unit_field "$id" '.ci_ready_at // empty')" ]]; then
        continue
      fi
    elif [[ "$(unit_field "$id" '.ci_wip_wait // empty')" != "$head" ]]; then
      continue
    fi
    k=$((k + 1))
    if (( k <= wip )); then
      if [[ "$gated:$gdraft" != "1:false" ]] && slot_sync "$id" "$head"; then k=$((k - 1)); continue; fi
      if (( precheck_on )) && [[ "$gated:$gdraft" != "1:false" ]] && [[ "$(unit_field "$id" '.precheck_sha // empty')" != "$head" ]]; then
        # 没有本机预检结论的不占名额：排给预检，名额留给下一个已预检的单元（已 ready 在跑的门控 PR 不再预检）
        [[ -n "$pre_id" || -n "$(unit_field "$id" '.precheck_pid // empty')" ]] || pre_id="$id"
        k=$((k - 1)); if (( gated )); then gwait_of["$br"]="$id:$head"; else wait_of["$br"]="$id:$head"; fi
        continue
      fi
      if (( gated )); then gated_ready "$id" "$br" "$head"; continue; fi
      for r in $(gh run list --commit "$head" --json databaseId,conclusion --jq '.[] | select(.conclusion=="cancelled") | .databaseId' 2>/dev/null); do
        gh run rerun "$r" --failed >/dev/null 2>&1 || true
      done
      set_unit "$id" "$(hist ci-wip-start "slot $k/$wip") | del(.ci_wip_wait) | del(.ci_cancel_reruns)"
      started=$((started + 1))
    else
      if (( gated )); then gwait_of["$br"]="$id:$head"; else wait_of["$br"]="$id:$head"; fi
      # 名额满时也提前预检排队中的下一个：名额一空出就有已预检的单元可上
      if (( precheck_on )) && [[ -z "$pre_id" && "$(unit_field "$id" '.precheck_sha // empty')" != "$head" && -z "$(unit_field "$id" '.precheck_pid // empty')" ]]; then
        pre_id="$id"
      fi
    fi
  # 同一优先级按 ready_since 先后；critical 与可解锁依赖只在 readiness 相同时作 tie-break。
  done < <(jqf -r --argjson hotfix "${CI_HOTFIX_BRANCHES:-[]}" '[.units[] | select(.stage == "blocked-external") | .blocked_on | numbers] as $deps
      | [.units[] | select(.stage == "ready-to-merge" and (.hold_handoff_waiting // false) == false and (.pr // null) != null and (.lane // "") != "direct-main"
      and (.hotpatch // false) != true and (.branch // "") != ""
      and ((.branch as $br | $hotfix | index($br)) == null)
      and .product_paths != false)]
      | sort_by([(if .main_red == true then 0 elif .ci_priority == true then 1 else 2 end),
                 (.ready_since // 0), (if .critical == true then 0 else 1 end),
                 (if (.issue as $i | $deps | index($i)) or (.branch as $b | any($deps[]; $b == "agent/issue-\(.)")) then 0 else 1 end)])
      | .[] | [.id, .branch, (.approved_sha // "")] | @tsv' "$UNITS")
  while IFS=$'\t' read -r r st br; do
    [[ "$st" != queued && -n "${wait_of[$br]:-}" ]] && jobs_to_load+=("$r")
  done < <(unfinished_runs | jqf -r '.[] | select(.event == "pull_request") | [.databaseId, .status, .headBranch] | @tsv' 2>/dev/null)
  ci_jobs_prefetch "${jobs_to_load[@]}" || :
  if (( ${#wait_of[@]} > 0 )); then
    while IFS=$'\t' read -r r st br; do
      [[ -n "$r" && -n "${wait_of[$br]:-}" ]] || continue
      if [[ "$st" != queued ]]; then
        jobs="$(ci_jobs_status "$r")" || continue
        jqf -e 'all(.[]; . != "in_progress")' <<<"$jobs" >/dev/null 2>&1 || continue
      fi
      ci_cancel_run_once "$r" "ci wip" && n=$((n + 1))
    done < <(unfinished_runs | jqf -r '.[] | select(.event == "pull_request") | [.databaseId, .status, .headBranch] | @tsv' 2>/dev/null)
    for br in "${!wait_of[@]}"; do
      id="${wait_of[$br]%%:*}"; head="${wait_of[$br]#*:}"
      [[ "$(unit_field "$id" '.ci_wip_wait // empty')" == "$head" ]] || set_unit "$id" ".ci_wip_wait=$(js "$head")"
    done
  fi
  for br in "${!gwait_of[@]}"; do
    id="${gwait_of[$br]%%:*}"; head="${gwait_of[$br]#*:}"
    gated_wait "$id" "$br" "$head"
    [[ "$(unit_field "$id" '.ci_wip_wait // empty')" == "$head" ]] || set_unit "$id" ".ci_wip_wait=$(js "$head")"
  done
  if (( ${#GATED_OF[@]} > 0 )); then
    gated_demote_unapproved
  fi
  if [[ -n "$pre_id" ]] && ! jqf -e 'any(.units[]; .precheck_pid != null)' "$UNITS" >/dev/null; then
    precheck_launch "$pre_id" "$(unit_field "$pre_id" .pr)" "$(unit_field "$pre_id" '.approved_sha // empty')" || say "precheck clone unavailable for $pre_id"
  fi
  (( n + started > 0 )) && say "ci wip: $wip free PR runner slot(s); $(( ${#wait_of[@]} + ${#gwait_of[@]} )) ready unit(s) wait for a CI slot (cancelled $n queued run(s)); started $started"
  return 0
}

# Sole CI admission decision point for a scheduler tick. Gate-managed hotfixes are readied first; then
# review deferral and WIP slots apply, both exempting hotfix branches. The shared cancel set makes the
# first selected action authoritative for the rest of this pass.
ci_admission() {
  local CI_HOTFIX_BRANCHES
  local detail_started detail_elapsed
  local -A CI_ADMISSION_CANCELLED=()
  detail_started=$SECONDS
  CI_HOTFIX_BRANCHES="$(ci_hotfix_branches)" || { say "ci admission paused: open PR census unavailable for hotfix classification"; return 0; }
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "ci admission detail hotfix_classification=${detail_elapsed}s"
  detail_started=$SECONDS
  ci_ready_hotfix_gated
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "ci admission detail gated_ready=${detail_elapsed}s"
  detail_started=$SECONDS
  ci_defer_unapproved
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "ci admission detail defer_unapproved=${detail_elapsed}s"
  detail_started=$SECONDS
  ci_assign_wip
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "ci admission detail wip_assignment=${detail_elapsed}s"
}

pr_behind_main() { # pr head → 0 = head 不含当前 origin/main
  git -C "$ROOT" fetch -q origin "refs/pull/$1/head" 2>/dev/null || return 1
  [[ "$(git -C "$ROOT" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)" == "$2" ]] || return 1
  ! git -C "$ROOT" merge-base --is-ancestor refs/remotes/origin/main "$2" 2>/dev/null
}
# head 是 approved 与 main 某提交的干净两亲合并（GitHub update-branch 的产物）：PR 自身改动没变，批准沿用，不再全量复审。
approval_carries() { # pr approved head
  local p1 p2 extra tree
  git -C "$ROOT" fetch -q origin "refs/pull/$1/head" 2>/dev/null || return 1
  [[ "$(git -C "$ROOT" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)" == "$3" ]] || return 1
  read -r _ p1 p2 extra <<<"$(git -C "$ROOT" rev-list --parents -n1 "$3" 2>/dev/null)"
  [[ "$p1" == "$2" && "$p2" =~ $SHA_RE && -z "$extra" ]] || return 1
  # update-branch merges GitHub's newest main, which the local origin/main may not have yet (10-28: every carry
  # after a fresh merge went stale, costing a rereview + self-check + CI per main advance).
  git -C "$ROOT" merge-base --is-ancestor "$p2" refs/remotes/origin/main 2>/dev/null \
    || { git -C "$ROOT" fetch -q origin refs/heads/main 2>/dev/null && git -C "$ROOT" merge-base --is-ancestor "$p2" FETCH_HEAD 2>/dev/null; } \
    || return 1
  tree="$(git -C "$ROOT" merge-tree --write-tree "$p1" "$p2" 2>/dev/null)" || return 1
  [[ "$tree" == "$(git -C "$ROOT" rev-parse "$3^{tree}" 2>/dev/null)" ]]
}

# ---------- 3. 串行 merge queue + 合并后 exact-SHA suites 验证 ----------
revert_squash_merge() { # pr merge_sha [branch]; main 写入仅由 supervisor 执行时生效；给 branch 就把回退推到该分支（回退 PR），不碰 main
  local pr="$1" merge_sha="$2" target="${3:-main}" origin_url revert_repo
  origin_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || return 1
  [[ -n "$origin_url" ]] || return 1
  mkdir -p "$WT_ROOT" || return 1
  revert_repo="$(mktemp -d "$WT_ROOT/merge-revert-${pr}.XXXXXX")" || return 1
  # 从本地 checkout 克隆（硬链接对象）再取最新 main，避免每次全量下载。
  if ! git clone -q --no-checkout "$ROOT" "$revert_repo/r" 2>/dev/null; then rm -rf -- "$revert_repo"; return 1; fi
  revert_repo="$revert_repo/r"
  git -C "$revert_repo" config user.name "the product Autopilot Supervisor"
  git -C "$revert_repo" config user.email "zenoforge-autopilot@users.noreply.github.com"
  if ! git -C "$revert_repo" remote set-url origin "$origin_url" \
    || ! git -C "$revert_repo" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main; then
    say "merge revert fetch failed PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    return 1
  fi
  if ! git -C "$revert_repo" cat-file -e "${merge_sha}^{commit}" 2>/dev/null \
    || ! git -C "$revert_repo" merge-base --is-ancestor "$merge_sha" refs/remotes/origin/main; then
    say "merge revert refused: commit not on origin/main PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    return 1
  fi
  if git -C "$revert_repo" log refs/remotes/origin/main --format=%H \
    --grep="This reverts commit ${merge_sha}\." | grep -q .; then
    say "merge revert already present PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    [[ "$target" == main ]]
    return
  fi
  if ! git -C "$revert_repo" checkout -q -B "autopi-revert-pr-${pr}" refs/remotes/origin/main; then
    say "merge revert checkout failed PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    return 1
  fi
  # Squash merge commits have one parent; plain git revert is the correct inverse.
  if ! git -C "$revert_repo" revert --no-edit "$merge_sha"; then
    say "merge revert conflict PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    return 1
  fi
  # Push runs only when this function is executed by the live supervisor.
  if ! git -C "$revert_repo" push origin "HEAD:refs/heads/$target"; then
    say "merge revert push failed PR#$pr merge=$merge_sha"
    rm -rf -- "${revert_repo%/r}"
    return 1
  fi
  rm -rf -- "${revert_repo%/r}"
  return 0
}

# Pipeline-suites 首红：并行跑本机复现（detached，tick 不等它）和 GitHub 原生 rerun。复现证明「父提交过、候选败」才回退；
# 回退走 revert_squash_merge（main 的历史是幂等记录，push 的非快进拒绝是唯一并发控制）。其余情形保持原路径。
MAIN_RED_DIR="$A/main-red"
main_red_launch() { # sha run-id attempt → 后台写 $MAIN_RED_DIR/<sha>.report，一行 culprit=… 或 fallback=…
  local sha="$1" run="$2" attempt="$3" report="$MAIN_RED_DIR/$1.report"
  [[ -f "$ROOT/engine/night/main-ci-recovery.sh" ]] || { echo "fallback=worker-missing" > "$report"; return 0; }
  (cd "$ROOT" && exec setsid timeout -k 5 330 bash -c '
    out="$(ZF_REPO_DIR="$1" bash "$1/engine/night/main-ci-recovery.sh" attribute-red "$2" "$3" "$4" 2>/dev/null | tail -n 1)"
    printf "%s\n" "${out:-fallback=attribution-failed}" > "$5.tmp" && mv "$5.tmp" "$5"' _ "$ROOT" "$run" "$attempt" "$sha" "$report") > /dev/null 2>&1 < /dev/null &
}
main_red_attribution() { # sha run-id attempt；置 MAIN_RED_REVERTED（已回退）和 MAIN_RED_PENDING（复现还在跑）
  local sha="$1" run="$2" attempt="$3" dir="$MAIN_RED_DIR" report line culprit suite uid
  MAIN_RED_REVERTED=0; MAIN_RED_PENDING=0
  [[ "$sha" =~ $SHA_RE && "$run" =~ ^[0-9]+$ && "$attempt" =~ ^[1-9][0-9]*$ ]] || return 0
  report="$dir/$sha.report"
  mkdir -p "$dir" || return 0
  if [[ -e "$dir/$sha.reverted" ]]; then MAIN_RED_REVERTED=1; return 0; fi
  [[ ! -e "$dir/$sha.revert-failed" ]] || return 0
  if [[ ! -e "$dir/$sha.started" ]]; then
    : > "$dir/$sha.started"
    main_red_launch "$sha" "$run" "$attempt"
    say "main red $sha run=$run attempt=$attempt: reproduction started"
  fi
  if [[ ! -s "$report" ]]; then
    # 超过 7 分钟还没有报告就按超时走原路径
    (( NOW_EPOCH - $(stat -c %Y "$dir/$sha.started" 2>/dev/null || echo 0) < 420 )) && MAIN_RED_PENDING=1
    return 0
  fi
  line="$(head -n 1 "$report")"
  [[ "$line" == culprit=* ]] || return 0
  culprit="${line#culprit=}"; culprit="${culprit%% *}"
  suite="${line#*suite=}"; suite="${suite%% *}"
  [[ "$culprit" =~ $SHA_RE ]] || return 0
  if ! revert_squash_merge "main-red-${sha:0:9}" "$culprit"; then
    : > "$dir/$sha.revert-failed"
    say "main red $sha: revert of $culprit failed (conflict or push race); current rerun path continues"
    return 0
  fi
  : > "$dir/$sha.reverted"; MAIN_RED_REVERTED=1
  gh workflow run pipeline-suites.yml --ref main >/dev/null 2>&1 || say "main red $sha: Pipeline suites dispatch on the revert failed"
  say "main red $sha: reverted $culprit (parent passes, candidate fails $suite)"
  echo "[$STAMP] MAIN-RED-REVERTED main=$sha culprit=$culprit suite=$suite run=$run" >> "$A/alerts/gate.md"
  uid="$(jqf -r --arg c "$culprit" 'first(.units[] | select((.land_sha // "") == $c) | .id) // empty' "$UNITS")"
  [[ -n "$uid" ]] || return 0
  set_unit "$uid" "$(hist main-red-reverted "$culprit reverted after $suite failed on main") | .main_red_reverted=$(js "$culprit") | .approved_sha=null | .repair_hint=$(js "你落地的提交 $culprit 让 main 的 Pipeline suites 失败（run $run attempt $attempt，suite $suite），已被自动回退：父提交通过、该提交失败。用 gh run view $run --attempt $attempt --log-failed 看失败，在你的分支上基于当前 origin/main 重新应用改动（回退的回退或 cherry-pick $culprit），先让 $suite 通过再落地。") | .stage=\"repair-pending\""
}

ci_classify_run() { # exact run metadata + failed-step logs; retry budget is deliberately separate
  local run="$1" expected_sha="$2" run_sha status conclusion failed_log judge_input judge_output judged_class
  CI_CLASS=unknown; CI_RUN_ID="$(jqf -r '.databaseId // empty' <<<"$run")"
  CI_RUN_ATTEMPT="$(jqf -r '.attempt | select(type=="number" and .>0 and floor==.)' <<<"$run")"
  run_sha="$(jqf -r '.headSha // empty' <<<"$run")"
  status="$(jqf -r '.status // empty' <<<"$run")"
  conclusion="$(jqf -r '.conclusion // empty' <<<"$run")"
  CI_REASON="Pipeline suites ${status:-missing}/${conclusion:-no-verdict} on $expected_sha"
  [[ "$run_sha" == "$expected_sha" && "$expected_sha" =~ ^[0-9a-f]{40}$ ]] || return 0
  [[ "$status" == completed ]] || return 0
  if [[ "$conclusion" == success ]]; then CI_CLASS=pass; return 0; fi
  # Cancelled, timed out, skipped and missing verdicts do not establish a regression.
  [[ "$conclusion" == failure && "$CI_RUN_ID" =~ ^[0-9]+$ ]] || return 0
  if [[ ! "$CI_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]; then
    CI_REASON="$CI_REASON; run attempt unavailable, supervisor reconciliation required"
    return 0
  fi
  if ! failed_log="$(gh run view "$CI_RUN_ID" --attempt "$CI_RUN_ATTEMPT" --log-failed 2>/dev/null)"; then
    CI_REASON="$CI_REASON; failed logs unavailable"
    return 0
  fi
  CI_CLASS="$(printf '%s\n' "$failed_log" | python3 -c '
import re, sys
lines = sys.stdin.read().splitlines()
code = re.compile(r"FAILED suite=|\bnot ok \d+(?:\s|$)|(?:^|\s)(?-i:FAIL|FAILED)\s+\S|\b(?:AssertionError|SyntaxError|ReferenceError)\b|\berror TS\d+:|\b(?:Tests?|Suites?):[^\n]*\b[1-9]\d* failed\b|\b[1-9]\d* (?:tests?|suites?) (?:failed|failing)\b|\btest(?: case)? timed out", re.I)
network = re.compile(r"gnutls|curl: \((?:5|6|7|18|28|35|52|55|56|60)\)|could not resolve (?:host|proxy)|ECONNRESET|ETIMEDOUT|EAI_AGAIN|connection (?:reset|timed out)|failed to connect to|couldn.?t connect to|network is unreachable|TLS connection was non-properly terminated", re.I)
failed = re.compile(r"\b(?:fatal|error|failed|failure|exception)\b|timed out|##\[error\]", re.I)
wrapper = re.compile(r"(?:Error: )?Process completed with exit code \d+\.?$|The process .+ failed with exit code \d+\.?$", re.I)
suite_timeout = re.compile(r"FAILED suite=\S+.* timed out after \d+s\s*$", re.I)
if any(code.search(suite_timeout.sub("", line)) for line in lines):
    print("code")
elif any(network.search(line) or suite_timeout.search(line) for line in lines) and not any(failed.search(line) and not network.search(line) and not suite_timeout.search(line) and not wrapper.search(line) for line in lines):
    print("infra")
else:
    print("unknown")
')"
  [[ "$CI_CLASS" == infra || "$CI_CLASS" == code ]] || CI_CLASS=unknown
  judge_input="$(jqf -cn --arg event_id "ci:$CI_RUN_ID:$CI_RUN_ATTEMPT" \
    --arg current "$CI_CLASS" --arg sha "$expected_sha" \
    --arg failedLog "$(tail -c 12000 <<<"$failed_log")" \
    '{event_id:$event_id,currentDecision:$current,sha:$sha,failedLog:$failedLog}')"
  judge_output=""
  if [[ -n "${TYPESAFE_API_KEY:-}${TYPESAFE_ENV_FILE:-}" ]]; then
    judge_output="$(printf '%s\n' "$judge_input" | bash "$ROOT/engine/ts-judge.sh" ci-failure 2>/dev/null || true)"
  fi
  judged_class="$(jqf -r 'select(.status=="answered" and .adopted==true) | .decision // empty' <<<"$judge_output" 2>/dev/null || true)"
  case "$judged_class" in
    code|infra|flaky) CI_CLASS="$judged_class" ;;
  esac
}

ci_failure_retry_status() { # exact SHA, current run, existing reservation (null if unused)
  local sha="$1" run="$2" reserved="$3"
  CI_RETRY_ACTION=hold; CI_RETRY_RECORD=""
  if [[ ! "$CI_RUN_ID" =~ ^[0-9]+$ || ! "${CI_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ ]] \
    || ! jqf -e --arg sha "$sha" '.headSha==$sha and .status=="completed" and .conclusion=="failure"' <<<"$run" >/dev/null; then
    CI_REASON="$CI_REASON; retry identity unavailable, supervisor reconciliation required"
    return 0
  fi
  if [[ "$reserved" == null ]]; then
    CI_RETRY_RECORD="$(jqf -cn --arg sha "$sha" --arg run "$CI_RUN_ID" --argjson attempt "$CI_RUN_ATTEMPT" --arg at "$STAMP" \
      '{sha:$sha,workflow:"Pipeline suites",run_id:$run,attempt:$attempt,requested_at:$at}')"
    CI_RETRY_ACTION=request
  elif jqf -e --arg sha "$sha" --arg run "$CI_RUN_ID" --argjson attempt "$CI_RUN_ATTEMPT" '
    type=="object" and .sha==$sha and .workflow=="Pipeline suites" and (.run_id|tostring)==$run
    and (.attempt | type=="number" and .>0 and floor==.) and .attempt < $attempt
  ' <<<"$reserved" >/dev/null 2>&1; then
    # Server evidence reconciles even an unconfirmed rerun request; polling the old red does not.
    CI_RETRY_ACTION=observed
    CI_REASON="$CI_REASON; later completed attempt $CI_RUN_ATTEMPT observed after the reserved rerun (1/1)"
  else
    CI_REASON="$CI_REASON; retry already reserved (1/1), no proven later attempt; supervisor reconciliation required"
  fi
}

# 失败只有 per-suite 超时、没有任何 not ok：CI 机负载导致（2026-10-20 land-queue.test.sh 在 492s 上限被杀，
# 把产品 PR #3859 白白回退）。按基础设施处理：重跑一次失败 job，不回退、不当代码裁决。
suites_timeout_only() { # log-failed text
  grep -qE 'FAILED suite=.* timed out after' <<<"$1" || return 1
  ! grep -qE 'not ok [0-9]+ -' <<<"$1" && ! grep -E 'FAILED suite=' <<<"$1" | grep -vq 'timed out after'
}

# 门禁候选：从 origin/main HEAD 往回，直到第一个非 [skip ci] 提交为止（含）。
# [skip ci] 提交通常没有 suites run（L7），但 land-direct-main 会为落地提交手动派发一次，有 run 就用它。
pipeline_path_re() { # pipeline-suites.yml 的 paths → 正则（** 任意，* 不跨目录）
  sed -n "/^  pull_request:/,/^  [a-z_]*:\$/p" "$ROOT/.github/workflows/pipeline-suites.yml" 2>/dev/null \
    | sed -nE "s/^ *- '([^']+)'.*/\\1/p" \
    | sed -E 's/[.]/\\./g; s/[*][*]/@@/g; s/[*]/[^\/]*/g; s/@@/.*/g; s/^/^/; s/$/$/' | paste -sd'|'
}
gate_eval_sha() {
  # 只看最新的「非 [skip ci]」提交会让流水线 PR 饿死：产品合并频繁，最新提交的套件总在排队（2026-10-20 #3857/#3862/#3868 等 4–15 小时）。
  # 产品提交不改流水线路径，旧提交的套件结论对它仍然成立：一直往前走，直到第一个改了流水线路径的非 [skip ci] 提交（含）。
  local sha re
  re="$(pipeline_path_re)"
  for sha in $(git -C "$ROOT" log -n 30 --format=%H refs/remotes/origin/main 2>/dev/null); do
    printf '%s\n' "$sha"
    git -C "$ROOT" log -1 --format=%B "$sha" | grep -qiE '\[(skip ci|ci skip|no ci|skip actions|actions skip)\]' && continue
    [[ -n "$re" ]] && ! git -C "$ROOT" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null | grep -qE "$re" && continue
    return 0
  done
}

# main 的 Pipeline suites run 每个慢 tick 只列一次；逐提交的结论从同一份结果取，不再一提交一次 gh run list。
# 读失败也记为本拍已尝试，suites_run_for 无输出 = 没有结论，门禁照旧保持关闭。
MAIN_SUITES_RUNS=""
MAIN_SUITES_RUNS_LOADED=false
MAIN_SUITES_PREFETCH_PID=""
MAIN_SUITES_PREFETCH_DIR=""
main_suites_prefetch() { # 在早期慢 tick 阶段并行读取，run_merge_lane 与快照发布共用结果
  [[ -z "$MAIN_SUITES_PREFETCH_PID" ]] || return 0
  MAIN_SUITES_PREFETCH_DIR="$(mktemp -d)" || return 0
  (
    query_started=$SECONDS
    query_status=0
    gh run list --workflow "Pipeline suites" --branch main --limit 100 \
      --json conclusion,status,createdAt,headSha,databaseId,attempt \
      >"$MAIN_SUITES_PREFETCH_DIR/runs" 2>/dev/null || query_status=$?
    printf '%s %s\n' "$query_status" "$((SECONDS - query_started))" >"$MAIN_SUITES_PREFETCH_DIR/result"
  ) &
  MAIN_SUITES_PREFETCH_PID=$!
}
main_suites_load() {
  [[ "$MAIN_SUITES_RUNS_LOADED" != true ]] || return 0
  MAIN_SUITES_RUNS_LOADED=true
  local query_status=1 query_seconds=0 started=$SECONDS
  if [[ -n "$MAIN_SUITES_PREFETCH_PID" ]]; then
    wait "$MAIN_SUITES_PREFETCH_PID" || :
    read -r query_status query_seconds <"$MAIN_SUITES_PREFETCH_DIR/result" || :
    if [[ "$query_status" == 0 ]]; then
      MAIN_SUITES_RUNS="$(cat "$MAIN_SUITES_PREFETCH_DIR/runs" 2>/dev/null)"
    fi
    rm -rf -- "$MAIN_SUITES_PREFETCH_DIR"
    MAIN_SUITES_PREFETCH_PID=""
    MAIN_SUITES_PREFETCH_DIR=""
  else
    MAIN_SUITES_RUNS="$(gh run list --workflow "Pipeline suites" --branch main --limit 100 \
      --json conclusion,status,createdAt,headSha,databaseId,attempt 2>/dev/null)" || MAIN_SUITES_RUNS=""
    query_seconds=$((SECONDS - started))
  fi
  jqf -e 'type=="array"' <<<"$MAIN_SUITES_RUNS" >/dev/null || MAIN_SUITES_RUNS=""
  [[ "$query_seconds" =~ ^[0-9]+$ ]] && (( query_seconds < 2 )) || say "merge detail main_suites_query=${query_seconds:-unknown}s"
}
suites_run_for() { # sha → 该提交最新一次 Pipeline suites run（JSON，无则空）
  main_suites_load
  [[ -n "$MAIN_SUITES_RUNS" ]] || return 0
  jqf --arg sha "$1" 'map(select(.headSha==$sha)) | sort_by(.createdAt) | last // empty' <<<"$MAIN_SUITES_RUNS"
}

gate_note() { # 门禁状态只在变化时写 alerts/gate.md，避免每拍刷屏触发 bell
  local last="$A/.gate-last"
  [[ "$(cat "$last" 2>/dev/null)" == "$1" ]] && return 0
  echo "[$STAMP] $1" >> "$A/alerts/gate.md"
  printf '%s\n' "$1" > "$last"
}

retry_blocked_units() { # BLOCK 只在 head 变了，或 main 已推进且该单元尚未因此重评过时重派
  local id pr head reviewed blocked_main retries
  while IFS=$'\t' read -r id pr reviewed blocked_main retries; do
    [[ -n "$id" && -n "$pr" ]] || continue
    head="$(pr_view "$pr" headRefOid)"
    [[ "$head" =~ $SHA_RE ]] || continue
    if [[ "$head" != "$reviewed" ]]; then
      set_unit "$id" "$(hist block-retry "head moved to $head") | .stage=\"rereview-pending\""
      say "blocked unit=$id head moved -> rereview-pending"
    elif [[ "$blocked_main" != "$MAIN_HEAD" ]] && (( retries < 1 )); then
      set_unit "$id" "$(hist block-retry "main moved to $MAIN_HEAD") | .stage=\"review-pending\" | .block_retries=$((retries+1))"
      say "blocked unit=$id main moved -> one fresh review"
    fi
  done < <(jqf -r '.units[] | select(.stage=="blocked-external" and .blocked_on == null and .size_recut_pending != true and ((.note // "") | contains("CONFLICTED") | not)) | [.id, (.pr // "" | tostring), (.reviewed_sha // ""), (.blocked_main_sha // ""), (.block_retries // 0 | tostring)] | @tsv' "$UNITS")
}

# 队头阻塞（2026-10-21 06:42）：车道每拍只看排序后的前 BATCH_MAX*3 个就绪单元（热修、critical、最老），82 个就绪里
# 前 12 个全在等 CI 或被挡，排在 21–60 位的绿单元从来轮不到看。现在一次批量取所有 open PR 的检查汇总：
# 还没占到 CI 名额的（本拍不可能合）排到最后；其余同档内 CI 已出结论（绿/红）的先看，还在跑的其次。
merge_candidates() { # window → 就绪单元（每行一个 JSON）
  local rf; rf="$(mktemp)" || return 0
  # 同一份 census 带回 head 与 draft 状态：合并车道不再逐个 gh pr view state/headRefOid（每拍 12 个候选约 24 次调用）。
  tick_prs | node "$HERE/../ci/pr-required-aggregate.mjs" --latest-checks | jqf 'map({key: (.number | tostring), value: {head: .headRefOid, draft: .isDraft, checks: [.statusCheckRollup[]? | {name: (.name // .context // ""), link: (.detailsUrl // .targetUrl // ""), started_at: (if .__typename == "CheckRun" then (.startedAt // .started_at // null) else (.createdAt // .created_at // null) end), bucket: (if .__typename == "StatusContext" then ((.state // "" | ascii_downcase) as $s | if $s == "success" then "pass" elif ($s == "failure" or $s == "error") then "fail" else "pending" end) elif (.status // "COMPLETED") != "COMPLETED" then "pending" else ((.conclusion // "" | ascii_downcase) as $c | if $c == "success" then "pass" elif $c == "neutral" then "skipping" elif $c == "cancelled" then "cancel" elif ($c | IN("failure", "timed_out", "action_required", "startup_failure")) then "fail" else "pending" end) end)}], ci: ([.statusCheckRollup[]? | if .__typename == "StatusContext" then (.state // "" | ascii_downcase) elif (.status // "COMPLETED") != "COMPLETED" then "pending" else (.conclusion // "" | ascii_downcase) end] | if any(.[]; IN("pending", "expected", "queued", "in_progress", "waiting", "requested")) then 2 elif any(.[]; IN("failure", "error", "cancelled", "timed_out", "action_required", "startup_failure")) then 1 else 0 end)}}) | from_entries' > "$rf"
  jqf -e 'type == "object"' "$rf" >/dev/null 2>&1 || echo '{}' > "$rf"
  jqf -c --slurpfile r "$rf" '[.units[] | select(.stage=="ready-to-merge" and (.hold_handoff_waiting // false) == false and (.pr // null) != null and (.lane // "") != "direct-main")]
    | sort_by([(if (.ci_wip_wait != null and .ci_wip_wait == .approved_sha) then 1 else 0 end),
        (if .hotpatch == true then 0 elif .critical == true then 1 else 2 end),
        ($r[0][(.pr | tostring)].ci // 2), (.merge_checked_epoch // 0), (.ready_since // 0)])
    | .[0:'"$1"'] | map(. + {pr_open_head: ($r[0][(.pr | tostring)].head // null), pr_open_draft: $r[0][(.pr | tostring)].draft, pr_open_checks: ($r[0][(.pr | tostring)].checks // null)}) | .[]' "$UNITS"
  rm -f -- "$rf"
}

# 冲突的单元送修复：作废批准、留历史、给 repair 提示。合并车道两处发现冲突（checks 未齐时、合并失败后）共用；
# cause 同时进历史和日志，hint 各处自己的话（热修回迁 / 迁移编号）。
merge_conflict_to_repair() { # id pr cause repair_hint head
  local head="${5:-}" fresh files
  # GitHub 的 CONFLICTING 常是过期事实（83 个冲突修复里 8 个没有真冲突）：再问一次当前 mergeability，已无冲突就服务端
  # update-branch 一次（按 unit/head 记账，写在台账行里），批准随后由 approval_carries 沿用。锁文件与迁移 PR、更新失败、
  # 仍冲突或未知都照旧派修复。
  if [[ "$head" =~ $SHA_RE && "$(unit_field "$1" '.conflict_update_head // empty')" != "$head" ]]; then
    set_unit "$1" ".conflict_update_head=$(js "$head")" || :
    fresh="$(gh pr view "$2" --json mergeable,headRefOid --jq '"\(.mergeable) \(.headRefOid)"' 2>/dev/null)"
    if [[ "$fresh" == "MERGEABLE $head" ]]; then
      files="$(gh pr view "$2" --json files --jq '.files[].path' 2>/dev/null)"
      if [[ -n "$files" ]] && ! grep -qE '(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$|(^|/)migrations/' <<<"$files" \
        && ci_update_branch "$2" "$head"; then
        set_unit "$1" "$(hist conflict-cleared "PR#$2 GitHub reports no conflict; update-branch at $head")"
        say "PR#$2 conflict already gone; update-branch requested at $head, approval carries on the new head"
        return 0
      fi
    fi
  fi
  set_unit "$1" "$(hist merge-conflict "PR#$2 $3") | .approved_sha=null | .repair_hint=$(js "$4") | .stage=\"repair-pending\""
  say "merge skipped PR#$2 ($3) -> repair-pending"
}

# 合入即写 awaiting-release（#4515 发布状态单一事实源）：unit 台账的 unit→issue 关系驱动，
# 不读 PR 正文。无 issue 的单元（外部 PR，关闭词由 GitHub 在合并时自动关票）无事可写。
# 写失败不回滚合入（PR 已在 main 上），告警到 alerts/merge.md 人工补 conclude_merged_run。
merge_lane_awaiting_release() { # ready-unit-json pr
  local issue
  issue="$(jqf -r '.issue // empty' <<<"$1")"
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 0
  if scheduler_conclude_merged_pr "$issue" "$2" >>"$LOG" 2>&1; then
    say "issue #$issue entered awaiting-release at merge of PR#$2"
  else
    echo "[$STAMP] merged PR#$2 but the awaiting-release write for issue #$issue failed; rerun conclude_merged_run #$issue $2" >> "$A/alerts/merge.md"
    say "awaiting-release write failed for issue #$issue after PR#$2 merge"
  fi
  return 0
}

run_merge_lane() {
  local merge_max eval_sha gate_run suites grid glf gnet gtest tmpnr ready id pr adoption_pr_number approved head state branch adopted_head adopt_at adopted_label pre_merge_sha merge_sha checks red fails missing_required ready_at ready_sha rule_head rule_result rule_event rule_hint rule_actor rule_ok candidate_ids cands detail_started detail_elapsed
  # 所有 PR（含流水线 PR）都只由自己 head 上的必需检查把关，合并后由 main CI 验证；没有待验证批、没有合并后等裁决的 merging 态。
  # main 已完成的红裁决仍拦流水线 PR（pipe_open）；产品 PR 照旧不被脚本红拦（2026-10-20：15 个产品 PR 排队 3–22 小时）。
  local pipe_open=1 pipe_dep merged_count=0 mstate i
  [[ "$(jqf -r .auto_merge <<<"$CFG")" == "true" ]] || return 0
  # fast_land_lane may advance main earlier in this tick; refresh the rule-lane and suite-gate base here.
  detail_started=$SECONDS
  if git -C "$ROOT" fetch -q origin main 2>/dev/null; then
    MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)"
  fi
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail refresh_main=${detail_elapsed}s"
  merge_max="$(jqf -r '.batch_max // 4' <<<"$CFG")"
  [[ "$merge_max" =~ ^[1-9][0-9]*$ ]] || merge_max=4
  eval_sha=""; gate_run=""
  local candidate
  # 取候选链上最新一个「已完成」的 run；更新的 [skip ci] 直落提交只有在跑的 run 时不让产品合并干等它（直落频繁会饿死车道）。
  local first_eval="" first_run="" run
  detail_started=$SECONDS
  for candidate in $(gate_eval_sha); do
    [[ "$candidate" =~ $SHA_RE ]] || continue
    run="$(suites_run_for "$candidate")"
    [[ -n "$run" ]] || { [[ -z "$first_eval" ]] && first_eval="$candidate"; continue; }
    [[ -z "$first_eval" ]] && { first_eval="$candidate"; first_run="$run"; }
    # 被取消的 run 不是裁决（去重会取消被取代的排队 run），继续往链上找
    if [[ "$(jqf -r '.status // empty' <<<"$run")" == completed && "$(jqf -r '.conclusion // empty' <<<"$run")" != cancelled ]]; then eval_sha="$candidate"; gate_run="$run"; break; fi
  done
  [[ -n "$eval_sha" ]] || { eval_sha="$first_eval"; gate_run="$first_run"; }
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail suite_gate_lookup=${detail_elapsed}s"
  detail_started=$SECONDS
  ci_classify_run "$gate_run" "$eval_sha"
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail main_ci_classify=${detail_elapsed}s"
  suites="$(jqf -r '.conclusion // empty' <<<"$gate_run")"
  if [[ "$(jqf -r '.status // empty' <<<"$gate_run")" == completed && "$suites" == failure ]]; then
    local retry_record
    MAIN_RED_REVERTED=0; MAIN_RED_PENDING=0
    open_landed_red_unit "$eval_sha" "$CI_RUN_ID" "$CI_RUN_ATTEMPT"
    [[ "$CI_CLASS" != code ]] || main_red_attribution "$eval_sha" "$CI_RUN_ID" "$CI_RUN_ATTEMPT"
    [[ -f "$A/gate-net-rerun.json" ]] || echo '{}' > "$A/gate-net-rerun.json"
    retry_record="$(jqf -c --arg sha "$eval_sha" 'if has($sha) then .[$sha] else null end' "$A/gate-net-rerun.json" 2>/dev/null)" || retry_record='{}'
    ci_failure_retry_status "$eval_sha" "$gate_run" "$retry_record"
    if (( MAIN_RED_REVERTED )); then
      CI_REASON="$CI_REASON; culprit reverted, awaiting Pipeline suites on the revert"
    elif [[ "$CI_RETRY_ACTION" == request ]]; then
      if jqf --arg sha "$eval_sha" --argjson record "$CI_RETRY_RECORD" \
        '.[$sha]=$record' "$A/gate-net-rerun.json" | write_state "$A/gate-net-rerun.json"; then
        if gh run rerun "$CI_RUN_ID" --failed >/dev/null 2>&1; then
          CI_REASON="$CI_REASON; first-failure rerun requested (1/1), awaiting a later attempt"
        else
          CI_REASON="$CI_REASON; first-failure rerun request unconfirmed (1/1), awaiting server evidence"
        fi
      else
        CI_REASON="$CI_REASON; retry reservation failed, lane held"
      fi
    elif [[ "$CI_RETRY_ACTION" == observed && "$CI_CLASS" == code ]]; then
      if (( MAIN_RED_PENDING )); then CI_REASON="$CI_REASON; reproduction still running, main-red unit waits"
      else open_main_red_unit "$eval_sha" "$CI_RUN_ID" "$CI_RUN_ATTEMPT"; fi
    fi
  fi
  local pending_pass=0 hotpatch_pass=0
  if [[ "$CI_CLASS" == unknown ]] && jqf -e --arg sha "$eval_sha" '
      type=="object" and .headSha==$sha and ($sha | test("^[0-9a-f]{40}$"))
      and (.databaseId | type=="number" and .>0 and floor==.)
      and (.conclusion==null or .conclusion=="")
      and (.status | IN("queued", "in_progress", "waiting", "pending", "requested"))
    ' <<<"$gate_run" >/dev/null; then pending_pass=1; fi
  if [[ "$CI_CLASS" == pass ]] || (( pending_pass )); then hotpatch_pass=1; fi
  if [[ "$CI_CLASS" != pass ]] && (( ! pending_pass )); then
    gate_note "GATE class=$CI_CLASS main=${eval_sha:-unknown} run=${CI_RUN_ID:-unknown}; $CI_REASON; merge lane held for pipeline PRs; product PRs still merge"
    pipe_open=0
  elif [[ "$suites" != "success" ]] && (( pipe_open )); then
    gate_note "GATE main=${eval_sha:-unknown} run=${CI_RUN_ID:-unknown} status=$(jqf -r .status <<<"$gate_run") — pipeline PRs merge on their own checks; main CI verifies after merge"
  elif (( pipe_open )); then
    gate_note "GATE main=$eval_sha suites=success — merge lane open"
  fi

  # 候选的检查行取自 merge_candidates 那一次批量 gh pr list（census），不再逐个 gh pr checks；合并仍用 --match-head-commit 钉住 head。
  detail_started=$SECONDS
  cands="$(merge_candidates "$((merge_max * 3))")"
  candidate_ids="$(jqf -cs '[.[] | select(type=="object") | .id] | unique' <<<"$cands")"
  if jqf -e 'length > 0' <<<"$candidate_ids" >/dev/null; then
    units_update --argjson ids "$candidate_ids" --argjson checked "$NOW_EPOCH" \
      '.units |= map(if (.id as $id | $ids | index($id)) != null then .merge_checked_epoch=$checked else . end)' \
      || { detail_elapsed=$((SECONDS - detail_started)); (( detail_elapsed < 2 )) || say "merge detail candidate_build=${detail_elapsed}s"; say "merge lane stopped: could not record the current candidate scan"; return 0; }
  fi
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail candidate_build=${detail_elapsed}s"
  detail_started=$SECONDS
  while IFS= read -r ready; do
    [[ -z "$ready" || "$ready" == "null" ]] && break
    id="$(jqf -r .id <<<"$ready")"; pr="$(jqf -r .pr <<<"$ready")"
    # Fair bounded scans rotate past repeatedly blocked candidates; their scan time was written as one ledger update above.
    approved="$(jqf -r '.approved_sha // empty' <<<"$ready")"
    head="$(jqf -r '.pr_open_head // empty' <<<"$ready")"
    if [[ "$head" =~ $SHA_RE ]]; then
      state=OPEN
    elif [[ -n "${TICK_PR_STATE[$pr]:-}" ]]; then
      state="${TICK_PR_STATE[$pr]}"
    else
      state="$(pr_view "$pr" state)"
      [[ -n "$state" ]] && TICK_PR_STATE["$pr"]="$state"
    fi
    if [[ "$state" == "MERGED" || "$state" == "CLOSED" ]]; then
      [[ "$state" == MERGED ]] && state=merged || state=closed
      set_unit "$id" "$(hist pr-"$state" "outside the merge lane") | .stage=\"$state\""
      say "unit=$id PR#$pr already $state; left the merge lane"
      continue
    fi
    if ! jqf -e '(.stacked_on == null) or (.stacked_on_released == true)' <<<"$ready" >/dev/null; then
      say "merge skipped PR#$pr (stacked predecessor has not completed its release cycle)"
      continue
    fi
    if [[ -n "${READIED_PRS[$pr]:-}" ]]; then say "merge skipped PR#$pr (readied this pass; CI starts now)"; continue; fi
    if jqf -e '(.gated // false) == true and .pr_open_checks == null' <<<"$ready" >/dev/null; then
      say "merge skipped PR#$pr (check census unavailable)"
      continue
    fi
    [[ "$head" =~ $SHA_RE ]] || head="$(pr_view "$pr" headRefOid)"
    # 先沿用批准再跳过 draft：slot_sync 的 update-branch 会换 draft 的 head，不沿用的话 gated_ready 永远不 ready 它
    if [[ "$approved" =~ $SHA_RE && "$head" =~ $SHA_RE && "$head" != "$approved" ]] && approval_carries "$pr" "$approved" "$head"; then
      set_unit "$id" "$(hist approval-carried "clean main merge $head on approved $approved") | .approved_sha=$(js "$head")"
      say "approval carried PR#$pr $approved -> $head (clean update-branch merge)"
      post_approved_status "$id" "$head"
      approved="$head"
    fi
    if [[ "$(jqf -r '.pr_open_draft // false' <<<"$ready")" == true ]]; then say "merge skipped PR#$pr (draft, waiting for its CI slot)"; continue; fi
    if [[ ! "$head" =~ $SHA_RE ]]; then say "merge skipped PR#$pr (head unreadable; unit left unchanged)"; continue; fi
    if [[ ! "$approved" =~ $SHA_RE || "$head" != "$approved" ]]; then
      # 批准绑定的 head 已变（或旧台账无绑定）：新提交必须先评审，不能带着旧批准合并。
      set_unit "$id" "$(hist approval-stale "approved=${approved:-none} head=${head:-unknown}") | .stage=\"rereview-pending\""
      say "merge skipped PR#$pr (head ${head:-unknown} != approved ${approved:-none}) -> rereview-pending"
      continue
    fi
    # #4484：非 agent 分支的接管 PR，重活 job 的 if 只认 agent/issue- 前缀或 pipeline-ci 标签，不打标签
    # 就永远拿不到必需检查。首次接管确保产生 labeled 事件并记录时间下限；已有同名标签时先移除再加回，
    # 因为 gh pr edit --add-label 对已有标签是 no-op，不会启动 policy 与重活检查。之后新 head 的
    # synchronize/update-branch 事件已开 CI，沿用原下限，避免把已经启动的检查误判为过期。
    branch="$(jqf -r '.branch // empty' <<<"$ready")"
    adopted_head="$(unit_field "$id" '.ci_adopt_head // empty')"
    adopt_at="$(unit_field "$id" '.ci_adopt_at // empty')"
    if [[ -n "$branch" && ! "$branch" =~ $GATED_BRANCH_RE && "$adopted_head" != "$head" ]]; then
      if [[ -n "$adopt_at" ]]; then
        # The label already triggered CI for the prior head; synchronize/update-branch started
        # fresh checks for this head. Keep the original floor rather than resetting it after
        # those runs have already started.
        set_unit "$id" ".ci_adopt_head=$(js "$head")"
        say "adopt PR#$pr: $PIPELINE_CI_LABEL retained for new head; synchronize CI supplies fresh checks"
      else
        ensure_pipeline_ci_label
        adoption_pr_number="$pr"
        adopted_label="$(tick_prs | jqf -r --arg pr "$adoption_pr_number" --arg label "$PIPELINE_CI_LABEL" '[.[] | select((.number | tostring) == $pr) | .labels[]?.name] | any(.[]; . == $label)')"
        if tick_prs_changed \
          && { [[ "$adopted_label" != true ]] || gh pr edit "$pr" --remove-label "$PIPELINE_CI_LABEL" >/dev/null 2>&1; } \
          && gh pr edit "$pr" --add-label "$PIPELINE_CI_LABEL" >/dev/null 2>&1; then
          set_unit "$id" "$(hist ci-adopt "non-agent branch gets a fresh $PIPELINE_CI_LABEL labeled event; heavy PR CI starts") | .ci_adopt_head=$(js "$head") | .ci_adopt_at=$(js "$STAMP")"
          say "adopt PR#$pr: $PIPELINE_CI_LABEL label event started branch policy and heavy gates"
        else
          say "merge skipped PR#$pr ($PIPELINE_CI_LABEL label event setup failed; retried next pass)"
        fi
      fi
      continue
    fi
    checks="$(jqf -c '.pr_open_checks // empty' <<<"$ready")"
    if [[ -z "$checks" ]]; then say "merge skipped PR#$pr (check census unavailable)"; continue; fi
    fails="$(jqf -r '[.[] | select(.bucket == "fail") | .name] | sort | join(",")' <<<"$checks" 2>/dev/null || true)"
    if [[ -n "$fails" && "$(jqf -r '.ci_test_checked // empty' <<<"$ready")" != "$head:$fails" ]]; then
      set_unit "$id" ".ci_test_checked=$(js "$head:$fails")"
      red_out="$(ci_test_red_checks "$checks")"
      red="$(head -n1 <<<"$red_out")"; red_facts="$(tail -n +2 <<<"$red_out")"
      if [[ -n "$red" ]]; then
        if ci_stale_base_hop "$id" "$pr" "$head" "$red_facts"; then continue; fi
        set_unit "$id" ".ci_facts_head=$(js "$head") | .ci_facts=$(js "$red_facts")"
        say "triage PR#$pr head ${head:0:9}: $(ci_triage "$head" "$red_facts") (verdict only; routing unchanged)"
        cancel_branch_runs "$(jqf -r '.branch // empty' <<<"$ready")" "tests already red; repair pushes a new head"
        set_unit "$id" "$(hist ci-test-red "$red") | .approved_sha=null | .repair_hint=$(js "PR head $head 的必需检查已有测试失败：$red。用 gh pr checks $pr 与失败 job 日志定位；失败的是集成测试就先在本机测试库复现（RUN_INTEGRATION=1 npx vitest run <文件>，PGTEST_URL 已配好），修到本地绿再 push；本 PR 引起的就修并补回归测试；确属与本 PR 无关的环境故障就不改代码，在报告里写明证据。$(ci_fact_hint "$head" "$red_facts")") | .stage=\"repair-pending\""
        say "merge skipped PR#$pr (tests failed in: $red) -> repair-pending without waiting for the other checks or a rerun"
        continue
      fi
    fi
    if ! jqf -e 'length > 0 and all(.[]; .bucket != "pending")' <<<"$checks" >/dev/null; then
      # 冲突的 PR GitHub 不跑 pull_request CI，checks 永远 pending；以前只在合并失败后才查冲突，于是永远等下去
      # （2026-10-20 热修回迁 pr-3588 已批准却 CONFLICTING）。checks 未齐时先看是否冲突，冲突就派修复合 main。
      if [[ "$(pr_view "$pr" mergeable)" == CONFLICTING ]]; then
        merge_conflict_to_repair "$id" "$pr" "conflicts with main; CI cannot start" "PR 与最新 main 冲突，GitHub 不会跑 CI 也拒绝合并。git merge --no-edit origin/main，按两边意图解决冲突（热修回迁以生产已验证行为为准），跑受影响测试，推送。" "$head"
        continue
      fi
      say "merge skipped PR#$pr (checks pending or unavailable)"
      continue
    fi
    red="$(jqf -r '[.[] | select(.bucket=="fail" or .bucket=="cancel") | .name] | unique | join(", ")' <<<"$checks")"
    if [[ -n "$red" ]]; then
      if jqf -e 'any(.[]; .bucket == "fail")' <<<"$checks" >/dev/null; then
        if ci_cancelled_upstream "$checks"; then
          if [[ "$(unit_field "$id" '.ci_wip_wait // empty')" == "$head" ]]; then say "merge skipped PR#$pr (CI waits for a WIP slot)"
          else ci_cancelled "$id" "$pr" "$head" "$red" upstream; fi
        else ci_red "$id" "$pr" "$head" "$red"; fi
      elif [[ "$(unit_field "$id" '.ci_wip_wait // empty')" == "$head" ]]; then say "merge skipped PR#$pr (CI waits for a WIP slot)"
      else ci_cancelled "$id" "$pr" "$head" "$red"; fi
      continue
    fi
    if [[ "$(jqf -r '.gated // false' <<<"$ready")" == true ]]; then
      ready_at="$(jqf -r '.ci_ready_at // empty' <<<"$ready")"
      ready_sha="$(jqf -r '.ci_ready_sha // empty' <<<"$ready")"
      if [[ -z "$ready_at" || "$ready_sha" != "$head" ]]; then
        say "merge skipped PR#$pr (ready_for_review evidence missing for approved head)"
        continue
      fi
      missing_required="$(required_checks_without_pass "$checks" "$ready_at")"
    else
      # #4484：接管（打 pipeline-ci 标签）前的旧绿行不算数，时间下限同门控 ready_for_review 语义；
      # 标签留在 PR 上，所以后续 synchronize/update-branch 已触发同一批检查；保留首次 labeled 时间下限。
      adopt_at="$(jqf -r '.ci_adopt_at // empty' <<<"$ready")"
      missing_required="$(required_checks_without_pass "$checks" "$adopt_at")"
    fi
    if [[ -n "$missing_required" ]]; then
      # #4484：聚合 job 定义在分支自带的 workflow 里，先于它创建的分支永远没有这一行。不是无限等：
      # 落后 main 且干净就服务端 update-branch（新 head 带上聚合 job 与 label 条件，批准由
      # approval_carries 沿用），冲突照旧派修复合 main；只在真正转移时记账，每个 head 一次，
      # 转不动的由 ready-to-merge SLO 升级。
      if [[ "$(unit_field "$id" '.ci_sync_head // empty')" != "$head" ]] && pr_behind_main "$pr" "$head"; then
        state="$(pr_view "$pr" mergeable)"
        if [[ "$state" == MERGEABLE ]] && ci_update_branch "$pr" "$head"; then
          set_unit "$id" "$(hist ci-sync-update-branch "required checks missing: $missing_required") | .ci_sync_head=$(js "$head")"
          say "merge skipped PR#$pr (required checks without a real pass: $missing_required) -> update-branch refreshes the branch workflows"
          continue
        fi
        if [[ "$state" == CONFLICTING ]]; then
          set_unit "$id" ".ci_sync_head=$(js "$head")"
          merge_conflict_to_repair "$id" "$pr" "required checks never ran; branch conflicts with main" "PR 长期拿不到必需检查且与最新 main 冲突。git merge --no-edit origin/main，按两边意图解决冲突，跑受影响测试，推送。" "$head"
          continue
        fi
      fi
      say "merge skipped PR#$pr (required checks without a real pass: $missing_required)"
      continue
    fi
    pipe_dep=0
    jqf -e 'any(.[]; .name | startswith("Pipeline suites") or . == "Select pipeline-suite scope")' <<<"$checks" >/dev/null && pipe_dep=1
    if (( pipe_dep && ! pipe_open )); then
      if (( hotpatch_pass )) && [[ "$(jqf -r '.hotpatch // false' <<<"$ready")" == true ]]; then
        say "merge PR#$pr hot patch while main suites are pending (not red)"
      else
        say "merge skipped PR#$pr (touches pipeline paths; pipeline merges held)"; continue
      fi
    fi
    # 先取当前 PR ref 并确认它仍是刚才审核/批准的 head，再对这个固定 SHA 执行同一规则判定（#4548 CTO 裁决
    # 2026-10-29）：原样复用 rule-lane.sh，actor 与 direct-main 同源取合并身份——supervisor 起拍
    # （ZF_AGENT_NAME=supervisor）时非 unit 分支的 PR 走规则通道，按 Rule-Replay 回放报告放行；
    # unit worker 的分支（agent/issue-*、agent/auto-issue-*、factory/*、hand/*）无论环境一律按 unit 判定，
    # 改到规则文件即拒、PR 留修复说明并转 supervisor 队列。
    if ! git -C "$ROOT" fetch -q origin "refs/pull/$pr/head" 2>/dev/null; then
      say "merge skipped PR#$pr (rule diff unavailable)"
      continue
    fi
    rule_head="$(git -C "$ROOT" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)"
    if [[ "$rule_head" != "$head" ]]; then
      say "merge skipped PR#$pr (rule diff head moved)"
      continue
    fi
    case "$branch" in
      agent/issue-*|agent/auto-issue-*|factory/*|hand/*) rule_actor="unit:${branch}" ;;
      *) rule_actor="${ZF_AGENT_NAME:-unit}" ;;
    esac
    if rule_result="$(cd "$ROOT" && ZF_AGENT_NAME="$rule_actor" bash "$ROOT/engine/rule-lane.sh" "$MAIN_HEAD" "$rule_head" 2>&1)"; then
      rule_ok=1
    else
      rule_ok=0
    fi
    rule_event="${rule_result%%$'\n'*}"
    if [[ "$rule_event" != rule-lane:\ decision=* ]]; then
      say "merge skipped PR#$pr (rule lane unavailable: ${rule_event:-no result})"
      continue
    fi
    say "$rule_event"
    if (( ! rule_ok )); then
      if [[ "$rule_event" == *decision=unit-reject* ]]; then
        if [[ "$(unit_field "$id" '.rule_lane_commented_sha // empty')" != "$head" ]]; then
          rule_hint="${rule_result#*$'\n'}"
          rule_hint="${rule_hint#rule-lane: }"
          if gh pr comment "$pr" --body "$rule_hint" >/dev/null 2>&1; then
            set_unit "$id" ".rule_lane_commented_sha=$(js "$head")" \
              || say "rule-lane: could not record repair comment PR#$pr head=${head:0:12}"
          else
            say "rule-lane: repair comment failed PR#$pr head=${head:0:12}"
          fi
        fi
        to_supervisor "$id" "PR#$pr 改到规则文件（${rule_event#*files=}）：unit 不能合入规则改动，转 supervisor 规则通道处理"
      elif [[ "$rule_event" == *decision=rule-reject* ]]; then
        say "merge skipped PR#$pr (rule lane rejected the replay report)"
      else
        say "merge skipped PR#$pr (rule lane failed)"
      fi
      continue
    fi
    pre_merge_sha="$(git -C "$ROOT" ls-remote origin refs/heads/main 2>/dev/null | awk 'NR==1 {print $1}')"
    # main may advance while PR checks run or another lane lands; exact-head PR checks gate the merge,
    # and post-merge exact-SHA CI verifies the resulting main commit without a stable-main barrier.
    if [[ "$pre_merge_sha" =~ $SHA_RE ]]; then
      tick_prs_changed
      if gh pr merge "$pr" --squash --match-head-commit "$approved" >/dev/null 2>&1; then
        merge_sha="$(gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null)"
        [[ "$merge_sha" =~ $SHA_RE ]] || merge_sha=""
        if [[ -n "$merge_sha" ]]; then
          set_unit "$id" "$(hist merged "merged on green PR CI; main CI verifies $merge_sha") | (.stage=\"merged\") | .merge_sha=\"$merge_sha\" | .pre_merge_sha=\"$pre_merge_sha\""
          merge_lane_awaiting_release "$ready" "$pr"
          merged_count=$((merged_count + 1))
          say "merged PR#$pr merge=$merge_sha (own checks green; main CI verifies)"
          (( merged_count >= merge_max )) && break
          continue
        fi
        set_unit "$id" "$(hist merged "merged on green PR CI; mergeCommit SHA unavailable") | (.stage=\"merged\")"
        merge_lane_awaiting_release "$ready" "$pr"
        echo "[$STAMP] merged PR#$pr but mergeCommit SHA unavailable; unit=$id marked merged, main CI covers it" >> "$A/alerts/merge.md"
        break
      elif mstate="$(pr_view "$pr" mergeable)"; for i in 1 2 3; do [[ "$mstate" == UNKNOWN ]] || break; sleep 2; mstate="$(pr_view "$pr" mergeable)"; done; [[ "$mstate" == CONFLICTING ]]; then
        # GitHub 合并失败后 mergeable 常短暂为 UNKNOWN：以前当成"squash 失败"每拍空试（#3885/#3860 又空转 10+ 小时）
        # 冲突不会自己消失：以前每拍空试 merge（#3885/#3860 空转数小时），现在直接派修复合 main。
        merge_conflict_to_repair "$id" "$pr" "conflicts with main" "PR 与最新 main 冲突，GitHub 拒绝合并。git merge --no-edit origin/main，按两边意图解决冲突（迁移编号顺延到 main 之后），跑受影响测试后 push。" "$head"
      else
        say "merge skipped PR#$pr (synchronous squash merge failed)"
      fi
    else
      say "merge skipped PR#$pr (pre-merge main SHA unavailable)"
    fi
  done <<<"$cands"
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail candidate_pass=${detail_elapsed}s"
  detail_started=$SECONDS
  retry_blocked_units
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail blocked_pr_recheck=${detail_elapsed}s"
}

# ---------- 3b. 完成清理：终态单元回收 clone，台账瘦身，日志轮转 ----------
rotate_logs() {
  local f
  for f in "$LOG" "$A"/alerts/*.md; do
    [[ -f "$f" ]] || continue
    (( $(wc -c < "$f") > 5242880 )) && mv -f "$f" "$f.1"
  done
  return 0
}

worktree_cleanup_block_reason() { # dir -> reason when deleting it could lose recoverable Git work
  local wt="$1" status stash head remote_refs pushed_refs
  [[ -e "$wt/.git" ]] || return 1
  if ! status="$(git -C "$wt" status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
    printf 'could not inspect Git status'
    return 0
  fi
  [[ -z "$status" ]] || { printf 'uncommitted changes'; return 0; }
  if ! stash="$(git -C "$wt" stash list -n 1 2>/dev/null)"; then
    printf 'could not inspect Git stashes'
    return 0
  fi
  [[ -z "$stash" ]] || { printf 'Git stash exists'; return 0; }
  if ! head="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)"; then
    printf 'could not inspect HEAD'
    return 0
  fi
  if ! remote_refs="$(git -C "$wt" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)"; then
    printf 'could not inspect remote-tracking refs'
    return 0
  fi
  [[ -n "$remote_refs" ]] || { printf 'no remote-tracking refs to verify HEAD'; return 0; }
  if ! pushed_refs="$(git -C "$wt" for-each-ref --contains "$head" --format='%(refname)' refs/remotes 2>/dev/null)"; then
    printf 'could not verify whether HEAD was pushed'
    return 0
  fi
  [[ -n "$pushed_refs" ]] || { printf 'HEAD is not reachable from a remote-tracking ref'; return 0; }
  return 1
}

cleanup_tick() {
  local id wt n_total b track r block_reason
  # eval 在途（pending/running）的单元保留 worktree：#4656 起 eval 并行跑，可能在单元 merged 之后才结束。
  for id in $(jqf -r '.units[] | select(.stage=="merged" or .stage=="landed" or .stage=="awaiting-live-event" or .stage=="done" or .stage=="wontfix" or .stage=="duplicate" or .stage=="closed") | select((.eval_gate.status // "") | IN("pending","running") | not) | .id' "$UNITS"); do
    for wt in "$WT_ROOT/wt-${id}" "/tmp/wt-${id}"; do
      [[ -d "$wt" ]] || continue
      if block_reason="$(worktree_cleanup_block_reason "$wt")"; then
        say "preserve worktree $wt: $block_reason"
      else
        rm -rf -- "$wt"
        say "cleanup worktree $wt"
      fi
    done
  done
  n_total="$(jqf '.workers | length' "$WORKERS" 2>/dev/null || echo 0)"
  if (( n_total > 60 )); then
    # 未回收的 worker 一律保留，只裁剪已回收的旧记录。
    jqf '{workers: ([.workers[] | select(.harvested != true)] + ([.workers[] | select(.harvested == true)] | sort_by(.started) | .[-60:]))}' "$WORKERS" | write_state "$WORKERS"
    say "trim workers ledger $n_total"
  fi
  # 只删一天无写入的超大日志：活 worker 的日志仍在写，不会被删。
  find "$SUP" -maxdepth 1 -name '*.worker.log' -size +4M -mmin +1440 -delete 2>/dev/null
  # worker 临时目录（runtime-env.sh 的 AP_TMPDIR）：一天没动的条目回收。
  [[ -n "${AP_TMPDIR:-}" && -d "$AP_TMPDIR" ]] && find "$AP_TMPDIR" -mindepth 1 -maxdepth 1 -mmin +1440 -exec rm -rf -- {} + 2>/dev/null
  # worker 常把日志、构建直接写到 /tmp（不走 TMPDIR）：WSL 的 /tmp 是 3.9G tmpfs，10-21 18:4x 再次写满（L72）。
  # 只收本用户、里外都 6 小时没写过的顶层条目；Claude Code 自己的 claude-* 不动，在跑的构建有新写入不会被收。
  local sys_tmp="${AP_SYSTEM_TMP:-/tmp}" e
  if [[ "${AP_SYSTEM_TMP_FS:-$(stat -f -c %T "$sys_tmp" 2>/dev/null)}" == tmpfs ]]; then
    while IFS= read -r -d '' e; do
      [[ -z "$(find "$e" -mmin -360 -print -quit 2>/dev/null)" ]] && rm -rf -- "$e"
    done < <(find "$sys_tmp" -mindepth 1 -maxdepth 1 -user "$(id -u)" -mmin +360 ! -name 'claude-*' -print0 2>/dev/null)
  fi
  # 本地分支只在"曾跟踪的远端分支已删除（[gone]）"时清理；从未 push 的本地分支不动。每小时一次。
  if [[ ! -f "$A/.branch-gc" || -n "$(find "$A/.branch-gc" -mmin +60 2>/dev/null)" ]]; then
    touch "$A/.branch-gc"
    if git -C "$ROOT" fetch -q --prune origin 2>/dev/null; then
      while read -r b track; do
        [[ "$track" == "[gone]" ]] || continue
        git -C "$ROOT" branch -q -D "$b" 2>/dev/null && say "cleanup local branch $b (upstream gone)"
      done < <(git -C "$ROOT" for-each-ref --format='%(refname:short) %(upstream:track)' 'refs/heads/agent/' 'refs/heads/fix/' 2>/dev/null)
    fi
    # 远端 rescued/* 收尾：issue 已关闭或无 issue 号超龄的先进 bundle（$AGENT_ARCHIVE）再删，逐条记 rescued-gc.log。
    if [[ -f "$HERE/rescued_gc.sh" ]]; then
      r="$(timeout 600 bash "$HERE/rescued_gc.sh" "$ROOT" "$A/rescued-gc.log" 2>&1 | tail -1)"
      [[ -n "$r" ]] && say "$r"
    fi
  fi
}

# ---------- 4z. M5 生效即验收（#4495/#4501）：直落单等登记的生产事件才关票 ----------
# pipeline-system 票的验收块是 issue 正文 ```json 围栏里带 acceptance 数组的对象，至少一项
# id=live-event，通过 event 字段或登记表 acceptance_item_ids 绑定到登记机制。
# 派发时把验收块存进 unit 记录；direct-main 落地后不立即关票（stage=awaiting-live-event），
# 观测到该机制晚于落地时间的事件行才关票（评论附证据行），超过该机制的沉默上限转 supervisor；
# 关票前对比存档的验收块，worker 改过验收项就拒绝关票。
MECH_REGISTRY_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/state/mechanism-registry.json"

acceptance_block_from_body() { # stdin: issue 正文 → 首个带 acceptance 数组的 ```json 围栏块（canonical JSON），无则空
  local body block
  body="$(cat)"
  while [[ "$body" == *'```json'* ]]; do
    body="${body#*'```json'}"
    block="${body%%'```'*}"
    body="${body#*'```'}"
    jqf -ce 'if type=="object" and (.acceptance|type)=="array" then . else empty end' <<<"$block" && return 0
  done
  return 1
}

acceptance_live_event_ref() { # acceptance-json → live-event 项绑定的登记表机制 id
  local ref
  ref="$(jqf -r 'first(.acceptance[] | select(.id == "live-event") | .event // empty) // ""' <<<"$1")"
  if [[ -n "$ref" ]]; then
    printf '%s\n' "$ref"
    return 0
  fi
  [[ -r "$MECH_REGISTRY_FILE" ]] || return 1
  jqf -r --arg item "live-event" '
    [.mechanisms[] | select(any(.acceptance_item_ids[]?; . == $item)) | .id]
    | if length == 1 then .[0] else empty end
  ' "$MECH_REGISTRY_FILE"
}

acceptance_has_live_event() { # acceptance-json → 验收块是否含 live-event 项
  jqf -e 'any(.acceptance[]; .id == "live-event")' <<<"$1" >/dev/null 2>&1
}

mechanism_registry_entry() { # mechanism-id → 登记表机制 JSON，未知或登记表缺失为空
  [[ -r "$MECH_REGISTRY_FILE" ]] || return 1
  jqf -ce --arg id "$1" '[.mechanisms[] | select(.id == $id)][0] // empty' "$MECH_REGISTRY_FILE"
}

acceptance_live_event_registered() { # acceptance-json → 0 当 live-event 可解析到已登记机制
  local ref
  ref="$(acceptance_live_event_ref "$1")" || return 1
  [[ -n "$ref" ]] && mechanism_registry_entry "$ref" >/dev/null
}

mechanism_event_after() { # mechanism-json landed-epoch → stdout：晚于落地时间的事件行，无则非零
  local mech="$1" landed="$2" ev base root file pattern path line epoch
  while IFS= read -r ev; do
    base="$(jqf -r '.base // "runtime"' <<<"$ev")"
    file="$(jqf -r '.file // empty' <<<"$ev")"
    pattern="$(jqf -r '.pattern // empty' <<<"$ev")"
    [[ -n "$file" && -n "$pattern" ]] || continue
    if [[ "$base" == agent_home ]]; then root="${AGENT_HOME:-${HOME:-}/.zenoforge}"; else root="$A"; fi
    for path in "$root/$file" "$root/$file.1"; do
      [[ -r "$path" ]] || continue
      while IFS= read -r line; do
        [[ "$line" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\] ]] || continue
        epoch="$(ap_iso_epoch "${BASH_REMATCH[1]}")"
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        (( epoch > landed )) || continue
        printf '%s' "$line"
        return 0
      done < <(grep -E -- "$pattern" "$path" 2>/dev/null || true)
    done
  done < <(jqf -c '.events[]?' <<<"$mech")
  return 1
}

landed_live_event_wait() { # unit issue land-sha → 0=无 live-event 项，照旧立即关票；1=已转等待生产事件
  local stored
  stored="$(unit_field "$1" '.acceptance // empty')"
  if [[ -z "$stored" ]]; then
    # M5 之前派发的在途单没有存档：落地时读当前验收块作为基线；读不到按无验收块关票
    stored="$(gh issue view "$2" --json number,title,body,state,labels 2>/dev/null | jqf -r '.body // ""' | acceptance_block_from_body || true)"
  fi
  [[ -n "$stored" ]] || return 0
  acceptance_has_live_event "$stored" || return 0
  set_unit "$1" ".acceptance=$(jqf -ce . <<<"$stored") | .landed_at=$(js "$STAMP") | .stage=\"awaiting-live-event\""
  say "live-event wait unit=$1 issue=$2 sha=$3 已落地、待生效"
  ( source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "live-event-wait:$2:$3" \
      "live-event-wait issue=#$2 status=已落地、待生效 sha=$3 unit=$1" ) \
    || say "live-event wait unit=$1: supervisor inbox unavailable"
  return 1
}

live_event_watch() { # 每拍：等待生产事件的直落单——事件出现关票、超沉默上限或验收块被改转 supervisor
  local u id issue stored ref mech bound landed landed_epoch evidence issue_json_now current state close_comment close_status
  jqf -e 'any(.units[]; .stage=="awaiting-live-event")' "$UNITS" >/dev/null || return 0
  while read -r u; do
    id="$(jqf -r .id <<<"$u")"
    issue="$(jqf -r '.issue // empty' <<<"$u")"
    stored="$(jqf -ce '.acceptance // empty' <<<"$u" 2>/dev/null)"
    landed="$(jqf -r '.landed_at // empty' <<<"$u")"
    landed_epoch="$(ap_iso_epoch "$landed")"
    if [[ -z "$issue" || -z "$stored" || -z "$landed" || ! "$landed_epoch" =~ ^[0-9]+$ ]]; then
      to_supervisor "$id" "awaiting-live-event 记录缺 issue、验收块存档或落地时间（台账被手工改动过？）"
      continue
    fi
    ref="$(acceptance_live_event_ref "$stored")"
    mech="$(mechanism_registry_entry "$ref")"
    if [[ -z "$ref" || -z "$mech" ]]; then
      ( source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "live-event-unbound:$issue" \
          "live-event-unbound issue=#$issue status=已落地、待生效：live-event 项未引用登记表机制，无法自动观测，等 supervisor 处理" ) >/dev/null 2>&1 \
        || say "live-event wait unit=$id issue=$issue: unbound live-event, supervisor inbox unavailable"
      continue
    fi
    bound="$(jqf -r '.silence_hours // 24' <<<"$mech")"
    [[ "$bound" =~ ^[0-9]+$ ]] || bound=24
    if evidence="$(mechanism_event_after "$mech" "$landed_epoch")"; then
      issue_json_now="$(gh issue view "$issue" --json number,title,body,state,labels,comments 2>/dev/null)"
      if [[ -z "$issue_json_now" ]]; then
        say "live-event wait unit=$id issue=$issue: event observed but issue read failed; retry next tick"
        continue
      fi
      current="$(jqf -r '.body // ""' <<<"$issue_json_now" | acceptance_block_from_body || true)"
      if [[ "$current" != "$stored" ]]; then
        to_supervisor "$id" "M5：#$issue 验收块与派发/落地存档不一致，拒绝按 live-event 关票（验收项不得改动）"
        continue
      fi
      state="$(jqf -r '.state // ""' <<<"$issue_json_now")"
      if [[ "$state" != "OPEN" && "$state" != "CLOSED" ]]; then
        say "live-event wait unit=$id issue=$issue: event observed but issue state is unreadable; retry next tick"
        continue
      fi
      close_comment="结案：已落地 $(jqf -r '.land_sha // "见台账"' <<<"$u")（direct-main 车道）并观测到登记的生产事件 $ref。证据：${evidence:0:400}"
      if ! (
        source "$SCHEDULER_AGENT_LIB" || exit 1
        pipeline_system_close_comment_valid "$ROOT" "$issue" "$close_comment" false "${MAIN_HEAD:-origin/main}"
      ); then
        to_supervisor "$id" "M5：#$issue 已观测到 $ref，但落地 SHA 不满足 pipeline-system 结案证据，拒绝自动关票"
        continue
      fi
      close_status=0
      if [[ "$state" == "CLOSED" ]]; then
        if ! jqf -e --arg comment "$close_comment" 'any(.comments[]?; .body == $comment)' <<<"$issue_json_now" >/dev/null; then
          ( source "$SCHEDULER_AGENT_LIB" && guarded_write gh issue comment "$issue" --repo "$REPO" --body "$close_comment" ) >/dev/null 2>&1 || close_status=$?
        fi
      else
        ( source "$SCHEDULER_AGENT_LIB" && guarded_write gh issue close "$issue" --repo "$REPO" --reason completed --comment "$close_comment" ) >/dev/null 2>&1 || close_status=$?
      fi
      if (( close_status == 0 )); then
        set_unit "$id" "$(hist live-event-closed "$ref") | .stage=\"closed\""
        say "live-event close issue=$issue unit=$id event=$ref evidence=$(js "${evidence:0:200}")"
      else
        say "live-event wait unit=$id issue=$issue: event observed but gh issue close failed; retry next tick"
      fi
    elif (( NOW_EPOCH - landed_epoch > bound * 3600 )); then
      to_supervisor "$id" "M5：#$issue 落地后超过沉默上限 ${bound}h 仍未出现登记事件 $ref，已落地、待生效转 supervisor"
    fi
  done < <(jqf -c '.units[] | select(.stage=="awaiting-live-event")' "$UNITS")
}

# ---------- 4a. issue 收单：按空闲产能收（work-conserving），不是固定 3 个 ----------
# 2026-10-20 maintainer：8 个 worker 是雇来干活的。实测平均只 2/8 在干、近半数 tick 0 个在干，而 open issue 有 500+：
# 根因是收单只收 pipeline-system 标签、在途上限 3。现在：空闲槽位 = max_workers - 在跑 - 待派，按空槽收单；
# 非产品标签走直落车道，产品标签（默认 ready-for-agent）走 PR 车道（实现 → 推分支 → 流水线开 PR → 评审 → 合并 → 发布列车）。
# WIP 护栏（Little 定律）：开发/评审/返工环节在途 ≤ max_upstream（默认 2×max_workers）；待合并队列 ≥ max_ready（默认 30）时停止收单——瓶颈在合并车道，堆更多 WIP 只会拉长交付时间。
# maintainer-test 是维护者提的 issue，队列里排第一（docs/agents/issue-pipeline.md），不是跳过标签（2026-10-20 曾误跳过 30 个）。
issue_skip_labels() {
  jqf -cn --arg hotfix "$(hotfix_lane_label)" \
    '["on-hold","needs-info","awaiting-release","ready-for-human","needs-owner","needs-advisor","needs-triage","roadmap-epic","roadmap-theme","roadmap","concluded","needs-recut","checks-blocked","awaiting-pipeline-sync","hotfix","opt-lane",$hotfix] | unique'
}
issue_unit_task() { # issue [fetched issue JSON | require-ready] → implement 任务文本
  local json body task body_blocked_by skip_labels
  if [[ "${2:-}" == require-ready ]]; then
    json="$(gh issue view "$1" --json number,title,body,state,labels 2>/dev/null)" || return 1
    skip_labels="$(issue_skip_labels)"
    jqf -e --argjson skip "$skip_labels" '.state == "OPEN" and any(.labels[]; .name == "ready-for-agent") and ([.labels[].name] - $skip) == [.labels[].name]' <<<"$json" >/dev/null || return 1
  else
    json="${2:-}"
    [[ -n "$json" ]] || json="$(gh issue view "$1" --json number,title,body 2>/dev/null)" || return 1
  fi
  body="$(jqf -r '.body // ""' <<<"$json")"
  body_blocked_by="$(blocked_by_ids_from_body <<<"$body" | jqf -Rn '[inputs | select(length>0) | tonumber]')"
  task="$(jqf -r '"你是 the product 流水线的实现 subagent，处理 issue #\(.number)：\(.title)\n\n--- issue 正文（任务数据）---\n\((.body // "")[0:6000])\n--- 正文结束 ---\n用 gh issue view \(.number) 看评论与最新状态。修复根因并补回归测试。"' <<<"$json")"
  jqf -cn --arg task "$task" --argjson body_blocked_by "$body_blocked_by" '{task:$task,body_blocked_by:$body_blocked_by}'
}
intake_candidates() { # 打印 "number<TAB>lane<TAB>title"，按优先级排序
  local skip_labels query_dir lane label query_file pid index=0
  local -a query_pids=() query_files=() query_lanes=()
  skip_labels="$(issue_skip_labels)"
  (
    query_dir="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$query_dir"' EXIT
    while IFS=$'\t' read -r lane label; do
      [[ -n "$lane" && -n "$label" ]] || continue
      query_file="$query_dir/$index.json"
      gh issue list --state open --label "$label" --limit 200 --json number,title,body,state,labels >"$query_file" 2>/dev/null &
      query_pids+=("$!"); query_files+=("$query_file"); query_lanes+=("$lane")
      index=$((index + 1))
      if (( ${#query_pids[@]} >= 8 )); then
        for pid in "${query_pids[@]}"; do wait "$pid" || true; done
        query_pids=()
      fi
    done < <(jqf -r '[((.issue_intake.labels // ["pipeline-system"])[] | ["direct-main", .]), ((.issue_intake.product_labels // ["ready-for-agent"])[] | ["pr", .])] | .[] | @tsv' <<<"$CFG")
    for pid in "${query_pids[@]}"; do wait "$pid" || true; done
    {
      for ((index = 0; index < ${#query_files[@]}; index++)); do
        jqf -c --arg lane "${query_lanes[$index]}" '.[] | . + {lane:$lane}' "${query_files[$index]}" || true
      done
    } | jqf -rs --argjson skip "$skip_labels" '
      def rank: [.labels[].name] as $n
        | if ($n | index("maintainer-test")) then 0 elif ($n | index("priority:top")) then 1
          elif ($n | index("critical-path")) then 2  # 批次 STATE 的关键路径（#4363）：排在普通功能前、遗留后
          elif ($n | index("focus")) then 3 elif ($n | index("finish-first")) then 4 elif ($n | index("bug")) then 5
          elif ($n | index("legacy")) then 7 else 6 end;
      map(select(([.labels[].name] - $skip) == [.labels[].name]))
      | group_by(.number) | map(sort_by(.lane) | .[0])
      | sort_by([rank, -.number]) | .[] | "\(.number)\t\(.lane)\t\(.title | gsub("\t"; " "))\t\([.labels[].name] | tojson)\t({number,title,body,state,labels} | @base64)"'
  )
}
predecessor_candidates() { # 停在前置上的单元：先把前置 issue 批量拉进来（拓扑顺序）
  local dep issue skip_labels q response start
  local -a deps=() deps_filtered=() chunk=()
  local -A issue_in_ledger=()
  skip_labels="$(issue_skip_labels)"
  mapfile -t deps < <(jqf -r '[.units[] | select(.stage=="blocked-external" and .blocked_on != null) | .blocked_on] | unique | .[]' "$UNITS")
  while IFS= read -r issue; do [[ "$issue" =~ ^[0-9]+$ ]] && issue_in_ledger["$issue"]=1; done \
    < <(jqf -r '[.units[].issue | numbers] | unique | .[]' "$UNITS")
  for dep in "${deps[@]}"; do
    [[ "${issue_in_ledger[$dep]:-}" == 1 ]] || deps_filtered+=("$dep")
  done
  for ((start=0; start<${#deps_filtered[@]}; start+=20)); do
    chunk=("${deps_filtered[@]:start:20}"); q=""
    for dep in "${chunk[@]}"; do
      [[ "$dep" =~ ^[0-9]+$ ]] || continue
      q+=" i$dep: issue(number: $dep) { number title body state labels(first: 100) { nodes { name } } }"
    done
    [[ -n "$q" ]] || continue
    response="$(gh api graphql -F owner='{owner}' -F name='{repo}' -f query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {$q} }" 2>/dev/null)" || continue
    jqf -r --argjson skip "$skip_labels" '
      [.data.repository | to_entries[] | .value | select(type=="object")
        | {number,title,body:(.body // ""),state,labels:[.labels.nodes[]? | {name}]}]
      | sort_by(.number)[] | select(.state=="OPEN")
      | select(([.labels[].name] - $skip) == [.labels[].name])
      | "\(.number)\t\(if any(.labels[]; .name=="pipeline-system") then "direct-main" else "pr" end)\t\(.title | gsub("\t"; " "))\t\([.labels[].name] | tojson)\t(. | @base64)"' <<<"$response"
  done
}
existing_handoff_candidates() {
  local state_dir="${AGENT_HOME:-${HOME:-}/.zenoforge}/state"
  local files=( "$state_dir"/*.json )
  [[ -f "${files[0]}" ]] || return 0
  jqf -r '
    select(.state == "ready-for-agent" and (.scheduler_handoff.episode // "") != "")
    | (input_filename | capture("(?<n>[0-9]+)\\.json$").n | tonumber) as $n
    | [$n, "pr", "handoff", "[]"] | @tsv
  ' "${files[@]}" 2>/dev/null
}
handoff_open_pr() { # issue → matching PR rows from this tick's single census
  local n="$1"
  [[ -n "${HANDOFF_PR_CENSUS:-}" ]] || return 1
  jqf -c --slurpfile u "$UNITS" --arg n "$n" '
    [.[] | . as $p
      | [($p.body // "") | match("(?i)\\b(?:fix(?:es)?|closes|resolves)[[:space:]:]+#(?<id>[0-9]+)"; "g") | .captures[0].string] as $fixes
      | [($p.body // "") | match("(?im)^[[:space:]]*[-*]?[[:space:]]*refs[[:space:]:]+#(?<id>[0-9]+)"; "g") | .captures[0].string] as $refs
      | (if ($fixes | length) > 0 then $fixes else $refs end) as $claims
      | ([($p.headRefName // "") | capture("^agent/issue-(?<id>[0-9]+)$").id] + $claims | unique) as $issues
      | select(($issues | index($n)) != null)
      | $p + {ambiguousIssues: (($issues | length) > 1)}]
    | map(. as $p | select($p.ambiguousIssues or (any($u[0].units[]; .pr == $p.number and .issue != null and (.issue | tostring) != $n) | not)))
    | map({number,headRefName,ambiguousIssues,hotfix:any(.labels[]; .name == "hotfix")})
  ' <<<"$HANDOFF_PR_CENSUS"
}
handoff_include_pr() { # fallback after a failed census: inspect only a known PR
  local pr_number="$1" row
  row="$(gh pr view "$pr_number" --json number,headRefName,title,body,state,labels 2>/dev/null)" || row=""
  if ! jqf -e --argjson pr "$pr_number" 'type=="object" and .number==$pr and (.headRefName|type)=="string" and (.state | IN("OPEN","CLOSED","MERGED")) and (.labels | type)=="array" and all(.labels[]; (.name | type)=="string")' <<<"$row" >/dev/null; then
    jqf --argjson pr "$pr_number" '.units |= map(if .pr == $pr then .hold_handoff_lookup_pending=true | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
    return 1
  fi
  jqf --argjson pr "$pr_number" '.units |= map(if .pr == $pr then del(.hold_handoff_lookup_pending) | if ((.hold_handoff_wait_issues // []) | length) == 0 then del(.hold_handoff_waiting) else . end else . end)' "$UNITS" | write_state "$UNITS"
  if jqf -e '.state == "OPEN"' <<<"$row" >/dev/null; then
    HANDOFF_PR_CENSUS="$(jqf -c --slurpfile row <(printf '%s' "$row") '. + [$row[0]]' <<<"$HANDOFF_PR_CENSUS")"
  fi
}
register_new_issues() {
  local enabled live pending idle upstream max_up ready_q max_ready want added=0 n lane title labels task_record task body_blocked_by branch busy handoff state_file acceptance
  local episode existing_id existing_pr prior_pr pr_changed pr_state lane_policy handoff_all handoff_pr handoff_branch recovery_sha
  local cached_prs busy_prs issue64
  local existing_only="${1:-0}" only_pred=0 ids lookup handoff_rows matches ids_state pr_number known_prs known_failed hotfix_prs prior_worktree prior_reason episode_hash related_id related_hash unsafe_clones
  local issue_json parent_reason parent_status parent_transition_status
  hotfix_issue_numbers || say "hotfix issue list unavailable; linked issue PRs may not be classified this tick"
  enabled="$(jqf -r 'if .issue_intake.enabled == false then "false" else "true" end' <<<"$CFG")"
  [[ "$enabled" == true || "$existing_only" == 1 ]] || return 0
  if (( existing_only )); then
    # Existing units consume their handoff even when new intake is at capacity.
    handoff_rows="$(existing_handoff_candidates)"
    [[ -n "$handoff_rows" ]] || return 0
    if [[ "${2:-}" != reuse ]]; then
      HANDOFF_CENSUS_PARTIAL=0; HANDOFF_WAIT_PRS='[]'; HANDOFF_WAIT_BRANCHES='[]'
      cached_prs="$(tick_prs 2>/dev/null || true)"
      if [[ -n "$cached_prs" ]] && jqf -e 'type=="array" and length < 300' <<<"$cached_prs" >/dev/null; then
        HANDOFF_PR_CENSUS="$(jqf -c '[.[] | {number,headRefName,title,body,labels}]' <<<"$cached_prs")"
      else
        HANDOFF_PR_CENSUS="$(gh pr list --state open --limit 500 --json number,headRefName,title,body,labels 2>/dev/null)" || HANDOFF_PR_CENSUS=""
      fi
      jqf -e 'type == "array" and all(.[]; (.number | type)=="number" and (.labels | type)=="array" and all(.labels[]; (.name | type)=="string"))' <<<"${HANDOFF_PR_CENSUS:-}" >/dev/null || HANDOFF_PR_CENSUS=""
      if [[ -z "$HANDOFF_PR_CENSUS" ]]; then
        HANDOFF_CENSUS_PARTIAL=1; HANDOFF_PR_CENSUS='[]'
        while read -r pr_number; do handoff_include_pr "$pr_number" || true; done < <(jqf -r '[.units[] | select((.stage | IN("merged","landed","closed","done","wontfix","duplicate")) | not) | .pr | select(type=="number")] | unique | .[]' "$UNITS")
      else
        jqf '.units |= map(if .hold_handoff_lookup_pending == true then del(.hold_handoff_lookup_pending) | if ((.hold_handoff_wait_issues // []) | length) == 0 then del(.hold_handoff_waiting) else . end else . end)' "$UNITS" | write_state "$UNITS"
      fi
    fi
    want=1000000000; busy=""
  else
  live="$(live_workers)"
  pending="$(jqf '[.units[] | select(.stage | test("-pending$"))] | length' "$UNITS")"
  idle=$(( MAX - live - pending ))
  (( idle > 0 )) || return 0
  max_up="$(jqf -r ".issue_intake.max_upstream // $((2 * MAX))" <<<"$CFG")"; [[ "$max_up" =~ ^[0-9]+$ ]] || max_up=$((2 * MAX))
  max_ready="$(jqf -r '.issue_intake.max_ready // 30' <<<"$CFG")"; [[ "$max_ready" =~ ^[0-9]+$ ]] || max_ready=30
  upstream="$(jqf '[.units[] | select(.stage | test("^(implement|review|rereview|repair)(-pending)?$"))] | length' "$UNITS")"
  ready_q="$(jqf '[.units[] | select(.stage=="ready-to-merge" or .stage=="landing")] | length' "$UNITS")"
  # 合并车道是约束时停收新单，但挡着别人的前置照收：它们不收，停着的后继永远放不开（10-22 49 个单元停在前置上，
  # 其中 10 个前置从没进过流水线，因为 intake 一直 held）。
  want=$(( max_up - upstream )); (( idle < want )) && want=$idle
  if (( ready_q >= max_ready )); then
    say "intake held: $ready_q units wait to merge (max_ready $max_ready); the merge lane is the constraint; predecessors still admitted"
    only_pred=1; want=$idle
  fi
  (( want > 0 )) || { say "intake held: $upstream units upstream (max_upstream $max_up)"; return 0; }
  # 已有 open PR 的 issue 不再收（#3957 已由 #3958 实现，分支名却不是 agent/issue-N）：看分支、标题和正文里是否提到它。
  if [[ -n "${HANDOFF_PR_CENSUS:-}" && "${HANDOFF_CENSUS_PARTIAL:-0}" != 1 ]]; then
    busy="$(jqf -r '.[] | "\(.headRefName) \(.title) \(.body // "")"' <<<"$HANDOFF_PR_CENSUS")"
  else
    busy_prs="$(tick_prs 2>/dev/null)" || busy_prs=""
    if [[ -n "$busy_prs" ]]; then
      busy="$(jqf -r '.[] | "\(.headRefName) \(.title) \(.body // "")"' <<<"$busy_prs")"
    else
      busy="$(gh pr list --state open --limit 200 --json headRefName,title,body --jq '.[] | "\(.headRefName) \(.title) \(.body // "")"' 2>/dev/null)" || return 0
    fi
  fi
  fi
  while IFS=$'\t' read -r n lane title labels issue64; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( added < want )) || break
    issue_json=""
    [[ -n "$issue64" ]] && issue_json="$(printf '%s' "$issue64" | base64 -d 2>/dev/null)" || true
    state_file="${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json"
    episode="$(jqf -r 'select(.state == "ready-for-agent") | .scheduler_handoff.episode // empty' "$state_file" 2>/dev/null)"
    handoff_all="$(jqf -c 'select(.state == "ready-for-agent") | .scheduler_handoff // {}' "$state_file" 2>/dev/null)"
    [[ -n "$handoff_all" ]] || handoff_all='{}'
    handoff_pr="$(jqf -r '.open_pr // empty' <<<"$handoff_all")"
    handoff_branch="$(jqf -r '.open_branch // empty' <<<"$handoff_all")"
    if [[ -n "$episode" ]]; then
      if (( existing_only )); then
        # An unavailable PR lookup must not release an already known unit's old approval.
        jqf --argjson n "$n" --arg episode "$episode" '.units |= map(if (.issue == $n or .branch == ("agent/issue-" + ($n | tostring))) and .hold_handoff_episode != $episode then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
      fi
      # Recorded PRs can be outside the census or attached to an existing unit.
      # Read their current labels before reusing them, rather than inferring
      # ownership from an old hold snapshot.
      known_prs="$(jqf -c --argjson n "$n" --arg pr "$handoff_pr" '
        ([.units[] | select(.issue == $n or .branch == ("agent/issue-" + ($n | tostring))) | .pr | select(type == "number")]
          + (if ($pr | test("^[0-9]+$")) then [($pr | tonumber)] else [] end)) | unique' "$UNITS")"
      known_failed=0
      while read -r pr_number; do
        if ! jqf -e --argjson pr "$pr_number" 'any(.[]; .number == $pr)' <<<"${HANDOFF_PR_CENSUS:-[]}" >/dev/null; then
          handoff_include_pr "$pr_number" || known_failed=1
        fi
      done < <(jqf -r '.[]' <<<"$known_prs")
      if (( known_failed )); then
        HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$known_prs" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        HANDOFF_WAIT_BRANCHES="$(jqf -c --arg branch "$handoff_branch" 'if $branch == "" then . else (. + [$branch] | unique) end' <<<"${HANDOFF_WAIT_BRANCHES:-[]}")"
        jqf --argjson n "$n" --argjson prs "$known_prs" '.units |= map(if .issue == $n or .branch == ("agent/issue-" + ($n | tostring)) or ((.pr // null) as $pr | $prs | index($pr)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
        continue
      fi
      if [[ "$handoff_pr" =~ ^[0-9]+$ ]] && ! jqf -e --argjson pr "$handoff_pr" 'any(.[]; .number == $pr)' <<<"${HANDOFF_PR_CENSUS:-[]}" >/dev/null; then
        handoff_pr=""; handoff_branch=""
      fi
      # A PR can appear after the handoff, or use a non-agent branch.
      lookup="$(handoff_open_pr "$n")" || { [[ -n "$handoff_pr" ]] && lookup='[]' || continue; }
      if [[ "$handoff_pr" =~ ^[0-9]+$ ]]; then
        lookup="$(jqf -c --argjson pr "$handoff_pr" --slurpfile census <(printf '%s' "$HANDOFF_PR_CENSUS") '
          if any(.[]; .number == $pr) then . else
            . + [$census[0][] | select(.number == $pr) | {number,headRefName,ambiguousIssues:false,hotfix:any(.labels[]; .name == "hotfix")}]
          end' <<<"$lookup")"
      fi
      hotfix_prs="$(jqf -c --argjson prs "$known_prs" '[.[] | select(.number as $p | $prs | index($p)) | select(any(.labels[]; .name == "hotfix")) | .number]' <<<"${HANDOFF_PR_CENSUS:-[]}")"
      if jqf -e --argjson known "$hotfix_prs" 'any(.[]; .hotfix == true) or ($known | length > 0)' <<<"$lookup" >/dev/null; then
        ids="$(jqf -c --argjson known "$hotfix_prs" '([.[].number] + $known) | unique' <<<"$lookup")"
        HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$ids" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        HANDOFF_WAIT_BRANCHES="$(jqf -c --argjson prs "$ids" --slurpfile census <(printf '%s' "$HANDOFF_PR_CENSUS") --arg branch "$handoff_branch" '
          . + [$census[0][] | select(.number as $p | $prs | index($p)) | .headRefName | select(type=="string" and length>0)] + (if $branch == "" then [] else [$branch] end) | unique' <<<"${HANDOFF_WAIT_BRANCHES:-[]}")"
        jqf --argjson n "$n" --argjson prs "$ids" '.units |= map(if .issue == $n or .branch == ("agent/issue-" + ($n | tostring)) or ((.pr // null) as $pr | $prs | index($pr)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
        continue
      fi
      # Clear this issue's wait from a PR once its successfully read association
      # no longer points here; other handoffs may still be waiting on the PR.
      ids="$(jqf -c '[.[].number] | unique' <<<"$lookup")"
      jqf --argjson n "$n" --argjson prs "$ids" '.units |= map(
        if ((.hold_handoff_wait_issues // []) | index($n)) != null and .issue != $n
          and .hold_handoff_lookup_pending != true and ((.pr // null) as $pr | $prs | index($pr)) == null
        then .hold_handoff_wait_issues |= map(select(. != $n))
          | if (.hold_handoff_wait_issues | length) == 0 then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end
        else . end)' "$UNITS" | write_state "$UNITS"
      # Individually read ledger PRs can protect their old approvals, but do not
      # establish that an unregistered PR for this issue does not also exist.
      if [[ "${HANDOFF_CENSUS_PARTIAL:-0}" == 1 ]]; then
        HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$ids" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        jqf --argjson n "$n" --argjson prs "$ids" '.units |= map(if .issue == $n or ((.pr // null) as $pr | $prs | index($pr)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
        continue
      fi
      matches="$(jqf 'length' <<<"$lookup")"
      if (( matches > 1 )) || jqf -e 'any(.[]; .ambiguousIssues == true)' <<<"$lookup" >/dev/null; then
        ids="$(jqf -c '[.[].number] | sort' <<<"$lookup")"
        HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$ids" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        ids_state="$(jqf -r 'map(tostring) | join("-")' <<<"$ids")"
        jqf --argjson n "$n" --argjson prs "$ids" '.units |= map(if .issue == $n or ((.pr // null) as $pr | $prs | index($pr)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
        (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "handoff-pr-ambiguous:$n:$ids" "handoff-pr-ambiguous issue=#$n status=prs-$ids_state prs=$ids") \
          || say "handoff issue #$n: could not notify supervisor about ambiguous PRs $ids"
        continue
      elif (( matches == 1 )); then
        handoff_pr="$(jqf -r '.[0].number' <<<"$lookup")"
        handoff_branch="$(jqf -r '.[0].headRefName' <<<"$lookup")"
      fi
    fi
    handoff="$(jqf -c --arg n "$n" '(.scheduler_handoff // {}) | select((.start_ref // "") | test("^rescued/.*(issue-|hand-)" + $n + "([^0-9]|$)")) | select((.start_sha // "") | test("^[0-9a-f]{40}$"))' "$state_file" 2>/dev/null)"
    [[ -n "$handoff" ]] || handoff='{}'
    existing_id="$(jqf -r --argjson n "$n" --arg pr "$handoff_pr" '[.units[] | select(.issue == $n or ($pr != "" and ((.pr // "") | tostring) == $pr))] | sort_by([if ($pr != "" and ((.pr // "") | tostring) == $pr) then 0 else 1 end, if (.stage | IN("parked","supervisor-review","blocked-external","done","closed","landed","merged","wontfix","duplicate")) then 1 else 0 end]) | .[0].id // empty' "$UNITS")"
    if [[ -n "$existing_id" ]]; then
      (( existing_only )) || continue
      [[ -n "$episode" ]] || continue
      ids="$(jqf -c --argjson n "$n" --arg pr "$handoff_pr" '[.units[] | select(.issue == $n or ($pr != "" and ((.pr // "") | tostring) == $pr)) | .id]' "$UNITS")"
      if jqf -e --argjson n "$n" --arg pr "$handoff_pr" --arg episode "$episode" 'all(.units[] | select(.issue == $n or ($pr != "" and ((.pr // "") | tostring) == $pr)); .hold_handoff_episode == $episode) and ($pr == "" or any(.units[]; ((.pr // "") | tostring) == $pr))' "$UNITS" >/dev/null; then
        jqf --argjson ids "$ids" --argjson n "$n" '.units |= map(if (.id as $id | $ids | index($id)) != null then .hold_handoff_wait_issues = ((.hold_handoff_wait_issues // []) | map(select(. != $n))) | if (.hold_handoff_wait_issues | length) == 0 and .hold_handoff_lookup_pending != true then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end else . end)' "$UNITS" | write_state "$UNITS"
        continue
      fi
      HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$(jqf -c '[.[].number]' <<<"$lookup")" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
      lane="$(unit_field "$existing_id" '.lane // empty')"
      # Block the old approval while any matching unit still has a live owner.
      jqf --argjson ids "$ids" --argjson n "$n" '.units |= map(if (.id as $id | $ids | index($id)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
      jqf -e --argjson ids "$ids" 'any(.workers[]; (.unit as $id | $ids | index($id)) != null and .harvested != true)' "$WORKERS" >/dev/null && continue
      # A worker which has already started may have read the old issue; do not
      # consume the new episode until it exits and the continuation can run.
      jqf -e --argjson ids "$ids" 'any(.units[]; (.id as $id | $ids | index($id)) != null and (.stage == "landing" or .self_check_pid != null or .advisor_pid != null or .precheck_pid != null or (.stage == "blocked-external" and .blocked_on != null)))' "$UNITS" >/dev/null && continue
      # Any related unit may contain work that the chosen unit cannot deliver.
      unsafe_clones=0
      episode_hash="$(printf '%s' "$episode" | sha256sum)"; episode_hash="${episode_hash%% *}"
      while IFS= read -r related_id; do
        prior_worktree="$WT_ROOT/wt-$related_id"
        if prior_reason="$(worktree_cleanup_block_reason "$prior_worktree")"; then
          unsafe_clones=1
          related_hash="$(printf '%s' "$related_id" | sha256sum)"; related_hash="${related_hash%% *}"
          (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "handoff-preserved-clone:$n:$episode:$related_id" \
            "handoff-preserved-clone issue=#$n status=episode-$episode_hash-unit-$related_hash unit=$related_id worktree=$prior_worktree reason=$prior_reason") \
            || say "handoff issue #$n: could not notify supervisor about the preserved clone"
        fi
      done < <(jqf -r '.[]' <<<"$ids")
      (( unsafe_clones == 0 )) || continue
      prior_pr="$(unit_field "$existing_id" '.pr // empty')"
      existing_pr="$prior_pr"; pr_changed=false
      if [[ "$handoff_pr" =~ ^[0-9]+$ ]]; then existing_pr="$handoff_pr"; fi
      pr_state=""
      if [[ "$existing_pr" =~ ^[0-9]+$ ]]; then
        pr_state="$(pr_view "$existing_pr" state)" || continue
      fi
      if [[ "$pr_state" == OPEN ]]; then
        lane="$(classify_lane "$existing_pr")" || { say "hold handoff issue #$n: cannot classify PR#$existing_pr; retry next tick"; continue; }
        lane_policy="$(lane_policy_blob)"
        [[ "$existing_pr" == "$prior_pr" ]] || pr_changed=true
      else
        [[ -n "$lane" ]] || lane=pr
        pr_changed=true
      fi
    else
      if [[ -n "$episode" ]]; then
        HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$(jqf -c '[.[].number]' <<<"$lookup")" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
      fi
      (( existing_only )) && continue
      if [[ -n "$episode" && "$handoff_pr" =~ ^[0-9]+$ && -n "$handoff_branch" ]]; then
        pr_state="$(pr_view "$handoff_pr" state)" || continue
        if [[ "$pr_state" == OPEN ]]; then
          lane="$(classify_lane "$handoff_pr")" || { say "hold handoff issue #$n: cannot classify PR#$handoff_pr; retry next tick"; continue; }
          lane_policy="$(lane_policy_blob)"
        else
          handoff_pr=""
        fi
      else
        handoff_pr=""
      fi
      [[ -n "$handoff_pr" ]] || ! grep -qE "(#|issue-)${n}([^0-9]|\$)" <<<"$busy" || continue
    fi
    if (( ! existing_only )) && [[ -z "$episode" ]]; then
      [[ -n "$issue_json" ]] || issue_json="$(gh issue view "$n" --json number,title,body,state,labels 2>/dev/null)" || continue
      if parent_reason="$(scheduler_issue_intake_parent_reason "$n" "$issue_json")"; then
        if scheduler_issue_transition "$n" needs-triage "intake-parent:$parent_reason" . 0 "$issue_json"; then
          say "intake issue #$n -> needs-triage (parent: $parent_reason)"
        else
          parent_transition_status=$?
          # roadmap_ensure_issue_parent returns 3 only for a confirmed roadmap container.
          if (( parent_transition_status == 3 )); then
            if scheduler_issue_transition "$n" tracker "intake-parent:roadmap-container:$parent_reason" '.tracker_parent = true' 0 "$issue_json"; then
              say "intake issue #$n -> tracker (roadmap container parent: $parent_reason)"
            else
              say "intake issue #$n held: roadmap container parent tracker update failed"
            fi
          else
            say "intake issue #$n held: parent detected but needs-triage label update failed"
          fi
        fi
        continue
      else
        parent_status=$?
        if (( parent_status != 1 )); then
          say "intake issue #$n deferred: could not verify parent status"
          continue
        fi
      fi
    fi
    if (( ! existing_only )) && [[ -z "$episode" && -z "${existing_id:-}" && "$lane" == direct-main ]]; then
      acceptance="$(jqf -r '.body // ""' <<<"$issue_json" | acceptance_block_from_body || true)"
      # M5（#4501）：pipeline-system 票的验收块必须绑定 live-event 到登记机制，否则退回补写。
      if ! acceptance_has_live_event "${acceptance:-}" || ! acceptance_live_event_registered "${acceptance:-}"; then
        if scheduler_issue_transition "$n" needs-info "m5-live-event-missing" . 0 "$issue_json"; then
          gh issue comment "$n" --body "M5 生效即验收（#4495/#4501）：pipeline-system 票的验收块（\`\`\`json 围栏内的 acceptance 数组）必须包含一项 id=live-event，并通过 event 字段或登记表 acceptance_item_ids 绑定到 engine/state/mechanism-registry.json 中的机制。补写后重新加 ready-for-agent 标签。" >/dev/null 2>&1
          say "intake issue #$n -> needs-info (M5 live-event missing)"
        else
          say "intake issue #$n: M5 live-event relabel failed; retry next tick"
        fi
        continue
      fi
    fi
    if (( existing_only )) || [[ -n "$episode" ]]; then
      task_record="$(issue_unit_task "$n" require-ready)" || continue
    else
      task_record="$(issue_unit_task "$n" "$issue_json")" || continue
    fi
    task="$(jqf -r .task <<<"$task_record")"
    body_blocked_by="$(jqf -c '.body_blocked_by // []' <<<"$task_record")"
    if [[ "$lane" == direct-main ]]; then branch="agent/auto-issue-$n"; else branch="agent/issue-$n"; fi
    recovery_sha="$(jqf -r '.worktree_sha // .start_sha // empty' <<<"$handoff_all")"
    if [[ "$recovery_sha" =~ $SHA_RE ]]; then
      if [[ "$lane" == pr ]]; then branch="agent/issue-$n-recovered-${recovery_sha:0:12}"
      else branch="agent/auto-issue-$n-recovered-${recovery_sha:0:12}"; fi
    fi
    if [[ -n "$existing_id" ]]; then
      jqf --arg id "$existing_id" --argjson n "$n" --arg episode "$episode" --arg pr_state "$pr_state" --arg task "$task" --argjson body_blocked_by "$body_blocked_by" \
        --arg lane "$lane" --arg lane_policy "${lane_policy:-}" --arg branch "$branch" --arg existing_pr "$existing_pr" --arg handoff_branch "$handoff_branch" --argjson pr_changed "$pr_changed" --argjson ids "$ids" --argjson handoff "$handoff" --argjson handoff_all "$handoff_all" --arg at "$STAMP" \
        '.units |= map(if (.id as $unit | $ids | index($unit)) != null then
          .hold_handoff_wait_issues = ((.hold_handoff_wait_issues // []) | map(select(. != $n)))
          | if (.hold_handoff_wait_issues | length) == 0 and .hold_handoff_lookup_pending != true then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end
        else . end | if .id != $id then
          if (.id as $other | $ids | index($other)) != null then
            .stage="parked" | .approved_sha=null | .hold_handoff_episode=$episode
            | .note=("Superseded by handoff unit " + $id)
          else . end
        else
          .issue = $n | .body_blocked_by = $body_blocked_by | .hold_handoff_episode = $episode | .approved_sha = null | .reviewed_sha = null | .reviewed_pr_head = null | del(.blocked_on, .self_fix_pending)
          | if $pr_changed then del(.ci_adopt_head, .ci_adopt_at, .ci_sync_head, .ci_ready_sha, .ci_ready_at, .ci_held_sha, .ci_wip_wait, .gated, .lane_policy, .product_paths) else . end
          | .history = ((.history // []) + [{stage:"supervisor-requeue",result:"ownerless hold handoff; read issue comments",at:$at}])
          | if $pr_state == "OPEN" then
              .stage = "repair-pending" | .pr = ($existing_pr | tonumber) | .lane = $lane | .lane_policy = $lane_policy | del(.product_paths)
              | if $handoff_branch != "" then .branch = $handoff_branch else . end
              | .repair_hint = "Read the issue comments for the ownerless hold handoff and complete the existing PR."
            else
              .stage = "implement-pending" | .task = $task | .lane = $lane | .branch = $branch
              | del(.pr, .handoff_start_ref, .handoff_start_sha, .handoff_start_applied)
              | if $handoff.start_ref then .handoff_start_ref = $handoff.start_ref | .handoff_start_sha = $handoff.start_sha else . end
            end
          | del(.handoff_worktree, .handoff_worktree_sha, .handoff_worktree_dirty, .handoff_worktree_applied, .handoff_integration_sha, .handoff_original_pr_head, .handoff_delivery_verified_sha)
          | del(.handoff_start_ref, .handoff_start_sha, .handoff_start_applied)
          | if $handoff.start_ref then .handoff_start_ref = $handoff.start_ref | .handoff_start_sha = $handoff.start_sha else . end
          | if (($handoff_all.worktree_sha // "") | test("^[0-9a-f]{40}$")) then
              .handoff_worktree = $handoff_all.worktree | .handoff_worktree_sha = $handoff_all.worktree_sha | .handoff_worktree_dirty = $handoff_all.worktree_dirty
            else . end
          end)' "$UNITS" | write_state "$UNITS"
      say "hold handoff issue #$n resumed existing unit=$existing_id"
    else
      if [[ "$handoff_pr" =~ ^[0-9]+$ ]]; then branch="$handoff_branch"; fi
      jqf --argjson n "$n" --arg title "$title" --argjson labels "${labels:-[]}" --arg task "$task" --argjson body_blocked_by "$body_blocked_by" --arg lane "$lane" --arg lane_policy "${lane_policy:-}" --arg branch "$branch" --arg episode "$episode" --argjson handoff "$handoff" --argjson handoff_all "$handoff_all" \
        --arg pr "$handoff_pr" --arg acceptance "${acceptance:-}" \
        '.units += [{id:("issue-"+($n|tostring)), issue:$n, title:$title, labels:$labels, stage:"implement-pending", lane:$lane, branch:$branch, task:$task, body_blocked_by:$body_blocked_by, history:[],hold_handoff_episode:$episode}
          + (if $acceptance != "" then {acceptance:($acceptance | fromjson)} else {} end)
          + (if $pr != "" then {pr:($pr | tonumber),stage:"repair-pending",lane_policy:$lane_policy,repair_hint:"Read the issue comments for the ownerless hold handoff and complete the existing PR."} else {} end)
          + (if (($handoff_all.worktree_sha // "") | test("^[0-9a-f]{40}$")) then {handoff_worktree:$handoff_all.worktree,handoff_worktree_sha:$handoff_all.worktree_sha,handoff_worktree_dirty:$handoff_all.worktree_dirty} else {} end)
          + (if $handoff.start_ref then {handoff_start_ref:$handoff.start_ref,handoff_start_sha:$handoff.start_sha} else {} end)]' \
        "$UNITS" | write_state "$UNITS"
    fi
    added=$((added+1))
    say "intake issue #$n -> implement-pending ($lane)"
  done < <(if (( existing_only )); then printf '%s\n' "$handoff_rows"; else predecessor_candidates; (( only_pred )) || intake_candidates; fi)
  if (( ! existing_only && added == 0 && ! only_pred )) && [[ ! -f "$A/.idle-alert" || -n "$(find "$A/.idle-alert" -mmin +60 2>/dev/null)" ]]; then
    touch "$A/.idle-alert"
    echo "[$STAMP] IDLE-CAPACITY live=$live/$MAX pending=$pending: intake found no eligible issue (labels or skip labels too narrow?)" >> "$A/alerts/slo.md"
  fi
}

# ---------- 4b. 环节 SLO 护栏：每个等待环节有预算，超了写 alerts/slo.md（每单元每次停留只报一次） ----------
handoff_pr_waiting() { # PR issue: unresolved handoffs retain every associated PR
  local pr_number="$1" n="${2:-0}" state_file episode
  jqf -e --argjson pr "$pr_number" 'index($pr) != null' <<<"${HANDOFF_WAIT_PRS:-[]}" >/dev/null && return 0
  jqf -e --argjson pr "$pr_number" --argjson n "$n" 'any(.units[]; .hold_handoff_waiting == true and (.pr == $pr or .issue == $n or ((.hold_handoff_wait_issues // []) | index($n)) != null))' "$UNITS" >/dev/null && return 0
  (( n > 0 )) || return 1
  state_file="${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json"
  episode="$(jqf -r 'select(.state == "ready-for-agent") | .scheduler_handoff.episode // empty' "$state_file" 2>/dev/null)"
  [[ -n "$episode" ]] || return 1
  ! jqf -e --argjson n "$n" --arg episode "$episode" 'any(.units[]; .issue == $n and .hold_handoff_episode == $episode)' "$UNITS" >/dev/null
}
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
优化类 ticket（声称浪费、延迟或竞态并给了量化数字）：第一步用现有数据复现这些数字——issue 自带的证据、账本、本 checkout 的文件与 git 历史，不发新的外部请求；测量窗口从被测机制最后一次改动之后开始（用 git log 定位），窗口跨过该改动测的是旧机制。把测到的数字和算法写进报告。复现不了就不实现：报告第一行写 OBSOLETE: <测到的数字、窗口、数据来源>，流水线据此关单。复现了就带着测量结果实现，它就是验收对比的基线。'
HOTPATCH_HINT='发布阻断：这个 PR 的补丁已作为热修跑在生产上（cihost /srv/app/release-drift-carried.tsv），但没合进 main，所有 Example 发布都因此停住。先 git merge origin/main 解决冲突：冲突时以生产已验证的行为为准，同时保留 main 上的后续修复；保持改动最小，补/修回归测试，推送。'
orphan_issue_states() { # issue numbers... → {"number":"OPEN|CLOSED"} from one targeted GraphQL census
  (( $# > 0 )) || { printf '{}\n'; return 0; }
  local query="" number
  for number in "$@"; do
    [[ "$number" =~ ^[0-9]+$ ]] || continue
    query+=" i$number: issue(number: $number) { state }"
  done
  [[ -n "$query" ]] || { printf '{}\n'; return 0; }
  gh api graphql -F owner='{owner}' -F name='{repo}' \
    -f query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {$query} }" \
    --jq '.data.repository | to_entries | map(select(.value != null) | {key:(.key[1:]),value:.value.state}) | from_entries' 2>/dev/null
}
reconcile_orphan_prs() {
  local last prs states_by_number orphan_issue_numbers blocked rows n prn branch draft title issue_state gated reg=0 max="${ORPHAN_REGISTER_MAX:-3}" agent_left=0 foreign=0 now
  local -a issue_numbers=()
  last="$(cat "$A/orphan-check.epoch" 2>/dev/null)"
  [[ "$last" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - last < ${ORPHAN_CHECK_SECONDS:-1800} )) && return 0
  echo "$NOW_EPOCH" > "$A/orphan-check.epoch"
  prs="$(tick_prs)" || return 0
  blocked="$(jqf -c '[.units[] | select(.stage=="blocked-external" and .blocked_on != null) | .blocked_on]' "$UNITS")"
  orphan_issue_numbers="$(jqf -c --slurpfile u "$UNITS" '
      ($u[0].units | map(.pr) | map(select(. != null))) as $known
      | [.[] | select(.number as $n | $known | index($n) | not)
          | (try (.headRefName | capture("^agent/(auto-)?issue-(?<n>[0-9]+)$").n | tonumber) catch null)
          | select(. != null)] | unique' <<<"$prs")" || return 0
  mapfile -t issue_numbers < <(jqf -r '.[]' <<<"$orphan_issue_numbers")
  if (( ${#issue_numbers[@]} > 0 )); then
    states_by_number="$(orphan_issue_states "${issue_numbers[@]}")" || return 0
  else
    states_by_number='{}'
  fi
  rows="$(jqf -r --slurpfile u "$UNITS" --argjson b "$blocked" --argjson states "$states_by_number" '
      ($u[0].units | map(.pr) | map(select(. != null))) as $known
      | map(select(.number as $n | $known | index($n) | not))
      | map((try (.headRefName | capture("^agent/(auto-)?issue-(?<n>[0-9]+)$").n | tonumber) catch null) as $i
          | . + {issue:$i})
      | map(.issue as $i | . + {blocks: ($i != null and ($b | index($i)) != null), issue_state: (if $i != null then ($states[($i | tostring)] // "UNKNOWN") else "UNKNOWN" end)})
      | sort_by([(if .blocks then 0 else 1 end), .number]) | .[]
      | "\(.number)\t\(.headRefName)\t\(.isDraft)\t\(.issue // "")\t\(.title | gsub("\t"; " "))\t\(.issue_state)"' <<<"$prs")"
  now="$(date -u +%FT%TZ)"
  # 生产热修的源 PR 先收（任意分支），它们挡着所有发布（release_train.sh 写 release-blockers.json）。
  for prn in $(jqf -r '.blockers[]?' "$A/release-blockers.json" 2>/dev/null); do
    [[ "$prn" =~ ^[0-9]+$ ]] || continue
    if [[ -n "${HANDOFF_PR_CENSUS:-}" && "${HANDOFF_CENSUS_PARTIAL:-0}" == 1 ]]; then
      handoff_include_pr "$prn" || continue
      register_new_issues 1 reuse
    fi
    handoff_pr_waiting "$prn" 0 && continue
    jqf -e --argjson p "$prn" 'any(.units[]; .pr == $p)' "$UNITS" >/dev/null && continue
    jqf -e --argjson p "$prn" 'any(.[]; .number == $p)' <<<"$prs" >/dev/null || continue
    jqf --argjson prn "$prn" --arg b "$(jqf -r --argjson p "$prn" '.[] | select(.number == $p) | .headRefName' <<<"$prs")" \
      --arg t "$(jqf -r --argjson p "$prn" '.[] | select(.number == $p) | .title' <<<"$prs")" --arg now "$now" --arg h "$HOTPATCH_HINT" \
      '.units += [{id:("pr-"+($prn|tostring)), title:$t, stage:"review-pending", pr:$prn, branch:$b, critical:true, hotpatch:true, repair_hint:$h,
        note:"release blocker: production hot patch not on main; forward-port and merge first",
        history:[{stage:"orphan-registered", result:"release blocker (carried production hot patch)", at:$now}]}]' "$UNITS" | write_state "$UNITS"
    say "release-blocker PR#$prn registered (carried production hot patch)"
  done
  while IFS=$'\t' read -r prn branch draft n title issue_state; do
    [[ "$prn" =~ ^[0-9]+$ ]] || continue
    jqf -e --argjson p "$prn" 'any(.units[]; .pr == $p)' "$UNITS" >/dev/null && continue
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then foreign=$((foreign + 1)); continue; fi
    handoff_pr_waiting "$prn" "$n" && { agent_left=$((agent_left + 1)); continue; }
    if [[ "$issue_state" == CLOSED ]]; then
      tick_prs_changed
      gh pr close "$prn" --comment "Autopilot: issue #$n is closed; this PR outside the pipeline ledger is superseded." >/dev/null 2>&1 \
        && say "orphan PR#$prn closed: issue #$n is closed"
      continue
    fi
    if jqf -e --argjson n "$n" 'any(.units[]; .issue == $n)' "$UNITS" >/dev/null; then
      # 台账单元自己没有 PR 又没结束时，这个孤儿 PR 可能就是唯一的实现：不关，也不再收一个单元，留给 supervisor。
      if ! jqf -e --argjson n "$n" 'any(.units[]; .issue == $n and (.pr != null or (.stage | test("^(merged|landed|closed|done)$"))))' "$UNITS" >/dev/null; then
        agent_left=$((agent_left + 1)); say "orphan PR#$prn kept: issue #$n has a ledger unit without its own PR"; continue
      fi
      tick_prs_changed
      gh pr close "$prn" --comment "Autopilot: issue #$n is handled by $(jqf -r --argjson n "$n" '[.units[] | select(.issue == $n)][0].id' "$UNITS") in the pipeline ledger; this older PR is superseded." >/dev/null 2>&1 \
        && say "orphan PR#$prn closed: issue #$n already has a ledger unit"
      continue
    fi
    if (( reg >= max )); then agent_left=$((agent_left + 1)); continue; fi
    # 收编不 ready：draft 的 agent/issue-* 孤儿只加门控标签，批准且占到名额后才由名额门 ready；非 draft 孤儿保持旧路径直到第一次 repair。
    # 不符合门控条件的 draft（如 agent/auto-issue-*）沿用旧行为，ready 后走旧路径。
    gated=0
    if [[ "$draft" == true ]]; then
      if [[ "$branch" =~ $GATED_BRANCH_RE ]]; then gated_flag_pr "$prn" && gated=1; else tick_prs_changed; gh pr ready "$prn" >/dev/null 2>&1; fi
    fi
    jqf --argjson prn "$prn" --argjson n "$n" --arg b "$branch" --arg t "$title" --arg now "$now" \
      '.units += [{id:("pr-"+($prn|tostring)), title:$t, stage:"review-pending", pr:$prn, issue:$n, branch:$b,
        critical:([.units[] | select(.stage=="blocked-external" and .blocked_on == $n)] | length > 0),
        history:[{stage:"orphan-registered", result:"open PR outside the ledger", at:$now}]}]' "$UNITS" | write_state "$UNITS"
    (( gated )) && set_unit "pr-$prn" '.gated=true'
    reg=$((reg + 1))
    say "orphan PR#$prn registered for review (issue #$n)"
  done <<<"$rows"
  echo "agent=$agent_left foreign=$foreign" > "$A/orphan-prs.count"
}

# ---------- 旧 PR 生命周期（#4360）：超龄/深度落后的 agent PR 自动三分类 ----------
# agent PR（agent/* 与 hand/* 分支）超过 7 天或落后 main 超过 300 个提交就分类，理由写进 PR 评论：
#   已在 main（patch-id 等价，或合并后与 main 树一致）→ 关闭 PR；
#   已过时（改动文件在 main 上已全部删除）→ 关闭 PR；与 main 合并冲突只说明 main 动了，不说明意图过时，归「仍需要」；
#   仍需要 → 按原意图开新 ticket（带原 PR 链接与意图摘要，ready-for-agent），原 ticket 开着会被新票取代，
#   旧 PR 关闭。台账里有该 PR 的单元一并 closed。人手分支（fix/、ci/、hotfix/）不归流水线管，不动。
# 判定全用本地 git（一次批量 fetch 所有候选分支），不调模型；原 ticket 已关闭的 PR 不再承载活意图，直接关闭。
AGED_PR_AGE_SECONDS=$((7 * 24 * 3600))
AGED_PR_BEHIND_COMMITS=300
aged_pr_intent_issue() { # branch → issue number（agent/issue-N / agent/auto-issue-N），无则空
  [[ "$1" =~ ^agent/(auto-)?issue-([0-9]+)$ ]] && printf '%s' "${BASH_REMATCH[2]}"
  return 0
}
aged_pr_ticket_body() { # prn branch age behind issue intent_title intent_body
  local prn="$1" branch="$2" age="$3" behind="$4" issue="$5" title="$6" body="$7" origin_line
  origin_line="此票由旧 PR 生命周期 sweep 按 #4360 重开。
- 原 PR：#${prn}（分支 ${branch}，超龄关闭：年龄 $((age / 86400)) 天、落后 main ${behind} 个提交）"
  if [[ -n "$issue" ]]; then
    origin_line="$origin_line
- 原 ticket：#${issue}"
  fi
  printf '%s\n' "$origin_line" "
## 原意图摘要
${title}

${body:0:2000}

## 说明
旧 PR 经三分类判定为「仍需要」，未合入的改动按原意图在当前 main 上重做；原 PR 已关闭，理由见其 PR 评论。"
}
aged_pr_close() { # prn branch age behind class reason [new-issue] → 0 关闭成功
  local prn="$1" branch="$2" age="$3" behind="$4" class="$5" reason="$6" m="${7:-}" unit_id comment
  comment="Autopilot 旧 PR 生命周期（#4360）：关闭此 PR。
- 分类：${class}
- 理由：${reason}
- 触发：年龄 $((age / 86400)) 天、落后 main ${behind} 个提交（阈值 7 天 / 300 提交）"
  if ! gh pr close "$prn" --comment "$comment" >/dev/null 2>&1; then
    say "aged PR#$prn: close failed; retry next round"
    return 1
  fi
  unit_id="$(jqf -r --argjson p "$prn" '[.units[] | select(.pr == $p) | .id] | first // empty' "$UNITS")"
  [[ -n "$unit_id" ]] && set_unit "$unit_id" "$(hist aged-triage "${class}: ${reason}") | .stage=\"closed\""
  say "aged PR#$prn ($branch): ${class} — ${reason}${m:+; reopened as #${m}}"
  return 0
}
aged_pr_lifecycle() {
  local last pr_json rows prn branch head created created_epoch age behind n issue_json intent_title intent_body pr_json_meta
  local live_prs mt rc plus total files f missing file_total done_n=0 left=0 max="${AGED_PR_MAX:-6}" main_ref="refs/remotes/origin/main" m_url m_n
  [[ "${HANDOFF_CENSUS_PARTIAL:-0}" != 1 ]] || { say "aged PR lifecycle deferred: handoff PR census unavailable"; return 0; }
  last="$(cat "$A/aged-pr-check.epoch" 2>/dev/null || true)"
  [[ "$last" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - last < ${AGED_PR_CHECK_SECONDS:-3600} )) && return 0
  echo "$NOW_EPOCH" > "$A/aged-pr-check.epoch"
  pr_json="$(gh pr list --state open --limit 300 --json number,headRefName,headRefOid,createdAt,baseRefName 2>/dev/null)" || return 0
  rows="$(jqf -r 'map(select(.baseRefName == "main" and (.headRefName | test("^(agent|hand)/"))))
      | sort_by(.createdAt) | .[]
      | [.number, .headRefName, .headRefOid, .createdAt] | @tsv' <<<"$pr_json")"
  # 一次批量取回所有候选分支的对象，之后 patch-id/merge-tree/落后计数全是本地判定。
  git -C "$ROOT" fetch -q origin $(jqf -r 'map(select(.baseRefName == "main" and (.headRefName | test("^(agent|hand)/"))) | .headRefName) | unique | .[]' <<<"$pr_json") 2>/dev/null || true
  # 超龄指无人推进：台账单元在年龄窗口内还有历史记录的 PR 是在途工作，不分类（10-29 同一拍关掉了刚复审 READY 的 #4004 和刚交付全绿的 #4022）。
  live_prs="$(jqf -c --argjson cut "$((NOW_EPOCH - AGED_PR_AGE_SECONDS))" '[.units[]
      | select(.pr != null and (.stage | IN("merged","closed") | not))
      | select(([.history[]?.at // empty | try fromdateiso8601 catch 0] | max // 0) > $cut) | .pr]' "$UNITS")"
  while IFS=$'\t' read -r prn branch head created; do
    [[ "$prn" =~ ^[0-9]+$ && "$head" =~ $SHA_RE ]] || continue
    jq -e --argjson p "$prn" 'index($p) != null' <<<"$live_prs" >/dev/null && continue
    n="$(aged_pr_intent_issue "$branch")"
    handoff_pr_waiting "$prn" "${n:-0}" && continue
    created_epoch="$(ap_iso_epoch "$created")"
    [[ "$created_epoch" =~ ^[0-9]+$ && "$created_epoch" -gt 0 ]] || continue
    age=$(( NOW_EPOCH - created_epoch ))
    behind=""
    if git -C "$ROOT" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1; then
      behind="$(git -C "$ROOT" rev-list --count "$head..$main_ref" 2>/dev/null)"
    fi
    if (( age <= AGED_PR_AGE_SECONDS )) && [[ "${behind:-0}" -le $AGED_PR_BEHIND_COMMITS ]]; then continue; fi
    if (( done_n >= max )); then left=$((left + 1)); continue; fi
    # 原 ticket 已关闭：意图已有结局，这个 PR 不再承载活的东西。
    if [[ -n "$n" ]]; then
      issue_json="$(gh issue view "$n" --json state,title,body 2>/dev/null)" || { say "aged PR#$prn: issue #$n unreadable; retry next round"; continue; }
      if [[ "$(jqf -r .state <<<"$issue_json")" == CLOSED ]]; then
        aged_pr_close "$prn" "$branch" "$age" "${behind:-?}" "已在 main" "原 ticket #$n 已关闭，此 PR 不再承载活的意图" "" || continue
        done_n=$((done_n + 1)); continue
      fi
    fi
    if ! git -C "$ROOT" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1; then
      say "aged PR#$prn: head $head not fetchable; retry next round"; continue
    fi
    plus="$(git -C "$ROOT" cherry "$main_ref" "$head" 2>/dev/null | grep -c '^+' || true)"
    total="$(git -C "$ROOT" cherry "$main_ref" "$head" 2>/dev/null | grep -c '^[-+]' || true)"
    if [[ "$plus" == 0 && "$total" -gt 0 ]]; then
      aged_pr_close "$prn" "$branch" "$age" "${behind:-?}" "已在 main" "$total 个提交的 patch-id 全部与 main 等价" "" || continue
      done_n=$((done_n + 1)); continue
    fi
    rc=0
    mt="$(git -C "$ROOT" merge-tree --write-tree "$main_ref" "$head" 2>/dev/null)" || rc=$?
    if [[ $rc -eq 0 ]]; then
      if [[ "$(head -1 <<<"$mt")" == "$(git -C "$ROOT" rev-parse -q --verify "$main_ref^{tree}" 2>/dev/null)" ]]; then
        aged_pr_close "$prn" "$branch" "$age" "${behind:-?}" "已在 main" "改动与 main 合并后的树与 main 完全一致，改动已经存在" "" || continue
        done_n=$((done_n + 1)); continue
      fi
    else
      files="$(git -C "$ROOT" diff --name-only "$(git -C "$ROOT" merge-base "$main_ref" "$head" 2>/dev/null)" "$head" 2>/dev/null)"
      file_total="$(grep -c . <<<"$files" || true)"
      missing=0
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        git -C "$ROOT" cat-file -e "$main_ref:$f" 2>/dev/null || missing=$((missing + 1))
      done <<<"$files"
      if (( file_total > 0 && missing == file_total )); then
        aged_pr_close "$prn" "$branch" "$age" "${behind:-?}" "已过时" "改动的 $file_total 个文件在 main 上已全部删除" "" || continue
        done_n=$((done_n + 1)); continue
      fi
      # 冲突只说明 main 动了，不说明意图过时：落到下方「仍需要」按原意图重开。
    fi
    # 仍需要：按原意图在新 main 上开新 ticket，旧 PR 关闭。
    if [[ -n "$n" ]]; then
      intent_title="$(jqf -r .title <<<"$issue_json")"; intent_body="$(jqf -r .body <<<"$issue_json")"
    else
      pr_json_meta="$(gh pr view "$prn" --json title,body 2>/dev/null)" || { say "aged PR#$prn: pr view failed; retry next round"; continue; }
      intent_title="$(jqf -r .title <<<"$pr_json_meta")"; intent_body="$(jqf -r .body <<<"$pr_json_meta")"
    fi
    m_url="$(gh issue create --title "重做（旧 PR #${prn}）：${intent_title}" \
      --body "$(aged_pr_ticket_body "$prn" "$branch" "$age" "${behind:-?}" "$n" "$intent_title" "$intent_body")" \
      --label ready-for-agent 2>/dev/null)" || { say "aged PR#$prn: new ticket create failed; retry next round"; continue; }
    m_n="${m_url##*/}"
    [[ "$m_n" =~ ^[0-9]+$ ]] || { say "aged PR#$prn: new ticket URL unparsable: ${m_url:-empty}; PR left open"; continue; }
    if [[ -n "$n" ]]; then
      gh issue close "$n" --comment "Autopilot 旧 PR 生命周期（#4360）：此票的意图已按当前 main 重开为 #${m_n}（原 PR #${prn} 超龄关闭，新票带原意图摘要）。本票随之关闭，如有问题请 reopen。" >/dev/null 2>&1 \
        || say "aged PR#$prn: supersede-close of issue #$n failed; new ticket #${m_n} stands"
    fi
    aged_pr_close "$prn" "$branch" "$age" "${behind:-?}" "仍需要" "原意图已按新 main 重开为 #${m_n}" "$m_n" || continue
    done_n=$((done_n + 1))
  done <<<"$rows"
  (( done_n > 0 || left > 0 )) && say "aged PR lifecycle: classified=$done_n deferred=$left"
  echo "classified=$done_n deferred=$left" > "$A/aged-prs.count"
  return 0
}

# 每拍按 NODE-HEALTH.md 的标准给各环节打分：快照写 node-health.txt，UNHEALTHY 写 alerts/node-health.md（每指标每小时一次）；
# 持续 3 小时 UNHEALTHY 的指标自动开/续 pipeline-system issue，由流水线自己修（maintainer 2026-10-20：系统要自己发现并报告异常）。
# flow.* 流动指标越过缺陷阈值时另发一条 supervisor inbox 事件（每越限一次只发一条，#4366）；常规采样只进 dashboard。
run_node_health() {
  [[ -f "$HERE/node_health.py" ]] || return 0
  python3 "$HERE/node_health.py" --runtime "$A" --hours 5 --alert --file-issues --inbox --json "$A/node-health.json" > "$A/node-health.txt" 2>>"$A/autopilot.err" || say "node health scoring failed"
  # CI 花费采样要逐个取 job（首次几百次 API 调用）：每 30 分钟在后台跑一次，不占调度拍。
  # 没有 pid 文件时不能退成 kill -0 0：0 是本进程组，永远成功，采样就永远不启动（L71 体检时 CI 浪费一直 NO-DATA）。
  local cs_pid; cs_pid="$(cat "$A/.ci-spend.pid" 2>/dev/null || true)"
  if [[ -f "$HERE/ci_spend.py" ]] && ! { [[ "$cs_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$cs_pid" 2>/dev/null; } \
    && [[ -z "$(find "$A" -maxdepth 1 -name ci-spend.json -mmin -30 2>/dev/null)" ]]; then
    (cd "$ROOT" && exec setsid python3 "$HERE/ci_spend.py" --runtime "$A" --hours 5) >> "$A/ci-spend.log" 2>&1 < /dev/null &
    echo $! > "$A/.ci-spend.pid"
  fi
}

# 记录每拍各阶段耗时（秒），tick done 行只列 ≥5s 的阶段：一拍 6–7 分钟时看不出慢在哪（L60）。
TICK_PHASES=""
phase() { local t0=$SECONDS rc=0; "$@" || rc=$?; (( SECONDS - t0 >= 5 )) && TICK_PHASES+=" $1=$((SECONDS - t0))s"; return $rc; }

stage_slo_watch() {
  local budgets row id stage since key
  budgets="$(jqf -c '.stage_slo_minutes // {"pending":30,"ready-to-merge":120,"landing":60,"supervisor-review":60,"blocked-external":240}' <<<"$CFG")"
  while IFS=$'\t' read -r id stage since key; do
    [[ -n "$id" ]] || continue
    set_unit "$id" ".slo_alerted=$(js "$key")"
    echo "[$STAMP] SLO-BREACH unit=$id stage=$stage waiting ${since}min" >> "$A/alerts/slo.md"
  done < <(jqf -r --argjson b "$budgets" --argjson now "$NOW_EPOCH" '
      .units[] | select(.stage | test("^(closed|landed|merged|done)$") | not)
      | ((.history // []) | map(select(.at != null)) | last | .at // empty) as $at | select($at != null)
      | ($at | sub("\\.[0-9]+"; "") | fromdateiso8601) as $t
      | (if (.stage | endswith("-pending")) then "pending" else .stage end) as $class
      | select($b[$class] != null and ($now - $t) > ($b[$class] * 60))
      | (.stage + "@" + $at) as $key | select((.slo_alerted // "") != $key)
      | "\(.id)\t\(.stage)\t\((($now - $t) / 60) | floor)\t\($key)"' "$UNITS" 2>/dev/null)
}

# ---------- 4c. 发布列车：每 15 分钟触发 issue-pipeline 的 release 选择器（单实例） ----------
run_release_train() {
  [[ "$(jqf -r 'if .release_train.enabled == false then "false" else "true" end' <<<"$CFG")" == true ]] || return 0
  [[ -f "$HERE/release_train.sh" ]] || return 0
  [[ ! -f "$A/.release-train" || -n "$(find "$A/.release-train" -mmin +15 2>/dev/null)" ]] || return 0
  systemctl --user is-active --quiet zf-release-train 2>/dev/null && return 0
  touch "$A/.release-train"
  # 本服务只有大写代理变量；-E 一个未设置的小写名会让 systemd 设成空串，libcurl 优先读小写，
  # 空 https_proxy = 直连被墙的 GitHub（10-22 17:37Z 起委托切片的 git fetch 每次卡 60s 超时）
  local -x http_proxy="${http_proxy:-${HTTP_PROXY:-}}" https_proxy="${https_proxy:-${HTTPS_PROXY:-}}" no_proxy="${no_proxy:-${NO_PROXY:-}}"
  if systemd-run --user --unit zf-release-train --collect -p RuntimeMaxSec=10800 \
      -E PATH -E HOME -E HTTP_PROXY -E HTTPS_PROXY -E ALL_PROXY -E NO_PROXY \
      -E http_proxy -E https_proxy -E no_proxy -E NODE_USE_ENV_PROXY \
      -E MAC_AUTOPILOT_RUNTIME_DIR="$A" -E MAC_AUTOPILOT_ROOT="$ROOT" \
      /bin/bash -c "exec /bin/bash '$HERE/release_train.sh' >> '$A/release-train.log' 2>&1" >/dev/null 2>&1; then
    say "release train started"
  else
    say "release train launch failed"
  fi
}

# 修 main 单元的共用车道守卫：同 id 幂等；已转人工的旧单元给新的红让位；同一时间只保留一个在途修 main 单元。
main_red_lane_ready() { # unit-id new-red-sha；rc 0 = 可以开新单元
  local id="$1" sha="$2" stale
  jqf -e --arg id "$id" 'any(.units[]; .id == $id)' "$UNITS" >/dev/null && return 1
  # 旧 SHA 的修 main 单元已转人工（如只能改 workflow）：新的红不能被它挡住，旧单元作废。
  for stale in $(jqf -r '.units[] | select(.main_red == true and .stage == "supervisor-review") | .id' "$UNITS"); do
    set_unit "$stale" "$(hist superseded "main red again at $sha") | .stage=\"closed\""
    say "main-red unit $stale superseded by a new failure at $sha"
  done
  jqf -e 'any(.units[]; .main_red == true and (.stage | test("^(closed|landed|merged|done)$") | not))' "$UNITS" >/dev/null && return 1
  return 0
}

# main 的 Pipeline suites 红：立即开一个修 main 的直落单元（不等 supervisor 5 小时一查；2026-10-19 门禁因此关了 6 小时）。
open_main_red_unit() { # sha run-id attempt (a repeated, classified code failure)
  local id="main-red-${1:0:9}" failed task attempt="${3:-}"
  local recovery_session="${AGENT_HOME:-${HOME:-}/.zenoforge}/main-red/$1.json"
  [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || return 0
  if jqf -e --arg sha "$1" '
    .red_sha == $sha and .red_workflow == "pipeline-suites.yml"
      and (.status == "rerun-requested" or .status == "bisecting"
        or .status == "culprit-found" or .status == "revert-open" or .status == "unattributed")
  ' "$recovery_session" >/dev/null 2>&1; then
    say "main-red unit $id deferred to the Pipeline suites bisect session"
    return 0
  fi
  main_red_lane_ready "$id" "$1" || return 0
  failed="$(gh run view "$2" --attempt "$attempt" --log-failed 2>/dev/null | grep -oE 'FAILED suite=[^ ]+ exit_code=[^ ]+ first_error=.{0,160}' | sort -u | head -10)"
  task="你是 the product 流水线的实现 subagent。main 的 Pipeline suites 在 $1 上失败（run $2 attempt $attempt），产品合并门禁因此关闭，这是最高优先级。
失败 suite：
${failed:-（日志里没解析出 FAILED suite= 行，用 gh run view $2 --attempt $attempt --log-failed 自查）}
用 gh run view $2 --attempt $attempt --log-failed 看完整失败；本地跑失败的 suite 复现。判断是测试/fixture 跟不上新改动、真实回归，还是 CI 负载下的超时（超时看 engine/run-ci-suites.sh 的 suite_weight_seconds：超时 = 3×权重，按实测刷新）。修根因，不弱化断言、不删测试。"
  units_update --arg id "$id" --arg sha "$1" --arg task "$task" --arg run "$2" --argjson attempt "$attempt" \
    '.units += [{id:$id, main_red:true, critical:true, ci_sha:$sha, ci_run_id:$run, ci_run_attempt:$attempt, title:("fix red main Pipeline suites at "+$sha[0:9]), stage:"implement-pending", lane:"direct-main", branch:("agent/"+$id), task:$task, history:[]}]'
  say "main suites red at $1 (run $2) -> opened $id"
  echo "[$STAMP] MAIN-RED unit=$id main=$1 run=$2" >> "$A/alerts/gate.md"
}

# 落地自红的 fast path（2026-10-29 zf-ab 请求）：post-land Pipeline suites 首红，失败 suite 属于
# 最近绿..红 head 窗口内某次落地 changed paths 按 focused-test-paths.mjs 映射出的 suite（含落地直接改的
# 测试文件）时，立即开 fix-forward 单元，不等重跑确认/二分/复现。反例：aec22b350（#4659）改
# the provider script，advisor-answer-stall 在 post-land run 40962277656 红，live advisor 坏了约 1 小时才被人工发现。
# post-land run 由 land-direct-main 每次落地 dispatch、去重后只有最新一个跑到完成，红的 head 不一定是
# 罪魁落地本身，所以归属按窗口内逐落地映射。不映射到窗口内任何落地的 suite 不过这里，仍走原有
# 重跑/二分路径。同一落地 SHA + 同一 suite 只开一次（单元 id 幂等）；一拍最多开一个，多个归属单元
# 随后续拍次逐个开出。
open_landed_red_unit() { # red-head-sha run-id attempt
  local head="$1" run="$2" attempt="$3"
  local run_json green_sha candidates c mapped row s owner="" suite="" first_error id repo url task owner_subject failed
  [[ "$head" =~ $SHA_RE && "$run" =~ ^[0-9]+$ && "$attempt" =~ ^[1-9][0-9]*$ ]] || return 0
  main_suites_load
  [[ -n "$MAIN_SUITES_RUNS" ]] || return 0
  run_json="$(jqf -c --argjson id "$run" 'map(select(.databaseId==$id)) | first // empty' <<<"$MAIN_SUITES_RUNS")"
  jqf -e --arg sha "$head" '.headSha==$sha and .status=="completed" and .conclusion=="failure"' <<<"$run_json" >/dev/null || return 0
  green_sha="$(jqf -r --arg at "$(jqf -r '.createdAt // empty' <<<"$run_json")" '
    map(select(.status=="completed" and .conclusion=="success" and (.createdAt // "") < $at))
    | sort_by(.createdAt) | last | .headSha // empty' <<<"$MAIN_SUITES_RUNS")"
  [[ "$green_sha" =~ $SHA_RE ]] || return 0
  git -C "$ROOT" merge-base --is-ancestor "$green_sha" "$head" 2>/dev/null || return 0
  failed="$(gh run view "$run" --attempt "$attempt" --log-failed 2>/dev/null \
    | grep -oE 'FAILED suite=[^ ]+ exit_code=[^ ]+ first_error=.{0,160}' | sort -u || true)"
  [[ -n "$failed" ]] || return 0
  candidates="$(git -C "$ROOT" rev-list "$green_sha..$head" 2>/dev/null | head -50 | tac)"
  while IFS= read -r c; do
    [[ "$c" =~ $SHA_RE ]] || continue
    mapped="$(cd "$ROOT" && node engine/focused-test-paths.mjs --range "${c}^" "$c" 2>/dev/null || true)"
    [[ -n "$mapped" ]] || continue
    while IFS= read -r row; do
      s="${row#FAILED suite=}"; s="${s%% *}"
      [[ -n "$s" ]] || continue
      printf '%s\n' "$mapped" | grep -qxF "$s" || continue
      owner="$c"; suite="$s"; first_error="${row#*first_error=}"
      break
    done <<< "$failed"
    [[ -n "$owner" ]] && break
  done <<< "$candidates"
  [[ -n "$owner" ]] || return 0
  id="landed-red-${owner:0:9}-$(printf '%s' "$suite" | sha256sum | cut -c1-6)"
  main_red_lane_ready "$id" "$head" || return 0
  owner_subject="$(git -C "$ROOT" log -1 --format=%s "$owner" 2>/dev/null || true)"
  repo="$(git -C "$ROOT" remote get-url origin 2>/dev/null)"
  repo="${repo#*github.com[:/]}"; repo="${repo%.git}"
  if [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then url="https://github.com/${repo}/actions/runs/${run}"; else url="run ${run}"; fi
  task="你是 the product 流水线的实现 subagent。post-land Pipeline suites 红（${url}，attempt ${attempt}），失败的 suite 按 focused-test-paths.mjs 归属到你落地的提交 ${owner}（${owner_subject}），是本次落地的回归，最高优先级直接修根因。
失败 suite：${suite}
first_error：${first_error}
用 gh run view ${run} --attempt ${attempt} --log-failed 看完整失败，本地跑 ${suite} 复现；修根因，不弱化断言、不删测试。若该 suite 覆盖线上运行面（advisor、调度器等），在报告写明 live 组件是否受影响。"
  units_update --arg id "$id" --arg owner "$owner" --arg suite "$suite" --arg sha "$head" --arg run "$run" \
    --argjson attempt "$attempt" --arg url "$url" --arg task "$task" \
    '.units += [{id:$id, main_red:true, landed_red:true, critical:true, landed_sha:$owner, landed_suite:$suite, ci_sha:$sha, ci_run_id:$run, ci_run_attempt:$attempt, ci_run_url:$url, title:("fix post-land red "+($suite|split("/")|last)+" at "+$owner[0:9]), stage:"implement-pending", lane:"direct-main", branch:("agent/"+$id), task:$task, history:[]}]'
  say "landed red at $head (run $run): suite $suite owned by landing $owner -> opened $id"
  echo "[$STAMP] LANDED-RED unit=$id landing=$owner suite=$suite run=$run" >> "$A/alerts/gate.md"
}

supersede_resolved_main_red_units() {
  [[ "$MAIN_HEAD" =~ $SHA_RE ]] || return 0
  local pending green_shas id ci_sha candidate reason history_update
  pending="$(jqf -r --slurpfile workers "$WORKERS" '
    .units[] as $unit
    | select($unit.main_red == true and $unit.stage == "implement-pending")
    | select(any($workers[0].workers[]; .unit == $unit.id and .harvested != true) | not)
    | [$unit.id, ($unit.ci_sha // "")] | @tsv
  ' "$UNITS")"
  [[ -n "$pending" ]] || return 0
  main_suites_load
  [[ -n "$MAIN_SUITES_RUNS" ]] || return 0
  green_shas="$(jqf -r '
    [ .[] | select((.headSha // "") | test("^[0-9a-f]{40}$"))
      | {sha:.headSha, at:(.createdAt // ""), status:(.status // ""), conclusion:(.conclusion // "")}
    ]
    | group_by(.sha)
    | map(sort_by(.at) | last)
    | map(select(.status == "completed" and .conclusion == "success"))
    | sort_by(.at) | reverse | .[].sha
  ' <<<"$MAIN_SUITES_RUNS")"
  [[ -n "$green_shas" ]] || return 0
  while IFS=$'\t' read -r id ci_sha; do
    [[ -n "$id" && "$ci_sha" =~ $SHA_RE ]] || continue
    while read -r candidate; do
      [[ "$candidate" =~ $SHA_RE && "$candidate" != "$ci_sha" ]] || continue
      git -C "$ROOT" merge-base --is-ancestor "$ci_sha" "$candidate" 2>/dev/null || continue
      git -C "$ROOT" merge-base --is-ancestor "$candidate" "$MAIN_HEAD" 2>/dev/null || continue
      reason="newer main SHA $candidate passed Pipeline suites"
      history_update="$(hist superseded "$reason")"
      set_unit "$id" "$history_update | .stage=\"closed\""
      say "main-red unit $id superseded by green Pipeline suites at $candidate"
      break
    done <<<"$green_shas"
  done <<<"$pending"
}

# ---------- 4. 新 PR 自动评审（限量：只挑最新 max_pending_reviews 个） ----------
# PR 关联 issue 带 hotfix 时也不登记（#4615）：10-29 #4612/#4613 开出来时漏了 PR 标签，被登记成 unit 后
# ci_wip 掐掉了它们的 CI。关联认分支 agent/issue-<n>-*（含 agent/issue-hf-<n>）和正文 Refs #n。
hotfix_linked_issue_numbers() { # PR JSON → 关联 issue 号数组
  jqf -cn --argjson p "$1" '
    ([($p.headRefName // "") | match("^agent/issue-(hf-)?([0-9]+)(-|$)") | .captures[1].string | tonumber]
      + [($p.body // "") | match("(?im)^[[:space:]]*[-*]?[[:space:]]*refs[[:space:]:]+#([0-9]+)"; "g") | .captures[0].string | tonumber]
    | unique)
  '
}
is_hotfix_pr() { # PR JSON → success when config, PR label, or linked issue marks it hotfix
  local pr="$1" label branch prefix linked hot
  label="$(hotfix_lane_label)"
  jqf -e --arg label "$label" 'any(.labels[]?; .name == $label)' <<<"$pr" >/dev/null && return 0
  branch="$(jqf -r '.headRefName // ""' <<<"$pr")"
  while IFS= read -r prefix; do
    [[ -n "$prefix" && "$branch" == "$prefix"* ]] && return 0
  done < <(hotfix_lane_branch_prefixes)
  linked="$(hotfix_linked_issue_numbers "$pr")" || return 1
  [[ "$linked" != "[]" ]] || return 1
  if hotfix_issue_numbers >/dev/null; then hot="$TICK_HOTFIX_ISSUES"; else hot='[]'; fi
  jqf -e --argjson linked "$linked" --argjson hot "$hot" \
    'any($linked[]; . as $n | $hot | index($n) != null)' <<<"{}" >/dev/null
}
label_hotfix_pr() { # PR number, currently known label names
  local pr="$1" labels="$2" label
  label="$(hotfix_lane_label)"
  jqf -e --arg label "$label" 'index($label) != null' <<<"$labels" >/dev/null && return 0
  gh pr edit "$pr" --add-label "$label" >/dev/null 2>&1 || { say "hotfix PR#$pr: could not add configured label $label"; return 1; }
  tick_prs_changed
  say "hotfix PR#$pr: added configured label $label"
}
register_new_prs() {
  [[ "$(jqf -r .auto_dispatch_new_prs <<<"$CFG")" == "true" ]] || return 0
  local CAP="${MAX_PENDING_REVIEWS:-12}" n_registered=0 pr sha pr_head target branch draft title labels pr_num critical u wt rep lane body64 body body_file pr_json
  while IFS=$'\t' read -r pr sha branch draft title labels body64; do
    [[ -z "$sha" ]] && continue
    [[ "$pr" =~ ^[0-9]{1,9}$ ]] || { say "skip malformed PR number from gh pr list"; continue; }
    pr_num="$((10#$pr))"
    (( pr_num > 0 )) || { say "skip non-positive PR number from gh pr list"; continue; }
    (( n_registered >= CAP )) && break
    [[ "$draft" == "true" ]] && continue
    body="$(jqf -nr --arg body64 "$body64" '$body64 | @base64d')" || body=""
    body_file="$(scheduler_jq_arg_file "$body")" || continue
    pr_json="$(jqf -cn --argjson number "$pr_num" --arg branch "$branch" --rawfile body "$body_file" --argjson labels "$labels" \
      '{number:$number,headRefName:$branch,body:$body,labels:[$labels[] | {name:.}]}')"
    rm -f -- "$body_file"
    # CI 准入与新 PR 收单共用 is_hotfix_pr；热修 PR 由 supervisor 负责，scheduler 不登记。
    if is_hotfix_pr "$pr_json"; then
      label_hotfix_pr "$pr_num" "$labels" || true
      say "skip pr-$pr_num: configured hotfix lane"
      continue
    fi
    jqf -e --argjson pr_num "$pr_num" '([.units[].pr] | map(select(. != null)) | index($pr_num)) != null' "$UNITS" >/dev/null 2>&1 && continue
    critical=false
    has_critical_label "$labels" && critical=true
    if [[ "$FOCUS_MODE" == "release" && "$critical" != "true" && "$(critical_pending_count)" -gt 0 ]]; then
      FOCUS_SKIPPED+=("pr-$pr_num")
      say "skip new PR unit=pr-$pr_num focus=release critical=false"
      continue
    fi
    u="$(jqf -cn --argjson pr_num "$pr_num" --arg title "$title" --arg branch "$branch" --argjson critical "$critical" '{id:("pr-"+($pr_num|tostring)),title:$title,stage:"review-pending",pr:$pr_num,branch:$branch,critical:$critical,history:[]}')"
    jqf --argjson u "$u" '.units += [$u]' "$UNITS" | write_state "$UNITS"
    n_registered=$((n_registered+1))
    if [[ -n "${HANDOFF_PR_CENSUS:-}" ]]; then
      if [[ "${HANDOFF_CENSUS_PARTIAL:-0}" == 1 ]]; then handoff_include_pr "$pr_num" || continue; fi
      register_new_issues 1 reuse
      jqf -e --arg id "pr-$pr_num" 'any(.units[]; .id == $id and .hold_handoff_waiting == true)' "$UNITS" >/dev/null && continue
      [[ "$(unit_field "pr-$pr_num" '.stage')" == review-pending ]] || continue
    fi
    lane="$(ensure_lane "pr-$pr_num" "$pr_num")" || { say "new PR unit=pr-$pr_num: lane unavailable"; continue; }
    [[ "$lane" == direct-main ]] && cancel_branch_runs "$branch" "direct-main lane; does not use PR CI"
    room_for "pr-$pr_num" review || continue
    pick review || continue
    wt="$(ensure_clone "pr-$pr_num")" || { say "new PR unit=pr-$pr_num: clone unavailable; stays review-pending"; continue; }
    target="$(unit_review_target "pr-$pr_num" "$pr_num" "$lane" "$branch")" || { say "new PR unit=pr-$pr_num: PR head unavailable; stays review-pending"; continue; }
    read -r pr_head sha <<<"$target"
    checkout_pr_head "$wt" "$pr_num" "$sha" "$pr_head" || { say "new PR unit=pr-$pr_num: PR head unavailable; stays review-pending"; continue; }
    rep="review-${pr_num}-${TAG}.md"
    dispatch_if_room "pr-$pr_num" "review" "review" "${rep%.md}.worker.log" "$rep" \
      "$PICK_MODEL" "$PICK_EFFORT" "$(review_prompt "$pr_num" "$title" "$sha" "$rep" "$lane" "$wt")" "$sha" "$wt" "$pr_head" || true
  done < <(tick_prs | jqf -r 'sort_by(-.number) | .[0:15] | .[] | "\(.number)\t\(.headRefOid)\t\(.headRefName)\t\(.isDraft)\t\(.title | gsub("\t"; " "))\t\([.labels[].name] | @json)\t\((.body // "") | @base64)"' 2>/dev/null)
}

# 把本拍已经读到的 PR 与 run 事实发布成一份快照（pr-run-snapshot.json，见 runtime-env.sh）：bell、zombie-watch、dashboard 读它，
# 不再各自列 run。每个分区读失败就写 null，读的人把它当"不可用"。快照是这台主机本拍的读缓存，不是权威，别的主机自己重建。
publish_pr_run_snapshot() {
  local prs unfinished ci suites infra query_dir query_ci_pid query_infra_pid query_started query_elapsed
  prs="$(tick_prs 2>/dev/null | jqf -c 'map({number, headRefOid, headRefName, isDraft, title, labels: [.labels[]?.name]})')" || prs=""
  unfinished="$(unfinished_runs)"
  main_suites_load; suites="$MAIN_SUITES_RUNS"
  query_dir="$(mktemp -d)" || query_dir=""
  if [[ -n "$query_dir" ]]; then
    query_started=$SECONDS
    { gh run list --workflow CI --branch main --limit 100 --json databaseId,headSha,status,conclusion,createdAt,attempt >"$query_dir/ci" 2>/dev/null || :; } &
    query_ci_pid=$!
    { gh run list -R example-org/example-infra --limit 30 --json databaseId,status,conclusion,createdAt,headSha,workflowName,displayTitle >"$query_dir/infra" 2>/dev/null || :; } &
    query_infra_pid=$!
    wait "$query_ci_pid" || :
    wait "$query_infra_pid" || :
    ci="$(cat "$query_dir/ci" 2>/dev/null)"
    infra="$(cat "$query_dir/infra" 2>/dev/null)"
    rm -rf -- "$query_dir"
    query_elapsed=$((SECONDS - query_started))
    (( query_elapsed < 2 )) || say "snapshot run_queries=${query_elapsed}s"
  else
    ci=""; infra=""
    say "snapshot run queries unavailable: temporary directory could not be created"
  fi
  pr_run_snapshot_publish "$A" "$prs" "$unfinished" "$ci" "$suites" "$infra" "$MAIN_HEAD" \
    || say "pr-run snapshot not written; readers treat it as unavailable"
}

# ---------- tick 互斥：同一时刻只允许一个 scheduler 写台账 ----------
SCHED_LOCK="$A/.scheduler.lock"
SCHED_LOCK_HELD=false
acquire_scheduler_lock() {
  local old owner="$BASHPID"
  if ! mkdir "$SCHED_LOCK" 2>/dev/null; then
    old="$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 1; fi
    rm -rf -- "$SCHED_LOCK"
    mkdir "$SCHED_LOCK" 2>/dev/null || return 1
  fi
  echo "$owner" > "$SCHED_LOCK/pid"
  SCHED_LOCK_HELD=true
  trap 'release_scheduler_lock' EXIT
}
release_scheduler_lock() {
  [[ "${SCHED_LOCK_HELD:-false}" == true ]] || return 0
  if [[ "$(cat "$SCHED_LOCK/pid" 2>/dev/null || true)" == "$BASHPID" ]]; then
    rm -rf -- "$SCHED_LOCK"
  fi
  SCHED_LOCK_HELD=false
}
acquire_scheduler_lock_wait() {
  until acquire_scheduler_lock; do sleep 0.05; done
}
phase_yield_lock() { # slow operation; let the local refill controller take the same ledger lock
  local rc=0
  release_scheduler_lock
  phase "$@" || rc=$?
  acquire_scheduler_lock_wait
  LIVE_WORKER_CACHE_UNTIL=0
  return "$rc"
}

# ---------- 派生视图：体检评分、看板渲染 ----------
# 它们只读快照与台账，不参与任何单元决策：拍末起一个分离的进程去跑，拍不等它们（看板一次约 40 秒）。上一轮视图没跑完就让它跑完、本轮跳过。
VIEWS_LOCK="$A/.views.lock"
run_views() { # full = 体检 + 看板；dashboard = 只渲染看板（暂停时）
  [[ "$1" == full ]] && run_node_health
  SESSION_TZ="$SESSION_TZ" python3 "$HERE/gen_dashboard.py" 2>>"$A/autopilot.err"
}
views_entry() { # scheduler.sh --views <mode>：分离进程入口，自己持有视图锁
  local old
  if ! mkdir "$VIEWS_LOCK" 2>/dev/null; then
    old="$(cat "$VIEWS_LOCK/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 0; fi
    rm -rf -- "$VIEWS_LOCK"
    mkdir "$VIEWS_LOCK" 2>/dev/null || return 0
  fi
  echo "$$" > "$VIEWS_LOCK/pid"
  trap 'rm -rf "$VIEWS_LOCK"' EXIT
  run_views "${1:-dashboard}"
}
launch_views() { # mode；AUTOPI_VIEWS_INLINE=true 时就地跑完（测试与排障）
  if [[ "${AUTOPI_VIEWS_INLINE:-false}" == true ]]; then run_views "$1"; return 0; fi
  setsid timeout -k 30 900 bash "$HERE/scheduler.sh" --views "$1" >> "$A/views.log" 2>&1 < /dev/null &
}

state_schema_ok() {
  jqf -e 'type=="object" and (.units|type)=="array"
    and all(.units[]; type=="object" and (.id|type)=="string" and (.id|length)>0 and (.stage|type)=="string")
    and ([.units[].id]|length)==([.units[].id]|unique|length)' "$UNITS" >/dev/null \
    && jqf -e 'type=="object" and (.workers|type)=="array"
    and all(.workers[]; type=="object" and (.pid|type)=="number" and .pid>0 and (.unit|type)=="string")' "$WORKERS" >/dev/null
}

# 补派循环入口（#4628）：loop.sh 与慢 tick 并行检查本地台账，30 秒一次或发现新退出的 worker 时触发。
# 慢阶段只在等待 GitHub 时让出同一 SCHED_LOCK；补派只本地收割 direct-main 实现结果、回收孤儿记录，
# 再派发 implement-pending；不做 GitHub 查询/写入或远端 fetch。其他报告与 PR 注册仍由慢 tick 处理。
refill_tick() {
  cd "$ROOT" || { echo "scheduler: root $ROOT unavailable" >&2; return 1; }
  acquire_scheduler_lock || return 75
  if ! state_schema_ok; then
    say "state schema invalid; refill stopped before external actions"
    echo "[$STAMP] invalid units/workers schema; supervisor recovery required" >> "$A/alerts/state.md"
    return 2
  fi
  MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)"
  phase harvest_workers true
  phase recover_orphans
  if [[ -e "$PAUSE_FILE" ]]; then
    say "refill paused by $PAUSE_FILE: no dispatch"
  else
    phase dispatch_pending true
  fi
  say "refill done live=$(live_workers) secs=$SECONDS${TICK_PHASES:+ slow:$TICK_PHASES}"
}

main() {
  local views_mode=dashboard
  cd "$ROOT" || { echo "scheduler: root $ROOT unavailable" >&2; return 1; }
  acquire_scheduler_lock || { echo "[$STAMP] scheduler tick skipped: another tick holds $SCHED_LOCK" >> "$LOG"; return 0; }
  if ! state_schema_ok; then
    say "state schema invalid; tick stopped before external actions"
    echo "[$STAMP] invalid units/workers schema; supervisor recovery required" >> "$A/alerts/state.md"
    return 2
  fi
  rotate_logs
  if update_budget >/dev/null; then
    budget_alert_if_needed
  else
    echo "[$STAMP] BUDGET-METER-ERROR sessions_dir scan failed; dispatch continues" >> "$A/alerts/waste.md"
    say "budget meter scan failed; dispatch continues"
  fi
  if git -C "$ROOT" fetch -q origin main 2>/dev/null; then
    MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)"
  fi
  main_suites_prefetch
  phase harvest_workers
  phase reconcile_size_recuts
  phase self_check_harvest
  phase precheck_harvest
  phase recover_orphans
  phase recover_orphan_landing
  phase live_event_watch
  if [[ -e "$PAUSE_FILE" ]]; then
    # 用户的后端 Codex 暂停开关：保留回收、验证与发布列车，不派发、不合并。
    say "paused by $PAUSE_FILE: harvest and release train only, no dispatch or merge"
    phase run_release_train
  else
    phase stuck_worker_disposition
    phase_yield_lock release_dependency_blocks
    phase register_new_issues 1
    phase register_new_issues
    phase retire_landed_pr_units
    phase supersede_resolved_main_red_units
    phase dispatch_pending
    phase dispatch_supervisor_arbiters
    phase dispatch_prompt_evals
    phase fast_land_lane
    phase_yield_lock ci_admission
    phase_yield_lock run_merge_lane
    phase register_new_prs
    phase reconcile_orphan_prs
    phase aged_pr_lifecycle
    phase run_release_train
    phase stage_slo_watch
    phase dispatch_pending
    views_mode=full
  fi
  cleanup_tick
  flush_focus_alert
  publish_pr_run_snapshot
  launch_views "$views_mode"
  say "tick done units=$(jqf '.units | length' "$UNITS") live=$(live_workers) secs=$SECONDS${TICK_PHASES:+ slow:$TICK_PHASES}"
}

if [[ "${AUTOPI_TEST_LIBRARY_ONLY:-false}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi
case "${1:-}" in
  --views) views_entry "${2:-dashboard}" ;;
  --refill) refill_tick ;;
  *) main "$@" ;;
esac
