#!/usr/bin/env bash
# platform-env.sh: Linux PATH untouched, Homebrew gnubin on PATH for both prefixes, platform_require fails loud with exit 78.
# Runs on Linux and macOS: the OS is chosen by assigning OSTYPE in the sourcing shell, and Homebrew prefixes are fake directories.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "platform-env.test.sh: $*" >&2; exit 1; }
t="$test_env_root/pe"
mkdir -p "$t/arm/bin" "$t/intel/bin" "$t/fakebin" "$t/min"
touch "$t/arm/bin/brew" "$t/intel/bin/brew"; chmod +x "$t/arm/bin/brew" "$t/intel/bin/brew"
source "$engine/platform-env.sh" # on macOS this is what makes the GNU tools below resolvable; a no-op on Linux
unset ZF_OS ZF_RUNNER ZF_TIMERS # on macOS it exported these; the cases below must start from the Linux defaults

# run <ostype> <path> <script>: source platform-env.sh in a fresh strict shell that believes it is on <ostype>.
run() { env "PATH=$2" "$BASH" -u -c 'OSTYPE=$1; source "$2/platform-env.sh"; eval "$3"' _ "$1" "$engine" "$3"; }

# Linux with the default runner: PATH byte-identical, nothing exported, platform_require a no-op even with a non-GNU timeout.
printf '#!/bin/sh\necho usage: timeout\nexit 1\n' > "$t/fakebin/timeout"; chmod +x "$t/fakebin/timeout"
p="$t/fakebin:$PATH"
[[ "$(run linux-gnu "$p" 'printf %s "$PATH"')" == "$p" ]] || fail 'Linux default runner changed PATH'
[[ -z "$(run linux-gnu "$p" 'env | grep -E "^ZF_(OS|RUNNER|TIMERS)="')" ]] || fail 'Linux default runner exported ZF_ variables'
run linux-gnu "$p" 'platform_require' || fail 'platform_require is not a no-op on Linux with the default runner'
[[ "$(run linux-gnu "$p" 'printf %s "$ZF_OS"')" == linux ]] || fail 'ZF_OS not linux'
[[ -z "$(run linux-gnu "$p" 'printf %s "${ZF_RUNNER:-}"')" ]] || fail 'Linux default runner set a ZF_RUNNER'
[[ "$(ZF_RUNNER=systemd run linux-gnu "$p" 'printf %s "$PATH"')" == "$p" ]] || fail 'explicit ZF_RUNNER=systemd changed PATH'

# Linux with ZF_RUNNER=pidfile: only the portable-shim directory goes first; no gnubin.
[[ "$(ZF_RUNNER=pidfile run linux-gnu "$p" 'printf %s "$PATH"')" == "$engine/portable-shim:$p" ]] || fail 'ZF_RUNNER=pidfile PATH wrong on Linux'

# macOS, Apple Silicon and Intel both installed: /opt/homebrew-style prefix (first in the list) wins.
gnubin() { local d=; for f in coreutils findutils gnu-sed grep gnu-tar gawk; do d="$d$1/opt/$f/libexec/gnubin:"; done; printf %s "$d"; }
base="$t/fakebin:/usr/bin:/bin"
want="$engine/portable-shim:$t/arm/bin:$(gnubin "$t/arm")$base:$t/arm/opt/util-linux/bin"
got="$(ZF_BREW_PREFIXES="$t/arm $t/intel" run darwin24.0 "$base" 'printf %s "$PATH"')"
[[ "$got" == "$want" ]] || fail $'Apple Silicon PATH wrong\n got:  '"$got"$'\n want: '"$want"
# Intel only.
want="$engine/portable-shim:$t/intel/bin:$(gnubin "$t/intel")$base:$t/intel/opt/util-linux/bin"
got="$(ZF_BREW_PREFIXES="$t/nothing $t/intel" run darwin24.0 "$base" 'printf %s "$PATH"')"
[[ "$got" == "$want" ]] || fail $'Intel PATH wrong\n got:  '"$got"$'\n want: '"$want"
# Sourcing again, in the same shell and in a child, does not grow PATH.
once="$(ZF_BREW_PREFIXES="$t/arm" run darwin24.0 "$base" 'printf %s "$PATH"')"
twice="$(ZF_BREW_PREFIXES="$t/arm" run darwin24.0 "$base" 'source "$2/platform-env.sh"; "$BASH" -c "OSTYPE=darwin24.0; source $2/platform-env.sh; printf %s \"\$PATH\""')"
[[ "$twice" == "$once" ]] || fail 'sourcing platform-env.sh twice changed PATH'
# A brew directory already later on PATH moves to the front instead of staying behind the system bash.
got="$(ZF_BREW_PREFIXES="$t/arm" run darwin24.0 "/usr/bin:$t/arm/bin:/bin" 'printf %s "$PATH"')"
[[ "$got" == "$engine/portable-shim:$t/arm/bin:$(gnubin "$t/arm")/usr/bin:/bin:$t/arm/opt/util-linux/bin" ]] || fail "brew dir not moved to the front: $got"
# Defaults and overrides.
[[ "$(ZF_BREW_PREFIXES="$t/arm" run darwin24.0 "$base" 'printf "%s %s %s" "$ZF_OS" "$ZF_RUNNER" "$ZF_TIMERS"')" == 'darwin pidfile launchd' ]] || fail 'macOS defaults wrong'
[[ "$(ZF_RUNNER=systemd ZF_BREW_PREFIXES="$t/arm" run darwin24.0 "$base" 'printf %s "$ZF_RUNNER"')" == systemd ]] || fail 'explicit ZF_RUNNER lost on macOS'
[[ "$(ZF_BREW_PREFIXES="$t/arm" run darwin24.0 "$base" 'env | grep -c "^ZF_OS="')" == 1 ]] || fail 'ZF_OS not exported on macOS'

# platform_require: passes where the tools exist, names every missing one, exits 78, prints the install command.
export ZF_BREW_PREFIXES="$t/arm" # fake brew dirs from here on: a real Homebrew gnubin must not outrank the fakes
run darwin24.0 "$PATH" 'platform_require' || fail 'platform_require failed on a host with the dependencies'
rc=0; err="$(run darwin24.0 "$t/fakebin:$PATH" 'platform_require' 2>&1)" || rc=$?
[[ $rc == 78 ]] || fail "non-GNU timeout: exit $rc, wanted 78"
[[ "$err" == *GNU-timeout* && "$err" == *"brew bundle --file=$engine/Brewfile"* ]] || fail "non-GNU timeout: no hint in: $err"
[[ "$err" != *GNU-date* ]] || fail "non-GNU timeout also blamed date: $err"
rm "$t/fakebin/timeout"
printf '#!/bin/sh\necho "date: illegal option -- d" >&2\nexit 1\n' > "$t/fakebin/date"; chmod +x "$t/fakebin/date"
rc=0; err="$(run darwin24.0 "$t/fakebin:$PATH" 'platform_require' 2>&1)" || rc=$?
[[ $rc == 78 && "$err" == *GNU-date* ]] || fail "BSD date: exit $rc, output: $err"
rm "$t/fakebin/date"
# Only dirname, timeout, date and true on PATH: flock and setsid are named, nothing else is.
for tool in dirname timeout date true; do ln -s "$(type -P "$tool")" "$t/min/$tool"; done
rc=0; err="$(run darwin24.0 "$t/min" 'platform_require' 2>&1)" || rc=$?
[[ $rc == 78 && "$err" == *flock* && "$err" == *setsid* && "$err" != *GNU-* ]] || fail "missing flock and setsid: exit $rc, output: $err"
# Linux with ZF_RUNNER=pidfile gets the same check with the package-manager hint.
rc=0; err="$(ZF_RUNNER=pidfile run linux-gnu "$t/min" 'platform_require' 2>&1)" || rc=$?
[[ $rc == 78 && "$err" == *"package manager"* ]] || fail "Linux pidfile hint: exit $rc, output: $err"

# Every formula whose gnubin directory platform-env.sh puts on PATH (plus bash, util-linux, flock) is in the Brewfile.
formulae="$(sed -n 's/^  for _zf_f in \(.*\); do _zf_path_front.*/\1/p' "$engine/platform-env.sh")"
[[ -n $formulae ]] || fail 'cannot find the formula list in platform-env.sh'
for f in $formulae bash util-linux flock; do grep -q "^brew \"$f\"" "$engine/Brewfile" || fail "Brewfile lacks $f"; done

echo 'platform-env.test.sh: PASS'
