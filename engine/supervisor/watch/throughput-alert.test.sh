#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
engine=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
watch_dir="$engine/supervisor/watch"
fixture="$test_env_root/throughput"
mkdir -p "$fixture"
units="$fixture/units.json"
log="$fixture/scheduler.log"
pause="$fixture/PAUSE"
now="$(node -e 'process.stdout.write(String(Math.floor(Date.parse("2026-11-02T12:00:00Z") / 1000)) )')"

fail() { printf 'throughput-alert.test.sh: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in '$1'"; }
assert_empty() { [[ -z "$1" ]] || fail "$2: expected no alert, got '$1'"; }
run_alert() {
  node "$watch_dir/throughput-alert.cjs" "$units" "$log" "$pause" "$now" 60 3 2>/dev/null
}
set_units() {
  cat > "$units" <<'JSON'
{"units":[
 {"id":"pr-41","pr":41,"stage":"ready-to-merge","history":[{"stage":"review-approve","at":"2026-11-02T09:00:00Z"},{"stage":"ci-infra-red","at":"2026-11-02T11:40:00Z"}]},
 {"id":"pr-42","pr":42,"stage":"ready-to-merge","history":[{"stage":"review-approve","at":"2026-11-02T10:00:00Z"},{"stage":"ci-cancelled-restart","at":"2026-11-02T11:50:00Z"}]}
]}
JSON
}

# Config defaults are part of the watch config surface.
printf '{"watch":{}}\n' > "$fixture/config.json"
defaults="$(ZF_SUPERVISOR_CONFIG="$fixture/config.json" node - "$engine/supervisor/lib/config.cjs" <<'NODE'
const {config} = require(process.argv[2]);
process.stdout.write(`${config.watch.ready_stuck_minutes} ${config.watch.no_output_hours}`);
NODE
)"
[[ "$defaults" == '60 3' ]] || fail "expected watch defaults '60 3', got '$defaults'"

# An aged ready queue with no merge must report its size, oldest PRs, and each PR's latest skip reason.
set_units
cat > "$log" <<'LOG'
[2026-11-02T10:00:00Z] merge skipped PR#41 (draft, waiting for its CI slot)
[2026-11-02T11:00:00Z] merge skipped PR#41 (checks pending or unavailable)
[2026-11-02T11:10:00Z] merge skipped PR#42 (CI waits for a WIP slot)
LOG
rm -f "$pause"
alert="$(run_alert)"
assert_contains "$alert" 'throughput stalled' 'stuck queue alert'
assert_contains "$alert" 'ready-to-merge=2' 'stuck queue count'
assert_contains "$alert" 'PR#41 (checks pending or unavailable)' 'latest skip reason'
assert_contains "$alert" 'PR#42 (CI waits for a WIP slot)' 'second skip reason'

# Any successful pipeline merge in the stuck window suppresses the stuck and no-output alerts.
printf '[2026-11-02T11:55:00Z] merged PR#99 merge=abc\n' >> "$log"
alert="$(run_alert)"
assert_empty "$alert" 'recent merge suppression'

# A CI repair rerun returning from rereview starts a new ready-stage age window.
cat > "$units" <<'JSON'
{"units":[
 {"id":"pr-43","pr":43,"stage":"ready-to-merge","history":[{"stage":"review-approve","at":"2026-11-02T08:00:00Z"},{"stage":"ci-repair-rerun","at":"2026-11-02T11:50:00Z"}]}
]}
JSON
printf '[2026-11-02T10:55:00Z] merged PR#42 merge=abc\n' > "$log"
alert="$(run_alert)"
assert_empty "$alert" 'recent ready-stage transition suppression'

# PAUSE suppresses both throughput conditions, even when the file is empty.
: > "$pause"
: > "$log"
alert="$(run_alert)"
assert_empty "$alert" 'PAUSE suppression'
rm -f "$pause"

# Supervisor-owned work must not trigger the stuck alert; the recent merge here suppresses no-output.
cat > "$units" <<'JSON'
{"units":[
 {"id":"pr-51","pr":51,"stage":"ready-to-merge","supervisor_owned":true,"history":[{"stage":"review-approve","at":"2026-11-02T08:00:00Z"}]}
]}
JSON
printf '[2026-11-02T10:00:00Z] merged PR#50 merge=abc\n' > "$log"
alert="$(run_alert)"
assert_empty "$alert" 'supervisor-owned filtering'

# A young ready item still reports when the configurable no-output window elapses.
cat > "$units" <<'JSON'
{"units":[
 {"id":"pr-61","pr":61,"stage":"ready-to-merge","history":[{"stage":"review-approve","at":"2026-11-02T11:30:00Z"}]}
]}
JSON
: > "$log"
alert="$(run_alert)"
assert_contains "$alert" 'throughput idle' 'no-output alert'
assert_contains "$alert" 'ready-to-merge=1' 'no-output ready count'

# A rotation moves the last merge to scheduler.log.1 and leaves the live log missing or fresh.
cat > "$log.1" <<'LOG'
[2026-11-02T11:45:00Z] merged PR#60 (rotated out)
LOG
rm -f "$log"
alert="$(run_alert)"
assert_empty "$alert" 'merge in the rotated log, live log missing'
: > "$log"
alert="$(run_alert)"
assert_empty "$alert" 'merge in the rotated log, live log fresh'
rm -f "$log.1"

# The tick gap also reads the newest of the two logs: a missing live log is not 0 epoch.
grep -Fq 'stat -c %Y "$A/scheduler.log" "$A/scheduler.log.1"' "$watch_dir/pipe-watch.sh" || fail 'pipe-watch must stat both logs'

printf 'throughput alert tests: all checks passed\n'
