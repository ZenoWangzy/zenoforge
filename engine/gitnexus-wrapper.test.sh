#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
wrapper="$script_dir/gitnexus-wrapper.sh"
installer="$script_dir/install-gitnexus-wrapper.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

npm_bin="$tmp/npm/bin"
real_path="$tmp/npm/lib/node_modules/gitnexus/dist/cli/index.js"
test_bin="$tmp/test-bin"
repo_seed="$tmp/repo-seed"
repo="$tmp/repo"
git init --bare -q "$tmp/origin.git"
git init -b main -q "$repo_seed"
git -C "$repo_seed" config user.name 'Wrapper Test'
git -C "$repo_seed" config user.email 'wrapper-test@example.invalid'
mkdir -p "$repo_seed/engine"
cp "$wrapper" "$repo_seed/engine/gitnexus-wrapper.sh"
git -C "$repo_seed" add .
git -C "$repo_seed" commit -qm 'base wrapper'
git -C "$repo_seed" remote add origin "$tmp/origin.git"
git -C "$repo_seed" push -q origin main
git --git-dir="$tmp/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$tmp/origin.git" "$repo"
git -C "$repo" config user.name 'Wrapper Test'
git -C "$repo" config user.email 'wrapper-test@example.invalid'
git -C "$repo" switch -qc hand/installer-test
printf '\n# unlanded test artifact\n' >> "$repo/engine/gitnexus-wrapper.sh"
git -C "$repo" add engine/gitnexus-wrapper.sh
git -C "$repo" commit -qm 'unlanded wrapper change'
mkdir -p "$(dirname -- "$real_path")" "$test_bin" "$npm_bin"
cat > "$real_path" <<'FAKE_CLI'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GITNEXUS_CALL_LOG"
if [[ "${1:-}" == --version ]]; then echo 1.6.12; fi
FAKE_CLI
chmod +x "$real_path"
ln -s ../lib/node_modules/gitnexus/dist/cli/index.js "$npm_bin/gitnexus"
if HOME="$tmp/home" AGENT_HOME="$tmp/agent" ZF_REPO_DIR="$repo" ZF_NPM_GLOBAL_BIN_DIR="$npm_bin" bash "$installer" >"$tmp/unlanded.out" 2>&1; then
  echo "expected unlanded installer refusal" >&2
  exit 1
fi
[[ -L "$npm_bin/gitnexus" && ! -e "$npm_bin/gitnexus.real-link" ]]
git -C "$repo" push -q origin HEAD:main
git -C "$repo" fetch -q origin main
HOME="$tmp/home" AGENT_HOME="$tmp/agent" ZF_REPO_DIR="$repo" ZF_NPM_GLOBAL_BIN_DIR="$npm_bin" bash "$installer" >/dev/null
[[ -L "$npm_bin/gitnexus.real-link" ]]
[[ -x "$npm_bin/gitnexus" ]]
[[ -f "$tmp/agent/gitnexus-analyze-guard-live-since" ]]
cmp -s <(git -C "$repo" show origin/main:engine/gitnexus-wrapper.sh) "$npm_bin/gitnexus"
original_target="$(readlink "$npm_bin/gitnexus.real-link")"
rm -- "$npm_bin/gitnexus"
ln -s ../lib/node_modules/gitnexus/dist/cli/index.js "$npm_bin/gitnexus"
HOME="$tmp/home" AGENT_HOME="$tmp/agent" ZF_REPO_DIR="$repo" ZF_NPM_GLOBAL_BIN_DIR="$npm_bin" bash "$installer" >/dev/null
[[ "$(readlink "$npm_bin/gitnexus.real-link")" == "$original_target" ]]

cat > "$test_bin/systemd-run" <<'FAKE_SYSTEMD_RUN'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$GITNEXUS_SYSTEMD_ARGS"
while [[ "$1" != -- ]]; do shift; done
shift
exec "$@"
FAKE_SYSTEMD_RUN
chmod +x "$test_bin/systemd-run"
export PATH="$test_bin:$PATH"
export GITNEXUS_CALL_LOG="$tmp/calls"
export GITNEXUS_SYSTEMD_ARGS="$tmp/systemd-args"
export GITNEXUS_ANALYZE_LOCK_FILE="$tmp/agent/gitnexus-analyze.lock"
export GITNEXUS_ANALYZE_LOCK_WAIT_SECONDS=0
export GITNEXUS_MEMINFO_FILE="$tmp/meminfo"
export AGENT_HOME="$tmp/agent"
: > "$GITNEXUS_CALL_LOG"

"$npm_bin/gitnexus" --version | grep -qx '1.6.12'
: > "$GITNEXUS_CALL_LOG"
[[ ! -e "$GITNEXUS_SYSTEMD_ARGS" ]]
"$npm_bin/gitnexus" --print-minimum-available-mb | grep -qx '7680'
[[ ! -s "$GITNEXUS_CALL_LOG" ]]

unset GITNEXUS_ANALYZE_MEMORY_CAP_MB GITNEXUS_ANALYZE_MIN_AVAILABLE_MB
printf 'MemAvailable: 7864320 kB\n' > "$GITNEXUS_MEMINFO_FILE"
"$npm_bin/gitnexus" analyze --index-only
grep -Fq 'MemoryMax=5120M' "$GITNEXUS_SYSTEMD_ARGS"
grep -Fq 'MemorySwapMax=0' "$GITNEXUS_SYSTEMD_ARGS"
: > "$GITNEXUS_CALL_LOG"

export GITNEXUS_ANALYZE_MEMORY_CAP_MB=3000
export GITNEXUS_ANALYZE_MIN_AVAILABLE_MB=6000
"$npm_bin/gitnexus" --print-minimum-available-mb | grep -qx '6000'
printf 'MemAvailable: 5500000 kB\n' > "$GITNEXUS_MEMINFO_FILE"
if "$npm_bin/gitnexus" analyze --index-only >"$tmp/low.out" 2>&1; then
  echo "expected low-memory refusal" >&2
  exit 1
else
  status=$?
fi
[[ "$status" == 3 ]]
grep -Fq 'MemAvailable 5371MB < 6000MB' "$tmp/low.out"
[[ ! -s "$GITNEXUS_CALL_LOG" ]]

printf 'MemAvailable: 9000000 kB\n' > "$GITNEXUS_MEMINFO_FILE"
"$npm_bin/gitnexus" analyze --index-only
grep -Fq 'MemoryMax=3000M' "$GITNEXUS_SYSTEMD_ARGS"
grep -Fq 'MemorySwapMax=0' "$GITNEXUS_SYSTEMD_ARGS"
grep -qx 'analyze --index-only' "$GITNEXUS_CALL_LOG"

# A direct analyze shares the pipeline helper's existing lock.
(
  exec 9>"$GITNEXUS_ANALYZE_LOCK_FILE"
  flock 9
  if "$npm_bin/gitnexus" analyze --index-only >"$tmp/locked.out" 2>&1; then
    echo "expected busy-lock refusal" >&2
    exit 1
  else
    status=$?
  fi
  [[ "$status" == 3 ]]
  grep -Fq 'shared lock busy' "$tmp/locked.out"
)

# Pipeline helper owns the same lock already; its explicit handoff avoids self-deadlock.
(
  exec 9>"$GITNEXUS_ANALYZE_LOCK_FILE"
  flock 9
  ZF_GITNEXUS_REFRESH_LOCK_HELD=1 "$npm_bin/gitnexus" analyze --index-only
)
[[ "$(wc -l < "$GITNEXUS_CALL_LOG" | tr -d ' ')" == 2 ]]

# One-shot commands share one host-wide lock (2026-09-29: 24 parallel
# `impact` calls froze WSL); a long-running server never takes it.
export GITNEXUS_QUERY_LOCK_FILE="$tmp/agent/gitnexus-query.lock"
: > "$GITNEXUS_CALL_LOG"
(
  exec 8>"$GITNEXUS_QUERY_LOCK_FILE"
  flock 8
  if GITNEXUS_QUERY_LOCK_WAIT_SECONDS=0 "$npm_bin/gitnexus" impact foo >"$tmp/query-locked.out" 2>&1; then
    echo "expected busy query lock refusal" >&2
    exit 1
  else
    status=$?
  fi
  [[ "$status" == 3 ]]
  grep -Fq 'query lock busy' "$tmp/query-locked.out"
  GITNEXUS_QUERY_LOCK_WAIT_SECONDS=0 "$npm_bin/gitnexus" mcp
)
grep -qx 'mcp' "$GITNEXUS_CALL_LOG"
if grep -q '^impact' "$GITNEXUS_CALL_LOG"; then
  echo 'unexpected match' >&2
  exit 1
fi
GITNEXUS_QUERY_LOCK_WAIT_SECONDS=0 "$npm_bin/gitnexus" impact foo
grep -qx 'impact foo' "$GITNEXUS_CALL_LOG"

# Sandboxed agents see AGENT_HOME read-only; the default lock must not live there.
mkdir -p "$tmp/read-only-home"
chmod 555 "$tmp/read-only-home"
( unset GITNEXUS_QUERY_LOCK_FILE
  AGENT_HOME="$tmp/read-only-home" GITNEXUS_QUERY_LOCK_WAIT_SECONDS=60 "$npm_bin/gitnexus" impact sandboxed )
grep -qx 'impact sandboxed' "$GITNEXUS_CALL_LOG"

# The default lock is per uid: on a shared CI runner another user's
# /tmp/zf-gitnexus-query.lock was not writable (2026-09-29).
(
  unset GITNEXUS_QUERY_LOCK_FILE
  exec 8>"/tmp/zf-gitnexus-query-$(id -u).lock"
  flock 8
  if GITNEXUS_QUERY_LOCK_WAIT_SECONDS=0 "$npm_bin/gitnexus" impact per-uid >"$tmp/per-uid.out" 2>&1; then
    echo "expected the default lock to be the per-uid lock" >&2
    exit 1
  fi
  grep -Fq 'query lock busy' "$tmp/per-uid.out"
)
echo "gitnexus-wrapper.test.sh: PASS"
