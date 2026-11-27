#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const MIN_SHA_PREFIX = 7;

function sameSha(a, b) {
  if (!a || !b) return false;
  const [short, long] = a.length <= b.length ? [a, b] : [b, a];
  return short.length >= MIN_SHA_PREFIX && long.startsWith(short);
}

function result(status, features, reasons) {
  return { status, features, reasons };
}

const PERFORMANCE_METRICS = ['first_paint_ms', 'largest_contentful_paint_ms', 'js_heap_used_mb', 'long_task_count'];
const MIN_PERFORMANCE_RUNS = 5;
const CONFIG_PATHS_DIR = fileURLToPath(new URL('./mac-autopilot/', import.meta.url));

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function validatePerformanceBudget(budgets) {
  const reasons = [];
  if (!isObject(budgets) || !isObject(budgets.default)) {
    return ['performance budget must be an object with a default entry'];
  }
  for (const [id, entry] of Object.entries(budgets)) {
    if (!isObject(entry)) {
      reasons.push('performance budget entry ' + id + ' must be an object');
      continue;
    }
    if (typeof entry.basis !== 'string' || entry.basis.trim().length < 20) {
      reasons.push('performance budget entry ' + id + ' basis must be a string of at least 20 characters');
    }
    for (const key of Object.keys(entry)) {
      if (key !== 'basis' && !PERFORMANCE_METRICS.includes(key)) {
        reasons.push('performance budget entry ' + id + ' has unknown metric ' + key);
      }
    }
    for (const metric of PERFORMANCE_METRICS) {
      const limit = entry[metric];
      if (limit === undefined) {
        if (id === 'default') reasons.push('performance budget default is missing metric ' + metric);
      } else if (typeof limit !== 'number' || !Number.isFinite(limit) || limit < 0) {
        reasons.push('performance budget entry ' + id + ' has invalid metric ' + metric);
      }
    }
  }
  return reasons;
}

function performanceDataReasons(id, performance) {
  if (!isObject(performance)) return ['feature ' + id + ' performance object is missing'];
  const reasons = [];
  for (const metric of PERFORMANCE_METRICS) {
    const measured = performance[metric];
    if (typeof measured !== 'number' || !Number.isFinite(measured) || measured < 0) {
      reasons.push('feature ' + id + ' performance.' + metric + ' must be a finite non-negative number');
    }
  }
  for (const count of ['run_count', 'error_count', 'work_count']) {
    const value = performance[count];
    if (!Number.isInteger(value) || value < 0) {
      reasons.push('feature ' + id + ' performance.' + count + ' must be a non-negative integer');
    }
  }
  if (Number.isInteger(performance.run_count) && performance.run_count >= 0 && performance.run_count < MIN_PERFORMANCE_RUNS) {
    reasons.push('feature ' + id + ' performance.run_count ' + performance.run_count + ' is below minimum ' + MIN_PERFORMANCE_RUNS);
  }
  if (Number.isInteger(performance.error_count) && performance.error_count > 0) {
    reasons.push('feature ' + id + ' performance.error_count is ' + performance.error_count + ', expected 0');
  }
  if (Number.isInteger(performance.work_count) && performance.work_count === 0) {
    reasons.push('feature ' + id + ' performance.work_count is 0, expected work to be confirmed');
  }
  return reasons;
}

export function checkProof(plan, proofText, head, budgetText = null) {
  const matched = plan?.matched_features;
  if (!Array.isArray(matched) || matched.some((id) => typeof id !== 'string' || !id)) {
    throw new Error('plan must carry a matched_features array of feature ids');
  }
  if (matched.length === 0) return result('not-required', {}, ['plan matches no feature']);
  if (typeof proofText !== 'string' || proofText.trim() === '') return result('missing', {}, ['proof file is absent or empty']);

  let proof;
  try {
    proof = JSON.parse(proofText);
  } catch (error) {
    return result('invalid', {}, ['proof is not JSON: ' + error.message]);
  }
  if (!proof || typeof proof !== 'object' || Array.isArray(proof)) return result('invalid', {}, ['proof must be a JSON object']);
  if (!Array.isArray(proof.features) || proof.features.length === 0) {
    return result('invalid', {}, ['proof.features must be a non-empty array of per-feature results']);
  }
  if (typeof proof.source_sha !== 'string' || !proof.source_sha) return result('invalid', {}, ['proof.source_sha is missing']);
  if (!sameSha(proof.source_sha, head)) {
    return result('stale', {}, ['proof.source_sha ' + proof.source_sha + ' differs from head ' + head]);
  }

  const features = {};
  const reasons = [];
  for (const id of matched) {
    const rows = proof.features.filter((row) => row?.feature_id === id);
    if (rows.length === 0) {
      features[id] = 'missing';
      reasons.push('no result for feature ' + id);
    } else if (rows.every((row) => row.status === 'PASS')) {
      features[id] = 'ok';
    } else {
      features[id] = 'failed';
      const failed = rows.find((row) => row.status !== 'PASS');
      reasons.push('feature ' + id + ' status is ' + (failed.status ?? 'absent') + ', not PASS');
    }
  }
  const values = Object.values(features);
  if (!values.every((value) => value === 'ok')) {
    return result(values.includes('missing') ? 'missing' : 'invalid', features, reasons);
  }
  if (budgetText === null || budgetText === undefined) return result('ok', features, []);

  let budgets;
  try {
    budgets = JSON.parse(budgetText);
  } catch (error) {
    return result('invalid', features, ['performance budget is not JSON: ' + error.message]);
  }
  const budgetReasons = validatePerformanceBudget(budgets);
  if (budgetReasons.length > 0) return result('invalid', Object.fromEntries(matched.map((id) => [id, 'failed'])), budgetReasons);

  const invalidReasons = [];
  const overBudgetReasons = [];
  const performanceFeatures = { ...features };
  for (const id of matched) {
    const rows = proof.features.filter((row) => row?.feature_id === id);
    if (rows.length !== 1) {
      invalidReasons.push('feature ' + id + ' must have exactly one result row for performance metrics');
      performanceFeatures[id] = 'failed';
      continue;
    }
    const performance = rows[0].performance;
    const dataReasons = performanceDataReasons(id, performance);
    if (dataReasons.length > 0) {
      invalidReasons.push(...dataReasons);
      performanceFeatures[id] = 'failed';
      continue;
    }
    const entry = budgets[id] ?? budgets.default;
    const limits = Object.fromEntries(PERFORMANCE_METRICS.map((metric) => [metric, entry[metric] ?? budgets.default[metric]]));
    for (const metric of PERFORMANCE_METRICS) {
      if (performance[metric] > limits[metric]) {
        overBudgetReasons.push('feature ' + id + ' metric ' + metric + ' measured=' + performance[metric] + ' budget=' + limits[metric] + ' (basis: ' + entry.basis + ')');
        performanceFeatures[id] = 'over-budget';
      }
    }
  }
  if (invalidReasons.length > 0) return result('invalid', performanceFeatures, invalidReasons);
  if (overBudgetReasons.length > 0) return result('over-budget', performanceFeatures, overBudgetReasons);
  return result('ok', performanceFeatures, []);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    const value = argv[++i];
    if (!value) throw new Error(`missing value for ${token}`);
    if (token === '--plan') args.plan = value;
    else if (token === '--proof') args.proof = value;
    else if (token === '--head') args.head = value;
    else throw new Error(`unknown argument: ${token}`);
  }
  for (const name of ['plan', 'proof', 'head']) if (!args[name]) throw new Error(`--${name} is required`);
  return args;
}

function resolvePerformanceBudgetPath() {
  const resolved = spawnSync('python3', [
    '-c',
    'from config_paths import zf_config_file; path = zf_config_file("state/perf-budget.json"); print(path or "")',
  ], { cwd: CONFIG_PATHS_DIR, encoding: 'utf8' });
  if (resolved.error) throw new Error('cannot resolve performance budget: ' + resolved.error.message);
  if (resolved.status !== 0) throw new Error('cannot resolve performance budget: ' + resolved.stderr.trim());
  return resolved.stdout.trim() || null;
}

export function runCli(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  let plan;
  try {
    plan = JSON.parse(readFileSync(args.plan, 'utf8'));
  } catch (error) {
    throw new Error('cannot read plan ' + args.plan + ': ' + error.message);
  }
  const proofText = existsSync(args.proof) ? readFileSync(args.proof, 'utf8') : null;
  const functional = checkProof(plan, proofText, args.head);
  let budgetPath;
  try {
    budgetPath = resolvePerformanceBudgetPath();
  } catch (error) {
    const output = functional.status === 'ok'
      ? result('invalid', functional.features, ['performance budget file could not be resolved: ' + error.message])
      : functional;
    process.stdout.write(JSON.stringify(output) + '\n');
    return;
  }
  if (!budgetPath) {
    console.error('verify-proof-check: no performance budget file; performance checks skipped');
    process.stdout.write(JSON.stringify(functional) + '\n');
    return;
  }
  if (functional.status !== 'ok') {
    process.stdout.write(JSON.stringify(functional) + '\n');
    return;
  }
  let budgetText;
  try {
    budgetText = readFileSync(budgetPath, 'utf8');
  } catch (error) {
    process.stdout.write(JSON.stringify(result('invalid', functional.features, ['performance budget file could not be read: ' + error.message])) + '\n');
    return;
  }
  process.stdout.write(JSON.stringify(checkProof(plan, proofText, args.head, budgetText)) + '\n');
}

if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(SCRIPT_PATH)) {
  try {
    runCli();
  } catch (error) {
    console.error(`verify-proof-check: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(2);
  }
}
