#!/usr/bin/env bash
# autopilot 运行环境：解析路径、补 PATH、提供可移植的时间/通知/OOM 证据工具。
# repo、commit-pinned 版本与过渡期的旧 autopi 副本都可 source；
# 环境变量显式给出的路径优先（测试与 systemd 单元用）。
_ap_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# Only an immutable deployed engine has deploy.env. Ordinary and pinned the product checkouts must keep
# ZF_ENGINE_DIR unset so the scheduler continues to resolve its helpers from the live checkout.
if [[ -f "$_ap_here/../deploy.env" ]]; then
  source "$_ap_here/../config.sh"
fi
if [[ -z "${MAC_AUTOPILOT_ROOT:-}" ]]; then
  case "$_ap_here" in
    */.scratch-supervisor/autopi-versions/*/engine/mac-autopilot) MAC_AUTOPILOT_ROOT="${_ap_here%/.scratch-supervisor/autopi-versions/*}" ;;
    */.scratch-supervisor/autopi) MAC_AUTOPILOT_ROOT="${_ap_here%/.scratch-supervisor/autopi}" ;;
    */engine/mac-autopilot) MAC_AUTOPILOT_ROOT="${_ap_here%/engine/mac-autopilot}" ;;
    *) MAC_AUTOPILOT_ROOT="${ZF_REPO_DIR:-$_ap_here}" ;; # engine outside the target checkout: the target is ZF_REPO_DIR
  esac
fi
MAC_AUTOPILOT_SUPERVISOR_DIR="${MAC_AUTOPILOT_SUPERVISOR_DIR:-$MAC_AUTOPILOT_ROOT/.scratch-supervisor}"
MAC_AUTOPILOT_RUNTIME_DIR="${MAC_AUTOPILOT_RUNTIME_DIR:-$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi}"
export MAC_AUTOPILOT_ROOT MAC_AUTOPILOT_SUPERVISOR_DIR MAC_AUTOPILOT_RUNTIME_DIR
# Linux/systemd keeps its existing PATH; macOS resolves the GNU toolchain before the shared process helpers load.
source "$_ap_here/../platform-env.sh"; platform_require
source "$_ap_here/../proc.sh"
# Same setting lib.sh resolves; the autopilot scripts source this file, not lib.sh.
UNIT_PREFIX="${ZF_UNIT_PREFIX:-zenoforge}"
UNIT_PREFIX_TRANSIENT="${ZF_UNIT_PREFIX:-zf}"
# 状态根（PAUSE、计量开关）：与 lib.sh/config.sh 同一优先级，部署环境（导出后 ZF_HOME）不改代码即可移走。
AGENT_HOME="${AGENT_HOME:-${ZF_HOME:-${HOME:-}/.zenoforge}}"
export PATH="$PATH:${HOME:-}/.local/bin:${HOME:-}/.npm-global/bin:/usr/local/bin"
# gh 调用计量窗口：$AGENT_HOME/measure/gh.on 存在时，调度器与它派出的单元经计量 shim 调 gh（engine/gh-measure）。
if [[ -f "$AGENT_HOME/measure/gh.on" && -x "${ZF_ENGINE_DIR:-$MAC_AUTOPILOT_ROOT/engine}/gh-measure/bin/gh" ]]; then
  export PATH="${ZF_ENGINE_DIR:-$MAC_AUTOPILOT_ROOT/engine}/gh-measure/bin:$PATH"
fi
# WSL 的 /tmp 是 3.9G tmpfs，worker 跑测试的临时目录无人回收会把它写满（2026-10-21 09:10 100%：land 与 #3596 修复
# 都 ENOSPC，修复 worker 自行改用 /var/tmp 绕过）。/tmp 是 tmpfs 时 TMPDIR 改到同盘短路径（postgres socket 不超
# 108 字节），cleanup_tick 回收一天未动的条目。
if [[ "$(uname -s)" == Linux && "$(stat -f -c %T /tmp 2>/dev/null)" == tmpfs && "${TMPDIR:-/tmp}" == /tmp* ]]; then
  AP_TMPDIR="${AP_TMPDIR:-${HOME:-}/.vecta-tmp}"
  mkdir -p "$AP_TMPDIR" 2>/dev/null && export AP_TMPDIR TMPDIR="$AP_TMPDIR"
fi

# worker push 前在本机跑集成测试：pg-container.ts 见到 PGTEST_URL 就在这台服务器上每个测试文件建临时库
# （zenoforge-pgtest.service，127.0.0.1:5432，the test-database setup notes）。10-17 重装丢了它，
# 集成测试首次运行推迟到批准后的 CI：10-22 一天 146 次返工由批准后 CI 红触发。体检 workers.local_test_db 盯可达性。
export PGTEST_URL="${PGTEST_URL:-postgresql://example@127.0.0.1:5432/postgres}"

# L27：时间解析一律走 python datetime，不用 BSD/GNU date 格式解析。无法解析时输出空串。
ap_iso_epoch() {
  python3 - "${1:-}" <<'PY'
from datetime import datetime, timezone
import sys
try:
    d = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
    print(int((d if d.tzinfo else d.replace(tzinfo=timezone.utc)).timestamp()))
except Exception:
    print("")
PY
}

ap_mtime_epoch() {
  python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1" 2>/dev/null
}

ap_notify() { # title message；无桌面通知通道时返回 1（调用方记 failed，不影响主流程）
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$1" "$2" >/dev/null 2>&1
  else
    return 1
  fi
}

# worker 死因的内存证据：查内核 OOM 记录。
ap_oom_command() { # minutes
  printf "journalctl -k --since '-%s min' --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -20" "$1"
}
ap_oom_evidence() { # minutes
  journalctl -k --since "-$1 min" --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -20
}

# 每拍 PR 与 run 快照（pr-run-snapshot.json，scheduler 每拍写一次，运行目录下）：bell、zombie-watch、dashboard 读它，不再各自列 run。
# 它是写它的主机本拍的读缓存，GitHub 没有的它都没有，别的主机自己重建。分区为 null 或文件缺失/格式错 = 不可用，读的人不据此决策；
# 过期只按身份判（run id、head SHA 对不上），不按时钟。
pr_run_snapshot_publish() { # dir prs unfinished main_ci main_suites infra_runs main_head；每个分区不是 JSON 数组就写 null
  local dir="$1" tmp part i; local -a files=()
  tmp="$(mktemp "$dir/.pr-run-snapshot.XXXXXX")" || return 1
  for i in 2 3 4 5 6; do
    part="$(mktemp "$dir/.pr-run-snapshot-part.XXXXXX")" || { rm -f "$tmp" "${files[@]}"; return 1; }
    files+=("$part")
    jq -ce 'select(type=="array")' <<<"${!i:-}" > "$part" 2>/dev/null || true
    [[ -s "$part" ]] || echo null > "$part"
  done
  if jq -n --arg tick "$(date -u +%FT%TZ)" --arg main "${7:-}" \
      --slurpfile prs "${files[0]}" --slurpfile unfinished "${files[1]}" --slurpfile ci "${files[2]}" \
      --slurpfile suites "${files[3]}" --slurpfile infra "${files[4]}" \
      '{schema: 1, tick: $tick, main_head: $main, prs: $prs[0], unfinished_runs: $unfinished[0],
        main_runs: {CI: $ci[0], "Pipeline suites": $suites[0]}, infra_runs: $infra[0]}' > "$tmp" \
    && [[ -s "$tmp" ]] && mv -f "$tmp" "$dir/pr-run-snapshot.json"; then
    rm -f "${files[@]}"; return 0
  fi
  rm -f "$tmp" "${files[@]}"; return 1
}
pr_run_snapshot_section() { # dir jq-path → 该分区的 JSON 数组；不可用返回 1
  jq -ce "select(.schema == 1) | $2 | select(type == \"array\")" "$1/pr-run-snapshot.json" 2>/dev/null
}
