#!/usr/bin/env node
// Offline replay for ticket 11. Inputs contain copied repair rows and immutable
// GitHub compare facts; this command never resolves refs or calls GitHub.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { triage } from './failure-triage.mjs';

const SHA_RE = /^[0-9a-f]{40}$/i;
const OBSERVED_OWNERS = new Set([
  'stale-base', 'attributable', 'cancellation', 'infrastructure', 'missing-log',
]);

function hasPinnedCompare(compare) {
  return compare?.complete === true
    && SHA_RE.test(compare.baseSha ?? '')
    && SHA_RE.test(compare.headSha ?? '')
    && SHA_RE.test(compare.mergeBaseSha ?? '')
    && Number.isInteger(compare.behind)
    && compare.behind >= 0
    && Array.isArray(compare.prFiles)
    && Array.isArray(compare.mainFiles);
}

function verdictFor(event) {
  // Ticket 10 owns this predicate. Missing its result is not evidence of a genuine failure.
  if (event.cancelledUpstream === true) return 'cancelled';
  if (event.cancelledUpstream !== false || !hasPinnedCompare(event.compare)) return 'unknown';

  return triage({
    suites: event.suites,
    prFiles: event.compare.prFiles,
    mainFiles: event.compare.mainFiles,
    behind: event.compare.behind,
    complete: true,
  });
}

function timestamp(value, label) {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) throw new Error(`${label} must be an ISO timestamp`);
  return parsed;
}

function countSessions(events) {
  const sessions = new Map();
  const conflicts = new Set();
  for (const event of events) {
    const session = event.session;
    if (!session || typeof session.id !== 'string' || !session.id) continue;
    if (conflicts.has(session.id)) continue;
    const freshTokens = Number.isSafeInteger(session.freshTokens) ? session.freshTokens : null;
    if (!sessions.has(session.id)) {
      sessions.set(session.id, freshTokens);
    } else if (sessions.get(session.id) === null && freshTokens !== null) {
      sessions.set(session.id, freshTokens);
    } else if (freshTokens !== null && sessions.get(session.id) !== freshTokens) {
      sessions.set(session.id, null);
      conflicts.add(session.id);
    }
  }
  return sessions;
}

export function replayTriage(input) {
  const start = timestamp(input.window?.from, 'window.from');
  const until = timestamp(input.window?.until, 'window.until');
  if (until <= start) throw new Error('window.until must be after window.from');
  if (!Array.isArray(input.events)) throw new Error('events must be an array');

  const rowsInWindow = input.events.filter((event) => {
    const at = timestamp(event.at, 'event.at');
    return at >= start && at < until;
  });
  const replayRows = rowsInWindow.filter((event) => event.session?.resolved === true
    && typeof event.session.id === 'string' && event.session.id.length > 0);
  const sessionsInWindow = new Set(rowsInWindow
    .map((event) => event.session?.id)
    .filter((id) => typeof id === 'string' && id.length > 0));
  const sessionsUsed = countSessions(replayRows);

  const verdicts = { cancelled: 0, 'stale-base': 0, attributable: 0, unknown: 0 };
  const observedOwners = {
    'stale-base': 0, attributable: 0, cancellation: 0, infrastructure: 0, 'missing-log': 0,
    unavailable: 0,
  };
  const patchOutcomes = { 'no-patch': 0, 'changed-file': 0, unknown: 0 };
  let falseStaleVerdicts = 0;
  let confirmedStaleVerdicts = 0;
  let unverifiedStaleVerdicts = 0;
  let freshTokensAvoided = 0;
  let missingAvoidedTokenSessions = 0;
  let wrongVerdictCiMinutes = 0;
  let missingWrongVerdictCiMinutes = false;
  const countedAvoidedSessions = new Set();

  for (const event of replayRows) {
    const verdict = verdictFor(event);
    verdicts[verdict] += 1;

    const owner = OBSERVED_OWNERS.has(event.observedOwner) ? event.observedOwner : 'unavailable';
    observedOwners[owner] += 1;
    if (event.patchStatus === 'no-patch' || event.patchStatus === 'changed-file') {
      patchOutcomes[event.patchStatus] += 1;
    } else {
      patchOutcomes.unknown += 1;
    }

    if (verdict === 'stale-base') {
      if (owner === 'stale-base') {
        confirmedStaleVerdicts += 1;
        const session = event.session;
        if (!countedAvoidedSessions.has(session.id)) {
          countedAvoidedSessions.add(session.id);
          const freshTokens = sessionsUsed.get(session.id);
          if (Number.isSafeInteger(freshTokens)) freshTokensAvoided += freshTokens;
          else missingAvoidedTokenSessions += 1;
        }
      } else if (owner === 'unavailable') {
        unverifiedStaleVerdicts += 1;
      } else {
        falseStaleVerdicts += 1;
        if (Number.isFinite(event.ciMinutes) && event.ciMinutes >= 0) {
          wrongVerdictCiMinutes += event.ciMinutes;
        } else {
          missingWrongVerdictCiMinutes = true;
        }
      }
    }
  }

  const unitsInWindow = new Set(rowsInWindow.map((event) => event.unitId).filter(Boolean));
  const unitsUsed = new Set(replayRows.map((event) => event.unitId).filter(Boolean));
  const sessionsWithUsage = [...sessionsUsed.values()].filter(Number.isSafeInteger).length;
  const freshTokensAvailable = sessionsWithUsage === sessionsUsed.size
    ? [...sessionsUsed.values()].reduce((sum, value) => sum + value, 0)
    : null;
  const compareEvidenceRows = replayRows.filter((event) => hasPinnedCompare(event.compare)).length;
  const cancellationEvidenceRows = replayRows.filter((event) => typeof event.cancelledUpstream === 'boolean').length;
  const knownWrongVerdictCiMinutes = falseStaleVerdicts === 0
    ? 0
    : missingWrongVerdictCiMinutes ? null : wrongVerdictCiMinutes;
  const ciMinutesWouldHaveWasted = unverifiedStaleVerdicts > 0
    ? null
    : knownWrongVerdictCiMinutes;

  return {
    window: input.window,
    coverage: {
      rows: {
        used: replayRows.length,
        inWindow: rowsInWindow.length,
        recordedBaselineReference: input.baseline?.repairRows ?? null,
      },
      units: {
        used: unitsUsed.size,
        inWindow: unitsInWindow.size,
        ledgerUnitsWithRepairRows: input.baseline?.units ?? null,
      },
      sessions: {
        used: sessionsUsed.size,
        linkedInWindow: sessionsInWindow.size,
        ledgerRepairSessionLinks: input.baseline?.repairSessions ?? null,
      },
      pinnedCompareRows: compareEvidenceRows,
      cancellationResultRows: cancellationEvidenceRows,
      daysWithUnresolvedSessionLinks: input.coverage?.daysWithUnresolvedSessionLinks ?? [],
      allLedgerSessionLinks: input.coverage?.allLedgerSessionLinks ?? null,
      allLedgerSessionsResolved: input.coverage?.allLedgerSessionsResolved ?? null,
      supervisorResolvedSessionLinks: input.coverage?.supervisorResolvedSessionLinks ?? null,
    },
    verdicts,
    observedOwnership: observedOwners,
    patchOutcomes: {
      ...patchOutcomes,
      recordedNoPatchReference: input.baseline?.noPatchRows ?? null,
    },
    falseStaleVerdicts,
    confirmedStaleVerdicts,
    unverifiedStaleVerdicts,
    ciMinutesWrongVerdictsObserved: knownWrongVerdictCiMinutes,
    freshTokens: {
      availableInUsedSessions: freshTokensAvailable,
      sessionsWithUsage,
      avoidedByConfirmedStaleVerdicts: missingAvoidedTokenSessions === 0 ? freshTokensAvoided : null,
      missingAvoidedTokenSessions,
    },
    ciMinutesWrongVerdictsWouldHaveWasted: ciMinutesWouldHaveWasted,
  };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  try {
    const path = process.argv[2];
    if (!path) throw new Error('usage: failure-triage-replay.mjs <copied-replay-input.json>');
    const input = JSON.parse(readFileSync(path, 'utf8'));
    process.stdout.write(`${JSON.stringify(replayTriage(input), null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
