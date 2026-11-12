#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/log-shape-classes.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT
export ZF_GH_REPO=test/repo
export ZF_LOG_SHAPE_CONFIG="$tmp/log-shapes.json"
export GH_FAKE_STATE="$tmp/gh"
mkdir -p "$tmp/bin" "$tmp/logs" "$GH_FAKE_STATE"
echo '[]' > "$GH_FAKE_STATE/issues.json"

# Fake gh: lists and creates issues in a JSON file, and records every call.
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
state="$GH_FAKE_STATE"
echo "$*" >> "$state/calls"
case "$1 $2" in
  "issue list")
    query=""
    while [[ $# -gt 0 ]]; do [[ "$1" == --search ]] && query="${2% in:title}"; shift; done
    jq --arg q "$query" '[.[] | select(.title | contains($q))]' "$state/issues.json"
    ;;
  "issue create")
    title=""; body=""
    while [[ $# -gt 0 ]]; do [[ "$1" == --title ]] && title="$2"; [[ "$1" == --body ]] && body="$2"; shift; done
    n=$(( $(jq 'length' "$state/issues.json") + 1 ))
    jq --argjson n "$n" --arg t "$title" --arg b "$body" '. + [{number:$n,title:$t,body:$b,state:"OPEN"}]' "$state/issues.json" > "$state/issues.next"
    mv "$state/issues.next" "$state/issues.json"
    echo "https://example.test/issues/$n"
    ;;
  "issue comment") echo "comment $3" >> "$state/comments" ;;
  "issue reopen") : ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
class_of() { printf 'cls-%s' "$(printf '%s' "$1" | shasum -a 256 | cut -c1-12)"; }

# Explicit config: the signature names what files; the allowlist names routine shapes.
cat > "$ZF_LOG_SHAPE_CONFIG" <<'JSON'
{"threshold":20,"signatures":["widget <n> failed"],"allowlist":["heartbeat ok"]}
JSON

# Non-allowlisted failure shape above threshold, with varying ids and timestamps.
: > "$tmp/logs/engine.log"
for i in $(seq 1 25); do
  printf 'ERROR widget %d failed for ticket %d at 2026-11-12T01:%02d:00Z\n' "$((i * 7))" "$((i + 900))" "$i" >> "$tmp/logs/engine.log"
done
# Allowlisted routine shape at high volume.
for i in $(seq 1 60); do printf 'heartbeat ok seq %d\n' "$i" >> "$tmp/logs/engine.log"; done
# Below-threshold failure, same log: nothing files.
printf 'ERROR gadget 1 failed\n' >> "$tmp/logs/engine.log"
# scheduler.log is out of scope even when it matches.
for i in $(seq 1 30); do printf 'ERROR widget %d failed\n' "$i" >> "$tmp/logs/scheduler.log"; done

rc=0; bash "$script" "$tmp/logs/engine.log" "$tmp/logs/scheduler.log" || rc=$?
echo "first run rc=$rc"
[[ "$rc" -eq 0 ]] || { echo 'FAIL: first run returned nonzero' >&2; exit 1; }
[[ "$(jq 'length' "$GH_FAKE_STATE/issues.json")" -eq 1 ]] || { echo 'FAIL: first run must file exactly one issue' >&2; exit 1; }
title="$(jq -r '.[0].title' "$GH_FAKE_STATE/issues.json")"
[[ "$title" == "Repeated log shape $(class_of 'ERROR widget <n> failed for ticket <n> at')" ]] \
  || { echo "FAIL: issue title is not the engine class id: $title" >&2; exit 1; }
body="$(jq -r '.[0].body' "$GH_FAKE_STATE/issues.json")"
[[ "$body" == *'Count: 25 occurrences'* ]] || { echo "FAIL: issue body lacks the count: $body" >&2; exit 1; }
[[ "$body" != *'failed for ticket'* ]] || { echo 'FAIL: issue body carries a raw masked shape' >&2; exit 1; }
grep -q "$(class_of 'heartbeat ok seq <n>')" "$GH_FAKE_STATE/issues.json" && { echo 'FAIL: allowlisted routine shape filed an issue' >&2; exit 1; }
grep -q "$(class_of 'ERROR gadget <n> failed')" "$GH_FAKE_STATE/issues.json" && { echo 'FAIL: below-threshold shape filed an issue' >&2; exit 1; }
grep -q "$(class_of 'ERROR widget <n> failed')" "$GH_FAKE_STATE/issues.json" && { echo 'FAIL: scheduler.log shape was filed' >&2; exit 1; }
[[ "$(grep -c '^issue create' "$GH_FAKE_STATE/calls")" -eq 1 ]] || { echo 'FAIL: first run must create one issue' >&2; exit 1; }
echo 'ok - one class issue with class id and count, no raw shape; routine, below-threshold and scheduler.log files nothing'

# Second run with the same shape: updates the same issue, adds no new one.
rc=0; bash "$script" "$tmp/logs/engine.log" "$tmp/logs/scheduler.log" || rc=$?
[[ "$rc" -eq 0 ]] || { echo 'FAIL: second run returned nonzero' >&2; exit 1; }
[[ "$(jq 'length' "$GH_FAKE_STATE/issues.json")" -eq 1 ]] || { echo 'FAIL: second run added an issue' >&2; exit 1; }
[[ "$(grep -c '^issue create' "$GH_FAKE_STATE/calls")" -eq 1 ]] || { echo 'FAIL: second run created a second issue' >&2; exit 1; }
[[ "$(grep -c '^comment' "$GH_FAKE_STATE/comments")" -eq 1 ]] || { echo 'FAIL: second run did not update the existing issue' >&2; exit 1; }
echo 'ok - repeat run updates the same class issue and adds none'

# Closed class issue: a recurrence reopens it instead of filing a new one or staying silent.
jq '.[0].state = "CLOSED"' "$GH_FAKE_STATE/issues.json" > "$GH_FAKE_STATE/issues.next" && mv "$GH_FAKE_STATE/issues.next" "$GH_FAKE_STATE/issues.json"
rc=0; bash "$script" "$tmp/logs/engine.log" "$tmp/logs/scheduler.log" || rc=$?
[[ "$rc" -eq 0 ]] || { echo 'FAIL: closed-class run returned nonzero' >&2; exit 1; }
[[ "$(grep -c '^issue reopen' "$GH_FAKE_STATE/calls")" -eq 1 ]] || { echo 'FAIL: closed class issue was not reopened' >&2; exit 1; }
[[ "$(jq 'length' "$GH_FAKE_STATE/issues.json")" -eq 1 ]] || { echo 'FAIL: closed-class recurrence filed a new issue' >&2; exit 1; }
echo 'ok - recurrence of a closed class reopens its issue'
