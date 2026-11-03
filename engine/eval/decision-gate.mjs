#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { compareResults, summarizeSupervisor } from './compare.mjs';
import { zfConfigFile } from '../pack-dir.mjs';

const here = dirname(fileURLToPath(import.meta.url));
// The full-coverage universe for gate labels. 'supervisor' is a selectable extra stage (the
// six-action arbitration prompt, #4369) but never part of the required full coverage: accepted
// labels predate it, and its terra calls are only spent when a diff actually touches it.
// --subset (the engine-pin gate, engine-sync.sh) keeps only the selected stages' cases at one
// run: a pin must not pay the full twice-run suite to compare the stages its diff touches.
const stages = ['triage', 'advisor', 'implement', 'review', 'end-to-end'];
const selectableStages = [...stages, 'supervisor'];
const evalHome = join(process.env.AGENT_HOME || process.env.ZF_HOME || join(homedir(), '.zenoforge'), 'eval');
const json = (path) => JSON.parse(readFileSync(path, 'utf8'));
function loadCases(repo, stage) {
  const path = zfConfigFile(`eval/cases/${stage}.json`, repo);
  if (!path) throw new Error(`eval cases are unavailable for stage ${stage}`);
  return json(path).cases;
}

function parseArgs(args) {
  const values = {};
  for (let index = 0; index < args.length; index++) {
    const key = args[index];
    if (key === '--subset') { values.subset = true; continue; }
    if (!key?.startsWith('--') || args[index + 1] === undefined) throw new Error(`invalid argument: ${key ?? ''}`);
    values[key.slice(2)] = args[index + 1];
    index += 1;
  }
  for (const key of ['repo', 'sha', 'tree', 'stages', 'baseline', 'label', 'output']) {
    if (!values[key]) throw new Error(`--${key} is required`);
  }
  return values;
}

function runEval(repo, args) {
  const runner = join(repo, 'engine/eval/run-eval.mjs');
  const result = spawnSync('node', [runner, ...args], {
    cwd: repo,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, GH_TOKEN: '', GITHUB_TOKEN: '' },
  });
  if (result.error || result.status !== 0) {
    throw new Error(`run-eval ${args.join(' ')} failed (${result.status ?? result.error?.code}): ${(result.stderr ?? '').slice(-1200)}`);
  }
  return result.stdout;
}

function requireFullCandidate(candidate, repo) {
  const expected = [];
  for (const stage of stages) {
    const cases = loadCases(repo, stage);
    for (const c of cases) for (let run = 1; run <= 2; run++) expected.push(`${stage}/${c.id}/${run}`);
  }
  const actual = new Set(candidate.results.map((row) => `${row.stage}/${row.caseId}/${row.run}`));
  const missing = expected.filter((id) => !actual.has(id));
  if (missing.length) throw new Error(`full evaluation is incomplete (${missing.length} case/run result(s) missing)`);
}

function requireComparableBaseline(baseline, repo) {
  const expected = new Set();
  for (const stage of stages) {
    const cases = loadCases(repo, stage);
    for (const c of cases) for (let run = 1; run <= 2; run++) expected.add(`${stage}/${c.id}/${run}`);
  }
  const actual = new Set(baseline.results.map((row) => `${row.stage}/${row.caseId}/${row.run}`));
  // Cases added since the baseline was accepted stay unpaired: the candidate runs them
  // (requireFullCandidate) and the comparison lists them as unpaired, never as flips.
  // Removed cases shrink the comparison silently, so they still fail here.
  const extra = [...actual].filter((id) => !expected.has(id));
  if (extra.length) {
    throw new Error(`accepted label ${baseline.label} does not cover the current eval cases (extra=${extra.length})`);
  }
}

function writeReport(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(temporary, path);
}

function mergeAcceptedSubset(baseline, candidate) {
  // A pin label becomes the accepted baseline for its version id. Keep accepted rows
  // for untouched stages so the next pin can compare a different stage against the
  // current live engine rather than an empty overlap. Candidate rows replace the
  // prior row for the same stage/case/run after they pass this gate.
  const key = (row) => `${row.stage}/${row.caseId}/${row.run}`;
  const rows = new Map((baseline.results ?? []).map((row) => [key(row), row]));
  for (const row of candidate.results ?? []) rows.set(key(row), row);
  return {
    ...candidate,
    results: [...rows.values()].sort((a, b) => key(a).localeCompare(key(b))),
  };
}

async function main() {
  const values = parseArgs(process.argv.slice(2));
  const repo = resolve(values.repo);
  const output = resolve(values.output);
  const selectedStages = values.stages.split(',').filter(Boolean);
  const concurrency = Number(values.concurrency ?? '3');
  if (!selectedStages.length || selectedStages.some((stage) => !selectableStages.includes(stage))) throw new Error('invalid --stages');
  if (!Number.isSafeInteger(concurrency) || concurrency < 1) throw new Error('--concurrency must be a positive integer');
  for (const label of [values.baseline, values.label]) {
    if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(label)) throw new Error(`invalid label: ${label}`);
  }
  const actualTree = spawnSync('git', ['-C', repo, 'rev-parse', `${values.sha}^{tree}`], { encoding: 'utf8' });
  if (actualTree.status !== 0 || actualTree.stdout.trim() !== values.tree) throw new Error('candidate SHA/tree mismatch');
  const actualHead = spawnSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  if (actualHead.status !== 0 || actualHead.stdout.trim() !== values.sha) throw new Error('candidate checkout is not at the reviewed SHA');
  // The pin gate runs from a built version directory, where BUILD-INFO and gate artifacts sit
  // untracked beside the engine; tracked-content drift still fails in both modes.
  const dirty = spawnSync('git', ['-C', repo, 'status', '--porcelain', values.subset ? '--untracked-files=no' : '--untracked-files=normal'], { encoding: 'utf8' });
  if (dirty.status !== 0 || dirty.stdout.trim()) throw new Error('candidate checkout has uncommitted changes');

  const baselinePath = join(evalHome, values.baseline, 'results.json');
  if (!existsSync(baselinePath)) throw new Error(`accepted evaluation label is missing: ${values.baseline}`);
  const baseline = json(baselinePath);
  requireComparableBaseline(baseline, repo);
  const candidatePath = join(evalHome, values.label, 'results.json');
  let resuming = existsSync(candidatePath);
  for (const stage of selectedStages) {
    const cases = loadCases(repo, stage);
    if (!cases.length) throw new Error(`no evaluation cases for affected stage ${stage}`);
    const args = ['--stage', stage, '--case', cases.map((c) => c.id).join(','), '--runs', '1',
      '--concurrency', String(concurrency), '--label', values.label];
    if (resuming) args.push('--resume');
    runEval(repo, args);
    resuming = true;
  }
  // The final full run stays scoped to the product stages: run-eval's own stage list also carries
  // 'supervisor', whose 141 terra arbitrations are not part of a full gate label (see stages above).
  // A subset label skips the completion entirely: only the selected stages' single runs exist,
  // and compareResults pairs just the case/runs both labels hold.
  if (!values.subset) {
    for (const stage of stages) {
      runEval(repo, ['--stage', stage, '--resume', '--concurrency', String(concurrency), '--label', values.label]);
    }
  }
  const candidate = json(candidatePath);
  if (!values.subset) requireFullCandidate(candidate, repo);
  const compareOutput = runEval(repo, ['--compare', values.baseline, values.label]).trim();
  const comparison = compareResults(baseline, candidate);
  // Introduced-incident review cases gate only a label that ran review; a subset without it has no review rows to fail.
  const criticalIds = selectedStages.includes('review')
    ? new Set(loadCases(repo, 'review').filter((c) => c.kind === 'introduced-incident').map((c) => c.id))
    : new Set();
  const criticalFailures = candidate.results
    .filter((row) => row.stage === 'review' && criticalIds.has(row.caseId) && row.pass !== true)
    .map((row) => `${row.caseId}/run-${row.run}`);
  // #4369 CTO gate for supervisor-prompt changes: no unsafe approve, and overall accuracy must meet or exceed
  // the constant-requeue reference on the same cases (the old arbiter's 2.8% baseline lost to its 71.6%).
  const supervisor = summarizeSupervisor(candidate.results);
  const supervisorFailures = [];
  if (supervisor.total) {
    const overall = supervisor.byAction && Object.values(supervisor.byAction).reduce((sum, row) => sum + row.correct, 0);
    if (supervisor.unsafeApproves > 0) supervisorFailures.push(`unsafe approves: ${supervisor.unsafeApproves}`);
    if (overall < supervisor.alwaysRequeue.correct) {
      supervisorFailures.push(`overall ${overall}/${supervisor.total} below the constant-requeue reference ${supervisor.alwaysRequeue.correct}/${supervisor.total}`);
    }
  }
  const regressions = comparison.regressions.map((row) => `${row.stage}/${row.caseId}/run-${row.run}`);
  const passed = regressions.length === 0 && criticalFailures.length === 0 && supervisorFailures.length === 0;
  if (passed && values.subset) writeReport(candidatePath, mergeAcceptedSubset(baseline, candidate));
  writeReport(output, {
    status: passed ? 'passed' : 'failed',
    tree: values.tree,
    label: values.label,
    baseline: values.baseline,
    stages: selectedStages,
    ...(values.subset ? { subset: true } : {}),
    regressions,
    criticalFailures,
    ...(supervisor.total ? { supervisor: { overall: supervisor.byAction, alwaysRequeue: supervisor.alwaysRequeue, unsafeApproves: supervisor.unsafeApproves, failures: supervisorFailures } } : {}),
    comparison: compareOutput,
  });
  if (!passed) console.error(`eval gate failed: regressions=${regressions.length} critical_failures=${criticalFailures.length} supervisor_failures=${supervisorFailures.length}`);
}

main().catch((error) => {
  const values = (() => { try { return parseArgs(process.argv.slice(2)); } catch { return {}; } })();
  if (values.output) {
    const detail = { status: 'error', label: values.label ?? '', baseline: values.baseline ?? '', stages: (values.stages ?? '').split(',').filter(Boolean), error: error.message };
    mkdirSync(dirname(resolve(values.output)), { recursive: true });
    writeFileSync(resolve(values.output), `${JSON.stringify(detail, null, 2)}\n`);
  }
  console.error(error.message);
  process.exitCode = 1;
});
