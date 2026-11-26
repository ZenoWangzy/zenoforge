import { execFileSync, spawn } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const baselineName = 'tools/gh-transport-baseline.txt';
const baselineHeader = '# gh transport baseline: one unwrapped script path per line; remove entries as callers load the wrapper.\n';
const wrapperCommands = new Set(['apply_gh_write', 'guarded_write', 'gh_write_soft', 'health_prod_errors_gh_read']);
const commandWrappers = new Set(['command', 'env', 'exec', 'nice', 'nohup', 'sudo', 'timeout']);
const deferredSourceTypes = new Set(['CaseClause', 'CmdSubst', 'ForClause', 'FuncDecl', 'IfClause', 'ProcSubst', 'Subshell', 'WhileClause']);
const skippedDirectories = new Set(['fixtures', 'node_modules', 'vendor']);

function usage() {
  console.error('usage: node tools/gh-transport-ratchet.mjs [--tighten] [--root <path>]');
}

function parseArgs(args) {
  let root = process.cwd();
  let tighten = false;
  let base;
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === '--tighten') tighten = true;
    else if (args[index] === '--root' && args[index + 1]) root = resolve(args[++index]);
    else if (args[index] === '--base' && args[index + 1]) base = args[++index];
    else return undefined;
  }
  return { root, tighten, base };
}

function shellFilesUnder(root, dir) {
  const absolute = join(root, dir);
  if (!existsSync(absolute)) return [];
  const results = [];
  for (const entry of readdirSync(absolute, { withFileTypes: true })) {
    const path = join(dir, entry.name).split(sep).join('/');
    if (entry.isDirectory()) {
      if (!skippedDirectories.has(entry.name)) results.push(...shellFilesUnder(root, path));
    } else if (entry.isFile() && path.endsWith('.sh')) results.push(path);
  }
  return results;
}

function scriptsUnder(root, dir) {
  return shellFilesUnder(root, dir).filter((path) => {
    if (/\.test\.sh$|(^|\/)test-[^/]*\.sh$/.test(path) || path === 'engine/lib.sh' || path.startsWith('engine/lib.d/')) return false;
    return /^#!.*\b(?:bash|sh)\b/.test(readFileSync(join(root, path), 'utf8'));
  }).sort();
}

async function mainLibrarySources(root) {
  const files = [...(existsSync(join(root, 'engine/lib.sh')) ? ['engine/lib.sh'] : []), ...shellFilesUnder(root, 'engine/lib.d'), ...shellFilesUnder(root, 'engine/providers')];
  const paths = new Set(files);
  const byName = new Map();
  for (const path of shellFilesUnder(root, 'engine')) {
    const name = path.slice(path.lastIndexOf('/') + 1);
    byName.set(name, [...(byName.get(name) ?? []), path]);
  }
  for (let index = 0; index < files.length;) {
    const batch = files.slice(index, index + 4);
    const sources = batch.map((path) => readFileSync(join(root, path), 'utf8'));
    const sourceBytes = sources.map((source) => Buffer.from(source));
    const trees = await Promise.all(batch.map((path, batchIndex) =>
      /\bsource\b|(?:^|[\s;|&])\.[ \t]+/m.test(sources[batchIndex]) ? parseScript(root, path, sources[batchIndex]) : undefined));
    for (let batchIndex = 0; batchIndex < batch.length; batchIndex += 1) {
      if (!trees[batchIndex]) continue;
      const path = batch[batchIndex];
      const source = sources[batchIndex];
      const tree = trees[batchIndex];
      const sourcePaths = new Set();
      const visit = (value) => {
        if (!value || typeof value !== 'object') return;
        if (Array.isArray(value)) {
          for (const item of value) visit(item);
          return;
        }
        if (value.Type === 'CallExpr' && Array.isArray(value.Args)) {
          const args = value.Args.map((word) => rawWord(sourceBytes[batchIndex], word));
          if ((args[0] === 'source' || args[0] === '.') && args[1]) sourcePaths.add(args[1]);
        }
        for (const child of Object.values(value)) visit(child);
      };
      visit(tree);
      for (const sourcePath of sourcePaths) {
        for (const match of sourcePath.matchAll(/([A-Za-z0-9_.-]+\.sh)(?=["'\s;|&)]|$)/g)) {
          const name = match[1];
          const direct = sourcePath.match(new RegExp(`(?:^|["' /])((?:engine/)?(?:lib\\.d|providers)/[^"' ]*${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`));
          const targets = direct ? [direct[1].startsWith('engine/') ? direct[1] : `engine/${direct[1]}`] : byName.get(name) ?? [];
          for (const target of targets) {
            if (!paths.has(target) && existsSync(join(root, target))) {
              paths.add(target);
              files.push(target);
            }
          }
        }
      }
    }
    index += batch.length;
  }
  return paths;
}

function rawWord(sourceBytes, word) {
  return sourceBytes.toString('utf8', word.Pos.Offset, word.End.Offset).replace(/^['"]|['"]$/g, '');
}

function expandPathVariables(value, variables) {
  return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::[-+?=][^}]*)?\}|\$([A-Za-z_][A-Za-z0-9_]*)/g, (match, braced, plain) => {
    const name = braced ?? plain;
    return variables.get(name) ?? match;
  });
}

function staticPathValue(root, path, raw, variables) {
  const directory = resolve(root, dirname(path));
  let unresolved = false;
  let value = raw.replace(/^["']|["']$/g, '').replace(/\$\(dirname[^)]*\)/g, directory);
  value = value.replace(/\$\(\s*cd(?:\s+--)?\s+([^)]+?)\s+&&\s+pwd(?:\s+-P)?\s*\)/g, (_match, destination) => {
    const expanded = expandPathVariables(destination.replace(/["']/g, ''), variables);
    if (expanded.includes('$') || !expanded.startsWith(sep)) {
      unresolved = true;
      return '';
    }
    return resolve(expanded);
  });
  value = expandPathVariables(value, variables).replace(/["']/g, '');
  if (unresolved || !value || value.includes('$') || !value.startsWith(sep)) return undefined;
  return resolve(value);
}

function pathVariablesBefore(root, path, sourceBytes, tree, offset) {
  const variables = new Map();
  for (const statement of tree.Stmts ?? []) {
    if (statement.Pos.Offset >= offset) break;
    const command = statement.Cmd;
    if (command?.Type !== 'CallExpr') continue;
    for (const assignment of command.Assigns ?? []) {
      const name = assignment.Name?.Value;
      if (!name) continue;
      const raw = assignment.Value ? rawWord(sourceBytes, assignment.Value) : '';
      const value = staticPathValue(root, path, raw, variables)
        ?? (name === 'ENGINE_DIR' && raw === '${ZF_ENGINE_DIR:-$ROOT/engine}' ? resolve(root, 'engine') : undefined);
      if (value) variables.set(name, value);
      else variables.delete(name);
    }
  }
  return variables;
}

function isWrapperPath(root, path, raw, variables, mainLibraryHasTransport) {
  const targetPath = staticPathValue(root, path, raw, variables);
  if (!targetPath || !existsSync(targetPath)) return false;
  const target = targetPath.split(sep).join('/');
  const relativeTarget = relative(root, target).split(sep).join('/');
  if (relativeTarget === 'engine/lib.d/transport.sh') return true;
  return relativeTarget === 'engine/lib.sh' && mainLibraryHasTransport;
}

function wrapperLoadOffset(root, path, args, offset, variables, mainLibraryHasTransport) {
  if ((args[0] !== 'source' && args[0] !== '.') || !isWrapperPath(root, path, args[1] ?? '', variables, mainLibraryHasTransport)) return undefined;
  return offset;
}

function skipCommandOptions(args, index, wrapper) {
  const optionsWithArguments = {
    env: new Set(['-u', '--unset', '-C', '--chdir', '-S', '--split-string']),
    exec: new Set(['-a', '--argv0']),
    nice: new Set(['-n', '--adjustment']),
    sudo: new Set(['-u', '--user', '-g', '--group', '-h', '--host', '-p', '--prompt', '-C', '--close-from', '-D', '--chdir', '-R', '--chroot', '-T', '--command-timeout', '-r', '--role', '-t', '--type', '-U', '--other-user']),
    timeout: new Set(['-k', '--kill-after', '-s', '--signal']),
  }[wrapper] ?? new Set();
  while (index < args.length) {
    const value = args[index];
    if (value === '--') return index + 1;
    if (!value.startsWith('-')) break;
    if ((wrapper === 'command' && /^-[vV]/.test(value)) || (wrapper === 'env' && (value === '-S' || value === '--split-string'))) return args.length;
    if (optionsWithArguments.has(value)) index += 2;
    else index += 1;
  }
  return index;
}

function ghCommandIndex(args) {
  let index = 0;
  while (commandWrappers.has(args[index])) {
    const wrapper = args[index];
    index += 1;
    if (wrapper === 'env') {
      index = skipCommandOptions(args, index, wrapper);
      while (/^[A-Za-z_][A-Za-z0-9_]*=/.test(args[index] ?? '')) index += 1;
    } else if (wrapper === 'command' || wrapper === 'exec' || wrapper === 'nice' || wrapper === 'sudo' || wrapper === 'nohup') {
      index = skipCommandOptions(args, index, wrapper);
    } else if (wrapper === 'timeout') {
      index = skipCommandOptions(args, index, wrapper);
      if (index < args.length) index += 1;
    }
  }
  return index;
}

function isGhCall(args) {
  if (wrapperCommands.has(args[0])) return isGhCall(args.slice(1));
  const index = ghCommandIndex(args);
  return args[index] === 'gh';
}

function isLoadedLibraryGuard(value, sourceBytes) {
  if (value.Type !== 'IfClause') return false;
  return (value.Cond ?? []).some((statement) => {
    const command = statement.Cmd;
    if (!statement.Negated || command?.Type !== 'DeclClause' || command.Variant?.Value !== 'declare') return false;
    const args = (command.Args ?? []).map((arg) => rawWord(sourceBytes, arg.Value ?? arg));
    return args.includes('-F') && (args.includes('agent_epoch') || args.includes('gh'));
  });
}

function parseScript(root, path, source) {
  return new Promise((resolveTree, reject) => {
    const child = spawn('shfmt', ['-tojson', '-ln', 'bash', '-filename', path], { cwd: root });
    let stdout = '';
    let stderr = '';
    let size = 0;
    let failed;
    child.stdout.on('data', (chunk) => {
      size += chunk.length;
      if (size > 32 * 1024 * 1024) {
        failed = new Error(`${path}: shfmt output exceeded 32 MB`);
        child.kill();
      } else stdout += chunk;
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => reject(new Error(`${path}: could not run shfmt: ${error.message}`)));
    child.on('close', (status) => {
      if (failed) return reject(failed);
      if (status !== 0) return reject(new Error(`${path}: could not parse with shfmt${stderr.trim() ? `: ${stderr.trim()}` : ''}`));
      try {
        resolveTree(JSON.parse(stdout));
      } catch (error) {
        reject(new Error(`${path}: invalid shfmt output: ${error.message}`));
      }
    });
    child.stdin.on('error', () => {});
    child.stdin.end(source);
  });
}

async function mainLibraryLoadsTransport(root) {
  const path = 'engine/lib.sh';
  const library = join(root, path);
  if (!existsSync(library)) return false;
  const source = readFileSync(library, 'utf8');
  const sourceBytes = Buffer.from(source);
  const tree = await parseScript(root, path, source);
  for (const statement of tree.Stmts ?? []) {
    const command = statement.Cmd;
    if (command?.Type !== 'CallExpr' || !Array.isArray(command.Args)) continue;
    const args = command.Args.map((word) => rawWord(sourceBytes, word));
    const variables = pathVariablesBefore(root, path, sourceBytes, tree, statement.Pos.Offset);
    if (wrapperLoadOffset(root, path, args, statement.Pos.Offset, variables, false) !== undefined) return true;
  }
  return false;
}

async function scanScript(root, path, mainLibraryHasTransport) {
  const source = readFileSync(join(root, path), 'utf8');
  const sourceBytes = Buffer.from(source);
  const code = source.replace(/^[ \t]*#.*$/gm, '');
  const firstCallText = code.search(/\bgh\b/i);
  if (firstCallText < 0) return false;
  const tree = await parseScript(root, path, source);
  let firstCall = Infinity;
  let firstLoad = Infinity;
  const visit = (value, canLoadTransport = true) => {
    if (!value || typeof value !== 'object') return;
    if (Array.isArray(value)) {
      for (const item of value) visit(item, canLoadTransport);
      return;
    }
    const loadedLibraryGuard = isLoadedLibraryGuard(value, sourceBytes);
    const loadAllowed = canLoadTransport && (!deferredSourceTypes.has(value.Type) || loadedLibraryGuard)
      && !(value.Type === 'BinaryCmd' && ['|', '|&'].includes(value.Op));
    if (value.Type === 'CallExpr' && Array.isArray(value.Args)) {
      const args = value.Args.map((word) => rawWord(sourceBytes, word));
      if (isGhCall(args)) firstCall = Math.min(firstCall, value.Pos.Offset);
      if (loadAllowed && wrapperLoadOffset(root, path, args, value.Pos.Offset, pathVariablesBefore(root, path, sourceBytes, tree, value.Pos.Offset), mainLibraryHasTransport) !== undefined) firstLoad = Math.min(firstLoad, value.Pos.Offset);
    }
    for (const [key, child] of Object.entries(value)) {
      const shortCircuited = value.Type === 'BinaryCmd' && ['&&', '||'].includes(value.Op) && key === 'Y';
      const guardedThen = loadedLibraryGuard && key === 'Then';
      const childLoadAllowed = canLoadTransport && (!deferredSourceTypes.has(value.Type) || guardedThen);
      visit(child, childLoadAllowed && !shortCircuited);
    }
  };
  visit(tree);
  return firstCall < Infinity && firstLoad > firstCall;
}

function parseBaseline(content) {
  const entries = new Set();
  for (const line of content.split(/\r?\n/)) {
    const value = line.trim();
    if (!value || value.startsWith('#')) continue;
    if (!/^(?:engine|tools)\/.+\.sh$/.test(value) || value.includes('..')) throw new Error(`${baselineName} has an invalid path: ${value}`);
    entries.add(value);
  }
  return entries;
}

function readBaseline(root) {
  const file = join(root, baselineName);
  if (!existsSync(file)) throw new Error(`${baselineName} is missing`);
  return parseBaseline(readFileSync(file, 'utf8'));
}

function baselineGrowth(root, current, requestedBase) {
  let base = requestedBase;
  if (!base) {
    try {
      base = execFileSync('git', ['-C', root, 'rev-parse', '--verify', 'origin/main'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    } catch {
      return [];
    }
  } else {
    try {
      base = execFileSync('git', ['-C', root, 'rev-parse', '--verify', base], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    } catch {
      throw new Error(`base ref is unavailable: ${requestedBase}`);
    }
  }
  let previous;
  try {
    previous = execFileSync('git', ['-C', root, 'show', `${base}:${baselineName}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    return [];
  }
  const oldEntries = parseBaseline(previous);
  return [...current].filter((path) => !oldEntries.has(path)).sort();
}

function printOffender(path) {
  console.log(`FAIL ${path} calls gh without the engine transport wrapper. Load it before the call with: source "$(git -C "$(dirname -- "\${BASH_SOURCE[0]}")" rev-parse --show-toplevel)/engine/lib.d/transport.sh"`);
}

async function run({ root, tighten, base }) {
  const baseline = readBaseline(root);
  const baselineAdds = baselineGrowth(root, baseline, base);
  if (baselineAdds.length) {
    console.log(`FAIL ${baselineName} may only shrink from its base; remove added entries: ${baselineAdds.join(', ')}`);
    return 1;
  }
  const librarySources = await mainLibrarySources(root);
  const mainLibraryHasTransport = await mainLibraryLoadsTransport(root);
  const candidates = ['engine', 'tools'].flatMap((dir) => scriptsUnder(root, dir)).filter((path) => !librarySources.has(path));
  const offenders = new Set();
  for (let index = 0; index < candidates.length; index += 4) {
    const matches = await Promise.all(candidates.slice(index, index + 4).map(async (path) => [path, await scanScript(root, path, mainLibraryHasTransport)]));
    for (const [path, hasOffender] of matches) if (hasOffender) offenders.add(path);
  }
  const newOffenders = [...offenders].filter((path) => !baseline.has(path)).sort();
  for (const path of newOffenders) printOffender(path);
  if (newOffenders.length) return 1;
  if (tighten) {
    const rows = [...offenders].sort().map((path) => `${path}\n`).join('');
    writeFileSync(join(root, baselineName), baselineHeader + rows);
    console.log('gh-transport-ratchet baseline tightened');
    return 0;
  }
  for (const path of [...baseline].filter((entry) => !offenders.has(entry)).sort()) console.log(`NOTE ${path} no longer calls gh; run node tools/gh-transport-ratchet.mjs --tighten to remove it from ${baselineName}.`);
  console.log('gh-transport-ratchet ok');
  return 0;
}

const options = parseArgs(process.argv.slice(2));
if (!options) {
  usage();
  process.exitCode = 2;
} else {
  try {
    process.exitCode = await run(options);
  } catch (error) {
    console.error(`gh-transport-ratchet: ${error.message}`);
    process.exitCode = 1;
  }
}
