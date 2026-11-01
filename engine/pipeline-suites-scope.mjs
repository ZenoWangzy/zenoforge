import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { focusedTestPaths, RELATED_TESTS, resolveTrackedSuitePaths } from './focused-test-paths.mjs';

export const FULL_SUITE_PATHS = Object.freeze([
  '.github/workflows/ci.yml',
  '.github/workflows/pipeline-suites.yml',
  '.github/workflows/pipeline-suites-nightly.yml',
  'engine/check-rulings.sh',
  'engine/focused-test-paths.mjs',
  'engine/lesson-fragments.sh',
  'engine/lib.sh',
  'engine/pipeline-suites-scope.mjs',
  'engine/run-ci-suites.sh',
  'engine/suite-rule.jq',
  'engine/test-env.sh',
]);

export const FULL_SUITE_PATH_PREFIXES = Object.freeze([]);

export const SUITE_PATH_COVERAGE = new Map();
function addCoverage(suite, path) {
  const paths = SUITE_PATH_COVERAGE.get(suite) ?? new Set();
  paths.add(path);
  SUITE_PATH_COVERAGE.set(suite, paths);
}

for (const [path, suites] of RELATED_TESTS) {
  for (const suite of suites) addCoverage(suite, path);
}
addCoverage('engine/land-direct-main.test.sh', 'lessons/**');

function isSelectableSuitePath(path) {
  return path.endsWith('.test.sh') || path.endsWith('.test.mjs')
    || (/(^|\/)test-[^/]+\.sh$/.test(path) && !path.endsWith('/test-env.sh'));
}

function suiteCoverageFor(trackedPaths, repoRoot) {
  const tracked = trackedPaths instanceof Set ? trackedPaths : new Set(trackedPaths);
  const coverage = new Map([...SUITE_PATH_COVERAGE].map(([suite, paths]) => [suite, new Set(paths)]));
  for (const [suite, paths] of coverage) {
    for (const resolvedSuite of resolveTrackedSuitePaths([suite], tracked, repoRoot)) {
      if (resolvedSuite === suite) continue;
      const resolvedPaths = coverage.get(resolvedSuite) ?? new Set();
      for (const path of paths) resolvedPaths.add(path);
      coverage.set(resolvedSuite, resolvedPaths);
    }
  }
  for (const suite of tracked) {
    if (!isSelectableSuitePath(suite)) continue;
    const paths = coverage.get(suite) ?? new Set();
    paths.add(suite);
    const source = suite.replace(/\.test\.(sh|mjs)$/, '.$1');
    if (tracked.has(source)) paths.add(source);
    coverage.set(suite, paths);
  }
  return { tracked, coverage };
}

function coversPath(coveragePath, changedPath) {
  return coveragePath.endsWith('/**')
    ? changedPath.startsWith(coveragePath.slice(0, -2))
    : coveragePath === changedPath;
}

export function pipelineSuiteScope(changedPaths, trackedPaths, refs = {}) {
  const { tracked, coverage } = suiteCoverageFor(trackedPaths, refs.cwd ?? process.cwd());
  const selected = new Set(focusedTestPaths(changedPaths, tracked, refs));
  const full = changedPaths.length === 0 || changedPaths.some((path) => FULL_SUITE_PATHS.includes(path)
    || FULL_SUITE_PATH_PREFIXES.some((prefix) => path.startsWith(prefix)));
  for (const path of changedPaths) {
    const suites = [...coverage].filter(([suite, paths]) => tracked.has(suite)
      && [...paths].some((coveredPath) => coversPath(coveredPath, path)));
    for (const [suite] of suites) selected.add(suite);
  }

  return { full, testPaths: [...selected].sort() };
}

function gitPaths(args) {
  const output = execFileSync('git', args, { encoding: 'utf8' });
  return output.split('\0').filter(Boolean);
}

function main(base, head) {
  if (!base || !head) throw new Error('Usage: node pipeline-suites-scope.mjs <base> <head>.');
  const allChangedPaths = gitPaths([
    'diff', '--name-only', '-z', '--no-renames', '--diff-filter=ACMRTUXBD', `${base}..${head}`,
  ]);
  const trackedPaths = new Set(gitPaths(['ls-tree', '-r', '--name-only', '-z', head]));
  const refs = { baseRef: base, headRef: head, cwd: process.cwd() };
  if (allChangedPaths.some((path) => FULL_SUITE_PATHS.includes(path)
    || FULL_SUITE_PATH_PREFIXES.some((prefix) => path.startsWith(prefix)))) {
    process.stdout.write(`${JSON.stringify(pipelineSuiteScope(allChangedPaths, trackedPaths, refs))}\n`);
    return;
  }
  // Use the workflow's input boundary: unrelated product files in a mixed PR must not force all shards.
  const workflow = execFileSync('git', ['show', `${head}:.github/workflows/pipeline-suites.yml`], { encoding: 'utf8' });
  const prBlock = workflow.match(/^  pull_request:\s*\n([\s\S]*?)(?=^  [\w-]+:|^permissions:)/m)?.[1];
  const pathBlock = prBlock?.match(/^    paths:\s*\n([\s\S]*)/m)?.[1];
  if (!pathBlock) throw new Error('Pipeline workflow has no pull_request input paths.');
  const patterns = pathBlock.split(/\r?\n/).map((line) => line.trim()).filter((line) => line && !line.startsWith('#'))
    .map((line) => {
      const pattern = line.match(/^-\s*(['"])([^'"]+)\1\s*$/)?.[2];
      if (!pattern || pattern.startsWith('!')) throw new Error(`Unsupported pipeline input path: ${line}`);
      return `:(glob)${pattern}`;
    });
  if (patterns.length === 0) throw new Error('Pipeline workflow input paths are empty.');
  const changedPaths = gitPaths([
    'diff', '--name-only', '-z', '--no-renames', '--diff-filter=ACMRTUXBD', `${base}..${head}`, '--', ...patterns,
  ]);
  process.stdout.write(`${JSON.stringify(pipelineSuiteScope(changedPaths, trackedPaths, refs))}\n`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  main(...process.argv.slice(2));
}
