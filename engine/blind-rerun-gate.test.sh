#!/usr/bin/env bash
# blind-rerun-gate.test.sh -- implement_blind_rerun_gate (lib.sh).
# Issue 2695 ran implement four times to the same BLOCKED-CHECKS network
# timeout and 2731 four times to the same lesson delivery refusal; a third run
# of the same issue/stage/failure class must need a changed input, otherwise
# the ticket is parked once with its decisive reason.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FIXTURE_REPO="$TMPDIR/repo"
git init -q --bare -b main "$TMPDIR/origin.git"
git init -q -b main "$FIXTURE_REPO"
git -C "$FIXTURE_REPO" config user.name test
git -C "$FIXTURE_REPO" config user.email test@example.invalid
mkdir -p "$FIXTURE_REPO/engine" "$FIXTURE_REPO/infra/example-ui" "$FIXTURE_REPO/docs"
printf 'base\n' > "$FIXTURE_REPO/engine/dispatch-codex.sh"
printf 'base\n' > "$FIXTURE_REPO/infra/example-ui/thinking.test.mjs"
printf 'base\n' > "$FIXTURE_REPO/docs/unrelated.md"
git -C "$FIXTURE_REPO" add -A
GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' \
  git -C "$FIXTURE_REPO" commit -qm base
git -C "$FIXTURE_REPO" remote add origin "$TMPDIR/origin.git"
git -C "$FIXTURE_REPO" push -q origin main
git -C "$FIXTURE_REPO" fetch -q origin
export ZF_REPO_DIR="$FIXTURE_REPO"
source "$SCRIPT_DIR/lib.sh"
REPO_DIR="$FIXTURE_REPO"
REPO=test/repo
FAILED=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "ok - $desc"; else echo "not ok - $desc (expected [$expected], got [$actual])"; FAILED=1; fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "ok - $desc"; else echo "not ok - $desc (missing [$needle])"; FAILED=1; fi
}

main_commit() {
  local file="$1" at="$2"
  printf '%s\n' "$at" >> "$FIXTURE_REPO/$file"
  git -C "$FIXTURE_REPO" add -A
  GIT_COMMITTER_DATE="$at" GIT_AUTHOR_DATE="$at" git -C "$FIXTURE_REPO" commit -qm "change $file"
  git -C "$FIXTURE_REPO" push -q origin main
  git -C "$FIXTURE_REPO" fetch -q origin
}

# Fakes: GitHub comments come from FAKE_COMMENTS_JSON; writes are recorded.
FAKE_COMMENTS_JSON='[]'
COMMENTS_LOG="$TMPDIR/comments.log"; : > "$COMMENTS_LOG"
HOLDS_LOG="$TMPDIR/holds.log"; : > "$HOLDS_LOG"
: > "$AGENT_HOME/supervisor-inbox"
gh() {
  if [ "${1:-} ${2:-}" = "api repos/test/repo/issues/$GATE_ISSUE/comments" ]; then
    [ "${FAKE_GH_FAIL:-0}" = 0 ] || return 1
    jq -c '.[] | {created_at, body}' <<< "$FAKE_COMMENTS_JSON"
    return 0
  fi
  return 1
}
guarded_issue_comment() {
  printf '%s\n' "$2" >> "$COMMENTS_LOG"
  FAKE_COMMENTS_JSON="$(jq -c --arg body "$2" '. + [{created_at:"2026-01-03T00:00:00Z",body:$body}]' <<< "$FAKE_COMMENTS_JSON")"
}
hold_issue() { printf '%s\n' "$*" >> "$HOLDS_LOG"; }

gate() {
  GATE_STATUS=0
  implement_blind_rerun_gate "$GATE_ISSUE" 2>/dev/null || GATE_STATUS=$?
}

BLOCKED1='`node infra/example-ui/thinking.test.mjs` — fetch failed: ConnectTimeoutError (185.199.110.133:443, timeout 10000ms)'
BLOCKED2='`node infra/example-ui/thinking.test.mjs` — `TypeError: fetch failed; ConnectTimeoutError`，连接固定版本源码 `185.199.108.133:443` 超时。'

# 1. issue 2695 shape: two checks-blocked runs, model-worded differently.
GATE_ISSUE=1902695
state_merge "$GATE_ISSUE" "$(jq -cn --arg r1 "$BLOCKED1" --arg r2 "$BLOCKED2" '{
  expected_paths:["infra/example-ui/thinking.test.mjs"],
  model_policy:{unit:"implement",step:"work",
    history:[{unit:"implement",step:"work",requeued:true,failure:{unit:"implement",stage:"checks-blocked",reason:$r1,recorded_at:"2026-01-02T00:00:00Z"}}],
    failure:{unit:"implement",stage:"checks-blocked",reason:$r2,recorded_at:"2026-01-02T06:00:00Z"}}}')" >/dev/null
gate
assert_eq "two same-class environmental blocks and no changed input park the ticket" 0 "$GATE_STATUS"
assert_contains "the supervisor inbox gets the decisive reason" "$(cat "$AGENT_HOME/supervisor-inbox")" \
  'blind-rerun issue=#1902695 stage=checks-blocked'
assert_contains "the inbox line names the failing command" "$(cat "$AGENT_HOME/supervisor-inbox")" \
  'node infra/example-ui/thinking.test.mjs'
assert_contains "the ticket comment carries the decisive reason" "$(cat "$COMMENTS_LOG")" 'ConnectTimeoutError'
assert_contains "the ticket is put on hold by the gate" "$(cat "$HOLDS_LOG")" '--holder blind-rerun-gate'
gate
assert_eq "the parked ticket stays parked on the next tick" 0 "$GATE_STATUS"
assert_eq "the inbox line is written once" 1 "$(grep -c 'blind-rerun issue=#1902695' "$AGENT_HOME/supervisor-inbox")"
assert_eq "the comment is posted once" 1 "$(grep -c 'zf-blind-rerun issue=#1902695' "$COMMENTS_LOG")"

# 2. A main commit touching only unrelated paths is no new input.
main_commit docs/unrelated.md '2026-01-02T08:00:00Z'
gate
assert_eq "an unrelated main commit does not reopen dispatch" 0 "$GATE_STATUS"

# 3. A run-environment carrier changed on main after the failure: rerun allowed.
main_commit engine/dispatch-codex.sh '2026-01-02T09:00:00Z'
gate
assert_eq "an environment change on main lets the third run go" 1 "$GATE_STATUS"

# 4. A commit touching the failing area (named in the failure) also counts.
GATE_ISSUE=1902696
state_merge "$GATE_ISSUE" "$(jq -cn --arg r1 "$BLOCKED1" --arg r2 "$BLOCKED2" '{
  model_policy:{failures:[{unit:"implement",stage:"checks-blocked",reason:$r1,recorded_at:"2026-01-02T10:00:00Z"},
    {unit:"implement",stage:"checks-blocked",reason:$r2,recorded_at:"2026-01-02T11:00:00Z"}]}}')" >/dev/null
gate
assert_eq "same-class pair recorded in model_policy.failures is gated" 0 "$GATE_STATUS"
main_commit infra/example-ui/thinking.test.mjs '2026-01-02T12:00:00Z'
gate
assert_eq "a main commit touching the failing test lets the run go" 1 "$GATE_STATUS"

# 5. issue 2731 shape: the same lesson refusal twice, the first moved into
# history by a requeue. A pipeline bot comment is not new input; a human one is.
REFUSAL=$'pipeline-system direct-main delivery failed for issue #2731\nFrom $HOME/wt/issue-2731\nshared lesson delivery must add rule, catalog entry, and incident guard together'
GATE_ISSUE=1902731
FAKE_COMMENTS_JSON="$(jq -cn --arg body "$BOT_DISCLAIMER
Pipeline progress note" '[{created_at:"2026-01-04T01:00:00Z",body:$body}]')"
state_merge "$GATE_ISSUE" "$(jq -cn --arg r "$REFUSAL" '{
  pipeline_system:{enabled:true},
  model_policy:{history:[{unit:"implement",requeued:true,failure:{unit:"implement",stage:"pipeline-system-delivery",reason:$r,recorded_at:"2026-01-04T00:00:00Z"}}],
    failure:{unit:"implement",stage:"pipeline-system-delivery",reason:$r,recorded_at:"2026-01-04T00:30:00Z"}}}')" >/dev/null
gate
assert_eq "a repeated lesson refusal with only bot comments is parked" 0 "$GATE_STATUS"
FAKE_COMMENTS_JSON="$(jq -c '. + [{created_at:"2026-01-04T02:00:00Z",body:"Write the lesson as a fragment."}]' <<< "$FAKE_COMMENTS_JSON")"
gate
assert_eq "a human issue comment after the failure lets the run go" 1 "$GATE_STATUS"

# 6. Different failure classes, a single failure, a landing retry, a
# supervisor hold release, and an unreadable comment history.
GATE_ISSUE=1902732
FAKE_COMMENTS_JSON='[]'
state_merge "$GATE_ISSUE" "$(jq -cn --arg r "$REFUSAL" '{
  model_policy:{history:[{failure:{unit:"implement",stage:"pipeline-system-delivery",reason:$r,recorded_at:"2026-01-05T00:00:00Z"}}],
    failure:{unit:"implement",stage:"pipeline-system-delivery",reason:"could not apply pipeline-system diff for scripts/ci/x.test.mjs",recorded_at:"2026-01-05T01:00:00Z"}}}')" >/dev/null
gate
assert_eq "two different failure classes do not gate" 1 "$GATE_STATUS"
GATE_ISSUE=1902733
state_merge "$GATE_ISSUE" "$(jq -cn --arg r "$BLOCKED1" '{model_policy:{failure:{unit:"implement",stage:"checks-blocked",reason:$r,recorded_at:"2026-01-05T00:00:00Z"}}}')" >/dev/null
gate
assert_eq "a single failure does not gate" 1 "$GATE_STATUS"
GATE_ISSUE=1902734
state_merge "$GATE_ISSUE" "$(jq -cn --arg r1 "$BLOCKED1" --arg r2 "$BLOCKED2" '{
  pipeline_system:{landing_retry_sha:"0123456789abcdef0123456789abcdef01234567"},
  model_policy:{failures:[{unit:"implement",stage:"checks-blocked",reason:$r1,recorded_at:"2026-01-05T00:00:00Z"},
    {unit:"implement",stage:"checks-blocked",reason:$r2,recorded_at:"2026-01-05T01:00:00Z"}]}}')" >/dev/null
gate
assert_eq "a model-free landing retry is never gated" 1 "$GATE_STATUS"
state_merge "$GATE_ISSUE" 'del(.pipeline_system) | .hold_released_at = "2026-01-05T02:00:00Z"' >/dev/null
gate
assert_eq "a supervisor hold release after the failure lets the run go" 1 "$GATE_STATUS"
state_merge "$GATE_ISSUE" 'del(.hold_released_at)' >/dev/null
FAKE_GH_FAIL=1
gate
FAKE_GH_FAIL=0
assert_eq "an unreadable comment history skips the tick" 0 "$GATE_STATUS"
assert_eq "an unreadable comment history does not park" 0 "$(grep -c 'issue=#1902734' "$AGENT_HOME/supervisor-inbox" || true)"

# 7. A checks-blocked run lands in the model-policy failure records and
# survives the sweep's requeue, so the gate sees it on the next dispatch.
GATE_ISSUE=1902735
CODEX_SANDBOX_MODE=danger-full-access
roadmap_ensure_issue_parent() { return 0; }
is_on_hold() { return 1; }
ensure_state_labels() { :; }
guarded_write() { :; }
recut_parent_has_open_child() { return 1; }
WT_FIXTURE="$TMPDIR/wt"
git clone -q "$TMPDIR/origin.git" "$WT_FIXTURE"
git -C "$WT_FIXTURE" config user.name test
git -C "$WT_FIXTURE" config user.email test@example.invalid
BLOCK_LOG="$TMPDIR/implement.log"
printf 'BLOCKED-CHECKS: %s\n' "$BLOCKED1" > "$BLOCK_LOG"
state_merge "$GATE_ISSUE" '{"attempts":1,"model_policy":{"unit":"implement","step":"work"}}' >/dev/null
record_implement_blocked_checks "$GATE_ISSUE" "$WT_FIXTURE" "$BLOCK_LOG"
assert_eq "a checks-blocked run is recorded as an implement failure" checks-blocked \
  "$(state_read "$GATE_ISSUE" | jq -r '.model_policy.failure.stage')"
state_requeue "$GATE_ISSUE" >/dev/null 2>&1
assert_eq "the checks-blocked failure survives requeue in model-policy history" 1 \
  "$(implement_failure_records "$(state_read "$GATE_ISSUE")" | jq 'length')"
printf 'BLOCKED-CHECKS: %s\n' "$BLOCKED2" > "$BLOCK_LOG"
git -C "$WT_FIXTURE" commit -q --allow-empty -m 'run 2'
record_implement_blocked_checks "$GATE_ISSUE" "$WT_FIXTURE" "$BLOCK_LOG"
state_requeue "$GATE_ISSUE" >/dev/null 2>&1
gate
assert_eq "the third dispatch after two identical blocks is parked" 0 "$GATE_STATUS"

[ "$FAILED" -eq 0 ] || { echo FAILED; exit 1; }
echo "ALL PASSED"
