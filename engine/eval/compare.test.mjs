import test from 'node:test';
import assert from 'node:assert/strict';
import { compareResults, formatComparison, summarizeSupervisor } from './compare.mjs';
const fixture = (label, rows) => ({ label, results: rows.map(([caseId, run, pass]) => ({ stage: 'triage', caseId, run, pass })) });
test('counts paired flips even with unchanged totals; regressions print first', () => {
  const before = fixture('before', [['a', 1, true], ['a', 2, false], ['b', 1, false], ['b', 2, true]]);
  const after = fixture('after', [['a', 1, false], ['a', 2, false], ['b', 1, true], ['b', 2, true]]);
  const result = compareResults(before, after);
  assert.deepEqual(result.totals, { baseline: { passed: 2, total: 4 }, candidate: { passed: 2, total: 4 } });
  assert.deepEqual(result.regressions.map((r) => [r.caseId, r.run]), [['a', 1]]);
  assert.equal(result.improvements[0].caseId, 'b');
  assert.equal(result.inconsistency.baseline.length, 2);
  assert.equal(result.inconsistency.candidate.length, 0);
  assert.match(formatComparison(result).split('\n')[0], /pass→fail.*a/);
});
test('missing cases and repeats are unpaired, never an improvement', () => {
  const r = compareResults(fixture('a', [['x', 1, true]]), fixture('b', [['y', 1, true], ['y', 2, false]]));
  assert.equal(r.unpaired.length, 3);
  assert.equal(r.regressions.length + r.improvements.length, 0);
  assert.throws(() => compareResults(fixture('a', [['x', 1, true], ['x', 1, true]]), fixture('b', [])), /duplicate/);
});

test('partial labels compare only the shared cases and say which ones were compared', () => {
  const before = fixture('full', [['a', 1, true], ['b', 1, true], ['c', 1, false]]);
  const after = fixture('partial', [['a', 1, false], ['c', 1, true]]);
  const r = compareResults(before, after);
  assert.deepEqual(r.paired, ['triage/a/1', 'triage/c/1']);
  assert.deepEqual(r.regressions.map((x) => x.caseId), ['a']);
  assert.deepEqual(r.improvements.map((x) => x.caseId), ['c']);
  assert.deepEqual(r.unpaired.map((x) => x.id), ['triage/b/1']);
  const text = formatComparison(r);
  assert.match(text, /compared in both labels: triage\/a\/1, triage\/c\/1$/m);
  assert.match(text, /UNPAIRED triage\/b\/1 only in full/);
  assert.doesNotMatch(text, /compared in both labels:[^\n]*triage\/b/);
});

test('supervisor comparison reports accuracy by action and the constant-requeue reference', () => {
  const row = (caseId, expectedAction, pass, action) => ({ stage: 'supervisor', caseId, run: 1, expectedAction, pass, action });
  const before = { label: 'arbiter', results: [
    row('r1', 'requeue', true, 'requeue'), row('r2', 'requeue', false, 'approve'),
    row('a1', 'approve', false, 'approve'), row('p1', 'park', false, 'requeue'),
    row('c1', 'close', false, 'requeue'), row('rr1', 'reroute', false, 'requeue'),
    row('d1', 'decision', false, 'requeue'),
  ] };
  const after = { label: 'f12', results: [
    row('r1', 'requeue', true, 'requeue'), row('r2', 'requeue', true, 'requeue'),
    row('a1', 'approve', true, 'approve'), row('p1', 'park', true, 'park'),
    row('c1', 'close', true, 'close'), row('rr1', 'reroute', true, 'reroute'),
    row('d1', 'decision', true, 'decision'),
  ] };
  const r = compareResults(before, after);
  assert.deepEqual(r.supervisor.baseline.byAction.requeue, { correct: 1, total: 2 });
  assert.deepEqual(r.supervisor.candidate.byAction.reroute, { correct: 1, total: 1 });
  assert.deepEqual(r.supervisor.alwaysRequeue, { correct: 2, total: 7 });
  assert.deepEqual(summarizeSupervisor(before.results).alwaysRequeue, { correct: 2, total: 7 });
  const output = formatComparison(r);
  assert.match(output, /supervisor action accuracy arbiter: approve 0\/1.*requeue 1\/2/);
  assert.match(output, /supervisor constant-requeue reference \(paired cases\): 2\/7 \(28\.6%\)/);
});

test('repair comparison counts discordance, excludes skips and preserves unknown usage', async () => {
  const { compareArms, formatArmComparison } = await import('./compare.mjs');
  const arm = (pass, tokens, wall_ms) => ({ pass, reasons: [], tokens, wall_ms, identity: 'codex:fixture:high' });
  const rows = [
    { cold: arm(true, 10, 100), resume: arm(false, 20, 200) },
    { cold: arm(false, null, 300), resume: arm(true, 40, 400) },
    { cold: arm(true, 30, 500), resume: arm(true, 60, 600) },
    { cold: arm(false, 40, 700), resume: { status: 'skipped', pass: null, reasons: ['no session'], tokens: null, wall_ms: null } },
  ].map((repair_arms, i) => ({ stage: 'end-to-end', caseId: `c${i}`, run: 1, repair_arms }));
  const result = compareArms({ label: 'paired', results: [...rows, { stage: 'end-to-end', caseId: 'no-repair', run: 1, pass: true }] });
  assert.equal(result.chains, 4);
  assert.equal(result.paired, 3);
  assert.deepEqual(result.discordant, { coldOnly: ['end-to-end/c0/1'], resumeOnly: ['end-to-end/c1/1'] });
  assert.deepEqual(result.arms.cold, { passed: 2, total: 4, skipped: 0, tokens: { median: null, sum: null }, wall_ms: { median: 400, sum: 1600 } });
  assert.deepEqual(result.arms.resume, { passed: 2, total: 3, skipped: 1, tokens: { median: 40, sum: 120 }, wall_ms: { median: 400, sum: 1200 } });
  assert.match(formatArmComparison(result), /cold: pass 2\/4.*tokens median=unknown sum=unknown/);
  assert.match(formatArmComparison(result), /cold pass, resume fail: 1/);
  assert.match(formatArmComparison(result), /resume pass, cold fail: 1/);
  const empty = compareArms({ label: 'none', results: [] });
  assert.deepEqual(empty.arms.cold.tokens, { median: null, sum: null });
});
