#!/usr/bin/env bash
# ensure_clone 对半合并残留脏树的恢复（issue-5064，2026-11-05）：repair worker 按提示
# `git merge origin/main` 撞冲突后被 stuck-kill，index 留 unmerged 条目而 merge 状态文件
# 已不在；`git stash push` 拒收这种 index，redispatch 从此每拍 "PR branch unavailable"。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/clone-recovery"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/agent"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "clone-recovery.test.sh: $*" >&2; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

ROOT="$fixture/repo"
command git init -q -b main "$ROOT"
git() { command git -C "$ROOT" "$@"; }
git config user.email t@example.invalid; git config user.name t
echo base > "$ROOT/shared.txt"; git add -A; git commit -qm base
command git init -q --bare -b main "$fixture/origin.git"
git remote add origin "$fixture/origin.git"
git push -q -u origin main
git checkout -q -b agent/issue-901
echo branch-change > "$ROOT/shared.txt"; git commit -qam branch
git push -q -u origin agent/issue-901
git checkout -q main
echo main-change > "$ROOT/shared.txt"
echo main-only > "$ROOT/main-added.txt"; git add -A; git commit -qam mainmove
git push -q origin main
git fetch -q origin
MAIN_HEAD="$(git rev-parse refs/remotes/origin/main)"
WANT="$(git rev-parse refs/remotes/origin/agent/issue-901)"
unset -f git

units() { printf '%s\n' "$1" > "$UNITS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
patch_of() { ls "$A"/wt-issue-901-recovery-*.patch 2>/dev/null | head -n 1; }
log_has() { [[ -n "$(grep "$1" "$LOG" 2>/dev/null || true)" ]]; }

# 事故现场：merge 撞冲突后 worker 被杀、merge 状态文件不在、index 仍带 unmerged 条目，
# 另有一个必须存活的 untracked 文件。extra-local-commit=yes 把 HEAD 挪到未推送提交上。
make_zombie() { # [keep-merge-head] [extra-local-commit]
  local dir="$WT_ROOT/wt-issue-901"
  rm -rf -- "$dir" "$A"/wt-issue-901-recovery-*.patch
  command git clone -q "$ROOT" "$dir"
  command git -C "$dir" remote set-url origin "$fixture/origin.git"
  command git -C "$dir" config user.email t@example.invalid
  command git -C "$dir" config user.name t
  command git -C "$dir" checkout -q agent/issue-901
  [[ "${2:-}" != yes ]] || { echo unpushed > "$dir/shared.txt"; command git -C "$dir" commit -qam unpushed; }
  command git -C "$dir" merge --no-edit refs/remotes/origin/main >/dev/null 2>&1 || true
  command git -C "$dir" ls-files -u | grep -q . || fail "fixture did not produce an unmerged index"
  if [[ "${1:-}" != yes ]]; then
    rm -f "$dir/.git/MERGE_HEAD" "$dir/.git/MERGE_MSG" "$dir/.git/AUTO_MERGE"
  fi
  echo repro-notes > "$dir/notes.md"
}

units '{"units":[{"id":"issue-901","issue":901,"branch":"agent/issue-901","lane":"pr","stage":"repair-pending","history":[]}]}'

# --- 1. HEAD 等于远端、无活 worker：备份 diff、reset、恰好一条恢复记录；下一拍不再重复 ---
printf '%s\n' '{"workers":[]}' > "$WORKERS"
make_zombie
: > "$LOG"
out="$(ensure_clone issue-901 agent/issue-901 1 "$WANT")" || fail "recovery did not unwedge the clone"
[[ "$out" == "$WT_ROOT/wt-issue-901" ]] || fail "ensure_clone returned $out"
patch="$(patch_of)"; [[ -n "$patch" ]] || fail "recovery wrote no diff backup beside the logs"
grep -q 'branch-change' "$patch" || fail "backup patch lost the unmerged file content"
grep -q 'main-added.txt' "$patch" || fail "backup patch lost the staged merge changes"
status_now="$(command git -C "$WT_ROOT/wt-issue-901" status --porcelain)"
[[ "$status_now" == *"notes.md"* && "$status_now" != *U* ]] || fail "tracked tree was not reset to the pushed head ($status_now)"
[[ -f "$WT_ROOT/wt-issue-901/notes.md" ]] || fail "recovery removed an untracked file"
[[ -z "$(command git -C "$WT_ROOT/wt-issue-901" stash list)" ]] || fail "recovery stashed instead of leaving the reset tree in place"
[[ "$(grep -c 'clone recovery' "$LOG")" == 1 ]] || fail "recovery must log exactly one record ($(grep -c 'clone recovery' "$LOG"))"
command git -C "$WT_ROOT/wt-issue-901" config --unset user.name
ensure_clone issue-901 agent/issue-901 1 "$WANT" >/dev/null || fail "the refill after recovery still failed"
[[ "$(command git -C "$WT_ROOT/wt-issue-901" config user.name)" == "$(command git -C "$ROOT" config user.name)" ]] \
  || fail "ensure_clone left the clone without a git identity"
[[ "$(grep -c 'clone recovery' "$LOG")" == 1 ]] || fail "a later refill logged another recovery record"

# --- 2. 活 worker 占用同一棵树：不备份、不 reset、ensure_clone 照旧拒绝 ---
make_zombie
: > "$LOG"
sleep 300 & live_pid=$!
live_start="$(coord_process_start_ticks "$live_pid")"
jq -n --argjson pid "$live_pid" --argjson start "$live_start" --arg dir "$WT_ROOT/wt-issue-901" \
  '{workers:[{pid:$pid,pid_start:$start,unit:"issue-901",type:"repair",log:"x.log",report:"r.md",workdir:$dir}]}' > "$WORKERS"
if ensure_clone issue-901 agent/issue-901 1 "$WANT" >/dev/null 2>&1; then
  kill "$live_pid" 2>/dev/null || :; fail "ensure_clone dispatched into a worktree held by a live worker"
fi
kill "$live_pid" 2>/dev/null || :; wait "$live_pid" 2>/dev/null || :
[[ -z "$(patch_of)" ]] || fail "a live worker's tree was backed up and reset"
log_has 'clone recovery' && fail "a live worker's tree produced a recovery record"
command git -C "$WT_ROOT/wt-issue-901" ls-files -u | grep -q . || fail "the live worker's unmerged tree was mutated"
[[ -f "$WT_ROOT/wt-issue-901/notes.md" ]] || fail "refusal under a live worker removed an untracked file"

# --- 3. HEAD 不同于远端（未推送提交 + 残留 unmerged）：两拍都拒绝，升级只发生一次 ---
printf '%s\n' '{"workers":[]}' > "$WORKERS"
make_zombie "" yes
: > "$LOG"; rm -f "$A/clone-head-mismatch.once" "$AGENT_HOME/supervisor-inbox"
if ensure_clone issue-901 agent/issue-901 1 "$WANT" >/dev/null 2>&1; then fail "a divergent head was reset or redispatched"; fi
if ensure_clone issue-901 agent/issue-901 1 "$WANT" >/dev/null 2>&1; then fail "the second refill stopped refusing"; fi
[[ "$(grep -c 'clone mismatch' "$LOG")" == 1 ]] || fail "mismatch must escalate exactly once across refills ($(grep -c 'clone mismatch' "$LOG"))"
[[ "$(wc -l < "$A/clone-head-mismatch.once")" == 1 ]] || fail "mismatch once-file recorded more than one key"
grep -q "clone-head-mismatch unit=issue-901" "$AGENT_HOME/supervisor-inbox" 2>/dev/null \
  || fail "mismatch escalation did not reach the supervisor inbox"
command git -C "$WT_ROOT/wt-issue-901" ls-files -u | grep -q . || fail "the divergent tree was mutated"
[[ -z "$(patch_of)" ]] || fail "a divergent head produced a recovery backup"
[[ "$(field issue-901 .stage)" == repair-pending ]] || fail "mismatch refusal must leave the unit in place ($(field issue-901 .stage))"

# --- 4. 还开着的 merge 绝不自动 abort ---
make_zombie yes
printf '%s\n' '{"workers":[]}' > "$WORKERS"
: > "$LOG"
if ensure_clone issue-901 agent/issue-901 1 "$WANT" >/dev/null 2>&1; then fail "an open merge was redispatched"; fi
[[ -f "$WT_ROOT/wt-issue-901/.git/MERGE_HEAD" ]] || fail "the open merge was aborted instead of refused"
log_has 'clone recovery' && fail "an open merge produced a recovery record"

# --- 5. 活性核实不了（worker 台账损坏）：拒绝而不是赌一把 reset ---
make_zombie
printf 'not json' > "$WORKERS"
: > "$LOG"
if ensure_clone issue-901 agent/issue-901 1 "$WANT" >/dev/null 2>&1; then fail "recovery ran with an unreadable worker ledger"; fi
command git -C "$WT_ROOT/wt-issue-901" ls-files -u | grep -q . || fail "the tree was reset without a verifiable liveness check"
[[ -z "$(patch_of)" ]] || fail "a backup was written without a verifiable liveness check"
log_has 'liveness unknown' || fail "the unverifiable liveness refusal was not logged"

# --- 6. 领先 origin 的分叉（已提交未推送 + 普通脏树）不受恢复闸影响：照旧 stash+保留本地提交 ---
make_zombie "" yes
command git -C "$WT_ROOT/wt-issue-901" reset -q --hard HEAD
echo unpushed-work > "$WT_ROOT/wt-issue-901/shared.txt"
printf '%s\n' '{"workers":[]}' > "$WORKERS"
: > "$LOG"
ahead_head="$(command git -C "$WT_ROOT/wt-issue-901" rev-parse HEAD)"
out="$(ensure_clone issue-901 agent/issue-901 1 "$WANT")" || fail "an ahead branch with a dirty tree stopped redispatching"
[[ "$(command git -C "$WT_ROOT/wt-issue-901" rev-parse HEAD)" == "$ahead_head" ]] \
  || fail "the stash path must keep the unpushed local head"
[[ -n "$(command git -C "$WT_ROOT/wt-issue-901" stash list)" ]] || fail "the stash path no longer stashes the dirty tree"
! log_has 'clone recovery' && ! log_has 'clone mismatch' || fail "the ahead case must not take the recovery gates"

echo 'clone-recovery.test.sh: PASS'
