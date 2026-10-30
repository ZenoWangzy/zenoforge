import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { sampleEfficiency, appendMetricRecords } from './efficiency-regression.mjs';
const home = mkdtempSync(path.join(os.tmpdir(), 'repeat-dispatch-'));
try {
  mkdirSync(path.join(home, 'logs'));
  for (const name of ['implement-42-20261007T000000Z.log', 'implement-42-20261008T110000Z.log', 'repair-42-20261007T001000Z.log', 'repair-42-20261008T111000Z.log']) writeFileSync(path.join(home, 'logs', name), 'model call\n');
  appendMetricRecords(home, [
    {record_type:'event', event_type:'dispatch', event_id:'d1', issue:42, ts:'2026-10-07T00:00:00Z'},
    {record_type:'event', event_type:'attempt-terminal', event_id:'t1', issue:42, ts:'2026-10-07T01:00:00Z', terminal_cause:'review-not-ready'},
    {record_type:'event', event_type:'dispatch', event_id:'d2', issue:42, ts:'2026-10-08T11:00:00Z'},
    {record_type:'event', event_type:'dispatch', event_id:'d3', issue:43, ts:'2026-10-07T00:00:00Z'},
    {record_type:'event', event_type:'attempt-resumed', event_id:'r1', issue:43, ts:'2026-10-08T11:00:30Z', retry_reason:'supervisor-resume'},
    {record_type:'event', event_type:'dispatch', event_id:'d4', issue:43, ts:'2026-10-08T11:01:00Z'},
    {record_type:'event', event_type:'dispatch', event_id:'d5', issue:44, ts:'2026-10-07T00:00:00Z'},
    {record_type:'event', event_type:'attempt-terminal', event_id:'t2', issue:44, ts:'2026-10-07T01:00:00Z', terminal_cause:'launch-budget-refused'},
    {record_type:'event', event_type:'dispatch', event_id:'d6', issue:44, ts:'2026-10-08T11:02:00Z'},
    {record_type:'event', event_type:'dispatch', event_id:'d7', issue:45, ts:'2026-10-07T00:00:00Z', boot_id:'old'},
    {record_type:'event', event_type:'dispatch', event_id:'d8', issue:45, ts:'2026-10-08T11:03:00Z', boot_id:'new'},
    {record_type:'event', event_type:'dispatch', event_id:'d9', issue:46, ts:'2026-10-07T00:00:00Z'},
    {record_type:'event', event_type:'attempt-terminal', event_id:'t3', issue:46, ts:'2026-10-07T01:00:00Z', terminal_cause:'network-egress', attempt_refunded:true},
    {record_type:'event', event_type:'dispatch', event_id:'d10', issue:46, ts:'2026-10-08T11:04:00Z'},
    {record_type:'event', event_type:'dispatch', event_id:'d11', issue:47, ts:'2026-10-07T00:00:00Z', boot_id:'old'},
    {record_type:'event', event_type:'attempt-terminal', event_id:'t4', issue:47, ts:'2026-10-07T01:00:00Z', terminal_cause:'interrupted', attempt_refunded:true},
    {record_type:'event', event_type:'dispatch', event_id:'d12', issue:47, ts:'2026-10-08T11:05:00Z', boot_id:'new'},
    {record_type:'event', event_type:'dispatch', event_id:'d13', issue:48, ts:'2026-10-07T00:00:00Z', boot_id:'same'},
    {record_type:'event', event_type:'attempt-terminal', event_id:'t5', issue:48, ts:'2026-10-07T01:00:00Z', terminal_cause:'interrupted', attempt_refunded:true},
    {record_type:'event', event_type:'dispatch', event_id:'d14', issue:48, ts:'2026-10-08T11:06:00Z', boot_id:'same'},
    {record_type:'event', event_type:'dispatch', event_id:'d15', issue:49, ts:'2026-10-07T00:00:00Z', boot_id:'same'},
    {record_type:'event', event_type:'attempt-terminal', event_id:'t6', issue:49, ts:'2026-10-07T01:00:00Z', terminal_cause:'interrupted', systemd_result:'core-dump', attempt_refunded:false},
    {record_type:'event', event_type:'dispatch', event_id:'d16', issue:49, ts:'2026-10-08T11:07:00Z', boot_id:'same'},
  ]);
  appendMetricRecords(home,[{record_type:'hourly',sampled_at:'2026-10-08T12:00:00Z',metrics:{repeat_dispatches:81}}]);
  const result = await sampleEfficiency({home, repo:'test/repo', now:new Date('2026-10-08T12:05:00Z'), runningIssues:[], getClosedIssues:async()=>[], fetchCi:async()=>({queue_seconds:[], run_seconds:[], errors:[]}), sendAlert:async()=>{}});
  assert.equal(result.row.metrics.repeat_dispatches, 2);
  assert.equal(result.row.repeat_run_causes['review-not-ready'], 1);
  assert.equal(result.row.repeat_run_causes.interrupted, 1);
  assert.equal(result.row.repeat_dispatches_excluded, 6);
  assert.equal(result.row.repeat_model_calls, 2);
  console.log('ok - real dispatches exclude explicit recovery and never double count repair calls');
} finally { rmSync(home, {recursive:true, force:true}); }
