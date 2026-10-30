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
    echo "[$(date -u +%FT%TZ)] TICK-TIMEOUT scheduler tick killed after ${AUTOPI_TICK_LIMIT_SECONDS:-1800}s; the next tick clears the stale lock" \
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
    echo "[$(date -u +%FT%TZ)] REFILL-TIMEOUT refill tick killed after ${AUTOPI_REFILL_LIMIT_SECONDS:-300}s; the next tick clears the stale lock" \
      | tee -a "$A/scheduler.log" >> "$A/alerts/waste.md"
  fi
  return 0
}
# #4628: the slow tick runs beside the refill controller. The scheduler yields the same ledger lock
# around slow GitHub phases; a busy refill returns 75 and is retried five seconds later.
refill_window() { # seconds [slow-tick-pid]：慢 tick 存活期间，或下一拍前的补派窗口
  local slept=0 cadence="${AUTOPI_REFILL_SECONDS:-30}" signature rc
  REFILL_SINCE="${REFILL_SINCE:-0}"
  REFILL_LAST_EXIT="${REFILL_LAST_EXIT:-}"
  while :; do
    if [[ -n "${2:-}" ]]; then
      pid_running "$2" || break
    else
      (( slept < $1 )) || break
    fi
    sleep 5; slept=$((slept + 5)); REFILL_SINCE=$((REFILL_SINCE + 5))
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
