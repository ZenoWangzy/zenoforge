import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import { replayRule } from './rule-replay.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, 'replay-fixtures');
const asOf = '2026-10-29T12:00:00Z';
const generatedAt = '2026-10-29T12:00:01Z';
const readJson = (name) => JSON.parse(readFileSync(join(fixtures, name), 'utf8'));

test('replays the #4053 5M raw-token candidate and separates false stops from real parks', () => {
  const report = replayRule(readJson('4053-ledger.json'), readJson('4053-raw-token-rule.json'), { asOf, generatedAt });

  assert.equal(report.window.from, '2026-10-22T12:00:00.000Z');
  assert.equal(report.event.type, 'control-rule-replay.completed');
  assert.deepEqual(report.falseStops.map((row) => row.unitId).sort(), ['issue-13159', 'pr-13381']);
  assert.deepEqual(report.intercepted.map((row) => row.unitId), ['issue-13680']);
  assert.equal(report.falseStops.find((row) => row.unitId === 'issue-13159').trigger.metrics.rawTokens, 40000000);
  assert.equal(report.falseStops.find((row) => row.unitId === 'pr-13381').accepted.stage, 'supervisor-approve');
  assert.equal(report.intercepted[0].evidence.stage, 'supervisor-budget-park');
});

test('replays the f6 3-round or 4-hour candidate, including reset, window seed, and unresolved hits', () => {
  const report = replayRule(readJson('f6-ledger.json'), readJson('f6-stoploss-rule.json'), { asOf, generatedAt });
  const roundFalseStop = report.falseStops.find((row) => row.unitId === 'f6-round-accepted');
  const windowFalseStop = report.falseStops.find((row) => row.unitId === 'f6-window-seed');

  assert.ok(roundFalseStop);
  assert.equal(roundFalseStop.trigger.at, '2026-10-28T12:20:00.000Z');
  assert.equal(roundFalseStop.trigger.metrics.rounds, 3);
  assert.ok(windowFalseStop, 'pre-window starts seed the in-window round count');
  assert.equal(windowFalseStop.trigger.at, '2026-10-23T10:00:00.000Z');
  assert.deepEqual(report.intercepted.map((row) => row.unitId), ['f6-wall-intercepted']);
  assert.equal(report.intercepted[0].trigger.metrics.elapsedSeconds, 14401);
  assert.deepEqual(report.unresolved.map((row) => row.unitId), ['f6-round-unresolved']);
  assert.equal(report.falseStops.some((row) => row.unitId === 'f6-supervisor-reset'), false);
  assert.equal(report.coverage.eventsInWindow, 16);
});

test('predicate paths support scalar, membership, presence, and compound operators', () => {
  const ledger = {
    units: [{
      id: 'predicate-operators', issue: 77, history: [
        { stage: 'write-start', at: '2026-10-28T10:00:00Z' },
        { stage: 'custom-check', at: '2026-10-28T10:01:00Z', rawTokens: 10, labels: ['pipeline'], reason: null },
      ],
    }],
  };
  const rule = {
    id: 'predicate-operators',
    predicate: { all: [
      { path: 'unit.id', op: 'eq', value: 'predicate-operators' },
      { path: 'unit.issue', op: 'ne', value: 0 },
      { path: 'event.stage', op: 'in', value: ['custom-check'] },
      { path: 'event.stage', op: 'contains', value: 'check' },
      { path: 'event.labels', op: 'contains', value: 'pipeline' },
      { path: 'event.reason', op: 'eq', value: null },
      { path: 'event.reason', op: 'ne', value: 'blocked' },
      { path: 'event.reason', op: 'in', value: [null, 'allowed'] },
      { path: 'metrics.rawTokens', op: 'gt', value: 9 },
      { path: 'metrics.rawTokens', op: 'gte', value: 10 },
      { path: 'metrics.rawTokens', op: 'lt', value: 11 },
      { path: 'metrics.rawTokens', op: 'lte', value: 10 },
      { path: 'unit.issue', op: 'exists' },
      { any: [
        { path: 'unit.lane', op: 'eq', value: 'missing-lane' },
        { path: 'event.stage', op: 'eq', value: 'custom-check' },
      ] },
      { not: { path: 'event.stage', op: 'eq', value: 'write-start' } },
    ] },
  };
  const report = replayRule(ledger, rule, { asOf, generatedAt });

  assert.equal(report.unresolved[0].trigger.stage, 'custom-check');
  assert.equal(report.unresolved[0].trigger.at, '2026-10-28T10:01:00.000Z');

  const missingFieldReport = replayRule(ledger, {
    id: 'missing-field',
    predicate: { all: [
      { path: 'event.stage', op: 'eq', value: 'write-start' },
      { not: { path: 'event.reason', op: 'exists' } },
    ] },
  }, { asOf, generatedAt });
  assert.equal(missingFieldReport.unresolved[0].trigger.stage, 'write-start');
});

test('fails closed on malformed predicates and timestamps', () => {
  assert.throws(() => replayRule({ units: [] }, { id: 'bad', predicate: { path: 'metrics.rounds', op: 'regex', value: '3' } }, { asOf, generatedAt }), /unsupported predicate operator/);
  assert.throws(() => replayRule({ units: [{ id: 'broken', history: [{ stage: 'write-start' }] }] }, readJson('f6-stoploss-rule.json'), { asOf, generatedAt }), /history\[0\]\.at/);
});

test('CLI writes one machine-readable completion report without editing the ledger', () => {
  const temp = mkdtempSync(join(tmpdir(), 'rule-replay-'));
  try {
    const ledgerPath = join(temp, 'ledger.json');
    const rulePath = join(temp, 'rule.json');
    const reportPath = join(temp, 'report.json');
    writeFileSync(ledgerPath, JSON.stringify(readJson('4053-ledger.json')));
    writeFileSync(rulePath, JSON.stringify(readJson('4053-raw-token-rule.json')));
    const before = readFileSync(ledgerPath, 'utf8');
    const result = spawnSync(process.execPath, [
      resolve(here, 'rule-replay.mjs'), ledgerPath, rulePath, reportPath, '--as-of', asOf,
    ], { encoding: 'utf8' });

    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /false-stops=2 intercepted=1 unresolved=0/);
    assert.deepEqual(JSON.parse(readFileSync(ledgerPath, 'utf8')), JSON.parse(before));
    const report = JSON.parse(readFileSync(reportPath, 'utf8'));
    assert.equal(report.rule.id, 'issue-4053-lifecycle-raw-token-5m');
    assert.equal(report.source.ledger, ledgerPath);
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
});

test('CLI compares baseline and candidate decisions over the same replay window', () => {
  const temp = mkdtempSync(join(tmpdir(), 'rule-replay-baseline-'));
  try {
    const ledgerPath = join(temp, 'ledger.json');
    const candidatePath = join(temp, 'candidate.json');
    const baselinePath = join(temp, 'baseline.json');
    const sameReportPath = join(temp, 'same-report.json');
    const changedReportPath = join(temp, 'changed-report.json');
    const ledger = readJson('4053-ledger.json');
    const candidate = readJson('4053-raw-token-rule.json');
    const sameBaseline = { ...candidate, predicate: { ...candidate.predicate } };
    const quietBaseline = {
      ...candidate,
      id: 'baseline-higher-threshold',
      predicate: { ...candidate.predicate, value: 100_000_000 },
    };
    writeFileSync(ledgerPath, JSON.stringify(ledger));
    writeFileSync(candidatePath, JSON.stringify(candidate));
    writeFileSync(baselinePath, JSON.stringify(sameBaseline));

    const same = spawnSync(process.execPath, [
      resolve(here, 'rule-replay.mjs'), ledgerPath, candidatePath, sameReportPath,
      '--baseline', baselinePath, '--as-of', asOf,
    ], { encoding: 'utf8' });
    assert.equal(same.status, 0, same.stderr);
    assert.match(same.stdout, /changed-decisions=0 new-false-stops=0/);
    const sameReport = JSON.parse(readFileSync(sameReportPath, 'utf8'));
    assert.equal(sameReport.baseline.rule.id, candidate.id);
    assert.equal(sameReport.source.baselineRule, baselinePath);
    assert.deepEqual(sameReport.changedDecisions, []);
    assert.deepEqual(sameReport.newFalseStops, []);
    assert.equal(sameReport.window.from, '2026-10-22T12:00:00.000Z');

    writeFileSync(baselinePath, JSON.stringify(quietBaseline));
    const changed = spawnSync(process.execPath, [
      resolve(here, 'rule-replay.mjs'), ledgerPath, candidatePath, changedReportPath,
      '--as-of', asOf, '--baseline', baselinePath,
    ], { encoding: 'utf8' });
    assert.equal(changed.status, 0, changed.stderr);
    assert.match(changed.stdout, /changed-decisions=3 new-false-stops=2/);
    const changedReport = JSON.parse(readFileSync(changedReportPath, 'utf8'));
    assert.deepEqual(changedReport.changedDecisions, [
      { unitId: 'issue-13159', baseline: null, candidate: 'falseStop' },
      { unitId: 'issue-13680', baseline: null, candidate: 'intercepted' },
      { unitId: 'pr-13381', baseline: null, candidate: 'falseStop' },
    ]);
    assert.deepEqual(changedReport.newFalseStops.map((row) => row.unitId).sort(), ['issue-13159', 'pr-13381']);
    assert.equal(changedReport.window.from, sameReport.window.from);
    assert.equal(changedReport.window.until, sameReport.window.until);
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
});
