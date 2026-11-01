import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { zfEnv } from '../pack-dir.mjs';

export const NIGHT_SUITE_PATH = 'engine/night/night.test.sh';
export const NIGHT_PROGRESS_CONTEXT_ENV = 'NIGHT_TEST_PROGRESS_CONTEXT';
const HELPER_PATH = 'engine/night/night-test-progress.mjs';
const AUX_PATH = 'engine/night/main-ci-recovery.test.sh';
const AUX_GROUP = 'main-ci-recovery';
const VERSION = 1;
// Revalidate old greens with real executions. An observed red has no age-based pardon.
const GREEN_MAX_AGE_MS = 24 * 60 * 60 * 1000;
const hash = (value) => createHash('sha256').update(value).digest('hex');
const identityHash = (value) => hash(JSON.stringify(value));
const sourceHash = (path) => hash(readFileSync(path));

// Shared with post-land attribution so captured output and thrown I/O errors agree.
// Callers decide whether a result failed; words in a successful test are not a failure.
export function localStorageFailureDiagnostic({ error, stdout = '', stderr = '' }) {
  return `${error?.code ?? ''} ${error?.message ?? ''}\n${stdout}\n${stderr}`
    .split(/\r?\n/).find((line) => /\bENOSPC\b|No space left on device/i.test(line))?.trim();
}

export function clearNightTestControls(env) {
  for (const key of ['NIGHT_TEST_GROUP', 'NIGHT_TEST_CASE', 'NIGHT_TEST_SEED_FIXTURE', NIGHT_PROGRESS_CONTEXT_ENV,
    'ZF_NIGHT_TEST_PROGRESS_CONTEXT']) delete env[key];
  return env;
}

export function nightProgressPolicy(env = process.env) {
  // These are configured limits, never this probe's shrinking remaining seconds.
  return {
    version: VERSION,
    night_jobs: env.NIGHT_TEST_JOBS || '8',
    stage_timeout_seconds: env.ZF_PREFLIGHT_STAGE_TIMEOUT_SECONDS || null,
    post_land_suite_timeout_seconds: env.ZF_POST_LAND_SUITE_TIMEOUT_SECONDS || '1800',
    post_land_slot_timeout_seconds: zfEnv('POST_LAND_SLOT_TIMEOUT_SECONDS', undefined, env) || '1800',
    post_land_slots: env.ZF_POST_LAND_SLOTS || '1',
  };
}

function directory(path) {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  if (!lstatSync(path).isDirectory() || realpathSync(path) !== resolve(path)) throw new Error(`Unsafe night progress directory: ${path}`);
  return path;
}

function readJson(path) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.size > 65536) throw new Error(`Invalid night progress file: ${path}`);
  return JSON.parse(readFileSync(path, 'utf8'));
}

function present(path) {
  try { lstatSync(path); return true; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

function atomicJson(path, value) {
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value)}\n`, { flag: 'wx', mode: 0o600 });
  renameSync(temporary, path);
}

function contextIdentity(doc) {
  return { version: doc.version, head: doc.head, baseline: doc.baseline, verifier_key: doc.verifier_key, policy: doc.policy, sources: doc.sources };
}

export function createNightProgressContext({ root, repoRoot, head, baseline, verifierKey, policy }) {
  if (!root || !/^[a-f0-9]{40,64}$/.test(head) || !/^[a-f0-9]{40,64}$/.test(baseline) || !/^[a-f0-9]{64}$/.test(verifierKey)) return undefined;
  const paths = [NIGHT_SUITE_PATH, AUX_PATH, HELPER_PATH];
  // An old baseline/candidate without this protocol still runs the whole canonical suite.
  if (paths.some((path) => !existsSync(join(repoRoot, path)))) return undefined;
  const identity = { version: VERSION, head, baseline, verifier_key: verifierKey, policy, sources: Object.fromEntries(paths.map((path) => [path, sourceHash(join(repoRoot, path))])) };
  const key = identityHash(identity);
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const contextDir = directory(join(realpathSync(root), 'night-groups', key));
  const contextFile = join(contextDir, 'context.json');
  const doc = { ...identity, key };
  if (present(contextFile)) {
    if (JSON.stringify(readJson(contextFile)) !== JSON.stringify(doc)) throw new Error('Night progress context is corrupt; refusing to reuse it');
  } else atomicJson(contextFile, doc);
  return contextFile;
}

function loadContext(contextFile, script, verifyHead = false) {
  if (!isAbsolute(contextFile) || !isAbsolute(script)) throw new Error('Night progress paths must be absolute');
  const context = readJson(contextFile);
  if (context.version !== VERSION || context.key !== identityHash(contextIdentity(context))
    || dirname(contextFile).split('/').at(-1) !== context.key || contextFile !== join(directory(dirname(contextFile)), 'context.json')) {
    throw new Error('Night progress context binding does not match');
  }
  const repoRoot = resolve(dirname(script), '../..');
  if (script !== join(repoRoot, NIGHT_SUITE_PATH)) throw new Error('Night progress requires the canonical night suite');
  for (const path of [NIGHT_SUITE_PATH, AUX_PATH, HELPER_PATH]) {
    if (sourceHash(join(repoRoot, path)) !== context.sources?.[path]) throw new Error(`Night progress source changed: ${path}`);
  }
  if (verifyHead) {
    const result = spawnSync('git', ['-C', repoRoot, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
    if (result.status !== 0 || result.error || result.stdout.trim() !== context.head) throw new Error('Night progress HEAD changed');
  }
  return { context, repoRoot };
}

export function prepareNightProgress(contextFile, script, groups) {
  const { context } = loadContext(contextFile, script, true);
  if (!groups.length || new Set(groups).size !== groups.length || groups.some((group) => !/^[a-z][a-z0-9-]*$/.test(group) || ['all', 'health-seed', AUX_GROUP].includes(group))) {
    throw new Error('Night progress group manifest is invalid');
  }
  // The owner passes its original array, so selection and completeness have one source.
  const identity = { version: VERSION, context_key: context.key, groups, auxiliary: AUX_GROUP };
  const key = identityHash(identity);
  const manifestDir = directory(join(dirname(contextFile), 'manifests', key));
  directory(join(manifestDir, 'greens'));
  directory(join(manifestDir, 'reds'));
  const file = join(manifestDir, 'manifest.json');
  const doc = { ...identity, key, context_file: contextFile };
  if (present(file)) {
    if (JSON.stringify(readJson(file)) !== JSON.stringify(doc)) throw new Error('Night progress manifest is corrupt');
  } else atomicJson(file, doc);
  return file;
}

function loadManifest(file, script) {
  const manifest = readJson(file);
  const { context, repoRoot } = loadContext(manifest.context_file, script, true);
  const identity = { version: manifest.version, context_key: manifest.context_key, groups: manifest.groups, auxiliary: manifest.auxiliary };
  const expected = join(dirname(manifest.context_file), 'manifests', manifest.key, 'manifest.json');
  if (manifest.version !== VERSION || manifest.context_key !== context.key || manifest.key !== identityHash(identity)
    || file !== expected || manifest.auxiliary !== AUX_GROUP || !Array.isArray(manifest.groups)
    || !manifest.groups.length || new Set(manifest.groups).size !== manifest.groups.length
    || manifest.groups.some((group) => !/^[a-z][a-z0-9-]*$/.test(group) || ['all', 'health-seed', AUX_GROUP].includes(group))) {
    throw new Error('Night progress manifest binding does not match');
  }
  directory(dirname(file));
  directory(join(dirname(file), 'greens'));
  directory(join(dirname(file), 'reds'));
  return { manifest, context, repoRoot };
}

function receiptFile(file, kind, group) { return join(dirname(file), kind, `${group}.json`); }

function boundReceipt(doc, manifest, group) {
  return doc.version === VERSION && doc.manifest_key === manifest.key && doc.context_key === manifest.context_key && doc.group === group;
}

function greenReceipt(file, manifest, group) {
  try {
    const doc = readJson(receiptFile(file, 'greens', group));
    const age = Date.now() - doc.completed_at_ms;
    return boundReceipt(doc, manifest, group) && doc.kind === 'green' && doc.exit_code === 0
      && Number.isSafeInteger(doc.completed_at_ms) && age >= 0 && age <= GREEN_MAX_AGE_MS;
  } catch { return false; }
}

function observedRed(file, manifest, group) {
  const path = receiptFile(file, 'reds', group);
  if (!present(path)) return undefined;
  try {
    const doc = readJson(path);
    if (boundReceipt(doc, manifest, group) && doc.kind === 'observed-red' && Number.isInteger(doc.exit_code)
      && doc.exit_code > 0 && doc.exit_code <= 255 && typeof doc.diagnostic === 'string') return doc;
  } catch { /* A broken failure record cannot silently pardon an earlier red. */ }
  return { diagnostic: `corrupt observed-red record for ${group}`, exit_code: 1 };
}

export async function runNightProgressGroup(file, script, group) {
  const { manifest, repoRoot } = loadManifest(file, script);
  if (![...manifest.groups, AUX_GROUP].includes(group)) throw new Error(`Unknown night progress group: ${group}`);
  if (!observedRed(file, manifest, group) && greenReceipt(file, manifest, group)) {
    console.log(`Night group reused: ${group}`);
    return 0;
  }
  const env = { ...process.env };
  delete env[NIGHT_PROGRESS_CONTEXT_ENV];
  delete env.NIGHT_TEST_CASE;
  if (group === AUX_GROUP) {
    delete env.NIGHT_TEST_GROUP;
    delete env.NIGHT_TEST_SEED_FIXTURE;
  } else env.NIGHT_TEST_GROUP = group;
  let interrupted = false;
  let tail = '';
  let firstFailure = '';
  let infrastructureFailure = '';
  const child = spawn('bash', [group === AUX_GROUP ? join(repoRoot, AUX_PATH) : script], {
    cwd: repoRoot, env, stdio: ['ignore', 'pipe', 'pipe'],
  });
  const onSignal = (signal) => { interrupted = true; child.kill(signal); };
  const term = () => onSignal('SIGTERM');
  const interrupt = () => onSignal('SIGINT');
  process.on('SIGTERM', term);
  process.on('SIGINT', interrupt);
  const forward = (stream) => (chunk) => {
    stream.write(chunk);
    const text = chunk.toString('utf8');
    tail = `${tail}${text}`.slice(-8192);
    if (!firstFailure) firstFailure = text.split(/\r?\n/).find((line) => /not ok|ENOSPC|No space left on device/i.test(line))?.slice(0, 1000) || '';
    if (!infrastructureFailure) infrastructureFailure = localStorageFailureDiagnostic({ stdout: tail })?.slice(0, 1000) || '';
  };
  child.stdout.on('data', forward(process.stdout));
  child.stderr.on('data', forward(process.stderr));
  let result;
  try {
    result = await new Promise((resolveResult) => {
      child.once('error', (error) => resolveResult({ error }));
      child.once('close', (code, signal) => resolveResult({ code, signal }));
    });
  } finally {
    process.off('SIGTERM', term);
    process.off('SIGINT', interrupt);
  }
  if (result.error) throw result.error;
  if (interrupted || result.signal || [124, 130, 137, 143].includes(result.code)) return result.code || 143;
  // This run remains failed, but storage exhaustion cannot establish a completed
  // test result. A later attempt must execute again; any earlier real red stays intact.
  if (result.code !== 0 && infrastructureFailure) return result.code ?? 1;
  loadManifest(file, script);
  const receipt = { version: VERSION, manifest_key: manifest.key, context_key: manifest.context_key, group, exit_code: result.code, completed_at_ms: Date.now() };
  if (result.code === 0) {
    atomicJson(receiptFile(file, 'greens', group), { ...receipt, kind: 'green' });
  } else if (!observedRed(file, manifest, group)) {
    atomicJson(receiptFile(file, 'reds', group), { ...receipt, kind: 'observed-red', diagnostic: `${firstFailure}\n${infrastructureFailure}\n${tail}`.trim() });
  }
  return result.code ?? 1;
}

export function completeNightProgress(file, script) {
  const { manifest } = loadManifest(file, script);
  let complete = true;
  for (const group of [...manifest.groups, AUX_GROUP]) {
    const red = observedRed(file, manifest, group);
    if (red) {
      console.error(`not ok - night group ${group} previously exited ${red.exit_code}; fresh baseline/rerun attribution is required\n${red.diagnostic}`);
      complete = false;
    } else if (!greenReceipt(file, manifest, group)) {
      console.error(`not ok - night group ${group} has no current completed green receipt`);
      complete = false;
    }
  }
  return complete ? 0 : 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [operation, ...args] = process.argv.slice(2);
    if (operation === 'policy-key' && args.length === 0) console.log(identityHash(nightProgressPolicy()));
    else if (operation === 'prepare' && args.length >= 3) console.log(prepareNightProgress(args[0], args[1], args.slice(2)));
    else if (operation === 'run' && args.length === 3) process.exitCode = await runNightProgressGroup(...args);
    else if (operation === 'complete' && args.length === 2) process.exitCode = completeNightProgress(...args);
    else throw new Error('Invalid night progress operation');
  } catch (error) {
    console.error(`not ok - night progress: ${localStorageFailureDiagnostic({ error }) ?? error.message}`);
    process.exitCode = 1;
  }
}
