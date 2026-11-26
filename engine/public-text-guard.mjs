import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const repoRoot = process.cwd();
const baselinePath = 'tools/public-text-baseline.txt';
const posixRoots = [['', 'home'].join('/'), ['', 'Users'].join('/')];
const posixRootHomes = [['', 'root'].join('/'), ['', 'var', 'root'].join('/'), ['', 'private', 'var', 'root'].join('/')];
const posixPath = new RegExp(`(^|[^A-Za-z0-9_.-])(?:(?:${posixRoots.join('|')})/[^/<>\\s]+(?=/|$|\\s|[),;.:])|(?:${posixRootHomes.join('|')})(?=/|$|\\s|[),;.:]))`, 'i');
const backslash = String.fromCharCode(92);
const escapedBackslash = `${backslash}${backslash}`;
const separator = `${escapedBackslash}{1,2}`;
const windowsPath = new RegExp(`(^|[^A-Za-z0-9_.-])[A-Z]:${separator}Users${separator}[^${escapedBackslash}\\s<>]+(?=${separator}|$|\\s|[),;.:])`, 'i');

function git(args, options = {}) {
  return execFileSync('git', args, { cwd: repoRoot, maxBuffer: 512 * 1024 * 1024, ...options });
}

function refsFromArgs(args) {
  let base;
  let head;
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === '--base') base = args[++index];
    else if (args[index] === '--head') head = args[++index];
  }
  if (!base || !head) throw new Error('base and head refs are required');
  return { base, head };
}

function sourceEntries(ref) {
  const tree = git(['ls-tree', '-rz', '--full-tree', '--format=%(objectname) %(path)', '-r', ref], { encoding: 'utf8' });
  return tree.split('\0').filter(Boolean).map((record) => {
    const separatorIndex = record.indexOf(' ');
    return { oid: record.slice(0, separatorIndex), file: record.slice(separatorIndex + 1) };
  });
}

function sourceBlobs(entries) {
  if (entries.length === 0) return new Map();
  const input = Buffer.from(entries.map(({ oid }) => oid).join('\n') + '\n');
  const output = git(['cat-file', '--batch'], { encoding: 'buffer', input });
  const blobs = new Map();
  let offset = 0;
  for (const entry of entries) {
    const headerEnd = output.indexOf(10, offset);
    if (headerEnd < 0) throw new Error('invalid git blob stream');
    const header = output.toString('utf8', offset, headerEnd);
    const size = Number(header.slice(header.lastIndexOf(' ') + 1));
    if (!Number.isSafeInteger(size) || size < 0) throw new Error('invalid git blob size');
    const start = headerEnd + 1;
    const end = start + size;
    const content = output.subarray(start, end);
    blobs.set(entry.file, content.includes(0) ? null : content.toString('utf8'));
    offset = end + 1;
  }
  return blobs;
}

function lineKinds(line, terms) {
  const kinds = [];
  if (posixPath.test(line) || windowsPath.test(line)) kinds.push('path');
  const lowered = line.toLowerCase();
  if (terms.some((term) => lowered.includes(term.toLowerCase()))) kinds.push('private');
  return kinds;
}

function filenameId(file) {
  return `name:${createHash('sha256').update(file).digest('hex')}`;
}

function treeMatches(ref, terms) {
  const matches = new Map();
  const entries = sourceEntries(ref);
  const blobs = sourceBlobs(entries);
  for (const { file } of entries) {
    const id = filenameId(file);
    for (const kind of lineKinds(file, terms)) {
      const key = `${kind}\t${id}`;
      if (!matches.has(key)) matches.set(key, { kind, id, location: `${id}:filename` });
    }
    const content = blobs.get(file);
    if (content === null) continue;
    for (const [index, line] of content.split(/\r?\n/).entries()) {
      for (const kind of lineKinds(line, terms)) {
        const key = `${kind}\t${id}`;
        matches.set(key, { kind, id, location: `${file}:${index + 1}` });
      }
    }
  }
  return matches;
}

function readCommitFile(ref, file) {
  try {
    return { exists: true, content: git(['show', `${ref}:${file}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }) };
  } catch {
    return { exists: false, content: '' };
  }
}

function commitFileMatches(ref, file, kind, terms) {
  const entry = sourceEntries(ref).find(({ file: candidate }) => filenameId(candidate) === file);
  if (!entry) return false;
  if (lineKinds(entry.file, terms).includes(kind)) return true;
  const { exists, content } = readCommitFile(ref, entry.file);
  return exists && content.split(/\r?\n/).some((line) => lineKinds(line, terms).includes(kind));
}

function parseBaseline(content) {
  const entries = new Map();
  const failures = [];
  for (const [index, row] of content.split(/\r?\n/).entries()) {
    if (!row) continue;
    const parts = row.split('\t');
    const kind = parts[0];
    const id = parts.slice(1).join('\t');
    if (!['path', 'private'].includes(kind) || !/^name:[a-f0-9]{64}$/.test(id)) {
      failures.push(`${baselinePath}:${index + 1}`);
      continue;
    }
    const key = `${kind}\t${id}`;
    if (entries.has(key)) failures.push(`${baselinePath}:${index + 1}`);
    entries.set(key, { kind, id, location: id });
  }
  return { entries, failures };
}

function readDenylist() {
  let raw;
  if (Object.hasOwn(process.env, 'ZF_PUBLIC_TEXT_DENYLIST')) {
    raw = process.env.ZF_PUBLIC_TEXT_DENYLIST;
  } else {
    const configPath = process.env.ZF_PUBLIC_TEXT_DENYLIST_FILE
      ?? join(process.env.XDG_CONFIG_HOME || join(homedir(), '.config'), 'zenoforge', 'public-text-denylist');
    if (existsSync(configPath)) raw = readFileSync(configPath, 'utf8');
    else if (process.env.ZF_PUBLIC_TEXT_DENYLIST_FILE) throw new Error('configured private denylist cannot be read');
    else raw = '';
  }
  return [...new Set(raw.split(/\r?\n/).map((term) => term.trim()).filter(Boolean))];
}

function redactTerms(value, terms) {
  let output = value;
  for (const term of terms) {
    const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    output = output.replace(new RegExp(escaped, 'gi'), '[redacted]');
  }
  return output;
}

function addedLines(base, head) {
  const diff = git(['diff', '--no-ext-diff', '--no-renames', '--unified=0', `${base}...${head}`, '--'], { encoding: 'utf8' });
  const additions = [];
  let file = '';
  let newLine = 0;
  let inHunk = false;
  for (const line of diff.split(/\r?\n/)) {
    if (line.startsWith('diff --git ')) {
      file = '';
      newLine = 0;
      inHunk = false;
    } else if (!inHunk && line.startsWith('+++ b/')) {
      file = line.slice(6);
    } else if (!inHunk && line.startsWith('+++ ')) {
      file = '';
    } else if (line.startsWith('@@')) {
      const hunk = /\+(\d+)(?:,\d+)? @@/.exec(line);
      newLine = hunk ? Number(hunk[1]) : 0;
      inHunk = true;
    } else if (inHunk && line.startsWith('+')) {
      if (file && newLine > 0) additions.push({ file, lineNumber: newLine, text: line.slice(1) });
      newLine += 1;
    } else if (inHunk && line.startsWith('-')) {
      continue;
    } else if (inHunk && line.startsWith('\\')) {
      continue;
    } else if (inHunk && newLine > 0) {
      newLine += 1;
    }
  }
  return additions;
}

function changedFiles(base, head) {
  return git(['diff', '--no-ext-diff', '--name-only', '--diff-filter=ACMR', '-z', `${base}...${head}`, '--'], { encoding: 'utf8' })
    .split('\0')
    .filter(Boolean);
}

function pullRequestBody() {
  const eventPath = process.env.GITHUB_EVENT_PATH;
  if (!eventPath) return '';
  const event = JSON.parse(readFileSync(eventPath, 'utf8'));
  return typeof event.pull_request?.body === 'string' ? event.pull_request.body : '';
}

function commitMessages(base, head) {
  const commits = git(['rev-list', '--reverse', `${base}..${head}`], { encoding: 'utf8' }).trim();
  if (!commits) return [];
  return commits.split(/\r?\n/).map((sha) => ({
    label: `commit message ${sha.slice(0, 12)}`,
    content: git(['show', '-s', '--format=%B', sha], { encoding: 'utf8' }),
  }));
}

function baselineCheck(base, head, terms, failures) {
  const baseFile = readCommitFile(base, baselinePath);
  const headFile = readCommitFile(head, baselinePath);
  const baseBaseline = parseBaseline(baseFile.content);
  const headBaseline = parseBaseline(headFile.content);
  failures.push(...baseBaseline.failures, ...headBaseline.failures);
  const baseMatches = !baseFile.exists || terms.length > 0 ? treeMatches(base, terms) : null;
  if (!baseFile.exists) {
    for (const match of baseMatches.values()) {
      if (!headBaseline.entries.has(`${match.kind}\t${match.id}`)) {
        failures.push(`main match missing from baseline: ${match.location}`);
      }
    }
    for (const entry of headBaseline.entries.values()) {
      if (!baseMatches.has(`${entry.kind}\t${entry.id}`)) {
        failures.push(`baseline seed is not present on main: ${entry.location}`);
      }
    }
    return;
  }
  if (baseMatches) {
    for (const match of baseMatches.values()) {
      if (!baseBaseline.entries.has(`${match.kind}\t${match.id}`)) {
        failures.push(`main match missing from baseline: ${match.location}`);
      }
    }
  }
  for (const entry of headBaseline.entries.values()) {
    if (!baseBaseline.entries.has(`${entry.kind}\t${entry.id}`)) {
      failures.push(`baseline may only shrink: ${baselinePath} (${entry.location})`);
    }
  }
  for (const entry of baseBaseline.entries.values()) {
    if (headBaseline.entries.has(`${entry.kind}\t${entry.id}`)) continue;
    if (entry.kind === 'private' && terms.length === 0) {
      failures.push(`private baseline cannot shrink while denylist is skipped: ${entry.location}`);
    } else if (commitFileMatches(head, entry.id, entry.kind, terms)) {
      failures.push(`baseline entry still matches: ${entry.location}`);
    }
  }
}

function scanDiffAndMetadata(base, head, terms, failures) {
  const found = new Set();
  const record = (location, lineNumber, text) => {
    if (lineKinds(text, terms).length > 0) found.add(`${location}:${lineNumber}`);
  };
  for (const file of changedFiles(base, head)) record(file, 'filename', file);
  for (const line of addedLines(base, head)) record(line.file, line.lineNumber, line.text);
  for (const message of commitMessages(base, head)) {
    for (const [index, line] of message.content.split(/\r?\n/).entries()) record(message.label, index + 1, line);
  }
  for (const [index, line] of pullRequestBody().split(/\r?\n/).entries()) record('PR body', index + 1, line);
  failures.push(...found);
}

function main() {
  const { base, head } = refsFromArgs(process.argv.slice(2));
  const terms = readDenylist();
  const failures = [];
  baselineCheck(base, head, terms, failures);
  scanDiffAndMetadata(base, head, terms, failures);
  if (terms.length === 0) console.log('public-text-guard: private denylist skipped (not configured)');
  for (const failure of new Set(failures)) console.error(`public-text-guard: blocked ${redactTerms(failure, terms)}`);
  if (failures.length > 0) process.exitCode = 1;
  else console.log('public-text-guard: passed');
}

try {
  main();
} catch {
  console.error('public-text-guard: could not inspect public text');
  process.exitCode = 1;
}
