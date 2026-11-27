#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

export ZF_COORD_RELEASED_RETAIN_SECONDS=3600
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/coord.sh"

fail() { printf 'coord.test.sh: %s\n' "$*" >&2; exit 1; }
new_owner="$(coord_new_owner)" || fail 'coord_new_owner failed'
[[ "$new_owner" =~ ^owner-[0-9]+-[0-9]+-[0-9]+-[0-9]+$ ]] || fail 'coord_new_owner returned an invalid owner id'
trial() { printf 'coord.test.sh: trial %s: %s\n' "$1" "$2"; }

now="$(date +%s)"
retain_seconds=3600
older="issue-81001"
inside="issue-81002"
live="issue-81003"
legacy="issue-81004"
malformed="issue-81005"

write_claim() {
  local key="$1" owner="$2" expires_at="$3" released_at="$4"
  jq -cn --arg key "$key" --arg owner "$owner" --arg released_at "$released_at" \
    --argjson now "$now" --argjson expires_at "$expires_at" \
    '{version:1,key:$key,owner:(if $owner=="" then null else $owner end),owner_kind:"test",
      subject:$key,unit:"test-unit",stage:"test",acquired_at:$now,renewed_at:$now,expires_at:$expires_at}
     + (if $released_at=="" then {} else
          {last_owner:"fixture-owner",released_at:($released_at|tonumber),release_reason:"released"}
        end)' > "$COORD_DIR/$key.json"
}

mkdir -p "$COORD_DIR"
write_claim "$older" "" 0 "$((now-retain_seconds-10))"
write_claim "$inside" "" 0 "$((now-retain_seconds+60))"
write_claim "$live" "owner-live" "$((now+600))" ""
write_claim "$legacy" "" 0 ""

coord_reap_expired || fail 'claim sweep failed'
[[ ! -e "$COORD_DIR/$older.json" ]] || fail 'released claim older than the retention window was not pruned'
[[ -e "$COORD_DIR/$older.lock" ]] || fail 'pruning removed the per-key lock file'
[[ -e "$COORD_DIR/$inside.json" ]] || fail 'released claim inside the retention window was pruned'
[[ -e "$COORD_DIR/$live.json" ]] || fail 'live claim was pruned'
[[ -e "$COORD_DIR/$legacy.json" ]] || fail 'claim without released_at was pruned'

if coord_read "$older" >/dev/null; then
  fail 'pruned claim did not read as absent before reacquire'
else
  rc=$?
  (( rc == 1 )) || fail "pruned claim read returned $rc instead of absent (1)"
fi
coord_acquire "$older" owner-after-prune test 81001 test-unit test \
  || fail 'claim could not be acquired after pruning'
coord_read "$older" >/dev/null || fail 'reacquired claim was not readable'

printf '{ malformed json\n' > "$COORD_DIR/$malformed.json"
if coord_reap_expired 2>/dev/null; then
  fail 'malformed claim did not keep the sweep fail-closed'
else
  rc=$?
  (( rc == 3 )) || fail "malformed claim sweep returned $rc instead of unknown (3)"
fi
[[ -e "$COORD_DIR/$malformed.json" ]] || fail 'malformed claim was removed'

clock_file="$test_env_root/coord-clock"
printf '123456\n' > "$clock_file"
ZF_COORD_CLOCK_FILE="$clock_file"
[[ "$(coord_now_s)" == 123456 ]] || fail 'coord_now_s ignored the virtual clock file'
printf 'invalid\n' > "$clock_file"
if coord_now_s >/dev/null 2>&1; then fail 'coord_now_s accepted a malformed clock value'; fi
unset ZF_COORD_CLOCK_FILE

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/coord/sim/lib.sh"
sim_world_new "$test_env_root/coord-sim"
sim_host_new A
sim_host_new B
printf '100\n' > "$SIM_WORLD/A.clock"
printf '100\n' > "$SIM_WORLD/B.clock"

coord_remote_run() {
  local host="$1" action="$2"
  shift 2
  sim_as "$host" -- env AGENT_HOME="$SIM_WORLD/hosts/$host" \
    REPO_DIR="$SIM_WORLD/hosts/$host/coord/repo.git" ZF_COORD=on ZF_HOST_ID="$host" \
    ZF_COORD_LEASE_SECONDS=10 ZF_COORD_CLOCK_FILE="$SIM_WORLD/$host.clock" \
    ZF_COORD_TEST_RACE_DIR="${ZF_COORD_TEST_RACE_DIR:-}" ZF_COORD_TEST_RACE_KEY="${ZF_COORD_TEST_RACE_KEY:-}" \
    bash -c '
      source "$SIM_ENGINE_DIR/coord.sh"
      git() {
        local status=0 push=0 arg
        for arg in "$@"; do [[ "$arg" == push ]] && push=1; done
        command git "$@" || status=$?
        if (( push == 1 && status == 0 )) && [[ "${ZF_COORD_TEST_DROP_ACK:-0}" == 1 ]]; then
          ZF_COORD_TEST_DROP_ACK=0
          return 1
        fi
        return "$status"
      }
      git_fetch_bounded() {
        local repo="$1"
        shift
        git -C "$repo" fetch --quiet origin "$@"
      }
      action="$1"
      shift
      if [[ "$action" == acquire && "${1:-}" == "${ZF_COORD_TEST_RACE_KEY:-}" && -n "${ZF_COORD_TEST_RACE_DIR:-}" ]]; then
        : > "$ZF_COORD_TEST_RACE_DIR/$ZF_HOST_ID.ready"
        for ((attempt = 0; attempt < 1000; attempt++)); do
          [[ -e "$ZF_COORD_TEST_RACE_DIR/go" ]] && break
          sleep 0.01
        done
        [[ -e "$ZF_COORD_TEST_RACE_DIR/go" ]] || exit 3
      fi
      case "$action" in
        read) coord_read "$@" ;;
        acquire) coord_acquire "$@" ;;
        held) [[ -r "$AGENT_HOME/coord/held/$1" ]] && cat -- "$AGENT_HOME/coord/held/$1" ;;
        batch) coord_acquire_many "$@" ;;
        lost-ack) ZF_COORD_TEST_DROP_ACK=1; coord_acquire "$@" ;;
        renew) coord_renew "$@" ;;
        release) coord_release "$@" ;;
        assert) coord_assert_owned "$@" ;;
        init) coord_init ;;
        refresh) coord_refresh ;;
      esac
    ' _ "$action" "$@"
}

coord_remote_publish() {
  local key="$1" record="$2" blob tree commit
  blob="$(printf '%s\n' "$record" | "$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\tclaim.json\n' "$blob" | "$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" mktree)"
  commit="$(GIT_AUTHOR_NAME=zenoforge-coord GIT_AUTHOR_EMAIL=coord@localhost \
    GIT_COMMITTER_NAME=zenoforge-coord GIT_COMMITTER_EMAIL=coord@localhost \
    "$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" commit-tree "$tree" -m "claim $key")"
  "$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" update-ref "refs/claims/$key" "$commit"
}

trial 1 'remote init, refresh, and owned read'
coord_remote_run A init || fail 'coord_init wrapper failed'
coord_remote_run A refresh || fail 'coord_refresh wrapper failed'

valid_remote="issue-81005"
valid_record="$(jq -cn --arg key "$valid_remote" \
  '{proto:1,version:1,key:$key,owner:"owner-a",owner_kind:"test",subject:$key,unit:"test-unit",stage:"test",expires_at:200}')"
coord_remote_publish "$valid_remote" "$valid_record"
valid_read="$(coord_remote_run A read "$valid_remote")" \
  || fail "valid remote claim did not read as owned: $valid_read"
[[ $(jq -r '.owner' <<<"$valid_read") == owner-a ]] || fail 'valid remote claim lost its owner'
printf 'invalid\n' > "$SIM_WORLD/B.clock"
if coord_remote_run B read "$valid_remote" >/dev/null 2>&1; then
  fail 'remote claim read succeeded with an invalid clock'
else
  rc=$?
  (( rc == 3 )) || fail "remote claim clock failure returned $rc instead of unknown (3)"
fi
printf '100\n' > "$SIM_WORLD/B.clock"
trial 2 'initial quiet observation does not take over'
if coord_remote_run B acquire "$valid_remote" owner-b test "$valid_remote" unit-b implement; then
  fail 'claim was taken over before an observation interval'
else
  rc=$?
  (( rc == 1 )) || fail "first quiet-claim read returned $rc instead of held (1)"
fi
trial 3 'incomplete lease observation does not take over'
printf '105\n' > "$SIM_WORLD/B.clock"
if coord_remote_run B acquire "$valid_remote" owner-b test "$valid_remote" unit-b implement; then
  fail 'claim was taken over before the lease interval'
else
  rc=$?
  (( rc == 1 )) || fail "second quiet-claim read returned $rc instead of held (1)"
fi
trial 4 'unchanged claim is taken over after a full observation lease'
printf '110\n' > "$SIM_WORLD/B.clock"
coord_remote_run B acquire "$valid_remote" owner-b test "$valid_remote" unit-b implement \
  || fail 'unchanged claim was not taken over after a full observation lease'
taken_over="$(coord_remote_run A read "$valid_remote")" || fail 'taken-over claim could not be read'
[[ $(jq -r '.owner' <<<"$taken_over") == owner-b ]] || fail 'takeover did not publish the new owner'
[[ $(jq -r '.generation' <<<"$taken_over") == 2 ]] || fail 'takeover did not increment generation'

trial 5 'too-new proto reads as unknown'
too_new="issue-81006"
too_new_record="$(jq -cn --arg key "$too_new" \
  '{proto:2,version:1,key:$key,owner:"owner-a",owner_kind:"test",subject:$key,unit:"test-unit",stage:"test",expires_at:200}')"
coord_remote_publish "$too_new" "$too_new_record"
if coord_remote_run A read "$too_new" >/dev/null 2>&1; then
  fail 'too-new remote claim read as owned'
else
  rc=$?
  (( rc == 3 )) || fail "too-new remote claim read returned $rc instead of unknown (3)"
fi

trial 6 'malformed record reads as unknown'
malformed_remote="issue-81007"
malformed_record="$(jq -cn --arg key "$malformed_remote" \
  '{version:1,key:$key,owner:"owner-a",subject:$key,unit:"test-unit",stage:"test",expires_at:200}')"
coord_remote_publish "$malformed_remote" "$malformed_record"
if coord_remote_run A read "$malformed_remote" >/dev/null 2>&1; then
  fail 'malformed remote claim read as owned'
else
  rc=$?
  (( rc == 3 )) || fail "malformed remote claim read returned $rc instead of unknown (3)"
fi

trial 7 'long observation gap resets the takeover interval'
gap_key="issue-81008"
gap_record="$(jq -cn --arg key "$gap_key" \
  '{proto:1,version:1,key:$key,owner:"owner-a",owner_kind:"test",subject:$key,unit:"test-unit",stage:"test",generation:1,expires_at:200}')"
coord_remote_publish "$gap_key" "$gap_record"
if coord_remote_run B acquire "$gap_key" owner-b test "$gap_key" unit-b implement; then fail 'first gap observation took over'; else rc=$?; (( rc == 1 )) || fail "first gap observation returned $rc"; fi
printf '106\n' > "$SIM_WORLD/B.clock"
if coord_remote_run B acquire "$gap_key" owner-b test "$gap_key" unit-b implement; then fail 'claim took over across an observation gap'; else rc=$?; (( rc == 1 )) || fail "gap reset returned $rc"; fi
printf '111\n' > "$SIM_WORLD/B.clock"
if coord_remote_run B acquire "$gap_key" owner-b test "$gap_key" unit-b implement; then fail 'gap reset did not restart the observation lease'; else rc=$?; (( rc == 1 )) || fail "post-gap observation returned $rc"; fi
printf '116\n' > "$SIM_WORLD/B.clock"
coord_remote_run B acquire "$gap_key" owner-b test "$gap_key" unit-b implement || fail 'claim did not become takeable after a complete post-gap observation lease'

trial 8 'backward clock step resets the takeover interval'
backward_key="issue-81009"
backward_record="$(jq -cn --arg key "$backward_key" \
  '{proto:1,version:1,key:$key,owner:"owner-a",owner_kind:"test",subject:$key,unit:"test-unit",stage:"test",generation:1,expires_at:300}')"
coord_remote_publish "$backward_key" "$backward_record"
printf '200\n' > "$SIM_WORLD/B.clock"
if coord_remote_run B acquire "$backward_key" owner-b test "$backward_key" unit-b implement; then fail 'first backward-clock observation took over'; else rc=$?; (( rc == 1 )) || fail "first backward-clock observation returned $rc"; fi
printf '205\n' > "$SIM_WORLD/B.clock"
if coord_remote_run B acquire "$backward_key" owner-b test "$backward_key" unit-b implement; then fail 'second backward-clock observation took over'; else rc=$?; (( rc == 1 )) || fail "second backward-clock observation returned $rc"; fi
printf '204\n' > "$SIM_WORLD/B.clock"
if coord_remote_run B acquire "$backward_key" owner-b test "$backward_key" unit-b implement; then fail 'claim took over after a backward clock step'; else rc=$?; (( rc == 1 )) || fail "backward-clock reset returned $rc"; fi
printf '209\n' > "$SIM_WORLD/B.clock"
if coord_remote_run B acquire "$backward_key" owner-b test "$backward_key" unit-b implement; then fail 'backward-clock reset did not restart the observation lease'; else rc=$?; (( rc == 1 )) || fail "post-backward observation returned $rc"; fi
printf '214\n' > "$SIM_WORLD/B.clock"
coord_remote_run B acquire "$backward_key" owner-b test "$backward_key" unit-b implement || fail 'claim did not become takeable after a complete post-step observation lease'

trial 9 'lost push acknowledgement resolves by remote readback'
lost_ack_key="issue-81010"
coord_remote_run A lost-ack "$lost_ack_key" owner-ack test "$lost_ack_key" unit-a implement \
  || fail 'acquire did not resolve a lost push acknowledgement by readback'
lost_ack_record="$(coord_remote_run B read "$lost_ack_key")" || fail 'lost-ack claim was not readable'
[[ $(jq -r '.owner' <<<"$lost_ack_record") == owner-ack ]] || fail 'lost-ack readback did not confirm the writer owner'
held_record="$(coord_remote_run A held "$lost_ack_key")" || fail 'successful acquire did not create a held entry'
[[ $(jq -r '.owner' <<<"$held_record") == owner-ack ]] || fail 'held entry owner does not match the acquired claim'
trial 10 'held entry follows renewal and release'
coord_remote_run A renew "$lost_ack_key" owner-ack || fail 'owned remote claim did not renew'
held_record="$(coord_remote_run A held "$lost_ack_key")" || fail 'renew removed the held entry'
[[ $(jq -r '.owner' <<<"$held_record") == owner-ack ]] || fail 'renewed held entry owner changed'
coord_remote_run A release "$lost_ack_key" owner-ack || fail 'owned remote claim did not release'
if coord_remote_run A held "$lost_ack_key" >/dev/null 2>&1; then fail 'release did not remove the held entry'; fi

trial 11 'partial batch rolls back prior acquired claims'
batch_blocked="issue-81012"
batch_blocked_record="$(jq -cn --arg key "$batch_blocked" \
  '{proto:1,version:1,key:$key,owner:"owner-a",owner_kind:"test",subject:$key,unit:"test-unit",stage:"test",generation:1,expires_at:300}')"
coord_remote_publish "$batch_blocked" "$batch_blocked_record"
if batch_output="$(coord_remote_run B batch owner-b test unit-b implement 81011 81012)"; then
  fail 'partial remote batch succeeded despite a held member'
else
  rc=$?
  (( rc == 1 )) || fail "partial remote batch returned $rc instead of held (1): $batch_output"
fi
if coord_remote_run A read issue-81011 >/dev/null 2>&1; then
  fail 'partial remote batch did not release its first acquired member'
else
  rc=$?
  (( rc == 1 )) || fail "partial remote batch rollback read returned $rc instead of free (1)"
fi

trial 12 'twenty concurrent acquirers produce one winner'
race_key="issue-81013"
race_dir="$SIM_WORLD/coord-race"
mkdir -p "$race_dir"
race_hosts=()
race_pids=()
for ((i = 1; i <= 20; i++)); do
  race_host="race-$i"
  sim_host_new "$race_host"
  printf '300\n' > "$SIM_WORLD/$race_host.clock"
  race_hosts+=("$race_host")
done
export ZF_COORD_TEST_RACE_DIR="$race_dir" ZF_COORD_TEST_RACE_KEY="$race_key"
for race_host in "${race_hosts[@]}"; do
  coord_remote_run "$race_host" acquire "$race_key" "owner-$race_host" test "$race_key" "unit-$race_host" implement \
    > "$SIM_WORLD/$race_host.out" 2>&1 &
  race_pids+=("$!")
done
for race_host in "${race_hosts[@]}"; do
  sim_wait_for "$race_dir/$race_host.ready" || fail "20-way acquirer $race_host did not reach the compare-and-swap barrier: $(<"$SIM_WORLD/$race_host.out")"
done
: > "$race_dir/go"
race_winners=0
for race_pid in "${race_pids[@]}"; do
  if wait "$race_pid"; then
    race_winners=$((race_winners + 1))
  else
    rc=$?
    (( rc == 1 )) || fail "20-way acquirer returned $rc instead of held (1)"
  fi
done
[[ $race_winners == 1 ]] || fail "20-way race produced $race_winners winners instead of one"
unset ZF_COORD_TEST_RACE_DIR ZF_COORD_TEST_RACE_KEY

printf 'coord.test.sh: PASS\n'
