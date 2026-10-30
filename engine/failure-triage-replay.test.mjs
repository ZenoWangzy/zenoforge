import assert from 'node:assert/strict';
import test from 'node:test';

import { replayTriage } from './failure-triage-replay.mjs';

const suite = 'engine/lib.test.sh';
const sha = (n) => String(n).repeat(40);
const window = { from: '2026-10-20T00:00:00Z', until: '2026-10-24T00:00:00Z' };
const compare = {
  baseSha: sha(1),
  headSha: sha(2),
  mergeBaseSha: sha(3),
  behind: 2,
  prFiles: ['docs/readme.md'],
  mainFiles: [suite],
  complete: true,
};

test('replays only resolved sessions in the requested window and reports coverage', () => {
  const result = replayTriage({
    window,
    baseline: { repairRows: 346, noPatchRows: 156, units: 114, repairSessions: 251 },
    coverage: { daysWithUnresolvedSessionLinks: ['2026-10-19', '2026-10-20'], allLedgerSessionLinks: 251, allLedgerSessionsResolved: 194 },
    events: [
      { at: '2026-10-21T10:00:00Z', unitId: 'u1', session: { id: 's1', resolved: true, freshTokens: 120 }, cancelledUpstream: false, suites: [suite], compare, observedOwner: 'stale-base' },
      { at: '2026-10-21T11:00:00Z', unitId: 'u2', session: { id: 's2', resolved: false }, cancelledUpstream: false, suites: [suite], compare },
      { at: '2026-10-24T00:00:00Z', unitId: 'u3', session: { id: 's3', resolved: true, freshTokens: 40 }, cancelledUpstream: false, suites: [suite], compare },
    ],
  });

  assert.deepEqual(result.coverage.rows, { used: 1, inWindow: 2, recordedBaselineReference: 346 });
  assert.deepEqual(result.coverage.units, { used: 1, inWindow: 2, ledgerUnitsWithRepairRows: 114 });
  assert.deepEqual(result.coverage.sessions, { used: 1, linkedInWindow: 2, ledgerRepairSessionLinks: 251 });
  assert.deepEqual(result.coverage.daysWithUnresolvedSessionLinks, ['2026-10-19', '2026-10-20']);
  assert.equal(result.verdicts['stale-base'], 1);
  assert.equal(result.freshTokens.avoidedByConfirmedStaleVerdicts, 120);
});

test('passes cancellation through and leaves missing cancellation or compare facts unknown', () => {
  const result = replayTriage({
    window,
    events: [
      { at: '2026-10-21T10:00:00Z', unitId: 'u1', session: { id: 's1', resolved: true }, cancelledUpstream: true, suites: [suite], compare },
      { at: '2026-10-21T11:00:00Z', unitId: 'u2', session: { id: 's2', resolved: true }, suites: [suite], compare },
      { at: '2026-10-21T12:00:00Z', unitId: 'u3', session: { id: 's3', resolved: true }, cancelledUpstream: false, suites: [suite], compare: { ...compare, headSha: 'branch-name' } },
    ],
  });

  assert.deepEqual(result.verdicts, { cancelled: 1, 'stale-base': 0, attributable: 0, unknown: 2 });
  assert.equal(result.coverage.pinnedCompareRows, 2);
});

test('reports false stale-base verdicts and only credits confirmed stale sessions', () => {
  const result = replayTriage({
    window,
    events: [
      { at: '2026-10-21T10:00:00Z', unitId: 'u1', session: { id: 's1', resolved: true, freshTokens: 120 }, cancelledUpstream: false, suites: [suite], compare, observedOwner: 'attributable', ciMinutes: 18 },
      { at: '2026-10-21T11:00:00Z', unitId: 'u2', session: { id: 's2', resolved: true, freshTokens: 40 }, cancelledUpstream: false, suites: [suite], compare },
    ],
  });

  assert.equal(result.falseStaleVerdicts, 1);
  assert.equal(result.confirmedStaleVerdicts, 0);
  assert.equal(result.unverifiedStaleVerdicts, 1);
  assert.equal(result.freshTokens.avoidedByConfirmedStaleVerdicts, 0);
  assert.equal(result.ciMinutesWrongVerdictsObserved, 18);
  assert.equal(result.ciMinutesWrongVerdictsWouldHaveWasted, null);
});

test('conflicting usage for one confirmed stale session stays unavailable', () => {
  const result = replayTriage({
    window,
    events: [
      { at: '2026-10-21T10:00:00Z', unitId: 'u1', session: { id: 's1', resolved: true, freshTokens: 120 }, cancelledUpstream: false, suites: [suite], compare, observedOwner: 'stale-base' },
      { at: '2026-10-21T11:00:00Z', unitId: 'u1', session: { id: 's1', resolved: true, freshTokens: 200 }, cancelledUpstream: false, suites: [suite], compare, observedOwner: 'stale-base' },
      { at: '2026-10-21T12:00:00Z', unitId: 'u1', session: { id: 's1', resolved: true, freshTokens: 120 }, cancelledUpstream: false, suites: [suite], compare, observedOwner: 'stale-base' },
    ],
  });

  assert.equal(result.confirmedStaleVerdicts, 3);
  assert.equal(result.freshTokens.availableInUsedSessions, null);
  assert.equal(result.freshTokens.avoidedByConfirmedStaleVerdicts, null);
  assert.equal(result.freshTokens.missingAvoidedTokenSessions, 1);
});

test('package Vitest suites remain unknown through the shared classifier', () => {
  const result = replayTriage({
    window,
    events: [{
      at: '2026-10-21T10:00:00Z',
      unitId: 'u1',
      session: { id: 's1', resolved: true },
      cancelledUpstream: false,
      suites: ['packages/shared/tests/example.test.ts'],
      compare,
    }],
  });

  assert.equal(result.verdicts.unknown, 1);
});
