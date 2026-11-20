#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
script="$script_dir/prompt-observer-report.sh"
systemd_dir="$script_dir/../systemd"
service="$systemd_dir/zenoforge-prompt-observer-report.service"
timer="$systemd_dir/zenoforge-prompt-observer-report.timer"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT

grep -Fq 'OnCalendar=*-*-* 01:05:00 UTC' "$timer" \
  || { echo 'not ok - prompt observer runs daily beside the night monitors' >&2; exit 1; }
grep -Eq '^ExecStart=:/bin/bash -c .*exec /bin/bash .*night/prompt-observer-report\.sh' "$service" \
  || { echo 'not ok - prompt observer service runs the report-only script' >&2; exit 1; }
! grep -Eq 'prompt-observer-(compare|low-score)\.sh' "$service" \
  || { echo 'not ok - prompt observer service calls a GitHub-writing observer' >&2; exit 1; }
grep -Fxq 'Environment=MAC_AUTOPILOT_RUNTIME_DIR=%h/.zenoforge/checkout/.scratch-supervisor/autopi' "$service" \
  || { echo 'not ok - prompt observer reads the unit ledger runtime' >&2; exit 1; }
grep -Fxq 'zenoforge-prompt-observer-report.timer - timer-alerted-zenoforge-prompt-observer-report.timer' \
  "$systemd_dir/pipeline-timers.list" \
  || { echo 'not ok - prompt observer timer is tracked by run-tick' >&2; exit 1; }
echo 'ok - prompt observer is scheduled as a tracked daily report'

runtime="$tmp/runtime"
mkdir -p "$runtime" "$tmp/bin"
cat > "$runtime/units.json" <<'JSON'
{"units":[
  {"id":"unit-1","stage":"merged","prompt":"triage","history":[{"stage":"review-request-changes"},{"stage":"supervisor-approve"}]},
  {"id":"unit-2","stage":"merged","prompt":"triage","history":[{"stage":"review-approve"}]},
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

MAC_AUTOPILOT_RUNTIME_DIR="$runtime" ZF_REPO_DIR="$tmp/no-repo" \
  PROMPT_OBSERVER_REPORT="$tmp/report.jsonl" PROMPT_OBSERVER_MIN_SAMPLES=2 \
  bash "$script" > /dev/null
jq -s -e 'length == 1 and .[0].stage == "merged" and .[0].prompt == "triage" and
  .[0].sample_size == 2 and (.[0].score > 0.83 and .[0].score < 0.84) and
  .[0].unit_ids == ["unit-1","unit-2"]' "$tmp/report.jsonl" >/dev/null
cmp "$runtime/units.json" "$tmp/units.json.original"
[[ ! -e "$TEST_GH_CALLS" ]]
echo 'ok - observer writes the report without GitHub calls or ledger changes'
