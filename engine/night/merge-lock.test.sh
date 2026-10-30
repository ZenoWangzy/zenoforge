#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"

tmp="$(mktemp -d)"
worker_pids=()
cleanup() {
  local pid status=$?
  for pid in "${worker_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${worker_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  if ((status != 0)); then
    for file in "$tmp"/*.log; do [[ -f "$file" ]] && { printf '\n--- %s ---\n' "$file" >&2; cat "$file" >&2; }; done
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT
unset AGENT_HOME
export ZF_HOME="$tmp/zenoforge-agent-home/.zenoforge"
mkdir -p "$HOME/.zenoforge" "$ZF_HOME" "$tmp/ready" "$tmp/release"
jq ".roles.advisor.disabled = false" "$REPO_DIR/engine/model-policy.default.json" > "$HOME/.zenoforge/model-policy.json"
jq ".roles.advisor.disabled = false" "$REPO_DIR/engine/model-policy.default.json" > "$ZF_HOME/model-policy.json"
source "$REPO_DIR/engine/lib.sh"
mkdir -p "$AGENT_HOME/locks" "$ZF_HOME/locks"
assert_reason() {
  local expected="$1" status_code="$2" expected_head="$3" observed_head="$4" actual
  actual="$(main_pr_merge_failure_reason "$status_code" "$expected_head" "$observed_head")"
  [ "$actual" = "$expected" ] || {
    printf 'expected merge failure reason %q, got %q\n' "$expected" "$actual" >&2
    exit 1
  }
}
assert_reason 'GitHub merge command timed out (status=124)' 124 head-a head-a
assert_reason 'head moved' 1 head-a head-b
assert_reason 'gate refused merge (gh status=1)' 1 head-a head-a
assert_reason 'PR head state unavailable (gh status=1)' 1 head-a ''

shim="$REPO_DIR/engine/gh-shim/gh"
test -x "$shim"
cat > "$tmp/real-gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_SHIM_TEST_LOG"
EOF
chmod +x "$tmp/real-gh"
export GH_SHIM_TEST_LOG="$tmp/gh-calls"
for form in direct parent-repo timeout; do
  : > "$GH_SHIM_TEST_LOG"
  status=0
  case "$form" in
    direct) ZF_GH_REAL_CLI="$tmp/real-gh" "$shim" pr merge 42 --auto 2>"$tmp/gh-error" || status=$? ;;
    parent-repo) ZF_GH_REAL_CLI="$tmp/real-gh" "$shim" -R test/repo pr merge 42 --auto-merge 2>"$tmp/gh-error" || status=$? ;;
    timeout) ZF_GH_REAL_CLI="$tmp/real-gh" timeout 5 "$shim" pr merge 42 --auto 2>"$tmp/gh-error" || status=$? ;;
  esac
  [ "$status" -eq 64 ] || { echo "$form: expected refusal 64, got $status" >&2; exit 1; }
  grep -Fq 'no required-checks list' "$tmp/gh-error"
  test ! -s "$GH_SHIM_TEST_LOG"
done
ZF_GH_REAL_CLI="$tmp/real-gh" "$shim" pr merge 42 --squash --match-head-commit test-head
grep -Fxq 'pr merge 42 --squash --match-head-commit test-head' "$GH_SHIM_TEST_LOG"
printf 'merge-lock.test.sh: PASS\n'
