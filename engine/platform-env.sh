#!/usr/bin/env bash
# Platform layer: source this (never execute it) before anything that needs GNU tools. bash 3.2-safe, because macOS ships 3.2.
#   Linux with the default runner: no output, no fork, PATH untouched (the function below is only defined).
#   macOS (or ZF_RUNNER=pidfile): Homebrew gnubin directories first on PATH, ZF_OS/ZF_RUNNER/ZF_TIMERS exported.
# Homebrew prefixes: /opt/homebrew (Apple Silicon) and /usr/local (Intel); ZF_BREW_PREFIXES overrides the probe list (tests).

# Exit 78 (EX_CONFIG) naming every missing dependency. Without it the first symptom is a silent rc 127 from `timeout`
# (the unit loop logs only 124 and 137). Probes capability, not the --version string: uutils coreutils is not GNU.
platform_require() {
  [[ -n ${ZF_PLATFORM_ACTIVE:-} ]] || return 0
  local missing="" t
  (( BASH_VERSINFO[0] >= 5 )) || missing="$missing bash>=5(running ${BASH_VERSION%%[( ]*})"
  timeout --foreground -k 1 5 true >/dev/null 2>&1 || missing="$missing GNU-timeout"
  [[ "$(date -d @0 +%s 2>/dev/null)" == 0 ]] || missing="$missing GNU-date"
  for t in flock setsid; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  [[ -n $missing ]] || return 0
  echo "zenoforge: missing on this host:$missing" >&2
  if [[ $ZF_OS == darwin ]]; then
    echo "zenoforge: install them with: brew bundle --file=$ZF_ENGINE_DIR/Brewfile (Homebrew: https://brew.sh)" >&2
  else
    echo "zenoforge: install bash 5, GNU coreutils and util-linux (flock, setsid) with the system package manager (docs/install.md)" >&2
  fi
  exit 78
}

case "$OSTYPE" in darwin*) ZF_OS=darwin ;; linux*) ZF_OS=linux ;; *) ZF_OS=other ;; esac
ZF_PLATFORM_ACTIVE=1
if [[ $ZF_OS == linux && ${ZF_RUNNER:-systemd} == systemd ]]; then ZF_PLATFORM_ACTIVE=; return 0; fi   # the origin deployment's path ends here
ZF_ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

_zf_path_front() { local p=":$PATH:"; p="${p//":$1:"/:}"; PATH="$1:${p#:}"; PATH="${PATH%:}"; } # dir to the front, once
_zf_path_back() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$PATH:$1" ;; esac; }

if [[ $ZF_OS == darwin ]]; then
  for ZF_BREW in ${ZF_BREW_PREFIXES:-/opt/homebrew /usr/local}; do [[ -x $ZF_BREW/bin/brew ]] && break; done
  # Reverse of the PATH order wanted: coreutils first, then findutils, gnu-sed, grep, gnu-tar, gawk.
  for _zf_f in gawk gnu-tar grep gnu-sed findutils coreutils; do _zf_path_front "$ZF_BREW/opt/$_zf_f/libexec/gnubin"; done
  _zf_path_front "$ZF_BREW/bin"
  _zf_path_back "$ZF_BREW/opt/util-linux/bin" # keg-only: supplies setsid, shadows nothing macOS ships
fi
: "${ZF_RUNNER:=$([[ $ZF_OS == darwin ]] && echo pidfile || echo systemd)}"
: "${ZF_TIMERS:=$([[ $ZF_OS == darwin ]] && echo launchd || echo systemd)}"
[[ $ZF_RUNNER == pidfile ]] && _zf_path_front "$ZF_ENGINE_DIR/portable-shim"
export PATH ZF_OS ZF_RUNNER ZF_TIMERS
unset _zf_f
