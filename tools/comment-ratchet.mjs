#!/usr/bin/env node
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

process.chdir(join(fileURLToPath(import.meta.url), '..', '..'));
const baselinePath = 'tools/comment-baseline.txt';
const kinds = { '.sh': 'sh', '.bash': 'sh', '.mjs': 'ts', '.cjs': 'ts', '.js': 'ts', '.ts': 'ts', '.py': 'py' };
const kindOf = (path) => kinds[extname(path)];
const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 1 << 30 });
const missing = [];

const argv = process.argv.slice(2);
const proofAt = argv.indexOf('--proof');
const changedAt = argv.indexOf('--changed');
if (argv.length && !(argv.length === 1 && argv[0] === '--tighten') && !(proofAt === 0 && argv.length === 2) && !(changedAt === 0 && argv.length === 2)) {
  console.error(`REFUSAL found=${JSON.stringify('unsupported arguments')} alternative=${JSON.stringify('run node tools/comment-ratchet.mjs with no arguments, --tighten, --proof <ref>, or --changed <ref>')} documented_in=docs/enforced-rules.md`);
  process.exit(2);
}

let shfmtBin = 'shfmt';
function findShfmt() {
  for (const bin of ['shfmt', join(homedir(), '.local', 'bin', 'shfmt')]) {
    if (!spawnSync(bin, ['--version']).error) return bin;
  }
  return null;
}

function run(cmd, args, input) {
  const r = spawnSync(cmd === 'shfmt' ? shfmtBin : cmd, args, { input, encoding: 'utf8', maxBuffer: 1 << 30 });
  if (r.error?.code === 'ENOENT') { missing.push(cmd); return null; }
  if (r.status !== 0) throw new Error(`${cmd} failed on ${args.join(' ')}: ${r.stderr.trim()}`);
  return r.stdout;
}

let ts = null;
function loadTs() {
  if (ts) return ts;
  const attempt = (load) => { try { return load(); } catch { return null; } };
  const fromNpmRoot = () => {
    const root = execFileSync('npm', ['root', '-g'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    return createRequire(import.meta.url)(join(root, 'typescript'));
  };
  const found = attempt(() => createRequire(join(process.cwd(), 'package.json'))('typescript'))
    ?? attempt(fromNpmRoot)
    ?? attempt(() => createRequire(import.meta.url)(join(homedir(), '.npm-global', 'lib', 'node_modules', 'typescript')));
  if (found) ts = found; else missing.push('typescript');
  return ts;
}

const ignoredTs = (text) => /^(eslint-|@ts-|\/ <reference|#!)/.test(text.replace(/^\/\/|^\/\*|\*\/$/g, '').trimStart());
const regexAllowed = (prev, S) => prev === undefined || ![S.Identifier, S.CloseParenToken, S.CloseBracketToken, S.CloseBraceToken,
  S.NumericLiteral, S.StringLiteral, S.NoSubstitutionTemplateLiteral, S.TemplateTail, S.RegularExpressionLiteral,
  S.PlusPlusToken, S.MinusMinusToken, S.ThisKeyword, S.TrueKeyword, S.FalseKeyword, S.NullKeyword].includes(prev);

function countTs(text) {
  const T = loadTs();
  if (!T) return 0;
  const S = T.SyntaxKind;
  const scanner = T.createScanner(T.ScriptTarget.Latest, false, T.LanguageVariant.Standard, text);
  const templateBraces = [];
  let n = 0, prev;
  let kind = scanner.scan();
  while (kind !== S.EndOfFileToken) {
    if (kind === S.SingleLineCommentTrivia || kind === S.MultiLineCommentTrivia) {
      if (!ignoredTs(scanner.getTokenText())) n++;
    } else if (kind < S.FirstTriviaToken || kind > S.LastTriviaToken) {
      if (kind === S.TemplateHead) templateBraces.push(0);
      else if (kind === S.OpenBraceToken && templateBraces.length) templateBraces[templateBraces.length - 1]++;
      else if (kind === S.CloseBraceToken && templateBraces.length) {
        if (templateBraces[templateBraces.length - 1] === 0) {
          kind = scanner.reScanTemplateToken(false);
          if (kind === S.TemplateTail) templateBraces.pop();
        } else templateBraces[templateBraces.length - 1]--;
      }
      if ((kind === S.SlashToken || kind === S.SlashEqualsToken) && regexAllowed(prev, S)) kind = scanner.reScanSlashToken();
      prev = kind;
    }
    kind = scanner.scan();
  }
  return n;
}

function countSh(text) {
  const out = run('shfmt', ['--to-json'], text);
  if (out === null) return 0;
  let n = 0;
  (function walk(node) {
    if (Array.isArray(node)) return node.forEach(walk);
    if (!node || typeof node !== 'object') return;
    if ('Hash' in node) {
      const text = node.Text ?? '';
      const shebang = text.startsWith('!') && node.Pos?.Offset === 0;
      if (!shebang && !text.trimStart().startsWith('shellcheck ')) n++;
      return;
    }
    Object.values(node).forEach(walk);
  })(JSON.parse(out));
  return n;
}

const pyCount = `import io, re, sys, tokenize
n = 0
for tok in tokenize.tokenize(io.BytesIO(sys.stdin.buffer.read()).readline):
    if tok.type != tokenize.COMMENT: continue
    if tok.start[0] == 1 and tok.string.startswith('#!'): continue
    if re.match(r'#\\s*(type:|noqa|pragma)', tok.string): continue
    n += 1
print(n)`;

function countPy(text) {
  const out = run('python3', ['-I', '-c', pyCount], text);
  return out === null ? 0 : Number(out);
}

const counters = { sh: countSh, ts: countTs, py: countPy };
const stripped = {
  sh: (text) => run('shfmt', ['-mn'], text),
  ts: (text, path) => {
    const T = loadTs();
    return T && T.createPrinter({ removeComments: true }).printFile(T.createSourceFile(path, text, T.ScriptTarget.Latest, false));
  },
  py: (text) => run('python3', ['-I', '-c', 'import ast,sys;sys.stdout.write(ast.dump(ast.parse(sys.stdin.read())))'], text),
};

function requireTools(kindSet) {
  missing.length = 0;
  if (kindSet.has('sh')) {
    const found = findShfmt();
    if (found) shfmtBin = found; else missing.push('shfmt');
  }
  if (kindSet.has('ts')) loadTs();
  if (kindSet.has('py')) run('python3', ['--version'], '');
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
