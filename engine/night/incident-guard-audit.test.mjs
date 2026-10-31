import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const auditScript = path.join(repoRoot, 'engine/night/incident-guard-audit.mjs');

test('guard audit reports historical drift, missing targets, and duplicate checks', (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'incident-guard-audit-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const repo = path.join(root, 'repo');
  const history = path.join(root, 'history');
  const state = path.join(repo, 'engine/state');
  const sourceDir = path.join(repo, 'engine');
  mkdirSync(state, { recursive: true });
  mkdirSync(path.join(repo, '.github/workflows'), { recursive: true });
  mkdirSync(history, { recursive: true });
  writeFileSync(path.join(sourceDir, 'present.test.mjs'), '');
  writeFileSync(path.join(sourceDir, 'source.mjs'), 'export function currentSymbol() {}\n');

  const duplicatedCheck = {
    command: ['node', '${REPO_DIR}/engine/present.test.mjs'],
    expected: 'exit:0',
    test_file: '${REPO_DIR}/engine/present.test.mjs',
    why: 'Same focused regression protects same incident.',
  };
  const guard = (id, machineChecks, className = id, whatHappened = `${id} happened`) => ({
    id,
    class: className,
    what_happened: whatHappened,
    machine_checks: machineChecks,
  });
  writeFileSync(path.join(state, 'incident-guards.json'), JSON.stringify({ incidents: [
    guard('stable-guard', [duplicatedCheck]),
    guard('drifted-guard', [duplicatedCheck]),
    guard('missing-file-guard', [{
      command: ['node', '${REPO_DIR}/engine/deleted.test.mjs'],
      expected: 'exit:0',
      test_file: '${REPO_DIR}/engine/deleted.test.mjs',
      why: 'Deleted test remains named.',
    }]),
    guard('missing-symbol-guard', [{
      command: ['bash', '-c', "grep -Fq 'removedSymbol' \"${REPO_DIR}/engine/source.mjs\""],
      expected: 'exit:0',
      test_file: '${REPO_DIR}/engine/present.test.mjs',
      why: 'Source symbol remains present.',
    }]),
    guard('missing-hidden-root-guard', [{
      command: ['test', '-f', '${REPO_DIR}/.github/workflows/deleted.yml'],
      expected: 'exit:0',
      test_file: '${REPO_DIR}/.github/workflows/deleted.yml',
      why: 'Workflow file remains present.',
    }]),
    guard('file-target-is-directory', [{
      command: ['test', '-f', '${REPO_DIR}/.github/workflows'],
      expected: 'exit:0',
      test_file: '${REPO_DIR}/.github/workflows',
      why: 'The checked target must stay a file.',
    }]),
    guard('grep-heredoc-guard', [{
      command: ['bash', '-c', 'grep -Fq literalCheck <<<"$content"'],
      expected: 'exit:0',
      test_file: '${REPO_DIR}/engine/present.test.mjs',
      why: 'Here-string grep consumes generated content.',
    }]),
    guard('conditional-grep-guard', [{
      command: ['bash', '-c', 'if test -f "${REPO_DIR}/engine/source.mjs"; then grep -Fq absentFromSource "${REPO_DIR}/engine/source.mjs"; else grep -Fq inactiveBranch "${REPO_DIR}/engine/source.mjs"; fi'],
      expected: 'exit:0',
      test_file: '${REPO_DIR}/engine/present.test.mjs',
      why: 'Only the active shell branch is checked.',
    }]),
    guard('binary-command-guard', [{
      command: ['${REPO_DIR}/node_modules/.bin/vitest', 'run', '${REPO_DIR}/engine/present.test.mjs'],
      expected: 'exit:0',
      test_file: '${REPO_DIR}/engine/present.test.mjs',
      why: 'The package binary is environment tooling, not checked source.',
    }]),
    guard('negative-file-check', [{
      command: ['bash', '-c', 'test ! -f "${REPO_DIR}/engine/expected-absent.mjs"'],
      expected: 'exit:0',
      test_file: '${REPO_DIR}/engine/present.test.mjs',
      why: 'The absent file is the asserted condition.',
    }]),
    guard('duplicate-a', [duplicatedCheck], 'duplicate class', 'same failure'),
    guard('duplicate-b', [duplicatedCheck], 'duplicate class', 'same failure'),
    guard('near-a', [duplicatedCheck], 'approval failure', 'approval step is missing'),
    guard('near-b', [duplicatedCheck], 'approval failures', 'approval step is missing'),
    guard('argv-boundary-a', [{
      ...duplicatedCheck,
      command: ['node', '${REPO_DIR}/engine/present.test.mjs', 'alpha beta'],
    }], 'argv boundary', 'same failure'),
    guard('argv-boundary-b', [{
      ...duplicatedCheck,
      command: ['node', '${REPO_DIR}/engine/present.test.mjs', 'alpha', 'beta'],
    }], 'argv boundary', 'same failure'),
  ] }, null, 2));
  writeFileSync(path.join(history, 'rulings-progress-20261001T000000.log'), [
    'CHECKED incident-guard:stable-guard',
    'CHECKED incident-guard:drifted-guard',
    'CHECKED incident-guard:missing-file-guard',
    'CHECKED incident-guard:missing-symbol-guard',
    'CHECKED incident-guard:missing-hidden-root-guard',
    'CHECKED incident-guard:duplicate-a',
  ].join('\n'));
  writeFileSync(path.join(history, 'rulings-progress-20261002T000000.log'), [
    'DRIFT incident-guard:drifted-guard command changed',
    'CHECKED incident-guard:duplicate-b',
  ].join('\n'));
  const recentStamp = new Date().toISOString().replace(/[-:.Z]/g, '');
  writeFileSync(path.join(history, `rulings-progress-${recentStamp.slice(0, 8)}T${recentStamp.slice(9)}-${process.pid}.log`),
    'DRIFT incident-guard:stable-guard still running\n');
  writeFileSync(path.join(history, 'unrelated.log'), 'DRIFT incident-guard:stable-guard\n');

  const outputPath = path.join(root, 'audit.json');
  const result = spawnSync(process.execPath, [auditScript, '--repo', repo, '--history-dir', history, '--output', outputPath], {
    encoding: 'utf8',
    env: {
      ...process.env,
      ZF_REPO_DIR: repo,
      ZF_ENGINE_DIR: path.join(repo, 'engine'),
      ZF_CONFIG_ROOT: path.join(repo, '.zenoforge'),
      ZF_PACK_DIR: '',
    },
  });
  assert.equal(result.status, 0, result.stderr);
  const audit = JSON.parse(result.stdout);
  assert.equal(audit.history.files, 2);
  assert.equal(audit.history.inProgressFiles, 1);
  assert.equal(audit.history.firstFile, 'rulings-progress-20261001T000000.log');
  assert.equal(audit.history.lastFile, 'rulings-progress-20261002T000000.log');
  assert.equal(audit.history.observations, 8);
  assert.equal(audit.history.checked, 7);
  assert.equal(audit.history.drifted, 1);
  assert.equal(audit.history.errors, 0);
  assert.deepEqual(audit.neverDrifted, [
    'duplicate-a', 'duplicate-b', 'missing-file-guard', 'missing-hidden-root-guard', 'missing-symbol-guard', 'stable-guard',
  ]);
  assert.deepEqual(audit.missingTargets, [
    { id: 'file-target-is-directory', targets: [{ kind: 'file', target: '.github/workflows' }] },
    { id: 'missing-file-guard', targets: [{ kind: 'file', target: 'engine/deleted.test.mjs' }] },
    { id: 'missing-hidden-root-guard', targets: [{ kind: 'file', target: '.github/workflows/deleted.yml' }] },
    { id: 'missing-symbol-guard', targets: [{ kind: 'symbol', target: 'engine/source.mjs#removedSymbol' }] },
  ]);
  assert.deepEqual(audit.nearDuplicates, [
    { kind: 'exact', guards: ['duplicate-a', 'duplicate-b'] },
    { kind: 'near', guards: ['near-a', 'near-b'] },
  ]);
  assert.deepEqual(JSON.parse(readFileSync(outputPath, 'utf8')), audit);
});

test('with a pack, the registry comes from the engine build and targets resolve against --repo, then the build', (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'incident-guard-audit-pack-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const repo = path.join(root, 'repo');
  const packRoot = path.join(root, 'version');
  const history = path.join(root, 'history');
  // The target repo has no scripts/agent (the pipeline moved out); the engine build's version root has it.
  mkdirSync(path.join(packRoot, 'scripts/agent/state'), { recursive: true });
  mkdirSync(path.join(repo, 'engine/state'), { recursive: true });
  mkdirSync(path.join(repo, '.zenoforge/state'), { recursive: true });
  mkdirSync(history, { recursive: true });
  writeFileSync(path.join(packRoot, 'scripts/agent/fixture.test.sh'), '');
  mkdirSync(path.join(packRoot, 'engine'), { recursive: true });
  writeFileSync(path.join(packRoot, 'engine/built.test.sh'), '');
  writeFileSync(path.join(repo, 'plain.test.sh'), '');
  const registry = JSON.stringify({ incidents: [
    { id: 'pack-test-file', machine_checks: [{ test_file: 'scripts/agent/fixture.test.sh' }] },
    { id: 'pack-command-file', machine_checks: [{ command: ['bash', '${REPO_DIR}/scripts/agent/fixture.test.sh'] }] },
    { id: 'pack-missing-file', machine_checks: [{ test_file: 'scripts/agent/missing.test.sh' }] },
    { id: 'repo-test-file', machine_checks: [{ test_file: 'plain.test.sh' }] },
    { id: 'built-command-file', machine_checks: [{ command: ['bash', '${REPO_DIR}/engine/built.test.sh'] }] },
  ] });
  writeFileSync(path.join(packRoot, 'scripts/agent/state/incident-guards.json'), registry);
  writeFileSync(path.join(repo, 'engine/state/incident-guards.json'), registry);
  writeFileSync(path.join(repo, '.zenoforge/state/incident-guards.json'), JSON.stringify({ incidents: [
    { id: 'config-only-file', machine_checks: [{ test_file: 'config/missing.test.sh' }] },
  ] }));
  const run = (env) => spawnSync(process.execPath, [auditScript, '--repo', repo, '--history-dir', history],
    { encoding: 'utf8', env: {
      ...process.env,
      ZF_REPO_DIR: repo,
      ZF_ENGINE_DIR: path.join(repo, 'engine'),
      ZF_CONFIG_ROOT: path.join(repo, '.zenoforge'),
      ZF_PACK_DIR: '',
      ZF_PACK_REL: '',
      ZF_PACK_ROOT: '',
      ...env,
    } });

  const config = run({ ZF_PACK_REL: 'scripts/agent', ZF_PACK_ROOT: packRoot,
    ZF_PACK_DIR: path.join(packRoot, 'scripts/agent') });
  assert.equal(config.status, 0, config.stderr);
  assert.deepEqual(JSON.parse(config.stdout).missingTargets, [
    { id: 'config-only-file', targets: [{ kind: 'file', target: 'config/missing.test.sh' }] },
  ]);
  unlinkSync(path.join(repo, '.zenoforge/state/incident-guards.json'));

  const pack = run({ ZF_PACK_REL: 'scripts/agent', ZF_PACK_ROOT: packRoot,
    ZF_PACK_DIR: path.join(packRoot, 'scripts/agent') });
  assert.equal(pack.status, 0, pack.stderr);
  assert.deepEqual(JSON.parse(pack.stdout).missingTargets, [
    { id: 'pack-missing-file', targets: [{ kind: 'file', target: 'scripts/agent/missing.test.sh' }] },
  ]);

  // Without a pack nothing changes: the registry is read from the repo and pack-prefixed targets are missing there.
  const plain = run({});
  assert.equal(plain.status, 0, plain.stderr);
  assert.deepEqual(JSON.parse(plain.stdout).missingTargets.map((entry) => entry.id).sort(),
    ['built-command-file', 'pack-command-file', 'pack-missing-file', 'pack-test-file']);
});

test('guard targets resolve through the target repo after the repo and build miss', () => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'incident-guard-audit-target-repo-'));
  const repo = path.join(root, 'repo');
  const buildRoot = path.join(root, 'build');
  const targetRepo = path.join(root, 'target-repo');
  const history = path.join(root, 'history');
  const state = path.join(buildRoot, 'engine/state');
  mkdirSync(state, { recursive: true });
  mkdirSync(history, { recursive: true });
  mkdirSync(path.join(buildRoot, 'engine'), { recursive: true });
  mkdirSync(path.join(targetRepo, 'ops/host-units'), { recursive: true });
  mkdirSync(path.join(targetRepo, 'engine'), { recursive: true });
  writeFileSync(path.join(targetRepo, 'ops/host-units/target-only.test.py'), '');
  writeFileSync(path.join(targetRepo, 'ops/host-units/symbol-only.sh'), 'targetRepoSymbol\n');
  writeFileSync(path.join(buildRoot, 'engine/source.mjs'), 'differentBuildSymbol\n');
  writeFileSync(path.join(targetRepo, 'engine/source.mjs'), 'buildSymbol\n');
  writeFileSync(path.join(state, 'incident-guards.json'), JSON.stringify({ incidents: [
    { id: 'target-repo-file', machine_checks: [{ test_file: '${REPO_DIR}/ops/host-units/target-only.test.py' }] },
    { id: 'missing-in-both', machine_checks: [{ test_file: '${REPO_DIR}/ops/host-units/missing.test.sh' }] },
    { id: 'target-repo-symbol', machine_checks: [{
      command: ['bash', '-c', "grep -Fq 'targetRepoSymbol' \"${REPO_DIR}/ops/host-units/symbol-only.sh\""],
    }] },
    { id: 'build-symbol-is-checked', machine_checks: [{
      command: ['bash', '-c', "grep -Fq 'buildSymbol' \"${REPO_DIR}/engine/source.mjs\""],
    }] },
  ] }));

  const baseEnv = {
    ...process.env,
    ZF_REPO_DIR: targetRepo,
    ZF_ENGINE_DIR: path.join(buildRoot, 'engine'),
    ZF_CONFIG_ROOT: path.join(repo, '.zenoforge'),
    ZF_PACK_DIR: '',
    ZF_PACK_REL: 'engine',
    ZF_PACK_ROOT: buildRoot,
  };
  const run = (args, env = {}) => spawnSync(process.execPath, [auditScript, '--repo', repo,
    '--history-dir', history, ...args], { encoding: 'utf8', env: { ...baseEnv, ...env } });
  const expectedMissing = [
    { id: 'build-symbol-is-checked', targets: [{ kind: 'symbol', target: 'engine/source.mjs#buildSymbol' }] },
    { id: 'missing-in-both', targets: [{ kind: 'file', target: 'ops/host-units/missing.test.sh' }] },
  ];
  const assertMissingTargets = (result, expected = expectedMissing) => {
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout).missingTargets, expected);
  };

  assertMissingTargets(run([]));
  assertMissingTargets(run(['--target-repo', targetRepo], { ZF_REPO_DIR: repo }));

  writeFileSync(path.join(targetRepo, 'ops/host-units/symbol-only.sh'), 'differentTargetRepoSymbol\n');
  assertMissingTargets(run([]), [
    ...expectedMissing,
    { id: 'target-repo-symbol', targets: [{ kind: 'symbol', target: 'ops/host-units/symbol-only.sh#targetRepoSymbol' }] },
  ]);
});
