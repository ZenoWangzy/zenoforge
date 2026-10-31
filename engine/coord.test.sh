#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

export ZF_COORD_RELEASED_RETAIN_SECONDS=3600
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/coord.sh"

fail() { printf 'coord.test.sh: %s\n' "$*" >&2; exit 1; }

now="$(date +%s)"
retain_seconds=3600
older="issue-81001"
inside="issue-81002"
live="issue-81003"
legacy="issue-81004"
malformed="issue-81005"

write_claim() {
  local key="$1" owner="$2" expires_at="$3" released_at="$4"
  jq -cn --arg key "$key" --arg owner "$owner" --arg released_at "$released_at" \
    --argjson now "$now" --argjson expires_at "$expires_at" \
    '{version:1,key:$key,owner:(if $owner=="" then null else $owner end),owner_kind:"test",
      subject:$key,unit:"test-unit",stage:"test",acquired_at:$now,renewed_at:$now,expires_at:$expires_at}
     + (if $released_at=="" then {} else
          {last_owner:"fixture-owner",released_at:($released_at|tonumber),release_reason:"released"}
        end)' > "$COORD_DIR/$key.json"
}

mkdir -p "$COORD_DIR"
write_claim "$older" "" 0 "$((now-retain_seconds-10))"
write_claim "$inside" "" 0 "$((now-retain_seconds+60))"
write_claim "$live" "owner-live" "$((now+600))" ""
write_claim "$legacy" "" 0 ""

coord_reap_expired || fail 'claim sweep failed'
[[ ! -e "$COORD_DIR/$older.json" ]] || fail 'released claim older than the retention window was not pruned'
[[ -e "$COORD_DIR/$older.lock" ]] || fail 'pruning removed the per-key lock file'
[[ -e "$COORD_DIR/$inside.json" ]] || fail 'released claim inside the retention window was pruned'
[[ -e "$COORD_DIR/$live.json" ]] || fail 'live claim was pruned'
[[ -e "$COORD_DIR/$legacy.json" ]] || fail 'claim without released_at was pruned'

if coord_read "$older" >/dev/null; then
  fail 'pruned claim did not read as absent before reacquire'
else
  rc=$?
  (( rc == 1 )) || fail "pruned claim read returned $rc instead of absent (1)"
fi
coord_acquire "$older" owner-after-prune test 81001 test-unit test \
  || fail 'claim could not be acquired after pruning'
coord_read "$older" >/dev/null || fail 'reacquired claim was not readable'

printf '{ malformed json\n' > "$COORD_DIR/$malformed.json"
if coord_reap_expired 2>/dev/null; then
  fail 'malformed claim did not keep the sweep fail-closed'
else
  rc=$?
  (( rc == 3 )) || fail "malformed claim sweep returned $rc instead of unknown (3)"
fi
[[ -e "$COORD_DIR/$malformed.json" ]] || fail 'malformed claim was removed'

printf 'coord.test.sh: PASS\n'
