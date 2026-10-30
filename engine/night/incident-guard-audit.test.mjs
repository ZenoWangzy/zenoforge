import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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
