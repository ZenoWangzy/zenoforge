#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
runner="$script_dir/prompt-observer-run.sh"
systemd_dir="$script_dir/../systemd"
service="$systemd_dir/zenoforge-prompt-observer-report.service"
timer="$systemd_dir/zenoforge-prompt-observer-report.timer"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT

grep -Fq 'OnCalendar=*-*-* 01:05:00 UTC' "$timer" \
  || { echo 'not ok - prompt observer runs daily beside the night monitors' >&2; exit 1; }
grep -Eq '^ExecStart=:/bin/bash -c .*exec /bin/bash .*night/prompt-observer-run\.sh' "$service" \
  || { echo 'not ok - prompt observer service runs the report and low-score caller' >&2; exit 1; }
grep -Fxq 'Environment=MAC_AUTOPILOT_RUNTIME_DIR=%h/.zenoforge/checkout/.scratch-supervisor/autopi' "$service" \
  || { echo 'not ok - prompt observer reads the unit ledger runtime' >&2; exit 1; }
grep -Fxq 'zenoforge-prompt-observer-report.timer - timer-alerted-zenoforge-prompt-observer-report.timer' \
  "$systemd_dir/pipeline-timers.list" \
  || { echo 'not ok - prompt observer timer is tracked by run-tick' >&2; exit 1; }
echo 'ok - prompt observer is scheduled as a tracked daily caller'

runtime="$tmp/runtime"
mkdir -p "$runtime" "$tmp/bin"
cat > "$runtime/units.json" <<'JSON'
{"units":[
  {"id":"unit-1","stage":"merged","prompt":"engine/mac-autopilot/scheduler.d/dispatch-queue.sh","prompt_stage":"implement","prompt_version":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","history":[{"stage":"review-request-changes"},{"stage":"supervisor-approve"}]},
  {"id":"unit-2","stage":"merged","prompt":"engine/mac-autopilot/scheduler.d/dispatch-queue.sh","prompt_stage":"implement","prompt_version":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","history":[{"stage":"review-approve"}]},
  {"id":"pending","stage":"review-pending","prompt":"engine/prompts/triage.md","history":[{"stage":"review-approve"}]}
]}
JSON
cp "$runtime/units.json" "$tmp/units.json.original"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_GH_CALLS"
exit 1
STUB
chmod +x "$tmp/bin/gh"
cat > "$tmp/upsert" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ -s "$PROMPT_OBSERVER_REPORT" ]]
jq -s -e 'length == 1 and .[0].score < 0.9' "$PROMPT_OBSERVER_REPORT" >/dev/null
printf '%s\n' "$*" >> "$TEST_UPSERT_CALLS"
STUB
chmod +x "$tmp/upsert"
export PATH="$tmp/bin:$PATH" TEST_GH_CALLS="$tmp/gh.calls" TEST_UPSERT_CALLS="$tmp/upsert.calls"

run_scheduled_observer() {
  MAC_AUTOPILOT_RUNTIME_DIR="$runtime" ZF_REPO_DIR="$tmp/no-repo" ZF_REPO=test/repo \
    PROMPT_OBSERVER_REPORT="$tmp/report.jsonl" PROMPT_OBSERVER_MIN_SAMPLES=2 \
    PROMPT_OBSERVER_LOW_SCORE_THRESHOLD=0.9 PROMPT_OBSERVER_LOW_SCORE_REPORTS=1 \
    PROMPT_OBSERVER_LOW_SCORE_STATE="$tmp/state.json" PROMPT_OBSERVER_LOW_SCORE_UPSERT="$tmp/upsert" \
    bash "$runner" > /dev/null
}

run_scheduled_observer
jq -s -e 'length == 1 and .[0].stage == "merged" and .[0].prompt == "engine/mac-autopilot/scheduler.d/dispatch-queue.sh" and
  .[0].sample_size == 2 and (.[0].score > 0.83 and .[0].score < 0.84) and
  .[0].unit_ids == ["unit-1","unit-2"]' "$tmp/report.jsonl" >/dev/null
[[ "$(wc -l < "$TEST_UPSERT_CALLS")" == 1 ]]
run_scheduled_observer
[[ "$(wc -l < "$TEST_UPSERT_CALLS")" == 2 ]]
first_class="$(sed -n '1s/.*--class \([^ ]*\).*/\1/p' "$TEST_UPSERT_CALLS")"
second_class="$(sed -n '2s/.*--class \([^ ]*\).*/\1/p' "$TEST_UPSERT_CALLS")"
[[ -n "$first_class" && "$first_class" == "$second_class" ]]
cmp "$runtime/units.json" "$tmp/units.json.original"
[[ ! -e "$TEST_GH_CALLS" ]]
echo 'ok - scheduled observer reports before one idempotent low-score upsert'
