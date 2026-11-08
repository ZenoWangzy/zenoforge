#!/usr/bin/env bash
# 2026-11-08 VectA 24h: 43 slot syncs, 29 of them repeats on a PR whose only new commit was a bare main merge (340 CI minutes).
# slot_sync_needs_refresh decides from local git only: refresh when the main delta since the merge base touches a PR path,
# or when the PR is next for merge and its merge base is older than ci.slot_sync_max_base_age_hours (default 6).
# Conflicts are decided before it, in slot_sync. Real git repos; gh is never called.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"

fixture="$test_env_root/ci-admission-slot-sync"
supervisor="$fixture/supervisor"
mkdir -p "$supervisor/autopi/alerts" "$fixture/repo"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor" \
  MAC_AUTOPILOT_RUNTIME_DIR="$supervisor/autopi" REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
cp "$engine_dir/mac-autopilot/config.template.json" "$supervisor/autopi/config.json"
echo '{"units":[]}' > "$supervisor/autopi/units.json"
echo '{"workers":[]}' > "$supervisor/autopi/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "ci-admission-slot-sync.test.sh: $*" >&2; exit 1; }

# mk_repo name base_age_hours main_file pr_file -> sets ROOT and PR_HEAD. Base has a.txt b.txt; main then edits main_file, the PR edits pr_file.
mk_repo() {
  local r="$test_env_root/slot-sync-$1" at
  at="$(( $(date +%s) - $2 * 3600 ))"
  rm -rf "$r"; git init -q -b main "$r"
  git -C "$r" config user.email t@example.invalid; git -C "$r" config user.name t
  printf 'a\n' > "$r/a.txt"; printf 'b\n' > "$r/b.txt"; git -C "$r" add -A
  GIT_AUTHOR_DATE="@$at" GIT_COMMITTER_DATE="@$at" git -C "$r" commit -q -m base
  git -C "$r" checkout -q -b pr
  printf '%s\n' pr >> "$r/$4"; git -C "$r" add -A; git -C "$r" commit -q -m pr
  git -C "$r" checkout -q main
  printf '%s\n' main >> "$r/$3"; git -C "$r" add -A; git -C "$r" commit -q -m main
  git -C "$r" update-ref refs/remotes/origin/main main
  ROOT="$r"; PR_HEAD="$(git -C "$r" rev-parse pr)"
}
refresh() { slot_sync_needs_refresh "$PR_HEAD" "$1"; } # 0 = update-branch

CFG='{}'
mk_repo clean-fresh 1 b.txt a.txt
refresh 0 && fail 'clean head on a 1h base without path overlap was refreshed'
refresh 1 && fail 'next-for-merge head on a 1h base without path overlap was refreshed'

mk_repo clean-stale 10 b.txt a.txt
refresh 0 && fail 'a stale base refreshed a PR that is not next for merge'
refresh 1 || fail 'next-for-merge head on a 10h base was not refreshed'
CFG='{"ci":{"slot_sync_max_base_age_hours":12}}'
refresh 1 && fail 'ci.slot_sync_max_base_age_hours=12 did not raise the bound'
CFG='{"ci":{"slot_sync_max_base_age_hours":"x"}}'
refresh 1 || fail 'a non-numeric bound did not fall back to 6h'
CFG='{}'

mk_repo overlap 1 a.txt a.txt
refresh 0 || fail 'main delta touching a PR path was not refreshed'

mk_repo unknown 1 b.txt a.txt
refresh_unknown() { slot_sync_needs_refresh "$(printf '%040x' 77)" 0; }
refresh_unknown || fail 'unreadable git data must keep the old refresh behaviour'

# End to end through slot_sync: no update-branch without a reason, conflict still goes to repair, overlap still syncs.
td="$test_env_root/slot-sync-ledger"; mkdir -p "$td"
A="$td"; LOG="$td/scheduler.log"; : > "$LOG"; UNITS="$td/units.json"; WORKERS="$td/workers.json"
STAMP=ci-admission-test; SCHED_LOCK_HELD=true; SLOT_SYNC_BUDGET=5; SLOT_SYNC_SPENT=0
pr_behind_main() { return 0; }
update_calls=0; repair_calls=0; mergeable=MERGEABLE
ci_update_branch() { update_calls=$((update_calls + 1)); }
tick_pr_mergeable() { echo "$mergeable"; }
merge_conflict_to_repair() { repair_calls=$((repair_calls + 1)); }
run_sync() { # case-name main_file pr_file base_hours next
  mk_repo "$1" "$4" "$2" "$3"
  command jq -cn --arg h "$PR_HEAD" '{units:[{id:"u1",pr:9,branch:"agent/issue-9",lane:"pr",stage:"ready-to-merge",approved_sha:$h,history:[]}]}' > "$UNITS"
  echo '{"workers":[]}' > "$WORKERS"
  update_calls=0; repair_calls=0; SLOT_SYNC_SPENT=0
  rc=0; slot_sync u1 "$PR_HEAD" 0 "$5" || rc=$?
}
run_sync e2e-clean b.txt a.txt 1 1
[[ "$rc" == 1 && "$update_calls" == 0 ]] || fail "clean up-to-date head was synced (rc=$rc calls=$update_calls)"
command jq -e '.units[0].slot_sync_sha == null' "$UNITS" >/dev/null || fail 'a skipped sync still marked the head as synced'
run_sync e2e-stale b.txt a.txt 10 1
[[ "$rc" == 0 && "$update_calls" == 1 ]] || fail "stale next-for-merge head was not synced (rc=$rc calls=$update_calls)"
run_sync e2e-overlap a.txt a.txt 1 0
[[ "$rc" == 0 && "$update_calls" == 1 ]] || fail "path overlap was not synced (rc=$rc calls=$update_calls)"
mergeable=CONFLICTING
run_sync e2e-conflict b.txt a.txt 1 0
[[ "$rc" == 0 && "$update_calls" == 0 && "$repair_calls" == 1 ]] || fail "conflict did not go to repair (rc=$rc update=$update_calls repair=$repair_calls)"
# One sync per (PR, main): the async update-branch moves the head, so the next tick sees a head the memo does not know.
# With main unchanged that head must not sync again; a main move that touches a PR path must.
mergeable=MERGEABLE
run_sync e2e-memo a.txt a.txt 1 0
[[ "$rc" == 0 && "$update_calls" == 1 ]] || fail "memo case: first sync missing (rc=$rc calls=$update_calls)"
git -C "$ROOT" checkout -q pr; printf 'async\n' > "$ROOT/c.txt"; git -C "$ROOT" add -A; git -C "$ROOT" commit -q -m async-head
PR_HEAD="$(git -C "$ROOT" rev-parse pr)"; git -C "$ROOT" checkout -q main
update_calls=0; SLOT_SYNC_SPENT=0; rc=0; slot_sync u1 "$PR_HEAD" 0 0 || rc=$?
[[ "$rc" == 1 && "$update_calls" == 0 ]] || fail "second tick after the async head move synced again (rc=$rc calls=$update_calls)"
printf 'more\n' >> "$ROOT/a.txt"; git -C "$ROOT" commit -q -am main-moves; git -C "$ROOT" update-ref refs/remotes/origin/main main
update_calls=0; SLOT_SYNC_SPENT=0; rc=0; slot_sync u1 "$PR_HEAD" 0 0 || rc=$?
[[ "$rc" == 0 && "$update_calls" == 1 ]] || fail "a main move touching a PR path did not sync (rc=$rc calls=$update_calls)"
echo 'ci-admission-slot-sync.test.sh: pass (no refresh when clean and fresh; refresh on stale next, overlap, conflict; one sync per PR and main)'
