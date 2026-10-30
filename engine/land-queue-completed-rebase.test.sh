#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
queue_script="${LAND_QUEUE_TEST_SCRIPT:-$root/engine/land-queue.sh}"
trap 'rm -rf -- "$test_env_root"' EXIT
export ZF_LAND_QUEUE_DIR="$AGENT_HOME/land-queue"
export TEST_UNIT_STATE=inactive TEST_UNIT_PID=0 TEST_PS_ROW=''
mkdir -p "$ZF_LAND_QUEUE_DIR/requests" "$ZF_LAND_QUEUE_DIR/logs" "$ZF_LAND_QUEUE_DIR/worktrees" "$AGENT_HOME/night/hand-registry"
cat > "$test_env_bin/systemctl" <<'SH'
#!/bin/bash
case "$*" in
  *--property=ActiveState*) printf '%s\n' "$TEST_UNIT_STATE" ;;
  *--property=MainPID*) printf '%s\n' "$TEST_UNIT_PID" ;;
  *) exit 97 ;;
esac
SH
cat > "$test_env_bin/ps" <<'SH'
#!/bin/bash
printf '%s\n' "$TEST_PS_ROW"
SH
chmod +x "$test_env_bin/systemctl" "$test_env_bin/ps"
fail() { echo "FAIL $*" >&2; exit 1; }
index=0
fixture() {
  index=$((index + 1)); ticket="$(printf '%020d' "${1:-$((900 + index))}")"; owner="hand-fixture-$index"; episode="1791940325715409$index"
  source_repo="$test_env_root/source-$index"; repo="$ZF_LAND_QUEUE_DIR/worktrees/$ticket"; request="$ZF_LAND_QUEUE_DIR/requests/$ticket.json"
  git init -q -b main "$source_repo"
  git -C "$source_repo" config user.name fixture; git -C "$source_repo" config user.email fixture@example.test
  mkdir -p "$source_repo/scripts"
  printf 'process.exit(0);\n' > "$source_repo/scripts/branch-delivery-policy.mjs"
  git -C "$source_repo" add .; git -C "$source_repo" commit -qm base
  git -C "$source_repo" checkout -qb source
  printf 'feature\n' > "$source_repo/feature"; git -C "$source_repo" add .; git -C "$source_repo" commit -qm feature
  original="$(git -C "$source_repo" rev-parse HEAD)"
  git -C "$source_repo" checkout -q main
  printf 'upstream\n' > "$source_repo/upstream"; git -C "$source_repo" add .; git -C "$source_repo" commit -qm upstream
  baseline="$(git -C "$source_repo" rev-parse HEAD)"
  git -C "$source_repo" worktree add -qb "land-queue/$ticket" "$repo" "$original"
  if [[ "${2:-}" == different-patch ]]; then
    git -C "$repo" rebase -q --exec "printf 'changed\\n' > feature; git add feature; git commit --amend -qm changed" "$baseline" > "$test_env_root/rebase.log" 2>&1
  else git -C "$repo" rebase -q "$baseline"; fi
  head="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" worktree lock --reason "land-direct-main:ticket=$ticket owner=$owner owner_pid=99999998 owner_start_ticks=1 unit=zf-land-direct-main-$ticket" "$repo"
  report="$test_env_root/report-$index"
  printf 'STATUS: BLOCKED-ON landing-failed %s\n' "$ticket" > "$report"
  reason="queued snapshot changed: branch=land-queue/$ticket head=$head"
  jq -n --arg ticket "$ticket" --arg owner "$owner" --arg episode "$episode" --arg original "$original" --arg repo "$repo" --arg source "$source_repo" --arg report "$report" --arg reason "$reason" \
    '{ticket:$ticket,owner:$owner,state:"failed",head_sha:$original,worktree:$repo,branch:("land-queue/"+$ticket),owner_worktree:$source,report:$report,reason:$reason,finished_epoch:1,hand_owner_resume:{name:$owner,pid:99999999,start_ticks:"1",provider_episode:$episode}}' > "$request"
  jq --arg source "$source_repo" '.hand_owner_resume + {worktree:$source}' "$request" > "$AGENT_HOME/night/hand-registry/$owner.json"
  printf 'land-direct-main: preflight baseline-sha=%s head=%s\n' "$baseline" "$head" > "$ZF_LAND_QUEUE_DIR/logs/$ticket.log"
}
run_recovery() { bash "$queue_script" requeue-completed-rebase "$request" "$owner" "$episode" "$original"; }
reject() {
  cp "$request" "$test_env_root/before.json"
  if run_recovery > "$test_env_root/recovery.log" 2>&1; then fail "$1 accepted"; fi
  cmp "$request" "$test_env_root/before.json" || fail "$1 mutated request"
  echo "PASS rejects $1 without request change"
}
for observed in 758 821; do
  fixture "$observed"
  run_recovery
  jq -e --arg original "$original" --arg head "$head" --arg reason "$reason" '.state == "queued" and .head_sha == $head and .completed_rebase_recovery.original_head == $original and .completed_rebase_recovery.original_failure == $reason and .finished_epoch == null' "$request" >/dev/null || fail recovery-evidence
  echo "PASS observed ticket$observed equivalent own rebase keeps original evidence"
done
fixture; printf 'other\n' > "$repo/other"; git -C "$repo" add other; git -C "$repo" commit -qm unrelated; reject unrelated-snapshot-mutation
fixture '' different-patch; reject changed-source-patch
fixture; printf 'dirty\n' > "$repo/dirty"; reject dirty-private-tree
fixture; TEST_UNIT_STATE=active; reject active-lander; TEST_UNIT_STATE=inactive
fixture; TEST_UNIT_PID=$$; reject retained-unit-PID; TEST_UNIT_PID=0
fixture; TEST_PS_ROW="codex exec --cd $source_repo"; reject active-source-worker; TEST_PS_ROW=''
fixture; TEST_PS_ROW="codex exec --cd $repo"; reject active-private-worker; TEST_PS_ROW=''
fixture
for p in "$request" "$AGENT_HOME/night/hand-registry/$owner.json"; do
  jq --argjson pid "$$" '.pid=$pid | if .hand_owner_resume then .hand_owner_resume.pid=$pid else . end' "$p" > "$p.tmp"; mv "$p.tmp" "$p"
done
reject PID-reuse-or-live-original
fixture; episode=wrong; reject wrong-episode
fixture; original="$(printf '%040d' 1)"; reject wrong-captured-head
fixture; printf 'not-owned\n' > "$ZF_LAND_QUEUE_DIR/logs/$ticket.log"; reject absent-lander-baseline
fixture; jq '.reason="preflight failed"' "$request" > "$request.tmp"; mv "$request.tmp" "$request"; reject real-preflight-refusal
fixture; jq '.provider_episode="different"' "$AGENT_HOME/night/hand-registry/$owner.json" > "$test_env_root/registry.tmp"; mv "$test_env_root/registry.tmp" "$AGENT_HOME/night/hand-registry/$owner.json"; reject changed-owner-episode
fixture; git -C "$repo" worktree unlock "$repo"; reject missing-lander-lock
fixture; git -C "$repo" worktree unlock "$repo"; git -C "$repo" worktree lock --reason "land-direct-main:ticket=$ticket owner=hand-other owner_pid=99999998 owner_start_ticks=1 unit=zf-land-direct-main-$ticket" "$repo"; reject wrong-lock-owner
fixture; git -C "$repo" worktree unlock "$repo"; git -C "$repo" worktree lock --reason "land-direct-main:ticket=$ticket owner=$owner owner_pid=$$ owner_start_ticks=1 unit=zf-land-direct-main-$ticket" "$repo"; reject reused-lock-PID
fixture
{
  flock -x 9
  reject held-request-lock
} 9>"$request.lock"
echo 'PASS completed-rebase focused regression'
