import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { createNightProgressContext, NIGHT_PROGRESS_CONTEXT_ENV, nightProgressPolicy } from './night-test-progress.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const HELPER = join(HERE, 'night-test-progress.mjs');
const PACK_DIR_MODULE = join(HERE, '../pack-dir.mjs');
const NIGHT_SOURCE = readFileSync(join(HERE, 'night.test.sh'), 'utf8');
const NIGHT_PREFIX = NIGHT_SOURCE.slice(0, NIGHT_SOURCE.indexOf('night_test_group() {'));
assert.ok(NIGHT_PREFIX.includes('night_test_groups+=(hand-dispatch)'), 'fixture executes the real all-group coordinator');
const NIGHT_GROUPS = [...NIGHT_PREFIX.matchAll(/night_test_groups(?:\+)?=\(([^)]*)\)/g)]
  .flatMap((match) => match[1].trim().split(/\s+/).filter(Boolean));
assert.ok(NIGHT_GROUPS.length > 0, 'fixture captures the real ordered group array');
const CHECKPOINT_GROUP = NIGHT_GROUPS[0];
const VERIFIER = 'a'.repeat(64);

function execute(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  assert.equal(result.error, undefined, result.error?.message);
  return result;
}

function git(cwd, ...args) {
  const result = execute('git', args, { cwd });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'night-progress-contract-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const repo = join(root, 'repo');
  const dir = join(repo, 'engine/night');
  const agentDir = join(repo, 'engine');
  mkdirSync(dir, { recursive: true });
  mkdirSync(agentDir, { recursive: true });
  copyFileSync(HELPER, join(dir, 'night-test-progress.mjs'));
  copyFileSync(PACK_DIR_MODULE, join(agentDir, 'pack-dir.mjs'));
  writeFileSync(join(repo, 'engine/test-env.sh'), [
    // Match the real bootstrap purge; the owner context must survive without a whitelist.
    'printf "%s\\t%s\\t%s\\n" "${NIGHT_TEST_GROUP:-all}" "${NIGHT_TEST_PROGRESS_CONTEXT-absent}" "${ZF_NIGHT_TEST_PROGRESS_CONTEXT-absent}" >> "$TEST_BOOTSTRAP_LOG"',
    'while IFS= read -r name; do',
    '  case "$name" in AGENT_*|ZF_*) unset "$name" ;; esac',
    'done < <(compgen -e)',
    'test_env_root="$(mktemp -d "$TEST_ROOT/runtime.XXXXXX")"',
    'test_host_home="$TEST_ROOT/home"',
    'mkdir -p "$test_host_home"',
  ].join('\n'));
  const groupBody = [
    'printf "%s\\n" "$group" >> "$TEST_CALLS"',
    'if [[ "$group" != main-ci-recovery ]]; then',
    '  [[ -z "${NIGHT_TEST_PROGRESS_CONTEXT:-}" && -z "${ZF_NIGHT_TEST_PROGRESS_CONTEXT:-}" && -z "${NIGHT_TEST_CASE:-}" ]] || exit 91',
    '  [[ -d "$NIGHT_TEST_SEED_FIXTURE" ]] || exit 92',
    'fi',
    'if [[ "$group" == "${TEST_FAIL_GROUP:-}" && -f "$TEST_FAIL_FILE" ]]; then',
    '  printf "not ok - planned real red group=%s ordinary assertion diagnostic retained\\n" "$group" >&2',
    '  exit 7',
    'fi',
    'if [[ "$group" == "${TEST_STORAGE_GROUP:-}" && -f "$TEST_STORAGE_FILE" ]]; then',
    '  printf "%s\\n" "$TEST_STORAGE_DIAGNOSTIC" >&2',
    '  exit 1',
    'fi',
    'if [[ "$group" == "${TEST_BLOCK_GROUP:-}" ]]; then',
    '  trap "exit 0" TERM',
    '  printf "%s\\n" "$BASHPID" > "$TEST_BLOCK_PID"',
    '  printf "checkpoint-fixture blocked=%s\\n" "$group"',
    '  read -r released < "$TEST_FIFO"',
    'fi',
    'printf "checkpoint-fixture completed=%s\\n" "$group"',
  ].join('\n');
  const nightFixture = NIGHT_SOURCE.replace(
    'if night_test_group night-seed; then\n  mkdir -p -- "${NIGHT_TEST_SEED_FIXTURE:?}"\n  exit 0\nfi',
    'if night_test_group night-seed; then\n  printf "seed\\n" >> "$TEST_SEEDS"\n  mkdir -p -- "${NIGHT_TEST_SEED_FIXTURE:?}"\n  exit 0\nfi',
  );
  writeFileSync(join(dir, 'night.test.sh'), nightFixture);
  writeFileSync(join(dir, 'hand-owned-issues.test.sh'), `#!/usr/bin/env bash\nset -euo pipefail\ngroup=hand-owned-issues\n${groupBody}\n`);
  writeFileSync(join(dir, 'hand-handoff-chain.test.sh'), `#!/usr/bin/env bash\nset -euo pipefail\ngroup=merge-handoff\n${groupBody}\n`);
  writeFileSync(join(agentDir, 'dispatch-codex.test.sh'), '#!/usr/bin/env bash\nset -euo pipefail\n');
  writeFileSync(join(agentDir, 'dispatch-load-guard.test.sh'), `#!/usr/bin/env bash\nset -euo pipefail\ngroup=hand-dispatch\n${groupBody}\n`);
  writeFileSync(join(dir, 'main-ci-recovery.test.sh'), `#!/usr/bin/env bash\nset -euo pipefail\n[[ -z "\${NIGHT_TEST_GROUP:-}" && -z "\${NIGHT_TEST_PROGRESS_CONTEXT:-}" && -z "\${ZF_NIGHT_TEST_PROGRESS_CONTEXT:-}" && -z "\${night_test_progress_context:-}" ]] || exit 93\ngroup=main-ci-recovery\n${groupBody}\n`);
  git(repo, 'init', '-q');
  git(repo, 'config', 'user.email', 'fixture@example.invalid');
  git(repo, 'config', 'user.name', 'Fixture');
  git(repo, 'add', '.');
  git(repo, 'commit', '-qm', 'fixture');
  const head = git(repo, 'rev-parse', 'HEAD');
  const env = { ...process.env, TEST_ROOT: root, TEST_CALLS: join(root, 'calls'), TEST_SEEDS: join(root, 'seeds'), TEST_BOOTSTRAP_LOG: join(root, 'bootstrap.tsv'), TEST_FAIL_FILE: join(root, 'red'), TEST_STORAGE_FILE: join(root, 'storage-exhausted'), TEST_FIFO: join(root, 'hold'), TEST_BLOCK_PID: join(root, 'blocked.pid'), NIGHT_TEST_JOBS: '1' };
  for (const name of ['NIGHT_TEST_GROUP', 'NIGHT_TEST_CASE', 'NIGHT_TEST_SEED_FIXTURE', NIGHT_PROGRESS_CONTEXT_ENV, 'ZF_NIGHT_TEST_PROGRESS_CONTEXT', 'ZF_CONFIG_ROOT', 'ZF_PACK_DIR', 'ZF_REPO_DIR', 'night_test_progress_context', 'NODE_TEST_CONTEXT', 'NODE_OPTIONS']) delete env[name];
  assert.equal(execute('mkfifo', [env.TEST_FIFO]).status, 0);
  const progress = join(root, 'progress');
  const options = { root: progress, repoRoot: repo, head, baseline: head, verifierKey: VERIFIER, policy: nightProgressPolicy(env) };
  const context = createNightProgressContext(options);
  return { root, repo, dir, head, env, context, options, script: join(dir, 'night.test.sh'), helper: join(dir, 'night-test-progress.mjs') };
}

function all(f, overrides = {}, checkpoint = true) {
  return execute('bash', [f.script], { cwd: f.repo, env: { ...f.env, ...(checkpoint ? { [NIGHT_PROGRESS_CONTEXT_ENV]: f.context } : {}), ...overrides } });
}

function helper(f, operation, ...args) {
  return execute(process.execPath, [f.helper, operation, ...args], { cwd: f.repo, env: f.env });
}

function manifest(f) {
  const manifests = join(dirname(f.context), 'manifests');
  const dirs = readdirSync(manifests);
  assert.equal(dirs.length, 1);
  return join(manifests, dirs[0], 'manifest.json');
}

function calls(f, group) {
  const names = existsSync(f.env.TEST_CALLS) ? readFileSync(f.env.TEST_CALLS, 'utf8').trim().split('\n') : [];
  return group ? names.filter((name) => name === group).length : names;
}

function startBlocked(f, overrides = {}) {
  const child = spawn('bash', [f.script], { cwd: f.repo, detached: true, env: { ...f.env, [NIGHT_PROGRESS_CONTEXT_ENV]: f.context, TEST_BLOCK_GROUP: 'hand-dispatch', ...overrides }, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  let resolveReady;
  let rejectReady;
  const ready = new Promise((resolveResult, rejectResult) => { resolveReady = resolveResult; rejectReady = rejectResult; });
  child.stdout.on('data', (chunk) => { output += chunk; if (output.includes('checkpoint-fixture blocked=hand-dispatch')) resolveReady(); });
  child.stderr.on('data', (chunk) => { output += chunk; });
  const closed = new Promise((resolveResult, rejectResult) => {
    child.once('error', rejectResult);
    child.once('close', (status, signal) => { rejectReady(new Error(`coordinator exited before block: ${status}/${signal}\n${output}`)); resolveResult({ status, signal, output }); });
  });
  return { child, ready, closed };
}

async function interrupt(run) {
  await run.ready;
  process.kill(-run.child.pid, 'SIGTERM');
  const result = await run.closed;
  assert.ok(result.status !== 0 || result.signal, result.output);
  return result;
}

test('night progress resumes completed groups after a real slot interruption, with a fresh seed and mandatory aux', { timeout: 20000 }, async (t) => {
  const f = fixture(t);
  const run = startBlocked(f);
  t.after(() => { try { process.kill(-run.child.pid, 'SIGKILL'); } catch {} });
  await interrupt(run);
  assert.throws(() => process.kill(Number(readFileSync(f.env.TEST_BLOCK_PID, 'utf8')), 0), { code: 'ESRCH' }, 'session cleanup reaps the blocked real child');
  const file = manifest(f);
  const doc = JSON.parse(readFileSync(file, 'utf8'));
  assert.deepEqual(doc.groups, NIGHT_GROUPS);
  assert.equal(calls(f, CHECKPOINT_GROUP), 1);
  assert.equal(existsSync(join(dirname(file), `greens/${CHECKPOINT_GROUP}.json`)), true);
  assert.equal(existsSync(join(dirname(file), 'greens/hand-dispatch.json')), false, 'TERM-exit-0 is not a completed green');
  const resumed = all(f);
  assert.equal(resumed.status, 0, `${resumed.stdout}\n${resumed.stderr}`);
  assert.match(resumed.stdout, /night\.test\.sh: PASS/);
  assert.ok(resumed.stdout.includes(`Night group reused: ${CHECKPOINT_GROUP}`));
  assert.equal(calls(f, CHECKPOINT_GROUP), 1);
  assert.equal(calls(f, 'hand-dispatch'), 2);
  for (const group of doc.groups) {
    if (group !== 'hand-dispatch') assert.equal(calls(f, group), 1, group);
  }
  assert.equal(readFileSync(f.env.TEST_SEEDS, 'utf8').trim().split('\n').length, 2);
  const bootstrapCalls = readFileSync(f.env.TEST_BOOTSTRAP_LOG, 'utf8').trim().split('\n').map((line) => line.split('\t'));
  for (const [group, context, legacy] of bootstrapCalls) {
    assert.equal(context, group === 'all' ? f.context : 'absent', `context leaked into ${group} bootstrap`);
    assert.equal(legacy, 'absent', `legacy context leaked into ${group} bootstrap`);
  }
  assert.equal(helper(f, 'complete', file, f.script).status, 0);
  rmSync(join(dirname(file), 'greens/main-ci-recovery.json'));
  const missingAux = helper(f, 'complete', file, f.script);
  assert.equal(missingAux.status, 1);
  assert.match(missingAux.stderr, /main-ci-recovery has no current completed green/);
  assert.equal(helper(f, 'run', file, f.script, 'main-ci-recovery').status, 0);
  assert.equal(helper(f, 'complete', file, f.script).status, 0);
});

test('night progress preserves a real red across interruption and later green executions', { timeout: 20000 }, async (t) => {
  const f = fixture(t);
  writeFileSync(f.env.TEST_FAIL_FILE, 'fail');
  const run = startBlocked(f, { TEST_FAIL_GROUP: 'merge-handoff' });
  t.after(() => { try { process.kill(-run.child.pid, 'SIGKILL'); } catch {} });
  await interrupt(run);
  const file = manifest(f);
  const redFile = join(dirname(file), 'reds/merge-handoff.json');
  const originalRed = readFileSync(redFile, 'utf8');
  assert.equal(JSON.parse(originalRed).exit_code, 7);
  rmSync(f.env.TEST_FAIL_FILE);
  writeFileSync(f.env.TEST_STORAGE_FILE, 'storage failure');
  const storageFailure = all(f, { TEST_STORAGE_GROUP: 'merge-handoff', TEST_STORAGE_DIAGNOSTIC: 'write failed: ENOSPC' });
  assert.notEqual(storageFailure.status, 0, storageFailure.stdout + storageFailure.stderr);
  assert.match(storageFailure.stderr, /write failed: ENOSPC/);
  assert.equal(readFileSync(redFile, 'utf8'), originalRed, 'a later infrastructure error cannot erase an earlier real red');
  assert.equal(existsSync(join(dirname(file), 'greens/merge-handoff.json')), false,
    'storage failure cannot create a completed green');
  rmSync(f.env.TEST_STORAGE_FILE);
  const resumed = all(f);
  assert.equal(resumed.status, 1);
  assert.match(resumed.stderr, /previously exited 7; fresh baseline\/rerun attribution is required/);
  assert.match(resumed.stderr, /ordinary assertion diagnostic retained/);
  assert.doesNotMatch(resumed.stdout, /night\.test\.sh: PASS/);
  assert.equal(calls(f, 'merge-handoff'), 3, 'the red group really reran after both failures');
  assert.equal(existsSync(join(dirname(file), 'greens/merge-handoff.json')), true);
  assert.equal(readFileSync(redFile, 'utf8'), originalRed, 'a later exit 0 never overwrites observed red');
  const fresh = all(f, {}, false);
  assert.equal(fresh.status, 0, fresh.stderr);
  assert.match(fresh.stdout, /night\.test\.sh: PASS/);
  assert.equal(calls(f, 'merge-handoff'), 4, 'fresh attribution executes all groups without checkpoint reuse');
});

for (const diagnostic of ['write failed: ENOSPC', 'mktemp: No space left on device']) {
  test(`night progress retries a failed storage probe without caching it: ${diagnostic}`, { timeout: 20000 }, (t) => {
    const f = fixture(t);
    const group = 'merge-handoff';
    const overrides = { TEST_STORAGE_GROUP: group, TEST_STORAGE_DIAGNOSTIC: diagnostic };
    writeFileSync(f.env.TEST_STORAGE_FILE, 'storage failure');
    const failed = all(f, overrides);
    assert.notEqual(failed.status, 0, failed.stdout + failed.stderr);
    assert.ok(failed.stderr.includes(diagnostic), failed.stderr);
    assert.doesNotMatch(failed.stdout, /night\.test\.sh: PASS/);
    const file = manifest(f);
    const greenFile = join(dirname(file), `greens/${group}.json`);
    const redFile = join(dirname(file), `reds/${group}.json`);
    assert.equal(calls(f, group), 1, 'the failed group really executed');
    assert.equal(existsSync(greenFile), false, 'storage exhaustion is not a completed green');
    assert.equal(existsSync(redFile), false, 'storage exhaustion is not a permanent observed test red');
    const incomplete = helper(f, 'complete', file, f.script);
    assert.equal(incomplete.status, 1);
    assert.match(incomplete.stderr, /merge-handoff has no current completed green receipt/);
    rmSync(f.env.TEST_STORAGE_FILE);
    const recovered = all(f, overrides);
    assert.equal(recovered.status, 0, recovered.stdout + recovered.stderr);
    assert.match(recovered.stdout, /night\.test\.sh: PASS/);
    assert.equal(calls(f, group), 2, 'recovery must execute the incomplete group again');
    assert.equal(JSON.parse(readFileSync(greenFile, 'utf8')).exit_code, 0);
    assert.equal(existsSync(redFile), false);
    const groups = JSON.parse(readFileSync(file, 'utf8')).groups;
    for (const completed of [...groups.filter((name) => name !== group), 'main-ci-recovery']) {
      assert.equal(calls(f, completed), 1, 'only previously completed greens can be reused');
    }
    assert.equal(helper(f, 'complete', file, f.script).status, 0);
  });
}

test('night progress rejects malformed, nonzero, mismatched, expired and future green receipts', { timeout: 20000 }, (t) => {
  const f = fixture(t);
  assert.equal(all(f).status, 0);
  const file = manifest(f);
  const group = 'merge-handoff';
  const receipt = join(dirname(file), `greens/${group}.json`);
  const original = JSON.parse(readFileSync(receipt, 'utf8'));
  const seed = join(f.root, 'manual-seed');
  mkdirSync(seed);
  f.env.NIGHT_TEST_SEED_FIXTURE = seed;
  const variants = [
    '{broken',
    JSON.stringify({ ...original, exit_code: 7 }),
    JSON.stringify({ ...original, context_key: 'b'.repeat(64) }),
    JSON.stringify({ ...original, completed_at_ms: 0 }),
    JSON.stringify({ ...original, completed_at_ms: Date.now() + 86400000 }),
  ];
  for (const [index, value] of variants.entries()) {
    writeFileSync(receipt, value);
    assert.equal(helper(f, 'run', file, f.script, group).status, 0);
    assert.equal(calls(f, group), index + 2, 'invalid receipt requires real execution');
    assert.equal(JSON.parse(readFileSync(receipt, 'utf8')).exit_code, 0);
  }
  writeFileSync(join(dirname(file), 'greens/unknown-group.json'), JSON.stringify(original));
  const unknown = helper(f, 'run', file, f.script, 'unknown-group');
  assert.equal(unknown.status, 1);
  assert.match(unknown.stderr, /Unknown night progress group/);
  assert.equal(calls(f, 'unknown-group'), 0);
  const knownCount = calls(f, group);
  assert.equal(helper(f, 'run', file, f.script, group).status, 0);
  assert.equal(calls(f, group), knownCount, 'a valid current green is reused');
  writeFileSync(join(dirname(file), `reds/${group}.json`), '{broken');
  const malformedRed = helper(f, 'complete', file, f.script);
  assert.equal(malformedRed.status, 1);
  assert.match(malformedRed.stderr, /corrupt observed-red record/);
  rmSync(join(dirname(file), `reds/${group}.json`));
  symlinkSync(join(f.root, 'missing-red-target'), join(dirname(file), `reds/${group}.json`));
  assert.equal(helper(f, 'complete', file, f.script).status, 1, 'a dangling failure record cannot be treated as absent');
});

test('night progress binds HEAD, base, verifier, policy, manifest and source while excluding remaining budget', { timeout: 20000 }, (t) => {
  const f = fixture(t);
  assert.equal(all(f).status, 0);
  const file = manifest(f);
  const groups = JSON.parse(readFileSync(file, 'utf8')).groups;
  assert.equal(createNightProgressContext({ ...f.options, policy: nightProgressPolicy({ ...f.env, ZF_FOCUSED_SUITE_TIMEOUT_SECONDS: '1' }) }), f.context);
  const contexts = [
    { baseline: 'b'.repeat(40) },
    { verifierKey: 'b'.repeat(64) },
    { policy: nightProgressPolicy({ ...f.env, NIGHT_TEST_JOBS: '2' }) },
    { policy: nightProgressPolicy({ ...f.env, ZF_POST_LAND_SLOT_TIMEOUT_SECONDS: '3600' }) },
  ].map((changed) => createNightProgressContext({ ...f.options, ...changed }));
  for (const context of contexts) {
    assert.notEqual(context, f.context);
    const prepared = helper(f, 'prepare', context, f.script, ...groups);
    assert.equal(prepared.status, 0, prepared.stderr);
    const completed = helper(f, 'complete', prepared.stdout.trim(), f.script);
    assert.equal(completed.status, 1, 'another context cannot borrow green receipts');
  }
  const changedManifest = helper(f, 'prepare', f.context, f.script, ...groups.slice().reverse());
  assert.equal(changedManifest.status, 0);
  assert.notEqual(changedManifest.stdout.trim(), file);
  assert.equal(helper(f, 'complete', changedManifest.stdout.trim(), f.script).status, 1);
  writeFileSync(join(f.repo, 'changed.txt'), 'new HEAD');
  git(f.repo, 'add', '.');
  git(f.repo, 'commit', '-qm', 'advance');
  assert.equal(helper(f, 'prepare', f.context, f.script, ...groups).status, 1);
  assert.equal(helper(f, 'complete', file, f.script).status, 1, 'completion checks the current HEAD as well');
  const changedHead = createNightProgressContext({ ...f.options, head: git(f.repo, 'rev-parse', 'HEAD') });
  assert.notEqual(changedHead, f.context);
  assert.equal(helper(f, 'prepare', changedHead, f.script, ...groups).status, 0);
  writeFileSync(f.script, `${readFileSync(f.script, 'utf8')}\n# source changed\n`);
  const changedSource = helper(f, 'prepare', changedHead, f.script, ...groups);
  assert.equal(changedSource.status, 1);
  assert.match(changedSource.stderr, /source changed/);
});

test('night progress is absent from ordinary full-suite runs and unknown selectors cannot report a pass', { timeout: 20000 }, (t) => {
  const f = fixture(t);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const result = all(f, {}, false);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /night\.test\.sh: PASS/);
  }
  const expectedCalls = 2 * (NIGHT_GROUPS.length + 1);
  assert.equal(calls(f).length, expectedCalls);
  assert.equal(calls(f, 'main-ci-recovery'), 2);
  assert.equal(existsSync(join(dirname(f.context), 'manifests')), false);
  const unknown = all(f, { NIGHT_TEST_GROUP: 'unknown-group' }, false);
  assert.equal(unknown.status, 2);
  assert.match(unknown.stderr, /Unknown NIGHT_TEST_GROUP/);
  assert.equal(calls(f).length, expectedCalls);
});

test('night progress context survives the real bootstrap without leaking into child environments', (t) => {
  const f = fixture(t);
  for (const name of ['test-env.sh', 'model-policy.default.json']) {
    copyFileSync(join(HERE, '..', name), join(f.repo, 'engine', name));
  }
  const headerEnd = NIGHT_PREFIX.indexOf('# Resolve the runtime used by the progress helper.');
  assert.ok(headerEnd > 0, 'coordinator bootstrap header must precede its node setup');
  const header = NIGHT_PREFIX.slice(0, headerEnd);
  const groupDefinitions = NIGHT_PREFIX.match(/^night_test_groups=.*\nnight_test_groups\+=.*$/m)?.[0];
  assert.ok(groupDefinitions, 'bootstrap probe uses the actual ordered group array');
  const probe = join(f.dir, 'bootstrap-context.test.sh');
  const manifestOut = join(f.root, 'bootstrap-manifest');
  writeFileSync(probe, `${header}\n${[
    'trap \'rm -rf -- "$test_env_root"\' EXIT',
    '[[ "${ZF_AGENT_TEST_MODE:-}" == 1 && -n "${MODEL_POLICY_TEST_WORK_MODEL:-}" ]]',
    '[[ -z "${AGENT_BOOTSTRAP_SENTINEL+x}" && -z "${ZF_BOOTSTRAP_SENTINEL+x}" ]]',
    '[[ "$night_test_progress_context" == "$TEST_EXPECTED_CONTEXT" ]]',
    '[[ -z "${NIGHT_TEST_PROGRESS_CONTEXT+x}" && -z "${ZF_NIGHT_TEST_PROGRESS_CONTEXT+x}" ]]',
    '"$TEST_NODE" -e \'for (const key of ["NIGHT_TEST_PROGRESS_CONTEXT", "ZF_NIGHT_TEST_PROGRESS_CONTEXT", "night_test_progress_context"]) if (Object.hasOwn(process.env, key)) process.exit(81)\'',
    groupDefinitions,
    '"$TEST_NODE" "$TEST_HELPER" prepare "$night_test_progress_context" "$TEST_NIGHT_SCRIPT" "${night_test_groups[@]}" > "$TEST_MANIFEST_OUT"',
    '',
  ].join('\n')}`);
  const bootstrapGate = execute('bash', [join(HERE, '../test-bootstrap-check.sh'), f.script, probe]);
  assert.equal(bootstrapGate.status, 0, bootstrapGate.stdout + bootstrapGate.stderr);
  git(f.repo, 'add', '.');
  git(f.repo, 'commit', '-qm', 'actual bootstrap context fixture');
  const head = git(f.repo, 'rev-parse', 'HEAD');
  const context = createNightProgressContext({ ...f.options, head, baseline: head });
  const result = execute('bash', [probe], { cwd: f.repo, env: { ...f.env,
    [NIGHT_PROGRESS_CONTEXT_ENV]: context,
    ZF_NIGHT_TEST_PROGRESS_CONTEXT: '/untrusted-legacy-context.json',
    night_test_progress_context: '/untrusted-exported-private-name',
    AGENT_BOOTSTRAP_SENTINEL: 'must-clear', ZF_BOOTSTRAP_SENTINEL: 'must-clear',
    TEST_EXPECTED_CONTEXT: context, TEST_NODE: process.execPath, TEST_HELPER: f.helper,
    TEST_NIGHT_SCRIPT: f.script, TEST_MANIFEST_OUT: manifestOut,
  } });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const file = readFileSync(manifestOut, 'utf8').trim();
  const doc = JSON.parse(readFileSync(file, 'utf8'));
  assert.deepEqual(doc.groups, NIGHT_GROUPS, 'actual bootstrap preserves the real ordered group manifest');
  assert.equal(doc.context_key, JSON.parse(readFileSync(context, 'utf8')).key);
  assert.equal(calls(f).length, 0, 'this bootstrap contract does not substitute diagnostic groups for validation');
  assert.equal(helper(f, 'complete', file, f.script).status, 1, 'bootstrap alone is never a green suite');
});
