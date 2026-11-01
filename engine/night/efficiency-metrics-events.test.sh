#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export AGENT_HOME="$tmp/home"
mkdir -p "$AGENT_HOME/state"
# shellcheck source=../lib.sh
source "$REPO_DIR/engine/lib.sh"

ticket_stage_record 42 untracked needs-triage writer create 1 create-42 2026-10-12T00:00:00Z
ticket_stage_record 42 needs-triage ready-for-agent writer advance 1 ready-42 2026-10-12T01:00:00Z
ticket_stage_record 42 ready-for-agent in-progress writer advance 1 work-42 2026-10-12T02:00:00Z
ticket_stage_record 42 in-progress closed writer close 1 close-42 2026-10-12T03:00:00Z
ticket_stage_record 42 closed released writer release 1 release-42 2026-10-12T04:00:00Z

reason=$'memory "pressure"\nsecond line'
object=$'unit "zf-implement-42"\nobject detail'
for gate in capacity dispatch-resources quarantine spend-budget blocked-parent web-advisor-provider code-review ci-queue land-queue; do
  efficiency_metrics_record_implement_decision 42 tick-"$gate" skipped "$gate" "$reason" "$object"
done
efficiency_metrics_record_implement_decision 42 tick-dispatched dispatched implement-dispatch started implement-unit

# A successful explicit hand release is the provenance for a legitimate resume.
recut_parent_has_open_child() { return 1; }
issue_transition() { return 0; }
ZF_AGENT_NAME=hand-test state_requeue 42 release-hold

# Events use their own timestamps, so they can span monthly files; read all of them.
cat "$AGENT_HOME"/metrics/efficiency-*.jsonl > "$tmp/efficiency-all.jsonl"
node - "$tmp/efficiency-all.jsonl" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const rows = fs.readFileSync(process.argv[2], 'utf8').trim().split('\n').map(JSON.parse);
const events = rows.filter((row) => row.record_type === 'event');
assert.ok(rows.every((row) => row.schema_version === 1));
const types = events.map((row) => row.event_type);
for (const type of ['ticket-created', 'stage-entered', 'stage-exited', 'ticket-closed', 'ticket-released', 'limiter', 'dispatch', 'attempt-resumed']) {
  assert.ok(types.includes(type), `missing ${type}`);
}
const expected = {
  capacity: 'agent_cap',
  'dispatch-resources': 'memory',
  quarantine: 'quarantine',
  'spend-budget': 'budget',
  'blocked-parent': 'blocked_by',
  'web-advisor-provider': 'advisor',
  'code-review': 'review',
  'ci-queue': 'ci_queue',
  'land-queue': 'land_queue',
};
for (const [gate, category] of Object.entries(expected)) {
  const row = events.find((event) => event.event_type === 'limiter' && event.gate === gate);
  assert.equal(row?.category, category, `${gate} category`);
  assert.equal(row.reason, 'memory "pressure"\nsecond line');
  assert.equal(row.object, 'unit "zf-implement-42"\nobject detail');
}
assert.equal(events.find((event) => event.event_type === 'dispatch')?.category, null);
assert.equal(events.find((event) => event.event_type === 'attempt-resumed')?.retry_reason, 'supervisor-resume');
console.log('ok - stage, closure, release, dispatch, and limiter events preserve exact values');
NODE
