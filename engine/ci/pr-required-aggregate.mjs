#!/usr/bin/env node
import { readFileSync } from 'node:fs';
// #4484: the single aggregate required check (re-actors/alls-green pattern, implemented
// locally). The merge gates no longer enumerate conditionally-skipping job names as
// "required" -- each PR workflow reports ONE always-concluding aggregate row instead, and
// that row is what required-pr-checks.json requires. This script computes the verdict:
// every named gate either passed, or is a conditional gate that legitimately did not run
// because the workflow's run condition was false at event time. A gate that skipped while
// the condition says it should have run fails HERE, immediately and visibly -- a red
// verdict instead of the pre-#4484 permanent "required checks skipped" wait.
//
// Usage (name=result pairs are the GitHub Actions `needs` results):
//   node engine/ci/pr-required-aggregate.mjs \
//     --expected <true|false> \
//     [--always name,...] [--conditional name,...] name=result ...
//   gh pr view/list JSON or a `gh pr checks` JSON array may be piped to
//     node engine/ci/pr-required-aggregate.mjs --latest-checks
//     the shared "latest same-name check" reader: SKIPPED rows are dropped
//     first -- a later pull_request_target run's skipped copy of the gates
//     must not mask the pull_request conclusion (#4687) -- then each name
//     keeps only the newest comparable run on the PR head, so a row canceled
//     by a newer run no longer blocks, while a cancellation that IS the
//     newest run still fails closed.
// --expected is the same ownership clause the heavy gates' own `if:` evaluates
// (agent/issue- branch prefix, PR_CI var, or the pipeline-ci label): it is the single
// source of truth for whether the conditional gates should have run.
// Exit 0 = aggregate green; exit 1 = red (stderr names every offender); exit 2 = bad argv.

function runId(row) {
  const link = row.detailsUrl ?? row.targetUrl ?? row.link ?? '';
  const match = /\/actions\/runs\/(\d+)(?:\/|$)/.exec(link);
  return match ? BigInt(match[1]) : null;
}

function checkTime(row) {
  const value = row.startedAt ?? row.started_at ?? row.createdAt ?? row.created_at ?? row.completedAt ?? row.completed_at;
  if (typeof value !== 'string') return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function latestCheckRows(rows, headSha = '') {
  if (!Array.isArray(rows)) throw new TypeError('statusCheckRollup must be an array');
  const groups = new Map();
  const unkeyed = [];
  rows.forEach((row, index) => {
    if (!row || typeof row !== 'object') return;
    // Dropped before selection: a SKIPPED row is another event's "did not run
    // here" copy, never this head's conclusion (#4687); `gh pr checks` reports
    // those rows as bucket "skipping".
    if (row.conclusion === 'SKIPPED' || row.bucket === 'skipping') return;
    const rowHead = row.headSha ?? row.head_sha;
    if (headSha && typeof rowHead === 'string' && rowHead !== headSha) return;
    const name = row.name ?? row.context;
    if (typeof name !== 'string' || name.length === 0) {
      unkeyed.push({ row, index });
      return;
    }
    const group = groups.get(name) ?? [];
    group.push({ row, index });
    groups.set(name, group);
  });

  const latest = [];
  for (const group of groups.values()) {
    if (group.length === 1) {
      latest.push(group[0]);
      continue;
    }
    const runIds = group.map(({ row }) => runId(row));
    const times = group.map(({ row }) => checkTime(row));
    let candidates = group;
    if (runIds.every((id) => id !== null)) {
      const newestRun = runIds.reduce((newest, id) => (id > newest ? id : newest));
      candidates = group.filter((_, index) => runIds[index] === newestRun);
      if (candidates.length > 1 && candidates.every(({ row }) => checkTime(row) !== null)) {
        const newestTime = candidates.reduce((newest, { row }) => Math.max(newest, checkTime(row)), -Infinity);
        const newestRows = candidates.filter(({ row }) => checkTime(row) === newestTime);
        if (newestRows.length === 1) candidates = newestRows;
      }
    } else if (times.every((time) => time !== null)) {
      const newestTime = Math.max(...times);
      const newestRows = group.filter((_, index) => times[index] === newestTime);
      if (newestRows.length === 1) candidates = newestRows;
    }
    // Keep an unorderable duplicate set intact so callers retain their existing fail-closed
    // behavior. GitHub Actions rows carry run links or timestamps and are ordered above.
    latest.push(...candidates);
  }
  return [...latest, ...unkeyed].sort((left, right) => left.index - right.index).map(({ row }) => row);
}

function latestCheckInput(input) {
  if (Array.isArray(input) && input.every((row) => row && typeof row === 'object'
    && ('number' in row || Array.isArray(row.statusCheckRollup)))) {
    return input.map((pr) => ({
      ...pr,
      ...(Array.isArray(pr.statusCheckRollup)
        ? { statusCheckRollup: latestCheckRows(pr.statusCheckRollup, pr.headRefOid ?? pr.head_sha ?? '') }
        : {}),
    }));
  }
  if (input && typeof input === 'object' && Array.isArray(input.statusCheckRollup)) {
    return {
      ...input,
      statusCheckRollup: latestCheckRows(input.statusCheckRollup, input.headRefOid ?? input.head_sha ?? ''),
    };
  }
  return latestCheckRows(input);
}

if (process.argv[2] === '--latest-checks') {
  try {
    const input = JSON.parse(readFileSync(0, 'utf8'));
    // Wait for the write: process.exit() drops a piped stdout past 64 KiB, which left the
    // scheduler's merge census truncated ("check census unavailable", 10-29).
    await new Promise((resolve) => process.stdout.write(`${JSON.stringify(latestCheckInput(input))}\n`, resolve));
  } catch (error) {
    console.error(`could not select latest check rows: ${error.message}`);
    process.exit(2);
  }
  process.exit(0);
}

const args = process.argv.slice(2);
const results = new Map();
let expected = null;
let always = [];
let conditional = [];
for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  if (arg === '--expected') expected = args[++i];
  else if (arg === '--always') always = args[++i].split(',').filter(Boolean);
  else if (arg === '--conditional') conditional = args[++i].split(',').filter(Boolean);
  else {
    const eq = arg.indexOf('=');
    if (eq <= 0) {
      console.error(`unrecognized argument: ${arg}`);
      process.exit(2);
    }
    results.set(arg.slice(0, eq), arg.slice(eq + 1));
  }
}
if (expected !== 'true' && expected !== 'false') {
  console.error('--expected <true|false> is required: was the heavy-gate run condition true for this event?');
  process.exit(2);
}

const offenders = [];
for (const name of [...always, ...conditional]) {
  const result = results.get(name);
  if (result === undefined) {
    offenders.push(`${name}: no result reported (fail closed)`);
  } else if (result === 'success') {
    continue;
  } else if (result === 'skipped' && conditional.includes(name) && expected !== 'true') {
    continue;
  } else if (result === 'skipped') {
    offenders.push(`${name}: skipped although the run condition says it should have run`);
  } else {
    offenders.push(`${name}: ${result}`);
  }
}
if (offenders.length > 0) {
  console.error(`required gates not green:\n  ${offenders.join('\n  ')}`);
  process.exit(1);
}
console.log(`required gates green: ${always.length} always-required, ${conditional.length} conditional (expected=${expected})`);
