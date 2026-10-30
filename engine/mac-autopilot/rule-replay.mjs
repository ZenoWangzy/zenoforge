#!/usr/bin/env node
// Pure seven-day replay of a candidate control rule against the autopilot unit ledger.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const WINDOW_MS = 7 * 24 * 60 * 60 * 1000;
const RULING_STAGES = new Set(['supervisor-requeue', 'supervisor-approve', 'advisor-ruling']);
const ACCEPTED_STAGES = new Set(['review-approve', 'supervisor-approve', 'merged', 'landed']);
const STOP_STAGES = new Set(['hold', 'on-hold', 'stop-loss', 'budget-stop', 'supervisor-budget-park']);
const OPERATORS = new Set(['eq', 'ne', 'gt', 'gte', 'lt', 'lte', 'in', 'contains', 'exists']);
const MISSING = Symbol('missing');

function hasOwn(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function instant(value, label) {
  const text = value instanceof Date ? value.toISOString() : value;
  if (typeof text !== 'string'
      || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/.test(text)) {
    throw new Error(`${label} must be an ISO timestamp with a timezone`);
  }
  const milliseconds = Date.parse(text);
  if (!Number.isFinite(milliseconds)) throw new Error(`${label} must be a valid ISO timestamp`);
  return milliseconds;
}

function scalar(value, label) {
  if (value !== null && !['string', 'number', 'boolean'].includes(typeof value)) {
    throw new Error(`${label} must be a JSON scalar`);
  }
  if (typeof value === 'number' && !Number.isFinite(value)) {
    throw new Error(`${label} must be finite`);
  }
}

function validatePredicate(predicate) {
  if (!predicate || typeof predicate !== 'object' || Array.isArray(predicate)) {
    throw new Error('rule.predicate must be an object');
  }
  const keys = Object.keys(predicate);
  for (const operator of ['all', 'any']) {
    if (hasOwn(predicate, operator)) {
      if (keys.length !== 1 || !Array.isArray(predicate[operator]) || predicate[operator].length === 0) {
        throw new Error(`predicate.${operator} must be a non-empty array`);
      }
      predicate[operator].forEach(validatePredicate);
      return;
    }
  }
  if (hasOwn(predicate, 'not')) {
    if (keys.length !== 1) throw new Error('predicate.not cannot have sibling fields');
    validatePredicate(predicate.not);
    return;
  }

  if (typeof predicate.path !== 'string' || predicate.path.length === 0
      || predicate.path.split('.').some((part) => part.length === 0)) {
    throw new Error('predicate.path must be a non-empty dotted path');
  }
  if (!OPERATORS.has(predicate.op)) throw new Error(`unsupported predicate operator: ${predicate.op}`);
  const allowedKeys = predicate.op === 'exists' ? ['path', 'op'] : ['path', 'op', 'value'];
  if (keys.some((key) => !allowedKeys.includes(key))
      || !hasOwn(predicate, 'path') || !hasOwn(predicate, 'op')
      || (predicate.op !== 'exists' && !hasOwn(predicate, 'value'))) {
    throw new Error('predicate must contain only path, op, and the operator value');
  }
  if (['gt', 'gte', 'lt', 'lte'].includes(predicate.op)
      && (typeof predicate.value !== 'number' || !Number.isFinite(predicate.value))) {
    throw new Error(`${predicate.op} predicate value must be a finite number`);
  }
  if (predicate.op === 'in') {
    if (!Array.isArray(predicate.value) || predicate.value.length === 0) {
      throw new Error('in predicate value must be a non-empty array');
    }
    predicate.value.forEach((value) => scalar(value, 'in predicate value'));
  } else if (predicate.op !== 'exists') {
    scalar(predicate.value, 'predicate.value');
  }
}

function validateRule(rule) {
  if (!rule || typeof rule !== 'object' || Array.isArray(rule)) throw new Error('rule must be an object');
  if (typeof rule.id !== 'string' || rule.id.trim() === '') throw new Error('rule.id must be a non-empty string');
  validatePredicate(rule.predicate);
}

function lookup(root, path) {
  let value = root;
  for (const part of path.split('.')) {
    if (value === null || typeof value !== 'object' || !hasOwn(value, part)) return MISSING;
    value = value[part];
  }
  return value;
}

function matches(snapshot, predicate) {
  if (hasOwn(predicate, 'all')) return predicate.all.every((entry) => matches(snapshot, entry));
  if (hasOwn(predicate, 'any')) return predicate.any.some((entry) => matches(snapshot, entry));
  if (hasOwn(predicate, 'not')) return !matches(snapshot, predicate.not);

  const actual = lookup(snapshot, predicate.path);
  if (predicate.op === 'exists') return actual !== MISSING;
  if (actual === MISSING) return false;
  switch (predicate.op) {
    case 'eq': return actual === predicate.value;
    case 'ne': return actual !== predicate.value;
    case 'gt': return typeof actual === 'number' && Number.isFinite(actual) && actual > predicate.value;
    case 'gte': return typeof actual === 'number' && Number.isFinite(actual) && actual >= predicate.value;
    case 'lt': return typeof actual === 'number' && Number.isFinite(actual) && actual < predicate.value;
    case 'lte': return typeof actual === 'number' && Number.isFinite(actual) && actual <= predicate.value;
    case 'in': return predicate.value.includes(actual);
    case 'contains': return typeof actual === 'string'
      ? actual.includes(String(predicate.value))
      : Array.isArray(actual) && actual.includes(predicate.value);
    default: return false;
  }
}

function rawTokensFrom(event) {
  const explicit = [event.metrics?.rawTokens, event.rawTokens, event.raw_tokens, event.tokens];
  for (const value of explicit) {
    if (Number.isSafeInteger(value) && value >= 0) return value;
  }
  if (typeof event.result === 'string') {
    const match = /\b(?:raw_?tokens|tokens)=(\d+)(?:\/\d+)?\b/i.exec(event.result);
    if (match) {
      const value = Number(match[1]);
      if (Number.isSafeInteger(value)) return value;
    }
  }
  return null;
}

function unitProjection(unit) {
  const fields = ['id', 'issue', 'pr', 'lane'];
  return Object.fromEntries(fields.filter((field) => hasOwn(unit, field)).map((field) => [field, unit[field]]));
}

function replayUnit(unit, rule, fromMs, untilMs) {
  if (!unit || typeof unit !== 'object' || Array.isArray(unit)
      || typeof unit.id !== 'string' || unit.id.trim() === '') {
    throw new Error('every ledger unit must have a non-empty string id');
  }
  const history = unit.history ?? [];
  if (!Array.isArray(history)) throw new Error(`unit ${unit.id} history must be an array`);
  const events = history.map((event, index) => {
    if (!event || typeof event !== 'object' || Array.isArray(event)) {
      throw new Error(`unit ${unit.id} history[${index}] must be an object`);
    }
    return { event, index, atMs: instant(event.at, `unit ${unit.id} history[${index}].at`) };
  }).sort((left, right) => left.atMs - right.atMs || left.index - right.index);

  let rounds = 0;
  let firstWriteAt = null;
  let rawTokens = null;
  let previousMatch = false;
  let trigger = null;
  let eventsInWindow = 0;
  const snapshots = [];
  const identity = unitProjection(unit);

  for (const entry of events) {
    if (entry.atMs > untilMs) continue;
    if (entry.atMs >= fromMs) eventsInWindow += 1;
    const stage = entry.event.stage;
    if (RULING_STAGES.has(stage)) {
      rounds = 0;
      firstWriteAt = null;
    }
    if (stage === 'write-start') {
      rounds += 1;
      if (firstWriteAt === null) firstWriteAt = entry.atMs;
    }
    const observedTokens = rawTokensFrom(entry.event);
    if (observedTokens !== null) rawTokens = observedTokens;

    const snapshot = {
      unit: identity,
      event: entry.event,
      metrics: {
        rawTokens,
        rounds,
        elapsedSeconds: firstWriteAt === null ? null : Math.max(0, (entry.atMs - firstWriteAt) / 1000),
      },
    };
    snapshots.push({ atMs: entry.atMs, snapshot });
    const currentMatch = matches(snapshot, rule.predicate);
    if (trigger === null && currentMatch && !previousMatch && entry.atMs >= fromMs) {
      trigger = { ...snapshots.at(-1), position: snapshots.length - 1 };
    }
    previousMatch = currentMatch;
  }

  if (!trigger) return { eventsInWindow, outcome: null };

  const later = snapshots.slice(trigger.position + 1);
  const accepted = later.find((entry) => ACCEPTED_STAGES.has(entry.snapshot.event.stage));
  const stop = snapshots.slice(trigger.position).find((entry) => isStopEvidence(entry.snapshot.event));
  const triggerRecord = {
    at: new Date(trigger.atMs).toISOString(),
    stage: trigger.snapshot.event.stage ?? null,
    metrics: trigger.snapshot.metrics,
  };

  if (accepted) {
    return {
      eventsInWindow,
      outcome: {
        category: 'falseStop',
        unitId: unit.id,
        trigger: triggerRecord,
        accepted: { at: new Date(accepted.atMs).toISOString(), stage: accepted.snapshot.event.stage },
      },
    };
  }
  if (stop) {
    const evidence = { at: new Date(stop.atMs).toISOString(), stage: stop.snapshot.event.stage };
    return {
      eventsInWindow,
      outcome: { category: 'intercepted', unitId: unit.id, trigger: triggerRecord, evidence },
    };
  }
  const last = snapshots.at(-1);
  return {
    eventsInWindow,
    outcome: {
      category: 'unresolved',
      unitId: unit.id,
      trigger: triggerRecord,
      lastObserved: last ? { at: new Date(last.atMs).toISOString(), stage: last.snapshot.event.stage ?? null } : null,
      currentStage: unit.stage ?? null,
    },
  };
}

function isStopEvidence(event) {
  if (!STOP_STAGES.has(event.stage)) return false;
  if (event.stage !== 'supervisor-budget-park') return true;
  const reason = [event.result, event.reason, event.event].filter((value) => typeof value === 'string').join(' ');
  return /lifetime spend budget|stop-loss|rounds?\s+\d+\s+of|wall\s+\d+\s*min|tokens=\d+/i.test(reason);
}

export function replayRule(ledger, rule, { asOf, generatedAt = asOf } = {}) {
  validateRule(rule);
  if (!ledger || typeof ledger !== 'object' || !Array.isArray(ledger.units)) {
    throw new Error('ledger.units must be an array');
  }
  const untilMs = instant(asOf, 'asOf');
  const generatedAtMs = instant(generatedAt, 'generatedAt');
  const fromMs = untilMs - WINDOW_MS;
  const coverage = { unitsInLedger: ledger.units.length, unitsInWindow: 0, eventsInWindow: 0, historyEventsRead: 0 };
  const falseStops = [];
  const intercepted = [];
  const unresolved = [];

  for (const unit of ledger.units) {
    const replay = replayUnit(unit, rule, fromMs, untilMs);
    if (replay.eventsInWindow > 0) coverage.unitsInWindow += 1;
    coverage.eventsInWindow += replay.eventsInWindow;
    const history = unit.history ?? [];
    coverage.historyEventsRead += history.filter((event) => instant(event.at, `unit ${unit.id} history.at`) <= untilMs).length;
    if (!replay.outcome) continue;
    if (replay.outcome.category === 'falseStop') falseStops.push(replay.outcome);
    else if (replay.outcome.category === 'intercepted') intercepted.push(replay.outcome);
    else unresolved.push(replay.outcome);
  }

  for (const list of [falseStops, intercepted, unresolved]) {
    list.sort((left, right) => left.trigger.at.localeCompare(right.trigger.at) || left.unitId.localeCompare(right.unitId));
  }
  return {
    schema: 'zf-control-rule-replay/v1',
    event: { type: 'control-rule-replay.completed', at: new Date(generatedAtMs).toISOString() },
    rule: { id: rule.id, ...(typeof rule.description === 'string' ? { description: rule.description } : {}), predicate: rule.predicate },
    window: { from: new Date(fromMs).toISOString(), until: new Date(untilMs).toISOString(), days: 7 },
    coverage,
    falseStops,
    intercepted,
    unresolved,
  };
}

function decisionsByUnit(report) {
  const decisions = new Map();
  for (const [list, category] of [['falseStops', 'falseStop'], ['intercepted', 'intercepted'], ['unresolved', 'unresolved']]) {
    for (const outcome of report[list]) decisions.set(outcome.unitId, category);
  }
  return decisions;
}

function compareReplays(baseline, candidate) {
  const baselineDecisions = decisionsByUnit(baseline);
  const candidateDecisions = decisionsByUnit(candidate);
  const unitIds = new Set([...baselineDecisions.keys(), ...candidateDecisions.keys()]);
  const changedDecisions = [...unitIds]
    .filter((unitId) => baselineDecisions.get(unitId) !== candidateDecisions.get(unitId))
    .sort()
    .map((unitId) => ({
      unitId,
      baseline: baselineDecisions.get(unitId) ?? null,
      candidate: candidateDecisions.get(unitId) ?? null,
    }));
  const baselineFalseStops = new Set(baseline.falseStops.map((outcome) => outcome.unitId));

  return {
    baseline: { rule: baseline.rule },
    changedDecisions,
    newFalseStops: candidate.falseStops.filter((outcome) => !baselineFalseStops.has(outcome.unitId)),
  };
}

function runCli(argv) {
  if (argv.length < 3) {
    throw new Error('usage: rule-replay.mjs <units.json> <candidate-rule.json> <report.json> [--baseline <rule.json>] [--as-of <ISO timestamp>]');
  }
  const [ledgerPath, rulePath, reportPath, ...options] = argv;
  let asOf;
  let baselinePath;
  for (let index = 0; index < options.length;) {
    const option = options[index];
    const value = options[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`${option} requires a value`);
    if (option === '--as-of' && asOf === undefined) asOf = value;
    else if (option === '--baseline' && baselinePath === undefined) baselinePath = value;
    else throw new Error(`unsupported or repeated option: ${option}`);
    index += 2;
  }
  const ledger = JSON.parse(readFileSync(ledgerPath, 'utf8'));
  const rule = JSON.parse(readFileSync(rulePath, 'utf8'));
  const baselineRule = baselinePath ? JSON.parse(readFileSync(baselinePath, 'utf8')) : undefined;
  const generatedAt = new Date().toISOString();
  const report = replayRule(ledger, rule, { asOf: asOf ?? generatedAt, generatedAt });
  if (baselinePath) {
    const baseline = replayRule(ledger, baselineRule, { asOf: asOf ?? generatedAt, generatedAt });
    Object.assign(report, compareReplays(baseline, report));
  }
  report.source = {
    ledger: resolve(ledgerPath),
    candidateRule: resolve(rulePath),
    ...(baselinePath ? { baselineRule: resolve(baselinePath) } : {}),
  };
  const output = resolve(reportPath);
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
  const comparison = baselineRule
    ? ` changed-decisions=${report.changedDecisions.length} new-false-stops=${report.newFalseStops.length}`
    : '';
  process.stdout.write(`${rule.id}: false-stops=${report.falseStops.length} intercepted=${report.intercepted.length} unresolved=${report.unresolved.length}${comparison}\nreport=${output}\n`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
