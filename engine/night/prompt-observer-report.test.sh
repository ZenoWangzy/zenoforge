#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
script="$script_dir/prompt-observer-report.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT
runtime="$tmp/runtime"
mkdir -p "$runtime" "$tmp/bin"
cat > "$runtime/units.json" <<'JSON'
{"units":[
  {"id":"unit-1","stage":"merged","prompt":"engine/mac-autopilot/scheduler.d/dispatch-queue.sh","prompt_stage":"implement","prompt_version":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","history":[{"stage":"review-request-changes"},{"stage":"supervisor-approve"}],"review_findings":[{"prompt":"engine/prompts/review-contract.md","prompt_version":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","disposition_block":"ok","dispositions":[{"id":"F1","disposition":"disproved"},{"id":"F2","disposition":"fixed"}]},{"prompt":"engine/prompts/review-contract.md","prompt_version":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","disposition_block":"ok","dispositions":[{"id":"F3","disposition":"fixed"}]}]},
  {"id":"unit-2","stage":"merged","prompt":"engine/mac-autopilot/scheduler.d/dispatch-queue.sh","prompt_stage":"implement","prompt_version":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","history":[{"stage":"review-approve"}],"review_findings":[{"prompt":"engine/prompts/review-contract.md","prompt_version":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","disposition_block":"ok","dispositions":[{"id":"F4","disposition":"fixed"},{"id":"F5","disposition":"fixed"}]}]},
  {"id":"pending","stage":"review-pending","prompt":"triage","history":[{"stage":"review-approve"}]}
]}
JSON
cp "$runtime/units.json" "$tmp/units.json.original"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_GH_CALLS"
exit 1
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" TEST_GH_CALLS="$tmp/gh.calls"

run_report() {
  MAC_AUTOPILOT_RUNTIME_DIR="$runtime" ZF_REPO_DIR="$tmp/no-repo" \
    PROMPT_OBSERVER_REPORT="$tmp/report.jsonl" PROMPT_OBSERVER_SAMPLE_RATE="${1:-1}" \
    PROMPT_OBSERVER_MIN_SAMPLES="${2:-5}" bash "$script"
}

run_report 1 2 > /dev/null
jq -s -e 'length == 3 and .[0].stage == "merged" and .[0].prompt == "engine/mac-autopilot/scheduler.d/dispatch-queue.sh" and
  .[0].prompt_stage == "implement" and .[0].prompt_version == "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" and
  .[0].sample_size == 2 and (.[0].score > 0.83 and .[0].score < 0.84) and
  .[0].unit_ids == ["unit-1","unit-2"] and (.[0] | has("status") | not) and
  .[1].stage == "review" and .[1].prompt_stage == "review" and .[1].prompt == "engine/prompts/review-contract.md" and
  .[1].prompt_version == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  .[1].sample_size == 2 and .[1].score == 0.75 and .[1].disproved_share == 0.25 and
  .[1].disproved_findings.disproved == 1 and .[1].disproved_findings.total == 4 and
  .[1].unit_ids == ["unit-1","unit-2"] and (.[1] | has("status") | not) and
  .[2].prompt_version == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
  .[2].sample_size == 1 and .[2].status == "insufficient-data" and (.[2] | has("score") | not) and
  .[2].disproved_findings.disproved == 0 and .[2].disproved_findings.total == 1 and
  .[2].unit_ids == ["unit-1"]' "$tmp/report.jsonl" >/dev/null

# One below the boundary reports insufficient data and omits score.
run_report 1 3 > /dev/null
jq -s -e 'length == 3 and .[0].sample_size == 2 and .[0].status == "insufficient-data" and
  (.[0] | has("score") | not) and .[0].unit_ids == ["unit-1","unit-2"]' "$tmp/report.jsonl" >/dev/null

# A zero rate samples no finished unit; unfinished units never enter the report.
run_report 0 1 > /dev/null
[[ ! -s "$tmp/report.jsonl" ]]
cmp "$runtime/units.json" "$tmp/units.json.original"
[[ ! -e "$TEST_GH_CALLS" ]]
