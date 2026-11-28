#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-scheduler-gates-fixture.sh"
source "$script_dir/scheduler.d/self-check.sh"

fail() { echo "incident-escape-gate.test.sh: $*" >&2; exit 1; }

sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
TAG=20261128T000000Z
runs_file="$sup/self-check-runs"
: > "$runs_file"
self_check_run() { echo run >> "$runs_file"; echo 'stub test run'; return 0; }
self_check_runs() { wc -l < "$runs_file" | tr -d ' '; }
pid_start() { echo stub; }

escape_test="packages/fruit/tests/registered.sh"
report_name=incident-escape-gate.md
report="$sup/$report_name"
mkdir -p "$ROOT/.zenoforge/state" "$ROOT/packages/fruit/tests" "$sup"
git init -q "$ROOT"
git -C "$ROOT" config user.name fixture
git -C "$ROOT" config user.email fixture@example.invalid
printf 'exit 0\n' > "$ROOT/$escape_test"

write_report() {
  printf '## decision-log\nTried the registered escape gate and verified its result.\n\n## how\nThe scheduler checks implementation reports before review.\n\n## why\nCommit 97ed8be added the report gate for issue #880.\n\n## root-cause\nThe incident report did not connect the recurrence guard to a registered test.\n\n## recurrence-guard\nkind: test\n'
  if [[ -n "${1:-}" ]]; then printf 'escape-test: %s\n' "$1"; fi
  printf '\n## prior-art\nSource: https://example.invalid/incident-reference\n'
}

incident_unit='{"id":"issue-1688","issue":1688,"labels":["bug"]}'
write_report > "$report"
reason="$(incident_report_gate_reason "$incident_unit" "$report")"
[[ -z "$reason" ]] || fail "a report without escape-test changed its result: $reason"

printf '{"version":1,"packages":{"packages/fruit":[{"test":"%s","command":["bash","%s"]}]}}\n' "$escape_test" "$escape_test" > "$ROOT/.zenoforge/state/escape-suites.json"
git -C "$ROOT" add .
git -C "$ROOT" commit -qm 'register fixture escape test'
write_report "$escape_test" > "$report"
reason="$(incident_report_gate_reason "$incident_unit" "$report")"
[[ -z "$reason" ]] || fail "a registered escape test was rejected: $reason"

printf '{"version":1,"packages":{"packages/fruit":[]}}\n' > "$ROOT/.zenoforge/state/escape-suites.json"
git -C "$ROOT" add .zenoforge/state/escape-suites.json
git -C "$ROOT" commit -qm 'remove fixture escape test registration'
reason="$(incident_report_gate_reason "$incident_unit" "$report")"
expected_reason="escape-test not registered: $escape_test"
[[ "$reason" == "$expected_reason" ]] || fail "expected '$expected_reason', got '$reason'"

jqf -cn --arg report "$report_name" \
  '{units:[{id:"issue-1688",issue:1688,lane:"direct-main",stage:"review-pending",labels:["bug"],implementation_report:$report,history:[]}]}' > "$UNITS"
self_check_before_review issue-1688 "$(git -C "$ROOT" rev-parse HEAD)" "$ROOT" || true
wait
self_check_harvest
output="$(jqf -r '.units[0].self_check_output' "$UNITS")"
grep -Fxq "incident report check failed: $expected_reason" "$output" \
  || fail "self-check log did not record the gate reason: $(cat "$output")"
[[ "$(self_check_runs)" == 0 ]] || fail 'a rejected incident report reached the normal self-check'

echo 'incident-escape-gate.test.sh: PASS'
