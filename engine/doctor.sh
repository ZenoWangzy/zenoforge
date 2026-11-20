#!/usr/bin/env bash
# Standalone host checks; keep this script runnable by macOS's Bash 3.2.
set -u

failures=0
os="$(uname -s 2>/dev/null || printf unknown)"
release="$(uname -r 2>/dev/null || :)"

case "$os" in
  Darwin)
    coreutils_fix='brew install coreutils && export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"'
    lock_fix='brew install flock util-linux && export PATH="$(brew --prefix util-linux)/bin:$PATH"'
    ;;
  *)
    if command -v apt-get >/dev/null 2>&1; then
      coreutils_fix='sudo apt-get install -y coreutils'
      lock_fix='sudo apt-get install -y util-linux'
    elif command -v dnf >/dev/null 2>&1; then
      coreutils_fix='sudo dnf install -y coreutils'
      lock_fix='sudo dnf install -y util-linux'
    elif command -v yum >/dev/null 2>&1; then
      coreutils_fix='sudo yum install -y coreutils'
      lock_fix='sudo yum install -y util-linux'
    else
      coreutils_fix='sudo apt-get install -y coreutils'
      lock_fix='sudo apt-get install -y util-linux'
    fi
    ;;
esac

report() {
  local status="$1" check="$2" detail="$3" fix="${4:-}"
  [[ "$status" != FAIL ]] || failures=1
  printf '%s  %s  %s' "$status" "$check" "$detail"
  [[ -z "$fix" ]] || printf '  [fix: %s]' "$fix"
  printf '\n'
}

if command -v timeout >/dev/null 2>&1 && timeout --foreground -k 1 5 /bin/true >/dev/null 2>&1; then
  report PASS 'GNU timeout' 'supports --foreground and -k'
else
  report FAIL 'GNU timeout' 'missing or incompatible' "$coreutils_fix"
fi

date_epoch="$(date -d @0 +%s 2>/dev/null || :)"
if [[ "$date_epoch" == 0 ]]; then
  report PASS 'GNU date' 'supports -d @epoch'
else
  report FAIL 'GNU date' 'missing or incompatible' "$coreutils_fix"
fi

lock_file="$(mktemp "${TMPDIR:-/tmp}/zf-doctor.XXXXXX" 2>/dev/null || :)"
if [[ -n "$lock_file" ]] && command -v flock >/dev/null 2>&1 && (
  exec 9>"$lock_file" && flock -n 9 && flock -u 9
); then
  report PASS flock 'nonblocking and unlock operations work'
else
  report FAIL flock 'missing or incompatible' "$lock_fix"
fi
[[ -z "$lock_file" ]] || rm -f "$lock_file" 2>/dev/null || :

if command -v setsid >/dev/null 2>&1 && setsid --wait /bin/true >/dev/null 2>&1; then
  report PASS setsid 'supports --wait'
else
  report FAIL setsid 'missing or incompatible' "$lock_fix"
fi

systemd_fix='mkdir -p "${AGENT_HOME:-$HOME/.zenoforge}" && printf "%s\\n" "ZF_RUNNER=pidfile" "ZF_TIMERS=loop" >> "${AGENT_HOME:-$HOME/.zenoforge}/capacity.env"'
if [[ "$os" != Linux ]]; then
  report PASS systemd "not required on $os"
elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  report PASS systemd 'user manager responds'
elif [[ "${ZF_RUNNER:-}" == pidfile && "${ZF_TIMERS:-}" == loop ]]; then
  report WARN systemd 'unavailable; pidfile and loop fallback is configured'
else
  report FAIL systemd 'user manager unavailable' "$systemd_fix"
fi

case "$release" in
  *Microsoft*|*microsoft*)
    report WARN 'WSL idle' 'set instanceIdleTimeout=-1 in %UserProfile%\.wslconfig' 'add [general] instanceIdleTimeout=-1 to %UserProfile%\.wslconfig'
    ;;
  *)
    report PASS 'WSL idle' 'not a WSL host'
    ;;
esac

exit "$failures"
