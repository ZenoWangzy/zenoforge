import { execFileSync, spawnSync } from 'node:child_process';
import path from 'node:path';

export const ESCAPE_SUITE_REGISTRY = '.zenoforge/state/escape-suites.json';

function fail(message) {
  throw new Error(message);
}

function relativeRepoPath(value, label) {
  if (typeof value !== 'string' || value.length === 0 || value.includes('\0') || value.includes('\\') || value.startsWith('/')) {
    fail(`${label} must be a relative repository path`);
  }
  const parts = value.split('/');
  if (parts.some((part) => part.length === 0 || part === '.' || part === '..') || path.posix.normalize(value) !== value) {
    fail(`${label} must be a normalized repository path`);
  }
  return value;
}

function git(cwd, args, options = {}) {
  return execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8', ...options });
}

function readRegistry(cwd, commit) {
  try {
    git(cwd, ['cat-file', '-e', `${commit}:${ESCAPE_SUITE_REGISTRY}`], { stdio: 'ignore' });
  } catch {
    return null;
  }
  return JSON.parse(git(cwd, ['show', `${commit}:${ESCAPE_SUITE_REGISTRY}`]));
}

function validateRegistry(registry, label) {
  if (!registry || typeof registry !== 'object' || Array.isArray(registry) || registry.version !== 1
      || !registry.packages || typeof registry.packages !== 'object' || Array.isArray(registry.packages)) {
    fail(`${label} must have version 1 and a packages object`);
  }
  const packages = new Map();
  for (const [rawPackagePath, entries] of Object.entries(registry.packages)) {
    const packagePath = relativeRepoPath(rawPackagePath, 'package path');
    if (!Array.isArray(entries)) fail(`escape tests for ${packagePath} must be an array`);
    const tests = new Map();
    for (const entry of entries) {
      if (!entry || typeof entry !== 'object' || Array.isArray(entry)) fail(`escape test for ${packagePath} must be an object`);
      const test = relativeRepoPath(entry.test, `test path for ${packagePath}`);
      if (!test.startsWith(`${packagePath}/`)) fail(`test ${test} must be inside package ${packagePath}`);
      if (!Array.isArray(entry.command) || entry.command.length === 0
          || entry.command.some((arg) => typeof arg !== 'string' || arg.length === 0 || arg.includes('\0'))) {
        fail(`command for ${test} must be a non-empty string array`);
      }
      tests.set(test, { test, command: entry.command });
    }
    packages.set(packagePath, tests);
  }
  return packages;
}

function mergedRegistry(cwd, base, head) {
  const merged = new Map();
  for (const [commit, label] of [[base, 'base registry'], [head, 'head registry']]) {
    const registry = readRegistry(cwd, commit);
    if (!registry) continue;
    for (const [packagePath, tests] of validateRegistry(registry, label)) {
      if (!merged.has(packagePath)) merged.set(packagePath, new Map());
      for (const [test, entry] of tests) merged.get(packagePath).set(test, entry);
    }
  }
  return merged;
}

function touchedPackages(cwd, base, head, packagePaths) {
  const changed = git(cwd, ['diff', '--no-renames', '--name-only', '-z', base, head]).split('\0').filter(Boolean);
  const touched = new Set();
  for (const file of changed) {
    const parts = file.split('/');
    let prefix = '';
    for (const part of parts) {
      prefix = prefix ? `${prefix}/${part}` : part;
      if (packagePaths.has(prefix)) touched.add(prefix);
    }
  }
  return touched;
}

function testExistsAtHead(cwd, head, test) {
  try {
    return git(cwd, ['cat-file', '-t', `${head}:${test}`]).trim() === 'blob';
  } catch {
    return false;
  }
}

export function runEscapeSuites({
  cwd = process.cwd(),
  base,
  head,
  timeoutSeconds = 900,
  run = spawnSync,
  log = console.log,
} = {}) {
  try {
    if (![base, head].every((sha) => typeof sha === 'string' && /^[0-9a-f]{40,64}$/.test(sha))) {
      fail('base and head must be commit ids');
    }
    const registry = mergedRegistry(cwd, base, head);
    const touched = touchedPackages(cwd, base, head, new Set(registry.keys()));
    const tests = [...touched].flatMap((packagePath) => [...registry.get(packagePath).values()].map((entry) => ({ packagePath, ...entry })));
    if (tests.length === 0) {
      log(`escape-suite: no registered tests matched touched packages registry=${ESCAPE_SUITE_REGISTRY} rc=0`);
      return 0;
    }

    let overallRc = 0;
    for (const { packagePath, test, command } of tests) {
      if (!testExistsAtHead(cwd, head, test)) {
        log(`escape-suite: package=${packagePath} test=${test} rc=1 reason=missing-at-head`);
        overallRc = 1;
        continue;
      }
      const result = run(command[0], command.slice(1), {
        cwd,
        timeout: Math.max(1, Number(timeoutSeconds) || 900) * 1000,
        stdio: 'inherit',
      });
      const rc = result.status ?? (result.error?.code === 'ETIMEDOUT' ? 124 : 127);
      log(`escape-suite: package=${packagePath} test=${test} rc=${rc} command=${JSON.stringify(command)}`);
      if (rc !== 0) overallRc = 1;
    }
    return overallRc;
  } catch (error) {
    log(`escape-suite: registry=${ESCAPE_SUITE_REGISTRY} rc=1 reason=${String(error?.message ?? error).replace(/[\r\n]+/g, ' ')}`);
    return 1;
  }
}

if (process.env.ZF_ESCAPE_SUITE_RUNNER === '1') {
  process.exitCode = runEscapeSuites({
    base: process.env.ZF_ESCAPE_SUITE_BASE,
    head: process.env.ZF_ESCAPE_SUITE_HEAD,
    timeoutSeconds: process.env.ZF_ESCAPE_SUITE_TIMEOUT_S,
  });
}
