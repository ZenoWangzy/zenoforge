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
# The pin is a worktree of the engine's own repository: the target checkout, unless ZF_ENGINE_DIR names an
# engine that lives in another checkout (ENGINE_REL = where the engine sits inside that repository).
# An engine outside every git work tree is an immutable version directory (engine-versions/<id>/engine, Line B): there is
# nothing to pin, the directory is the pin. Its engine-sync entry checks the version before the live pointer follows it.
# The zenoforge CLI is the other non-git case: it links ~/.zenoforge/engine/<version> into the checkout as engine/
# (untracked), so git has nothing to archive. CLI_LINK pins by that version's directory name and copies the linked version.
ENGINE_REPO="$MAC_AUTOPILOT_ROOT" ENGINE_REL=engine IMMUTABLE=0 CLI_LINK=0
engine_dir="${ZF_ENGINE_DIR:-$(cd "$SRC/.." && pwd -P)}"
if ! git -C "$engine_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -L "$MAC_AUTOPILOT_ROOT/engine" && -z "${ZF_ENGINE_DIR:-}" ]]; then
    CLI_LINK=1
  else
    IMMUTABLE=1 ENGINE_REL=. ZF_ENGINE_DIR="$engine_dir"
    export ZF_ENGINE_DIR
  fi
elif [[ -n "${ZF_ENGINE_DIR:-}" ]]; then
  ENGINE_REPO="$(git -C "$ZF_ENGINE_DIR" rev-parse --show-toplevel)"
  ENGINE_REL="$(git -C "$ZF_ENGINE_DIR" rev-parse --show-prefix)"; ENGINE_REL="${ENGINE_REL%/}"
  export ZF_ENGINE_DIR # the pin self-check runs the scheduler in child shells
fi
if (( IMMUTABLE )); then
  head="$(basename "$(dirname "$(readlink -f "$engine_dir")")")" version="$engine_dir" # the version id
else
  if (( CLI_LINK )); then head="$(basename -- "$engine_dir")"; else head="$(git -C "$ENGINE_REPO" rev-parse HEAD)"; fi
  version="$VERSIONS/$head"
fi
if (( ! IMMUTABLE )) && [[ ! -d "$version" ]]; then
  if (( CLI_LINK )); then
    # CLI install: engine/ is an untracked link to an engine version, so a worktree of this checkout would not
    # contain it. Copy the linked version, and the skills its checkout keeps next to engine/.
    stage="$(mktemp -d "$VERSIONS/.stage.XXXXXX")"
    trap 'rm -rf -- "$stage"' EXIT
    mkdir "$stage/engine"
    tar -c -C "$MAC_AUTOPILOT_ROOT/engine/" . | tar -x -C "$stage/engine"
    skills="$(cd -P "$MAC_AUTOPILOT_ROOT/engine/.." && pwd)/.agents/skills"
    [[ -d "$skills" ]] && { mkdir -p "$stage/.agents"; cp -R "$skills" "$stage/.agents/skills"; }
    mv "$stage" "$version"
    trap - EXIT
  else
    # Full-tree pinned worktree, objects shared with the live checkout; no copy list can miss files
    # again (10-29: the archive list missed verification-plan-runtime.sh, #4618, and
    # engine/ci/pr-required-aggregate.mjs, 8fb5cdbc3 — ~2h with zero merges). --lock, and the reason
    # names the scheduler unit: worktree-lifecycle's reaper releases bare locks after 24h but never
    # a lock owned by the live unit (10-25 the lane deleted three unlocked detached worker worktrees).
    git -C "$ENGINE_REPO" worktree add --detach --lock \
      --reason "autopi pin: unit=${UNIT_PREFIX}-autopilot-scheduler.service" "$version" "$head"
  fi
fi
code="$version/$ENGINE_REL/mac-autopilot"
source "$code/config-reconcile.sh"
reconcile_event="$(reconcile_runtime_config "$code/config.template.json" "$A/config.json" "${ZF_ENGINE_DIR:-$MAC_AUTOPILOT_ROOT/engine}/lib.sh")"
if [[ -n "$reconcile_event" ]]; then
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reconcile_event" | tee -a "$A/scheduler.log"
fi
[[ -f "$A/units.json" ]] || echo '{"units":[]}' > "$A/units.json"
previous="$(readlink "$LIVE" || true)"
# 切 live 指针前先让新 pin 里的 scheduler 自检（10-29 两次事故都是 pin 缺文件）。复用 scheduler
# 的 library 模式（scheduler suites 同一入口）：完整 source 四个 lib 文件，再核对 scheduler.sh
# 代码里每个 $HERE 相对引用（含 ../../ci/* 与 source 的 lib 文件）在新 pin 内真实存在。
# 文件齐全 ≠ census 可用：10-29 --latest-checks 的输出在 64 KiB 管道边界被截断，存在性检查全过。
# 所以再用 live 打开 PR 集合在新 pin 里跑一遍合并车道同一条 census 链，结果不是对象即拒绝切换；零个打开 PR 是合法的空 census（{}），读失败或格式错才是不可用。
pin_scheduler_self_check() { # version-dir → 0 = 该 pin 可以切 live
  local code="$1/$ENGINE_REL/mac-autopilot" ref
  AUTOPI_TEST_LIBRARY_ONLY=true bash "$code/scheduler.sh" || return 1
  while IFS= read -r ref; do
    [[ -e "$code/${ref#\$HERE/}" ]] || { echo "pin self-check: $1 lacks $ref" >&2; return 1; }
  done < <(grep -vE '^[[:space:]]*#' "$code/scheduler.sh" | grep -hoE '\$HERE/[A-Za-z0-9._/-]+' | sort -u)
  ( cd "$MAC_AUTOPILOT_ROOT" && AUTOPI_TEST_LIBRARY_ONLY=true bash -c '
      set -o pipefail
      source "$1/scheduler.sh"   # $HERE 落在新 pin 内，census 链用的 aggregate/jqf 都是 pin 里的这份
      tick_prs | pr_census_by_number | jqf -e "type == \"object\"" >/dev/null
    ' _ "$code" ) || { echo "pin self-check: live merge census unusable in $1" >&2; return 1; }
}
if (( IMMUTABLE )); then
  self_check=("$engine_dir/engine-sync.sh" --check "$(dirname "$(readlink -f "$engine_dir")")")
else
  self_check=(pin_scheduler_self_check "$version")
fi
if ! "${self_check[@]}"; then
  printf '[%s] SELF-CHECK FAILED pin=%s; live stays at %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$head" "${previous:-none}" | tee -a "$A/scheduler.log" >&2
  exit 1
fi
target="autopi-versions/$head/$ENGINE_REL/mac-autopilot"
(( ! IMMUTABLE )) || target="$engine_dir/mac-autopilot"
# Publish only a complete version; retain the prior tick's sibling files until the next switch.
ln -sfn "$target" "$RUN/.autopi-live.$$"
mv -Tf "$RUN/.autopi-live.$$" "$LIVE"
ln -sfn ../autopi-live/dashboard.html "$A/dashboard.html"
if (( ! IMMUTABLE )) && [[ "$previous" != "$target" ]]; then
  previous="${previous#autopi-versions/}"; previous="${previous%%/*}"
  for old in "$VERSIONS"/*; do
    [[ -d "$old" && "$old" != "$version" && "${old##*/}" != "$previous" ]] || continue
    if git -C "$ENGINE_REPO" worktree list --porcelain | grep -Fxq "worktree $old"; then
      # Pinned worktrees go through unlock+remove; rm -rf would leave a stale record that
      # breaks the next pin of the same SHA.
      git -C "$ENGINE_REPO" worktree unlock "$old" 2>/dev/null || true
      git -C "$ENGINE_REPO" worktree remove "$old" 2>/dev/null || true
    else
      rm -rf -- "$old"  # archive-based copy from before full-tree pins; no worktree record exists
    fi
  done
fi
# Keep legacy code copies in autopi/ until the operator switches the installed units.
echo "synced autopilot runtime: $LIVE ($head)"
echo "dashboard: $A/dashboard.html"
(( SYNC_ONLY )) && exit 0

if autopilot_manual_pause_is_valid; then
  echo "paused, not restarting"
  exit 0
fi

UNITS=(${UNIT_PREFIX}-autopilot-scheduler.service ${UNIT_PREFIX}-autopilot-bell.service ${UNIT_PREFIX}-autopilot-zombie.service)
if command -v systemctl >/dev/null 2>&1 && systemctl --user cat "${UNITS[0]}" >/dev/null 2>&1; then
  systemctl --user restart "${UNITS[@]}"
  echo "restarted systemd units: ${UNITS[*]}"
  exit 0
fi
for loop in loop.sh bell-loop.sh zombie-loop.sh; do
  pkill -f "autopi(-live)?/${loop//./[.]}" 2>/dev/null || true  # legacy autopi/ copies too, until they are removed
done
sleep 1
for loop in loop.sh bell-loop.sh; do
  [[ -f "$LIVE/$loop" ]] || { echo "$loop not in $LIVE: not started" >&2; continue; }
  nohup bash "$LIVE/$loop" >/dev/null 2>&1 </dev/null &
  echo "$!" > "$A/${loop%.sh}.pid"
  echo "$loop pid $!"
done
zombie_loop=""
if declare -F zf_config_file >/dev/null; then
  zombie_loop="$(zf_config_file mac-autopilot/zombie-loop.sh 2>/dev/null || true)"
fi
[[ -n "$zombie_loop" ]] || zombie_loop="$LIVE/zombie-loop.sh"
if [[ -f "$zombie_loop" ]]; then
  nohup bash "$zombie_loop" >/dev/null 2>&1 </dev/null &
  echo "$!" > "$A/zombie-loop.pid"
  echo "zombie-loop.sh pid $!"
else
  echo "zombie-loop.sh not found: not started" >&2
fi
