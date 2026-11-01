#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tmp="$(mktemp -d "$root/.git/release-runner-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
trace="$tmp/runner.trace"
config="$tmp/repo/.zenoforge/release.json"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_line() { grep -Fxq -- "$1" "$trace" || fail "runner trace lacks: $1"; }
trace_lines() { wc -l < "$trace"; }

mkdir -p "$tmp/repo/.zenoforge" "$tmp/repo/scripts/release" "$tmp/engine-real" "$tmp/cwd" "$tmp/home"
cp "$root/engine/config.sh" "$tmp/engine-real/config.sh"
cp "$root/engine/run-release.sh" "$tmp/engine-real/run-release.sh"
chmod +x "$tmp/engine-real/run-release.sh"
ln -s engine-real "$tmp/engine-live"

cat > "$tmp/repo/scripts/release/run-release.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
printf 'started\n' >> "$RUNNER_TRACE"
printf 'cwd=%s\n' "$PWD" >> "$RUNNER_TRACE"
printf 'engine=%s\n' "$ZF_ENGINE_DIR" >> "$RUNNER_TRACE"
printf 'repo=%s\n' "$ZF_REPO_DIR" >> "$RUNNER_TRACE"
printf 'config=%s\n' "$ZF_CONFIG_ROOT" >> "$RUNNER_TRACE"
printf 'marker=%s\n' "$RUNNER_MARKER" >> "$RUNNER_TRACE"
printf 'argc=%s\n' "$#" >> "$RUNNER_TRACE"
printf 'argument=<%s>\n' "$@" >> "$RUNNER_TRACE"
for name in \
  ZF_WEB_ADVISOR_PROVIDER_CALL_TIMEOUT_SECONDS \
  ZF_WEB_ADVISOR_PROVIDER_CDP_PORT \
  ZF_WEB_ADVISOR_PROVIDER_JOB_DIR \
  ZF_WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS \
  ZF_WEB_ADVISOR_PROVIDER_POLL_INTERVAL_SECONDS \
  ZF_WEB_ADVISOR_PROVIDER_SCRIPT \
  ZF_WEB_ADVISOR_PROVIDER_TOPIC \
  ZF_WEB_ADVISOR_PROVIDER_UNIT_PREFIX \
  ZF_CDP_BROWSER_LEASE_SCRIPT ZF_PACK_REL; do
  [[ -v $name ]] && printf 'leak=%s\n' "$name" >> "$RUNNER_TRACE"
done
exit 0
RUNNER
chmod +x "$tmp/repo/scripts/release/run-release.sh"
printf '%s\n' '{"release":{"runner":"scripts/release/run-release.sh"}}' > "$config"

dispatch() {
  (cd "$tmp/cwd" && env -i \
    PATH="$PATH" HOME="$tmp/home" PWD="$tmp/cwd" \
    ZF_ENGINE_DIR="$tmp/inherited-engine" \
    ZF_REPO_DIR="$tmp/repo" \
    ZF_CONFIG_ROOT="$tmp/repo/.zenoforge" \
    RUNNER_MARKER=caller-value RUNNER_TRACE="$trace" \
    bash "$tmp/engine-live/run-release.sh" "$@")
}

if output="$(dispatch first '' last 2>&1)"; then :; else fail "valid dispatch failed: $output"; fi
[[ ! -s "$trace" ]] && fail 'configured runner did not start'
assert_line 'started'
assert_line "cwd=$tmp/cwd"
assert_line "engine=$tmp/engine-real"
assert_line "repo=$tmp/repo"
assert_line "config=$tmp/repo/.zenoforge"
assert_line 'marker=caller-value'
assert_line 'argc=3'
assert_line 'argument=<first>'
assert_line 'argument=<>'
assert_line 'argument=<last>'
if grep -q '^leak=' "$trace"; then fail 'config.sh defaults leaked into the target runner environment'; fi

expect_failure() {
  local expected="$1" before after output status
  before="$(trace_lines)"
  if output="$(dispatch probe 2>&1)"; then status=0; else status=$?; fi
  [[ $status -ne 0 ]] || fail "expected failure containing '$expected'"
  [[ "$output" == *"$expected"* ]] || fail "missing error '$expected': $output"
  after="$(trace_lines)"
  [[ "$after" == "$before" ]] || fail 'runner started after a dispatcher failure'
}

mv "$config" "$config.saved"
expect_failure 'release.json is missing'
mv "$config.saved" "$config"

printf '%s\n' '{invalid json' > "$config"
expect_failure 'release.json is invalid'

printf '%s\n' '{"release":{"runner":"scripts/release/missing.sh"}}' > "$config"
expect_failure 'configured runner is not a regular executable file'

printf '%s\n' '{"release":{"runner":"scripts/release/run-release.sh"}}' > "$config"
chmod 0644 "$tmp/repo/scripts/release/run-release.sh"
expect_failure 'configured runner is not a regular executable file'

printf 'PASS: dispatcher preserves argv, env, and cwd; resolves symlinked engine path; fails closed for config and runner faults\n'
