#!/usr/bin/env bash
# autopilot 启动：发布 commit-pinned 代码版本 → 起常驻 loop（scheduler/bell/zombie）。
#   --sync-only  只发布版本与默认 config，不启动任何 loop（接管/预演用）。
# 已安装 systemd 用户单元（ops/host-units/zenoforge-autopilot-*.service）时交给 systemd 托管，
# 否则回退 nohup。看板只打印绝对路径，不自动打开桌面窗口。
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd -P)"
source "$SRC/runtime-env.sh"
RUN="$MAC_AUTOPILOT_SUPERVISOR_DIR"
A="$MAC_AUTOPILOT_RUNTIME_DIR"
LIVE="$RUN/autopi-live"
VERSIONS="$RUN/autopi-versions"
SYNC_ONLY=0
[[ "${1:-}" == "--sync-only" ]] && SYNC_ONLY=1
mkdir -p "$A/alerts" "$VERSIONS"
head="$(git -C "$MAC_AUTOPILOT_ROOT" rev-parse HEAD)"
version="$VERSIONS/$head"
if [[ ! -d "$version" ]]; then
  stage="$(mktemp -d "$VERSIONS/.stage.XXXXXX")"
  trap 'rm -rf -- "$stage"' EXIT
  # Archive the whole tracked engine tree: a hand-kept file list missed verification-plan-runtime.sh
  # and every pinned runtime failed sourcing it (10-29, #4618). 14 MB per version; only two are kept.
  # engine/matt-skills.sh falls back to <version>/.agents/skills, so publish it too; an unconditional pathspec aborts for repos without it.
  paths=(engine)
  git -C "$MAC_AUTOPILOT_ROOT" cat-file -e "$head:.agents/skills" 2>/dev/null && paths+=(.agents/skills)
  git -C "$MAC_AUTOPILOT_ROOT" archive "$head" "${paths[@]}" | tar -x -C "$stage"
  mv "$stage" "$version"
  trap - EXIT
fi
code="$version/engine/mac-autopilot"
source "$code/config-reconcile.sh"
reconcile_event="$(reconcile_runtime_config "$code/config.template.json" "$A/config.json" "$MAC_AUTOPILOT_ROOT/engine/lib.sh")"
if [[ -n "$reconcile_event" ]]; then
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reconcile_event" | tee -a "$A/scheduler.log"
fi
[[ -f "$A/units.json" ]] || echo '{"units":[]}' > "$A/units.json"
previous="$(readlink "$LIVE" || true)"
target="autopi-versions/$head/engine/mac-autopilot"
# Publish only a complete version; retain the prior tick's sibling files until the next switch.
ln -sfn "$target" "$RUN/.autopi-live.$$"
mv -Tf "$RUN/.autopi-live.$$" "$LIVE"
ln -sfn ../autopi-live/dashboard.html "$A/dashboard.html"
if [[ "$previous" != "$target" ]]; then
  previous="${previous#autopi-versions/}"; previous="${previous%%/*}"
  for old in "$VERSIONS"/*; do
    [[ -d "$old" && "$old" != "$version" && "${old##*/}" != "$previous" ]] || continue
    rm -rf -- "$old"
  done
fi
# Keep legacy code copies in autopi/ until the operator switches the installed units.
echo "synced autopilot runtime: $LIVE ($head)"
echo "dashboard: $A/dashboard.html"
(( SYNC_ONLY )) && exit 0

UNITS=(zenoforge-autopilot-scheduler.service zenoforge-autopilot-bell.service zenoforge-autopilot-zombie.service)
if command -v systemctl >/dev/null 2>&1 && systemctl --user cat "${UNITS[0]}" >/dev/null 2>&1; then
  systemctl --user restart "${UNITS[@]}"
  echo "restarted systemd units: ${UNITS[*]}"
  exit 0
fi
for loop in loop.sh bell-loop.sh zombie-loop.sh; do
  pkill -f "autopi(-live)?/${loop//./[.]}" 2>/dev/null || true  # legacy autopi/ copies too, until they are removed
done
sleep 1
for loop in loop.sh bell-loop.sh zombie-loop.sh; do
  nohup bash "$LIVE/$loop" >/dev/null 2>&1 </dev/null &
  echo "$!" > "$A/${loop%.sh}.pid"
  echo "$loop pid $!"
done
