#!/usr/bin/env node

import { createReadStream, existsSync } from 'node:fs';
import { mkdir, readFile, readdir, rename, stat, unlink, writeFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REGISTRY_PATH = `${process.env.ZF_PACK_REL || 'engine'}/state/incident-guards.json`;
// With a pack (ZF_PACK_REL), the registry lives in the engine build's version root, not in the target repo;
// guard targets resolve against --repo first, then against that build.
const PACK_ROOT = process.env.ZF_PACK_REL
  ? path.resolve(process.env.ZF_PACK_ROOT || path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..'))
  : null;
const HISTORY_PREFIX = 'rulings-progress-';

function parseArgs(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 2) {
    const option = args[index];
    const value = args[index + 1];
    if (!['--repo', '--history-dir', '--output'].includes(option) || !value || options[option]) {
      throw new Error('usage: incident-guard-audit.mjs --repo <path> --history-dir <path> [--output <path>]');
    }
    options[option] = value;
  }
  if (!options['--repo'] || !options['--history-dir']) {
    throw new Error('usage: incident-guard-audit.mjs --repo <path> --history-dir <path> [--output <path>]');
  }
  return options;
}

function resolveRepoPath(raw, repo) {
  if (typeof raw !== 'string' || /\s/.test(raw)) return null;
  let value = raw.trim().replace(/^['"]|['"]$/g, '')
    .replaceAll('${REPO_DIR}', repo).replaceAll('$REPO_DIR', repo).replaceAll('${repo}', repo);
  if (path.isAbsolute(value)) {
    const relative = path.relative(repo, value);
    if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) return null;
    value = relative;
  }
  value = value.replaceAll('\\', '/').replace(/^\.\//, '');
  if (!value || value.startsWith('-') || /^[<>]/.test(value) || /[*?\[\]]/.test(value) || /^\$/.test(value)) return null;
  const absolute = path.resolve(repo, value);
  if (absolute !== repo && !absolute.startsWith(`${repo}${path.sep}`)) return null;
  if (PACK_ROOT && !existsSync(absolute)) {
    // Pipeline files are in the engine build, not the product repo; a target is missing only if neither has it.
    const built = path.resolve(PACK_ROOT, value);
    if (built.startsWith(`${PACK_ROOT}${path.sep}`) && existsSync(built)) return { absolute: built, relative: value };
  }
  return { absolute, relative: path.relative(repo, absolute).split(path.sep).join('/') };
}

function shellSegments(source) {
  const segments = [];
  let start = 0;
  let quote = '';
  let escaped = false;
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (escaped) { escaped = false; continue; }
    if (char === '\\' && quote !== "'") { escaped = true; continue; }
    if (quote) {
      if (char === quote) quote = '';
      continue;
    }
    if (char === "'" || char === '"') { quote = char; continue; }
    if (char === ';' || char === '\n' || char === '|' || char === '&') {
      const segment = source.slice(start, index).trim();
      if (segment) segments.push(segment);
      if ((char === '|' || char === '&') && source[index + 1] === char) index += 1;
      start = index + 1;
    }
  }
  const tail = source.slice(start).trim();
  if (tail) segments.push(tail);
  return segments;
}

function shellWords(source) {
  const words = [];
  let word = '';
  let quote = '';
  let escaped = false;
  const flush = () => { if (word) words.push(word); word = ''; };
  for (const char of source) {
    if (escaped) { word += char; escaped = false; continue; }
    if (char === '\\' && quote !== "'") { escaped = true; continue; }
    if (quote) {
      if (char === quote) quote = '';
      else word += char;
      continue;
    }
    if (char === "'" || char === '"') { quote = char; continue; }
    if (/\s/.test(char)) { flush(); continue; }
    word += char;
  }
  if (escaped) word += '\\';
  flush();
  return words;
}

function fixedGrepArgs(args, repo) {
  const targets = [];
  let fixed = false;
  let pattern;
  let patternIndex = -1;
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--') {
      pattern = args[index + 1];
      patternIndex = index + 1;
      break;
    }
    if (arg === '-e' || arg === '--regexp') {
      pattern = args[index + 1];
      patternIndex = index + 1;
      break;
    }
    if (arg.startsWith('-')) {
      fixed ||= arg === '--fixed-strings' || arg.slice(1).includes('F');
      continue;
    }
    pattern = arg;
    patternIndex = index;
    break;
  }
  if (!fixed || patternIndex < 0 || typeof pattern !== 'string' || pattern.length === 0 || pattern.length > 120 || pattern.includes('\n')) return targets;
  const file = args.slice(patternIndex + 1).find((arg) => resolveRepoPath(arg, repo));
  const resolved = file && resolveRepoPath(file, repo);
  if (resolved) targets.push({ path: resolved, symbol: pattern });
  return targets;
}

function fixedGrepTargets(source, repo) {
  const targets = [];
  for (const segment of shellSegments(source)) {
    const words = shellWords(segment);
    const grepIndex = words.findIndex((word) => path.basename(word) === 'grep');
    if (grepIndex < 0 || words.slice(0, grepIndex).includes('!')) continue;
    targets.push(...fixedGrepArgs(words.slice(grepIndex + 1), repo));
  }
  return targets;
}

function fixedGrepArgv(command, repo) {
  return path.basename(String(command[0] ?? '')) === 'grep'
    ? fixedGrepArgs(command.slice(1), repo)
    : [];
}

function explicitFileChecks(source) {
  const targets = [];
  for (const segment of shellSegments(source)) {
    const words = shellWords(segment);
    for (let index = 0; index < words.length; index += 1) {
      if (words[index] !== 'test' && words[index] !== '[' && words[index] !== '[[') continue;
      let flagIndex = index + 1;
      if (words[flagIndex] === '!') continue;
      if (['-f', '-e', '-r', '-s'].includes(words[flagIndex]) && words[flagIndex + 1]) {
        targets.push(words[flagIndex + 1]);
      }
    }
  }
  return targets;
}

function executableFiles(command) {
  const targets = [];
  if (typeof command[0] === 'string' && command[0].includes('/') && !command[0].includes('node_modules/')) {
    targets.push(command[0]);
  }
  for (let index = 0; index < command.length - 1; index += 1) {
    if (!['bash', 'sh', 'node', 'python', 'python2', 'python3', 'ruby'].includes(command[index])) continue;
    const next = command[index + 1];
    if (next && !next.startsWith('-')) targets.push(next);
    if (command[index + 1] === '--test' && command[index + 2]) targets.push(command[index + 2]);
  }
  return targets;
}

function shellScript(command, repo) {
  const shellIndex = command.findIndex((part) => part === 'bash' || part === 'sh');
  if (shellIndex < 0 || command[shellIndex + 1] !== '-c' || !command[shellIndex + 2]) return null;
  let source = command[shellIndex + 2];
  const repositoryArgument = command.slice(shellIndex + 4).find((part) =>
    part === '${REPO_DIR}' || part === '$REPO_DIR' || part === repo);
  if (repositoryArgument) {
    const positional = command.indexOf(repositoryArgument, shellIndex + 3) - shellIndex - 3;
    const variables = [...source.matchAll(/\b([A-Za-z_]\w*)\s*=\s*["']?\$(\d+)["']?/g)]
      .filter(([, , index]) => Number(index) === positional)
      .map(([, name]) => name);
    for (const name of variables) source = source.replace(new RegExp(`\\$${name}\\b`, 'g'), repositoryArgument);
    source = source.replace(new RegExp(`\\$${positional}\\b`, 'g'), repositoryArgument);
  }
  return source;
}

function guardTargets(guard, repo) {
  const targets = new Map();
  const addFile = (raw) => {
    const resolved = resolveRepoPath(raw, repo);
    if (resolved) targets.set(`file:${resolved.relative}`, { kind: 'file', target: resolved.relative, absolute: resolved.absolute });
  };
  for (const check of guard.machine_checks ?? []) {
    addFile(check.test_file);
    for (const command of [check.command, check.per_tick_command ?? []]) {
      if (!Array.isArray(command)) continue;
      const script = shellScript(command, repo);
      const isDirectFileCheck = command[0] === 'test' || command[0] === '[' || command[0] === '[[';
      if (script !== null) {
        // shortcut: skip conditional shell branches; add branch parsing if a live stale target hides there.
        if (!/^\s*(?:if|case)\b/m.test(script)) {
          for (const target of explicitFileChecks(script)) addFile(target);
          for (const { path: resolved, symbol } of fixedGrepTargets(script, repo)) {
            const key = `symbol:${resolved.relative}#${symbol}`;
            targets.set(key, { kind: 'symbol', target: `${resolved.relative}#${symbol}`, absolute: resolved.absolute, symbol });
          }
        }
      } else if (isDirectFileCheck) {
        for (const target of explicitFileChecks(command.join(' '))) addFile(target);
      }
      for (const target of executableFiles(command)) addFile(target);
      for (const { path: resolved, symbol } of fixedGrepArgv(command, repo)) {
        const key = `symbol:${resolved.relative}#${symbol}`;
        targets.set(key, { kind: 'symbol', target: `${resolved.relative}#${symbol}`, absolute: resolved.absolute, symbol });
      }
    }
  }
  return [...targets.values()];
}

function normalizedCommand(command) {
  return Array.isArray(command) ? command.map((part) => String(part)
    .replaceAll('${REPO_DIR}', '$REPO_DIR').replace(/\s+/g, ' ').trim()) : [];
}

function checkSignature(guard) {
  return (guard.machine_checks ?? []).map((check) => JSON.stringify([
    normalizedCommand(check.command),
    normalizedCommand(check.per_tick_command ?? []),
    check.expected ?? '',
    check.test_file ? normalizedCommand([check.test_file]) : '',
  ])).sort().join('\n');
}

function semanticText(guard) {
  return [guard.class, guard.what_happened, ...(guard.machine_checks ?? []).map((check) => check.why)]
    .filter(Boolean).join(' ').toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

function trigrams(value) {
  const compact = `  ${value}  `;
  const result = new Set();
  for (let index = 0; index <= compact.length - 3; index += 1) result.add(compact.slice(index, index + 3));
  return result;
}

function textSimilarity(left, right) {
  const a = trigrams(left);
  const b = trigrams(right);
  let shared = 0;
  for (const value of a) if (b.has(value)) shared += 1;
  return shared / (a.size + b.size - shared || 1);
}

function duplicateGroups(incidents) {
  const buckets = new Map();
  for (const guard of incidents) {
    if (!(guard.machine_checks?.length)) continue;
    const signature = checkSignature(guard);
    const group = buckets.get(signature) ?? [];
    group.push(guard);
    buckets.set(signature, group);
  }
  const results = [];
  for (const guards of buckets.values()) {
    if (guards.length < 2) continue;
    const parent = guards.map((_, index) => index);
    const root = (index) => parent[index] === index ? index : (parent[index] = root(parent[index]));
    // ponytail: near-duplicate scan requires the same check signature; add broader candidate grouping if real duplicates vary assertions.
    for (let left = 0; left < guards.length; left += 1) {
      for (let right = left + 1; right < guards.length; right += 1) {
        if (textSimilarity(semanticText(guards[left]), semanticText(guards[right])) >= 0.88) {
          parent[root(right)] = root(left);
        }
      }
    }
    const connected = new Map();
    for (let index = 0; index < guards.length; index += 1) {
      const key = root(index);
      const group = connected.get(key) ?? [];
      group.push(guards[index]);
      connected.set(key, group);
    }
    for (const group of connected.values()) {
      if (group.length < 2) continue;
      const descriptions = new Set(group.map(semanticText));
      results.push({
        kind: descriptions.size === 1 ? 'exact' : 'near',
        guards: group.map((guard) => guard.id).sort(),
      });
    }
  }
  return results.sort((left, right) => left.guards[0].localeCompare(right.guards[0]));
}

async function readGuardHistory(historyDir) {
  let entries;
  try {
    entries = await readdir(historyDir, { withFileTypes: true });
  } catch (error) {
    if (error.code === 'ENOENT') return {
      files: 0, inProgressFiles: 0, firstFile: null, lastFile: null,
      observations: 0, checked: 0, drifted: 0, errors: 0, results: new Map(),
    };
    throw error;
  }
  const candidates = entries.filter((entry) => entry.isFile() && entry.name.startsWith(HISTORY_PREFIX))
    .map((entry) => entry.name).sort();
  const files = [];
  let inProgressFiles = 0;
  for (const file of candidates) {
    const match = /^rulings-progress-(\d{8})T(\d{6})\d+-(\d+)\.log$/.exec(file);
    if (match) {
      const startedAt = Date.parse(`${match[1].slice(0, 4)}-${match[1].slice(4, 6)}-${match[1].slice(6)}T${match[2].slice(0, 2)}:${match[2].slice(2, 4)}:${match[2].slice(4)}Z`);
      const age = Date.now() - startedAt;
      // ponytail: 15m window avoids PID-reuse false positives; widen only if rulings checks can outlast it.
      if (age >= -5 * 60_000 && age <= 15 * 60_000) {
        try {
          process.kill(Number(match[3]), 0);
          inProgressFiles += 1;
          continue;
        } catch (error) {
          if (error.code === 'EPERM') {
            inProgressFiles += 1;
            continue;
          }
          if (error.code !== 'ESRCH') throw error;
        }
      }
    }
    files.push(file);
  }
  const results = new Map();
  let observations = 0;
  let checked = 0;
  let drifted = 0;
  let errors = 0;
  for (const file of files) {
    const lines = createInterface({ input: createReadStream(path.join(historyDir, file)), crlfDelay: Infinity });
    for await (const line of lines) {
      const match = /^(CHECKED|DRIFT|ERROR)\s+incident-guard:([A-Za-z0-9._-]+)(?:\s|$)/.exec(line);
      if (!match) continue;
      const [, status, id] = match;
      const result = results.get(id) ?? { checked: 0, drifted: 0, errors: 0 };
      if (status === 'CHECKED') result.checked += 1;
      else if (status === 'DRIFT') result.drifted += 1;
      else result.errors += 1;
      if (status === 'CHECKED') checked += 1;
      else if (status === 'DRIFT') drifted += 1;
      else errors += 1;
      results.set(id, result);
      observations += 1;
    }
  }
  return {
    files: files.length, inProgressFiles, firstFile: files[0] ?? null, lastFile: files.at(-1) ?? null,
    observations, checked, drifted, errors, results,
  };
}

export async function auditIncidentGuards(repoInput, historyDirInput) {
  const repo = path.resolve(repoInput);
  const historyDir = path.resolve(historyDirInput);
  const registry = JSON.parse(await readFile(path.join(PACK_ROOT ?? repo, REGISTRY_PATH), 'utf8'));
  if (!Array.isArray(registry.incidents)) throw new Error(`invalid incident guard registry: ${REGISTRY_PATH}`);
  const incidents = registry.incidents;
  const history = await readGuardHistory(historyDir);
  const neverDrifted = incidents.filter((guard) => {
    const result = history.results.get(guard.id);
    return result && result.checked > 0 && result.drifted === 0;
  }).map((guard) => guard.id).sort();

  const missingByGuard = new Map();
  const markMissing = (id, target) => {
    const items = missingByGuard.get(id) ?? [];
    items.push(target);
    missingByGuard.set(id, items);
  };
  for (const guard of incidents) {
    for (const target of guardTargets(guard, repo)) {
      if (target.kind === 'file') {
        let isFile = false;
        try {
          isFile = (await stat(target.absolute)).isFile();
        } catch (error) {
          if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
        }
        if (!isFile) {
          markMissing(guard.id, { kind: 'file', target: target.target });
        }
      } else {
        let contents;
        try {
          if (!(await stat(target.absolute)).isFile()) throw Object.assign(new Error('not a file'), { code: 'ENOENT' });
          contents = await readFile(target.absolute, 'utf8');
        } catch (error) {
          if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
          markMissing(guard.id, { kind: 'file', target: target.target.split('#', 1)[0] });
          continue;
        }
        if (!contents.includes(target.symbol)) {
          markMissing(guard.id, { kind: 'symbol', target: target.target });
        }
      }
    }
  }
  const missingTargets = [...missingByGuard].map(([id, targets]) => ({
    id,
    targets: [...new Map(targets.map((target) => [`${target.kind}:${target.target}`, target])).values()]
      .sort((left, right) => left.target.localeCompare(right.target)),
  })).sort((left, right) => left.id.localeCompare(right.id));
  return {
    generatedAt: new Date().toISOString(),
    history: {
      files: history.files,
      inProgressFiles: history.inProgressFiles,
      firstFile: history.firstFile,
      lastFile: history.lastFile,
      observations: history.observations,
      checked: history.checked,
      drifted: history.drifted,
      errors: history.errors,
    },
    neverDrifted,
    missingTargets,
    nearDuplicates: duplicateGroups(incidents),
  };
}

async function main(args) {
  const options = parseArgs(args);
  const audit = await auditIncidentGuards(options['--repo'], options['--history-dir']);
  const output = `${JSON.stringify(audit, null, 2)}\n`;
  if (options['--output']) {
    const outputPath = path.resolve(options['--output']);
    await mkdir(path.dirname(outputPath), { recursive: true });
    const temporaryPath = `${outputPath}.${process.pid}.tmp`;
    try {
      await writeFile(temporaryPath, output, { mode: 0o600 });
      await rename(temporaryPath, outputPath);
    } catch (error) {
      await unlink(temporaryPath).catch(() => {});
      throw error;
    }
  }
  process.stdout.write(output);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`incident-guard-audit: ${error.message}\n`);
    process.exitCode = 1;
  });
}
