#!/usr/bin/env bash
# 无产出死亡诊断（11-03：两个评审单元 3 次死亡只留下 "died without a report"，死因——claude CLI 的
# Bun 运行时 SIGABRT、主机线程上限 EAGAIN——全在 worker 日志里没人读）：
#   1) 死于信号/OOM 的 worker：退出码、信号、末条错误行记到单元（.worker_death、历史、waste 告警），
#      并出现在 supervisor-review 的升级理由里；
#   2) 可恢复死因不再一概 supervisor-review：主机线程上限（EAGAIN）→ 提供方短冷却 + 回 pending
#      （不计无产出死亡、连续上限次才升级）；OOM/整组被杀 → 既有尺寸止损重切路由；
#   3) dispatch 的三个启动路径都包 pipeline.exit 退出足迹（无 footer 的旧日志由 bash 作业消息退回辨认）。
# 复用 stuck-worker-disposition.test.sh 的 fixture 模式：死 worker（真已退出的 pid）、gh-shim。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/worker-death"; sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/sessions" "$fixture/notrepo"
cp "$script_dir/config.template.json" "$sup/autopi/config.json"
printf '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$test_env_root/repo-root"; mkdir -p "$MAC_AUTOPILOT_ROOT"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$sup"
export CODEX_SESSIONS_DIR="$fixture/sessions" AUTOPI_TEST_LIBRARY_ONLY=true
unset GH_TOKEN GITHUB_TOKEN
export REQUIRED_PR_CHECKS_FILE="$test_env_root/required-pr-checks.json"
printf '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export PATH="$script_dir/../gh-shim:$PATH"

fail() { echo "worker-death-diagnosis.test.sh: $*" >&2; exit 1; }
source "$script_dir/scheduler.sh"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
: > "$A/alerts/waste.md"
FIXTURE_RECUT_LOG="$fixture/recut.calls"; export FIXTURE_RECUT_LOG

# 尺寸止损重切路由的桩（同 stuck-worker-disposition.test.sh）：记录调用、按需成功。
scheduler_recut_route() {
  local issue="$1" evidence="$2"
  jq -cn --arg issue "$issue" --arg evidence "$evidence" '{issue:$issue,evidence:$evidence}' >> "$FIXTURE_RECUT_LOG"
  printf '{"state":"needs-recut"}\n' > "$fixture/issue-state-$issue.json"
}
scheduler_issue_state() {
  local state_file="$fixture/issue-state-$1.json"
  [[ -f "$state_file" ]] && cat "$state_file" || printf '{}\n'
}

# ---- 0. dispatch 三个启动路径都把退出足迹写到独立 sidecar（pipeline.exit） --------------------
grep -Fq 'exit_file=$1; shift; rc=0; "$@" || rc=$?; printf "{\"type\":\"pipeline.exit\"' "$script_dir/scheduler.d/dispatch.sh" \
  || fail "dispatch must wrap each launch path with a worker exit footer"
grep -Fq '> "$exit_file"; exit "$rc"' "$script_dir/scheduler.d/dispatch.sh" \
  || fail "dispatch must write the exit footer outside the provider output log"
footer_line="$(grep -nF 'exit_file=$1; shift; rc=0; "$@" || rc=$?; printf "{\"type\":\"pipeline.exit\"' "$script_dir/scheduler.d/dispatch.sh" | cut -d: -f1)"
launch_line="$(grep -nF 'worker_scope_launch "$worker_pid_file"' "$script_dir/scheduler.d/dispatch.sh" | cut -d: -f1)"
[[ "$footer_line" =~ ^[0-9]+$ && "$launch_line" =~ ^[0-9]+$ && "$footer_line" -lt "$launch_line" ]] \
  || fail "all dispatch branches must pass through the footer before worker launch"

# 死 pid：起一个即退的 sleep（alive 只看存活），等它退出后复用该 pid。
dead_pid() {
  local p
  bash -c 'exec -a codex-fake sleep 0.05' >/dev/null 2>&1 & p=$!
  wait "$p" 2>/dev/null || true
  printf '%s' "$p"
}

iso_ago() { date -u -d "@$(( $(date -u +%s) - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ; }
mk_worker() { # unit pid log report → worker json
  jq -cn --argjson pid "$2" --argjson pgid "$2" --arg unit "$1" --arg log "$3" --arg report "$4" --arg at "$(iso_ago 5)" \
    --arg model "claude-sonnet-4-5" --arg provider "claude" --arg workdir "$fixture/notrepo" \
    '{pid:$pid, unit:$unit, type:"review", log:$log, report:$report, started:$at, model:$model,
      process_group:$pgid, provider:$provider, workdir:$workdir, token_usage_start:null}'
}
# 触顶单元的历史：MAX_NO_OUTPUT(=2) 次无产出死亡 + 已用掉 fresh-session 重试 → 下一次死亡即升级。
mk_capped_history() {
  jq -cn --arg at "$(iso_ago 60)" '[{stage:"worker-no-output",result:"review",at:$at},
    {stage:"worker-no-output",result:"review",at:$at},{stage:"fresh-session-retry",result:"2 deaths",at:$at}]'
}
write_units() { jq -cn --argjson u "$1" '{units:[$u]}' > "$sup/autopi/units.json"; }
write_workers() { jq -cn --argjson w "$1" '{workers:$w}' > "$sup/autopi/workers.json"; }

# ---- 1. 信号死亡（SIGABRT，Bun panic）记录死因并出现在 supervisor 理由里 -------------------
unit_a=pr-signal-death
pid_a="$(dead_pid)"
cat > "$sup/review-signal.worker.log" <<'LOG'
============================================================
Bun v1.4.4 (388955fac) Linux x64
Args: "claude" "-p" "review prompt" ...
oh no: Bun has crashed. This indicates a bug in Bun, not your code.
panic(main thread): abort() called
autopilot-worker: line 1: 3440798 Aborted                 "$@" > "$out.partial"
{"type":"pipeline.exit","rc":134}
LOG
write_units "$(jq -cn --arg id "$unit_a" --argjson hist "$(mk_capped_history)" '{id:$id, issue:5301, stage:"review", history:$hist}')"
write_workers "[$(mk_worker "$unit_a" "$pid_a" review-signal.worker.log review-signal.md)]"
harvest_workers
stage="$(unit_field "$unit_a" .stage)"
[[ "$stage" == supervisor-review ]] || fail "capped signal deaths must still escalate (got stage=$stage)"
note="$(unit_field "$unit_a" .note)"
[[ "$note" == *"3 workers died without a report"* ]] || fail "escalation reason must keep the death count: $note"
[[ "$note" == *"rc=134"* && "$note" == *"signal=ABRT"* ]] || fail "escalation reason must carry exit code and signal: $note"
[[ "$note" == *"panic(main thread): abort() called"* ]] || fail "escalation reason must carry the last error line: $note"
jq -e --arg id "$unit_a" '.units[] | select(.id==$id) | .worker_death.rc == 134 and .worker_death.signal == "ABRT"
  and (.worker_death.error | contains("panic(main thread)"))' "$UNITS" >/dev/null \
  || fail "the unit must record the diagnosed death (rc/signal/last error line)"
jq -e --arg id "$unit_a" '.units[] | select(.id==$id) | (.history // [])[-1].stage == "supervisor-escalated"' "$UNITS" >/dev/null \
  || fail "the last history entry must be the escalation"
grep -aq 'rc=134' "$A/alerts/waste.md" || fail "the waste alert must carry the death summary"

# ---- 2. 可恢复：主机线程上限（EAGAIN）不进 supervisor-review，冷却提供方并回 pending -------
: > "$A/alerts/waste.md"; rm -f "$A/cooldown.json"
unit_b=pr-start-limit
pid_b="$(dead_pid)"
cat > "$sup/review-eagain.worker.log" <<'LOG'
error: Failed to start HTTP Client thread: EAGAIN
note: The process or thread limit may have been reached (ulimit -u, or the container's pids limit); raise it or reduce concurrency
{"type":"pipeline.exit","rc":1}
LOG
write_units "$(jq -cn --arg id "$unit_b" --argjson hist "$(mk_capped_history)" '{id:$id, issue:5302, stage:"review", history:$hist}')"
write_workers "[$(mk_worker "$unit_b" "$pid_b" review-eagain.worker.log review-eagain.md)]"
harvest_workers
stage="$(unit_field "$unit_b" .stage)"
[[ "$stage" != supervisor-review ]] || fail "a start-limit death must not escalate to supervisor-review"
jq -e --arg id "$unit_b" '.units[] | select(.id==$id) | ((.history // []) | any(.stage == "worker-start-failed"))' "$UNITS" >/dev/null \
  || fail "a start-limit death must be recorded as worker-start-failed"
jq -e --arg id "$unit_b" '.units[] | select(.id==$id) | ((.history // []) | map(select(.stage == "worker-no-output")) | length) == 2' "$UNITS" >/dev/null \
  || fail "a start-limit death must not count toward the no-output cap"
jq -e --arg id "$unit_b" '.units[] | select(.id==$id) | (.worker_death.error | contains("EAGAIN"))' "$UNITS" >/dev/null \
  || fail "the start-limit death must still be diagnosed on the unit"
jq -e --argjson now "$(date +%s)" '.claude > $now' "$A/cooldown.json" >/dev/null \
  || fail "the worker's provider must cool down after a start-limit death"
jq -e --argjson pid "$pid_b" '.workers[] | select(.pid==$pid) | .harvested == true' "$WORKERS" >/dev/null \
  || fail "the start-limit worker must be harvested"
recover_orphans
[[ "$(unit_field "$unit_b" .stage)" == review-pending ]] || fail "orphan heal must requeue the unit for a cooldown-paced retry"

# ---- 3. 可恢复：OOM/整组被杀按既有尺寸止损路由重切，不进 supervisor-review ----------------
: > "$A/alerts/waste.md"; : > "$FIXTURE_RECUT_LOG"
unit_c=pr-oom-death
pid_c="$(dead_pid)"
cat > "$sup/review-oom.worker.log" <<'LOG'
FATAL ERROR: Reached heap limit - JavaScript heap out of memory
{"type":"pipeline.exit","rc":137}
LOG
write_units "$(jq -cn --arg id "$unit_c" --argjson hist "$(mk_capped_history)" '{id:$id, issue:5303, stage:"review", history:$hist}')"
write_workers "[$(mk_worker "$unit_c" "$pid_c" review-oom.worker.log review-oom.md)]"
harvest_workers
[[ "$(unit_field "$unit_c" .stage)" != supervisor-review ]] || fail "an OOM death must not escalate to supervisor-review"
[[ "$(unit_field "$unit_c" .stage)" == blocked-external ]] || fail "an OOM death must route to the size stop-loss (blocked-external), got $(unit_field "$unit_c" .stage)"
jq -e --arg id "$unit_c" '.units[] | select(.id==$id) | .size_recut_pending == true
  and ((.history // []) | any(.stage == "worker-oom-recut"))' "$UNITS" >/dev/null \
  || fail "the OOM death must be recorded as a size recut"
jq -e '.issue == "5303" and (.evidence | fromjson | .kind == "worker-oom-death")' "$FIXTURE_RECUT_LOG" >/dev/null \
  || fail "the recut route must receive the issue and the death evidence"
jq -e --arg id "$unit_c" '.units[] | select(.id==$id) | .worker_death.rc == 137 and .worker_death.signal == "KILL"' "$UNITS" >/dev/null \
  || fail "the OOM death must record exit code and signal"

# ---- 4. 无 footer 的旧日志：bash 作业消息退回辨认信号 --------------------------------------
pid_d="$(dead_pid)"
printf 'autopilot-worker: line 1: 1925806 Aborted                 "$@" > "$out.partial"\n' > "$sup/review-legacy.worker.log"
death_json="$(worker_death_of "$sup/review-legacy.worker.log")"
jq -e '.rc == 134 and .signal == "ABRT"' <<<"$death_json" >/dev/null \
  || fail "legacy logs without a footer must still diagnose the signal from the bash job message: $death_json"

# New dispatches keep exit metadata in a sidecar, so parsing provider output needs no footer.
printf 'provider JSON remains in the worker log\n' > "$sup/review-sidecar.worker.log"
printf '{"type":"pipeline.exit","rc":134}\n' > "$sup/review-sidecar.worker.log.pipeline-exit"
death_json="$(worker_death_of "$sup/review-sidecar.worker.log")"
jq -e '.rc == 134 and .signal == "ABRT"' <<<"$death_json" >/dev/null \
  || fail "the exit sidecar must supply the worker status without a footer in provider output: $death_json"

# ---- 5. 退出足迹包装的落盘行为：成功留报告，信号死亡只留 footer 与 partial -----------------
# 模拟 dispatch 的 WORKER_STDOUT_REPORT 包装（同一条 bash -c）在一个假 CLI 上执行。
out="$fixture/stdout-report.md"; log="$fixture/wrapped.worker.log"; exit_file="$fixture/wrapped.worker.pipeline-exit"
rm -f -- "$out" "$out.partial"
( bash -c 'exit_file=$1; out=$2; shift 2; rc=0; "$@" > "$out.partial" && [ -s "$out.partial" ] && mv -f "$out.partial" "$out" || rc=$?; printf "{\"type\":\"pipeline.exit\",\"rc\":%s}\n" "$rc" > "$exit_file"; exit "$rc"' \
    autopilot-worker "$exit_file" "$out" printf 'VERDICT: READY\n' ) > "$log" 2>&1
grep -Fq 'VERDICT: READY' "$out" || fail "a successful stdout-report worker must still land its report"
(jq -e '.type == "pipeline.exit" and .rc == 0' "$exit_file" >/dev/null) || fail "success must leave an rc=0 exit sidecar"
! grep -Fq 'pipeline.exit' "$log" || fail "exit sidecar must not contaminate provider output"
rm -f -- "$out" "$out.partial"
( bash -c 'exit_file=$1; out=$2; shift 2; rc=0; "$@" > "$out.partial" && [ -s "$out.partial" ] && mv -f "$out.partial" "$out" || rc=$?; printf "{\"type\":\"pipeline.exit\",\"rc\":%s}\n" "$rc" > "$exit_file"; exit "$rc"' \
    autopilot-worker "$exit_file" "$out" bash -c 'echo partial text; kill -ABRT $$' ) > "$log" 2>&1 || test $? -eq 134
[[ ! -f "$out" ]] || fail "a killed stdout-report worker must not land a report"
[[ -s "$out.partial" ]] || fail "the killed worker's partial output must stay for the provider-limit check"
jq -e '.type == "pipeline.exit" and .rc == 134' "$exit_file" >/dev/null || fail "a signal death must leave the exit sidecar (rc=134)"

echo "ok - worker-death-diagnosis.test.sh"
