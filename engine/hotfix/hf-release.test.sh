#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
p=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
real_git=$(command -v git)
sha=0123456789abcdef0123456789abcdef01234567
mkdir -p "$tmp/bin"

cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ -z ${GH_TOKEN+x} ]]
case "$1 $2" in
  'pr view')
    if [[ "$*" == *'--json state,mergeCommit'* ]]; then
      jq -cn --arg sha "$HF_RELEASE_TEST_SHA" '{state:"MERGED",mergeCommit:{oid:$sha}}'
    elif [[ "$*" == *'--json mergeCommit'* ]]; then
      printf '%s\n' "$HF_RELEASE_TEST_SHA"
    else
      exit 1
    fi
    ;;
  'run list')
    jq -cn --arg sha "$HF_RELEASE_TEST_SHA" '[{databaseId:1,headSha:$sha,conclusion:"success",status:"completed",event:"push",workflowName:"CI"}]'
    ;;
  'run view')
    printf '%s\n' '{"jobs":[{"name":"Postsubmit validate","status":"completed","conclusion":"success"}]}'
    ;;
  *) exit 1 ;;
esac
SH
cat > "$tmp/bin/git" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == fetch && "$*" == 'fetch -q origin main' ]]; then exit 0; fi
if [[ "$1" == merge-base && "$2" == --is-ancestor ]]; then exit 0; fi
exec "$HF_RELEASE_TEST_REAL_GIT" "$@"
SH
cat > "$tmp/bin/systemctl" <<'SH'
#!/usr/bin/env bash
[[ "$*" == *list-units* ]] || exit 0
pattern="${@: -1}"
printf 'prefix=%s pattern=%s\n' "${ZF_UNIT_PREFIX-UNSET}" "$pattern" >> "$HF_RELEASE_SYSTEMCTL_LOG"
[[ "$pattern" == '*-release-*' ]] || exit 0
n=$(cat "$HF_RELEASE_SYSTEMCTL_COUNT")
n=$((n + 1))
printf '%s\n' "$n" > "$HF_RELEASE_SYSTEMCTL_COUNT"
case "$HF_RELEASE_SYSTEMCTL_MODE" in
  active-two) ;;
  active-always) ;;
  empty) exit 0 ;;
  *) exit 1 ;;
esac
# systemctl's table output has leading padding; hf-release must parse the unit name,
# and ignore its own detached gate unit while waiting for the shared batch.
printf '  vecta-hf-release-7463.service loaded active running hotfix gate\n'
if [[ "$HF_RELEASE_SYSTEMCTL_MODE" == active-always || ( "$HF_RELEASE_SYSTEMCTL_MODE" == active-two && $n -le 2 ) ]]; then
  printf '  vecta-release-batch.service loaded active running factory release\n'
fi
SH
cat > "$tmp/bin/systemd-run" <<'SH'
#!/usr/bin/env bash
n=$(cat "$HF_RELEASE_SYSTEMD_RUN_COUNT")
n=$((n + 1))
printf '%s\n' "$n" > "$HF_RELEASE_SYSTEMD_RUN_COUNT"
printf '%s\n' "$*" >> "$HF_RELEASE_SYSTEMD_RUN_LOG"
case "$HF_RELEASE_SYSTEMD_RUN_MODE:$n" in
  loaded-once:1)
    echo 'Failed to start transient service unit: Unit vecta-release-batch.service was already loaded' >&2
    exit 1
    ;;
  fail:*) echo 'systemd-run failed for an unrelated reason' >&2; exit 7 ;;
  *) exit 0 ;;
esac
SH
cat > "$tmp/bin/sleep" <<'SH'
#!/usr/bin/env bash
case "${HF_RELEASE_TEST_SLEEP:-instant}" in
  instant) exit 0 ;;
  short) exec /usr/bin/sleep 0.1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/gh" "$tmp/bin/git" "$tmp/bin/systemctl" "$tmp/bin/systemd-run" "$tmp/bin/sleep"

export PATH="$tmp/bin:$PATH" HF_RELEASE_TEST_SHA="$sha" HF_RELEASE_TEST_REAL_GIT="$real_git"
export HF_RELEASE_SYSTEMCTL_LOG="$tmp/systemctl.log" HF_RELEASE_SYSTEMCTL_COUNT="$tmp/systemctl.count"
export HF_RELEASE_SYSTEMD_RUN_LOG="$tmp/systemd-run.log" HF_RELEASE_SYSTEMD_RUN_COUNT="$tmp/systemd-run.count"
reset_case() {
  : > "$HF_RELEASE_SYSTEMCTL_LOG"
  : > "$HF_RELEASE_SYSTEMD_RUN_LOG"
  printf '0\n' > "$HF_RELEASE_SYSTEMCTL_COUNT"
  printf '0\n' > "$HF_RELEASE_SYSTEMD_RUN_COUNT"
  : > "$AGENT_HOME/supervisor-inbox"
}
run_release() {
  local expected="$1" rc=0
  shift
  env -u ZF_UNIT_PREFIX "$@" "$p/hf-release.sh" 7463 3163 > "$tmp/output" 2>&1 || rc=$?
  [[ "$rc" == "$expected" ]] || { cat "$tmp/output" >&2; fail "hf-release exit was $rc; expected $expected"; }
}

rc=0; "$p/hf-release.sh" 1 || rc=$?
[[ "$rc" == 2 ]] || fail "usage failure exit was $rc; expected 2"

# The caller has no ZF_UNIT_PREFIX. The host's VectA batch appears in a padded
# systemctl row for two polls; the detached hf-release gate is not a blocker.
reset_case
run_release 0 HF_RELEASE_BATCH_WAIT_SECONDS=2 HF_RELEASE_TEST_SLEEP=instant \
  HF_RELEASE_SYSTEMCTL_MODE=active-two HF_RELEASE_SYSTEMD_RUN_MODE=success
[[ "$(cat "$HF_RELEASE_SYSTEMCTL_COUNT")" == 3 ]] || fail 'hf-release did not wait through two active-batch polls'
grep -Fq 'prefix=UNSET pattern=*-release-*' "$HF_RELEASE_SYSTEMCTL_LOG" || fail 'caller without ZF_UNIT_PREFIX did not query host release units'
grep -Fq 'waiting for release unit(s): vecta-release-batch.service' "$tmp/output" || fail 'wait log did not name the active batch unit'
[[ "$(cat "$HF_RELEASE_SYSTEMD_RUN_COUNT")" == 1 ]] || fail 'hf-release did not start once after the batch freed'

# The shared-unit reservation can race after the active-unit query. Retry the
# one "already loaded" response and succeed when systemd releases it.
reset_case
run_release 0 HF_RELEASE_BATCH_WAIT_SECONDS=2 HF_RELEASE_TEST_SLEEP=instant \
  HF_RELEASE_SYSTEMCTL_MODE=empty HF_RELEASE_SYSTEMD_RUN_MODE=loaded-once
[[ "$(cat "$HF_RELEASE_SYSTEMD_RUN_COUNT")" == 2 ]] || fail 'already-loaded systemd-run result was not retried once'

# A batch that remains active through the short budget must fail and notify the supervisor.
reset_case
run_release 1 HF_RELEASE_BATCH_WAIT_SECONDS=1 HF_RELEASE_TEST_SLEEP=short \
  HF_RELEASE_SYSTEMCTL_MODE=active-always HF_RELEASE_SYSTEMD_RUN_MODE=success
grep -Fq 'reason=release-batch-wait-timeout' "$AGENT_HOME/supervisor-inbox" || {
  cat "$tmp/output" >&2
  cat "$AGENT_HOME/supervisor-inbox" >&2
  fail 'batch timeout did not write its supervisor inbox line'
}
grep -Fq 'vecta-release-batch.service' "$AGENT_HOME/supervisor-inbox" || fail 'batch timeout inbox line did not name the active unit'
[[ "$(cat "$HF_RELEASE_SYSTEMD_RUN_COUNT")" == 0 ]] || fail 'hf-release attempted to start while a release batch stayed active'

# Other start errors remain failures rather than being converted to a successful echo.
reset_case
run_release 1 HF_RELEASE_BATCH_WAIT_SECONDS=2 HF_RELEASE_TEST_SLEEP=instant \
  HF_RELEASE_SYSTEMCTL_MODE=empty HF_RELEASE_SYSTEMD_RUN_MODE=fail

echo 'PASS hf-release waits for release units, retries an already-loaded start, and fails with an inbox notice on timeout'
