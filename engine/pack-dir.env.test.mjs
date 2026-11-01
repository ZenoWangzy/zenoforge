#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { zfEnv } from './pack-dir.mjs';

const envNames = ['ZF_CONFIG_ROOT', 'ZF_PACK_DIR', 'ZF_REPO_DIR', 'ZF_SAMPLE', 'DEPLOY_SAMPLE'];
const original = new Map(envNames.map((name) => [name, process.env[name]]));
const fixture = mkdtempSync(join(tmpdir(), 'zf-env-'));
const configRoot = join(fixture, '.zenoforge');

function clearFixtureEnv() {
  for (const name of envNames) delete process.env[name];
  process.env.ZF_CONFIG_ROOT = configRoot;
  process.env.ZF_PACK_DIR = '';
}

try {
  clearFixtureEnv();
  assert.equal(zfEnv('SAMPLE', 'engine-default'), 'engine-default', 'no config uses the engine default');
  process.env.ZF_SAMPLE = 'public';
  assert.equal(zfEnv('SAMPLE', 'engine-default'), 'public', 'no config uses the public spelling');

  mkdirSync(configRoot, { recursive: true });
  writeFileSync(join(configRoot, 'config.json'), JSON.stringify({ env_prefix: 'DEPLOY_' }));
  clearFixtureEnv();
  process.env.DEPLOY_SAMPLE = 'deployment';
  process.env.ZF_SAMPLE = 'public';
  assert.equal(zfEnv('SAMPLE', 'engine-default'), 'deployment', 'the configured prefix wins');

  clearFixtureEnv();
  process.env.ZF_SAMPLE = 'public';
  assert.equal(zfEnv('SAMPLE', 'engine-default'), 'public', 'the public spelling is the fallback');
  assert.equal(zfEnv('SAMPLE', 'engine-default', { ZF_CONFIG_ROOT: configRoot, DEPLOY_SAMPLE: 'provided' }), 'provided', 'a supplied environment is resolved too');

  clearFixtureEnv();
  process.env.DEPLOY_SAMPLE = '';
  process.env.ZF_SAMPLE = 'public';
  assert.equal(zfEnv('SAMPLE', 'engine-default'), '', 'a present empty value stays empty');

  const repoEnv = { ZF_REPO_DIR: fixture, DEPLOY_SAMPLE: 'from-product-config', ZF_SAMPLE: 'public' };
  assert.equal(zfEnv('SAMPLE', 'engine-default', repoEnv), 'from-product-config', 'the product config is found from the repo setting');

  console.log('pack-dir.env.test.mjs: PASS');
} finally {
  for (const [name, value] of original) {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
  rmSync(fixture, { recursive: true, force: true });
}
