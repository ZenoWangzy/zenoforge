#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { missingSourceCommentTools, sourceCommentKind, sourceComments, stripSourceComments } from './source-comments.mjs';

process.chdir(join(fileURLToPath(import.meta.url), '..', '..'));
const baselinePath = 'tools/comment-baseline.txt';
const kindOf = sourceCommentKind;
const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 1 << 30 });

const argv = process.argv.slice(2);
const proofAt = argv.indexOf('--proof');
const changedAt = argv.indexOf('--changed');
if (argv.length && !(argv.length === 1 && argv[0] === '--tighten') && !(proofAt === 0 && argv.length === 2) && !(changedAt === 0 && argv.length === 2)) {
  console.error(`REFUSAL found=${JSON.stringify('unsupported arguments')} alternative=${JSON.stringify('run node tools/comment-ratchet.mjs with no arguments, --tighten, --proof <ref>, or --changed <ref>')} documented_in=docs/enforced-rules.md`);
  process.exit(2);
}

const ignoredTs = (text) => /^(eslint-|@ts-|\/ <reference|#!)/.test(text.replace(/^\/\/|^\/\*|\*\/$/g, '').trimStart());
const counters = {
  sh: (text) => sourceComments('sh', text).filter(({ text: comment, offset }) => !(comment.startsWith('!') && offset === 0) && !comment.trimStart().startsWith('shellcheck ')).length,
  ts: (text) => sourceComments('ts', text).filter(({ text: comment }) => !ignoredTs(comment)).length,
  py: (text) => sourceComments('py', text).filter(({ line, text: comment }) => !(line === 1 && comment.startsWith('#!')) && !/^#\s*(type:|noqa|pragma)/.test(comment)).length,
};
const stripped = {
  sh: (text) => stripSourceComments('sh', text),
  ts: (text, path) => stripSourceComments('ts', text, path),
  py: (text) => stripSourceComments('py', text),
};

function requireTools(kindSet) {
  const missing = missingSourceCommentTools(kindSet);
  const need = {
    shfmt: ['shfmt is not installed (needed for .sh files)', 'download the static release binary from https://github.com/mvdan/sh/releases and chmod +x it'],
    typescript: ['typescript is not installed (needed for .js/.ts/.mjs/.cjs files)', 'run npm install -g typescript'],
    python3: ['python3 is not installed (needed for .py files)', 'install Python 3 on PATH'],
  };
  const gone = [...new Set(missing)];
  if (gone.length) {
    for (const tool of gone) {
      const [found, alternative] = need[tool] ?? [`${tool} is not installed`, `install ${tool} on PATH`];
      console.error(`REFUSAL found=${JSON.stringify(found)} alternative=${JSON.stringify(alternative)} documented_in=tools/comment-ratchet.mjs,docs/enforced-rules.md`);
    }
    process.exit(2);
  }
}

if (proofAt === 0) {
  const ref = argv[1];
  const base = git('merge-base', ref, 'HEAD').trim();
  const changed = git('diff', '--name-status', base, 'HEAD').split('\n').filter(Boolean)
    .map((line) => line.split('\t')).filter(([, ...paths]) => kindOf(paths.at(-1)));
  requireTools(new Set(changed.map(([, ...paths]) => kindOf(paths.at(-1)))));
  const differs = [];
  for (const [status, ...paths] of changed) {
    const path = paths.at(-1);
    if (!status.startsWith('M')) { differs.push(path); continue; }
    const before = git('show', `${base}:${path}`);
    const after = git('show', `HEAD:${path}`);
    if (stripped[kindOf(path)](before, path) !== stripped[kindOf(path)](after, path)) differs.push(path);
  }
  if (differs.length) {
    console.log(`REFUSAL found=${JSON.stringify(`code changes in ${differs.join(', ')}`)} alternative=${JSON.stringify('use --proof only for comment-only changes and run normal checks for code changes')} documented_in=docs/enforced-rules.md`);
    process.exit(1);
  }
  console.log('comment-only: ok');
  process.exit(0);
}

const scope = changedAt === 0 ? new Set(git('diff', '--name-only', git('merge-base', argv[1], 'HEAD').trim(), 'HEAD').split('\n').filter(Boolean)) : null;
const listed = scope ? [...scope] : git('ls-files', '--cached', '--others', '--exclude-standard', 'engine', 'tools', 'cli').split('\n');
const files = listed.filter((f) => kindOf(f) && !f.includes('/vendor/') && !f.includes('node_modules/') && existsSync(f));
requireTools(new Set(files.map(kindOf)));

const base = new Map();
const hasBaseline = existsSync(baselinePath);
if (hasBaseline) {
  for (const line of readFileSync(baselinePath, 'utf8').split('\n')) {
    if (!line || line.startsWith('#')) continue;
    const [n, path] = line.split('\t');
    base.set(path, Number(n));
  }
}

const now = new Map();
for (const f of files) {
  const n = counters[kindOf(f)](readFileSync(f, 'utf8'));
  if (n > 0) now.set(f, n);
}

let fail = false;
for (const [f, n] of now) {
  const b = base.get(f) ?? 0;
  if (n > b) {
    fail = true;
    console.log(`REFUSAL found=${JSON.stringify(`${f} has ${n} comments, baseline in ${baselinePath} is ${b}`)} alternative=${JSON.stringify('remove the comment, record decisions in an ADR, and track a shortcut in an issue')} documented_in=docs/enforced-rules.md,docs/adr/`);
  } else if (n < b) console.log(`NOTE ${f} shrank to ${n} comments (baseline ${b}): run node tools/comment-ratchet.mjs --tighten.`);
}
for (const [f, b] of base) if (!now.has(f) && (!scope || scope.has(f))) console.log(`NOTE ${f} has no comments left (baseline ${b}): run node tools/comment-ratchet.mjs --tighten.`);

if (argv[0] === '--tighten') {
  if (fail && hasBaseline) {
    console.error(`REFUSAL found=${JSON.stringify('a count above baseline')} alternative=${JSON.stringify('remove the added comment before tightening')} documented_in=docs/enforced-rules.md. Nothing tightened.`);
    process.exit(1);
  }
  const rows = [...now].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([f, n]) => `${n}\t${f}\n`).join('');
  writeFileSync(baselinePath, `# comment-ratchet baseline: <count><TAB><path>; lower a count when a comment is removed.\n${rows}`);
  console.log('comment-ratchet: baseline tightened');
  process.exit(0);
}
if (!fail) console.log('comment-ratchet ok');
process.exit(fail ? 1 : 0);
