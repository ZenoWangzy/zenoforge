#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
source "$SCRIPT_DIR/lib.sh"

repo="$TEST_ROOT/repo"
mkdir -p "$repo" "$TEST_ROOT/bin" "$TEST_ROOT/home"
git -C "$repo" init -q -b test-base
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
printf 'fixture\n' > "$repo/tracked"
git -C "$repo" add tracked
git -C "$repo" commit -qm baseline
head_sha="$(git -C "$repo" rev-parse HEAD)"
tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
origin_sha="$(printf 'origin advanced\n' | git -C "$repo" commit-tree "$tree" -p "$head_sha")"
git -C "$repo" update-ref refs/remotes/origin/main "$origin_sha"

cat > "$TEST_ROOT/bin/gitnexus-cihost-index" <<'FAKE'
#!/usr/bin/env bash
printf '%s\t%s\n' "$2" "$3" >> "$FAKE_GITNEXUS_LOG"
echo 'simulated remote refresh failure'
exit 1
FAKE
chmod +x "$TEST_ROOT/bin/gitnexus-cihost-index"
export AGENT_HOME="$TEST_ROOT/home"
export GITNEXUS_CIHOST_INDEX_SCRIPT="$TEST_ROOT/bin/gitnexus-cihost-index"
export FAKE_GITNEXUS_LOG="$TEST_ROOT/refresh.log"
gitnexus_available_memory_kb() { printf '%s\n' "$((4 * 1024 * 1024))"; }

if gitnexus_refresh_index_once "$repo" "$head_sha" gitnexus_index_matches_origin_main; then
  status=0
else
  status=$?
fi
assert_eq() {
  [[ "$1" == "$2" ]] || { echo "not ok - $3 (expected [$2], got [$1])" >&2; exit 1; }
}
assert_eq "$status" 1 'stale index stays unconfirmed'
assert_eq "$(cat "$FAKE_GITNEXUS_LOG")" "$(printf '%s\t%s' "$repo" "$origin_sha")" 'remote receives latest origin SHA'
assert_eq "$(cat "$AGENT_HOME/gitnexus-analyze-attempt")" "$repo $origin_sha" 'attempt marker records latest origin SHA'
assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_sha" 'refresh does not move checkout HEAD'
echo 'gitnexus-refresh-target.test.sh: PASS'
