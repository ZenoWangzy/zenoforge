#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$test_env_root/ctl"
remote="$fixture/remote.git"
repo="$fixture/repo"
agent="$fixture/agent"
mkdir -p "$fixture" "$repo" "$agent" "$fixture/autopi" "$fixture/bin"
git init --bare --quiet "$remote"
git -C "$repo" init --quiet
git -C "$repo" remote add origin "$remote"

run_ctl() {
  AGENT_HOME="$agent" ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" ZF_HOST_ID=test-a \
    MAC_AUTOPILOT_RUNTIME_DIR="$fixture/autopi" PATH="$fixture/bin:$PATH" bash "$engine/coord/ctl.sh" "$@"
}

run_coord() {
  local host="$1"
  shift
  AGENT_HOME="$fixture/agent-$host" ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" ZF_HOST_ID="$host" ZF_COORD=on \
    bash -c 'REPO_DIR="$ZF_REPO_DIR"; GIT_FETCH_TIMEOUT_SEC=60; source "$ZF_ENGINE_DIR/lib.d/transport.sh"; source "$ZF_ENGINE_DIR/coord.sh"; "$@"' _ "$@"
}

clear_claim_fixtures() {
  local ref
  local -a claims=()
  mapfile -t claims < <(git --git-dir="$remote" for-each-ref --format='%(refname)' 'refs/claims/issue-*')
  for ref in "${claims[@]}"; do
    git --git-dir="$remote" update-ref -d "$ref"
  done
}

seed_remote_ref() {
  local ref="$1" file="$2" content="$3" blob tree commit
  blob="$(printf '%s\n' "$content" | git --git-dir="$remote" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\t%s\n' "$blob" "$file" | git --git-dir="$remote" mktree)"
  commit="$(GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture \
    GIT_COMMITTER_EMAIL=fixture@example.invalid git --git-dir="$remote" commit-tree "$tree" -m fixture)"
  git --git-dir="$remote" update-ref "$ref" "$commit"
}

run_ctl probe --host-id test-a
[[ -z "$(git --git-dir="$remote" for-each-ref refs/claims/)" ]] || {
  echo 'ctl.test.sh: probe ref was not deleted' >&2
  exit 1
}

run_ctl control set primary=test-a
run_coord test-a coord_acquire issue-1 owner-a scheduler-worker 1 issue-1 implement
if run_coord test-b coord_acquire issue-2 owner-b scheduler-worker 2 issue-2 implement; then
  echo 'ctl.test.sh: non-primary host acquired a claim' >&2
  exit 1
else
  rc=$?
  [[ "$rc" -eq 1 ]] || { echo "ctl.test.sh: primary gate returned $rc" >&2; exit 1; }
fi
run_ctl drain test-a
if run_coord test-a coord_acquire issue-3 owner-a scheduler-worker 3 issue-3 implement; then
  echo 'ctl.test.sh: draining host acquired a new claim' >&2
  exit 1
else
  rc=$?
  [[ "$rc" -eq 1 ]] || { echo "ctl.test.sh: drain gate returned $rc" >&2; exit 1; }
fi
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-1:claim.json)"
jq -e '.owner == "owner-a"' <<<"$claim" >/dev/null || {
  echo 'ctl.test.sh: drain interrupted a running claim' >&2
  exit 1
}
run_coord test-a coord_release issue-1 owner-a
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-1:claim.json)"
jq -e '.owner == null' <<<"$claim" >/dev/null || {
  echo 'ctl.test.sh: running claim was not released at stage end' >&2
  exit 1
}

run_ctl control set primary=
run_ctl control set drain=
cat >"$fixture/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
if [[ "${1:-}" == --user && "${2:-}" == list-units ]]; then
  cat "$ZF_COORD_TEST_ACTIVE_UNITS"
  exit 0
fi
if [[ "${1:-}" == --user && "${2:-}" == show && "${3:-}" == zenoforge-renewd.timer ]]; then
  printf '%s\n' "${ZF_COORD_TEST_TIMER_LOAD_STATE:-loaded}"
  exit 0
fi
printf '%s\n' "$*" >>"$ZF_COORD_SYSTEMCTL_LOG"
exit 0
SYSTEMCTL
chmod +x "$fixture/bin/systemctl"
cat >"$fixture/active-units" <<'UNITS'
zf-implement-123.service loaded active running worker
zf-advisor-456.service loaded active running worker
zf-health-check.service loaded active running worker
UNITS
cat >"$fixture/autopi/units.json" <<'JSON'
{"units":[{"id":"issue-123","issue":123,"stage":"implement"},{"id":"issue-456","issue":456,"stage":"advisor"},{"id":"issue-789","issue":789,"stage":"implement"}]}
JSON
worker_start="$(AGENT_HOME="$agent" ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" \
  bash -c 'source "$ZF_ENGINE_DIR/coord.sh"; coord_process_start_ticks "$1"' _ "$$")"
jq -cn --argjson pid "$$" --argjson pid_start "$worker_start" \
  '{workers:[{pid:$pid,pid_start:$pid_start,unit:"issue-789",type:"implement",issue:"789"}]}' \
  >"$fixture/autopi/workers.json"
missing_agent="$fixture/agent-missing-timer"
if AGENT_HOME="$missing_agent" ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" ZF_HOST_ID=test-a \
  MAC_AUTOPILOT_RUNTIME_DIR="$fixture/autopi" ZF_COORD_TEST_ACTIVE_UNITS="$fixture/active-units" \
  ZF_COORD_TEST_TIMER_LOAD_STATE=not-found ZF_COORD_SYSTEMCTL_LOG="$fixture/systemctl.log" PATH="$fixture/bin:$PATH" \
  bash "$engine/coord/ctl.sh" enable --host-id test-d; then
  echo 'ctl.test.sh: enable succeeded without the renewal timer' >&2
  exit 1
fi
[[ ! -e "$missing_agent/host.env" && ! -e "$missing_agent/timers.local.list" ]] || {
  echo 'ctl.test.sh: enable changed coordination settings without the renewal timer' >&2
  exit 1
}
AGENT_HOME="$agent" ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" ZF_HOST_ID=test-a \
  MAC_AUTOPILOT_RUNTIME_DIR="$fixture/autopi" ZF_COORD_TEST_ACTIVE_UNITS="$fixture/active-units" \
  PATH="$fixture/bin:$PATH" bash "$engine/coord/ctl.sh" adopt-local
for issue in 123 456; do
  claim="$(git --git-dir="$remote" cat-file blob "refs/claims/issue-$issue:claim.json")"
  jq -e --arg issue "$issue" '.owner_kind == "systemd-worker" and .subject == $issue' <<<"$claim" >/dev/null || {
    echo "ctl.test.sh: local unit issue-$issue was not adopted" >&2
    exit 1
  }
done
jq -e '.owner_kind == "scheduler-worker" and .unit == "issue-789"' \
  < <(git --git-dir="$remote" cat-file blob refs/claims/issue-789:claim.json) >/dev/null || {
  echo 'ctl.test.sh: unit-loop worker was not adopted' >&2
  exit 1
}
[[ -z "$(git --git-dir="$remote" for-each-ref refs/claims/issue-*)" ]] && {
  echo 'ctl.test.sh: no scheduler claims were adopted' >&2
  exit 1
}

seed_remote_ref refs/status/test-b worker.json '{"proto":1,"host":"test-b","instance":"test-instance","heartbeat_at":"2026-11-26T00:00:00Z","draining":false,"caps":{"os":"linux","arch":"x86_64","cpus":2,"mem_mb":1024,"cli":{"gh":"ok"}}}'
status="$(run_ctl status show)"
grep -q 'test-b' <<<"$status" || {
  echo 'ctl.test.sh: status show omitted a remote host' >&2
  exit 1
}

seed_remote_ref refs/claims/bad-json claim.json '{broken'
run_ctl claim clear bad-json
[[ -z "$(git --git-dir="$remote" for-each-ref refs/claims/bad-json)" ]] || {
  echo 'ctl.test.sh: claim clear left a malformed claim' >&2
  exit 1
}
future_expiry=$(( $(date +%s) + 600 ))
unsupported_claim="$(jq -cn --argjson expires "$future_expiry" \
  '{version:2,key:"issue-778",owner:"owner-future",owner_kind:"scheduler-worker",subject:"778",unit:"issue-778",stage:"implement",expires_at:$expires}')"
seed_remote_ref refs/claims/issue-778 claim.json "$unsupported_claim"
run_ctl claim clear issue-778
[[ -z "$(git --git-dir="$remote" for-each-ref refs/claims/issue-778)" ]] || {
  echo 'ctl.test.sh: claim clear left an unsupported claim' >&2
  exit 1
}
oversized_data="$(printf '%09000d' 0)"
oversized_claim="$(jq -cn --arg checkpoint "$oversized_data" --argjson expires "$future_expiry" \
  '{version:1,key:"issue-779",owner:"owner-large",owner_kind:"scheduler-worker",subject:"779",unit:"issue-779",stage:"implement",expires_at:$expires,checkpoint:$checkpoint}')"
seed_remote_ref refs/claims/issue-779 claim.json "$oversized_claim"
run_ctl claim clear issue-779
[[ -z "$(git --git-dir="$remote" for-each-ref refs/claims/issue-779)" ]] || {
  echo 'ctl.test.sh: claim clear left an oversized claim' >&2
  exit 1
}
seed_remote_ref refs/claims/issue-776 claim.json \
  '{"version":1,"key":"issue-776","owner":null,"owner_kind":"scheduler-worker","subject":"776","unit":"issue-776","stage":"implement","expires_at":0,"checkpoint":{"attempts":3}}'
if run_ctl claim clear issue-776; then
  echo 'ctl.test.sh: claim clear deleted a valid released claim' >&2
  exit 1
else
  rc=$?
  [[ "$rc" -eq 1 ]] || { echo "ctl.test.sh: valid claim clear returned $rc" >&2; exit 1; }
fi
[[ -n "$(git --git-dir="$remote" for-each-ref refs/claims/issue-776)" ]] || {
  echo 'ctl.test.sh: claim clear deleted valid checkpoint data' >&2
  exit 1
}
seed_remote_ref refs/claims/issue-777 claim.json '{"version":1,"key":"issue-777","owner":null,"owner_kind":"scheduler-worker","subject":"777","unit":"issue-777","stage":"release","expires_at":0,"effects":{"deploy:9":{"state":"unknown","class":"once"}}}'
run_ctl effect clear issue-777 deploy:9
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-777:claim.json)"
jq -e '.effects["deploy:9"].state == "cleared"' <<<"$claim" >/dev/null || {
  echo 'ctl.test.sh: effect clear did not record the operator decision' >&2
  exit 1
}

if run_ctl purge; then
  echo 'ctl.test.sh: purge removed live claims' >&2
  exit 1
else
  rc=$?
  [[ "$rc" -eq 1 ]] || { echo "ctl.test.sh: live-claim purge returned $rc" >&2; exit 1; }
fi
clear_claim_fixtures
run_ctl purge
printf '%s\n' custom.timer >"$agent/timers.local.list"
AGENT_HOME="$agent" ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" ZF_HOST_ID=test-a \
  MAC_AUTOPILOT_RUNTIME_DIR="$fixture/autopi" ZF_COORD_TEST_ACTIVE_UNITS="$fixture/active-units" \
  ZF_COORD_SYSTEMCTL_LOG="$fixture/systemctl.log" PATH="$fixture/bin:$PATH" \
  bash "$engine/coord/ctl.sh" enable --host-id test-c
grep -Fxq 'ZF_COORD=on' "$agent/host.env" || { echo 'ctl.test.sh: enable did not set coordination on' >&2; exit 1; }
grep -Fxq 'ZF_HOST_ID=test-c' "$agent/host.env" || { echo 'ctl.test.sh: enable did not set host id' >&2; exit 1; }
grep -Fxq custom.timer "$agent/timers.local.list" || { echo 'ctl.test.sh: enable dropped an existing timer' >&2; exit 1; }
grep -Fxq zenoforge-renewd.timer "$agent/timers.local.list" || { echo 'ctl.test.sh: enable omitted the renewal timer' >&2; exit 1; }
grep -Fxq -- '--user start zenoforge-renewd.timer' "$fixture/systemctl.log" || {
  echo 'ctl.test.sh: enable did not start the renewal timer' >&2
  exit 1
}
config="$(env -u ZF_COORD -u ZF_HOST_ID AGENT_HOME="$agent" ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$engine" \
  bash -c 'source "$ZF_ENGINE_DIR/config.sh"; printf "%s|%s" "$ZF_COORD" "$ZF_HOST_ID"')"
[[ "$config" == 'on|test-c' ]] || { echo "ctl.test.sh: persisted host config was not loaded: $config" >&2; exit 1; }
claim="$(git --git-dir="$remote" cat-file blob refs/claims/issue-123:claim.json)"
jq -e '.owner_kind == "systemd-worker"' <<<"$claim" >/dev/null || {
  echo 'ctl.test.sh: enable did not adopt local work' >&2
  exit 1
}

clear_claim_fixtures
run_ctl purge
[[ -z "$(git --git-dir="$remote" for-each-ref refs/claims refs/status refs/coord)" ]] || {
  echo 'ctl.test.sh: purge left coordination refs' >&2
  exit 1
}

echo 'ctl.test.sh: ok'
