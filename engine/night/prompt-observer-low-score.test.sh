#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
script="$script_dir/prompt-observer-low-score.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT

cat > "$tmp/upsert" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_UPSERT_CALLS"
while (($#)); do
  if [[ "$1" == --body-file ]]; then
    cat -- "$2" >> "$TEST_UPSERT_BODIES"
    printf '\n---\n' >> "$TEST_UPSERT_BODIES"
    break
  fi
  shift
done
SH
chmod +x "$tmp/upsert"
export TEST_UPSERT_CALLS="$tmp/upsert-calls" TEST_UPSERT_BODIES="$tmp/upsert-bodies"

report="$tmp/report.jsonl"
state="$tmp/state.json"
write_low_report() {
  jq -cn --argjson score "${1:-0.4}" '{stage:"triage",prompt:"engine/prompts/triage.md",sample_size:3,
    score:$score,unit_ids:["unit-101","unit-102"],customer_data:"must-not-appear"}' > "$report"
}
run_report() {
  PROMPT_OBSERVER_LOW_SCORE_THRESHOLD=0.5 PROMPT_OBSERVER_LOW_SCORE_REPORTS=2 \
    PROMPT_OBSERVER_LOW_SCORE_STATE="$state" PROMPT_OBSERVER_LOW_SCORE_UPSERT="$tmp/upsert" \
    ZF_REPO=test/repo bash "$script" --report "$report"
}

# The first low report only starts the streak; the second opens an issue with public-safe evidence.
write_low_report
run_report >/dev/null
[[ ! -s "$TEST_UPSERT_CALLS" ]]
run_report >/dev/null
[[ "$(wc -l < "$TEST_UPSERT_CALLS")" == 1 ]]
grep -Fq -- '--lane product' "$TEST_UPSERT_CALLS"
grep -Fq -- 'engine/prompts/triage.md' "$TEST_UPSERT_BODIES"
grep -Fq -- 'Score: 0.4' "$TEST_UPSERT_BODIES"
grep -Fq -- 'unit-101' "$TEST_UPSERT_BODIES"
grep -Fq -- 'unit-102' "$TEST_UPSERT_BODIES"
grep -Fq -- 'Suggested change:' "$TEST_UPSERT_BODIES"
! grep -Fq -- 'must-not-appear' "$TEST_UPSERT_BODIES"

version_a="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
version_b="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
rm -f -- "$state" "$TEST_UPSERT_CALLS" "$TEST_UPSERT_BODIES"
{
  jq -cn --arg version "$version_a" '{stage:"review",prompt:"engine/prompts/review-contract.md",prompt_version:$version,sample_size:3,score:0.4,unit_ids:["unit-201"]}'
  jq -cn --arg version "$version_b" '{stage:"review",prompt:"engine/prompts/review-contract.md",prompt_version:$version,sample_size:3,score:0.3,unit_ids:["unit-202"]}'
} > "$report"
run_report >/dev/null
[[ ! -s "$TEST_UPSERT_CALLS" ]]
jq -e --arg a "$version_a" --arg b "$version_b" '.entries | length == 2 and
  any(.[]; .prompt_version == $a and .streak == 1) and
  any(.[]; .prompt_version == $b and .streak == 1)' "$state" >/dev/null
jq -cn --arg version "$version_a" '{stage:"review",prompt:"engine/prompts/review-contract.md",prompt_version:$version,sample_size:3,score:0.4,unit_ids:["unit-201"]}' > "$report"
run_report >/dev/null
[[ "$(wc -l < "$TEST_UPSERT_CALLS")" == 1 ]]
grep -Fq -- "Prompt version: \`$version_a\`" "$TEST_UPSERT_BODIES"
first_version_class="$(sed -n '1s/.*--class \([^ ]*\).*/\1/p' "$TEST_UPSERT_CALLS")"
jq -cn --arg version "$version_b" '{stage:"review",prompt:"engine/prompts/review-contract.md",prompt_version:$version,sample_size:3,score:0.3,unit_ids:["unit-202"]}' > "$report"
run_report >/dev/null
[[ "$(wc -l < "$TEST_UPSERT_CALLS")" == 2 ]]
second_version_class="$(sed -n '2s/.*--class \([^ ]*\).*/\1/p' "$TEST_UPSERT_CALLS")"
[[ "$first_version_class" != "$second_version_class" ]]
grep -Fq -- "Prompt version: \`$version_b\`" "$TEST_UPSERT_BODIES"

rm -f -- "$state" "$TEST_UPSERT_CALLS" "$TEST_UPSERT_BODIES"
implementation_version="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
jq -cn --arg version "$implementation_version" '{stage:"merged",prompt_stage:"implement",prompt:"engine/mac-autopilot/scheduler.d/dispatch-queue.sh",prompt_version:$version,sample_size:3,score:0.4,unit_ids:["unit-301"]}' > "$report"
run_report >/dev/null
[[ ! -s "$TEST_UPSERT_CALLS" ]]
run_report >/dev/null
[[ "$(wc -l < "$TEST_UPSERT_CALLS")" == 1 ]]
grep -Fq -- 'engine/mac-autopilot/scheduler.d/dispatch-queue.sh' "$TEST_UPSERT_BODIES"
grep -Fq -- 'Prompt stage: `implement`' "$TEST_UPSERT_BODIES"
grep -Fq -- "Prompt version: \`$implementation_version\`" "$TEST_UPSERT_BODIES"

# Later low reports call the shared upsert again with the same class, so it updates the open issue.
rm -f -- "$state" "$TEST_UPSERT_CALLS" "$TEST_UPSERT_BODIES"
write_low_report
run_report >/dev/null
[[ ! -s "$TEST_UPSERT_CALLS" ]]
run_report >/dev/null
[[ "$(wc -l < "$TEST_UPSERT_CALLS")" == 1 ]]
run_report >/dev/null
[[ "$(wc -l < "$TEST_UPSERT_CALLS")" == 2 ]]
first_class="$(sed -n '1s/.*--class \([^ ]*\).*/\1/p' "$TEST_UPSERT_CALLS")"
second_class="$(sed -n '2s/.*--class \([^ ]*\).*/\1/p' "$TEST_UPSERT_CALLS")"
[[ -n "$first_class" && "$first_class" == "$second_class" ]]

# Insufficient data breaks the streak and never creates or updates an issue.
rm -f -- "$state" "$TEST_UPSERT_CALLS" "$TEST_UPSERT_BODIES"
write_low_report
run_report >/dev/null
jq -cn '{stage:"triage",prompt:"engine/prompts/triage.md",sample_size:1,
  status:"insufficient-data",unit_ids:["unit-103"]}' > "$report"
run_report >/dev/null
[[ ! -s "$TEST_UPSERT_CALLS" ]]
write_low_report
run_report >/dev/null
[[ ! -s "$TEST_UPSERT_CALLS" ]]
run_report >/dev/null
[[ "$(wc -l < "$TEST_UPSERT_CALLS")" == 1 ]]

# A report can never target a path outside the prompt tree.
rm -f -- "$state" "$TEST_UPSERT_CALLS" "$TEST_UPSERT_BODIES"
jq -cn '{stage:"triage",prompt:"engine/lib.sh",sample_size:3,score:0.1,unit_ids:["unit-104"]}' > "$report"
set +e
run_report >/dev/null 2>&1
r=$?
set -e
[[ "$r" == 65 && ! -e "$TEST_UPSERT_CALLS" ]]

# Prompt edits flow into the existing eval selection for their stage.
REVIEW_SKILL=code-review
sched_config_file() { printf '%s\n' 'engine/prompts/review-contract.md'; }
source "$script_dir/../mac-autopilot/scheduler.d/evals-arbiter.sh"
[[ "$(decision_eval_stages_for_paths 'engine/prompts/triage.md')" == 'triage end-to-end ' ]]

echo 'ok - persistent low prompt scores upsert one prompt-only issue'
