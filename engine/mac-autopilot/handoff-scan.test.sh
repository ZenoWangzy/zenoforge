#!/usr/bin/env bash
# existing_handoff_candidates reads one state file per issue; only files that name a handoff can select, so only those may cost a process.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fixture="$test_env_root/handoff-scan"
AGENT_HOME="$fixture/agent-home"
A="$fixture/autopi"
LOG="$A/scheduler.log"
STAMP=2026-11-07T00:00:00Z
mkdir -p "$AGENT_HOME/state" "$A"
: > "$LOG"

source "$script_dir/scheduler.d/core.sh"
source "$script_dir/scheduler.d/intake-steps.sh"
source "$script_dir/scheduler.d/intake-index.sh"
source "$script_dir/scheduler.d/intake.sh"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

state="$AGENT_HOME/state"
for n in $(seq 100 139); do printf '{"state":"awaiting-release"}\n' > "$state/$n.json"; done
printf '{"state":"ready-for-agent","scheduler_handoff":{"episode":"e1"}}\n' > "$state/141.json"
printf '{"state":"ready-for-agent","scheduler_handoff":{"episode":""}}\n' > "$state/142.json"
printf '{"state":"awaiting-release","scheduler_handoff":{"episode":"e3"}}\n' > "$state/143.json"
printf '{"state":"ready-for-agent","scheduler_handoff":{"episode":"e4"}}\n' > "$state/144.json"

reads_file="$fixture/reads"; : > "$reads_file"
eval "$(declare -f jqf_optional_file | sed '1s/^jqf_optional_file/jqf_optional_file_real/')"
jqf_optional_file() { printf x >> "$reads_file"; jqf_optional_file_real "$@"; } # a file, not a counter: the scan runs in $( )

rows="$(existing_handoff_candidates)" || fail 'scan failed on valid state files'
[[ "$(cut -f1 <<<"$rows" | paste -sd, -)" == 141,144 ]] || fail "wrong rows: $(cut -f1 <<<"$rows" | paste -sd, -)"
# 44 files: the 4 that carry the key may be read, the 40 that do not must not be.
reads="$(wc -c < "$reads_file")"
(( reads <= 4 )) || fail "scan read $reads state files; only the 4 naming a handoff may be read"

printf '{invalid\n' > "$state/145.json"
: > "$reads_file"
if existing_handoff_candidates >/dev/null 2>&1; then fail 'a malformed state file no longer fails the scan'; fi
grep -Fq 'jqf error' "$LOG" || fail 'the malformed file lost its jqf diagnostic'
reads="$(wc -c < "$reads_file")"
(( reads >= 45 )) || fail "the malformed-file path must keep reading every file (read $reads)"

echo 'ok - handoff scan reads only files that name a handoff; a malformed file still fails loudly'
