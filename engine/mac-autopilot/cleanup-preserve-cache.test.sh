#!/usr/bin/env bash
# cleanup_tick keeps a worktree with unrescued work. The same kept worktrees came back every tick and cost a git walk each
# (24 s for 44 of them on 2026-11-07): a preserve verdict is reused until it is old, a delete verdict never is.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/cleanup-preserve-cache"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts" "$fixture/wt" "$fixture/sys-tmp"
cp "$script_dir/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
WT_ROOT="$fixture/wt"; SUP="$fixture/supervisor"; A="$MAC_AUTOPILOT_RUNTIME_DIR"; UNITS="$A/units.json"; LOG="$A/scheduler.log"
export AP_SYSTEM_TMP="$fixture/sys-tmp" AP_SYSTEM_TMP_FS=ext4
fail() { echo "cleanup-preserve-cache.test.sh: $*" >&2; exit 1; }
printf '%s\n' '{"units":[{"id":"keep-1","stage":"closed"},{"id":"keep-2","stage":"closed"},{"id":"drop-1","stage":"closed"}]}' > "$UNITS"
touch "$A/.branch-gc"
for id in keep-1 keep-2 drop-1; do mkdir -p "$WT_ROOT/wt-$id"; done
calls="$fixture/calls"; : > "$calls"; releasable=""
worktree_cleanup_block_reason() { # a file, not a counter: the check runs inside $( )
  printf '%s\n' "${1##*/}" >> "$calls"
  [[ "$1" != *keep-* || " $releasable " == *" ${1##*/} "* ]] || { printf 'Git stash exists'; return 0; }
  return 1
}
checked() { wc -l < "$calls"; }
tick() { : > "$LOG"; cleanup_tick || fail "$1: cleanup_tick failed"; }

tick first
[[ "$(checked)" == 3 ]] || fail "first tick checked $(checked) worktrees, wanted 3"
[[ -d "$WT_ROOT/wt-keep-1" && -d "$WT_ROOT/wt-keep-2" && ! -e "$WT_ROOT/wt-drop-1" ]] || fail 'first tick kept the wrong worktrees'
[[ "$(grep -c 'preserve worktree' "$LOG")" == 2 ]] || fail 'first tick did not name both kept worktrees'

tick second
[[ "$(checked)" == 3 ]] || fail "second tick walked kept worktrees again ($(checked) checks)"
[[ -d "$WT_ROOT/wt-keep-1" && -d "$WT_ROOT/wt-keep-2" ]] || fail 'second tick lost a kept worktree'

# An old verdict is checked again, and a worktree that stopped blocking is reclaimed.
releasable="wt-keep-2"
AUTOPI_WORKTREE_PRESERVE_RECHECK_SECONDS=0 tick third
[[ "$(checked)" == 5 ]] || fail "third tick rechecked $(( $(checked) - 3 )) kept worktrees, wanted 2"
[[ -d "$WT_ROOT/wt-keep-1" && ! -e "$WT_ROOT/wt-keep-2" ]] || fail 'third tick did not reclaim the worktree that stopped blocking'

echo 'ok - kept worktrees are not walked again until their verdict is old; delete verdicts are never reused'
