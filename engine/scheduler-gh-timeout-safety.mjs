#!/usr/bin/env node
import { realpathSync } from 'node:fs';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..');
const SOURCE_ROOTS = [
  path.join(SCRIPT_DIR, 'lib.sh'),
  path.join(SCRIPT_DIR, 'lib.d'),
  path.join(SCRIPT_DIR, 'mac-autopilot', 'scheduler.sh'),
  path.join(SCRIPT_DIR, 'mac-autopilot', 'scheduler.d'),
];
const DIRECT_GH = /(?:^\s*|[;&|({]\s*|\b(?:if|then|do|else)\s+!?[ \t]*)command[ \t]+gh(?=[ \t]|$)/;

function shellFiles(root) {
  if (!existsSync(root)) return [];
  const found = [];
  const pending = [root];
  while (pending.length) {
    const directory = pending.pop();
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) pending.push(absolute);
      else if (entry.isFile() && entry.name.endsWith('.sh') && !entry.name.endsWith('.test.sh')) found.push(absolute);
    }
  }
  return found;
}

export function findDirectGhCalls(files, repoRoot = REPO_ROOT) {
  const violations = [];
  for (const file of files) {
    let source;
    try {
      source = readFileSync(file, 'utf8');
    } catch (error) {
      violations.push(`${path.relative(repoRoot, file)}: cannot read: ${error.message}`);
      continue;
    }
    source.split(/\r?\n/).forEach((line, index) => {
      if (line.trimStart().startsWith('#')) return;
      if (DIRECT_GH.test(line)) {
        violations.push(`${path.relative(repoRoot, file)}:${index + 1}: command gh bypasses the timed wrapper`);
      }
    });
  }
  return violations;
}

function main(args) {
  const files = args.length
    ? args.map((file) => path.resolve(file))
    : SOURCE_ROOTS.flatMap((root) => (root.endsWith('.sh')
      ? existsSync(root) ? [root] : []
      : shellFiles(root)));
  const violations = findDirectGhCalls(files);
  if (violations.length) {
    for (const violation of violations) console.error(`scheduler-gh-timeout-safety: ${violation}`);
    console.error(`scheduler-gh-timeout-safety: ${violations.length} unbounded direct gh call(s) in ${files.length} scheduler/lib shell file(s)`);
    process.exitCode = 1;
    return;
  }
  console.log(`scheduler-gh-timeout-safety: no direct command gh calls in ${files.length} scheduler/lib shell file(s)`);
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  main(process.argv.slice(2));
}
