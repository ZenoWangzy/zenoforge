#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { missingSourceCommentTools, sourceCommentKind, sourceComments } from './source-comments.mjs';

process.chdir(join(fileURLToPath(import.meta.url), '..', '..'));
const baselinePath = 'tools/suppression-baseline.txt';
const exceptionsPath = 'tools/suppression-exceptions.json';
const directiveHint = /shellcheck\s+disable|@ts-expect-error|@ts-ignore|eslint-disable|noqa|type:\s*ignore/i;
const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 1 << 30 });
const argv = process.argv.slice(2);
const changedAt = argv.indexOf('--changed');
const tighten = argv.length === 1 && argv[0] === '--tighten';
if (argv.length && !tighten && !(changedAt === 0 && argv.length === 2)) {
  console.error('usage: node tools/suppression-ratchet.mjs [--tighten | --changed <ref>]');
  process.exit(2);
}

function readBaseline(text) {
  const rows = new Map();
  for (const [index, line] of text.split('\n').entries()) {
    if (!line || line.startsWith('#')) continue;
    const [rawCount, file, directive, ...extra] = line.split('\t');
    const count = Number(rawCount);
    if (!Number.isSafeInteger(count) || count < 1 || !file || !directive || extra.length) throw new Error(`${baselinePath}:${index + 1} is malformed`);
    const key = signature(file, directive);
    if (rows.has(key)) throw new Error(`${baselinePath}:${index + 1} duplicates ${file} ${directive}`);
    rows.set(key, { file, directive, count });
  }
  return rows;
}

function signature(file, directive) {
  return `${file}\0${directive}`;
}

function readExceptions() {
  const entries = JSON.parse(readFileSync(exceptionsPath, 'utf8'));
  if (!Array.isArray(entries)) throw new Error(`${exceptionsPath} must contain an array`);
  for (const [index, entry] of entries.entries()) {
    if (!entry || typeof entry !== 'object' || typeof entry.file !== 'string' || !Number.isSafeInteger(entry.line) || entry.line < 1 || typeof entry.directive !== 'string' || !entry.directive) {
      throw new Error(`${exceptionsPath} exception ${index + 1} must name a file, line and directive`);
    }
    if (typeof entry.adr !== 'string' || !/^docs\/adr\/\d{4}-[a-z0-9-]+\.md$/.test(entry.adr)) {
      throw new Error(`${exceptionsPath} exception ${index + 1} must name an ADR under docs/adr/`);
    }
    if (!existsSync(entry.adr)) throw new Error(`${exceptionsPath} exception ${index + 1} ADR does not exist: ${entry.adr}`);
    const adr = readFileSync(entry.adr, 'utf8');
    if (!adr.includes('<!-- adr-header v1 -->') || !/^> \*\*Decision:\*\*/m.test(adr)) {
      throw new Error(`${exceptionsPath} exception ${index + 1} does not reference a valid ADR: ${entry.adr}`);
    }
  }
  return entries;
}

function directiveIn(comment) {
  const body = comment.replace(/^\/\/|^\/\*|\*\/$/g, '').replace(/^#/, '').trim();
  const patterns = [
    /^shellcheck\s+disable(?:\s*=\s*\S+)?/,
    /^@ts-expect-error\b/,
    /^@ts-ignore\b/,
    /^eslint-disable(?:-(?:next-line|line))?(?:\s*:\s*.+|\s+[^*]+)?/,
    /^noqa(?:\s*:\s*.+)?/,
    /^type:\s*ignore(?:\s*\[[^\]]+\])?/,
  ];
  const match = patterns.map((pattern) => body.match(pattern)).find(Boolean);
  return match?.[0].trim().replace(/\s+/g, ' ');
}

function trackedSourceFiles() {
  return git('ls-files', '--cached', '--others', '--exclude-standard', 'engine', 'tools', 'cli').split('\n')
    .filter((path) => sourceCommentKind(path) && !path.includes('node_modules/') && existsSync(path));
}

function changedPaths(ref) {
  const base = git('merge-base', ref, 'HEAD').trim();
  return new Set(git('diff', '--name-only', base, 'HEAD').split('\n').filter(Boolean));
}

function parseDirectiveLine(path, text) {
  const kind = sourceCommentKind(path);
  return sourceComments(kind, text).flatMap(({ line, text: comment }) => {
    const directive = directiveIn(comment);
    return directive ? [{ file: path, line, directive }] : [];
  });
}

function currentDirectives(paths, exceptions) {
  const exceptionFiles = new Set(exceptions.map((entry) => entry.file));
  const files = new Set([...paths, ...exceptionFiles]);
  const candidates = new Map();
  for (const path of files) {
    if (!sourceCommentKind(path) || !existsSync(path)) continue;
    const text = readFileSync(path, 'utf8');
    if (exceptionFiles.has(path) || directiveHint.test(text)) candidates.set(path, text);
  }
  const kindSet = new Set([...candidates.keys()].map(sourceCommentKind).filter(Boolean));
  const missing = missingSourceCommentTools(kindSet);
  if (missing.length) {
    const help = {
      shfmt: 'shfmt is not installed (needed for shell sources)',
      typescript: 'typescript is not installed (needed for JavaScript and TypeScript sources)',
      python3: 'python3 is not installed (needed for Python sources)',
    };
    for (const tool of missing) console.error(`suppression-ratchet: ${help[tool] ?? `${tool} is not installed`}`);
    process.exit(2);
  }
  const found = [];
  for (const [path, text] of candidates) found.push(...parseDirectiveLine(path, text));
  return found;
}

function validatedExceptions(entries, directives) {
  const actual = new Set(directives.map((entry) => `${entry.file}\0${entry.line}\0${entry.directive}`));
  const seen = new Set();
  let fail = false;
  for (const [index, entry] of entries.entries()) {
    const key = `${entry.file}\0${entry.line}\0${entry.directive}`;
    if (seen.has(key)) {
      console.error(`FAIL ${exceptionsPath} exception ${index + 1} duplicates ${entry.file}:${entry.line}`);
      fail = true;
    } else if (!actual.has(key)) {
      console.error(`FAIL ${exceptionsPath} exception ${index + 1} does not match a suppression directive at ${entry.file}:${entry.line}`);
      fail = true;
    }
    seen.add(key);
  }
  return { keys: seen, fail };
}

function compareBaselineToRef(ref, baseline) {
  try {
    execFileSync('git', ['cat-file', '-e', `${ref}:${baselinePath}`], { stdio: 'ignore' });
  } catch {
    return null;
  }
  const previous = readBaseline(git('show', `${ref}:${baselinePath}`));
  let fail = false;
  for (const [key, row] of baseline) {
    const oldCount = previous.get(key)?.count ?? 0;
    if (row.count > oldCount) {
      console.error(`FAIL ${baselinePath} added ${row.count - oldCount} ${row.directive} directive(s) for ${row.file}; a baseline may only shrink`);
      fail = true;
    }
  }
  return fail;
}

function compareSeedBaseline(baseline, counts) {
  let fail = false;
  const keys = new Set([...baseline.keys(), ...counts.keys()]);
  for (const key of keys) {
    const wanted = baseline.get(key)?.count ?? 0;
    const found = counts.get(key)?.count ?? 0;
    if (wanted !== found) {
      const row = baseline.get(key) ?? counts.get(key);
      console.error(`FAIL ${baselinePath} initial count for ${row.file} ${row.directive} is ${wanted}, current tree has ${found}`);
      fail = true;
    }
  }
  return fail;
}

function writeBaseline(counts) {
  const rows = [...counts.values()].sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.directive < b.directive ? -1 : a.directive > b.directive ? 1 : 0))
    .map(({ count, file, directive }) => `${count}\t${file}\t${directive}\n`).join('');
  writeFileSync(baselinePath, `# suppression-ratchet baseline: count<TAB>file<TAB>directive; lower counts only.\n${rows}`);
}

function main() {
  const scope = changedAt === 0 ? changedPaths(argv[1]) : null;
  const exceptions = readExceptions();
  const hasBaseline = existsSync(baselinePath);
  const baseline = hasBaseline ? readBaseline(readFileSync(baselinePath, 'utf8')) : new Map();
  const previousBaseline = scope ? compareBaselineToRef(argv[1], baseline) : false;
  if (previousBaseline === true) process.exit(1);
  const baselineBootstrap = scope && previousBaseline === null;
  const paths = !scope || baselineBootstrap || scope.has(baselinePath) || scope.has(exceptionsPath)
    ? trackedSourceFiles()
    : [...scope].filter((path) => sourceCommentKind(path) && existsSync(path));
  const directives = currentDirectives(paths, exceptions);
  const exceptionState = validatedExceptions(exceptions, directives);
  const counts = new Map();
  for (const entry of directives) {
    const location = `${entry.file}\0${entry.line}\0${entry.directive}`;
    if (exceptionState.keys.has(location)) continue;
    const key = signature(entry.file, entry.directive);
    const row = counts.get(key) ?? { file: entry.file, directive: entry.directive, count: 0, lines: [] };
    row.count++;
    row.lines.push(entry.line);
    counts.set(key, row);
  }

  let fail = exceptionState.fail || (baselineBootstrap && compareSeedBaseline(baseline, counts));
  for (const [key, row] of counts) {
    const limit = baseline.get(key)?.count ?? 0;
    if (row.count > limit && !(tighten && !hasBaseline)) {
      for (const line of row.lines.slice(limit)) {
        console.error(`FAIL ${row.file}:${line} ${row.directive}: fix the finding, or record the exception in an ADR and add it to ${exceptionsPath}`);
      }
      fail = true;
    }
  }
  if (tighten) {
    if (fail && hasBaseline) {
      console.error('suppression-ratchet: a directive was added or an exception is invalid; baseline left unchanged');
      process.exit(1);
    }
    writeBaseline(counts);
    console.log('suppression-ratchet: baseline tightened');
    process.exit(0);
  }
  if (fail) process.exit(1);
  console.log('suppression-ratchet ok');
}

try {
  main();
} catch (error) {
  console.error(`suppression-ratchet: ${error.message}`);
  process.exit(2);
}
