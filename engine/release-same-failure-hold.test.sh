#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT
AGENT_HOME="$test_env_root/agent"
REPO_DIR="$test_env_root/repo"
UNIT_PREFIX_TRANSIENT=zf
mkdir -p "$AGENT_HOME" "$REPO_DIR"
FILE="$AGENT_HOME/release-batch-outcomes"
LINE='run-release: Fruit V4 workbench publication credential could not be loaded'
OTHER='run-release: release.json is missing: /x'

# Stubs: the decision and the alert are recorded, and the journal is a file the case writes.
record_release_decision() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$5" >> "$AGENT_HOME/decisions"; }
supervisor_inbox_append_once() { printf '%s\n' "$1" >> "$AGENT_HOME/inbox-keys"; }
journalctl() { cat "$AGENT_HOME/journal-stub"; }
source "$SCRIPT_DIR/lib.d/release-walk.sh"

assert_eq() {
  [ "$2" = "$3" ] || { echo "FAIL $1: expected [$2] got [$3]" >&2; exit 1; }
  echo "ok - $1"
}
row() { printf '1700000000\t%s\t%s\t%s\n' "$1" "$2" "$3"; }
set_rows() { : > "$FILE"; for r in "$@"; do printf '%s\n' "$r" >> "$FILE"; done; }
reset() { rm -f "$AGENT_HOME/decisions" "$AGENT_HOME/inbox-keys" "$FILE"; : > "$AGENT_HOME/journal-stub"; }

# Repository: BASE is the failed batch, DOCS changes only README, FIX changes scripts/release.
git -C "$REPO_DIR" init -q
git_in() { git -C "$REPO_DIR" -c user.name=test -c user.email=test@example.invalid "$@"; }
mkdir -p "$REPO_DIR/scripts/release"
echo one > "$REPO_DIR/scripts/release/x"; git_in add -A; git_in commit -q -m base
BASE="$(git_in rev-parse HEAD)"
echo two > "$REPO_DIR/README"; git_in add -A; git_in commit -q -m docs
DOCS="$(git_in rev-parse HEAD)"
echo three > "$REPO_DIR/scripts/release/x"; git_in add -A; git_in commit -q -m fix
FIX="$(git_in rev-parse HEAD)"

# (a) two failures on one line, candidate changes nothing under scripts/release: hold
reset
set_rows "$(row "$DOCS" failed "$LINE")" "$(row "$BASE" failed "$LINE")"
rc=0; release_batch_same_failure_hold "$DOCS" 910101 || rc=$?
assert_eq 'same line twice and no scripts/release change: hold' 0 "$rc"
assert_eq 'the hold logs one decision' 1 "$(wc -l < "$AGENT_HOME/decisions")"
assert_eq 'the hold alerts once, keyed by the line and the candidate' 1 "$(wc -l < "$AGENT_HOME/inbox-keys")"

# (b) same two failures, candidate changes scripts/release: no hold
reset
set_rows "$(row "$DOCS" failed "$LINE")" "$(row "$BASE" failed "$LINE")"
rc=0; release_batch_same_failure_hold "$FIX" 910101 || rc=$?
assert_eq 'scripts/release changed since the failed batch: no hold' 1 "$rc"

# (c) two failures on different lines: no hold
reset
set_rows "$(row "$DOCS" failed "$OTHER")" "$(row "$BASE" failed "$LINE")"
rc=0; release_batch_same_failure_hold "$DOCS" 910101 || rc=$?
assert_eq 'different error lines: no hold' 1 "$rc"

# (d) one finished batch only: no hold
reset
set_rows "$(row "$BASE" failed "$LINE")"
rc=0; release_batch_same_failure_hold "$DOCS" 910101 || rc=$?
assert_eq 'one batch only: no hold' 1 "$rc"

# (e) the git read fails (unknown candidate sha, then no repository): no hold
reset
set_rows "$(row "$DOCS" failed "$LINE")" "$(row "$BASE" failed "$LINE")"
rc=0; release_batch_same_failure_hold 0123456789012345678901234567890123456789 910101 || rc=$?
assert_eq 'git read of an unknown candidate fails closed: no hold' 1 "$rc"
REPO_DIR="$test_env_root/absent"
rc=0; release_batch_same_failure_hold "$DOCS" 910101 || rc=$?
REPO_DIR="$test_env_root/repo"
assert_eq 'missing repository fails closed: no hold' 1 "$rc"

# (f) the newest row is pending: its unit ended with a failed run, so it settles and holds
reset
set_rows "$(row "$DOCS" failed "$LINE")" "$(printf '1700000000\t%s\tpending\t\n' "$BASE")"
printf '%s\n' "$LINE" "zf-release-batch.service: Failed with result 'exit-code'." > "$AGENT_HOME/journal-stub"
rc=0; release_batch_same_failure_hold "$DOCS" 910101 || rc=$?
assert_eq 'a pending row whose run failed settles and holds' 0 "$rc"
assert_eq 'the settled row records failed and the run-release line' "failed|$LINE" "$(tail -n 1 "$FILE" | cut -f3,4 --output-delimiter='|')"

# (g) pending row with no end line in the journal settles unknown and never holds
reset
set_rows "$(row "$DOCS" failed "$LINE")" "$(printf '1700000000\t%s\tpending\t\n' "$BASE")"
rc=0; release_batch_same_failure_hold "$DOCS" 910101 || rc=$?
assert_eq 'no end line settles unknown: no hold' 1 "$rc"
assert_eq 'unknown is recorded as unknown' unknown "$(tail -n 1 "$FILE" | cut -f3)"

# (h) a long run-release line is cut to 120 characters when settled
reset
set_rows "$(printf '1700000000\t%s\tpending\t\n' "$BASE")"
long="run-release: $(printf 'x%.0s' {1..200})"
printf '%s\n' "$long" "zf-release-batch.service: Failed with result 'exit-code'." > "$AGENT_HOME/journal-stub"
release_batch_outcome_settle
assert_eq 'the stored run-release line is cut to 120 characters' 120 "$(tail -n 1 "$FILE" | cut -f4 | wc -c | awk '{print $1 - 1}')"

# (i) a new batch start appends a pending row with its sha
reset
release_batch_outcome_start "$FIX"
assert_eq 'a batch start appends a pending row with its commit' "$FIX|pending" "$(tail -n 1 "$FILE" | cut -f2,3 --output-delimiter='|')"

# (j) a malformed row among the last two: no hold, and the caller keeps running (a non-zero return, not an exit)
reset
set_rows "$(row "$DOCS" failed "$LINE")" "not-a-row"
rc=0; release_batch_same_failure_hold "$DOCS" 910101 || rc=$?
assert_eq 'a malformed outcome row gives no hold and the caller survives' 1 "$rc"
set_rows "not-a-row"
rc=0; release_batch_same_failure_hold "$DOCS" 910101 || rc=$?
assert_eq 'an outcome file with only a malformed row gives no hold' 1 "$rc"

# (k) an unset AGENT_HOME inside the hold: no hold, and the caller survives
rc=0; ( unset AGENT_HOME; release_batch_same_failure_hold "$DOCS" 910101 ) || rc=$?
assert_eq 'an unset AGENT_HOME gives no hold' 1 "$rc"

# (l) DRY_RUN=1: a batch start writes no outcome row
reset
( DRY_RUN=1; release_batch_outcome_start "$FIX" )
assert_eq 'a dry run writes no outcome row' no "$( [ -e "$FILE" ] && echo yes || echo no )"

echo 'all same-failure hold cases passed'
