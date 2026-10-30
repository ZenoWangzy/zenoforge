#!/usr/bin/env bash
# Source this file before platform-sensitive engine commands. Linux/systemd keeps its existing PATH.
# macOS uses Homebrew's GNU utilities because the system tools are older or have different flags.

platform_require() {
  [[ -n ${ZF_PLATFORM_ACTIVE:-} ]] || return 0
  local missing="" t
  (( BASH_VERSINFO[0] >= 5 )) || missing="$missing bash>=5(running ${BASH_VERSION%%[( ]*})"
  timeout --foreground -k 1 5 true >/dev/null 2>&1 || missing="$missing GNU-timeout"
  [[ "$(date -d @0 +%s 2>/dev/null)" == 0 ]] || missing="$missing GNU-date"
  for t in flock setsid; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  [[ -n $missing ]] || return 0
  echo "the product: missing on this host:$missing" >&2
  if [[ $ZF_OS == darwin ]]; then
    echo "the product: install them with: brew bundle --file=$ZF_ENGINE_DIR/Brewfile (Homebrew: https://brew.sh)" >&2
  else
    echo "the product: install bash 5, GNU coreutils and util-linux (flock, setsid) with the system package manager" >&2
  fi
  exit 78
}

case "${OSTYPE:-}" in darwin*) ZF_OS=darwin ;; linux*) ZF_OS=linux ;; *) ZF_OS=other ;; esac
ZF_PLATFORM_ACTIVE=1
if [[ $ZF_OS == linux && ${ZF_RUNNER:-systemd} == systemd ]]; then ZF_PLATFORM_ACTIVE=; return 0; fi
ZF_ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

_zf_path_front() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac; }
_zf_path_back() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$PATH:$1" ;; esac; }

if [[ $ZF_OS == darwin ]]; then
  for ZF_BREW in ${ZF_BREW_PREFIXES:-/opt/homebrew /usr/local}; do [[ -x $ZF_BREW/bin/brew ]] && break; done
  for _zf_f in gawk gnu-tar grep gnu-sed findutils coreutils; do
    _zf_path_front "$ZF_BREW/opt/$_zf_f/libexec/gnubin"
  done
  _zf_path_front "$ZF_BREW/bin"
  _zf_path_back "$ZF_BREW/opt/util-linux/bin"
fi
: "${ZF_RUNNER:=$([[ $ZF_OS == darwin ]] && echo pidfile || echo systemd)}"
: "${ZF_TIMERS:=$([[ $ZF_OS == darwin ]] && echo launchd || echo systemd)}"
[[ $ZF_RUNNER == pidfile ]] && _zf_path_front "$ZF_ENGINE_DIR/portable-shim"
export PATH ZF_OS ZF_RUNNER ZF_TIMERS
unset _zf_f
