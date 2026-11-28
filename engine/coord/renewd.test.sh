#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$test_env_root/renewd"
remote="$fixture/remote.git"
repo="$fixture/repo"
agent="$fixture/agent"
agent_b="$fixture/agent-b"
clock="$fixture/clock"
runner="$fixture/runner"
service="$engine/systemd/zenoforge-renewd.service"
timer="$engine/systemd/zenoforge-renewd.timer"
[[ -f "$service" && -f "$timer" ]]
grep -Fxq 'Type=oneshot' "$service"
grep -Fxq 'OnActiveSec=60s' "$timer"
grep -Fxq 'OnUnitActiveSec=60s' "$timer"
if grep -Fq 'zenoforge-renewd.timer' "$engine/systemd/pipeline-timers.list"; then
  echo 'renewd.test.sh: the local coordination timer is in the shipped timer list' >&2
  exit 1
fi
mkdir -p "$fixture/bin" "$repo" "$runner"
git init --bare --quiet "$remote"
git -C "$repo" init --quiet
git -C "$repo" remote add origin "$remote"
printf '0\n' >"$clock"
export ZF_COORD_TEST_REAL_GIT="$(type -P git)"
export ZF_COORD_TEST_PUSH_LOG="$fixture/push.log"
export ZF_COORD_TEST_RUNNER_DIR="$runner"
export ZF_COORD_TEST_STOP_LOG="$fixture/stops.log"
cat >"$fixture/bin/git" <<'GIT'
#!/usr/bin/env bash
subcommand=""
for arg in "$@"; do
  case "$arg" in
    fetch|ls-remote|push) subcommand="$arg"; break ;;
  esac
done
if [[ "$subcommand" == push ]]; then
  printf '%s\n' push >>"$ZF_COORD_TEST_PUSH_LOG"
  case "${ZF_COORD_TEST_PUSH_MODE:-}" in
    fail) exit 128 ;;
    lost-ack)
      "$ZF_COORD_TEST_REAL_GIT" "$@" || exit $?
      exit 128
      ;;
    same-owner-race)
      repo="${2:?repository required}"
      race_ref=""
      race_old=""
      for arg in "$@"; do
        case "$arg" in
          --force-with-lease=refs/claims/"$ZF_COORD_TEST_RACE_KEY":*)
            race_ref="refs/claims/$ZF_COORD_TEST_RACE_KEY"
            race_old="${arg#--force-with-lease=$race_ref:}"
            ;;
        esac
      done
      if [[ -n "$race_ref" && "$race_old" =~ ^[0-9a-f]{40,64}$ ]]; then
        race_now="$(<"$ZF_COORD_CLOCK_FILE")"
        race_lease="${ZF_COORD_LEASE_SECONDS:-900}"
        race_record="$("$ZF_COORD_TEST_REAL_GIT" -C "$repo" cat-file blob "$race_old:claim.json")"
        race_record="$(jq -c --argjson now "$race_now" --argjson lease "$race_lease" '.renewed_at=$now | .expires_at=($now+$lease)' <<<"$race_record")"
        race_blob="$(printf '%s\n' "$race_record" | "$ZF_COORD_TEST_REAL_GIT" -C "$repo" hash-object -w --stdin)"
        race_tree="$(printf '100644 blob %s\tclaim.json\n' "$race_blob" | "$ZF_COORD_TEST_REAL_GIT" -C "$repo" mktree)"
        race_commit="$(GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
          "$ZF_COORD_TEST_REAL_GIT" -C "$repo" commit-tree "$race_tree" -m race)"
        "$ZF_COORD_TEST_REAL_GIT" -C "$repo" push --force-with-lease="$race_ref:$race_old" origin "$race_commit:$race_ref" >/dev/null 2>&1 || exit $?
      fi
      ;;
  esac
fi
if [[ "$subcommand" == fetch && "${ZF_COORD_TEST_FETCH_MODE:-}" == fail ]]; then exit 128; fi
exec "$ZF_COORD_TEST_REAL_GIT" "$@"
GIT
cat >"$fixture/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
if [[ "${1:-}" == --user && "${2:-}" == show ]]; then
  cat "$ZF_COORD_TEST_RUNNER_DIR/${3:?unit required}"
elif [[ "${1:-}" == --user && "${2:-}" == stop ]]; then
  printf '%s\n' "$3" >>"$ZF_COORD_TEST_STOP_LOG"
  printf 'inactive\n' >"$ZF_COORD_TEST_RUNNER_DIR/$3"
else
  exit 2
fi
SYSTEMCTL
chmod +x "$fixture/bin/git" "$fixture/bin/systemctl"

run_coord() {
  env AGENT_HOME="$agent" ZF_COORD=on ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" ZF_HOST_ID=test-a \
    ZF_COORD_CLOCK_FILE="$clock" PATH="$fixture/bin:$PATH" \
    bash -c 'source "$ZF_ENGINE_DIR/config.sh"; REPO_DIR="$ZF_REPO_DIR"; GIT_FETCH_TIMEOUT_SEC=60; source "$ZF_ENGINE_DIR/lib.d/transport.sh"; coord_source_if_enabled; "$@"' _ "$@"
}

run_coord_b() {
  env AGENT_HOME="$agent_b" ZF_COORD=on ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" ZF_HOST_ID=test-b \
    ZF_COORD_CLOCK_FILE="$clock" PATH="$fixture/bin:$PATH" \
    bash -c 'source "$ZF_ENGINE_DIR/config.sh"; REPO_DIR="$ZF_REPO_DIR"; GIT_FETCH_TIMEOUT_SEC=60; source "$ZF_ENGINE_DIR/lib.d/transport.sh"; coord_source_if_enabled; "$@"' _ "$@"
}

run_renewd() {
  env AGENT_HOME="$agent" ZF_COORD=on ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" ZF_HOST_ID=test-a \
    ZF_COORD_CLOCK_FILE="$clock" ZF_COORD_TEST_RUNNER_DIR="$runner" ZF_COORD_TEST_CLOCK_FILE="$clock" \
    ZF_COORD_TEST_STOP_LOG="$ZF_COORD_TEST_STOP_LOG" PATH="$fixture/bin:$PATH" \
    bash "$engine/coord/renewd.sh" --once
}

run_renewd_b() {
  env AGENT_HOME="$agent_b" ZF_COORD=on ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" ZF_HOST_ID=test-b \
    ZF_COORD_CLOCK_FILE="$clock" ZF_COORD_TEST_RUNNER_DIR="$runner" \
    ZF_COORD_TEST_STOP_LOG="$ZF_COORD_TEST_STOP_LOG" PATH="$fixture/bin:$PATH" \
    bash "$engine/coord/renewd.sh" --once
}

seed_claim() {
  run_coord coord_acquire issue-123 owner-a systemd-worker 123 zf-implement-123.service implement
  printf 'active\n' >"$runner/zf-implement-123.service"
  run_coord coord_acquire issue-122 owner-z systemd-worker 122 zf-implement-122.service implement
  printf 'active\n' >"$runner/zf-implement-122.service"
}

seed_claim
printf 'test-instance\n' >"$agent/coord/instance"
: >"$ZF_COORD_TEST_PUSH_LOG"
run_renewd
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-123:claim.json)"
jq -e '.owner == "owner-a" and .renewed_at == 0 and .expires_at == 900' <<<"$claim" >/dev/null
claim_b="$(git --git-dir="$remote" cat-file blob refs/claims/issue-122:claim.json)"
jq -e '.owner == "owner-z" and .renewed_at == 0 and .expires_at == 900' <<<"$claim_b" >/dev/null
status="$(git --git-dir="$remote" cat-file blob refs/status/test-a:worker.json)"
jq -e '.host == "test-a" and .instance == "test-instance" and .proto == 1' <<<"$status" >/dev/null
[[ "$(wc -l <"$ZF_COORD_TEST_PUSH_LOG" | tr -d ' ')" == 1 ]]
run_coord coord_release issue-122 owner-z

printf '60\n' >"$clock"
export ZF_COORD_TEST_PUSH_MODE=lost-ack
run_renewd
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-123:claim.json)"
jq -e '.renewed_at == 60' <<<"$claim" >/dev/null
jq -e '.held_at == 60' "$agent/coord/held/issue-123" >/dev/null
unset ZF_COORD_TEST_PUSH_MODE

printf 'inactive\n' >"$runner/zf-implement-123.service"
run_renewd
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-123:claim.json)"
jq -e '.owner == "owner-a"' <<<"$claim" >/dev/null
printf '359\n' >"$clock"
run_renewd
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-123:claim.json)"
jq -e '.owner == "owner-a"' <<<"$claim" >/dev/null
printf '360\n' >"$clock"
run_renewd
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-123:claim.json)"
jq -e '.owner == null and .release_reason == "run-gone"' <<<"$claim" >/dev/null

run_coord coord_acquire issue-124 owner-b systemd-worker 124 zf-implement-124.service implement
printf 'active\n' >"$runner/zf-implement-124.service"
run_renewd
printf '959\n' >"$clock"
export ZF_COORD_TEST_PUSH_MODE=fail
run_renewd || :
[[ ! -s "$ZF_COORD_TEST_STOP_LOG" ]]
run_coord coord_assert_owned issue-124 owner-b >/dev/null
printf '960\n' >"$clock"
run_renewd || :
grep -Fxq 'zf-implement-124.service' "$ZF_COORD_TEST_STOP_LOG"
if run_coord coord_assert_owned issue-124 owner-b >/dev/null; then
  echo 'renewd.test.sh: a claim past the self-fence deadline was still owned' >&2
  exit 1
else
  rc=$?
  [[ "$rc" == 3 ]]
fi

unset ZF_COORD_TEST_PUSH_MODE
run_coord coord_acquire issue-125 owner-c systemd-worker 125 zf-implement-125.service implement
run_coord coord_release issue-125 owner-c
run_renewd
[[ -n "$(git --git-dir="$remote" show-ref --verify --hash refs/claims/issue-125 2>/dev/null || true)" ]]
printf '605759\n' >"$clock"
run_renewd
[[ -n "$(git --git-dir="$remote" show-ref --verify --hash refs/claims/issue-125 2>/dev/null || true)" ]]
printf '605760\n' >"$clock"
run_renewd
if git --git-dir="$remote" show-ref --verify --quiet refs/claims/issue-125; then
  echo 'renewd.test.sh: an unchanged released claim survived the janitor deadline' >&2
  exit 1
fi

run_coord coord_acquire issue-129 owner-i systemd-worker 129 zf-implement-129.service implement
printf 'active\n' >"$runner/zf-implement-129.service"
run_renewd
now="$(<"$clock")"
printf '%s\n' "$((now + 600))" >"$clock"
export ZF_COORD_TEST_FETCH_MODE=fail
run_renewd || :
grep -Fxq 'zf-implement-129.service' "$ZF_COORD_TEST_STOP_LOG"
jq -e '.lost == true and .owner_kind == "systemd-worker"' "$agent/coord/held/issue-129" >/dev/null
unset ZF_COORD_TEST_FETCH_MODE

run_coord coord_acquire issue-130 owner-f feeder 130 fastlane-130 fastlane 99999999 1
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-130:claim.json)"
jq -e 'has("pid") | not' <<<"$claim" >/dev/null
jq -e '.pid and .pid_start' "$agent/coord/held/issue-130" >/dev/null
run_coord coord_renew issue-130 owner-f 99999998 2
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-130:claim.json)"
jq -e 'has("pid") | not' <<<"$claim" >/dev/null
jq -e '.pid == 99999998 and .pid_start == 2' "$agent/coord/held/issue-130" >/dev/null
run_renewd
now="$(<"$clock")"
printf '%s\n' "$((now + 299))" >"$clock"
run_renewd
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-130:claim.json)"
jq -e '.owner == "owner-f"' <<<"$claim" >/dev/null
printf '%s\n' "$((now + 300))" >"$clock"
run_renewd
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-130:claim.json)"
jq -e '.owner == null and .release_reason == "run-gone"' <<<"$claim" >/dev/null

export ZF_COORD_LEASE_SECONDS=120
run_coord coord_acquire issue-130 owner-j systemd-worker 130 zf-implement-130.service implement
printf 'active\n' >"$runner/zf-implement-130.service"
run_renewd
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-130:claim.json)"
renewed_at="$(jq -r '.renewed_at' <<<"$claim")"
now="$(<"$clock")"
printf '%s\n' "$((now + 120))" >"$clock"
run_renewd
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-130:claim.json)"
jq -e --argjson renewed "$renewed_at" '.owner == "owner-j" and .renewed_at == $renewed and .expires_at == .renewed_at + 120' <<<"$claim" >/dev/null
grep -Fxq 'zf-implement-130.service' "$ZF_COORD_TEST_STOP_LOG"
jq -e '.lost == true' "$agent/coord/held/issue-130" >/dev/null
unset ZF_COORD_LEASE_SECONDS

run_coord coord_acquire issue-127 owner-e systemd-worker 127 zf-implement-127.service implement
printf 'active\n' >"$runner/zf-implement-127.service"
run_renewd
if run_coord_b coord_acquire issue-127 owner-f systemd-worker 127 zf-implement-127.service implement; then
  echo 'renewd.test.sh: a peer acquired a live claim' >&2
  exit 1
else
  rc=$?
  [[ "$rc" == 1 ]]
fi
printf 'inactive\n' >"$runner/zf-implement-127.service"
run_renewd
now="$(<"$clock")"
printf '%s\n' "$((now + 299))" >"$clock"
run_renewd
if run_coord_b coord_acquire issue-127 owner-f systemd-worker 127 zf-implement-127.service implement; then
  echo 'renewd.test.sh: a peer acquired during the dead-run grace' >&2
  exit 1
else
  rc=$?
  [[ "$rc" == 1 ]]
fi
now="$(<"$clock")"
printf '%s\n' "$((now + 1))" >"$clock"
run_renewd
run_coord_b coord_acquire issue-127 owner-f systemd-worker 127 zf-implement-127.service implement
printf 'active\n' >"$runner/zf-implement-127.service"
run_renewd_b
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-127:claim.json)"
jq -e '.owner == "owner-f"' <<<"$claim" >/dev/null
status_b="$(git --git-dir="$remote" cat-file blob refs/status/test-b:worker.json)"
jq -e '.host == "test-b" and .instance != "test-instance"' <<<"$status_b" >/dev/null

run_coord coord_acquire issue-128 owner-g systemd-worker 128 zf-implement-128.service implement
printf 'active\n' >"$runner/zf-implement-128.service"
run_renewd
if run_coord_b coord_acquire issue-128 owner-h systemd-worker 128 zf-implement-128.service implement; then
  echo 'renewd.test.sh: a peer acquired before the lease expired' >&2
  exit 1
else
  rc=$?
  [[ "$rc" == 1 ]]
fi
now="$(<"$clock")"
printf '%s\n' "$((now + 450))" >"$clock"
if run_coord_b coord_acquire issue-128 owner-h systemd-worker 128 zf-implement-128.service implement; then
  echo 'renewd.test.sh: a peer acquired before the observation lease' >&2
  exit 1
else
  rc=$?
  [[ "$rc" == 1 ]]
fi
export ZF_COORD_TEST_PUSH_MODE=fail
now="$(<"$clock")"
printf '%s\n' "$((now + 150))" >"$clock"
run_renewd || :
grep -Fxq 'zf-implement-128.service' "$ZF_COORD_TEST_STOP_LOG"
if run_coord coord_assert_owned issue-128 owner-g >/dev/null; then
  echo 'renewd.test.sh: fenced host still passed ownership check' >&2
  exit 1
else
  rc=$?
  [[ "$rc" == 3 ]]
fi
unset ZF_COORD_TEST_PUSH_MODE
now="$(<"$clock")"
printf '%s\n' "$((now + 300))" >"$clock"
run_coord_b coord_acquire issue-128 owner-h systemd-worker 128 zf-implement-128.service implement
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-128:claim.json)"
jq -e '.owner == "owner-h"' <<<"$claim" >/dev/null

run_coord coord_acquire issue-126 owner-d systemd-worker 126 zf-implement-126.service implement
printf 'active\n' >"$runner/zf-implement-126.service"
run_renewd
status="$(git --git-dir="$remote" cat-file blob refs/status/test-a:worker.json | jq -c '.instance="other-instance"')"
blob="$(printf '%s\n' "$status" | git --git-dir="$remote" hash-object -w --stdin)"
tree="$(printf '100644 blob %s\tworker.json\n' "$blob" | git --git-dir="$remote" mktree)"
commit="$(GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture \
  GIT_COMMITTER_EMAIL=fixture@example.invalid git --git-dir="$remote" commit-tree "$tree" -m fixture)"
git --git-dir="$remote" update-ref refs/status/test-a "$commit"
: >"$ZF_COORD_TEST_PUSH_LOG"
run_renewd || :
grep -Fxq 'zf-implement-126.service' "$ZF_COORD_TEST_STOP_LOG"
jq -e '.lost == true' "$agent/coord/held/issue-126" >/dev/null
[[ ! -s "$ZF_COORD_TEST_PUSH_LOG" ]]
status="$(git --git-dir="$remote" cat-file blob refs/status/test-a:worker.json | jq -c '.instance="test-instance"')"
blob="$(printf '%s\n' "$status" | git --git-dir="$remote" hash-object -w --stdin)"
tree="$(printf '100644 blob %s\tworker.json\n' "$blob" | git --git-dir="$remote" mktree)"
commit="$(GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture \
  GIT_COMMITTER_EMAIL=fixture@example.invalid git --git-dir="$remote" commit-tree "$tree" -m fixture)"
git --git-dir="$remote" update-ref refs/status/test-a "$commit"

run_coord coord_acquire issue-131 owner-k systemd-worker 131 zf-implement-131.service implement
printf 'active\n' >"$runner/zf-implement-131.service"
run_renewd
now="$(<"$clock")"
printf '%s\n' "$((now + 60))" >"$clock"
export ZF_COORD_TEST_PUSH_MODE=same-owner-race
export ZF_COORD_TEST_RACE_KEY=issue-131
run_renewd || :
unset ZF_COORD_TEST_PUSH_MODE ZF_COORD_TEST_RACE_KEY
remote_oid="$(git --git-dir="$remote" rev-parse refs/claims/issue-131)"
jq -e --arg owner owner-k --arg oid "$remote_oid" '.owner == $owner and .oid == $oid and .lost != true' "$agent/coord/held/issue-131" >/dev/null
if grep -Fxq 'zf-implement-131.service' "$ZF_COORD_TEST_STOP_LOG"; then
  echo 'renewd.test.sh: a same-owner concurrent renewal fenced the live run' >&2
  exit 1
fi

printf 'renewd.test.sh: PASS (multi-claim batched renewal, status publish, instance check, lost acknowledgement, same-owner renewal race, dead-run release and takeover, self-fence during outage and takeover, expired lease, janitor)\n'
