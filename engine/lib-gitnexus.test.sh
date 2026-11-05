#!/usr/bin/env bash
# GitNexus refresh behavior, separated to keep the library suites bounded.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-lib-helpers.sh"
# --- GitNexus refresh: WSL memory floor, remote refresh and latest-wins throttle --
GITNEXUS_TEST_ORIGINAL_AGENT_HOME="$AGENT_HOME"
GITNEXUS_TEST_ORIGINAL_PATH="$PATH"
GITNEXUS_TEST_ORIGINAL_WAIT="$GITNEXUS_REFRESH_LOCK_WAIT_SECONDS"
GITNEXUS_TEST_ORIGINAL_MIN_INTERVAL="$GITNEXUS_REFRESH_MIN_INTERVAL_SECONDS"
GITNEXUS_TEST_ROOT="$(mktemp -d)"
GITNEXUS_TEST_BIN="$GITNEXUS_TEST_ROOT/bin"
GITNEXUS_TEST_REPO="$GITNEXUS_TEST_ROOT/repo"
GITNEXUS_REAL_FLOCK="$(command -v flock)"
mkdir -p "$GITNEXUS_TEST_BIN" "$GITNEXUS_TEST_REPO"
git -C "$GITNEXUS_TEST_REPO" init -q -b main
git -C "$GITNEXUS_TEST_REPO" config user.email lib-test@example.com
git -C "$GITNEXUS_TEST_REPO" config user.name lib-test
printf 'fixture\n' > "$GITNEXUS_TEST_REPO/tracked"
git -C "$GITNEXUS_TEST_REPO" add tracked
git -C "$GITNEXUS_TEST_REPO" commit -qm baseline
mkdir -p "$GITNEXUS_TEST_REPO/.gitnexus"
GITNEXUS_FAILED_SHA="$(git -C "$GITNEXUS_TEST_REPO" rev-parse HEAD)"
cat > "$GITNEXUS_TEST_BIN/gitnexus-cihost-index" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  refresh)
    repo="$2"
    sha="$3"
    printf '%s\t%s\n' "$repo" "$sha" >> "$FAKE_GITNEXUS_LOG"
    if [ "${FAKE_GITNEXUS_EXIT_3:-0}" = "1" ]; then
      echo "simulated remote refresh failure"
      exit 3
    fi
    if [ "${FAKE_GITNEXUS_EMPTY_FAIL:-0}" != "0" ]; then
      exit "$FAKE_GITNEXUS_EMPTY_FAIL"
    fi
    touch "$FAKE_GITNEXUS_STARTED"
    if [ "${FAKE_GITNEXUS_WAIT:-0}" = "1" ]; then
      # Bounded (60 s), like run-advisor.test.sh's release wait: an unbounded one outlived cancelled CI jobs.
      for _ in $(seq 1 6000); do [ -f "$FAKE_GITNEXUS_RELEASE" ] && break; sleep 0.01; done
      [ -f "$FAKE_GITNEXUS_RELEASE" ] || exit 124
    elif [ "${FAKE_GITNEXUS_MEM_DROP:-0}" = "1" ]; then
      sleep 1.2
    else
      sleep 0.3
    fi
    if [ "${FAKE_GITNEXUS_FAIL:-0}" = "1" ]; then
      echo "simulated remote refresh failure"
      exit 1
    fi
    printf '{"lastCommit":"%s","indexedAt":"%s"}\n' "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$repo/.gitnexus/meta.json"
    echo "remote refresh complete"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$GITNEXUS_TEST_BIN/gitnexus-cihost-index"
cat > "$GITNEXUS_TEST_BIN/flock" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_FLOCK_WAIT_STARTED:-}" ] && [ "$1" = "-w" ]; then
  touch "$FAKE_FLOCK_WAIT_STARTED"
fi
exec "$GITNEXUS_REAL_FLOCK" "$@"
EOF
chmod +x "$GITNEXUS_TEST_BIN/flock"
GITNEXUS_REFRESH_MIN_AVAILABLE_KB="$(gitnexus_refresh_minimum_available_kb)"
PATH="$GITNEXUS_TEST_BIN:$PATH"
GITNEXUS_CIHOST_INDEX_SCRIPT="$GITNEXUS_TEST_BIN/gitnexus-cihost-index"
AGENT_HOME="$GITNEXUS_TEST_ROOT/home"
mkdir -p "$AGENT_HOME"
GITNEXUS_REFRESH_LOCK_WAIT_SECONDS=1
gitnexus_test_index_matches_commit() {
  local repo_dir="$1" expected_sha="$2" indexed
  [ -n "$expected_sha" ] && [ "$expected_sha" != "unknown" ] || return 1
  indexed="$(jq -r '.lastCommit // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null)" || return 1
  [ -n "$indexed" ] && [ "$indexed" = "$expected_sha" ]
}
export -f gitnexus_test_index_matches_commit
gitnexus_available_memory_kb() {
  if [ "${FAKE_GITNEXUS_MEM_DROP:-0}" = "1" ] && [ -e "$FAKE_GITNEXUS_STARTED" ]; then
    printf '%s\n' "$((GITNEXUS_REFRESH_MIN_AVAILABLE_KB - 1))"
  else
    printf '%s\n' "$FAKE_GITNEXUS_MEM_AVAILABLE_KB"
  fi
}
FAKE_GITNEXUS_LOG="$GITNEXUS_TEST_ROOT/analyze.calls"
FAKE_GITNEXUS_STARTED="$GITNEXUS_TEST_ROOT/analyze.started"
FAKE_GITNEXUS_REPO="$GITNEXUS_TEST_REPO"
FAKE_GITNEXUS_SHA="$GITNEXUS_FAILED_SHA"
FAKE_GITNEXUS_FAIL=1
FAKE_GITNEXUS_WAIT=0
FAKE_GITNEXUS_EXIT_3=0
FAKE_GITNEXUS_MEM_DROP=0
FAKE_GITNEXUS_EMPTY_FAIL=0
FAKE_GITNEXUS_MEM_AVAILABLE_KB=$((GITNEXUS_REFRESH_MIN_AVAILABLE_KB + 100000))
FAKE_GITNEXUS_RELEASE="$GITNEXUS_TEST_ROOT/analyze.release"
: > "$FAKE_GITNEXUS_LOG"
export PATH AGENT_HOME GITNEXUS_CIHOST_INDEX_SCRIPT FAKE_GITNEXUS_LOG FAKE_GITNEXUS_STARTED FAKE_GITNEXUS_REPO FAKE_GITNEXUS_SHA FAKE_GITNEXUS_FAIL FAKE_GITNEXUS_WAIT FAKE_GITNEXUS_EXIT_3 FAKE_GITNEXUS_EMPTY_FAIL FAKE_GITNEXUS_MEM_DROP FAKE_GITNEXUS_MEM_AVAILABLE_KB FAKE_GITNEXUS_RELEASE GITNEXUS_REAL_FLOCK
FAKE_GITNEXUS_MEM_AVAILABLE_KB=1500000
if gitnexus_refresh_index_once "$GITNEXUS_TEST_REPO" "$GITNEXUS_FAILED_SHA" gitnexus_test_index_matches_commit; then
  GITNEXUS_LOW_MEMORY_STATUS=0
else
  GITNEXUS_LOW_MEMORY_STATUS=$?
fi
assert_eq "below 3 GiB MemAvailable defers as stale-index status" "1" "$GITNEXUS_LOW_MEMORY_STATUS"
assert_contains "low-memory result names the 3 GiB floor" "$GITNEXUS_REFRESH_OUTPUT" "< 3072MB"
assert_eq "low memory does not start a remote refresh" "0" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"
assert_false "low memory does not consume the checkout SHA attempt" test -e "$AGENT_HOME/gitnexus-analyze-attempt"
assert_false "low memory does not start the refresh throttle" test -e "$AGENT_HOME/gitnexus-analyze-last-start"

FAKE_GITNEXUS_MEM_AVAILABLE_KB=$((GITNEXUS_REFRESH_MIN_AVAILABLE_KB + 100000))
FAKE_GITNEXUS_EXIT_3=1
if gitnexus_refresh_index_once "$GITNEXUS_TEST_REPO" "$GITNEXUS_FAILED_SHA" gitnexus_test_index_matches_commit; then
  GITNEXUS_WRAPPER_REFUSAL_STATUS=0
else
  GITNEXUS_WRAPPER_REFUSAL_STATUS=$?
fi
assert_eq "remote exit 3 stays a stale-index result" "1" "$GITNEXUS_WRAPPER_REFUSAL_STATUS"
assert_contains "remote exit 3 remains a non-fatal refresh failure" "$GITNEXUS_REFRESH_OUTPUT" "simulated remote refresh failure"
assert_eq "remote failure is recorded as one refresh attempt" "1" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"
rm -f "$AGENT_HOME/gitnexus-analyze-attempt" "$AGENT_HOME/gitnexus-analyze-last-start"
FAKE_GITNEXUS_EXIT_3=0

if gitnexus_refresh_index_once "$GITNEXUS_TEST_REPO" "$GITNEXUS_FAILED_SHA" gitnexus_test_index_matches_commit; then
  GITNEXUS_FAILED_REFRESH_STATUS=0
else
  GITNEXUS_FAILED_REFRESH_STATUS=$?
fi
assert_eq "a failed remote refresh stays a non-fatal stale-index result" "1" "$GITNEXUS_FAILED_REFRESH_STATUS"
assert_eq "first stale SHA starts one remote refresh" "2" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"
assert_false "same stale SHA does not start a second refresh inside the throttle" \
  gitnexus_refresh_index_once "$GITNEXUS_TEST_REPO" "$GITNEXUS_FAILED_SHA" gitnexus_test_index_matches_commit
assert_contains "repeat call reports the throttle" "$GITNEXUS_REFRESH_OUTPUT" "latest-wins throttle"
assert_eq "failed SHA remains at one refresh attempt" "2" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"
assert_false "triage and advisor cannot retry one checkout SHA under different freshness expectations" \
  gitnexus_refresh_index_once "$GITNEXUS_TEST_REPO" different-index-target gitnexus_test_index_matches_commit
assert_eq "same checkout SHA still starts only one refresh" "2" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"

FAKE_GITNEXUS_FAIL=0
git -C "$GITNEXUS_TEST_REPO" commit --allow-empty -qm 'new checkout SHA'
GITNEXUS_SUCCESS_SHA="$(git -C "$GITNEXUS_TEST_REPO" rev-parse HEAD)"
FAKE_GITNEXUS_SHA="$GITNEXUS_SUCCESS_SHA"
git -C "$GITNEXUS_TEST_REPO" update-ref refs/remotes/origin/main "$GITNEXUS_SUCCESS_SHA"
if gitnexus_refresh_index_once "$GITNEXUS_TEST_REPO" "$GITNEXUS_SUCCESS_SHA" gitnexus_test_index_matches_commit; then
  GITNEXUS_SUCCESSFUL_REFRESH_STATUS=0
else
  GITNEXUS_SUCCESSFUL_REFRESH_STATUS=$?
fi
assert_eq "new SHA is deferred while the shared refresh window is active" "1" "$GITNEXUS_SUCCESSFUL_REFRESH_STATUS"
assert_contains "deferred refresh names the latest-wins throttle" "$GITNEXUS_REFRESH_OUTPUT" "latest-wins throttle"
assert_eq "new SHA does not start a second refresh inside 30 minutes" "2" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"
assert_eq "throttled SHA does not replace the prior attempt marker" \
  "$GITNEXUS_TEST_REPO $GITNEXUS_FAILED_SHA" "$(cat "$AGENT_HOME/gitnexus-analyze-attempt")"
printf '1\n' > "$AGENT_HOME/gitnexus-analyze-last-start"
if gitnexus_refresh_index_once "$GITNEXUS_TEST_REPO" "$GITNEXUS_SUCCESS_SHA" gitnexus_test_index_matches_commit; then
  GITNEXUS_SUCCESSFUL_REFRESH_STATUS=0
else
  GITNEXUS_SUCCESSFUL_REFRESH_STATUS=$?
fi
assert_eq "a new checkout SHA permits one refresh and confirms its metadata" "0" "$GITNEXUS_SUCCESSFUL_REFRESH_STATUS"
assert_eq "latest SHA starts after the shared refresh window expires" "3" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"
assert_eq "new SHA is recorded by the remote refresh" "$GITNEXUS_SUCCESS_SHA" "$(jq -r '.lastCommit' "$GITNEXUS_TEST_REPO/.gitnexus/meta.json")"
assert_eq "sampled WSL MemAvailable stays above 3 GiB during remote refresh" \
  "1" "$(awk -F '\t' -v floor="$GITNEXUS_REFRESH_MIN_AVAILABLE_KB" '$1 == "run" && $7 == 0 && $6 >= floor { count++ } END { print count + 0 }' "$AGENT_HOME/night/gitnexus-analyze-memory.tsv")"
assert_eq "memory log marks only the confirmed refresh" \
  "1" "$(awk -F '\t' '$1 == "confirmed" { count++ } END { print count + 0 }' "$AGENT_HOME/night/gitnexus-analyze-memory.tsv")"
assert_true "confirmed refresh records the expected checkout SHA" \
  awk -F '\t' -v sha="$GITNEXUS_SUCCESS_SHA" \
    '$1 == "confirmed" && $4 == sha && $6 == sha { found=1 } END { exit !found }' \
    "$AGENT_HOME/night/gitnexus-analyze-memory.tsv"
assert_true "confirmed refresh records metadata age and commit lag" \
  awk -F '\t' -v sha="$GITNEXUS_SUCCESS_SHA" \
    '$1 == "confirmed" && $6 == sha && $7 ~ /^[0-9]+$/ && $7 <= 3600 && $8 == 0 && $9 == sha { found=1 } END { exit !found }' \
    "$AGENT_HOME/night/gitnexus-analyze-memory.tsv"
assert_eq "each GitNexus invocation leaves auditable start and completion records" \
  "6" "$(grep -cE '^(start|run)' "$AGENT_HOME/night/gitnexus-analyze-memory.tsv")"
cp "$GITNEXUS_TEST_REPO/.gitnexus/meta.json" "$GITNEXUS_TEST_ROOT/meta.before-low-memory.json"
FAKE_GITNEXUS_MEM_DROP=1
rm -f "$FAKE_GITNEXUS_STARTED"
git -C "$GITNEXUS_TEST_REPO" commit --allow-empty -qm 'memory dropped during remote refresh'
GITNEXUS_LOW_MEMORY_SHA="$(git -C "$GITNEXUS_TEST_REPO" rev-parse HEAD)"
FAKE_GITNEXUS_SHA="$GITNEXUS_LOW_MEMORY_SHA"
printf '1\n' > "$AGENT_HOME/gitnexus-analyze-last-start"
if gitnexus_refresh_index_once "$GITNEXUS_TEST_REPO" "$GITNEXUS_LOW_MEMORY_SHA" gitnexus_test_index_matches_commit; then
  GITNEXUS_LOW_MEMORY_STATUS=0
else
  GITNEXUS_LOW_MEMORY_STATUS=$?
fi
assert_eq "refresh is not confirmed when WSL memory falls below 3 GiB mid-run" "1" "$GITNEXUS_LOW_MEMORY_STATUS"
assert_contains "mid-run memory-floor failure is explicit" "$GITNEXUS_REFRESH_OUTPUT" "MemAvailable fell below 3072MB"
assert_eq "mid-run memory-floor failure is sampled in the run record" \
  "$((GITNEXUS_REFRESH_MIN_AVAILABLE_KB - 1))" \
  "$(awk -F '\t' '$1 == "run" { value=$6 } END { print value }' "$AGENT_HOME/night/gitnexus-analyze-memory.tsv")"
assert_eq "mid-run memory-floor failure does not append a confirmed record" \
  "1" "$(awk -F '\t' '$1 == "confirmed" { count++ } END { print count + 0 }' "$AGENT_HOME/night/gitnexus-analyze-memory.tsv")"
FAKE_GITNEXUS_MEM_DROP=0
# The low-memory case must not leak its extra commit or metadata into the origin/main freshness checks below.
git -C "$GITNEXUS_TEST_REPO" reset -q --hard "$GITNEXUS_SUCCESS_SHA"
cp "$GITNEXUS_TEST_ROOT/meta.before-low-memory.json" "$GITNEXUS_TEST_REPO/.gitnexus/meta.json"
FAKE_GITNEXUS_SHA="$GITNEXUS_SUCCESS_SHA"
FAKE_GITNEXUS_EMPTY_FAIL=43
FAKE_GITNEXUS_CREDENTIAL=do-not-log-test-fixture
export FAKE_GITNEXUS_CREDENTIAL
rm -f "$GITNEXUS_TEST_REPO/.gitnexus/meta.json"
rm -f "$AGENT_HOME/gitnexus-analyze-attempt" "$AGENT_HOME/gitnexus-analyze-last-start"
if gitnexus_refresh_index_once "$GITNEXUS_TEST_REPO" "$GITNEXUS_SUCCESS_SHA" gitnexus_test_index_matches_commit; then
  GITNEXUS_EMPTY_FAILURE_STATUS=0
else
  GITNEXUS_EMPTY_FAILURE_STATUS=$?
fi
assert_eq "empty remote failure remains a stale-index result" "1" "$GITNEXUS_EMPTY_FAILURE_STATUS"
assert_contains "empty remote failure reports refresh stage and exit code" \
  "$GITNEXUS_REFRESH_OUTPUT" "stage=remote-index-refresh exit=43"
assert_false "refresh diagnostics never copy credential environment values" \
  grep -qF "$FAKE_GITNEXUS_CREDENTIAL" <<<"$GITNEXUS_REFRESH_OUTPUT"
assert_eq "audit stores stage and exit code for empty-output failures" \
  "stage=remote-index-refresh exit=43" \
  "$(awk -F '\t' '$1 == "run" { detail=$10 } END { print detail }' "$AGENT_HOME/night/gitnexus-analyze-memory.tsv")"
cp "$GITNEXUS_TEST_ROOT/meta.before-low-memory.json" "$GITNEXUS_TEST_REPO/.gitnexus/meta.json"
FAKE_GITNEXUS_EMPTY_FAIL=0
unset FAKE_GITNEXUS_CREDENTIAL
GITNEXUS_HEALTH_LOG="$GITNEXUS_TEST_ROOT/health-memory.tsv"
printf 'run\tok\t1100\tsha-ok\t3145728\t3145728\t0\t0\trefresh-audit-v1\nconfirmed\tok\t1101\tsha-ok\nrun\tlate\t1990\tsha-late\t3145728\t3145728\t124\t0\trefresh-audit-v1\n' \
  > "$GITNEXUS_HEALTH_LOG"
assert_eq "HEALTH reports latest confirmed-refresh age and latest refresh exit independently" \
  "last-confirmed-age-sec=899 last-refresh-exit=124 refresh-samples=2/20 refresh-successes=0 refresh-rate=unknown refresh-target=95% refresh-memory-floor-violations=0" \
  "$(gitnexus_refresh_health_detail "$GITNEXUS_HEALTH_LOG" 2000)"
assert_eq "missing refresh history stays nonpaging and explicit" \
  "last-confirmed-age-sec=unknown last-refresh-exit=unknown refresh-samples=0/20 refresh-successes=0 refresh-rate=unknown refresh-target=95% refresh-memory-floor-violations=0" \
  "$(gitnexus_refresh_health_detail "$GITNEXUS_TEST_ROOT/no-history.tsv" 2000)"
write_gitnexus_refresh_window() {
  local path="$1" success_count="$2" low_memory_run="${3:-0}" i run_id analyzer_status minimum_kb
  : > "$path"
  for i in $(seq 1 20); do
    run_id="window-$i"
    analyzer_status=0
    minimum_kb="$GITNEXUS_REFRESH_MIN_AVAILABLE_KB"
    if (( i > success_count )); then analyzer_status=1; fi
    if (( i == low_memory_run )); then minimum_kb=$((GITNEXUS_REFRESH_MIN_AVAILABLE_KB - 1)); fi
    printf 'run\t%s\t%s\tsha-%s\t%s\t%s\t%s\t0\trefresh-audit-v1\n' \
      "$run_id" "$((1000 + i))" "$i" "$GITNEXUS_REFRESH_MIN_AVAILABLE_KB" \
      "$minimum_kb" "$analyzer_status" >> "$path"
    if (( analyzer_status == 0 )); then
      printf 'confirmed\t%s\t%s\tsha-%s\t2026-10-09T00:00:00Z\tsha-%s\t0\t0\tsha-%s\n' \
        "$run_id" "$((1000 + i))" "$i" "$i" "$i" >> "$path"
    fi
  done
}
write_gitnexus_refresh_window "$GITNEXUS_HEALTH_LOG" 19
if GITNEXUS_HEALTH_RATE_DETAIL="$(gitnexus_refresh_health_detail "$GITNEXUS_HEALTH_LOG" 2000)"; then
  GITNEXUS_HEALTH_RATE_STATUS=0
else
  GITNEXUS_HEALTH_RATE_STATUS=$?
fi
assert_eq "HEALTH accepts the exact 95% target after 20 refreshes" "0" "$GITNEXUS_HEALTH_RATE_STATUS"
assert_contains "HEALTH exposes rolling success rate after 20 refreshes" \
  "$GITNEXUS_HEALTH_RATE_DETAIL" \
  "refresh-samples=20/20 refresh-successes=19 refresh-rate=95% refresh-target=95% refresh-memory-floor-violations=0"
write_gitnexus_refresh_window "$GITNEXUS_HEALTH_LOG" 18
if GITNEXUS_HEALTH_RATE_DETAIL="$(gitnexus_refresh_health_detail "$GITNEXUS_HEALTH_LOG" 2000)"; then
  GITNEXUS_HEALTH_RATE_STATUS=0
else
  GITNEXUS_HEALTH_RATE_STATUS=$?
fi
assert_eq "HEALTH flags a rolling refresh rate below 95%" "1" "$GITNEXUS_HEALTH_RATE_STATUS"
assert_contains "HEALTH shows the below-target rolling refresh rate" \
  "$GITNEXUS_HEALTH_RATE_DETAIL" \
  "refresh-samples=20/20 refresh-successes=18 refresh-rate=90% refresh-target=95% refresh-memory-floor-violations=0"
write_gitnexus_refresh_window "$GITNEXUS_HEALTH_LOG" 20 20
if GITNEXUS_HEALTH_RATE_DETAIL="$(gitnexus_refresh_health_detail "$GITNEXUS_HEALTH_LOG" 2000)"; then
  GITNEXUS_HEALTH_RATE_STATUS=0
else
  GITNEXUS_HEALTH_RATE_STATUS=$?
fi
assert_eq "HEALTH flags any refresh that samples below 3 GiB" "1" "$GITNEXUS_HEALTH_RATE_STATUS"
assert_contains "HEALTH records a refresh-period memory floor violation" \
  "$GITNEXUS_HEALTH_RATE_DETAIL" "refresh-memory-floor-violations=1"
GITNEXUS_HEALTH_FIXTURE="$GITNEXUS_TEST_ROOT/index-health"
mkdir -p "$GITNEXUS_HEALTH_FIXTURE/.gitnexus"
git -C "$GITNEXUS_HEALTH_FIXTURE" init -q --initial-branch=main
git -C "$GITNEXUS_HEALTH_FIXTURE" config user.name "GitNexus Health Test"
git -C "$GITNEXUS_HEALTH_FIXTURE" config user.email "gitnexus-health@example.test"
printf 'index base\n' > "$GITNEXUS_HEALTH_FIXTURE/file.txt"
git -C "$GITNEXUS_HEALTH_FIXTURE" add file.txt
git -C "$GITNEXUS_HEALTH_FIXTURE" commit -qm 'index base'
GITNEXUS_HEALTH_BASE_SHA="$(git -C "$GITNEXUS_HEALTH_FIXTURE" rev-parse HEAD)"
GITNEXUS_HEALTH_NOW=1791500000
GITNEXUS_HEALTH_MEMORY_LOG="$GITNEXUS_HEALTH_FIXTURE/memory.tsv"
: > "$GITNEXUS_HEALTH_MEMORY_LOG"
GITNEXUS_HEALTH_INDEXED_AT="$(date -u -d "@$((GITNEXUS_HEALTH_NOW - 7200))" +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg at "$GITNEXUS_HEALTH_INDEXED_AT" --arg sha "$GITNEXUS_HEALTH_BASE_SHA" \
  '{indexedAt:$at,lastCommit:$sha}' > "$GITNEXUS_HEALTH_FIXTURE/.gitnexus/meta.json"
git -C "$GITNEXUS_HEALTH_FIXTURE" update-ref refs/remotes/origin/main "$GITNEXUS_HEALTH_BASE_SHA"
write_gitnexus_refresh_window "$GITNEXUS_HEALTH_MEMORY_LOG" 18
gitnexus_index_health "$GITNEXUS_HEALTH_FIXTURE" "$GITNEXUS_HEALTH_MEMORY_LOG" "$GITNEXUS_HEALTH_NOW"
assert_eq "GitNexus HEALTH reads BROKEN when 20-refresh success rate is below 95%" "BROKEN" "$GITNEXUS_INDEX_HEALTH_STATE"
assert_contains "GitNexus HEALTH includes below-target rate in its detail" "$GITNEXUS_INDEX_HEALTH_DETAIL" "refresh-rate=90%"
write_gitnexus_refresh_window "$GITNEXUS_HEALTH_MEMORY_LOG" 19
gitnexus_index_health "$GITNEXUS_HEALTH_FIXTURE" "$GITNEXUS_HEALTH_MEMORY_LOG" "$GITNEXUS_HEALTH_NOW"
assert_eq "GitNexus HEALTH accepts exactly 95% after 20 refreshes" "OK" "$GITNEXUS_INDEX_HEALTH_STATE"
: > "$GITNEXUS_HEALTH_MEMORY_LOG"
gitnexus_index_health "$GITNEXUS_HEALTH_FIXTURE" "$GITNEXUS_HEALTH_MEMORY_LOG" "$GITNEXUS_HEALTH_NOW"
assert_eq "GitNexus HEALTH stays OK at exactly two hours and zero commits behind" "OK" "$GITNEXUS_INDEX_HEALTH_STATE"
assert_contains "GitNexus HEALTH reports index age and total commit lag" "$GITNEXUS_INDEX_HEALTH_DETAIL" "index-age-sec=7200 commits-behind=0"
GITNEXUS_HEALTH_INDEXED_AT="$(date -u -d "@$((GITNEXUS_HEALTH_NOW - 7201))" +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg at "$GITNEXUS_HEALTH_INDEXED_AT" --arg sha "$GITNEXUS_HEALTH_BASE_SHA" \
  '{indexedAt:$at,lastCommit:$sha}' > "$GITNEXUS_HEALTH_FIXTURE/.gitnexus/meta.json"
gitnexus_index_health "$GITNEXUS_HEALTH_FIXTURE" "$GITNEXUS_HEALTH_MEMORY_LOG" "$GITNEXUS_HEALTH_NOW"
assert_eq "GitNexus HEALTH reads STUCK after two hours" "STUCK" "$GITNEXUS_INDEX_HEALTH_STATE"
for GITNEXUS_HEALTH_COMMIT in $(seq 1 51); do
  git -C "$GITNEXUS_HEALTH_FIXTURE" commit --allow-empty -qm "health advance $GITNEXUS_HEALTH_COMMIT"
  if [ "$GITNEXUS_HEALTH_COMMIT" = 50 ]; then GITNEXUS_HEALTH_50_SHA="$(git -C "$GITNEXUS_HEALTH_FIXTURE" rev-parse HEAD)"; fi
done
GITNEXUS_HEALTH_51_SHA="$(git -C "$GITNEXUS_HEALTH_FIXTURE" rev-parse HEAD)"
GITNEXUS_HEALTH_INDEXED_AT="$(date -u -d "@$GITNEXUS_HEALTH_NOW" +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg at "$GITNEXUS_HEALTH_INDEXED_AT" --arg sha "$GITNEXUS_HEALTH_BASE_SHA" \
  '{indexedAt:$at,lastCommit:$sha}' > "$GITNEXUS_HEALTH_FIXTURE/.gitnexus/meta.json"
git -C "$GITNEXUS_HEALTH_FIXTURE" update-ref refs/remotes/origin/main "$GITNEXUS_HEALTH_50_SHA"
gitnexus_index_health "$GITNEXUS_HEALTH_FIXTURE" "$GITNEXUS_HEALTH_MEMORY_LOG" "$GITNEXUS_HEALTH_NOW"
assert_eq "GitNexus HEALTH stays OK at exactly 50 commits behind" "OK" "$GITNEXUS_INDEX_HEALTH_STATE"
assert_contains "GitNexus HEALTH reports the exact 50-commit boundary" "$GITNEXUS_INDEX_HEALTH_DETAIL" "index-age-sec=0 commits-behind=50"
git -C "$GITNEXUS_HEALTH_FIXTURE" update-ref refs/remotes/origin/main "$GITNEXUS_HEALTH_51_SHA"
gitnexus_index_health "$GITNEXUS_HEALTH_FIXTURE" "$GITNEXUS_HEALTH_MEMORY_LOG" "$GITNEXUS_HEALTH_NOW"
assert_eq "GitNexus HEALTH reads STUCK after 50 commits behind" "STUCK" "$GITNEXUS_INDEX_HEALTH_STATE"
assert_contains "GitNexus HEALTH reports total lag above its commit threshold" "$GITNEXUS_INDEX_HEALTH_DETAIL" "commits-behind=51"
jq -n --arg at "$GITNEXUS_HEALTH_INDEXED_AT" --arg sha "$GITNEXUS_HEALTH_51_SHA" \
  '{indexedAt:$at,lastCommit:$sha}' > "$GITNEXUS_HEALTH_FIXTURE/.gitnexus/meta.json"
printf 'run\tone\t1791499997\tsha-one\t3145728\t3145728\t124\t0\nrun\ttwo\t1791499998\tsha-two\t3145728\t3145728\t143\t0\nrun\tthree\t1791499999\tsha-three\t3145728\t3145728\t1\t0\n' > "$GITNEXUS_HEALTH_MEMORY_LOG"
gitnexus_index_health "$GITNEXUS_HEALTH_FIXTURE" "$GITNEXUS_HEALTH_MEMORY_LOG" "$GITNEXUS_HEALTH_NOW"
assert_eq "GitNexus HEALTH reads BROKEN after three consecutive refresh failures" "BROKEN" "$GITNEXUS_INDEX_HEALTH_STATE"
assert_contains "GitNexus HEALTH reports three failed refreshes and their exit codes" "$GITNEXUS_INDEX_HEALTH_DETAIL" "refresh-failure-streak=3+ exit-codes=124,143,1"
printf 'run\tone\t1791499998\tsha-one\t3145728\t3145728\t124\t0\nrun\ttwo\t1791499999\tsha-two\t3145728\t3145728\t143\t0\n' > "$GITNEXUS_HEALTH_MEMORY_LOG"
gitnexus_index_health "$GITNEXUS_HEALTH_FIXTURE" "$GITNEXUS_HEALTH_MEMORY_LOG" "$GITNEXUS_HEALTH_NOW"
assert_eq "GitNexus HEALTH does not read BROKEN before three failed refreshes" "OK" "$GITNEXUS_INDEX_HEALTH_STATE"
printf 'run\tone\t1791499997\tsha-one\t3145728\t3145728\t124\t0\nrun\ttwo\t1791499998\tsha-two\t3145728\t3145728\t143\t0\nrun\tthree\t1791499999\tsha-three\t3145728\t3145728\t1\t0\n' > "$GITNEXUS_HEALTH_MEMORY_LOG"
mv "$GITNEXUS_HEALTH_FIXTURE/.gitnexus/meta.json" "$GITNEXUS_HEALTH_FIXTURE/.gitnexus/meta.valid.json"
gitnexus_index_health "$GITNEXUS_HEALTH_FIXTURE" "$GITNEXUS_HEALTH_MEMORY_LOG" "$GITNEXUS_HEALTH_NOW"
assert_eq "three refresh failures report BROKEN even without verifiable index metadata" "BROKEN" "$GITNEXUS_INDEX_HEALTH_STATE"
assert_contains "missing index and failure streak stay visible" "$GITNEXUS_INDEX_HEALTH_DETAIL" "index-age-sec=unknown commits-behind=unknown refresh-failure-streak=3+"
mv "$GITNEXUS_HEALTH_FIXTURE/.gitnexus/meta.valid.json" "$GITNEXUS_HEALTH_FIXTURE/.gitnexus/meta.json"
assert_true "remote helper receives only the checkout and pinned SHA" \
  awk -F '\t' -v repo="$GITNEXUS_TEST_REPO" '$1 != repo || $2 !~ /^[0-9a-f]{40}$/ { bad=1 } END { exit bad }' "$FAKE_GITNEXUS_LOG"
git -C "$GITNEXUS_TEST_REPO" update-ref refs/remotes/origin/main "$GITNEXUS_SUCCESS_SHA"
assert_true "origin/main freshness predicate matches its current remote-tracking ref" \
  gitnexus_index_matches_origin_main "$GITNEXUS_TEST_REPO" origin/main
GITNEXUS_STALE_INDEXED_AT="$(date -u -d '3700 seconds ago' +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg sha "$GITNEXUS_SUCCESS_SHA" --arg at "$GITNEXUS_STALE_INDEXED_AT" \
  '{lastCommit:$sha,indexedAt:$at}' > "$GITNEXUS_TEST_REPO/.gitnexus/meta.json"
assert_false "origin/main freshness predicate rejects an exact-SHA index older than one hour" \
  gitnexus_index_matches_origin_main "$GITNEXUS_TEST_REPO" origin/main
jq -n --arg sha "$GITNEXUS_SUCCESS_SHA" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{lastCommit:$sha,indexedAt:$at}' > "$GITNEXUS_TEST_REPO/.gitnexus/meta.json"
git -C "$GITNEXUS_TEST_REPO" commit --allow-empty -qm 'origin/main advanced'
GITNEXUS_ORIGIN_ADVANCED_SHA="$(git -C "$GITNEXUS_TEST_REPO" rev-parse HEAD)"
git -C "$GITNEXUS_TEST_REPO" update-ref refs/remotes/origin/main "$GITNEXUS_ORIGIN_ADVANCED_SHA"
assert_true "origin/main freshness accepts a fresh indexed ancestor" \
  gitnexus_index_matches_origin_main "$GITNEXUS_TEST_REPO" origin/main
for lag in {2..20}; do
  git -C "$GITNEXUS_TEST_REPO" commit --allow-empty -qm "origin/main advance $lag"
done
GITNEXUS_ORIGIN_ADVANCED_SHA="$(git -C "$GITNEXUS_TEST_REPO" rev-parse HEAD)"
git -C "$GITNEXUS_TEST_REPO" update-ref refs/remotes/origin/main "$GITNEXUS_ORIGIN_ADVANCED_SHA"
assert_true "origin/main freshness accepts exactly 20 indexed-ancestor commits" \
  gitnexus_index_matches_origin_main "$GITNEXUS_TEST_REPO" origin/main
git -C "$GITNEXUS_TEST_REPO" commit --allow-empty -qm 'origin/main advances beyond freshness bound'
GITNEXUS_ORIGIN_ADVANCED_SHA="$(git -C "$GITNEXUS_TEST_REPO" rev-parse HEAD)"
git -C "$GITNEXUS_TEST_REPO" update-ref refs/remotes/origin/main "$GITNEXUS_ORIGIN_ADVANCED_SHA"
assert_false "origin/main freshness predicate rejects metadata after origin/main advances" \
  gitnexus_index_matches_origin_main "$GITNEXUS_TEST_REPO" origin/main
mkdir -p "$GITNEXUS_TEST_REPO/packages/x"
printf 'x\n' > "$GITNEXUS_TEST_REPO/packages/x/a.ts"
git -C "$GITNEXUS_TEST_REPO" add packages/x/a.ts
git -C "$GITNEXUS_TEST_REPO" commit -qm 'product change'
git -C "$GITNEXUS_TEST_REPO" update-ref refs/remotes/origin/main "$(git -C "$GITNEXUS_TEST_REPO" rev-parse HEAD)"
git -C "$GITNEXUS_TEST_REPO" update-ref refs/remotes/origin/main "$GITNEXUS_ORIGIN_ADVANCED_SHA"
assert_true "refresh helper closes its lock after return" \
  bash -c 'exec 9>"$1" && flock -n 9' _ "$AGENT_HOME/gitnexus-analyze.lock"

# Two independent shells: second waits on the same lock, then sees the first
# remote refresh's exact-SHA result instead of launching another refresh.
GITNEXUS_CONCURRENT_HOME="$GITNEXUS_TEST_ROOT/concurrent-home"
GITNEXUS_CONCURRENT_REPO="$GITNEXUS_TEST_ROOT/concurrent-repo"
mkdir -p "$GITNEXUS_CONCURRENT_HOME" "$GITNEXUS_CONCURRENT_REPO"
git -C "$GITNEXUS_CONCURRENT_REPO" init -q -b main
git -C "$GITNEXUS_CONCURRENT_REPO" config user.email lib-test@example.com
git -C "$GITNEXUS_CONCURRENT_REPO" config user.name lib-test
printf 'fixture\n' > "$GITNEXUS_CONCURRENT_REPO/tracked"
git -C "$GITNEXUS_CONCURRENT_REPO" add tracked
git -C "$GITNEXUS_CONCURRENT_REPO" commit -qm baseline
mkdir -p "$GITNEXUS_CONCURRENT_REPO/.gitnexus"
AGENT_HOME="$GITNEXUS_CONCURRENT_HOME"
FAKE_GITNEXUS_REPO="$GITNEXUS_CONCURRENT_REPO"
FAKE_GITNEXUS_LOG="$GITNEXUS_TEST_ROOT/concurrent.calls"
FAKE_GITNEXUS_STARTED="$GITNEXUS_TEST_ROOT/concurrent.started"
FAKE_GITNEXUS_RELEASE="$GITNEXUS_TEST_ROOT/concurrent.release"
GITNEXUS_CONCURRENT_CALLER_STARTED="$GITNEXUS_TEST_ROOT/concurrent-b.started"
GITNEXUS_CONCURRENT_SHA="$(git -C "$GITNEXUS_CONCURRENT_REPO" rev-parse HEAD)"
FAKE_GITNEXUS_SHA="$GITNEXUS_CONCURRENT_SHA"
FAKE_GITNEXUS_WAIT=1
rm -f "$FAKE_GITNEXUS_RELEASE" "$GITNEXUS_CONCURRENT_CALLER_STARTED"
(
  source "$SCRIPT_DIR/lib.sh"
  gitnexus_available_memory_kb() { printf '%s\n' "$FAKE_GITNEXUS_MEM_AVAILABLE_KB"; }
  gitnexus_refresh_index_once "$GITNEXUS_CONCURRENT_REPO" "$GITNEXUS_CONCURRENT_SHA" gitnexus_test_index_matches_commit
) > "$GITNEXUS_TEST_ROOT/concurrent-a.out" 2>&1 &
GITNEXUS_CONCURRENT_PID_A=$!
for _ in {1..3000}; do
  [ -f "$FAKE_GITNEXUS_STARTED" ] && break
  sleep 0.01
done
(
  touch "$GITNEXUS_CONCURRENT_CALLER_STARTED"
  source "$SCRIPT_DIR/lib.sh"
  gitnexus_available_memory_kb() { printf '%s\n' "$FAKE_GITNEXUS_MEM_AVAILABLE_KB"; }
  gitnexus_refresh_index_once "$GITNEXUS_CONCURRENT_REPO" "$GITNEXUS_CONCURRENT_SHA" gitnexus_test_index_matches_commit
) > "$GITNEXUS_TEST_ROOT/concurrent-b.out" 2>&1 &
GITNEXUS_CONCURRENT_PID_B=$!
for _ in {1..3000}; do
  [ -f "$GITNEXUS_CONCURRENT_CALLER_STARTED" ] && break
  sleep 0.01
done
sleep 0.05
assert_true "second independent caller starts while remote refresh is held" test -f "$GITNEXUS_CONCURRENT_CALLER_STARTED"
assert_false "refresh lock stays held while remote refresh runs" \
  bash -c 'exec 9>"$1" && flock -n 9' _ "$AGENT_HOME/gitnexus-analyze.lock"
assert_eq "waiter cannot start a second refresh while first runs" "1" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"
touch "$FAKE_GITNEXUS_RELEASE"
if wait "$GITNEXUS_CONCURRENT_PID_A"; then GITNEXUS_CONCURRENT_STATUS_A=0; else GITNEXUS_CONCURRENT_STATUS_A=$?; fi
if wait "$GITNEXUS_CONCURRENT_PID_B"; then GITNEXUS_CONCURRENT_STATUS_B=0; else GITNEXUS_CONCURRENT_STATUS_B=$?; fi
assert_eq "first concurrent caller confirms refresh" "0" "$GITNEXUS_CONCURRENT_STATUS_A"
assert_eq "waiter sees fresh result after acquiring lock" "0" "$GITNEXUS_CONCURRENT_STATUS_B"
assert_eq "two processes start only one refresh for the checkout SHA" "1" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"

# If the first holder fails, its waiter receives stale-index status instead
# of starting another refresh during the shared throttle.
rm -f "$GITNEXUS_CONCURRENT_HOME/gitnexus-analyze-last-start"
git -C "$GITNEXUS_CONCURRENT_REPO" commit --allow-empty -qm 'failed refresh SHA'
GITNEXUS_CONCURRENT_FAILURE_SHA="$(git -C "$GITNEXUS_CONCURRENT_REPO" rev-parse HEAD)"
FAKE_GITNEXUS_SHA="$GITNEXUS_CONCURRENT_FAILURE_SHA"
FAKE_GITNEXUS_FAIL=1
FAKE_GITNEXUS_LOG="$GITNEXUS_TEST_ROOT/concurrent-failure.calls"
FAKE_GITNEXUS_STARTED="$GITNEXUS_TEST_ROOT/concurrent-failure.started"
FAKE_GITNEXUS_RELEASE="$GITNEXUS_TEST_ROOT/concurrent-failure.release"
GITNEXUS_CONCURRENT_CALLER_STARTED="$GITNEXUS_TEST_ROOT/concurrent-failure-b.started"
rm -f "$FAKE_GITNEXUS_RELEASE" "$GITNEXUS_CONCURRENT_CALLER_STARTED"
rm -f "$GITNEXUS_CONCURRENT_REPO/.gitnexus/meta.json"
(
  source "$SCRIPT_DIR/lib.sh"
  gitnexus_available_memory_kb() { printf '%s\n' "$FAKE_GITNEXUS_MEM_AVAILABLE_KB"; }
  gitnexus_refresh_index_once "$GITNEXUS_CONCURRENT_REPO" "$GITNEXUS_CONCURRENT_FAILURE_SHA" gitnexus_test_index_matches_commit
) > "$GITNEXUS_TEST_ROOT/concurrent-failure-a.out" 2>&1 &
GITNEXUS_CONCURRENT_PID_A=$!
for _ in {1..3000}; do
  [ -f "$FAKE_GITNEXUS_STARTED" ] && break
  sleep 0.01
done
(
  touch "$GITNEXUS_CONCURRENT_CALLER_STARTED"
  source "$SCRIPT_DIR/lib.sh"
  gitnexus_available_memory_kb() { printf '%s\n' "$FAKE_GITNEXUS_MEM_AVAILABLE_KB"; }
  if gitnexus_refresh_index_once "$GITNEXUS_CONCURRENT_REPO" "$GITNEXUS_CONCURRENT_FAILURE_SHA" gitnexus_test_index_matches_commit; then
    exit 0
  else
    echo "$GITNEXUS_REFRESH_OUTPUT"
    exit 1
  fi
) > "$GITNEXUS_TEST_ROOT/concurrent-failure-b.out" 2>&1 &
GITNEXUS_CONCURRENT_PID_B=$!
for _ in {1..3000}; do
  [ -f "$GITNEXUS_CONCURRENT_CALLER_STARTED" ] && break
  sleep 0.01
done
sleep 0.05
assert_true "failed-refresh waiter starts while first refresh is held" test -f "$GITNEXUS_CONCURRENT_CALLER_STARTED"
assert_eq "failed-refresh waiter does not start a concurrent refresh" "1" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"
touch "$FAKE_GITNEXUS_RELEASE"
if wait "$GITNEXUS_CONCURRENT_PID_A"; then GITNEXUS_CONCURRENT_STATUS_A=0; else GITNEXUS_CONCURRENT_STATUS_A=$?; fi
if wait "$GITNEXUS_CONCURRENT_PID_B"; then GITNEXUS_CONCURRENT_STATUS_B=0; else GITNEXUS_CONCURRENT_STATUS_B=$?; fi
assert_eq "failed concurrent analyzer stays a stale-index result" "1" "$GITNEXUS_CONCURRENT_STATUS_A"
assert_eq "waiter keeps non-fatal failure status" "1" "$GITNEXUS_CONCURRENT_STATUS_B"
assert_contains "failed waiter gets throttle note" "$(cat "$GITNEXUS_TEST_ROOT/concurrent-failure-b.out")" "latest-wins throttle"
assert_eq "failed concurrent SHA still starts only one refresh" "1" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"

# A wedged holder is bounded; its waiter returns stale without starting refresh.
GITNEXUS_REFRESH_LOCK_WAIT_SECONDS=1
exec 7>"$AGENT_HOME/gitnexus-analyze.lock"
flock 7
if gitnexus_refresh_index_once "$GITNEXUS_CONCURRENT_REPO" timeout-target gitnexus_test_index_matches_commit; then
  GITNEXUS_LOCK_TIMEOUT_STATUS=0
else
  GITNEXUS_LOCK_TIMEOUT_STATUS=$?
fi
flock -u 7
exec 7>&-
assert_eq "refresh lock wait timeout degrades to stale-index result" "1" "$GITNEXUS_LOCK_TIMEOUT_STATUS"
assert_contains "lock timeout is reported" "$GITNEXUS_REFRESH_OUTPUT" "timed out"
assert_eq "lock timeout does not start another refresh" "1" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"

# A checkout can advance while this caller waits. Refresh the SHA observed
# after acquiring the mutex, so newer origin work is not missed.
GITNEXUS_WAITED_HOME="$GITNEXUS_TEST_ROOT/waited-home"
GITNEXUS_WAITED_REPO="$GITNEXUS_TEST_ROOT/waited-repo"
mkdir -p "$GITNEXUS_WAITED_HOME" "$GITNEXUS_WAITED_REPO"
git -C "$GITNEXUS_WAITED_REPO" init -q -b main
git -C "$GITNEXUS_WAITED_REPO" config user.email lib-test@example.com
git -C "$GITNEXUS_WAITED_REPO" config user.name lib-test
printf 'fixture\n' > "$GITNEXUS_WAITED_REPO/tracked"
git -C "$GITNEXUS_WAITED_REPO" add tracked
git -C "$GITNEXUS_WAITED_REPO" commit -qm baseline
mkdir -p "$GITNEXUS_WAITED_REPO/.gitnexus"
GITNEXUS_WAITED_OLD_SHA="$(git -C "$GITNEXUS_WAITED_REPO" rev-parse HEAD)"
AGENT_HOME="$GITNEXUS_WAITED_HOME"
FAKE_GITNEXUS_REPO="$GITNEXUS_WAITED_REPO"
FAKE_GITNEXUS_LOG="$GITNEXUS_TEST_ROOT/waited.calls"
FAKE_GITNEXUS_STARTED="$GITNEXUS_TEST_ROOT/waited.started"
FAKE_GITNEXUS_FAIL=1
FAKE_GITNEXUS_WAIT=0
FAKE_FLOCK_WAIT_STARTED="$GITNEXUS_TEST_ROOT/waited-lock-requested"
export FAKE_FLOCK_WAIT_STARTED
exec 8>"$AGENT_HOME/gitnexus-analyze.lock"
flock 8
(
  source "$SCRIPT_DIR/lib.sh"
  gitnexus_available_memory_kb() { printf '%s\n' "$FAKE_GITNEXUS_MEM_AVAILABLE_KB"; }
  gitnexus_refresh_index_once "$GITNEXUS_WAITED_REPO" "$GITNEXUS_WAITED_OLD_SHA" gitnexus_test_index_matches_commit
) > "$GITNEXUS_TEST_ROOT/waited.out" 2>&1 &
GITNEXUS_WAITED_PID=$!
for _ in {1..3000}; do
  [ -f "$FAKE_FLOCK_WAIT_STARTED" ] && break
  sleep 0.01
done
assert_true "waiter reaches flock before checkout advances" test -f "$FAKE_FLOCK_WAIT_STARTED"
git -C "$GITNEXUS_WAITED_REPO" commit --allow-empty -qm 'checkout advanced while waiting'
GITNEXUS_WAITED_NEW_SHA="$(git -C "$GITNEXUS_WAITED_REPO" rev-parse HEAD)"
flock -u 8
exec 8>&-
if wait "$GITNEXUS_WAITED_PID"; then
  GITNEXUS_WAITED_REFRESH_STATUS=0
else
  GITNEXUS_WAITED_REFRESH_STATUS=$?
fi
assert_eq "refresh after checkout advance stays a stale-index result" "1" "$GITNEXUS_WAITED_REFRESH_STATUS"
assert_eq "attempt marker uses checkout SHA read after acquiring lock" \
  "$GITNEXUS_WAITED_REPO $GITNEXUS_WAITED_NEW_SHA" "$(cat "$AGENT_HOME/gitnexus-analyze-attempt")"
assert_false "waiter cannot repeat its failed refresh during throttle" \
  gitnexus_refresh_index_once "$GITNEXUS_WAITED_REPO" "$GITNEXUS_WAITED_NEW_SHA" gitnexus_test_index_matches_commit
assert_eq "checkout advance during wait still starts only one refresh" \
  "1" "$(wc -l < "$FAKE_GITNEXUS_LOG" | tr -d ' ')"

AGENT_HOME="$GITNEXUS_TEST_ORIGINAL_AGENT_HOME"
PATH="$GITNEXUS_TEST_ORIGINAL_PATH"
source "$SCRIPT_DIR/lib.sh"
GITNEXUS_REFRESH_LOCK_WAIT_SECONDS="$GITNEXUS_TEST_ORIGINAL_WAIT"
GITNEXUS_REFRESH_MIN_INTERVAL_SECONDS="$GITNEXUS_TEST_ORIGINAL_MIN_INTERVAL"
unset FAKE_GITNEXUS_LOG FAKE_GITNEXUS_STARTED FAKE_GITNEXUS_REPO FAKE_GITNEXUS_SHA FAKE_GITNEXUS_FAIL FAKE_GITNEXUS_WAIT FAKE_GITNEXUS_EXIT_3 FAKE_GITNEXUS_MEM_DROP FAKE_GITNEXUS_LOW_MEMORY_MARKER FAKE_GITNEXUS_MEM_AVAILABLE_KB FAKE_GITNEXUS_RELEASE FAKE_FLOCK_WAIT_STARTED GITNEXUS_CIHOST_INDEX_SCRIPT
rm -rf "$GITNEXUS_TEST_ROOT"


lib_case_exit
