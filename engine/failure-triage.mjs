#!/usr/bin/env node
// Verdict for a genuine CI failure: stale-base, attributable (to the PR) or unknown.
// Reuses the affected-only lane's suite mapping (pipeline-suites-scope.mjs); it adds no path list of its own.
// Input (JSON file or stdin): { suites: [failing suite paths], prFiles: [PR-owned changed paths since the merge base],
//   mainFiles: [paths main changed since that merge base], behind: <commits PR is behind main>, complete: <both lists untruncated> }
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { CROSS_SCRIPT_TESTS } from './focused-test-paths.mjs';
import { FULL_SUITE_PATHS, SUITE_PATH_COVERAGE } from './pipeline-suites-scope.mjs';

const RANK = { 'stale-base': 0, unknown: 1, attributable: 2 };

const covers = (coverage, path) => (coverage.endsWith('/**') ? path.startsWith(coverage.slice(0, -2)) : coverage === path);

// Can any of these changed paths affect the suite? Same rules as pipelineSuiteScope, asked for one suite.
// No import closure is inferred: a path no rule maps to the suite does not count.
export function affects(paths, suite) {
  const source = suite.replace(/\.test\.(sh|mjs)$/, '.$1');
  const coverage = SUITE_PATH_COVERAGE.get(suite) ?? new Set();
  return paths.some((p) => FULL_SUITE_PATHS.includes(p) || p === suite || p === source
    || [...coverage].some((c) => covers(c, p))
    || (p.startsWith('engine/') && /\.(?:sh|mjs)$/.test(p) && CROSS_SCRIPT_TESTS.includes(suite)));
}

function suiteVerdict(suite, { prFiles, mainFiles, behind }) {
  if (affects(prFiles, suite)) return 'attributable';
  return behind > 0 && affects(mainFiles, suite) ? 'stale-base' : 'unknown';
}

export function triage(facts) {
  const { suites = [], prFiles = [], mainFiles = [], behind = 0, complete = false } = facts;
  if (!complete || suites.length === 0) return 'unknown';
  // Package Vitest jobs (and anything outside the engine suites the mapping covers) are never classified.
  if (!suites.every((s) => s.startsWith('engine/'))) return 'unknown';
  let worst = 'stale-base';
  for (const suite of suites) {
    const v = suiteVerdict(suite, { prFiles, mainFiles, behind });
    if (RANK[v] > RANK[worst]) worst = v;
  }
  return worst;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  process.stdout.write(`${triage(JSON.parse(readFileSync(process.argv[2] ?? 0, 'utf8')))}\n`);
}
