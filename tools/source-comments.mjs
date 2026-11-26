import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import { extname, join } from 'node:path';

const kinds = { '.sh': 'sh', '.bash': 'sh', '.mjs': 'ts', '.cjs': 'ts', '.js': 'ts', '.ts': 'ts', '.py': 'py' };
const missingHelp = {
  shfmt: 'shfmt is not installed (needed for .sh files): download the static release binary from https://github.com/mvdan/sh/releases to ~/.local/bin/shfmt and chmod +x it',
  typescript: 'typescript is not installed (needed for .js/.ts/.mjs/.cjs files): run npm install -g typescript',
  python3: 'python3 is not installed (needed for .py files)',
};
let shfmtBin = 'shfmt';
let ts = null;

export function sourceCommentKind(path) {
  return kinds[extname(path)];
}

function findShfmt() {
  for (const bin of ['shfmt', join(homedir(), '.local', 'bin', 'shfmt')]) {
    if (!spawnSync(bin, ['--version']).error) return bin;
  }
  return null;
}

function loadTs() {
  if (ts) return ts;
  const attempt = (load) => { try { return load(); } catch { return null; } };
  const fromNpmRoot = () => {
    const root = spawnSync('npm', ['root', '-g'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    if (root.status !== 0) return null;
    return createRequire(import.meta.url)(join(root.stdout.trim(), 'typescript'));
  };
  ts = attempt(() => createRequire(join(process.cwd(), 'package.json'))('typescript'))
    ?? attempt(fromNpmRoot)
    ?? attempt(() => createRequire(import.meta.url)(join(homedir(), '.npm-global', 'lib', 'node_modules', 'typescript')));
  return ts;
}

function run(cmd, args, input) {
  const r = spawnSync(cmd === 'shfmt' ? shfmtBin : cmd, args, { input, encoding: 'utf8', maxBuffer: 1 << 30 });
  if (r.error?.code === 'ENOENT') return null;
  if (r.status !== 0) throw new Error(`${cmd} failed on ${args.join(' ')}: ${r.stderr.trim()}`);
  return r.stdout;
}

export function missingSourceCommentTools(kindSet) {
  const missing = [];
  if (kindSet.has('sh')) {
    const found = findShfmt();
    if (found) shfmtBin = found;
    else missing.push('shfmt');
  }
  if (kindSet.has('ts') && !loadTs()) missing.push('typescript');
  if (kindSet.has('py') && spawnSync('python3', ['--version']).error) missing.push('python3');
  return missing;
}

function shellComments(text) {
  const out = run('shfmt', ['--to-json'], text);
  if (out === null) throw new Error(missingHelp.shfmt);
  const comments = [];
  (function walk(node) {
    if (Array.isArray(node)) return node.forEach(walk);
    if (!node || typeof node !== 'object') return;
    if ('Hash' in node) {
      comments.push({ line: node.Pos?.Line ?? 1, offset: node.Pos?.Offset ?? 0, text: node.Text ?? '' });
      return;
    }
    Object.values(node).forEach(walk);
  })(JSON.parse(out));
  return comments;
}

function lineStarts(text) {
  const starts = [0];
  for (let i = 0; i < text.length; i++) if (text[i] === '\n') starts.push(i + 1);
  return starts;
}

function lineAt(starts, offset) {
  let low = 0, high = starts.length;
  while (low < high) {
    const mid = (low + high) >>> 1;
    if (starts[mid] <= offset) low = mid + 1;
    else high = mid;
  }
  return low;
}

function tsComments(text) {
  const T = loadTs();
  if (!T) throw new Error(missingHelp.typescript);
  const S = T.SyntaxKind;
  const scanner = T.createScanner(T.ScriptTarget.Latest, false, T.LanguageVariant.Standard, text);
  const starts = lineStarts(text), comments = [], templateBraces = [];
  let prev;
  let kind = scanner.scan();
  while (kind !== S.EndOfFileToken) {
    if (kind === S.SingleLineCommentTrivia || kind === S.MultiLineCommentTrivia) {
      comments.push({ line: lineAt(starts, scanner.getTokenPos()), text: scanner.getTokenText() });
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
  return comments;
}

function regexAllowed(prev, S) {
  return prev === undefined || ![S.Identifier, S.CloseParenToken, S.CloseBracketToken, S.CloseBraceToken,
    S.NumericLiteral, S.StringLiteral, S.NoSubstitutionTemplateLiteral, S.TemplateTail, S.RegularExpressionLiteral,
    S.PlusPlusToken, S.MinusMinusToken, S.ThisKeyword, S.TrueKeyword, S.FalseKeyword, S.NullKeyword].includes(prev);
}

const pythonComments = `import io, json, sys, tokenize
comments = []
for tok in tokenize.tokenize(io.BytesIO(sys.stdin.buffer.read()).readline):
    if tok.type == tokenize.COMMENT: comments.append({'line': tok.start[0], 'text': tok.string})
print(json.dumps(comments))`;

function pyComments(text) {
  const out = run('python3', ['-I', '-c', pythonComments], text);
  if (out === null) throw new Error(missingHelp.python3);
  return JSON.parse(out);
}

export function sourceComments(kind, text) {
  if (kind === 'sh') return shellComments(text);
  if (kind === 'ts') return tsComments(text);
  if (kind === 'py') return pyComments(text);
  throw new Error(`unsupported source comment kind: ${kind}`);
}

export function stripSourceComments(kind, text, path) {
  if (kind === 'sh') return run('shfmt', ['-mn'], text);
  if (kind === 'ts') {
    const T = loadTs();
    return T && T.createPrinter({ removeComments: true }).printFile(T.createSourceFile(path, text, T.ScriptTarget.Latest, false));
  }
  if (kind === 'py') return run('python3', ['-I', '-c', 'import ast,sys;sys.stdout.write(ast.dump(ast.parse(sys.stdin.read())))'], text);
  throw new Error(`unsupported source comment kind: ${kind}`);
}
