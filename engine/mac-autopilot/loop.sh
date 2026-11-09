#!/usr/bin/env bash
# autopilot 常驻 loop：每 tick_seconds（默认 120s）一拍慢 scheduler（GitHub 环节：登记→派发→门禁→合并→发布）；
# 慢 tick 同时有本地补派循环（#4628：每 30 秒或 worker 退出后触发）；每 15 拍跑一次可选 watcher。
# 由 systemd 单元（zenoforge-autopilot-scheduler）或 start.sh 托管。
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/runtime-env.sh"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
LIVE="$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live"
# 一拍有上限：2026-10-21 22:25 一拍在纯 bash 里处理 50MB 日志转了 17 分钟，期间不派活、不合并、不发布，也没人知道（L76）。
# 历史最长正常拍 1032 秒。--foreground 只终止 scheduler 本身；worker/land 都 setsid 自成进程组，不受影响。
run_tick() {
  local rc=0
  timeout --foreground -k 30 "${AUTOPI_TICK_LIMIT_SECONDS:-1800}" bash "$LIVE/scheduler.sh" >> "$A/loop.out" 2>&1 || rc=$?
  if (( rc == 124 || rc == 137 )); then
    # The one line is also the alert (waste.md), so a kill names its phase and the finished ones without a log read.
    echo "[$(date -u +%FT%TZ)] TICK-TIMEOUT scheduler tick killed after ${AUTOPI_TICK_LIMIT_SECONDS:-1800}s in phase $(cat "$A/.tick-phase" 2>/dev/null || echo unknown) after done: $(paste -sd, "$A/.tick-phases" 2>/dev/null || echo none); the next tick clears the stale lock" \
      | tee -a "$A/scheduler.log" >> "$A/alerts/waste.md"
  fi
  return 0
}
# 补派 tick（#4628）：单独限时，避免本地 clone/dispatch 卡住 refill controller。
run_refill() {
  local rc=0
  timeout --foreground -k 30 "${AUTOPI_REFILL_LIMIT_SECONDS:-300}" bash "$LIVE/scheduler.sh" --refill >> "$A/loop.out" 2>&1 || rc=$?
  (( rc != 75 )) || return 75 # shared scheduler lock is busy; keep the refill due and retry on the next poll
  if (( rc == 124 || rc == 137 )); then
    echo "[$(date -u +%FT%TZ)] REFILL-TIMEOUT refill tick killed after ${AUTOPI_REFILL_LIMIT_SECONDS:-300}s in phase $(cat "$A/.refill-phase" 2>/dev/null || echo unknown); the next tick clears the stale lock" \
      | tee -a "$A/scheduler.log" >> "$A/alerts/waste.md"
  fi
  return 0
}
# Dashboard data on its own cadence, not the tick's: a full tick takes 730-920s and gen_dashboard runs only at its end, so the page
# aged past bell.sh's 900s stale line. A detached `--views dashboard` owns VIEWS_LOCK (overlaps skip themselves), so this never blocks the poll.
launch_dashboard_views() {
  local every="${AUTOPI_DASHBOARD_SECONDS:-300}"
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 30 )) || every=300
  DASH_NEXT="${DASH_NEXT:-$((SECONDS + every))}" # first run one cadence after loop start: the tick-end full run covers the start
  (( SECONDS >= DASH_NEXT )) || return 0
  DASH_NEXT=$((SECONDS + every))
  setsid timeout -k 30 900 bash "$LIVE/scheduler.sh" --views dashboard >> "$A/views.log" 2>&1 < /dev/null &
}
# ci_admission as its own station (scheduler.sh --ci-admission): a free CI slot must not wait on the 20+ minute tick or the 300 s refill.
# The scheduler holds its own lock and a pass still running makes a new one exit at once, so this only paces the launches. The
# tick skips ci_admission while a pass started recently, and runs it again if this loop is an older one that never launches it.
launch_ci_admission() {
  local every="${AUTOPI_CI_ADMISSION_SECONDS:-120}"
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 30 )) || every=120
  CI_ADMISSION_NEXT="${CI_ADMISSION_NEXT:-$((SECONDS + every))}" # like the dashboard: the first pass is one cadence after loop start, the tick covers the gap
  (( SECONDS >= CI_ADMISSION_NEXT )) || return 0
  CI_ADMISSION_NEXT=$((SECONDS + every))
  setsid timeout -k 30 "${AUTOPI_CI_ADMISSION_KILL_SECONDS:-600}" bash "$LIVE/scheduler.sh" --ci-admission >> "$A/loop.out" 2>&1 < /dev/null &
}
# The merge lane as its own station (scheduler.sh --merge): a CLEAN PR must not wait for a refill that spent its budget on dispatch, or for a tick that is
# killed before its merge phase (no pass 10:11Z-, 2026-11-08). Same pacing as the CI station: the merge-lane flock makes an overlapping pass skip itself,
# so this only spaces the launches. The refill and the tick merge themselves while no pass started recently (an older loop, or a stuck station).
launch_merge_station() {
  local every="${AUTOPI_MERGE_STATION_SECONDS:-60}"
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 30 )) || every=60
  MERGE_STATION_NEXT="${MERGE_STATION_NEXT:-$((SECONDS + every))}"
  (( SECONDS >= MERGE_STATION_NEXT )) || return 0
  MERGE_STATION_NEXT=$((SECONDS + every))
  setsid timeout -k 30 "${AUTOPI_MERGE_STATION_KILL_SECONDS:-600}" bash "$LIVE/scheduler.sh" --merge >> "$A/loop.out" 2>&1 < /dev/null &
}
# The harvest group as its own station (scheduler.sh --harvest-station): finished workers must not wait for the 800-1500 s tick.
# Same pacing as the CI station: the scheduler holds its own lock, so this only spaces the launches, and the tick harvests itself
# while no pass started recently (this loop is an older one, or the station is stuck).
launch_harvest_station() {
  local every="${AUTOPI_HARVEST_STATION_SECONDS:-60}"
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 30 )) || every=60
  HARVEST_STATION_NEXT="${HARVEST_STATION_NEXT:-$((SECONDS + every))}"
  (( SECONDS >= HARVEST_STATION_NEXT )) || return 0
  HARVEST_STATION_NEXT=$((SECONDS + every))
  setsid timeout -k 30 "${AUTOPI_HARVEST_STATION_KILL_SECONDS:-600}" bash "$LIVE/scheduler.sh" --harvest-station >> "$A/loop.out" 2>&1 < /dev/null &
}
# The intake existing walk as its own station (scheduler.sh --existing-walk): units already in the ledger must not wait for the tick to be walked
# through intake's handoff block. Same pacing and fallback as the harvest station; the tick walks itself while no pass started recently.
launch_existing_walk() {
  local every="${AUTOPI_EXISTING_WALK_SECONDS:-60}"
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 30 )) || every=60
  EXISTING_WALK_NEXT="${EXISTING_WALK_NEXT:-$((SECONDS + every))}"
  (( SECONDS >= EXISTING_WALK_NEXT )) || return 0
  EXISTING_WALK_NEXT=$((SECONDS + every))
  setsid timeout -k 30 "${AUTOPI_EXISTING_WALK_KILL_SECONDS:-600}" bash "$LIVE/scheduler.sh" --existing-walk >> "$A/loop.out" 2>&1 < /dev/null &
}
# #4628: the slow tick runs beside the refill controller. The scheduler yields the same ledger lock
# around slow GitHub phases; a busy refill returns 75 and is retried five seconds later.
refill_window() { # seconds [slow-tick-pid]：慢 tick 存活期间，或下一拍前的补派窗口
  local cadence="${AUTOPI_REFILL_SECONDS:-30}" signature rc started=$SECONDS
  REFILL_SINCE="${REFILL_SINCE:-0}"
  REFILL_LAST_EXIT="${REFILL_LAST_EXIT:-}"
  while :; do
    if [[ -n "${2:-}" ]]; then
      pid_running "$2" || break
    else
      # wall clock, not summed sleeps: run_refill time inside the window used to stretch the idle gap past tick_seconds (#4686)
      (( SECONDS - started < $1 )) || break
    fi
    sleep 5; REFILL_SINCE=$((REFILL_SINCE + 5))
    launch_dashboard_views
    launch_ci_admission
    launch_merge_station
    launch_harvest_station
    launch_existing_walk
    signature="$(exited_worker_signature "$A/workers.json")"
    [[ -n "$signature" ]] || REFILL_LAST_EXIT=""
    if [[ -n "$signature" && "$signature" != "$REFILL_LAST_EXIT" ]] || (( REFILL_SINCE >= cadence )); then
      rc=0; run_refill || rc=$?
      if (( rc != 75 )); then
        REFILL_SINCE=0
        [[ -z "$signature" ]] || REFILL_LAST_EXIT="$signature"
      fi
    fi
  done
}
exited_worker_signature() {
  local pid
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    pid_running "$pid" || printf '%s\n' "$pid"
  done < <(jq -r '.workers[]? | select(.harvested != true) | .pid' "$1" 2>/dev/null) | sort -n | paste -sd, -
}
pid_running() { # read /proc directly: the 5s refill poll spawned one ps per worker (~14/s, 10-29 load 39)
  pid_live "$1" # proc.sh: that /proc read on Linux, ps on macOS
}
# 落到 main 的机制改动下一拍就生效（维护者：非产品代码做完马上生效）：run-tick 每拍 fast-forward 源 checkout，
# 它的 HEAD 变了就发布 pinned 版本并切换 live 指针。10-22 之前只能手工 start.sh --sync-only，修好的 advisor 与冷却晚生效一小时。
sync_from_main() {
  local src="$MAC_AUTOPILOT_ROOT/engine/mac-autopilot" head
  [[ -f "$src/start.sh" ]] || return 0
  head="$(git -C "$MAC_AUTOPILOT_ROOT" rev-parse HEAD 2>/dev/null)" || return 0
  [[ "$head" == "$(cat "$A/.synced-head" 2>/dev/null)" ]] && return 0
  if bash "$src/start.sh" --sync-only >> "$A/loop.out" 2>&1; then
    echo "$head" > "$A/.synced-head"
    echo "[$(date -u +%FT%TZ)] SYNC runtime from main $head" >> "$A/scheduler.log"
  fi
}
[[ "${AUTOPI_LOOP_LIBRARY_ONLY:-false}" == true ]] && return 0
bash "$HERE/wait-scheduler-lock.sh" || : # a restart keeps the old tick (KillMode=process); do not start a tick that must skip on its lock
n=0
while true; do
  sync_from_main
  run_tick & slow_pid=$!
  tick="$(jq -r '.tick_seconds // 120' "$A/config.json" 2>/dev/null)"
  [[ "$tick" =~ ^[0-9]+$ ]] && (( tick >= 30 )) || tick=120
  refill_window 0 "$slow_pid"
  wait "$slow_pid" || :
  refill_window "$tick"
  n=$((n+1))
  watcher="$MAC_AUTOPILOT_SUPERVISOR_DIR/watcher/watch.sh"
  if (( n % 15 == 0 )) && [[ -f "$watcher" ]]; then
    bash "$watcher" >> "$A/loop.out" 2>&1
  fi
done
