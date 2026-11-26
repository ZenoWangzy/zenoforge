#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$script_dir/test-env.sh"
fixture="$test_env_root/clone-pool-cleanup"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$script_dir/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8' "$script_dir/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { printf 'clone-pool-cleanup.test.sh: %s\n' "$*" >&2; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
remote="$fixture/origin.git"
seed="$fixture/seed"
command git init -q --bare "$remote"
command git init -q -b main "$seed"
command git -C "$seed" config user.email t@example.invalid
command git -C "$seed" config user.name t
mkdir -p "$seed/docs"
printf 'base\n' > "$seed/file.txt"
printf 'hidden\n' > "$seed/docs/hidden.txt"
command git -C "$seed" add file.txt
command git -C "$seed" add docs/hidden.txt
command git -C "$seed" commit -qm base
command git -C "$seed" remote add origin "$remote"
command git -C "$seed" push -qu origin main
command git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
WT_ROOT="$fixture/worktrees"
mkdir -p "$WT_ROOT"
clone="$WT_ROOT/wt-orphan"
command git clone -q "$remote" "$clone"
touch -d "@$(( $(date +%s) - 605000 ))" "$clone/.git/index"
unpushed_clone="$WT_ROOT/wt-unpushed"
command git clone -q "$remote" "$unpushed_clone"
command git -C "$unpushed_clone" switch -qc local-only
printf 'local\n' > "$unpushed_clone/local.txt"
command git -C "$unpushed_clone" add local.txt
command git -C "$unpushed_clone" commit -qm local-only
command git -C "$unpushed_clone" switch -q main
touch -d "@$(( $(date +%s) - 605000 ))" "$unpushed_clone/.git/index"
dirty_clone="$WT_ROOT/wt-dirty"
command git clone -q "$remote" "$dirty_clone"
printf 'uncommitted\n' > "$dirty_clone/scratch.txt"
touch -d "@$(( $(date +%s) - 605000 ))" "$dirty_clone/.git/index"
active_clone="$WT_ROOT/wt-active"
command git clone -q "$remote" "$active_clone"
touch -d "@$(( $(date +%s) - 605000 ))" "$active_clone/.git/index"
fresh_clone="$WT_ROOT/wt-fresh"
command git clone -q "$remote" "$fresh_clone"
eval_clone="$WT_ROOT/wt-eval"
command git clone -q "$remote" "$eval_clone"
touch -d "@$(( $(date +%s) - 605000 ))" "$eval_clone/.git/index"
jq -n '{units:[{id:"eval",stage:"merged",eval_gate:{status:"running"}}]}' > "$UNITS"
flagged_clone="$WT_ROOT/wt-flagged"
command git clone --sparse -q "$remote" "$flagged_clone"
command git -C "$flagged_clone" update-index --assume-unchanged docs/hidden.txt
mkdir -p "$flagged_clone/docs"
printf 'local hidden change\n' > "$flagged_clone/docs/hidden.txt"
touch -d "@$(( $(date +%s) - 605000 ))" "$flagged_clone/.git/index"
active_key="$(coord_unit_key active)"
active_owner="$(coord_new_owner)"
coord_acquire "$active_key" "$active_owner" scheduler-worker active active implement || fail 'could not set up the live clone owner'
touch "$A/.branch-gc"
: > "$UNITS_ARCHIVE"
SECONDS=0 AUTOPI_TICK_LIMIT_SECONDS=1800 AP_SYSTEM_TMP="$fixture/sys-tmp" AP_SYSTEM_TMP_FS=ext4 cleanup_tick || fail 'cleanup tick failed'
[[ ! -e "$clone" ]] || fail 'old clean clone outside the unit ledgers remained in the pool'
[[ -d "$unpushed_clone" ]] || fail 'clone with an unpushed local branch was removed'
[[ -d "$dirty_clone" ]] || fail 'clone with uncommitted work was removed'
[[ -d "$active_clone" ]] || fail 'clone with a live worker was removed'
[[ -d "$fresh_clone" ]] || fail 'fresh clone was removed before its retention period'
[[ -d "$eval_clone" ]] || fail 'clone used by a running eval was removed'
[[ -d "$flagged_clone" ]] || fail 'clone with a flagged file change was removed'
WT_ROOT="$fixture/batch-worktrees"
mkdir -p "$WT_ROOT"
rm -f "$A/.clone-pool-cleanup-cursor"
for ((i=0; i<51; i++)); do
  printf -v suffix '%03d' "$i"
  mkdir "$WT_ROOT/wt-batch-$suffix"
done
SECONDS=0 AUTOPI_TICK_LIMIT_SECONDS=1800 AP_SYSTEM_TMP="$fixture/sys-tmp" AP_SYSTEM_TMP_FS=ext4 cleanup_tick || fail 'bounded cleanup tick failed'
[[ "$(cat "$A/.clone-pool-cleanup-cursor")" == wt-batch-049 ]] || fail 'cleanup cursor did not stop after one bounded batch'
SECONDS=0 AUTOPI_TICK_LIMIT_SECONDS=1800 AP_SYSTEM_TMP="$fixture/sys-tmp" AP_SYSTEM_TMP_FS=ext4 cleanup_tick || fail 'cleanup cursor continuation failed'
[[ ! -e "$A/.clone-pool-cleanup-cursor" ]] || fail 'cleanup cursor did not clear after a full pass'
[[ -d "$WT_ROOT/wt-batch-050" ]] || fail 'cleanup cursor skipped the final clone-pool entry'
