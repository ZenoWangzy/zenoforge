#!/usr/bin/env node
// Delivery-stage timings plus the factory flow numbers (#4366): merges per hour against
// the 6.5 target, per-stage WIP age of open runs, and in/out conservation. Thresholds and
// the threshold-crossing inbox events live in mac-autopilot/node_health.py (one place).
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const DEFAULT_FLOW_WINDOW_HOURS = 5;

function secondsBetween(start, end) {
  const a = Date.parse(start || '');
  const b = Date.parse(end || '');
  return Number.isFinite(a) && Number.isFinite(b) && b >= a ? (b - a) / 1000 : null;
}

function quantile(values, q) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const index = Math.max(0, Math.min(sorted.length - 1, Math.ceil(q * sorted.length) - 1));
  return sorted[index];
}

function summarize(values) {
  const clean = values.filter(Number.isFinite);
  return {
    samples: clean.length,
    p50_seconds: quantile(clean, 0.5),
    p95_seconds: quantile(clean, 0.95),
  };
}

// A merge counts only with its PR proof; production acceptance keeps the module's marker rules.
function mergedAt(state) {
  const run = state?.run ?? {};
  const evidence = run.evidence ?? {};
  const proof = evidence.merged_pr;
  return proof && String(proof.number) === String(evidence.pr_number)
    ? Date.parse(proof.merged_at || '') || null : null;
}

function productionAcceptedAt(state) {
  const run = state?.run ?? {};
  const evidence = run.evidence ?? {};
  if (state.deploy_state !== 'deployed' || !/^[0-9a-f]{40,64}$/i.test(state.deployed_sha || '')) return null;
  return ['URL:', 'Visible DOM:', 'Same-run network:'].every((marker) => (evidence.real_user_path || '').includes(marker))
    ? Date.parse(evidence.production_evidence_at || '') || null : null;
}

// The stage an open run is currently sitting in is the one whose end boundary is the first
// missing milestone; it was entered when the previous boundary was crossed.
const WIP_STAGES = ['queue_to_implement', 'implement_to_review', 'review_to_ci', 'ci_to_merge', 'merge_to_production'];

function wipStage(state) {
  const run = state?.run ?? {};
  const boundaries = [
    Date.parse(run.entered_at || '') || null,
    Date.parse(run.implement_started_at || '') || null,
    Date.parse(run.evidence?.review_ready_at || '') || null,
    Date.parse(run.evidence?.ci_completed_at || '') || null,
    mergedAt({ run }),
  ];
  if (boundaries[0] === null) return { stage: 'queue_to_implement', enteredAt: null };
  const firstMissing = boundaries.findIndex((at) => at === null);
  const stageIndex = firstMissing === -1 ? boundaries.length - 1 : firstMissing - 1;
  return { stage: WIP_STAGES[stageIndex], enteredAt: boundaries[stageIndex] };
}

function flowMetrics(states, nowMs, windowMs) {
  const since = nowMs - windowMs;
  let entered = 0;
  let merged = 0;
  const ages = Object.fromEntries(WIP_STAGES.map((stage) => [stage, []]));
  for (const { issue, state } of states) {
    const enteredAt = Date.parse(state?.run?.entered_at || '') || null;
    if (enteredAt !== null && enteredAt >= since && enteredAt <= nowMs) entered += 1;
    const mergedAtMs = mergedAt(state);
    if (mergedAtMs !== null && mergedAtMs >= since && mergedAtMs <= nowMs) merged += 1;
    if (productionAcceptedAt(state) !== null) continue;
    const { stage, enteredAt: stageAt } = wipStage(state);
    if (stage === null || stageAt === null || stageAt > nowMs) continue;
    ages[stage].push({ issue, seconds: (nowMs - stageAt) / 1000 });
  }
  const oldest = (rows) => rows.sort((a, b) => b.seconds - a.seconds || Number(a.issue) - Number(b.issue)).slice(0, 5);
  const hours = windowMs / 3_600_000;
  return {
    window_hours: hours,
    merges_per_hour: hours > 0 ? merged / hours : null,
    entered,
    merged,
    imbalance: Math.abs(entered - merged),
    wip_age_seconds: Object.fromEntries(Object.entries(ages).map(([stage, rows]) => [stage, {
      samples: rows.length,
      p50_seconds: quantile(rows.map((row) => row.seconds), 0.5),
      p90_seconds: quantile(rows.map((row) => row.seconds), 0.9),
      oldest: oldest(rows),
    }])),
  };
}

export function collectThroughputMetrics(stateDir, { now, windowHours = DEFAULT_FLOW_WINDOW_HOURS } = {}) {
  const nowMs = now === undefined ? Date.now()
    : now instanceof Date ? now.getTime() : (Date.parse(now) || NaN);
  if (!Number.isFinite(nowMs)) throw new TypeError('now must be a parseable date');
  const stages = {
    queue_to_implement: [],
    implement_to_review: [],
    review_to_ci: [],
    ci_to_merge: [],
    merge_to_production: [],
    end_to_end: [],
  };
  let stateFiles = 0;
  let productionAccepted = 0;
  const states = [];
  if (!stateDir || !existsSync(stateDir)) {
    const empty = Object.fromEntries(Object.entries(stages).map(([k, v]) => [k, summarize(v)]));
    return { state_files: 0, production_accepted: 0, stages: empty,
      flow: flowMetrics(states, nowMs, windowHours * 3_600_000) };
  }

  for (const name of readdirSync(stateDir).filter((item) => item.endsWith('.json'))) {
    stateFiles += 1;
    let state;
    try {
      state = JSON.parse(readFileSync(path.join(stateDir, name), 'utf8'));
    } catch {
      continue;
    }
    states.push({ issue: name.slice(0, -5), state });
    const run = state?.run ?? {};
    const evidence = run?.evidence ?? {};
    const entered = run.entered_at;
    const implement = run.implement_started_at;
    const review = evidence.review_ready_at;
    const ci = evidence.ci_completed_at;
    const mergedMs = mergedAt(state);
    const merged = mergedMs !== null ? evidence.merged_pr.merged_at : null;
    const production = productionAcceptedAt(state) !== null ? evidence.production_evidence_at : null;

    stages.queue_to_implement.push(secondsBetween(entered, implement));
    stages.implement_to_review.push(secondsBetween(implement, review));
    stages.review_to_ci.push(secondsBetween(review, ci));
    stages.ci_to_merge.push(secondsBetween(ci, merged));
    stages.merge_to_production.push(secondsBetween(merged, production));
    stages.end_to_end.push(secondsBetween(entered, production));
    if (production) productionAccepted += 1;
  }

  return {
    state_files: stateFiles,
    production_accepted: productionAccepted,
    stages: Object.fromEntries(Object.entries(stages).map(([key, values]) => [key, summarize(values)])),
    flow: flowMetrics(states, nowMs, windowHours * 3_600_000),
  };
}

function parseArgs(argv) {
  let stateDir = '';
  let now;
  let windowHours;
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--state-dir') stateDir = path.resolve(argv[++i] ?? '');
    else if (argv[i] === '--now') now = argv[++i];
    else if (argv[i] === '--hours') {
      windowHours = Number(argv[++i]);
      if (!Number.isFinite(windowHours) || windowHours <= 0) throw new Error('--hours needs a positive number');
    } else throw new Error(`unknown argument: ${argv[i]}`);
  }
  if (!stateDir) throw new Error('--state-dir is required');
  return { stateDir, now, windowHours };
}

if (process.argv[1] && path.resolve(process.argv[1]) === SCRIPT_PATH) {
  try {
    const { stateDir, now, windowHours } = parseArgs(process.argv.slice(2));
    const options = {};
    if (now !== undefined) options.now = now;
    if (windowHours !== undefined) options.windowHours = windowHours;
    process.stdout.write(`${JSON.stringify(collectThroughputMetrics(stateDir, options))}\n`);
  } catch (error) {
    console.error(`throughput-metrics: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}
