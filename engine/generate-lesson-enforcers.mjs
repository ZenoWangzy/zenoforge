#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
export const DEFAULT_ROOT = process.env.ZF_REPO_DIR || path.resolve(path.dirname(SCRIPT_PATH), '..');
const RULES_PATH = 'lessons/RULES.md';
const REGISTRY_PATH = `${process.env.ZF_PACK_REL || 'engine'}/state/incident-guards.json`;
const OUTPUT_PATH = 'lessons/enforcers.json';
const SOURCE_FILE = /\.(?:cjs|js|jsx|mjs|ts|tsx|py|sh|sql|ya?ml)$/i;
const TEST_FILE = /(?:^|\/)(?:tests?\/|[^/]*\.test\.[^/]+$|test_[^/]+\.py$)/i;

function compareRuleIds(left, right) {
  return Number(left.slice(1)) - Number(right.slice(1));
}

function normalizeRepoPath(root, value) {
  if (typeof value !== 'string' || value.length === 0) return null;
  const normalized = value
    .replaceAll('${REPO_DIR}/', '')
    .replaceAll('${REPO_DIR}', '')
    .replace(/^\.\//, '');
  if (path.isAbsolute(normalized)) {
    const relative = path.relative(root, normalized);
    return relative.startsWith('..') ? null : relative.split(path.sep).join('/');
  }
  return normalized;
}

function trackedSourceFiles(root) {
  const output = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  return output.split('\0').filter((file) => file && SOURCE_FILE.test(file) && !file.startsWith('lessons/'));
}

function ruleOccurrences(text) {
  return [...text.matchAll(/^(?:<a id="[^"]*"><\/a>\s*)?(?:#+\s+)?\*\*(V\d+)\*\*/gm)].map((match) => match[1]);
}

function commandText(check) {
  return Array.isArray(check.command) ? check.command.join(' ') : '';
}

function isExistenceOnly(check) {
  const command = commandText(check).trim();
  const shellBody = command.replace(/^bash\s+-c\s+/, '').replace(/^node\s+-e\s+/, '');
  return /^(?:test\s+-[fe]\s+[^;&]+|(?:git\s+)?grep\s+-[^\s]*q[^\s]*\s+[^;&]+)(?:\s*&&\s*echo\s+[^;&]+)?$/.test(shellBody);
}

function commandPaths(root, check) {
  const result = new Set();
  if (isExistenceOnly(check)) return [];
  const explicitTestFile = normalizeRepoPath(root, check.test_file);
  if (explicitTestFile && existsSync(path.join(root, explicitTestFile))) result.add(explicitTestFile);

  const args = Array.isArray(check.command) ? check.command : [];
  const discoverIndex = args.indexOf('discover');
  if (args[discoverIndex - 1] === 'unittest' && discoverIndex !== -1) {
    const startDir = normalizeRepoPath(root, args[args.indexOf('-s', discoverIndex) + 1]);
    const pattern = args[args.indexOf('-p', discoverIndex) + 1];
    if (startDir && pattern) {
      const candidate = `${startDir}/${pattern}`;
      if (TEST_FILE.test(candidate) && existsSync(path.join(root, candidate))) result.add(candidate);
    }
  }

  const command = commandText(check);
  for (const match of command.matchAll(/(?:\$\{REPO_DIR\}\/)?((?:scripts|packages|infra|src|tests?|\.[A-Za-z0-9._-]+)\/[A-Za-z0-9._@/-]+)/g)) {
    const candidate = normalizeRepoPath(root, match[0]);
    if (candidate && TEST_FILE.test(candidate) && existsSync(path.join(root, candidate))) result.add(candidate);
  }

  return [...result];
}

function emptyRule() {
  return { source_refs: new Set(), enforcers: new Set(), test_paths: new Set(), incident_refs: new Set(), checks: [] };
}

function countClassifications(rules) {
  const counts = { enforced: 0, weak: 0, 'existence-check': 0, prose: 0 };
  for (const rule of Object.values(rules)) counts[rule.classification] += 1;
  return counts;
}

export function buildLessonEnforcers(root = DEFAULT_ROOT) {
  const absoluteRoot = path.resolve(root);
  const ruleText = readFileSync(path.join(absoluteRoot, RULES_PATH), 'utf8');
  const occurrences = ruleOccurrences(ruleText);
  const ids = [...new Set(occurrences)].sort(compareRuleIds);
  const state = new Map(ids.map((id) => [id, emptyRule()]));

  for (const file of trackedSourceFiles(absoluteRoot)) {
    const contents = readFileSync(path.join(absoluteRoot, file), 'utf8');
    if (contents.includes('\0')) continue;
    for (const match of contents.matchAll(/\bV\d+\b/g)) {
      const rule = state.get(match[0]);
      if (!rule) continue;
      rule.source_refs.add(file);
    }
  }

  const registry = JSON.parse(readFileSync(path.join(absoluteRoot, REGISTRY_PATH), 'utf8'));
  for (const incident of registry.incidents ?? []) {
    const rule = state.get(incident.lesson_id);
    if (!rule) continue;
    rule.incident_refs.add(incident.id);
    for (const enforcer of incident.enforcement?.enforced_by ?? []) {
      const candidate = normalizeRepoPath(absoluteRoot, enforcer);
      if (!candidate || !existsSync(path.join(absoluteRoot, candidate))) continue;
      rule.enforcers.add(candidate);
      if (TEST_FILE.test(candidate)) rule.test_paths.add(candidate);
    }
    for (const check of incident.machine_checks ?? []) {
      rule.checks.push(check);
      for (const enforcer of commandPaths(absoluteRoot, check)) {
        rule.enforcers.add(enforcer);
        if (TEST_FILE.test(enforcer)) rule.test_paths.add(enforcer);
      }
    }
  }

  const rules = Object.fromEntries(ids.map((id) => {
    const item = state.get(id);
    const hasBehavioralTest = item.test_paths.size > 0;
    const hasOnlyExistenceChecks = item.checks.length > 0
      && item.checks.every(isExistenceOnly)
      && item.test_paths.size === 0;
    const hasEnforcer = item.enforcers.size > 0;
    const hasSourceReference = item.source_refs.size > 0;
    const classification = hasBehavioralTest
      ? 'enforced'
      : hasOnlyExistenceChecks
        ? 'existence-check'
        : hasEnforcer || hasSourceReference || item.checks.length > 0
          ? 'weak'
          : 'prose';
    return [id, {
      classification,
      enforcer: hasEnforcer ? [...item.enforcers].sort() : 'prose',
      source_refs: [...item.source_refs].sort(),
      incident_refs: [...item.incident_refs].sort(),
    }];
  }));

  const duplicateRuleIds = Object.fromEntries(
    [...new Set(occurrences.filter((id, index) => occurrences.indexOf(id) !== index))]
      .sort(compareRuleIds)
      .map((id) => [id, occurrences.filter((candidate) => candidate === id).length]),
  );

  return {
    version: 1,
    generated_by: 'engine/generate-lesson-enforcers.mjs',
    generated_from: [RULES_PATH, REGISTRY_PATH, 'tracked code and test files containing V-IDs'],
    rule_entries: occurrences.length,
    unique_rule_ids: ids.length,
    duplicate_rule_ids: duplicateRuleIds,
    classification_legend: {
      enforced: 'A machine check or enforcement.enforced_by entry resolves to an existing test path.',
      weak: 'A source/test reference, machine check, or guard script is linked, but no test path is linked.',
      'existence-check': 'Every linked machine check only checks that a file or string is present, and no test path is linked.',
      prose: 'No tracked code/test reference or incident guard is linked.',
    },
    counts: countClassifications(rules),
    rules,
  };
}

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    const value = argv[index + 1];
    if (!value) throw new Error(`missing value for ${token}`);
    if (token === '--root') args.root = value;
    else if (token === '--output') args.output = value;
    else throw new Error(`unknown argument: ${token}`);
    index += 1;
  }
  return args;
}

export function runCli(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const root = path.resolve(args.root ?? DEFAULT_ROOT);
  const outputPath = path.resolve(root, args.output ?? OUTPUT_PATH);
  const map = buildLessonEnforcers(root);
  writeFileSync(outputPath, `${JSON.stringify(map, null, 2)}\n`);
  process.stdout.write(`${path.relative(root, outputPath)}: ${JSON.stringify(map.counts)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === SCRIPT_PATH) {
  try {
    runCli();
  } catch (error) {
    process.stderr.write(`ERROR generate-lesson-enforcers: ${error.message}\n`);
    process.exitCode = 1;
  }
}
