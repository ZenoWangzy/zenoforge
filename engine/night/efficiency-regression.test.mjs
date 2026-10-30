#!/usr/bin/env node

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  appendMetricRecord,
  appendMetricRecords,
  assessEfficiency,
  collectGitHubCiSamples,
  compareDailyMetrics,
  dailyEfficiency,
  dailyNodeMetrics,
  efficiencySummary,
  maintainerMailEfficiencySummary,
  renderMaintainerMailEfficiency,
  ghPages,
  readMetricRows,
  weeklyTimeSinks,
  weeklyDeliveryMetrics,
  runLifecycleMetricRows,
  syncIssueLifecycleEvents,
  closedIssueMetricRows,
  sampleEfficiency,
} from './efficiency-regression.mjs';

const root = mkdtempSync(path.join(os.tmpdir(), 'efficiency-regression-'));
try {
  const baseMetrics = {
    calls: 20,
    tokens: 1000,
    released_issues: 10,
    merged_prs: 10,
    tokens_per_released_issue: 100,
    queue_to_implement_seconds: 100,
    implement_to_merge_seconds: 200,
    merge_to_release_seconds: 300,
    repeat_dispatches: 2,
    ci_queue_seconds: 50,
    ci_run_seconds: 400,
    closed_issues: 7,
    limiter_ticket_hours: 1,
    ci_waste_share: 0.657,
    main_green_share: 0.55,
  };
  const sample = (options) => sampleEfficiency({
    getRunningIssues: () => [],
    getClosedIssues: async () => [],
    getOpenIssues: async () => readdirSync(path.join(options.home, 'state'))
      .filter((name) => /^[0-9]+\.json$/.test(name))
      .map((name) => ({ number: Number(name.slice(0, -5)), labels: [{ name: JSON.parse(readFileSync(path.join(options.home, 'state', name))).state }] })),
    ...options,
  });
  const row = (sampledAt, metrics = {}, extra = {}) => ({
    sampled_at: sampledAt,
    repeat_dispatch_metric_version: 2,
    ticket_tracking_metric_version: 2,
    metrics: { ...baseMetrics, ...metrics },
    stage_tickets: {
      queue_to_implement_seconds: ['10001'],
      implement_to_merge_seconds: [],
      merge_to_release_seconds: [],
    },
    stage_samples: {
      queue_to_implement_seconds: 30,
      implement_to_merge_seconds: 30,
      merge_to_release_seconds: 30,
    },
    stuck_by_stage: {},
    source_errors: [],
    ...extra,
  });
  const writeHistory = (home, rows) => {
    appendMetricRecords(home, rows.map((value) => ({ record_type: 'hourly', ...value })));
  };
  const storeHome = path.join(root, 'store');
  const firstMetric = { record_type: 'event', event_type: 'stage-entered', event_id: 'enter-1', ts: '2026-10-31T23:59:00Z', issue: '1' };
  appendMetricRecord(storeHome, firstMetric);
  appendMetricRecord(storeHome, firstMetric);
  appendMetricRecord(storeHome, { record_type: 'event', event_type: 'stage-exited', event_id: 'exit-1', ts: '2026-11-01T00:01:00Z', issue: '1' });
  assert.equal(readMetricRows(storeHome).length, 2, 'event IDs deduplicate across retries and files rotate monthly');
  assert.equal(statSync(path.join(storeHome, 'metrics')).mode & 0o777, 0o700);
  assert.equal(statSync(path.join(storeHome, 'metrics/efficiency-2026-10.jsonl')).mode & 0o777, 0o600);
  console.log('ok - append-only metric store deduplicates and rotates monthly with private modes');
  const legacyHome = path.join(root, 'legacy');
  mkdirSync(path.join(legacyHome, 'state'), { recursive: true });
  writeFileSync(path.join(legacyHome, 'state/efficiency-hourly.jsonl'), `${JSON.stringify(row('2026-10-12T10:05:00Z'))}\n`);
  const migrated = await sample({
    home: legacyHome,
    repo: 'fixture/example',
    now: new Date('2026-10-12T10:30:00Z'),
    fetchCi: async () => assert.fail('same-hour migrated row must not sample twice'),
    sendAlert: async () => {},
  });
  assert.equal(migrated.row.sampled_at, '2026-10-12T10:05:00Z');
  assert.equal(readMetricRows(legacyHome).filter((item) => item.record_type === 'hourly').length, 1);
  assert.ok(readFileSync(path.join(legacyHome, 'state/efficiency-hourly.jsonl.migrated'), 'utf8').includes('2026-10-12T10:05:00Z'));
  console.log('ok - legacy hourly history migrates once into monthly metrics store');
  const weekRows = (lastMetrics = {}, lastExtra = {}) => {
    const rows = [];
    const start = Date.parse('2026-10-01T00:00:00Z');
    for (let hour = 0; hour < 168; hour += 1) {
      rows.push(row(new Date(start + hour * 60 * 60 * 1000).toISOString()));
    }
    rows.push(row('2026-10-08T00:05:00Z', lastMetrics, lastExtra));
    return rows;
  };

  const slowThresholds = assessEfficiency(weekRows({ closed_issues: 4, ci_waste_share: 0.758, limiter_ticket_hours: 5 }));
  assert.equal(slowThresholds.status, 'SLOW');
  assert.ok(slowThresholds.violations.some(({ metric }) => metric === 'closed_issues'));
  assert.ok(slowThresholds.violations.some(({ metric }) => metric === 'ci_waste_share'));
  assert.ok(slowThresholds.violations.some(({ metric }) => metric === 'limiter_ticket_hours'));
  const brokenThresholds = assessEfficiency(weekRows({ closed_issues: 3, ci_waste_share: 0.858, limiter_ticket_hours: 9 }));
  assert.equal(brokenThresholds.status, 'BROKEN');
  const smallStageCohort = assessEfficiency(weekRows({
    implement_to_merge_seconds: 43029, ci_waste_share: 0.8,
  }, { stage_samples: {
    queue_to_implement_seconds: 12,
    implement_to_merge_seconds: 12,
    merge_to_release_seconds: 12,
  } }));
  assert.equal(smallStageCohort.driver.key, 'unknown');
  assert.equal(smallStageCohort.driver.reason, 'insufficient-stage-samples');
  assert.ok(!smallStageCohort.violations.some(({ metric }) => metric === 'implement_to_merge_seconds'),
    'a 12-ticket cohort cannot turn one long-lived stage into a BROKEN hourly alarm');
  const previousRows = weekRows({ main_green_share: 0.29 });
  for (const historyRow of previousRows.slice(0, -1)) historyRow.metrics.main_green_share = 0.4;
  previousRows.find((historyRow) => historyRow.sampled_at.startsWith('2026-10-07T00:00:00')).metrics.main_green_share = 0.8;
  const previousRegression = assessEfficiency(previousRows);
  assert.equal(previousRegression.violations.find(({ metric }) => metric === 'main_green_share')?.comparison, 'previous-24h');

  const observedMainGreenRows = weekRows({
    main_green_share: 1 / 3,
    queue_to_implement_seconds: 114078,
  }, {
    stage_samples: { queue_to_implement_seconds: 33 },
    stage_tickets: { queue_to_implement_seconds: ['1254', '2499', '2699', '2986', '2790'] },
    stuck_by_stage: { queue_to_implement_seconds: { count: 148, tickets: ['1159', '1147', '1163', '1162', '1161'] } },
  });
  const sampleShift = Date.parse('2026-10-13T11:11:43.620Z') - Date.parse(observedMainGreenRows.at(-1).sampled_at);
  for (const historyRow of observedMainGreenRows.slice(0, -1)) {
    historyRow.metrics.main_green_share = 0.4;
    historyRow.metrics.queue_to_implement_seconds = 114078;
  }
  for (const historyRow of observedMainGreenRows) {
    historyRow.sampled_at = new Date(Date.parse(historyRow.sampled_at) + sampleShift).toISOString();
  }
  const observedMainGreenRegression = assessEfficiency(observedMainGreenRows);
  const observedMainGreenViolation = observedMainGreenRegression.violations.find(({ metric }) => metric === 'main_green_share');
  assert.equal(observedMainGreenRegression.status, 'SLOW');
  assert.equal(observedMainGreenViolation?.current, 1 / 3);
  assert.equal(observedMainGreenViolation?.baseline, 0.53);
  assert.equal(observedMainGreenViolation?.comparison, 'baseline-2026-10-10');
  assert.equal(observedMainGreenRegression.driver.reason, 'most-stuck-tickets');
  assert.deepEqual(observedMainGreenRegression.driver.tickets, ['1159', '1147', '1163', '1162', '1161']);

  const recoveredMainGreenRows = weekRows({ main_green_share: 0.4 });
  for (const historyRow of recoveredMainGreenRows.slice(0, -1)) historyRow.metrics.main_green_share = 0.4;
  const recoveredMainGreen = assessEfficiency(recoveredMainGreenRows);
  assert.equal(recoveredMainGreen.status, 'OK');
  assert.ok(!recoveredMainGreen.violations.some(({ metric }) => metric === 'main_green_share'),
    'the fixed 0.53 baseline clears main-green SLOW only after share recovers above 0.3975');
  console.log('ok - issue 3747 main-green sample stays SLOW until the fixed baseline threshold is restored');

  const stuckTicketEvidence = assessEfficiency(weekRows({ limiter_ticket_hours: 9 }, {
    stage_tickets: { queue_to_implement_seconds: ['completed-queue-ticket'] },
    stuck_by_stage: { queue_to_implement_seconds: { count: 2, tickets: ['stuck-queue-ticket-1', 'stuck-queue-ticket-2'] } },
  }));
  assert.equal(stuckTicketEvidence.driver.reason, 'most-stuck-tickets');
  assert.deepEqual(stuckTicketEvidence.driver.tickets, ['stuck-queue-ticket-1', 'stuck-queue-ticket-2']);
  console.log('ok - closures, CI waste, and limiter-hours cross SLOW and BROKEN thresholds');
  console.log('ok - most-stuck driver reports stuck tickets instead of completed stage samples');

  const alarmHome = path.join(root, 'alarm');
  const regressionRows = weekRows({ released_issues: 6, queue_to_implement_seconds: 120 });
  regressionRows.at(-1).source_errors = ['ci-runs:unreadable'];
  writeHistory(alarmHome, regressionRows);
  const alarmMessages = [];
  const regression = await sample({
    home: alarmHome,
    repo: 'fixture/example',
    now: new Date('2026-10-08T00:30:00Z'),
    fetchCi: async () => ({ queue_seconds: [], run_seconds: [], errors: [] }),
    sendAlert: async (message) => alarmMessages.push(message),
  });
  assert.equal(regression.status, 'SLOW');
  assert.match(regression.detail, /source-errors=ci-runs:unreadable/);
  assert.equal(regression.alerts.length, 1);
  assert.match(regression.alerts[0].message, /metric=released_issues comparison=rolling-7d current=6 baseline=10/);
  assert.match(regression.alerts[0].message, /stage=queue_to_implement/);
  assert.match(regression.alerts[0].message, /stage-baseline=100/);
  assert.match(regression.alerts[0].message, /tickets=#10001/);
  assert.equal(alarmMessages.length, 1);
  const repeated = await sample({
    home: alarmHome,
    repo: 'fixture/example',
    now: new Date('2026-10-08T00:45:00Z'),
    fetchCi: async () => ({ queue_seconds: [], run_seconds: [], errors: [] }),
    sendAlert: async (message) => alarmMessages.push(message),
  });
  assert.equal(repeated.alerts.length, 0, 'same metric stays quiet inside six hours');
  console.log('ok - synthetic week throughput drop emits one alarm with largest latency increase and ticket');

  const steadyHome = path.join(root, 'steady');
  writeHistory(steadyHome, weekRows({
    released_issues: 11,
    merged_prs: 11,
    tokens: 800,
    tokens_per_released_issue: 80,
    queue_to_implement_seconds: 80,
    implement_to_merge_seconds: 180,
    merge_to_release_seconds: 280,
    repeat_dispatches: 0,
  }));
  const steady = await sample({
    home: steadyHome,
    repo: 'fixture/example',
    now: new Date('2026-10-08T00:30:00Z'),
    fetchCi: async () => ({ queue_seconds: [], run_seconds: [], errors: [] }),
    sendAlert: async () => assert.fail('steady history must not alert'),
  });
  assert.equal(steady.status, 'OK');
  assert.equal(steady.alerts.length, 0);
  console.log('ok - steady or improving history emits no alarm');

  const zeroReleaseHome = path.join(root, 'zero-release');
  writeHistory(zeroReleaseHome, weekRows({ released_issues: 0, tokens: 1000, tokens_per_released_issue: null }));
  const zeroRelease = await sample({
    home: zeroReleaseHome,
    repo: 'fixture/example',
    now: new Date('2026-10-08T00:30:00Z'),
    fetchCi: async () => ({ queue_seconds: [], run_seconds: [], errors: [] }),
    sendAlert: async () => {},
  });
  assert.equal(zeroRelease.status, 'BROKEN');
  assert.ok(zeroRelease.alerts.some(({ message }) => /metric=tokens_per_released_issue comparison=rolling-7d current=infinite baseline=100/.test(message)));
  console.log('ok - zero released tickets with spend alerts as infinite tokens per ticket');

  const shortHome = path.join(root, 'short');
  const shortRows = [];
  const shortStart = Date.parse('2026-10-07T00:00:00Z');
  for (let hour = 0; hour < 22; hour += 1) {
    shortRows.push(row(new Date(shortStart + hour * 60 * 60 * 1000).toISOString()));
  }
  shortRows.push(row('2026-10-07T22:05:00Z', { released_issues: 0 }));
  writeHistory(shortHome, shortRows);
  let shortAlertCount = 0;
  const short = await sample({
    home: shortHome,
    repo: 'fixture/example',
    now: new Date('2026-10-07T22:30:00Z'),
    fetchCi: async () => ({ queue_seconds: [], run_seconds: [], errors: [] }),
    sendAlert: async () => { shortAlertCount += 1; },
  });
  assert.equal(short.status, 'UNKNOWN');
  assert.match(short.detail, /insufficient-history hours=22\/24/);
  assert.equal(shortAlertCount, 0);
  console.log('ok - fewer than 24 hourly samples report UNKNOWN without alarm');

  const sourceHome = path.join(root, 'sources');
  mkdirSync(path.join(sourceHome, 'state'), { recursive: true });
  mkdirSync(path.join(sourceHome, 'spend'), { recursive: true });
  mkdirSync(path.join(sourceHome, 'logs'), { recursive: true });
  const now = new Date('2026-10-08T12:00:00Z');
  const ago = (minutes) => new Date(now.getTime() - minutes * 60_000).toISOString();
  writeFileSync(path.join(sourceHome, 'state/101.json'), JSON.stringify({
    state: 'concluded',
    released: true,
    closed_by_pipeline: true,
    deploy_state: 'deployed',
    deployed_sha: 'a'.repeat(40),
    run: {
      outcome: 'merged',
      entered_at: ago(120),
      implement_started_at: ago(60),
      merged_at: ago(30),
      concluded_at: ago(10),
      evidence: { pr_number: '55',
        merged_pr: {number:55,merged_at:ago(30),merge_sha:'b'.repeat(40)},
        production_evidence_at: ago(10),
        real_user_path:'URL: https://example.test\nVisible DOM: ready\nSame-run network: 200' },
    },
  }));
  writeFileSync(path.join(sourceHome, 'state/102.json'), JSON.stringify({ state: 'ready-for-agent', state_changed_at: ago(60) }));
  appendMetricRecords(sourceHome, [
    { record_type: 'event', event_type: 'ticket-created', event_id: 'create-101', ts: ago(60), issue: '101' },
    { record_type: 'event', event_type: 'stage-entered', event_id: 'enter-ready-101', ts: ago(60), issue: '101', stage: 'ready-for-agent' },
    { record_type: 'event', event_type: 'stage-exited', event_id: 'exit-ready-101', ts: ago(30), issue: '101', stage: 'ready-for-agent' },
    { record_type: 'event', event_type: 'stage-entered', event_id: 'enter-work-101', ts: ago(30), issue: '101', stage: 'in-progress' },
    { record_type: 'event', event_type: 'stage-exited', event_id: 'exit-work-101', ts: ago(5), issue: '101', stage: 'in-progress' },
    { record_type: 'event', event_type: 'stage-entered', event_id: 'enter-closed-101', ts: ago(5), issue: '101', stage: 'closed' },
    { record_type: 'event', event_type: 'ticket-closed', event_id: 'close-101', ts: ago(5), issue: '101' },
    { record_type: 'event', event_type: 'ticket-released', event_id: 'release-101', ts: ago(2), issue: '101' },
    { record_type: 'event', event_type: 'limiter', event_id: 'limit-102', ts: ago(60), issue: '102', category: 'memory', gate: 'dispatch-resources' },
  ]);
  const spendAt = Math.floor((now.getTime() - 20 * 60_000) / 1000);
  writeFileSync(path.join(sourceHome, 'spend/2026-10-08.log'), `${spendAt}\timplement\tcodex:test\t101\t\t1000\n`);
  writeFileSync(path.join(sourceHome, 'logs/implement-101-20261007T000000Z.log'), 'prior attempt\n');
  writeFileSync(path.join(sourceHome, 'logs/implement-101-20261008T114000Z.log'), 'repeat attempt\n');
  writeFileSync(path.join(sourceHome, 'logs/repair-101-20261007T000000Z.log'), 'prior repair\n');
  writeFileSync(path.join(sourceHome, 'logs/repair-101-20261008T114500Z.log'), 'repeat repair\n');
  appendMetricRecords(sourceHome, [
    { record_type:'event', event_type:'dispatch', event_id:'dispatch-old', issue:101, ts:'2026-10-07T00:00:00Z' },
    { record_type:'event', event_type:'dispatch', event_id:'dispatch-new', issue:101, ts:ago(20) },
  ]);
  const collected = await sample({
    home: sourceHome,
    repo: 'fixture/example',
    now,
    fetchCi: async () => ({ queue_seconds: [60, 120], run_seconds: [300, 600], errors: [] }),
    sendAlert: async () => assert.fail('first hourly sample has no baseline'),
  });
  assert.equal(collected.row.metrics.calls, 1);
  assert.equal(collected.row.metrics.tokens, 1000);
  assert.equal(collected.row.metrics.released_issues, 1);
  assert.equal(collected.row.metrics.merged_prs, 1);
  assert.equal(collected.row.metrics.tokens_per_released_issue, 1000);
  assert.equal(collected.row.metrics.queue_to_implement_seconds, 3600);
  assert.equal(collected.row.metrics.implement_to_merge_seconds, 1800);
  assert.equal(collected.row.metrics.merge_to_release_seconds, 1200);
  assert.equal(collected.row.metrics.repeat_dispatches, 1);
  assert.equal(collected.row.metrics.closed_issues, 1);
  assert.equal(collected.row.creations, 1);
  assert.equal(collected.row.closures, 1);
  assert.equal(collected.row.releases, 1);
  assert.equal(collected.row.ready_ticket_count, 1);
  assert.equal(collected.row.ready_not_running_count, 1);
  assert.equal(collected.row.running_implement_count, 0);
  assert.equal(collected.row.limiter_counts.memory, 1);
  assert.equal(collected.row.limiter_ticket_hours_by_reason.memory, 1);
  assert.equal(collected.row.repeat_run_causes.unknown, 1);
  assert.equal(collected.row.stage_ticket_hours['ready-for-agent'], 1.5);
  assert.equal(collected.row.stage_ticket_hours['in-progress'], 25 / 60);
  assert.equal(collected.row.waiting_ticket_hours, 1.5);
  assert.equal(collected.row.working_ticket_hours, 25 / 60);
  assert.equal(collected.row.metrics.ci_queue_seconds, 60);
  assert.equal(collected.row.metrics.ci_run_seconds, 300);
  assert.equal(readMetricRows(sourceHome).filter((item) => item.record_type === 'hourly').length, 1);
  const censusHome = path.join(root, 'live-census');
  mkdirSync(path.join(censusHome, 'state'), { recursive: true });
  for (const [issue, state] of Object.entries({
    1: { state: 'ready-for-agent' }, // closed issue left in state directory
    2: { state: 'ready-for-agent', state_changed_at: ago(120), implement_tick_decision: {
      outcome: 'skipped', gate: 'open-blocker', recorded_at: ago(60), reason: 'open #99', object: '#99',
    } },
    3: { state: 'tracker', tracker_parent: true },
    4: { state: 'ready-for-agent', implement_tick_decision: {
      outcome: 'skipped', gate: 'budget-exhausted', recorded_at: ago(30),
    } },
    6: { state: 'closed', state_changed_at: ago(120) },
    7: { state: 'awaiting-release', state_changed_at: ago(120) },
    5: { state: 'ready-for-agent', state_changed_at: ago(10), implement_tick_decision: {
      outcome: 'skipped', gate: 'capacity', recorded_at: ago(30),
    } },
  })) writeFileSync(path.join(censusHome, `state/${issue}.json`), JSON.stringify(state));
  appendMetricRecords(censusHome, [
    { record_type: 'event', event_type: 'stage-entered', event_id: 'tracker-unrouted', issue: 3, ts: ago(120), stage: 'unrouted' },
    { record_type: 'event', event_type: 'stage-entered', event_id: 'closed-unrouted', issue: 6, ts: ago(120), stage: 'unrouted' },
    { record_type: 'event', event_type: 'stage-entered', event_id: 'release-unrouted', issue: 7, ts: ago(120), stage: 'unrouted' },
    { record_type: 'event', event_type: 'limiter', event_id: 'older-memory', issue: 2, ts: ago(90), gate: 'dispatch-resources', category: 'memory' },
  ]);
  const census = await sample({
    home: censusHome, repo: 'fixture/example', now,
    getRunningIssues: () => ['4'],
    getOpenIssues: async () => [
      { number: 2, labels: [{ name: 'ready-for-agent' }] },
      { number: 3, labels: [] }, { number: 4, labels: [{ name: 'ready-for-agent' }] },
      { number: 5, labels: [{ name: 'ready-for-agent' }] },
      { number: 7, labels: [{ name: 'awaiting-release' }] },
    ],
    fetchCi: async () => ({ queue_seconds: [], run_seconds: [], errors: [] }), sendAlert: async () => {},
  });
  assert.equal(census.row.ready_ticket_count, 3, 'closed local ready must not inflate live queue');
  assert.equal(census.row.ready_not_running_count, 2);
  assert.equal(census.row.limiter_counts.blocked_by, 1, 'newer scheduler state decision wins over old metric event');
  assert.equal(census.row.limiter_counts.unknown, 1, 'decision before re-entry cannot explain current wait');
  assert.equal(census.row.stage_ticket_hours.tracker, 2, 'intentional tracker parents are not unrouted work');
  assert.equal(census.row.stage_ticket_hours.unrouted, undefined);
  assert.equal(census.row.stage_ticket_hours.closed, undefined);
  assert.equal(census.row.stage_ticket_hours['awaiting-release'], 2);
  const closedReadyHome = path.join(root, 'closed-ready-wip');
  mkdirSync(path.join(closedReadyHome, 'state'), { recursive: true });
  writeFileSync(path.join(closedReadyHome, 'state/8.json'), JSON.stringify({
    state: 'ready-for-agent', state_changed_at: ago(48 * 60), implement_tick_decision: {
      outcome: 'skipped', gate: 'capacity', recorded_at: ago(30),
    },
  }));
  appendMetricRecord(closedReadyHome, {
    record_type: 'event', event_type: 'stage-entered', event_id: 'closed-ready-enter',
    ts: ago(48 * 60), issue: '8', stage: 'ready-for-agent',
  });
  const closedReady = await sample({
    home: closedReadyHome, repo: 'fixture/example', now,
    getOpenIssues: async () => [],
    fetchCi: async () => ({ queue_seconds: [], run_seconds: [], errors: [] }), sendAlert: async () => {},
  });
  assert.equal(closedReady.row.limiter_ticket_hours, 0, 'closed ready state contributes no limiter hours');
  assert.equal(closedReady.row.waiting_ticket_hours, 0, 'closed ready stage interval is not current waiting time');
  assert.equal(closedReady.row.stuck_by_stage.queue_to_implement_seconds.count, 0,
    'closed ready state is excluded from queue WIP');
  const unavailable = await sample({
    home: censusHome, repo: 'fixture/example', now: new Date(now.getTime() + 3600000),
    getOpenIssues: async () => { throw new Error('offline'); },
    fetchCi: async () => ({ queue_seconds: [], run_seconds: [], errors: [] }), sendAlert: async () => {},
  });
  assert.equal(unavailable.row.ready_ticket_count, null, 'unreadable live census never falls back to stale local ready');
  assert.ok(unavailable.row.source_errors.includes('open-issues:unreadable'));
  console.log('ok - live labels, scheduler decisions, re-entry and tracker semantics drive attribution');
  const proofHome = path.join(root, 'merge-proof');
  mkdirSync(path.join(proofHome, 'state'), { recursive: true });
  writeFileSync(path.join(proofHome, 'state/10.json'), JSON.stringify({ state: 'awaiting-release', run: {
    outcome: 'merged', implement_started_at: ago(3 * 24 * 60), merged_at: ago(10),
    evidence: { pr_number: '110', merged_pr: { number: 110, merged_at: ago(2 * 24 * 60) } },
  } }));
  const proof = await sample({ home: proofHome, repo: 'fixture/example', now,
    fetchCi: async () => ({ queue_seconds: [], run_seconds: [], errors: [] }), sendAlert: async () => {},
  });
  assert.equal(proof.row.metrics.merged_prs, 0, 'reconciliation time cannot count old PR as new merge');
  assert.equal(proof.row.metrics.implement_to_merge_seconds, null);
  console.log('ok - exact PR merge proof takes precedence over local reconciliation timestamp');
  const summary = efficiencySummary(sourceHome);
  assert.equal(summary.current_24h.metrics.closed_issues, 1);
  assert.equal(summary.previous_24h, null);
  assert.equal(summary.baseline_2026_10_10.metrics.closed_issues, 7);
  const cliSummary = spawnSync(process.execPath, [
    new URL('./efficiency-regression.mjs', import.meta.url).pathname, 'summary', '--home', sourceHome,
  ], { encoding: 'utf8' });
  assert.equal(cliSummary.status, 0, cliSummary.stderr);
  assert.equal(JSON.parse(cliSummary.stdout).current_24h.metrics.closed_issues, 1);
  const comparativeSummary = efficiencySummary(alarmHome);
  assert.ok(comparativeSummary.previous_24h);
  assert.equal(comparativeSummary.baseline_2026_10_10.metrics.closed_issues, 7);
  console.log('ok - hourly row reads spend, release, merge, stage, repeat-dispatch, and GitHub CI sources');

  const maintainerHome = path.join(root, 'founder-mail-efficiency');
  mkdirSync(path.join(maintainerHome, 'night'), { recursive: true });
  mkdirSync(path.join(maintainerHome, 'land-queue', 'logs'), { recursive: true });
  mkdirSync(path.join(maintainerHome, 'land-queue', 'requests'), { recursive: true });
  const maintainerNow = '2026-10-13T12:00:00Z';
  const maintainerJournal = path.join(maintainerHome, 'journal.jsonl');
  writeFileSync(maintainerJournal, [
    { __REALTIME_TIMESTAMP: String(Date.parse('2026-10-13T06:10:00Z') * 1000), MESSAGE: 'timing tick=current-a section=read elapsed_sec=120' },
    { __REALTIME_TIMESTAMP: String(Date.parse('2026-10-13T06:11:00Z') * 1000), MESSAGE: 'timing tick=current-a section=dispatch elapsed_sec=180' },
    { __REALTIME_TIMESTAMP: String(Date.parse('2026-10-13T00:10:00Z') * 1000), MESSAGE: 'timing tick=previous-a section=read elapsed_sec=360' },
    { __REALTIME_TIMESTAMP: String(Date.parse('2026-10-13T00:11:00Z') * 1000), MESSAGE: 'timing tick=previous-a section=dispatch elapsed_sec=240' },
    { __REALTIME_TIMESTAMP: String(Date.parse('2026-10-12T06:10:00Z') * 1000), MESSAGE: 'timing tick=yesterday-a section=read elapsed_sec=420' },
  ].map((row) => JSON.stringify(row)).join('\n'));
  writeFileSync(path.join(maintainerHome, 'night/efficiency-ci-jobs.json'), JSON.stringify({ version: 3, runs: {
    '1:1': { created_at: '2026-10-13T06:30:00Z', conclusion: 'failure', event: 'pull_request', run_seconds: [100] },
    '2:1': { created_at: '2026-10-13T07:00:00Z', conclusion: 'success', event: 'push', head_branch: 'main', run_seconds: [400] },
    '3:1': { created_at: '2026-10-13T08:00:00Z', conclusion: 'failure', event: 'push', head_branch: 'main', run_seconds: [100] },
    '4:1': { created_at: '2026-10-13T01:00:00Z', conclusion: 'failure', event: 'pull_request', run_seconds: [100] },
    '5:1': { created_at: '2026-10-13T02:00:00Z', conclusion: 'success', event: 'push', head_branch: 'main', run_seconds: [100] },
    '6:1': { created_at: '2026-10-12T07:00:00Z', conclusion: 'failure', event: 'pull_request', run_seconds: [100] },
    '7:1': { created_at: '2026-10-12T08:00:00Z', conclusion: 'success', event: 'push', head_branch: 'main', run_seconds: [100] },
    '8:1': { created_at: '2026-10-13T09:00:00Z', conclusion: 'success', event: 'push', head_branch: 'feature', run_seconds: [100] },
  } }));
  writeFileSync(path.join(maintainerHome, 'night/supervisor-dispatch-queue.tsv.done'), [
    '2026-10-13T06:20:00Z\thand-a\tdispatched',
    '2026-10-13T07:20:00Z\thand-a\tdispatched',
    '2026-10-13T08:20:00Z\thand-b\tFAILED route unavailable',
    '2026-10-13T00:20:00Z\thand-a\tdispatched',
    '2026-10-13T01:20:00Z\thand-b\tdispatched',
    '2026-10-12T07:20:00Z\thand-a\tdispatched',
  ].join('\n'));
  writeFileSync(path.join(maintainerHome, 'land-queue/logs/receipts.log'), [
    'post-land-verify: receipt ticket=alpha outcome=green at=2026-10-13T06:45:00Z',
    'post-land-verify: receipt ticket=alpha outcome=green at=2026-10-13T06:45:00Z',
    'post-land-verify: receipt ticket=beta outcome=inconclusive at=2026-10-13T07:45:00Z',
    'post-land-verify: receipt ticket=gamma outcome=pre-existing at=2026-10-13T00:45:00Z',
    'post-land-verify: receipt ticket=delta outcome=culprit-test at=2026-10-12T06:45:00Z',
  ].join('\n'));
  writeFileSync(path.join(maintainerHome, 'land-queue/requests/failed-current.json'), JSON.stringify({ state: 'failed', updated_epoch: Date.parse('2026-10-13T09:00:00Z') / 1000 }));
  writeFileSync(path.join(maintainerHome, 'night/ps-issues.json'), JSON.stringify([
    { createdAt: '2026-10-13T06:30:00Z', closedAt: '2026-10-13T07:00:00Z', labels: [{ name: 'pipeline-system' }] },
    { createdAt: '2026-10-13T08:30:00Z', closedAt: '2026-10-13T08:45:00Z', labels: ['pipeline-system'] },
    { createdAt: '2026-10-13T09:30:00Z', closedAt: null, labels: [{ name: 'pipeline-system' }] },
    { createdAt: '2026-10-13T01:30:00Z', closedAt: '2026-10-13T02:00:00Z', labels: [{ name: 'pipeline-system' }] },
    { createdAt: '2026-10-12T07:30:00Z', closedAt: '2026-10-12T08:00:00Z', labels: [{ name: 'pipeline-system' }] },
  ]));
  const maintainerStats = maintainerMailEfficiencySummary(maintainerHome, maintainerNow, { journalFile: maintainerJournal });
  assert.equal(maintainerStats.metrics.current.tickSeconds, 300);
  assert.equal(maintainerStats.metrics.previous.tickSeconds, 600);
  assert.equal(maintainerStats.metrics.yesterday.tickSeconds, 420);
  assert.equal(maintainerStats.metrics.current.ciWaste, 2 / 7);
  assert.equal(maintainerStats.metrics.current.mainGreen, 0.5);
  assert.equal(maintainerStats.metrics.current.postLandEffective, 0.5, 'duplicate ticket+time receipt counts once');
  assert.equal(maintainerStats.metrics.current.dispatchFailures, 1);
  assert.equal(maintainerStats.metrics.current.repeatedDispatches, 2);
  assert.deepEqual(maintainerStats.metrics.current.pipelineIssues, { created: 3, closed: 2 });
  const maintainerDigest = renderMaintainerMailEfficiency(maintainerStats);
  assert.match(maintainerDigest, /\| 指标 \| 当前六小时 \| 前六小时 \| 昨日同时段 \|/);
  assert.match(maintainerDigest, /自动检查浪费占比较前六小时下降43%/);
  assert.match(maintainerDigest, /系统自动开单 \/ 关单 \| 3 \/ 2 次 \| 1 \/ 1 次 \| 1 \/ 1 次 \|/);
  console.log(`fixture maintainer digest:\n${maintainerDigest}`);
  console.log('ok - maintainer digest renders fixture-backed six-hour efficiency windows and >20% movement');

  const cacheHome = path.join(root, 'cache');
  const jobCalls = [];
  const run = (id, attempt, createdAt, conclusion = 'success') => ({
    id, run_attempt: attempt, created_at: createdAt, conclusion, head_branch: 'main',
  });
  let runs = [
    run(101, 1, '2026-10-08T10:00:00Z'),
    run(202, 1, '2026-10-08T10:15:00Z', 'cancelled'),
  ];
  const timings = {
    '101:1': [10, 20],
    '101:2': [40, 50],
    '202:1': [20, 30],
    '303:1': [60, 90],
  };
  const fakeGh = async (endpoint, collection) => {
    if (collection === 'workflow_runs') return runs;
    const id = Number(endpoint.match(/\/runs\/(\d+)\/jobs/)[1]);
    const currentRun = runs.find((item) => item.id === id);
    const [queueSeconds, runSeconds] = timings[`${id}:${currentRun.run_attempt}`];
    jobCalls.push(`${id}:${currentRun.run_attempt}`);
    const started = Date.parse(currentRun.created_at) + queueSeconds * 1000;
    return [{
      created_at: currentRun.created_at,
      started_at: new Date(started).toISOString(),
      completed_at: new Date(started + runSeconds * 1000).toISOString(),
    }];
  };
  const cachedFetchCi = (repo, since, options) => collectGitHubCiSamples(repo, since, {
    ...options,
    fetchPages: fakeGh,
  });
  const ciVerdictRuns = [
    run(401, 1, '2026-10-08T10:00:00Z', 'success'),
    run(402, 1, '2026-10-08T10:15:00Z', 'failure'),
    run(403, 1, '2026-10-08T10:30:00Z', 'cancelled'),
  ];
  const ciVerdictSeconds = { 401: 100, 402: 100, 403: 50 };
  const ciVerdicts = await collectGitHubCiSamples('fixture/example', Date.parse('2026-10-08T00:00:00Z'), {
    cacheFile: path.join(root, 'ci-verdicts.json'),
    nowMs: Date.parse('2026-10-08T12:00:00Z'),
    fetchPages: async (endpoint, collection) => {
      if (collection === 'workflow_runs') return endpoint.includes('event=push') ? ciVerdictRuns : [];
      const id = Number(endpoint.match(/\/runs\/(\d+)\/jobs/)[1]);
      const ciRun = ciVerdictRuns.find((item) => item.id === id);
      const duration = ciVerdictSeconds[id];
      return [{
        created_at: ciRun.created_at,
        started_at: ciRun.created_at,
        completed_at: new Date(Date.parse(ciRun.created_at) + duration * 1000).toISOString(),
      }];
    },
  });
  assert.equal(ciVerdicts.main_green_share, 0.5, 'cancelled main runs have no green/red verdict');
  assert.equal(ciVerdicts.ci_waste_share, 0.6, 'cancelled runs still count their consumed runner time as waste');
  assert.equal(JSON.parse(readFileSync(path.join(root, 'ci-verdicts.json'), 'utf8')).runs['401:1'].head_branch, 'main');
  console.log('ok - cancelled main runs do not count as red verdicts, but their runner time remains CI waste');
  const runPageCalls = [];
  const sampledRunWindow = await collectGitHubCiSamples('fixture/example', '2026-10-11T00:00:00Z', {
    cacheFile: path.join(root, 'bounded-ci.json'),
    nowMs: Date.parse('2026-10-11T23:59:59.999Z'),
    deadlineMs: Date.now() + 60_000,
    fetchPages: async (endpoint, collection, _timeoutMs, options) => {
      if (collection === 'workflow_runs') {
        runPageCalls.push({ endpoint, options });
        if (endpoint.includes('event=push')) return { total_count: 0, workflow_runs: [] };
        const page = Number(new URL(`https://fixture/${endpoint}`).searchParams.get('page'));
        const runs = Array.from({ length: page === 3 ? 50 : 100 }, (_, index) => {
          const runIndex = (page - 1) * 100 + index;
          return run(9000 + runIndex, 1, new Date(Date.parse('2026-10-11T00:00:00Z') + runIndex * 60_000).toISOString());
        });
        return page === 1 ? { total_count: 250, workflow_runs: runs } : runs;
      }
      const id = Number(endpoint.match(/\/runs\/(\d+)\/jobs/)[1]);
      const created = new Date(Date.parse('2026-10-11T00:00:00Z') + (id - 9000) * 60_000).toISOString();
      return [{ created_at: created, started_at: new Date(Date.parse(created) + 1000).toISOString(),
        completed_at: new Date(Date.parse(created) + 11_000).toISOString() }];
    },
  });
  assert.equal(sampledRunWindow.sampled_runs.pr, 20, 'CI run samples keep the 20-run cohort limit');
  assert.equal(sampledRunWindow.sampled_workflow_runs.pr, 20);
  assert.equal(sampledRunWindow.workflow_population.pr, 250, 'runner demand uses full cohort size as projection denominator');
  assert.equal(runPageCalls.filter((call) => call.endpoint.includes('event=pull_request')).length, 3,
    'even sample positions fetch only pages that contain a selected run');
  assert.ok(runPageCalls.every((call) => call.options.paginate === false), 'sample pages never fetch the full run history');
  assert.ok(runPageCalls[0].endpoint.includes('created=2026-10-11..2026-10-11'), 'daily query bounds runs to the requested UTC day');
  assert.ok(!sampledRunWindow.errors.includes('ci-pr-runs:unreadable'));
  assert.equal(sampledRunWindow.sample_method, 'bounded-stratified-bottom-k-run-id-v1');
  console.log('ok - CI sampler reads bounded pages and samples across the full day');

  const replayStartMs = Date.parse('2026-10-14T00:00:00Z');
  const replayPrRuns = Array.from({ length: 250 }, (_, index) => run(
    10000 + index, 1, new Date(replayStartMs + index * 10_000).toISOString(),
  ));
  const replayMainRuns = Array.from({ length: 80 }, (_, index) => run(
    20000 + index, 1, new Date(replayStartMs + index * 30_000).toISOString(),
  ));
  const runRank = (id) => createHash('sha256').update(String(id)).digest('hex');
  const initialPrCutoff = replayPrRuns.map((item) => runRank(item.id)).sort()[19];
  const addedIds = [];
  for (let candidate = 50000; addedIds.length < 24; candidate += 1) {
    if (runRank(candidate) > initialPrCutoff) addedIds.push(candidate);
  }
  const replayCalls = { runPages: 0, jobs: 0 };
  const replayCacheFile = path.join(root, 'hourly-replay/efficiency-ci-jobs.json');
  const initialSelected = new Set();
  for (let hour = 0; hour < 24; hour += 1) {
    const createdAt = new Date(replayStartMs + (hour + 1) * 60 * 60 * 1000).toISOString();
    replayPrRuns.push(run(addedIds[hour], 1, createdAt));
    const nowMs = replayStartMs + (hour + 1) * 60 * 60 * 1000;
    const runPagesBefore = replayCalls.runPages;
    const jobsBefore = replayCalls.jobs;
    const replay = await collectGitHubCiSamples('fixture/example', nowMs - 24 * 60 * 60 * 1000, {
      cacheFile: replayCacheFile,
      nowMs,
      deadlineMs: Date.now() + 60_000,
      fetchPages: async (endpoint, collection, _timeoutMs, options) => {
        if (collection === 'workflow_runs') {
          replayCalls.runPages += 1;
          const cohort = [...(endpoint.includes('event=pull_request') ? replayPrRuns : replayMainRuns)]
            .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
          const page = Number(new URL(`https://fixture/${endpoint}`).searchParams.get('page')) || 1;
          const pageRuns = cohort.slice((page - 1) * 100, page * 100);
          return options.includeTotalCount
            ? { total_count: cohort.length, workflow_runs: pageRuns }
            : pageRuns;
        }
        replayCalls.jobs += 1;
        const id = Number(endpoint.match(/\/runs\/(\d+)\/jobs/)[1]);
        const item = [...replayPrRuns, ...replayMainRuns].find((candidate) => candidate.id === id);
        const started = Date.parse(item.created_at) + 1000;
        return [{
          name: 'fixture job',
          created_at: item.created_at,
          started_at: new Date(started).toISOString(),
          completed_at: new Date(started + 5000).toISOString(),
        }];
      },
    });
    assert.equal(replay.sample_method, 'bounded-stratified-bottom-k-run-id-v1');
    assert.equal(replay.sampled_workflow_runs.pr, 20);
    assert.equal(replay.sampled_workflow_runs.main, 20, 'PR and main keep separate, representative cohorts');
    assert.equal(replay.workflow_run_page_requests, replayCalls.runPages - runPagesBefore);
    assert.equal(replay.jobs_requests, replayCalls.jobs - jobsBefore);
    const selected = new Set(replay.job_samples.map((job) => `${job.cohort}:${job.workflow_run_id}`));
    if (hour === 0) for (const key of selected) initialSelected.add(key);
    else assert.deepEqual(selected, initialSelected, 'a new run outside the bottom-k cutoff preserves existing sample identities');
  }
  assert.equal(replayCalls.runPages, 24 * 4, '24-hour replay counts every PR/main run-list page');
  assert.equal(replayCalls.jobs, 40, 'cached bottom-k samples fetch each selected run only once');
  assert.equal(replayCalls.runPages + replayCalls.jobs, 136, 'replay reports run-list pages plus job requests');
  console.log(`ok - 24-hour CI replay: run-list pages=${replayCalls.runPages}, jobs=${replayCalls.jobs}, total=${replayCalls.runPages + replayCalls.jobs}`);

  const neverStarted = await collectGitHubCiSamples('fixture/example', '2026-10-11T00:00:00Z', {
    nowMs: Date.parse('2026-10-11T23:59:59.999Z'),
    fetchPages: async (endpoint, collection) => {
      if (collection === 'workflow_runs') return endpoint.includes('event=pull_request')
        ? [run(9500, 1, '2026-10-11T00:00:00Z')] : [];
      return [
        { name: 'runner job', runner_id: 42, steps_count: 1, created_at: '2026-10-11T00:00:00Z', started_at: '2026-10-11T00:00:10Z', completed_at: '2026-10-11T00:01:00Z' },
        { name: 'queued job', runner_id: 0, steps_count: 0, created_at: '2026-10-11T00:00:00Z', completed_at: '2026-10-11T03:21:35Z' },
        { name: 'unknown runner', runner_id: null, steps_count: 0, created_at: '2026-10-11T00:00:00Z', completed_at: '2026-10-11T00:00:20Z' },
      ];
    },
  });
  assert.deepEqual(neverStarted.run_seconds, [50], 'only work with a runner and steps counts as runner time');
  assert.deepEqual(neverStarted.queue_seconds, [10, 12095], 'never-started elapsed time remains queue time');
  assert.equal(neverStarted.job_samples.find((job) => job.name === 'queued job').never_started, true);
  assert.equal(neverStarted.job_samples.find((job) => job.name === 'queued job').run_seconds, null);
  assert.equal(neverStarted.job_samples.find((job) => job.name === 'unknown runner').never_started, false,
    'missing runner ID is not coerced to runner_id=0');
  console.log('ok - zero-runner zero-step jobs count as queue only, with no fabricated runner time');
  const firstCacheSample = await sample({
    home: cacheHome,
    repo: 'fixture/example',
    now: new Date('2026-10-08T12:00:00Z'),
    fetchCi: cachedFetchCi,
    sendAlert: async () => assert.fail('cache fixture must not alert'),
  });
  runs = [
    run(101, 2, '2026-10-08T10:00:00Z'),
    run(202, 1, '2026-10-08T10:15:00Z', 'cancelled'),
    run(303, 1, '2026-10-08T12:30:00Z'),
  ];
  const secondCacheSample = await sample({
    home: cacheHome,
    repo: 'fixture/example',
    now: new Date('2026-10-08T13:00:00Z'),
    fetchCi: cachedFetchCi,
    sendAlert: async () => assert.fail('cache fixture must not alert'),
  });
  assert.deepEqual(jobCalls, ['101:1', '202:1', '101:2', '303:1']);
  assert.equal(firstCacheSample.row.metrics.ci_queue_seconds, 10);
  assert.equal(secondCacheSample.row.metrics.ci_queue_seconds, 40);
  assert.equal(secondCacheSample.row.metrics.ci_run_seconds, 50);
  assert.equal(firstCacheSample.row.ci_sample_method, 'bounded-stratified-bottom-k-run-id-v1');
  assert.equal(firstCacheSample.row.ci_run_list_page_requests, 2);
  assert.equal(firstCacheSample.row.ci_job_requests, 2);
  assert.equal(JSON.parse(readFileSync(path.join(cacheHome, 'night/efficiency-ci-jobs.json'), 'utf8'))
    .workflow_runs['pr:101'].run_attempt, 2, 'run metadata advances to a rerun attempt');
  console.log('ok - hourly CI cache fetches only unseen run attempts and includes cancelled runs');

  const staleCacheFile = path.join(root, 'stale-ci-cache.json');
  writeFileSync(staleCacheFile, JSON.stringify({ version: 3, runs: {
    '404:1': {
      created_at: '2026-10-08T11:00:00Z', conclusion: 'success', queue_seconds: [1], run_seconds: [2], jobs: [],
    },
  }, workflow_runs: {
    'pr:404': { id: 404, run_attempt: 1, created_at: '2026-10-08T11:00:00Z', cohort: 'pr', conclusion: 'success' },
  } }));
  const staleCacheSample = await collectGitHubCiSamples('fixture/example', '2026-10-08T12:00:00Z', {
    cacheFile: staleCacheFile,
    nowMs: Date.parse('2026-10-09T12:00:00Z'),
    fetchPages: async () => [],
  });
  assert.deepEqual(staleCacheSample.job_samples, [], 'expired run metadata cannot enter a later sample');
  const expiredCache = JSON.parse(readFileSync(staleCacheFile, 'utf8'));
  assert.deepEqual(expiredCache.runs, {}, 'expired cached job inputs are evicted');
  assert.deepEqual(expiredCache.workflow_runs, {}, 'expired workflow run metadata is evicted');

  const terminalRows = closedIssueMetricRows([
    { number: 1, state: 'closed', closed_at: '2026-10-10T00:00:00Z' },
    { number: 2, state: 'open', closed_at: null },
    { number: 3, state: 'closed', closed_at: 'invalid' },
    { number: 4, state: 'closed', closed_at: '2026-10-10T00:00:00Z', pull_request: {} },
  ]);
  assert.deepEqual(closedIssueMetricRows([
    {number:5,state:'closed',created_at:'2026-10-01T00:00:00Z',closed_at:'2026-10-04T00:00:00Z'},
  ]).map((row) => row.event_type), ['github-opened', 'github-closed'],
  'closed issue census records exact create and close times');
  assert.equal(terminalRows.length, 1);
  assert.equal(terminalRows[0].event_type, 'github-closed', 'census must not double-count ticket-closed writer events');
  const closedInterval = weeklyTimeSinks([{ record_type: 'event', issue: 1, event_type: 'stage-entered',
    stage: 'awaiting-release', ts: '2026-10-08T00:00:00Z' }, ...terminalRows], '2026-10-15T00:00:00Z');
  assert.equal(closedInterval.current.observed_ticket_hours, 48, 'authoritative external closure stops a stale local stage');
  const terminalCensusHome = path.join(root, 'closed-census');
  mkdirSync(path.join(terminalCensusHome, 'state'), { recursive: true });
  await sample({home: terminalCensusHome, repo: 'fixture/example', now: new Date('2026-10-15T00:00:00Z'),
    getClosedIssues: async () => [{ number: 1, state: 'closed', closed_at: '2026-10-10T00:00:00Z' }],
    fetchCi: async () => ({queue_seconds:[],run_seconds:[],errors:[]}), sendAlert: async () => {}});
  assert.equal(readMetricRows(terminalCensusHome).filter((r) => r.event_type === 'github-closed').length, 1);
  assert.equal(efficiencySummary(terminalCensusHome, '2026-10-15T00:00:00Z').weekly_time_sinks.closed_census_at, '2026-10-15T00:00:00.000Z');
  console.log('ok - closed issue census stops stale waiting intervals without counting closures twice');

  const end = Date.parse('2026-10-15T00:00:00Z');
  const event = (issue, type, stage, ts) => ({ record_type: 'event', issue, event_type: type, stage, ts });
  const sinkRows = [
    event('1', 'stage-entered', 'ready-for-agent', '2026-10-01T00:00:00Z'),
    event('1', 'stage-exited', 'ready-for-agent', '2026-10-10T00:00:00Z'),
    event('1', 'stage-entered', 'awaiting-release', '2026-10-10T00:00:00Z'),
    event('1', 'ticket-released', 'released', '2026-10-11T00:00:00Z'),
    event('1', 'stage-entered', 'unrouted', '2026-10-11T00:01:00Z'),
    event('2', 'stage-entered', 'tracker', '2026-10-01T00:00:00Z'),
    event('3', 'stage-entered', 'on-hold', '2026-10-08T00:00:00Z'),
    event('4', 'stage-entered', 'closed', '2026-10-01T00:00:00Z'),
    event('4', 'stage-entered', 'ready-for-agent', '2026-10-14T00:00:00Z'),
    event('4', 'stage-entered', 'awaiting-release', '2026-10-16T00:00:00Z'),
  ];
  const sinks = weeklyTimeSinks(sinkRows.reverse(), end);
  assert.equal(sinks.current.observed_ticket_hours, 264, 'clip at week boundaries; exclude terminal, future and tracker time');
  assert.equal(sinks.top5[0].stage, 'on-hold');
  assert.equal(sinks.top5.find((item) => item.stage === 'ready-for-agent').hours_per_day, 72 / 7);
  assert.equal(sinks.top5.find((item) => item.stage === 'ready-for-agent').previous_hours_per_day, 24);
  assert.equal(sinks.previous.observed_ticket_hours, 168);
  assert.equal(sinks.top5.some((item) => item.stage === 'unrouted'), false, 'label stripping after release must not reopen a ticket');
  assert.equal(weeklyTimeSinks([], end).current.history_spans_window, false);
  const partial = weeklyTimeSinks([event('1', 'stage-entered', 'ready-for-agent', '2026-10-14T00:00:00Z')], end);
  assert.equal(partial.top5[0].previous_hours_per_day, null, 'missing prior-week history is unknown, not zero');
  assert.equal(weeklyTimeSinks(sinkRows, end).top5[0].previous_hours_per_day, 0, 'observed old week without this stage is zero');
  assert.ok(efficiencySummary(cacheHome, new Date(end).toISOString()).weekly_time_sinks);
  const specialWaits = weeklyTimeSinks([
    event('20', 'stage-entered', 'needs-advisor', '2026-10-08T00:00:00Z'),
    event('21', 'stage-entered', 'on-hold', '2026-10-08T00:00:00Z'),
    event('22', 'stage-entered', 'container-check', '2026-10-08T00:00:00Z'),
  ], end);
  assert.deepEqual(specialWaits.special_waits, {
    advisor_issue_hours_per_day: 24,
    hold_issue_hours_per_day: 24,
    container_issue_hours_per_day: 24,
    container_stages: ['container-check'],
  }, 'advisor, hold, and container waits remain separate from lifecycle phases');
  const semanticSinks = weeklyTimeSinks([
    event('5', 'stage-entered', 'unrouted', '2026-10-08T00:00:00Z'),
    event('6', 'stage-entered', 'unrouted', '2026-10-10T00:00:00Z'),
    event('6', 'stage-exited', 'unrouted', '2026-10-11T00:00:00Z'),
  ], end, [{issue:'5',state:{tracker_parent:true}}, {issue:'6',state:{state:'awaiting-release',state_changed_at:'2026-10-10T00:00:00Z'}}]);
  assert.equal(semanticSinks.current.observed_ticket_hours,24,'weekly rollup shares existing tracker and same-transition release semantics');
  assert.equal(semanticSinks.top5[0].stage,'awaiting-release');

  const reopenHome = path.join(root, 'reopen-transition');
  mkdirSync(path.join(reopenHome, 'state'), {recursive:true});
  writeFileSync(path.join(reopenHome, 'state/ticket-transitions.jsonl'), JSON.stringify({
    event_id:'close-reopen-1',issue:23,from_stage:'released',to_stage:'ready-for-agent',
    ts:'2026-10-14T12:00:00Z',writer:'fixture',
  }) + '\n');
  await sample({home:reopenHome,repo:'fixture/example',now:new Date('2026-10-15T00:00:00Z'),
    getOpenIssues:async()=>[],getClosedIssues:async()=>[],
    fetchCi:async()=>({queue_seconds:[],run_seconds:[],errors:[]}),sendAlert:async()=>{}});
  assert.ok(readMetricRows(reopenHome).some((row) => row.event_type === 'ticket-reopened' && row.issue === 23),
    'terminal-to-open transition records a reopen boundary');

  console.log('ok - weekly sinks use disjoint raw stage intervals, retain incomplete-history status and never sum rolling daily snapshots');

  const deliveryEnd = Date.parse('2026-10-15T00:00:00Z');
  const deliverySince = deliveryEnd - 7 * 24 * 60 * 60 * 1000;
  const deliverySha = 'a'.repeat(40);
  const deliveryHeadSha = 'd'.repeat(40);
  const deliveryRows = runLifecycleMetricRows(100, {
    attempts: 2,
    deploy_state: 'deployed',
    deployed_sha: deliverySha,
    run: {
      implement_started_at: '2026-10-07T00:00:00Z',
      implement_started_sha: 'c'.repeat(40),
      implement_started_attempt: 2,
      evidence: {
        pr_number: 77,
        implementation_ended_at: '2026-10-09T02:00:00Z',
        implementation_head_sha: deliveryHeadSha,
        implementation_attempt: 2,
        review_ready_at: '2026-10-09T03:00:00Z',
        reviewed_head_sha: deliveryHeadSha,
        review_attempt: 2,
        ci_started_at: '2026-10-09T03:00:00Z',
        ci_completed_at: '2026-10-09T04:00:00Z',
        ci_head_sha: deliveryHeadSha,
        ci_attempt: 2,
        ci_jobs: [
          {run_id:'88',run_attempt:1,job_id:'99',head_sha:deliveryHeadSha,testcontainers_job:true,
            started_at:'2026-10-09T03:00:00Z',completed_at:'2026-10-09T04:00:00Z',runner_seconds:3600},
          {run_id:'89',run_attempt:1,job_id:'100',head_sha:deliveryHeadSha,testcontainers_job:false,
            started_at:'2026-10-09T03:30:00Z',completed_at:'2026-10-09T04:00:00Z',runner_seconds:1800},
        ],
        merged_pr: {number:77,merge_sha:'e'.repeat(40),merged_at:'2026-10-09T05:00:00Z'},
        production_build: {attempt:2,sha:deliverySha,run_id:'22',started_at:'2026-10-09T06:00:00Z',completed_at:'2026-10-09T07:00:00Z'},
        production_roll: {attempt:2,deployed_sha:deliverySha,started_at:'2026-10-09T07:00:00Z',completed_at:'2026-10-09T08:00:00Z'},
        production_evidence_at:'2026-10-09T12:00:00Z',
        production_evidence_attempt:2,
        real_user_path:'URL: https://example.test\nVisible DOM: ready\nSame-run network: 200',
      },
    },
  });
  const deliveryCensus = Array.from({length:168}, (_, hour) => ({
    record_type:'event',event_type:'lifecycle-census',
    ts:new Date(deliverySince + hour * 60 * 60 * 1000).toISOString(),
  }));
  const directRows = runLifecycleMetricRows(101, {
    attempts: 1,
    pipeline_system: {enabled:true,commit_sha:'b'.repeat(40),landed_at:'2026-10-10T00:00:00Z',landed_attempt:1},
    run: {outcome:'pipeline-system'},
  });
  assert.equal(runLifecycleMetricRows(103,{attempts:1,run:{merged_at:'2026-10-09T05:00:00Z',
    evidence:{pr_number:77}}}).some((row) => row.event_type === 'merged'),false,
  'legacy local merge timestamp does not become lifecycle proof without exact PR evidence');
  const pathState = {attempts:1,run:{implement_started_at:'2026-10-08T00:00:00Z',
    implement_started_sha:deliveryHeadSha,implement_started_attempt:1}};
  const unclassifiedStart = runLifecycleMetricRows(102,pathState).find((row) => row.event_type === 'implementation-started');
  const directStart = runLifecycleMetricRows(102,{...pathState,pipeline_system:{enabled:true}})
    .find((row) => row.event_type === 'implementation-started');
  assert.equal(unclassifiedStart.delivery_path,'product-release');
  assert.equal(directStart.delivery_path,'pipeline-system-direct-main');
  assert.notEqual(directStart.event_id,unclassifiedStart.event_id,
    'delivery-path correction can append direct start after an initially unclassified product-path snapshot');
  const implementationEndAt = '2026-10-08T00:00:01Z';
  const implementationEndFor = (sha) => runLifecycleMetricRows(102,{attempts:1,run:{evidence:{
    implementation_ended_at:implementationEndAt,implementation_head_sha:sha,implementation_attempt:1,
  }}}).find((row) => row.event_type === 'implementation-ended');
  assert.notEqual(implementationEndFor('e'.repeat(40)).event_id,implementationEndFor('f'.repeat(40)).event_id,
    'same-second repair completion remains distinct by implementation SHA');
  const delivery = weeklyDeliveryMetrics([
    ...deliveryRows,
    {record_type:'event',event_type:'github-opened',issue:100,ts:'2026-10-09T00:00:00Z'},
    ...directRows,
    ...deliveryCensus,
  ], deliveryEnd);
  assert.equal(delivery.window.complete, true, '168 hourly census points cover a full week');
  assert.equal(delivery.product_release_count, 1);
  assert.equal(delivery.pipeline_system_direct_main_count, 1, 'direct-main landing remains separate from product releases');
  assert.equal(delivery.open_to_released.median_seconds, 12 * 3600);
  assert.equal(delivery.stages.implementation.issue_hours_per_day, 26 / 7, 'implementation interval clips at week start');
  assert.equal(delivery.stages.implementation.coverage, 1);
  assert.equal(delivery.stages.checks.issue_hours_per_day, 2 / 7);
  assert.equal(delivery.stages.merge.issue_hours_per_day, 1 / 7);
  assert.equal(delivery.stages.build_roll.issue_hours_per_day, 3 / 7);
  assert.equal(delivery.stages.production_proof.issue_hours_per_day, 4 / 7);
  assert.equal(delivery.ci_runner_seconds, 5400, 'runner time stays separate from ticket stage hours');
  assert.equal(delivery.testcontainers_job_runner_seconds, 3600, 'Testcontainers runner job time is reported separately');
  const sparseCensus = deliveryCensus.filter((_, hour) => hour !== 80).concat(
    {record_type:'event',event_type:'lifecycle-census',ts:new Date(deliverySince + 31 * 60_000).toISOString()},
    {record_type:'event',event_type:'lifecycle-census',ts:new Date(deliveryEnd).toISOString()},
  );
  const sparseWindow = weeklyDeliveryMetrics([...deliveryRows, ...directRows, ...sparseCensus], deliveryEnd + 30 * 60 * 1000);
  assert.equal(sparseWindow.window.census_hours, 168);
  assert.equal(sparseWindow.window.complete, false, 'one missing hourly census cannot claim complete coverage');

  const replayHome = path.join(root, 'lifecycle-replay');
  appendMetricRecords(replayHome, [...deliveryRows, ...deliveryRows]);
  assert.equal(readMetricRows(replayHome).filter((row) => row.event_type === 'production-proof').length, 1,
    'replaying lifecycle state preserves one proof event');
  assert.equal(readMetricRows(replayHome).filter((row) => row.event_type === 'ci-job-completed').length, 2,
    'same-time CI jobs keep distinct idempotency keys');
  assert.equal(weeklyDeliveryMetrics(readMetricRows(replayHome), deliveryEnd).ci_runner_seconds, 5400,
    'replayed CI jobs retain all runner time');
  const issueSyncHome = path.join(root, 'lifecycle-issue-sync');
  mkdirSync(path.join(issueSyncHome, 'state'), {recursive:true});
  writeFileSync(path.join(issueSyncHome, 'state/102.json'), JSON.stringify({attempts:2,run:{
    implement_started_at:'2026-10-14T12:00:00Z',implement_started_sha:deliveryHeadSha,implement_started_attempt:2,
  }}));
  syncIssueLifecycleEvents(issueSyncHome, 102);
  syncIssueLifecycleEvents(issueSyncHome, 102);
  assert.equal(readMetricRows(issueSyncHome).filter((row) => row.event_type === 'implementation-started').length, 1,
    'writer-time sync appends exact events idempotently before hourly census');
  const reopened = weeklyDeliveryMetrics([
    {record_type:'event',event_type:'github-opened',issue:100,ts:'2026-10-07T00:00:00Z'},
    {record_type:'event',event_type:'github-closed',issue:100,ts:'2026-10-09T15:00:00Z'},
    {record_type:'event',event_type:'ticket-reopened',issue:100,ts:'2026-10-10T01:00:00Z'},
    {record_type:'event',event_type:'production-proof',issue:100,pr_number:'77',attempt:3,
      delivery_path:'product-release',sha:deliverySha,ts:'2026-10-10T05:00:00Z'},
  ], deliveryEnd);
  assert.equal(reopened.open_to_released.median_seconds, 4 * 3600, 'reopen starts fresh open-to-release interval');
  assert.equal(reopened.window.complete, false);
  assert.match(reopened.window.history_gap, /not backfilled/);
  const noLifecycleEvidence = weeklyDeliveryMetrics([], deliveryEnd);
  assert.equal(noLifecycleEvidence.open_to_released.median_seconds, null,
    'missing release evidence stays unknown');
  assert.equal(noLifecycleEvidence.stages.implementation.issue_hours_per_day, null,
    'missing stage evidence stays unknown instead of displaying zero hours');
  console.log('ok - weekly delivery links exact lifecycle evidence, clips boundaries, separates CI and direct-main, and handles replay/reopen');

  const ghBin = path.join(root, 'gh-bin');
  mkdirSync(ghBin);
  const largePage = path.join(root, 'large-ci-page.json');
  writeFileSync(largePage, JSON.stringify([{ workflow_runs: Array.from({ length: 50 }, (_, index) => ({
    id: index + 1, run_attempt: 1, created_at: ago(10), event: 'pull_request', conclusion: 'success',
    unused_payload: 'x'.repeat(300000),
  })) }, { workflow_runs: [{ id: 51, run_attempt: 1, created_at: ago(5), conclusion: 'success', event: 'pull_request' }] }]));
  writeFileSync(path.join(ghBin, 'gh'), `#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$EFFICIENCY_GH_ARGS_FILE"
[[ "$*" != *--slurp* || "$*" != *--jq* ]] || exit 2
if [[ "$*" == *--jq* ]]; then
  if [[ "$*" == *--paginate* ]]; then jq -r ".[] | \${!#}" "$EFFICIENCY_LARGE_PAGE"
  else jq -r ".[0] | \${!#}" "$EFFICIENCY_LARGE_PAGE"; fi
else cat "$EFFICIENCY_LARGE_PAGE"; fi
`);
  chmodSync(path.join(ghBin, 'gh'), 0o755);
  const oldPath = process.env.PATH;
  process.env.PATH = `${ghBin}:${oldPath}`;
  process.env.EFFICIENCY_LARGE_PAGE = largePage;
  const ghArgsFile = path.join(root, 'gh-args.log');
  process.env.EFFICIENCY_GH_ARGS_FILE = ghArgsFile;
  try {
    const projected = await ghPages('fixture/actions/runs', 'workflow_runs');
    assert.equal(projected.length, 51, 'compact JSON lines preserve every page');
    assert.equal(projected[0].id, 1);
    assert.equal(projected[0].unused_payload, undefined, 'irrelevant run metadata must be removed before execFile buffer');
    writeFileSync(ghArgsFile, '');
    const firstPage = await ghPages('fixture/actions/runs', 'workflow_runs', 30_000, { paginate: false });
    assert.equal(firstPage.length, 50, 'bounded mode returns only first API page');
    assert.ok(!readFileSync(ghArgsFile, 'utf8').includes('--paginate'), 'bounded mode omits gh api pagination');

    const censusPages = path.join(root, 'closed-pages.json');
    writeFileSync(censusPages, JSON.stringify([{ incomplete_results: false, items: [
      {number: 1, state:'closed', closed_at:'2026-10-14T20:00:00Z', labels:[], unused:'discard'},
    ] }]));
    process.env.EFFICIENCY_LARGE_PAGE = censusPages;
    writeFileSync(ghArgsFile, '');
    const incrementalHome = path.join(root, 'incremental-closed');
    mkdirSync(path.join(incrementalHome, 'state'), {recursive:true});
    await sample({home:incrementalHome,repo:'fixture/example',now:new Date('2026-10-15T00:00:00Z'),
      getClosedIssues:undefined,getOpenIssues:async()=>[],fetchCi:async()=>({queue_seconds:[],run_seconds:[],errors:[]}),sendAlert:async()=>{}});
    await sample({home:incrementalHome,repo:'fixture/example',now:new Date('2026-10-15T01:00:00Z'),
      getClosedIssues:undefined,getOpenIssues:async()=>[],fetchCi:async()=>({queue_seconds:[],run_seconds:[],errors:[]}),sendAlert:async()=>{}});
    const queryLog = readFileSync(ghArgsFile,'utf8');
    assert.match(queryLog,/closed:>=2026-10-01T00:00:00.000Z/, 'first census backfills two weeks');
    assert.match(queryLog,/closed:>=2026-10-14T23:00:00.000Z/, 'next census uses last success with one-hour overlap');
    assert.equal(readMetricRows(incrementalHome).filter(r=>r.event_type==='github-closed').length,1,'overlap deduplicates closure identity');
    writeFileSync(censusPages, JSON.stringify([{incomplete_results:true,items:[]}]));
    const incomplete = await sample({home:incrementalHome,repo:'fixture/example',now:new Date('2026-10-15T02:00:00Z'),
      getClosedIssues:undefined,getOpenIssues:async()=>[],fetchCi:async()=>({queue_seconds:[],run_seconds:[],errors:[]}),sendAlert:async()=>{}});
    assert.ok(incomplete.row.source_errors.includes('closed-issues:unreadable'));
    assert.equal(readMetricRows(incrementalHome).filter(r=>r.record_type==='closed-census').length,2,'failed census must not advance incremental cursor');

  } finally {
    process.env.PATH = oldPath;
    delete process.env.EFFICIENCY_LARGE_PAGE;
    delete process.env.EFFICIENCY_GH_ARGS_FILE;
  }
  console.log('ok - CI pages project needed fields; sampled workflow runs skip unbounded pagination');
  const cacheFile = path.join(cacheHome, 'night/efficiency-ci-jobs.json');
  writeFileSync(cacheFile, '{broken cache');
  runs = [run(303, 1, '2026-10-08T12:30:00Z')];
  const recoveredCacheSample = await sample({
    home: cacheHome,
    repo: 'fixture/example',
    now: new Date('2026-10-08T14:00:00Z'),
    fetchCi: cachedFetchCi,
    sendAlert: async () => assert.fail('corrupt cache fixture must not alert'),
  });
  assert.equal(jobCalls.at(-1), '303:1', 'corrupt cache refetches run jobs');
  assert.equal(recoveredCacheSample.row.metrics.ci_queue_seconds, 60);
  assert.equal(JSON.parse(readFileSync(cacheFile, 'utf8')).runs['303:1'].queue_seconds[0], 60);
  console.log('ok - corrupt CI cache refetches jobs and is replaced atomically');

  const budgetNowMs = Date.parse('2026-10-09T00:00:00Z');
  let budgetClockMs = 1000;
  const budgetRuns = Array.from({ length: 9 }, (_, index) => run(
    800 + index, 1, new Date(Date.parse('2026-10-08T20:00:00Z') + index * 60_000).toISOString(),
  ));
  const budgetFetchPages = async (endpoint, collection) => {
    if (collection === 'workflow_runs') return budgetRuns;
    const id = Number(endpoint.match(/\/runs\/(\d+)\/jobs/)[1]);
    if (id === 807) {
      budgetClockMs = 1005;
      throw new Error('fake gh timeout');
    }
    const item = budgetRuns.find((candidate) => candidate.id === id);
    const started = Date.parse(item.created_at) + 1000;
    return [{
      created_at: item.created_at,
      started_at: new Date(started).toISOString(),
      completed_at: new Date(started + 5000).toISOString(),
    }];
  };
  const dateNow = Date.now;
  Date.now = () => budgetClockMs;
  let bounded;
  try {
    bounded = await collectGitHubCiSamples('fixture/example', budgetNowMs - 24 * 60 * 60 * 1000, {
      cacheFile: path.join(root, 'budget/night/efficiency-ci-jobs.json'),
      deadlineMs: 1005,
      nowMs: budgetNowMs,
      fetchPages: budgetFetchPages,
    });
  } finally {
    Date.now = dateNow;
  }
  assert.equal(bounded.queue_seconds.length, 7);
  assert.equal(bounded.run_seconds.length, 7);
  assert.ok(bounded.errors.includes('ci-jobs:807:unreadable'));
  assert.ok(bounded.errors.includes('ci-jobs:deferred:1'));
  assert.equal(Object.keys(JSON.parse(readFileSync(path.join(root, 'budget/night/efficiency-ci-jobs.json'), 'utf8')).runs).length, 7);
  const gatewayFailure = await collectGitHubCiSamples('fixture/example', '2026-10-08T00:00:00Z', {
    nowMs: Date.parse('2026-10-08T12:00:00Z'),
    fetchPages: async () => { const error = new Error('failed'); error.stderr = 'Bad Gateway'; throw error; },
  });
  assert.equal(gatewayFailure.error_reasons['ci-pr-runs'], 'bad-gateway');
  assert.ok(gatewayFailure.errors.includes('ci-pr-runs:unreadable'));
  console.log('ok - CI fetch stops at its deadline, stores completed jobs, and reports deferred runs');

  const dailyEvents = [
    { record_type: 'event', event_type: 'stage-entered', ts: '2026-10-10T23:59:00Z', issue: 'pair-1', stage: 'ready-for-agent' },
    { record_type: 'event', event_type: 'stage-exited', ts: '2026-10-11T00:01:00Z', issue: 'pair-1', stage: 'ready-for-agent' },
    { record_type: 'event', event_type: 'stage-entered', ts: '2026-10-11T23:00:00Z', issue: 'open-1', stage: 'ready-for-agent' },
  ];
  const paired = dailyNodeMetrics(dailyEvents, '2026-10-11');
  assert.equal(paired.stages.find((stage) => stage.key === 'ready-for-agent').mean_seconds, 120);
  assert.equal(paired.stages.find((stage) => stage.key === 'ready-for-agent').open_at_end, 1);
  const missingNodes = dailyNodeMetrics(dailyEvents, '2026-10-08');
  assert.equal(missingNodes.status, 'missing');
  assert.deepEqual(missingNodes.stages, [], 'rollback gap is missing data, not a zero-valued day');
  const separatedNodes = dailyNodeMetrics([
    ...dailyEvents,
    { record_type: 'event', event_type: 'stage-entered', ts: '2026-10-11T02:00:00Z', issue: 'done-1', stage: 'concluded' },
    { record_type: 'event', event_type: 'stage-exited', ts: '2026-10-11T04:00:00Z', issue: 'done-1', stage: 'concluded' },
    { record_type: 'event', event_type: 'stage-entered', ts: '2026-10-11T05:00:00Z', issue: 'wait-1', stage: 'finish-first' },
    { record_type: 'event', event_type: 'stage-exited', ts: '2026-10-11T06:00:00Z', issue: 'wait-1', stage: 'finish-first' },
  ], '2026-10-11');
  assert.equal(separatedNodes.terminal.find((stage) => stage.key === 'concluded').mean_seconds, 7200);
  assert.equal(separatedNodes.stages.find((stage) => stage.key === 'concluded'), undefined);
  assert.equal(separatedNodes.stages.find((stage) => stage.key === 'finish-first').label, '等前置事项');

  const ciBaselines = [
    ['small', 'pr', 10, 1],
    ['Touched packages PR gate', 'pr', 200, 10],
    ['Unknown Alpha gate', 'pr', 10, 1],
    ['Unknown Beta gate', 'pr', 10, 1],
    ['Tiny gate', 'pr', 10, 1],
    ['Fail gate', 'pr', 10, 1],
    ['Pipeline suites', 'main', 200, 10],
    ['Queue-only gate', 'pr', null, 1],
  ];
  const dailyHistory = Array.from({ length: 7 }, (_, index) => {
    const day = new Date(Date.parse('2026-10-04T00:00:00Z') + index * 86_400_000).toISOString().slice(0, 10);
    return {
      record_type: 'daily', day,
      nodes: { status: 'available', stages: [{ key: 'gate', label: '主线检查', samples: 5, mean_seconds: 1846.1538461538462 }] },
      checks: { ci: ciBaselines.map(([name, cohort, runSeconds, queueSeconds]) => ({
        key: `ci:${cohort}:${name}`, name, label: name, category: 'ci', cohort,
        run: { samples: runSeconds === null ? 0 : 5, mean_seconds: runSeconds }, queue: { samples: 5, mean_seconds: queueSeconds },
        status_samples: 5, fail_cancel_rate: 0,
      })), local: [] },
    };
  });
  const terminalRanked = compareDailyMetrics({
    record_type: 'daily', day: '2026-10-11',
    nodes: { status: 'available', stages: [{ key: 'concluded', label: '已完成', samples: 5, mean_seconds: 7200 }] },
    checks: { ci: [], local: [] },
  }, dailyHistory.map((row) => ({ ...row, nodes: {
    status: 'available', stages: [{ key: 'concluded', label: '已完成', samples: 5, mean_seconds: 60 }],
  } })));
  assert.deepEqual(terminalRanked.nodes.stages, []);
  assert.equal(terminalRanked.nodes.terminal[0].key, 'concluded');
  assert.equal(terminalRanked.anomalies.length, 0, 'terminal-state dwell never creates an anomaly');
  assert.equal(terminalRanked.slowest_nodes.some((stage) => stage.key === 'concluded'), false);
  assert.doesNotMatch(terminalRanked.mail_summary, /已完成/);

  const ranked = compareDailyMetrics({
    record_type: 'daily', day: '2026-10-11',
    nodes: { status: 'available', stages: [{ key: 'gate', label: '主线检查', samples: 5, mean_seconds: 2400 }] },
    checks: { ci: [{ key: 'ci:pr:small', name: 'small', label: '小检查', category: 'ci', cohort: 'pr', run: { samples: 5, mean_seconds: 31 }, queue: { samples: 5, mean_seconds: 1 }, status_samples: 5, fail_cancel_rate: 0 }], local: [] },
  }, dailyHistory);
  assert.equal(ranked.anomalies[0].key, 'node:gate', '1.3x 40-minute gate ranks ahead of 3x 10-second check by excess hours');
  assert.ok(ranked.anomalies[0].excess_hours > ranked.anomalies[1].excess_hours);

  const dailyHome = path.join(root, 'daily');
  const baselineRow = (day) => ({
    record_type: 'daily', event_id: `daily:${day}`, ts: `${day}T00:00:00Z`, day,
    nodes: { status: 'available', stages: [{ key: 'ready-for-agent', label: '待开发', samples: 5, mean_seconds: 10 }] },
    checks: { ci: ciBaselines.map(([name, cohort, runSeconds, queueSeconds]) => ({
      key: `ci:${cohort}:${name}`, name, label: name, category: 'ci', cohort,
      run: { samples: runSeconds === null ? 0 : 5, mean_seconds: runSeconds }, queue: { samples: 5, mean_seconds: queueSeconds },
      status_samples: 5, fail_cancel_rate: 0,
    })), local: [] },
  });
  appendMetricRecords(dailyHome, [
    ...Array.from({ length: 7 }, (_, index) => baselineRow(new Date(Date.parse('2026-10-04T00:00:00Z') + index * 86_400_000).toISOString().slice(0, 10))),
    ...Array.from({ length: 5 }, (_, index) => ({
      record_type: 'event', event_type: 'stage-entered', event_id: `daily-enter-${index}`,
      ts: '2026-10-11T01:00:00Z', issue: `daily-${index}`, stage: 'ready-for-agent',
    })),
    ...Array.from({ length: 5 }, (_, index) => ({
      record_type: 'event', event_type: 'stage-exited', event_id: `daily-exit-${index}`,
      ts: '2026-10-11T01:01:00Z', issue: `daily-${index}`, stage: 'ready-for-agent',
    })),
    { record_type: 'event', event_type: 'limiter', event_id: 'daily-quota', ts: '2026-10-11T02:00:00Z', outcome: 'skipped', category: 'budget', gate: 'provider-quota' },
    { record_type: 'event', event_type: 'limiter', event_id: 'daily-scan', ts: '2026-10-11T02:01:00Z', outcome: 'skipped', category: 'budget', gate: 'budget-exhausted' },
    { record_type: 'event', event_type: 'dispatch', event_id: 'daily-dispatch-a', ts: '2026-10-11T02:02:00Z', issue: 991, gate: 'implement-dispatch' },
    { record_type: 'event', event_type: 'dispatch', event_id: 'daily-dispatch-b', ts: '2026-10-11T02:03:00Z', issue: 991, gate: 'implement-dispatch' },
    { record_type: 'event', event_type: 'attempt-terminal', event_id: 'daily-killed', ts: '2026-10-11T02:04:00Z', terminal_cause: 'watchdog-killed', systemd_result: 'signal:9' },
  ]);
  mkdirSync(path.join(dailyHome, 'night'), { recursive: true });
  writeFileSync(path.join(dailyHome, 'night/night.log'), '01:00:00Z tick=20261011T010000Z-1\nrefusing: MemAvailable 5800MB below 6144MB floor\n');
  mkdirSync(path.join(dailyHome, 'land-queue/requests'), { recursive: true });
  const epoch = (value) => Date.parse(value) / 1000;
  writeFileSync(path.join(dailyHome, 'land-queue/requests/landed.json'), JSON.stringify({
    state: 'landed', enqueued_epoch: epoch('2026-10-11T01:58:00Z'), finished_epoch: epoch('2026-10-11T02:00:00Z'),
  }));
  writeFileSync(path.join(dailyHome, 'land-queue/requests/failed.json'), JSON.stringify({
    state: 'failed', finished_epoch: epoch('2026-10-11T02:05:00Z'), reason: 'rebase conflict',
  }));
  process.env.ZF_AGENT_TEST_MODE = '1';
  process.env.ZF_AGENT_TEST_ROOT = root;
  const dailyJob = (name, cohort, runSeconds, queueSeconds, conclusion = 'success') => ({
    name, cohort, status: 'completed', conclusion, queue_seconds: queueSeconds, run_seconds: runSeconds,
  });
  const ciJobs = [
    ...Array.from({ length: 5 }, () => dailyJob('Touched packages PR gate', 'pr', 1000, 10)),
    dailyJob('Touched packages PR gate', 'pr', null, 12095, 'cancelled'),
    ...Array.from({ length: 5 }, () => dailyJob('Unknown Alpha gate', 'pr', 500, 1)),
    ...Array.from({ length: 5 }, () => dailyJob('Unknown Beta gate', 'pr', 500, 1)),
    ...Array.from({ length: 5 }, () => dailyJob('Tiny gate', 'pr', 31, 1)),
    ...Array.from({ length: 5 }, () => dailyJob('Fail gate', 'pr', 10, 1, 'failure')),
    ...Array.from({ length: 5 }, () => dailyJob('Pipeline suites', 'main', 200, 10)),
    ...Array.from({ length: 5 }, () => ({ ...dailyJob('Queue-only gate', 'pr', null, 12095, 'cancelled'), runner_id: 0, steps_count: 0 })),
  ];
  ciJobs[5].runner_id = 0;
  ciJobs[5].steps_count = 0;
  ciJobs[5].never_started = true;
  await dailyEfficiency({
    home: dailyHome,
    repo: 'fixture/example',
    day: '2026-10-11',
    nowMs: Date.parse('2026-10-12T12:00:00Z'),
    fetchCi: async () => ({
      sampled_runs: { pr: 5, main: 0 }, sampled_workflow_runs: { pr: 5, main: 0 },
      workflow_population: { pr: 10, main: 0 }, main_green_share: 1,
      job_samples: ciJobs, errors: [], error_reasons: {},
    }),
  });
  const efficiencyInbox = path.join(dailyHome, 'night/efficiency-inbox');
  const sharedInbox = path.join(dailyHome, 'supervisor-inbox');
  const inboxLines = readFileSync(efficiencyInbox, 'utf8').trim().split('\n');
  assert.ok(inboxLines.some((line) => /efficiency-anomaly day=2026-10-11 status=(?:SLOW|BROKEN) type=check label=合并请求改动范围检查/.test(line)));
  assert.ok(inboxLines.some((line) => /label=合并请求其他检查：Unknown Alpha gate/.test(line)));
  assert.ok(inboxLines.some((line) => /label=合并请求其他检查：Unknown Beta gate/.test(line)));
  assert.ok(inboxLines.some((line) => /label=合并请求其他检查：Fail gate.*fail-cancel-rate/.test(line)),
    'fail-rate jump alarms even without excess duration');
  assert.ok(!inboxLines.some((line) => /label=合并请求其他检查：Tiny gate/.test(line)),
    '3x short check stays in the report but misses the 0.5-hour inbox floor');
  assert.ok(!inboxLines.some((line) => /label=待开发/.test(line)), 'small node excess does not wake the inbox');
  assert.ok(!inboxLines.some((line) => /label=合并请求其他检查(?: |$)/.test(line)), 'unmapped jobs keep concrete names');
  const touchedDailyCheck = readMetricRows(dailyHome).find((item) => item.record_type === 'daily' && item.day === '2026-10-11')
    .checks.ci.find((check) => check.name === 'Touched packages PR gate');
  assert.equal(touchedDailyCheck.run.samples, 5);
  assert.equal(touchedDailyCheck.queue.samples, 6);
  assert.equal(touchedDailyCheck.runner_minutes, 5 * 1000 / 60);
  assert.match(touchedDailyCheck.label, /改动范围检查/);
  const dailyRecord = readMetricRows(dailyHome).find((item) => item.record_type === 'daily' && item.day === '2026-10-11');
  assert.equal(dailyRecord.resource_utilization.dispatch.repeat_issue_dispatches_M, 1);
  assert.equal(dailyRecord.resource_utilization.rework.repeat_dispatch_share_M, 0.5);
  assert.equal(dailyRecord.resource_utilization.codex.provider_quota_holds_M, 1);
  assert.equal(dailyRecord.resource_utilization.wsl.memavailable_at_refusal_M.min_mb_M, 5800);
  assert.equal(dailyRecord.resource_utilization.cihost_ci.runner_slots_M, null);
  assert.equal(dailyRecord.resource_utilization.cihost_ci.runner_slot_demand_pct_E, null);
  assert.match(dailyRecord.resource_utilization.cihost_ci.runner_slot_demand_reason, /capacity snapshot/);
  assert.equal(dailyRecord.resource_utilization.landing.landed, 1);
  assert.equal(dailyRecord.resource_utilization.landing.failure_reasons_M['rebase-conflict'], 1);
  assert.equal(dailyRecord.resource_utilization.post_land.live_depth_M, null);
  assert.equal(dailyRecord.resource_utilization.main.red_hours_M, null);
  assert.equal(dailyRecord.resource_utilization.rework.watchdog_killed_hands_M, 1);
  const queueOnlyCheck = dailyRecord.slowest_checks.find((check) => check.name === 'Queue-only gate');
  assert.equal(queueOnlyCheck.slowest_metric, 'queue', 'queue-only check appears in the slow-check table without runner samples');
  assert.equal(queueOnlyCheck.run.samples, 0);
  assert.equal(queueOnlyCheck.queue.mean_seconds, 12095);
  assert.match(JSON.parse(readFileSync(path.join(dailyHome, 'night/efficiency/daily-2026-10-11.json'), 'utf8')).mail_summary,
    /Queue-only gate（排队较久）：运行均值 暂无数据.*排队均值 3.4小时/);
  assert.ok(inboxLines.some((line) => /runner_mean_seconds=1000 .*queue_mean_seconds=2024\.166/.test(line)),
    'alert shows runner and queue means separately');
  assert.equal(existsSync(sharedInbox), false, 'daily anomalies route only to efficiency inbox');
  assert.equal(JSON.parse(readFileSync(path.join(dailyHome, 'night/efficiency/daily-2026-10-11.json'), 'utf8')).day, '2026-10-11');
  await dailyEfficiency({ home: dailyHome, repo: 'fixture/example', day: '2026-10-11', nowMs: Date.parse('2026-10-12T12:00:00Z') });
  assert.equal(readFileSync(efficiencyInbox, 'utf8').trim().split('\n').length, inboxLines.length, 'reruns do not duplicate same-day anomaly lines');
  assert.equal(readMetricRows(dailyHome).filter((item) => item.record_type === 'daily' && item.day === '2026-10-11').length, 1);
  writeFileSync(efficiencyInbox, `${new Date(Date.parse('2026-10-12T12:00:00Z') - 25 * 60 * 60 * 1000).toISOString().replace('.000', '')} efficiency-anomaly stale-fixture\n`);
  await dailyEfficiency({ home: dailyHome, repo: 'fixture/example', day: '2026-10-11', nowMs: Date.parse('2026-10-12T12:00:00Z') });
  await dailyEfficiency({ home: dailyHome, repo: 'fixture/example', day: '2026-10-11', nowMs: Date.parse('2026-10-12T12:00:00Z') });
  const escalations = readFileSync(sharedInbox, 'utf8').match(/efficiency-inbox-unread/g) || [];
  assert.equal(escalations.length, 1, 'stale efficiency inbox escalates exactly once');

  const historicalHome = path.join(root, 'historical');
  const historicalInbox = path.join(historicalHome, 'night/efficiency-inbox');
  mkdirSync(path.dirname(historicalInbox), { recursive: true });
  writeFileSync(historicalInbox, '2026-10-10T00:00:00Z efficiency-anomaly stale-historical-line\n');
  appendMetricRecords(historicalHome, Array.from({ length: 7 }, (_, index) => {
    const day = new Date(Date.parse('2026-10-03T00:00:00Z') + index * 86_400_000).toISOString().slice(0, 10);
    const history = baselineRow(day);
    history.checks.ci = [{ key: 'ci:pr:Historical gate', name: 'Historical gate', label: 'Historical gate', category: 'ci', cohort: 'pr',
      run: { samples: 5, mean_seconds: 10 }, queue: { samples: 5, mean_seconds: 1 }, status_samples: 5, fail_cancel_rate: 0 }];
    return history;
  }));
  await dailyEfficiency({
    home: historicalHome, repo: 'fixture/example', day: '2026-10-10', nowMs: Date.parse('2026-10-12T12:00:00Z'),
    fetchCi: async () => ({ sampled_runs: { pr: 5, main: 0 }, job_samples: Array.from({ length: 5 }, () =>
      dailyJob('Historical gate', 'pr', 1000, 1)), errors: [], error_reasons: {} }),
  });
  const historicalDaily = readMetricRows(historicalHome).find((item) => item.record_type === 'daily' && item.day === '2026-10-10');
  assert.ok(historicalDaily);
  assert.equal(historicalDaily.resource_utilization.dispatch.dispatches_M, null, 'missing event samples stay unknown, not zero');
  assert.equal(readFileSync(historicalInbox, 'utf8'), '2026-10-10T00:00:00Z efficiency-anomaly stale-historical-line\n',
    'historical backfill writes data but neither anomaly nor stale-inbox alerts');
  assert.equal(existsSync(path.join(historicalHome, 'supervisor-inbox')), false);

  const hourlyHome = path.join(root, 'hourly-route');
  writeHistory(hourlyHome, weekRows({ released_issues: 6 }));
  const hourly = await sample({ home: hourlyHome, repo: 'fixture/example', now: new Date('2026-10-08T00:30:00Z'),
    fetchCi: async () => ({ queue_seconds: [], run_seconds: [], errors: [] }) });
  assert.equal(hourly.alerts.length, 1);
  assert.match(readFileSync(path.join(hourlyHome, 'night/efficiency-inbox'), 'utf8'), /efficiency-regression status=SLOW metric=released_issues/);
  assert.equal(existsSync(path.join(hourlyHome, 'supervisor-inbox')), false, 'hourly alarms use efficiency inbox');
  console.log('ok - daily rollup pairs dwell, preserves missing days, ranks by excess hours, splits queue/run, and routes alerts safely');
} finally {
  rmSync(root, { recursive: true, force: true });
}
