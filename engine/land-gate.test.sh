#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
gate_script="$script_dir/land-gate.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/land-gate-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'land-gate.test.sh: %s\n' "$*" >&2
  exit 1
}

new_fixture() {
  local name="$1"
  FIXTURE_ROOT="$tmp/$name"
  FIXTURE_REPO="$FIXTURE_ROOT/repo"
  FIXTURE_REMOTE="$FIXTURE_ROOT/origin.git"
  mkdir -p "$FIXTURE_ROOT"
  git init --bare -q "$FIXTURE_REMOTE"
  git init -q "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" checkout -q -b seed
  git -C "$FIXTURE_REPO" config user.name 'land-gate fixture'
  git -C "$FIXTURE_REPO" config user.email 'land-gate@example.invalid'
  mkdir -p "$FIXTURE_REPO/engine"
  cp "$gate_script" "$FIXTURE_REPO/engine/land-gate.sh"
  cp "$script_dir/test-bootstrap-check.sh" "$FIXTURE_REPO/engine/test-bootstrap-check.sh"
  cp "$script_dir/test-env.sh" "$FIXTURE_REPO/engine/test-env.sh"
  git -C "$FIXTURE_REPO" add engine
  git -C "$FIXTURE_REPO" commit -q -m 'fixture: seed land gate'
  git -C "$FIXTURE_REPO" remote add origin "$FIXTURE_REMOTE"
  git -C "$FIXTURE_REPO" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "$FIXTURE_REPO" push -q origin HEAD:refs/heads/main
  git -C "$FIXTURE_REPO" fetch -q origin main
  git -C "$FIXTURE_REPO" checkout -q -b gate-test origin/main
}

run_gate() {
  (
    cd "$FIXTURE_REPO"
    bash "$gate_script" "$@"
  )
}

assert_rejected() {
  local expected="$1"
  shift
  local log="$tmp/gate-output.log"
  if run_gate "$@" > "$log" 2>&1; then
    cat "$log" >&2
    fail "expected rejection containing: $expected"
  fi
  if ! grep -Fq "$expected" "$log"; then
    cat "$log" >&2
    fail "rejection did not identify rule/message: $expected"
  fi
}

# A shell test without the test-env bootstrap must fail before any land gate passes.
new_fixture bootstrap
cat > "$FIXTURE_REPO/engine/fixture.test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'missing test-env source\n'
SH
assert_rejected 'ERROR check-rulings: test suite must start with set -euo pipefail and source test-env.sh' \
  engine/fixture.test.sh

# A compliant new shell test passes.
new_fixture compliant
cat > "$FIXTURE_REPO/engine/fixture.test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "engine/test-env.sh"
printf 'valid fixture test\n'
SH
if ! run_gate engine/fixture.test.sh > "$tmp/compliant-output.log" 2>&1; then
  cat "$tmp/compliant-output.log" >&2
  fail 'compliant new test should pass bootstrap and syntax checks'
fi

# An ordinary shell file passes all fixture checks.
new_fixture normal
printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "ok\\n"\n' > "$FIXTURE_REPO/engine/normal.sh"
if ! run_gate engine/normal.sh > "$tmp/normal-output.log" 2>&1; then
  cat "$tmp/normal-output.log" >&2
  fail 'normal file should pass'
fi
grep -Fq 'land-gate: PASS' "$tmp/normal-output.log" || fail 'normal pass marker missing'

printf 'land-gate tests passed\n'
