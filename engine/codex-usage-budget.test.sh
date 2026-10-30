#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$test_env_root"
trap 'rm -rf "$TMP"' EXIT
export AGENT_HOME="$TMP/agent"
export CODEX_DAILY_TOKEN_BUDGET=8000000
export CODEX_PRODUCTION_TOKEN_RESERVE=2000000
export CODEX_BUDGET_RESERVATION_TOKENS=2200000
export CODEX_PRODUCTION_RESERVATION_TOKENS=1000000
source "$ROOT/engine/lib.sh"

pass=0
fail=0
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s (expected [%s], got [%s])\n' "$name" "$expected" "$actual" >&2
    fail=$((fail + 1))
  fi
}
assert_true() {
  local name="$1"; shift
  if "$@"; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    fail=$((fail + 1))
  fi
}
assert_reserve_status() {
  local name="$1" expected="$2" status=0
  shift 2
  codex_budget_reserve "$@" >/dev/null 2>&1 || status=$?
  assert_eq "$name" "$expected" "$status"
}

now="$(date +%s)"
output_file="$TMP/fake-codex.log"
printf '%s\n' 'finished' 'tokens used' '5,900,123' > "$output_file"
assert_eq 'fake Codex tokens used output parses with separators' 5900123 "$(codex_tokens_used "$output_file")"

assert_eq 'first concurrent work reservation accepted' 0 "$(codex_budget_reserve work test-a 2>/dev/null; echo $?)"
assert_eq 'second concurrent work reservation accepted' 0 "$(codex_budget_reserve work test-b 2>/dev/null; echo $?)"
assert_reserve_status 'third work reservation throttled at work ceiling' 75 work test-c
codex_budget_release test-a
codex_budget_release test-b
assert_eq 'hand dispatch reserves remaining work slice by default' 6000000 "$CODEX_HAND_DISPATCH_RESERVATION_TOKENS"
assert_eq 'first large hand dispatch reserve accepted' 0 "$(codex_budget_reserve work hand-a "$CODEX_HAND_DISPATCH_RESERVATION_TOKENS" 2>/dev/null; echo $?)"
assert_reserve_status 'second large hand dispatch is throttled while first is active' 75 work hand-b "$CODEX_HAND_DISPATCH_RESERVATION_TOKENS"
assert_eq 'production incident reserve remains available during hand dispatch' 0 "$(codex_budget_reserve production incident-a 1000000 2>/dev/null; echo $?)"
codex_budget_release hand-a
codex_budget_release incident-a

work_identity="$(model_policy identity work)"
record_premium_spend implement "$work_identity" 123 '' "$now" 5900123
assert_reserve_status 'work stays below hard limit but cannot reserve another dispatch' 75 work test-after-spend
production_identity="$(model_policy identity production)"
assert_eq 'production reserve remains available to production role' 0 "$(codex_budget_reserve production test-production 2>/dev/null; echo $?)"
codex_budget_release test-production

IFS=$'\t' read -r verdict used limit projected work_used production_used reserved reset_at \
  <<< "$(codex_budget_status "$now")"
assert_eq 'budget health turns SLOW at 70 percent' SLOW "$verdict"
assert_eq 'budget health reports actual tokens used' 5900123 "$used"
assert_eq 'budget health reports configured account budget' 8000000 "$limit"
assert_eq 'budget health reports production role usage' 0 "$production_used"

record_premium_spend production "$production_identity" node-auto-owner '' "$now" 2099877
IFS=$'\t' read -r verdict used limit projected work_used production_used reserved reset_at \
  <<< "$(codex_budget_status "$now")"
assert_eq 'budget health turns BROKEN at configured limit' BROKEN "$verdict"
assert_eq 'budget health total includes work and production roles' 8000000 "$used"

read -r reset_month reset_day reset_year < <(date -d "@$((now + 172800))" '+%b %-d %Y')
case "$reset_day" in
  1|21|31) reset_ordinal=st ;;
  2|22) reset_ordinal=nd ;;
  3|23) reset_ordinal=rd ;;
  *) reset_ordinal=th ;;
esac
usage_limit="ERROR: You’ve hit your usage limit. Try again at $reset_month ${reset_day}${reset_ordinal}, $reset_year 1:13 AM"
usage_limit_output="$TMP/fake-codex-usage-limit.log"
printf '%s\n' "$usage_limit" > "$usage_limit_output"
usage_limit="$(cat "$usage_limit_output")"
# Pipeline suites run with LC_ALL=C. Keep both CLI apostrophe spellings covered
# under that locale so UTF-8 matching cannot regress on the CI runner image.
export LC_ALL=C
assert_true 'fake Codex usage-limit output with curly apostrophe is a quota refusal' premium_call_is_quota_refused "$usage_limit" 1
ascii_usage_limit="ERROR: You've hit your usage limit. Try again at $reset_month ${reset_day}${reset_ordinal}, $reset_year 1:13 AM"
assert_true 'fake Codex usage-limit output with ASCII apostrophe is a quota refusal' premium_call_is_quota_refused "$ascii_usage_limit" 1
expected_reset="$(agent_epoch "$reset_month $reset_day, $reset_year 1:13 AM")"
assert_eq 'Codex usage-limit reset time parses from error text' "$expected_reset" "$(parse_quota_reset_epoch "$usage_limit")"
note_provider_quota_exhausted codex '' "$usage_limit" >/dev/null 2>&1
marker="$(_quota_marker_file codex)"
assert_eq 'usage-limit message holds Codex until stated reset' "$expected_reset" "$(cat "$marker")"
assert_reserve_status 'usage-limit hold blocks launches until reset time' 75 work test-usage-hold
fault_file="$ENV_FAULT_DIR/$(env_fault_key env:codex-usage-limit).log"
assert_true 'usage-limit message records reset in environment fault ledger' grep -q 'env:codex-usage-limit.*reset' "$fault_file"

# 2026-10-11: shipped defaults (8M/day, one hand reserving the whole 6M work share) refused every hand
# dispatch. The defaults must leave room for at least ten concurrent hand reservations.
default_hand_slots="$(env -u CODEX_DAILY_TOKEN_BUDGET -u CODEX_PRODUCTION_TOKEN_RESERVE -u CODEX_HAND_DISPATCH_RESERVATION_TOKENS \
  AGENT_HOME="$TMP/defaults-agent" bash -c 'source "$1/engine/lib.sh" >/dev/null 2>&1
    echo $(( (CODEX_DAILY_TOKEN_BUDGET - CODEX_PRODUCTION_TOKEN_RESERVE) / CODEX_HAND_DISPATCH_RESERVATION_TOKENS ))' _ "$ROOT")"
assert_true 'default budget admits at least ten concurrent hand reservations' test "${default_hand_slots:-0}" -ge 10

printf 'RESULTS: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
