#!/usr/bin/env bash
# 卡住任务处置（#4371）：消费 f8（#4366）的 WIP 年龄信号——
#   超阈值单元的活 worker 指纹无进展（跨确认窗口不变）→ 停止（含后端进程组）并 requeue；
#   同一单元第 2 次卡住 → #4363（f6）止损路由：hold.sh on-hold + supervisor 裁决；
#   有进展（事件流/工作克隆变化）的长任务不停；窗口内、信号健康或无 scorecard 时不动作。
# 复用 aged-pr-lifecycle.test.sh 的 fixture 模式：真进程（ps/kill 真跑），GitHub 调用经 gh-shim。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/stuck"; sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts"
cp "$script_dir/config.template.json" "$sup/autopi/config.json"
printf '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$test_env_root/repo-root"; mkdir -p "$MAC_AUTOPILOT_ROOT"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$sup"
export CODEX_SESSIONS_DIR="$fixture/sessions" AUTOPI_TEST_LIBRARY_ONLY=true
unset GH_TOKEN GITHUB_TOKEN
export REQUIRED_PR_CHECKS_FILE="$test_env_root/required-pr-checks.json"
printf '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
mkdir -p "$MAC_AUTOPILOT_ROOT/engine"
cat > "$MAC_AUTOPILOT_ROOT/engine/hold.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE_HOLD_LOG"
[[ "${FIXTURE_HOLD_FAIL:-0}" != 1 ]]
SH
cat > "$test_env_root/bin/gh-real" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FIXTURE_GH_LOG"
SH
chmod +x "$MAC_AUTOPILOT_ROOT/engine/hold.sh" "$test_env_root/bin/gh-real"
export FIXTURE_HOLD_LOG="$fixture/hold.calls" FIXTURE_GH_LOG="$fixture/gh.calls"
export ZF_GH_REAL_CLI="$test_env_root/bin/gh-real"
export ZF_TEST_EVIDENCE_LEDGER="$fixture/test-evidence.jsonl"
touch "$ZF_TEST_EVIDENCE_LEDGER"
export PATH="$script_dir/../gh-shim:$test_env_root/bin:$PATH"

# alive() 用 ps 匹配参数里的 codex/claude：起一个 argv 带 codex 的真睡眠进程当活 worker
# （exec -a 保住名字，进程组=自身 pid，处置按组 TERM/KILL）。
sleeper="$test_env_root/codex-fake-sleeper.sh"
printf '#!/usr/bin/env bash\nsleep 600 & echo $! > "$1"\nexec -a codex-worker sleep 600\n' > "$sleeper"; chmod +x "$sleeper"
spawn_worker() {
  local name="$1" backend_file="$test_env_root/backend-$1.pid"
  setsid bash "$sleeper" "$backend_file" < /dev/null > /dev/null 2>&1 &
  local pid=$!
  for _ in {1..50}; do [[ -s "$backend_file" ]] && break; sleep 0.01; done
  printf '%s\n' "$pid" > "$test_env_root/worker-$name.pid"
  printf '%s' "$pid"
}
process_running() {
  local stat
  stat="$(ps -p "$1" -o stat= 2>/dev/null | tr -d ' ')"
  [[ -n "$stat" && "$stat" != Z* ]]
}
pid_dead() { ! process_running "$1"; }
wait_dead() {
  for _ in {1..50}; do pid_dead "$1" && return 0; sleep 0.02; done
  pid_dead "$1"
}
cleanup_workers() {
  local file pid
  for file in "$test_env_root"/worker-*.pid; do
    [[ -f "$file" ]] || continue
    pid="$(cat "$file")"
    kill -TERM -- "-$pid" 2>/dev/null || true
  done
  for file in "$test_env_root"/backend-*.pid; do
    [[ -f "$file" ]] || continue
    pid="$(cat "$file")"
    kill -TERM "$pid" 2>/dev/null || true
  done
}
trap cleanup_workers EXIT

# f8 scorecard fixture：UNHEALTHY 的 wip 年龄信号点名 review 阶段三张超龄单元。
scorecard() { # status
  jq -cn --arg status "$1" '{
    metrics: [{id:"flow.wip_age_stage_p90_hours", node:"flow", value:13.5, healthy:4, unhealthy:12, status:$status}],
    flow: {wip_age: [{stage:"review", count:3, p90_hours:13.5,
      oldest: [{id:"pr-77", age_hours:14}, {id:"pr-88", age_hours:13}, {id:"pr-99", age_hours:12.5}]}]}
  }'
}

iso_ago() { date -u -d "@$(( $(date -u +%s) - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ; }

# mk_unit id [jq-update]：stage=review、末事件 20h 前的单元，可选补丁（如 .stuck_probe=…）
mk_unit() {
  jq -cn --arg id "$1" --arg at "$(iso_ago 1200)" \
    '{id:$id, issue:4371, stage:"review", history:[{stage:"review-request-changes", at:$at}]}' | jq "${2:-.}"
}
probe_update() { # at-minutes-ago fp → 探针补丁表达式
  printf '.stuck_probe = %s' "$(jq -cn --arg at "$(iso_ago "$1")" --arg fp "$2" '{at:$at, fp:$fp}')"
}
mk_worker() { # unit pid [workdir] → worker json
  jq -cn --argjson pid "$2" --arg unit "$1" --arg log "worker-$1.log" --arg workdir "${3:-$fixture/notrepo}" --arg at "$(iso_ago 90)" \
    '{pid:$pid, unit:$unit, type:"review", log:$log, report:"r.md", started:$at, workdir:$workdir, model:"gpt-test"}'
}
mk_implement_worker() { # unit pid workdir → implement worker json
  jq -cn --argjson pid "$2" --arg unit "$1" --arg log "worker-$1.log" --arg workdir "$3" --arg at "$(iso_ago 1)" \
    '{pid:$pid, unit:$unit, type:"implement", log:$log, report:"r.md", started:$at, workdir:$workdir, model:"gpt-test"}'
}
write_units() { jq -cn --argjson a "$1" --argjson b "$2" --argjson c "$3" '{units:[$a,$b,$c]}' > "$sup/autopi/units.json"; }
write_workers() { jq -cn --argjson w "$1" '{workers:$w}' > "$sup/autopi/workers.json"; }
# worker 日志在 $SUP/<log>（dispatch 的落盘位置），不在 $SUP/autopi 下
fp_of() { stuck_worker_progress_fp "$(mk_worker "$1" "${2:-1}" "${3:-$fixture/notrepo}")"; }
seed_log() { mkdir -p "$fixture/notrepo"; printf 'event line 1\n' > "$sup/worker-$1.log"; }

fail() { echo "stuck-worker-disposition.test.sh: $*" >&2; exit 1; }
source "$script_dir/scheduler.sh"

FIXTURE_RECUT_LOG="$fixture/recut.calls"
FIXTURE_RECUT_FAIL_ISSUE=4372
export FIXTURE_RECUT_LOG FIXTURE_RECUT_FAIL_ISSUE
scheduler_recut_route() {
  local issue="$1" evidence="$2"
  jq -cn --arg issue "$issue" --argjson evidence "$evidence" '{issue:$issue,evidence:$evidence}' >> "$FIXTURE_RECUT_LOG"
  [[ "$issue" != "$FIXTURE_RECUT_FAIL_ISSUE" ]] || return 1
  printf '{"state":"needs-recut"}\n' > "$fixture/issue-state-$issue.json"
}
scheduler_issue_state() {
  local state_file="$fixture/issue-state-$1.json"
  [[ -f "$state_file" ]] && cat "$state_file" || printf '{}\n'
}

A="$MAC_AUTOPILOT_RUNTIME_DIR"
: > "$A/alerts/events.md"
CONFIRM=60  # 确认窗口 1 分钟：探针时间戳据此区分“窗口内”与“已过期”
worktree="$fixture/progress-repo"
mkdir -p "$worktree"
git -C "$worktree" init -q
git -C "$worktree" config user.name test
git -C "$worktree" config user.email test@example.invalid
printf 'baseline\n' > "$worktree/progress.txt"
git -C "$worktree" add progress.txt
git -C "$worktree" commit -qm baseline
printf 'working version one\n' > "$worktree/progress.txt"

pid1="$(spawn_worker pr-77-healthy)"; pid2="$(spawn_worker pr-88-progress)"; pid3="$(spawn_worker pr-99-window)"
seed_log pr-77; seed_log pr-88; seed_log pr-99

# ---- 1. 信号健康：不停止、不种探针 ----------------------------------------------------------
scorecard HEALTHY > "$A/node-health.json"
write_units "$(mk_unit pr-77)" "$(mk_unit pr-88)" "$(mk_unit pr-99)"
write_workers "[$(mk_worker pr-77 "$pid1"), $(mk_worker pr-88 "$pid2" "$worktree"), $(mk_worker pr-99 "$pid3")]"
STUCK_CONFIRM_MINUTES=$CONFIRM stuck_worker_disposition
kill -0 "$pid1" 2>/dev/null || fail "healthy signal must not kill worker pr-77"
[[ -z "$(unit_field pr-77 '.stuck_probe // empty')" ]] || fail "healthy signal must not seed a probe"
jq -e --argjson pid "$pid1" '.workers[] | select(.pid==$pid) | .harvested != true' "$WORKERS" >/dev/null || fail "worker must stay unharvested on healthy signal"

# ---- 2. UNHEALTHY：无进展（指纹跨窗口不变）→ 停止并 requeue；窗口内/指纹不同 → 只种探针 -----
scorecard UNHEALTHY > "$A/node-health.json"
write_units \
  "$(mk_unit pr-77 "$(probe_update 90 "$(fp_of pr-77)")")" \
  "$(mk_unit pr-88 "$(probe_update 90 "0|nogit|nogit")")" \
  "$(mk_unit pr-99 "$(probe_update 0 "$(fp_of pr-99)")")"
STUCK_CONFIRM_MINUTES=$CONFIRM stuck_worker_disposition
wait_dead "$pid1" || fail "no-progress worker pr-77 must be stopped (fingerprint unchanged across the window)"
wait_dead "$(cat "$test_env_root/backend-pr-77-healthy.pid")" || fail "the stuck worker's backend process must be stopped with its group"
jq -e --argjson pid "$pid1" '.workers[] | select(.pid==$pid) | .harvested == true and .stuck_killed == true' "$WORKERS" >/dev/null \
  || fail "stopped worker must be harvested with stuck_killed"
jq -e '.units[] | select(.id=="pr-77") | .stage == "review-pending" and ((.history // []) | any(.stage == "stuck-killed"))' "$UNITS" >/dev/null \
  || fail "first stuck must requeue the unit (review-pending) with history"
grep -q 'STUCK-KILL unit=pr-77' "$A/alerts/events.md" || fail "stuck kill must record an event"
[[ -z "$(unit_field pr-77 '.stuck_probe // empty')" ]] || fail "probe must be cleared after the kill"
kill -0 "$pid2" 2>/dev/null || fail "changed fingerprint (progress) must not stop pr-88"
kill -0 "$pid3" 2>/dev/null || fail "probe inside the confirm window must not stop pr-99"
jq -e --arg fp "$(fp_of pr-88 "$pid2" "$worktree")" '.units[] | select(.id=="pr-88") | .stuck_probe.fp == $fp' "$UNITS" >/dev/null \
  || fail "changed fingerprint must refresh the probe"

# ---- 3. 有进展的长任务：事件流和同一脏文件内容变化都刷新指纹，不停止 worker -----------------
old_fp="$(fp_of pr-88 "$pid2" "$worktree")"
printf "event line 2 (progress)\n" >> "$sup/worker-pr-88.log"
STUCK_CONFIRM_MINUTES=$CONFIRM stuck_worker_disposition
kill -0 "$pid2" 2>/dev/null || fail "progressing long task must not be stopped"
new_fp="$(fp_of pr-88 "$pid2" "$worktree")"
[[ "$old_fp" != "$new_fp" ]] || fail "event growth must change the progress fingerprint"
jq -e --arg fp "$new_fp" '.units[] | select(.id=="pr-88") | .stuck_probe.fp == $fp' "$UNITS" >/dev/null || fail "event growth must refresh the probe"
old_fp="$new_fp"
printf 'working version two\n' > "$worktree/progress.txt"
new_fp="$(fp_of pr-88 "$pid2" "$worktree")"
[[ "$old_fp" != "$new_fp" ]] || fail "editing an already-dirty file must change the progress fingerprint"
STUCK_CONFIRM_MINUTES=$CONFIRM stuck_worker_disposition
jq -e --arg fp "$new_fp" '.units[] | select(.id=="pr-88") | .stuck_probe.fp == $fp' "$UNITS" >/dev/null \
  || fail "dirty-file content progress must refresh the probe fingerprint"
printf 'untracked version one\n' > "$worktree/untracked-progress.txt"
old_fp="$(fp_of pr-88 "$pid2" "$worktree")"
printf 'untracked version two\n' > "$worktree/untracked-progress.txt"
new_fp="$(fp_of pr-88 "$pid2" "$worktree")"
[[ "$old_fp" != "$new_fp" ]] || fail "editing an untracked file must change the progress fingerprint"
STUCK_CONFIRM_MINUTES=$CONFIRM stuck_worker_disposition
jq -e --arg fp "$new_fp" '.units[] | select(.id=="pr-88") | .stuck_probe.fp == $fp' "$UNITS" >/dev/null \
  || fail "untracked-file content progress must refresh the probe fingerprint"
kill -TERM -- "-$pid2" 2>/dev/null || true; kill -TERM -- "-$pid3" 2>/dev/null || true

# ---- 4. 停滞确认 → 第 1 次卡住 requeue；第 2 次（历史已有一次）→ 止损路由 --------------------
pid4="$(spawn_worker pr-88-first-stuck)"
write_workers "[$(mk_worker pr-88 "$pid4" "$worktree")]"
write_units "$(mk_unit pr-77)" "$(mk_unit pr-88 "$(probe_update 90 "$(fp_of pr-88 "$pid4" "$worktree")")")" "$(mk_unit pr-99)"
STUCK_CONFIRM_MINUTES=$CONFIRM stuck_worker_disposition
wait_dead "$pid4" || fail "confirmed no-progress worker must be stopped"
jq -e '.units[] | select(.id=="pr-88") | .stage == "review-pending"' "$UNITS" >/dev/null \
  || fail "pr-88 first stuck must requeue"

pid5="$(spawn_worker pr-88-second-stuck)"
seed_log pr-88
write_workers "[$(mk_worker pr-88 "$pid5" "$worktree")]"
second_stuck_history='.history += [{stage:"stuck-killed", result:"no progress; episode 1", at:"'"$(iso_ago 25)"'"}]'
write_units "$(mk_unit pr-77)" \
  "$(mk_unit pr-88 "$(probe_update 90 "$(fp_of pr-88 "$pid5" "$worktree")") | $second_stuck_history")" \
  "$(mk_unit pr-99)"
STUCK_CONFIRM_MINUTES=$CONFIRM stuck_worker_disposition
wait_dead "$pid5" || fail "second stuck worker must be stopped too"
jq -e '.units[] | select(.id=="pr-88") | .stage == "supervisor-review" and ((.history // []) | any(.stage == "stuck-stoploss"))' "$UNITS" >/dev/null \
  || fail "second stuck must route to stop-loss (supervisor-review + stuck-stoploss)"
grep -q 'STUCK-STOPLOSS unit=pr-88' "$A/alerts/events.md" || fail "stop-loss must record an event"
grep -Fq -- '--hold 4371 --holder scheduler-stop-loss' "$FIXTURE_HOLD_LOG" || fail "second stuck must apply the existing issue hold path"
grep -Fq 'gh issue comment 4371' "$FIXTURE_GH_LOG" || fail "second stuck must report the stop-loss action through gh-shim"

# Hold failure is visible and the unit stays parked without claiming the issue was held.
pid7="$(spawn_worker pr-77-hold-fails)"
seed_log pr-77
hold_failure_history='.history += [{stage:"stuck-killed", result:"no progress; episode 1", at:"'"$(iso_ago 25)"'"}]'
write_workers "[$(mk_worker pr-77 "$pid7")]"
write_units \
  "$(mk_unit pr-77 "$(probe_update 90 "$(fp_of pr-77 "$pid7")") | $hold_failure_history")" \
  "$(mk_unit pr-88)" "$(mk_unit pr-99)"
FIXTURE_HOLD_FAIL=1 STUCK_CONFIRM_MINUTES=$CONFIRM stuck_worker_disposition
wait_dead "$pid7" || fail "second stuck worker must stop when the hold action fails"
jq -e '.units[] | select(.id=="pr-77") | .stage == "supervisor-review" and (.note | contains("hold could not be applied"))' "$UNITS" >/dev/null \
  || fail "failed hold must park the unit with an honest supervisor note"
grep -q 'STUCK-HOLD-FAILED unit=pr-77' "$A/alerts/events.md" || fail "failed hold must emit a visible event"
unset FIXTURE_HOLD_FAIL

# ---- 5. 信号恢复（HEALTHY）→ 清掉残留探针 ----------------------------------------------------
scorecard HEALTHY > "$A/node-health.json"
write_units "$(mk_unit pr-77 "$(probe_update 90 stale)")" "$(mk_unit pr-88)" "$(mk_unit pr-99)"
STUCK_CONFIRM_MINUTES=$CONFIRM stuck_worker_disposition
[[ -z "$(unit_field pr-77 '.stuck_probe // empty')" ]] || fail "recovered signal must clear stale probes"

# ---- 6. 无 scorecard（f8 未跑）：不动任何东西 -------------------------------------------------
rm -f "$A/node-health.json"
pid6="$(spawn_worker pr-77-no-scorecard)"
seed_log pr-77
write_workers "[$(mk_worker pr-77 "$pid6")]"
STUCK_CONFIRM_MINUTES=$CONFIRM stuck_worker_disposition
kill -0 "$pid6" 2>/dev/null || fail "missing scorecard must be a no-op"
kill -TERM -- "-$pid6" 2>/dev/null || true

# ---- 7. 盲区：不在 wip_age 点名名单、日志静默超过 slow_worker_minutes 的活 worker 也被探测并停止 --------
pid8="$(spawn_worker pr-55-unnamed)"
seed_log pr-55
touch -d '3 hours ago' "$sup/worker-pr-55.log"
scorecard HEALTHY > "$A/node-health.json"
write_workers "[$(mk_worker pr-55 "$pid8")]"
write_units "$(mk_unit pr-55 "$(probe_update 90 "$(fp_of pr-55 "$pid8")")")" "$(mk_unit pr-88)" "$(mk_unit pr-99)"
STUCK_CONFIRM_MINUTES=$CONFIRM stuck_worker_disposition
wait_dead "$pid8" || fail "unnamed worker with a log silent past slow_worker_minutes must be stopped"

# ---- 8. Implement command cap: over-cap workers route to recut, with supervisor fallback ----
test_cap="$(jqf -r '.implement_command_cap // 230' "$sup/autopi/config.json")"
[[ "$test_cap" == 230 ]] || fail "template command cap should default to 230, got $test_cap"
rm -f "$A/node-health.json"
cap_worktree="$fixture/command-cap-repo"
mkdir -p "$cap_worktree"
git -C "$cap_worktree" init -q
git -C "$cap_worktree" checkout -qb command-cap-worker
git -C "$cap_worktree" config user.name test
git -C "$cap_worktree" config user.email test@example.invalid
printf 'baseline\n' > "$cap_worktree/kept.txt"
git -C "$cap_worktree" add kept.txt
git -C "$cap_worktree" commit -qm baseline
printf 'uncommitted implementation\n' > "$cap_worktree/kept.txt"
cap_pid="$(spawn_worker implement-over-cap)"; fail_pid="$(spawn_worker implement-route-fails)"; exact_pid="$(spawn_worker implement-at-cap)"
cap_log="$sup/worker-cmdcap-over.log"; fail_log="$sup/worker-cmdcap-fail.log"; exact_log="$sup/worker-cmdcap-at.log"
over_cap=$((test_cap + 1))
: > "$cap_log"; : > "$fail_log"; : > "$exact_log"
for ((n=1; n<=over_cap; n++)); do
  printf -v command 'echo command-%03d' "$n"
  if (( n == over_cap )); then command+=" $(printf '%220s' '' | tr ' ' x)"; fi
  jq -cn --arg command "$command" '{type:"item.completed",item:{type:"command_execution",command:$command}}' >> "$cap_log"
  printf -v command 'echo failed-command-%03d' "$n"
  if (( n == over_cap )); then command+=" $(printf '%220s' '' | tr ' ' x)"; fi
  jq -cn --arg command "$command" '{type:"item.completed",item:{type:"command_execution",command:$command}}' >> "$fail_log"
done
for ((n=1; n<=test_cap; n++)); do
  printf -v command 'echo exact-command-%03d' "$n"
  jq -cn --arg command "$command" '{type:"item.completed",item:{type:"command_execution",command:$command}}' >> "$exact_log"
done
: > "$FIXTURE_HOLD_LOG"; : > "$FIXTURE_GH_LOG"; : > "$FIXTURE_RECUT_LOG"
write_workers "[$(mk_implement_worker cmdcap-over "$cap_pid" "$cap_worktree"), $(mk_implement_worker cmdcap-fail "$fail_pid" "$fixture/notrepo"), $(mk_implement_worker cmdcap-at "$exact_pid" "$fixture/notrepo")]"
write_units \
  "$(mk_unit cmdcap-over '.branch="command-cap-worker"')" \
  "$(mk_unit cmdcap-fail '.issue=4372 | .branch="command-cap-failure"')" \
  "$(mk_unit cmdcap-at)"
stuck_worker_disposition
wait_dead "$cap_pid" || fail "implement worker above the command cap must be stopped"
wait_dead "$fail_pid" || fail "implement worker whose recut route fails must be stopped"
kill -0 "$exact_pid" 2>/dev/null || fail "implement worker exactly at the command cap must keep running"
jq -e --argjson pid "$cap_pid" '.workers[] | select(.pid==$pid) | .harvested == true and .implement_command_capped.count == 231 and .implement_command_capped.cap == 230' "$WORKERS" >/dev/null \
  || fail "over-cap worker must be harvested with its command count and cap"
jq -e --argjson pid "$fail_pid" '.workers[] | select(.pid==$pid) | .harvested == true and .implement_command_capped.count == 231 and .implement_command_capped.cap == 230' "$WORKERS" >/dev/null \
  || fail "worker whose recut route fails must be harvested with its command count and cap"
jq -e --argjson pid "$exact_pid" '.workers[] | select(.pid==$pid) | .harvested != true' "$WORKERS" >/dev/null \
  || fail "worker exactly at the cap must stay unharvested"
jq -e '.units[] | select(.id=="cmdcap-over") | .stage == "blocked-external" and .size_recut_pending == true and .branch == "command-cap-worker" and any(.history[]; .stage=="implement-command-cap" and .result=="231/230 -> needs-recut") and (has("stuck_probe") | not)' "$UNITS" >/dev/null \
  || fail "over-cap unit must be blocked for recut with its branch and history"
jq -e '.units[] | select(.id=="cmdcap-fail") | .stage == "supervisor-review" and .note == "implement-command-cap: split" and any(.history[]; .stage=="implement-command-cap" and .result=="231/230")' "$UNITS" >/dev/null \
  || fail "failed recut route must fall back to supervisor review"
jq -e '.units[] | select(.id=="cmdcap-at") | .stage != "supervisor-review" and (all(.history[]?; .stage != "implement-command-cap"))' "$UNITS" >/dev/null \
  || fail "worker exactly at the cap must not be parked"
[[ "$(wc -l < "$FIXTURE_RECUT_LOG" | tr -d ' ')" == 2 ]] || fail "only over-cap workers must route to recut"
jq -e -s 'any(.[]; .issue=="4371" and .evidence.kind=="implement-command-cap" and .evidence.commands==231 and .evidence.limit==230 and .evidence.unit=="cmdcap-over" and .evidence.branch=="command-cap-worker" and (.evidence.stash | test("^[0-9a-f]{40}$")) and (.evidence.workdir | length > 0))' "$FIXTURE_RECUT_LOG" >/dev/null \
  || fail "successful recut route must receive implement-cap evidence and the unit branch"
jq -e -s 'any(.[]; .issue=="4372" and .evidence.kind=="implement-command-cap" and .evidence.commands==231 and .evidence.limit==230 and .evidence.unit=="cmdcap-fail" and .evidence.branch=="command-cap-failure")' "$FIXTURE_RECUT_LOG" >/dev/null \
  || fail "failed recut route must receive implement-cap evidence and the unit branch"
[[ ! -s "$FIXTURE_HOLD_LOG" ]] || fail "implement command cap must not create an issue hold"
! grep -Eq 'gh issue comment (4371|4372)' "$FIXTURE_GH_LOG" || fail "implement command cap must not comment on the issue"
grep -Fq 'IMPLEMENT-COMMAND-CAP unit=cmdcap-over' "$A/alerts/events.md" || fail "over-cap worker must keep its command-cap event line"
[[ "$(git -C "$cap_worktree" branch --show-current)" == command-cap-worker ]] || fail "command-cap stop must preserve the worker branch"
[[ "$(cat "$cap_worktree/kept.txt")" == baseline ]] || fail "command-cap stop must stash the uncommitted file"
git -C "$cap_worktree" stash list --format='%s' | head -n1 | grep -Fq 'autopilot: kept before redispatch' \
  || fail "command-cap stop must use the redispatch stash message"
git -C "$cap_worktree" stash show --format= --name-only 'stash@{0}' | grep -Fxq kept.txt \
  || fail "command-cap stash must contain the worker's uncommitted file"
cap_summary="$(jqf -r --arg id cmdcap-fail '[.units[] | select(.id==$id) | (.history // [])[] | select(.stage=="supervisor-escalated") | .decision.evidence] | last // ""' "$UNITS")"
grep -Fq 'recut route failed' <<<"$cap_summary" || fail "supervisor summary must explain the failed recut route"
summary_commands="$(sed -n '/^last 20 commands:$/,$p' <<<"$cap_summary" | tail -n +2)"
[[ "$(wc -l <<<"$summary_commands" | tr -d ' ')" -eq 20 ]] || fail "triage summary must attach the last 20 command fields"
grep -Fq 'echo failed-command-212' <<<"$summary_commands" || fail "triage summary must begin with failed-command 212"
grep -Fq 'echo failed-command-231' <<<"$summary_commands" || fail "triage summary must include failed-command 231"
[[ "$(tail -n1 <<<"$summary_commands" | wc -c | tr -d ' ')" -eq 201 ]] || fail "triage summary must cut each command field to 200 characters"
kill -TERM -- "-$exact_pid" 2>/dev/null || true

echo "stuck-worker-disposition.test.sh: all assertions passed"
