#!/usr/bin/env bash
# Repeated stall class -> one upsert, rate limited, counters only.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$AGENT_HOME/logs"
calls="$tmp/calls"; : > "$calls"
cat > "$tmp/upsert" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
for ((i=1;i<=$#;i++)); do [[ "${!i}" == --body-file ]] && j=$((i+1)) && cat -- "${!j}" >> "$FAKE_BODIES"; done
[[ "${FAKE_FAIL:-0}" != 1 ]]
FAKE
chmod +x "$tmp/upsert"
export FAKE_CALLS="$calls" FAKE_BODIES="$tmp/bodies" ZF_STALL_UPSERT="$tmp/upsert" ZF_STALL_NOW=1793800000
: > "$FAKE_BODIES"
day="$(date -u -d @1793800000 +%F)"
row() { printf '{"at":"%s","kind":"%s","targets":[],"state":"","decision":"wake"}\n' "$1" "$2"; }
{
  for m in 10 11 12 13 14; do row "${day}T00:0$((m-10)):00Z" ownerless-hold; done
  for m in 1 2 3 4; do row "${day}T00:0${m}:00Z" repeat-dispatch; done  # under threshold
  for m in 1 2 3 4 5 6; do row "${day}T00:0${m}:00Z" unit-harvest; done  # not a stall kind
  echo 'not json'
} > "$AGENT_HOME/logs/supervisor-alerts-$day.jsonl"

run() { bash "$SCRIPT_DIR/engine-stall-issue.sh"; }

run
[[ "$(wc -l < "$calls" | tr -d ' ')" == 1 ]]
grep -Fq -- '--class engine-stall-ownerless-hold ' "$calls"
grep -Fq -- '--repo ZenoWangzy/zenoforge' "$calls"
grep -Fq 'Occurrences in the last 86400s: 5' "$FAKE_BODIES"
grep -Fq "First seen: ${day}T00:00:00Z" "$FAKE_BODIES"
grep -Fq "Last seen: ${day}T00:04:00Z" "$FAKE_BODIES"
echo 'ok - repeated stall kind files one upsert with counters; quiet and non-stall kinds do not'

ZF_STALL_NOW=1793800100 run
[[ "$(wc -l < "$calls" | tr -d ' ')" == 1 ]]
echo 'ok - min gap blocks a second attempt'

ZF_STALL_NOW=1793800700 run
[[ "$(wc -l < "$calls" | tr -d ' ')" == 1 ]]
echo 'ok - class cooldown blocks a re-file after the gap'

ZF_STALL_NOW=$((1793800000 + 21600)) run
[[ "$(wc -l < "$calls" | tr -d ' ')" == 2 ]]
echo 'ok - class files again after the cooldown'

rm -f "$AGENT_HOME/state/engine-stall-issue.json"
FAKE_FAIL=1 run 2>/dev/null
[[ "$(wc -l < "$calls" | tr -d ' ')" == 3 ]]
jq -e '.last_attempt == 1793800000 and (.classes | length) == 0' "$AGENT_HOME/state/engine-stall-issue.json" >/dev/null
FAKE_FAIL=1 ZF_STALL_NOW=1793800100 run 2>/dev/null
[[ "$(wc -l < "$calls" | tr -d ' ')" == 3 ]]
echo 'ok - a failed upsert backs off and is retried after the gap'
