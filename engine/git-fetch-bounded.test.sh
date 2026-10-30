set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GIT_FETCH_TEST_ROOT="$(mktemp -d)"
GIT_FETCH_TEST_REAL_GIT="$(command -v git)"
trap 'rm -rf -- "$test_env_root" "$GIT_FETCH_TEST_ROOT"' EXIT

failures=0
assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$want], got [$got])"
    failures=$((failures + 1))
  fi
}
assert_true() {
  local desc="$1"
  shift
  if "$@"; then
    echo "ok - $desc"
  else
    echo "not ok - $desc"
    failures=$((failures + 1))
  fi
}
inbox_has_record() {
  test -f "$1" && grep -Eq "$2" "$1"
}

source "$SCRIPT_DIR/lib.sh"
for transport_message in \
  'Proxy CONNECT aborted' \
  'CONNECT tunnel failed' \
  'GnuTLS, handshake failed: The TLS connection was non-properly terminated.' \
  'CONNECT tunnel failed, response 502' \
  'connection reset by peer' \
  'failed to refresh available models: request timed out' \
  'connection timed out' \
  'Operation timed out during push' \
  'error: RPC failed; curl 28 Operation too slow. Less than 1024 bytes/sec transferred the last 20 seconds'; do
  assert_true "real transport stderr: $transport_message" agent_transport_is_transient "$transport_message"
done
for refusal_message in 'fatal: Authentication failed' 'CONNECT tunnel failed, response 407'; do
  if agent_transport_is_transient "$refusal_message"; then transport_status=0; else transport_status=$?; fi
  assert_eq "authentication stderr is permanent: $refusal_message" 1 "$transport_status"
done


# Every timeout-wrapped network git operation must escalate after ten seconds.
git_timeout_calls="$(grep -nE '(^|[[:space:];!($])timeout .*git (fetch|clone|ls-remote|push|pull)|(^|[[:space:];!($])timeout .*git -C .* (fetch|clone|ls-remote|push|pull)' \
  "$SCRIPT_DIR/lib.sh" "$SCRIPT_DIR/night/node-health.sh" \
  "$SCRIPT_DIR/supervise-pipeline.sh" "$SCRIPT_DIR/worktree-lifecycle.sh" \
  "$SCRIPT_DIR/run-tick.sh" || true)"
git_timeout_misses="$(printf '%s\n' "$git_timeout_calls" | awk 'NF && $0 !~ /timeout -k 10 /')"
assert_eq 'all bounded network git calls escalate after ten seconds' '' "$git_timeout_misses"

# Real local origins prove narrow fetch still refreshes main, open PR and rescued work.
narrow_origin="$GIT_FETCH_TEST_ROOT/narrow-origin"
narrow_client="$GIT_FETCH_TEST_ROOT/narrow-client"
git init -q -b main "$narrow_origin"
git -C "$narrow_origin" config user.name fixture
git -C "$narrow_origin" config user.email fixture@example.invalid
printf 'seed\n' > "$narrow_origin/seed"
git -C "$narrow_origin" add seed
git -C "$narrow_origin" commit -qm seed
for ref in agent/issue-123 rescued/work-issue-123 rescued/work-issue-1234 unrelated; do
  git -C "$narrow_origin" branch "$ref"
done
git -C "$narrow_origin" tag unrelated-tag
git init -q "$narrow_client"
git -C "$narrow_client" remote add origin "$narrow_origin"
git_fetch_bounded "$narrow_client"
assert_eq 'omitted refs fetch main only' 'refs/remotes/origin/main' "$(git -C "$narrow_client" for-each-ref --format='%(refname)')"
printf 'new-main\n' >> "$narrow_origin/seed"
git -C "$narrow_origin" commit -qam new-main
git_fetch_hand_bounded "$narrow_client" 123 agent/issue-123
assert_eq 'hand refreshes current main' "$(git -C "$narrow_origin" rev-parse main)" "$(git -C "$narrow_client" rev-parse origin/main)"
assert_eq 'hand fetches only needed branches, no tags or sibling ticket' $'refs/remotes/origin/agent/issue-123\nrefs/remotes/origin/main\nrefs/remotes/origin/rescued/work-issue-123' "$(git -C "$narrow_client" for-each-ref --format='%(refname)')"
if git_fetch_hand_bounded "$narrow_client" 123 missing-open-pr >/dev/null 2>&1; then missing_ref_status=0; else missing_ref_status=$?; fi
assert_true 'missing open PR branch fails closed' test "$missing_ref_status" -ne 0

# Fake fetch reports the exact lock path in git's normal diagnostic. Other git
# commands delegate to real git so the helper resolves the fixture git dir.
GIT_FETCH_TEST_BIN="$GIT_FETCH_TEST_ROOT/bin"
GIT_FETCH_TEST_REPO="$GIT_FETCH_TEST_ROOT/repo"
GIT_FETCH_TEST_CALLS="$GIT_FETCH_TEST_ROOT/calls"
GIT_FETCH_TEST_LOCK="$GIT_FETCH_TEST_REPO/.git/refs/remotes/origin/main.lock"
GIT_FETCH_TEST_FETCH_HEAD_LOCK="$GIT_FETCH_TEST_REPO/.git/FETCH_HEAD.lock"
GIT_FETCH_TEST_OUTSIDE_LOCK="$GIT_FETCH_TEST_ROOT/outside.lock"
mkdir -p "$GIT_FETCH_TEST_BIN" "$GIT_FETCH_TEST_REPO" "$AGENT_HOME"
git -C "$GIT_FETCH_TEST_REPO" init -q
cat > "$GIT_FETCH_TEST_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -u
is_fetch=0
for arg in "$@"; do
  [ "$arg" = fetch ] && is_fetch=1
done
if [ "$is_fetch" = 1 ]; then
  count="$(cat "$GIT_FETCH_TEST_CALLS" 2>/dev/null || printf '0')"
  count=$((count + 1))
  printf '%s\n' "$count" > "$GIT_FETCH_TEST_CALLS"
  if [ "$GIT_FETCH_TEST_MODE" = timeout ]; then
    trap '' TERM
    printf '%s\n' '17:00:00.000000 run-command.c:1 | d1 | main | region_enter | r1 | 0.4 | | index-pack | label:fetch-pack/index-pack' \
      >> "${GIT_TRACE2_PERF:-/dev/null}"
    sleep 60 & wait "$!"
  fi
  if [ "$GIT_FETCH_TEST_MODE" = transient-once ] && [ "$count" = 1 ]; then
    echo "fatal: unable to access 'https://github.com/example/repo.git/': CONNECT tunnel failed, response 502" >&2
    exit 128
  fi
  if [ "$GIT_FETCH_TEST_MODE" = transient-always ]; then
    echo "fatal: unable to access 'https://github.com/example/repo.git/': CONNECT tunnel failed, response 502" >&2
    exit 128
  fi
  if [[ "$GIT_FETCH_TEST_MODE" == ref-race-always ||
    ("$GIT_FETCH_TEST_MODE" == ref-race-once && "$count" == 1) ]]; then
    echo 'error: cannot lock ref refs/remotes/origin/main: is at 46a363ccae108d4221237d579524b96be29cd737 but expected cc0b20f4174a45484926638357ea145690bf9bc2' >&2
    exit 1
  fi
  if [ "$GIT_FETCH_TEST_MODE" = rejected ]; then
    echo "fatal: Authentication failed for 'https://github.com/example/repo.git/'" >&2
    exit 128
  fi
  if [[ "$GIT_FETCH_TEST_MODE" == stale && "$count" == 1 ]] || \
    [[ "$GIT_FETCH_TEST_MODE" =~ ^(fresh|outside|fetch-head-lock)$ ]]; then
    lock="$GIT_FETCH_TEST_LOCK"
    [ "$GIT_FETCH_TEST_MODE" = outside ] && lock="$GIT_FETCH_TEST_OUTSIDE_LOCK"
    if [ "$GIT_FETCH_TEST_MODE" = fetch-head-lock ]; then
      lock="$GIT_FETCH_TEST_FETCH_HEAD_LOCK"
      printf "fatal: Unable to create '%s': File exists.\n" "$lock" >&2
    else
      printf "fatal: cannot lock ref 'refs/remotes/origin/main': Unable to create '%s': File exists.\n" "$lock" >&2
    fi
    exit 1
  fi
  exit 0
fi
exec "$GIT_FETCH_TEST_REAL_GIT" "$@"
EOF
chmod +x "$GIT_FETCH_TEST_BIN/git"
export GIT_FETCH_TEST_REAL_GIT GIT_FETCH_TEST_CALLS GIT_FETCH_TEST_LOCK GIT_FETCH_TEST_FETCH_HEAD_LOCK GIT_FETCH_TEST_OUTSIDE_LOCK
PATH="$GIT_FETCH_TEST_BIN:$PATH"
export PATH GIT_FETCH_TEST_MODE
mkdir -p "$(dirname -- "$GIT_FETCH_TEST_LOCK")"

GIT_FETCH_TEST_MODE=stale
printf 'stale lock\n' > "$GIT_FETCH_TEST_LOCK"
touch -d '3 minutes ago' "$GIT_FETCH_TEST_LOCK"
rm -f "$GIT_FETCH_TEST_CALLS"
if git_fetch_bounded "$GIT_FETCH_TEST_REPO" main >/dev/null 2>"$GIT_FETCH_TEST_ROOT/stale.err"; then
  stale_status=0
else
  stale_status=$?
fi
assert_eq 'stale named ref lock lets fetch recover' 0 "$stale_status"
assert_true 'stale named ref lock is removed' test ! -e "$GIT_FETCH_TEST_LOCK"
assert_eq 'stale-lock recovery retries fetch once' 2 "$(cat "$GIT_FETCH_TEST_CALLS")"
assert_true 'stale-lock removal is recorded in supervisor inbox' \
  inbox_has_record "$AGENT_HOME/supervisor-inbox" \
    "stale-git-lock path=$GIT_FETCH_TEST_LOCK age=[0-9]+$"

GIT_FETCH_TEST_MODE=transient-once
rm -f "$GIT_FETCH_TEST_CALLS"
if git_fetch_bounded "$GIT_FETCH_TEST_REPO" main >/dev/null 2>"$GIT_FETCH_TEST_ROOT/transient-once.err"; then
  transient_once_status=0
else
  transient_once_status=$?
fi
assert_eq 'transient 502 fetch recovers on retry' 0 "$transient_once_status"
assert_eq 'transient 502 fetch retries once before success' 2 "$(cat "$GIT_FETCH_TEST_CALLS")"
assert_true 'transient fetch reports backoff' grep -Fq 'retrying in 1s' "$GIT_FETCH_TEST_ROOT/transient-once.err"

GIT_FETCH_TEST_MODE=ref-race-once
rm -f "$GIT_FETCH_TEST_CALLS"
if git_fetch_bounded "$GIT_FETCH_TEST_REPO" main >/dev/null 2>"$GIT_FETCH_TEST_ROOT/ref-race-once.err"; then
  ref_race_once_status=0
else
  ref_race_once_status=$?
fi
assert_eq 'concurrent ref update recovers on retry' 0 "$ref_race_once_status"
assert_eq 'concurrent ref update retries once before success' 2 "$(cat "$GIT_FETCH_TEST_CALLS")"
assert_true 'ref-update race reports backoff' grep -Fq 'retrying in 1s' "$GIT_FETCH_TEST_ROOT/ref-race-once.err"

GIT_FETCH_TEST_MODE=transient-always
rm -f "$GIT_FETCH_TEST_CALLS"
if git_fetch_bounded "$GIT_FETCH_TEST_REPO" main >/dev/null 2>"$GIT_FETCH_TEST_ROOT/transient-always.err"; then
  transient_always_status=0
else
  transient_always_status=$?
fi
assert_eq 'persistent transient fetch still fails closed' 128 "$transient_always_status"
assert_eq 'persistent transient fetch is bounded to three attempts' 3 "$(cat "$GIT_FETCH_TEST_CALLS")"
assert_eq 'persistent transient fetch is marked for cross-tick deferral' 1 "$GIT_FETCH_LAST_TRANSIENT"
assert_true 'last fetch stderr remains available to dispatch fallback' \
  grep -Fq 'response 502' <<< "$GIT_FETCH_LAST_STDERR"

GIT_FETCH_TEST_MODE=transient-always
rm -f "$GIT_FETCH_TEST_CALLS"
if ZF_GIT_FETCH_TRANSIENT_RETRIES=1 git_fetch_bounded "$GIT_FETCH_TEST_REPO" main >/dev/null 2>"$GIT_FETCH_TEST_ROOT/transient-once-only.err"; then
  transient_once_only_status=0
else
  transient_once_only_status=$?
fi
assert_eq 'one-retry consumers fail closed after the second transient failure' 128 "$transient_once_only_status"
assert_eq 'one-retry consumers make exactly two fetch attempts' 2 "$(cat "$GIT_FETCH_TEST_CALLS")"

GIT_FETCH_TEST_MODE=ref-race-always
rm -f "$GIT_FETCH_TEST_CALLS"
if ZF_GIT_FETCH_TRANSIENT_RETRIES=1 git_fetch_bounded "$GIT_FETCH_TEST_REPO" main >/dev/null 2>"$GIT_FETCH_TEST_ROOT/ref-race-always.err"; then
  ref_race_always_status=0
else
  ref_race_always_status=$?
fi
assert_eq 'persistent ref-update race remains failed at helper boundary' 1 "$ref_race_always_status"
assert_eq 'persistent ref-update race stays within configured retry count' 2 "$(cat "$GIT_FETCH_TEST_CALLS")"
assert_eq 'persistent ref-update race is marked for cross-tick deferral' 1 "$GIT_FETCH_LAST_TRANSIENT"
assert_true 'persistent ref-update diagnostic remains available to queue' \
  grep -Fq 'is at 46a363ccae108d4221237d579524b96be29cd737 but expected cc0b20f4174a45484926638357ea145690bf9bc2' <<< "$GIT_FETCH_LAST_STDERR"
assert_eq 'auth diagnostic is not a ref-update race' 1 "$(agent_ref_update_race_is_transient 'fatal: Authentication failed' && echo 0 || echo 1)"
assert_eq 'lane refusal is not a ref-update race' 1 "$(agent_ref_update_race_is_transient 'land-direct-main: preflight refused product lane' && echo 0 || echo 1)"
assert_eq 'write-guard refusal is not a ref-update race' 1 "$(agent_ref_update_race_is_transient 'write-guard: direct push refused' && echo 0 || echo 1)"
assert_eq 'rebase conflict is not a ref-update race' 1 "$(agent_ref_update_race_is_transient 'error: could not apply deadbeef during rebase' && echo 0 || echo 1)"

GIT_FETCH_TEST_MODE=rejected
rm -f "$GIT_FETCH_TEST_CALLS"
if git_fetch_bounded "$GIT_FETCH_TEST_REPO" main >/dev/null 2>"$GIT_FETCH_TEST_ROOT/rejected.err"; then
  rejected_status=0
else
  rejected_status=$?
fi
assert_eq 'auth failure is not retried' 128 "$rejected_status"
assert_eq 'auth failure performs one fetch' 1 "$(cat "$GIT_FETCH_TEST_CALLS")"

GIT_FETCH_TEST_MODE=fresh
printf 'fresh lock\n' > "$GIT_FETCH_TEST_LOCK"
rm -f "$GIT_FETCH_TEST_CALLS"
if ZF_GIT_FETCH_TRANSIENT_RETRIES=1 git_fetch_bounded "$GIT_FETCH_TEST_REPO" main >/dev/null 2>"$GIT_FETCH_TEST_ROOT/fresh.err"; then
  fresh_status=0
else
  fresh_status=$?
fi
assert_eq 'fresh named ref lock keeps fetch failing' 1 "$fresh_status"
assert_true 'fresh named ref lock is left alone' test -f "$GIT_FETCH_TEST_LOCK"
assert_eq 'fresh ref-lock contention gets one bounded retry' 2 "$(cat "$GIT_FETCH_TEST_CALLS")"
assert_eq 'fresh ref-lock contention is marked transient' 1 "$GIT_FETCH_LAST_TRANSIENT"

GIT_FETCH_TEST_MODE=fetch-head-lock
printf 'fresh FETCH_HEAD lock\n' > "$GIT_FETCH_TEST_FETCH_HEAD_LOCK"
rm -f "$GIT_FETCH_TEST_CALLS"
if ZF_GIT_FETCH_TRANSIENT_RETRIES=1 git_fetch_bounded "$GIT_FETCH_TEST_REPO" main >/dev/null 2>"$GIT_FETCH_TEST_ROOT/fetch-head-lock.err"; then
  fetch_head_lock_status=0
else
  fetch_head_lock_status=$?
fi
assert_eq 'FETCH_HEAD lock contention stays bounded' 1 "$fetch_head_lock_status"
assert_eq 'FETCH_HEAD lock contention gets one retry' 2 "$(cat "$GIT_FETCH_TEST_CALLS")"
assert_eq 'FETCH_HEAD lock contention is marked transient' 1 "$GIT_FETCH_LAST_TRANSIENT"
assert_true 'FETCH_HEAD diagnostic remains available to fallback' \
  grep -Fq 'FETCH_HEAD.lock' <<< "$GIT_FETCH_LAST_STDERR"
assert_true 'fresh FETCH_HEAD lock is left alone' test -f "$GIT_FETCH_TEST_FETCH_HEAD_LOCK"

GIT_FETCH_TEST_MODE=outside
printf 'outside lock\n' > "$GIT_FETCH_TEST_OUTSIDE_LOCK"
touch -d '3 minutes ago' "$GIT_FETCH_TEST_OUTSIDE_LOCK"
rm -f "$GIT_FETCH_TEST_CALLS"
if ZF_GIT_FETCH_TRANSIENT_RETRIES=0 git_fetch_bounded "$GIT_FETCH_TEST_REPO" main >/dev/null 2>"$GIT_FETCH_TEST_ROOT/outside.err"; then
  outside_status=0
else
  outside_status=$?
fi
assert_eq 'lock outside this repo does not recover fetch' 1 "$outside_status"
assert_true 'lock outside this repo is never removed' test -f "$GIT_FETCH_TEST_OUTSIDE_LOCK"
assert_eq 'outside lock failure cannot be recovered or removed' 1 "$(cat "$GIT_FETCH_TEST_CALLS")"

GIT_FETCH_TEST_MODE=timeout
rm -f "$GIT_FETCH_TEST_CALLS"
if timeout_result="$(GIT_FETCH_TEST_TIMEOUT_ERR="$GIT_FETCH_TEST_ROOT/timeout.err" python3 - "$SCRIPT_DIR" "$GIT_FETCH_TEST_REPO" <<'PY'
import os
import signal
import subprocess
import sys
import time

script_dir, repo = sys.argv[1:]
command = [
    "bash", "-c",
    'source "$1/lib.sh"; GIT_FETCH_TIMEOUT_SEC=1 git_fetch_bounded "$2" main',
    "_", script_dir, repo,
]
started = time.monotonic()
stderr_path = os.environ["GIT_FETCH_TEST_TIMEOUT_ERR"]
with open(stderr_path, "w") as stderr_file:
    proc = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=stderr_file, start_new_session=True)
# The fake git ignores SIGTERM and sleeps 60s, so a missing -k escalation
# takes ~60s. Escalation takes ~11.3s; 30s leaves room for a loaded host
# (11.5 failed a 2026-09-29 landing preflight at load ~15).
try:
    proc.wait(timeout=30)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    proc.wait()
    print("bounded git fetch exceeded timeout plus ten seconds")
    sys.exit(1)
elapsed = time.monotonic() - started
if proc.returncode != 124 or elapsed > 30:
    print(f"bounded git fetch returned status={proc.returncode} elapsed={elapsed:.2f}s")
    sys.exit(1)
print(f"bounded git fetch returned status={proc.returncode} elapsed={elapsed:.2f}s")
PY
)"; then
  timeout_status=0
else
  timeout_status=$?
fi
assert_eq 'SIGTERM-ignoring git fetch retries once and returns within two timeout windows' 0 "$timeout_status"
assert_true 'timeout regression output reports elapsed time' grep -Fq 'bounded git fetch returned status=' <<< "$timeout_result"
assert_eq 'timed-out fetch retries once at shared helper' 2 "$(cat "$GIT_FETCH_TEST_CALLS")"
assert_true 'a timed-out fetch names the phase it was in' \
  grep -Fq 'label:fetch-pack/index-pack' "$GIT_FETCH_TEST_ROOT/timeout.err"
printf '%s\n' "$timeout_result"

if [ "$failures" -gt 0 ]; then
  echo "FAILED ($failures assertions)"
  exit 1
fi
echo 'ALL PASS'
