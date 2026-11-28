import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { ciTargetConfig } from './ci-target-config.mjs';

test('resolves CI identity from target config environment aliases', (t) => {
  const configRoot = mkdtempSync(join(tmpdir(), 'zf-ci-target-config-'));
  t.after(() => rmSync(configRoot, { recursive: true, force: true }));
  writeFileSync(join(configRoot, 'config.json'), JSON.stringify({ env_prefix: 'TARGET_' }));

  assert.deepEqual(ciTargetConfig({
    ZF_CONFIG_ROOT: configRoot,
    TARGET_CI_RUNNER_USER: 'build-runner',
    TARGET_CI_SUITES_LANE: 'build-suites',
  }), {
    runnerUser: 'build-runner',
    suitesLane: 'build-suites',
  });
});

test('uses the shipped CI identity defaults without target overrides', () => {
  assert.deepEqual(ciTargetConfig({}), {
    runnerUser: 'vecta-ci',
    suitesLane: 'vecta-suites',
  });
});
