import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { lessonLintRegistry } from '../lesson-lints.mjs';

const REVIEW_SKIP_MAX_CHANGED_LINES = 80;
const REGISTRY_PATH = '.zenoforge/state/escape-suites.json';
const RULES_PATH = 'engine/state/rule-files.json';
const REVIEW_VERDICT_STAGES = new Set(['review-approve', 'review-request-changes', 'review-block']);
const CONTROL_PATHS = [
  REGISTRY_PATH,
  '.zenoforge/state/review-skip-invalidations.json',
  'engine/state/rule-files.json',
  'engine/state/scheduling-policy.json',
  'engine/mac-autopilot/risk-tiered-review.mjs',
  'engine/mac-autopilot/scheduler.d/risk-tiered-review.sh',
  'engine/mac-autopilot/scheduler.d/escape-suite-runner.mjs',
  'engine/mac-autopilot/scheduler.d/dispatch-queue.sh',
  'engine/mac-autopilot/scheduler.d/self-check.sh',
  'engine/mac-autopilot/scheduler.d/merge-lane.sh',
  'engine/mac-autopilot/scheduler.d/pr-body.sh',
  'engine/lesson-lints.mjs',
  'lessons/recurrence-ranking.json',
];

function packagesForPath(file, packages) {
  return Object.keys(packages)
    .filter((packagePath) => file === packagePath || file.startsWith(packagePath + '/'))
    .sort((left, right) => right.length - left.length);
}

export function assessReviewSkip({
  paths,
  changedLines,
  escapePackages,
  lintScopes,
  escapeResults,
  lessonLintRc,
  selfCheckStatus,
  selfCheckSha,
  headSha,
  invalidations = [],
  protectedPaths = [],
}) {
  const changed = [...new Set(paths)].sort();
  if (!changed.length || !Number.isInteger(changedLines) || changedLines < 0 || changedLines > REVIEW_SKIP_MAX_CHANGED_LINES) {
    return { eligible: false, reason: 'diff-size' };
  }
  if (changed.some((file) => protectedPaths.some((protectedPath) => file === protectedPath
    || (protectedPath.endsWith('/') && file.startsWith(protectedPath))))) {
    return { eligible: false, reason: 'protected-path' };
  }
  if (selfCheckStatus !== 'pass' || !headSha || selfCheckSha !== headSha || lessonLintRc !== 0) {
    return { eligible: false, reason: 'checks-not-green-on-head' };
  }

  const checks = new Map();
  for (const file of changed) {
    const lints = (lintScopes[file] ?? []).filter((lint) => lint.mode === 'enforce');
    const packagePaths = packagesForPath(file, escapePackages);
    if (!packagePaths.length || !lints.length) return { eligible: false, reason: 'uncovered:' + file };
    for (const packagePath of packagePaths) {
      const tests = escapePackages[packagePath] ?? [];
      if (!tests.length) return { eligible: false, reason: 'uncovered:' + file };
      const invalidation = invalidations.find((row) => row.path === file && row.packagePath === packagePath);
      if (invalidation && !tests.some((entry) => !invalidation.tests.includes(entry.test))) {
        return { eligible: false, reason: 'escape-test-required:' + file };
      }
      for (const entry of tests) {
        const result = escapeResults.find((row) => row.packagePath === packagePath && row.test === entry.test);
        if (!result || result.rc !== 0) return { eligible: false, reason: 'escape-suite-red:' + entry.test };
        checks.set('escape-suite:' + packagePath + ':' + entry.test, {
          kind: 'escape-suite',
          name: packagePath + ':' + entry.test,
          rc: result.rc,
        });
      }
    }
    for (const lint of lints) {
      checks.set('lesson-lint:' + lint.name, { kind: 'lesson-lint', name: lint.name, rc: 0 });
    }
  }
  return { eligible: true, changedLines, paths: changed, checks: [...checks.values()].sort((left, right) => left.name.localeCompare(right.name)) };
}

export function recordEscapeInvalidations(paths, basePackages, headPackages) {
  const invalidations = [];
  for (const file of [...new Set(paths)].sort()) {
    for (const packagePath of packagesForPath(file, headPackages)) {
      const tests = headPackages[packagePath] ?? [];
      const before = new Set((basePackages[packagePath] ?? []).map((entry) => entry.test));
      if (tests.length && !tests.some((entry) => !before.has(entry.test))) {
        invalidations.push({ path: file, packagePath, tests: tests.map((entry) => entry.test).sort() });
      }
    }
  }
  return invalidations;
}

export function recordEscapedPaths(paths, packages) {
  return [...new Set(paths)].sort().flatMap((file) => packagesForPath(file, packages)
    .filter((packagePath) => (packages[packagePath] ?? []).length)
    .map((packagePath) => ({ path: file, packagePath })));
}

export function riskTieredReviewStats(units, now = Date.now()) {
  const cutoff = now - 7 * 86400000;
  let maturedMergedUnits = 0;
  let skippedUnits = 0;
  let escapedSkippedUnits = 0;
  for (const unit of units) {
    const history = unit.history ?? [];
    const merged = [...history].reverse().find((event) => event.stage === 'merged');
    const mergedAt = Date.parse(merged?.at ?? '');
    if (!Number.isFinite(mergedAt) || mergedAt > cutoff) continue;
    maturedMergedUnits += 1;
    const skip = [...history].reverse().find((event) => event.stage === 'review-skip'
      && event.result === unit.approved_sha && Date.parse(event.at ?? '') <= mergedAt);
    if (!skip || history.some((event) => REVIEW_VERDICT_STAGES.has(event.stage)
      && event.result === unit.approved_sha && Date.parse(event.at ?? '') <= mergedAt)) continue;
    skippedUnits += 1;
    const skipPaths = new Set(skip.paths ?? []);
    const escaped = history.some((event) => event.stage === 'review-skip-escape'
      && Date.parse(event.at ?? '') >= mergedAt && Date.parse(event.at ?? '') <= mergedAt + 7 * 86400000
      && (event.paths ?? []).some((file) => skipPaths.has(file)));
    if (escaped) escapedSkippedUnits += 1;
  }
  return {
    maturedMergedUnits,
    skippedUnits,
    escapedSkippedUnits,
    skipShare: maturedMergedUnits ? skippedUnits / maturedMergedUnits : null,
    escapeShare: skippedUnits ? escapedSkippedUnits / skippedUnits : null,
  };
}

export function mergeUnitSnapshots(...snapshots) {
  const units = new Map();
  for (const snapshot of snapshots) {
    for (const unit of snapshot?.units ?? []) {
      if (unit && typeof unit.id === 'string') units.set(unit.id, unit);
    }
  }
  return [...units.values()];
}

export function countChangedLines(numstat) {
  let total = 0;
  for (const row of numstat.split(/\r?\n/).filter(Boolean)) {
    const [added, removed] = row.split('\t');
    if (!/^\d+$/.test(added) || !/^\d+$/.test(removed)) return null;
    total += Number(added) + Number(removed);
  }
  return total;
}

function git(repo, args) {
  return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
}

function readJsonAt(repo, revision, file) {
  try {
    return JSON.parse(git(repo, ['show', `${revision}:${file}`]));
  } catch {
    return null;
  }
}

function packageEntries(registry) {
  if (!registry || registry.version !== 1 || !registry.packages || typeof registry.packages !== 'object') return {};
  return Object.fromEntries(Object.entries(registry.packages)
    .filter(([, entries]) => Array.isArray(entries))
    .map(([packagePath, entries]) => [packagePath, entries.filter((entry) => entry && typeof entry.test === 'string'
      && Array.isArray(entry.command))]));
}

function mergedPackages(repo, base, head) {
  const packages = new Map();
  for (const revision of [base, head]) {
    const source = packageEntries(readJsonAt(repo, revision, REGISTRY_PATH));
    for (const [packagePath, entries] of Object.entries(source)) {
      if (!packages.has(packagePath)) packages.set(packagePath, new Map());
      for (const entry of entries) packages.get(packagePath).set(entry.test, entry);
    }
  }
  return Object.fromEntries([...packages].map(([packagePath, entries]) => [packagePath, [...entries.values()]]));
}

function pathScopes(lint) {
  return lint.gate ?? Object.keys(lint.files ?? {});
}

export function lintScopesForPath(file, registry = lessonLintRegistry) {
  return registry.filter((lint) => {
    if ((lint.mode ?? 'observe') !== 'enforce') return false;
    if (pathScopes(lint).includes(file)) return true;
    if (lint.classTag === 'exact-second-elapsed-grep') return file.endsWith('.test.sh');
    if (lint.classTag === 'symlink-blind-entry-check') return /\.m?js$/.test(file) && !/\.test\.m?js$/.test(file);
    if (lint.classTag === 'local-tz-z-stamp') return file.endsWith('.sh');
    return false;
  }).map((lint) => ({ name: `${lint.lesson ? `${lint.lesson}/` : ''}${lint.classTag}`, mode: 'enforce' }));
}

function changedPaths(repo, base, head) {
  return git(repo, ['diff', '--no-renames', '--name-only', '-z', base, head]).split('\0').filter(Boolean);
}

function changedLines(repo, base, head) {
  return countChangedLines(git(repo, ['diff', '--no-renames', '--numstat', base, head]));
}

function protectedPaths(repo, base, head) {
  const packRel = process.env.ZF_PACK_REL || 'engine';
  const rulesPath = `${packRel}/state/rule-files.json`;
  const files = new Set(CONTROL_PATHS);
  files.add(rulesPath);
  for (const file of CONTROL_PATHS) {
    if (file.startsWith('engine/')) files.add(`${packRel}/${file.slice('engine/'.length)}`);
  }
  for (const revision of [base, head]) {
    const registry = readJsonAt(repo, revision, rulesPath);
    if (!registry?.files || typeof registry.files !== 'object') return null;
    for (const file of Object.keys(registry.files)) {
      files.add(file);
      if (file.startsWith('engine/')) files.add(`${packRel}/${file.slice('engine/'.length)}`);
    }
  }
  return [...files];
}

function checkLog(text) {
  const escapeResults = [];
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^escape-suite: package=(.*?) test=(.*?) rc=(\d+)(?:\s|$)/);
    if (match) escapeResults.push({ packagePath: match[1], test: match[2], rc: Number(match[3]) });
  }
  const lessonMatch = text.match(/^risk-review-check: lesson-lints rc=(\d+)$/m);
  return { escapeResults, lessonLintRc: lessonMatch ? Number(lessonMatch[1]) : null };
}

function readInvalidations(file) {
  if (!file || !existsSync(file)) return [];
  const parsed = JSON.parse(readFileSync(file, 'utf8'));
  if (!Array.isArray(parsed)) throw new Error('invalid review-skip invalidations');
  return parsed;
}

export function evaluateReviewSkip({ repo, base, head, checkOutput, selfCheckStatus, selfCheckSha, invalidationsFile }) {
  const paths = changedPaths(repo, base, head);
  const checks = checkLog(checkOutput);
  const protectedList = protectedPaths(repo, base, head);
  if (!protectedList) return { eligible: false, reason: 'protected-path-registry-unavailable' };
  const lintScopes = Object.fromEntries(paths.map((file) => [file, lintScopesForPath(file)]));
  return assessReviewSkip({
    paths,
    changedLines: changedLines(repo, base, head),
    escapePackages: mergedPackages(repo, base, head),
    lintScopes,
    escapeResults: checks.escapeResults,
    lessonLintRc: checks.lessonLintRc,
    selfCheckStatus,
    selfCheckSha,
    headSha: head,
    invalidations: readInvalidations(invalidationsFile),
    protectedPaths: protectedList,
  });
}

export function recordEscapeInvalidationsAt(repo, base, head, invalidationsFile) {
  const basePackages = packageEntries(readJsonAt(repo, base, REGISTRY_PATH));
  const headPackages = mergedPackages(repo, base, head);
  const entries = recordEscapeInvalidations(changedPaths(repo, base, head), basePackages, headPackages);
  if (entries.length) {
    const prior = readInvalidations(invalidationsFile);
    const byPath = new Map(prior.map((entry) => [entry.path + '\0' + entry.packagePath, entry]));
    for (const entry of entries) byPath.set(entry.path + '\0' + entry.packagePath, entry);
    mkdirSync(path.dirname(invalidationsFile), { recursive: true });
    const temporary = `${invalidationsFile}.${process.pid}.tmp`;
    writeFileSync(temporary, `${JSON.stringify([...byPath.values()])}\n`);
    renameSync(temporary, invalidationsFile);
  }
  return {
    paths: recordEscapedPaths(changedPaths(repo, base, head), headPackages),
    invalidations: entries,
  };
}

function percentage(value) {
  return value == null ? '无数据' : `${Math.round(value * 100)}%`;
}

export function formatRiskTieredReviewStats(stats) {
  return `近7日已成熟合并单元：${stats.maturedMergedUnits}；跳过评审：${stats.skippedUnits}（${percentage(stats.skipShare)}）；其中后续7日逃逸：${stats.escapedSkippedUnits}（${percentage(stats.escapeShare)}）。`;
}

function parseArgs(args) {
  const options = { mode: 'decision', repo: process.cwd(), base: '', head: 'HEAD', checkOutput: '', status: '', selfCheckSha: '', invalidationsFile: '', units: '', archive: '' };
  for (let index = 0; index < args.length; index += 1) {
    const key = args[index];
    if (['--decision', '--record-escape', '--report'].includes(key)) options.mode = key.slice(2);
    else if (['--repo', '--base', '--head', '--check-output', '--status', '--self-check-sha', '--invalidations', '--units', '--archive'].includes(key)) {
      const value = args[index + 1];
      if (!value) throw new Error(`${key} requires a value`);
      const names = { 'check-output': 'checkOutput', 'self-check-sha': 'selfCheckSha', invalidations: 'invalidationsFile' };
      options[names[key.slice(2)] ?? key.slice(2)] = value;
      index += 1;
    } else throw new Error(`unknown argument: ${key}`);
  }
  return options;
}

if (process.argv[1] && existsSync(process.argv[1])
  && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.mode === 'decision') {
      const output = readFileSync(options.checkOutput, 'utf8');
      console.log(JSON.stringify(evaluateReviewSkip({
        repo: options.repo,
        base: options.base,
        head: options.head,
        checkOutput: output,
        selfCheckStatus: options.status,
        selfCheckSha: options.selfCheckSha,
        invalidationsFile: options.invalidationsFile,
      })));
    } else if (options.mode === 'record-escape') {
      console.log(JSON.stringify(recordEscapeInvalidationsAt(options.repo, options.base, options.head, options.invalidationsFile)));
    } else {
      const snapshots = [options.archive, options.units].filter((file) => file && existsSync(file))
        .map((file) => JSON.parse(readFileSync(file, 'utf8')));
      const units = mergeUnitSnapshots(...snapshots);
      console.log(formatRiskTieredReviewStats(riskTieredReviewStats(units)));
    }
  } catch (error) {
    console.error(`risk-tiered-review: ${String(error?.message ?? error).replace(/[\r\n]+/g, ' ')}`);
    process.exitCode = 1;
  }
}
