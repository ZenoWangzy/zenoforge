import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import {
  focusedTestPaths,
  remoteScript,
  runDeterministicRegressionGate,
} from './ci-toolchain-preflight.mjs';

test('the mirrored runner creates a writable Git index before tests that inspect tracked modes', () => {
  const script = remoteScript(
    ['engine/lib.sh'],
    ['engine/lib.test.sh'],
  );
  const init = script.indexOf('git init -q');
  const add = script.indexOf('git add --all');
  const commit = script.indexOf('toolchain preflight snapshot');
  const test = script.indexOf('engine/lib.test.sh');

  assert.ok(init >= 0);
  assert.ok(add > init);
  assert.ok(commit > add);
  assert.ok(test > commit);
});

test('selects changed pipeline script tests, including non-sibling test owners', () => {
  const tracked = new Set([
    'engine/dispatch-load-guard.test.sh',
    'engine/night/night.test.sh',
    'engine/ci-toolchain-preflight.test.mjs',
  ]);
  assert.deepEqual(focusedTestPaths([
    'engine/dispatch-load-guard.sh',
    'engine/night/dispatch.sh',
    'engine/night/node-health.sh',
    'engine/night/node-health-rules.sh',
    'engine/ci-toolchain-preflight.mjs',
    'engine/ci-toolchain-preflight.test.mjs',
  ], tracked), [
    'engine/ci-toolchain-preflight.test.mjs',
    'engine/dispatch-load-guard.test.sh',
    'engine/night/night.test.sh',
  ]);
});

test('selects the GitNexus wrapper test for its installer', () => {
  assert.deepEqual(focusedTestPaths([
    'engine/install-gitnexus-wrapper.sh',
  ], new Set(['engine/gitnexus-wrapper.test.sh'])), [
    'engine/gitnexus-wrapper.test.sh',
  ]);
});

test('selects policy tests for delivery preflight changes', () => {
  assert.deepEqual(focusedTestPaths([
    'scripts/branch-delivery-preflight.mjs',
  ], new Set(['scripts/branch-delivery-preflight.test.mjs'])), [
    'scripts/branch-delivery-preflight.test.mjs',
  ]);
});

test('runs available incident tests when mapped suite did not exist at target revision', () => {
  // The tracked suite that still names the script lives in a fixture, so deleting wording
  // checks from the real suite (f69db91ee) cannot remove the coverage this case relies on.
  const fixture = mkdtempSync(join(tmpdir(), 'zf-focused-unmapped-'));
  try {
    mkdirSync(join(fixture, 'engine'), { recursive: true });
    writeFileSync(join(fixture, 'engine/dispatch-load-guard.test.sh'), 'bash "$SCRIPT_DIR/night/dispatch.sh" --check\n');
    assert.deepEqual(focusedTestPaths([
      'engine/night/dispatch.sh',
      'engine/dispatch-load-guard.sh',
    ], new Set(['engine/dispatch-load-guard.test.sh']), { cwd: fixture }), [
      'engine/dispatch-load-guard.test.sh',
    ]);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});

test('fails closed when changed pipeline script has no focused test', () => {
  assert.throws(() => focusedTestPaths([
    'engine/new-guard.sh',
  ], new Set()), /No focused test exists/);
});
