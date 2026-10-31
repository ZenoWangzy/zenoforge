import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, resolve } from 'node:path';

test('acceptance account references and production URL prefer target night.json over the retained pack', () => {
  mkdirSync(resolve('.scratch'), { recursive: true });
  const dir = mkdtempSync(join(resolve('.scratch'), 'acceptance-config-test-'));
  const configRoot = join(dir, '.zenoforge');
  const packDir = join(dir, 'pack');
  const writeConfig = (root, accountRef, url) => {
    const file = join(root, 'night.json');
    mkdirSync(root, { recursive: true });
    writeFileSync(file, JSON.stringify({ acceptance: { account_ref: [accountRef] },
      production: { urls: { acceptance_login: url } } }));
  };
  try {
    writeConfig(configRoot, 'target-account@example.invalid', 'https://target.invalid/login');
    writeConfig(packDir, 'pack-account@example.invalid', 'https://pack.invalid/login');
    const script = "import { loadAcceptanceSettings } from './engine/night/acceptance-login-probe.mjs'; console.log(JSON.stringify(loadAcceptanceSettings()));";
    const child = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      cwd: resolve('.'), encoding: 'utf8',
      env: { ...process.env, ZF_CONFIG_ROOT: configRoot, ZF_PACK_DIR: packDir },
    });
    assert.equal(child.status, 0, child.stderr);
    const settings = JSON.parse(child.stdout);
    assert.deepEqual(settings.accountRefs, ['target-account@example.invalid']);
    assert.equal(settings.loginUrl, 'https://target.invalid/login');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('acceptance credential wrapper environment name comes from night.json', async () => {
  const { loadAcceptanceSettings } = await import('./acceptance-login-probe.mjs');
  mkdirSync(resolve('.scratch'), { recursive: true });
  const configRoot = mkdtempSync(join(resolve('.scratch'), 'acceptance-credentials-test-'));
  try {
    writeFileSync(join(configRoot, 'night.json'), JSON.stringify({
      acceptance: { account_ref: ['target-account@example.invalid'] },
      production: { urls: { acceptance_login: 'https://target.invalid/login' } },
      credentials: { wrapper_env_name: 'TEST_CREDENTIAL_WRAPPER' },
    }));
    const child = spawnSync(process.execPath, ['--input-type=module', '-e',
      "import { loadAcceptanceSettings } from './engine/night/acceptance-login-probe.mjs'; console.log(JSON.stringify(loadAcceptanceSettings()));"], {
      cwd: resolve('.'), encoding: 'utf8',
      env: { ...process.env, ZF_CONFIG_ROOT: configRoot, ZF_PACK_DIR: '' },
    });
    assert.equal(child.status, 0, child.stderr);
    const settings = JSON.parse(child.stdout);
    assert.equal(settings.wrapperEnvName, 'TEST_CREDENTIAL_WRAPPER');
  } finally { rmSync(configRoot, { recursive: true, force: true }); }
});

test('demo account checks keep using the configured credential wrapper contract', async () => {
  const { loginDemoAccount } = await import('./acceptance-login-probe.mjs');
  const settings = {
    wrapperEnvName: 'TEST_CREDENTIAL_WRAPPER',
    childAccountRefEnvName: 'TEST_ACCOUNT_REF',
    childPasswordEnvName: 'TEST_ACCOUNT_PASSWORD',
    accountRefs: ['primary@example.invalid'],
  };
  process.env.TEST_CREDENTIAL_WRAPPER = 'credential-helper';
  let invocation;
  try {
    const result = loginDemoAccount('demo@example.invalid', (...args) => {
      invocation = args;
      return { status: 0, stdout: JSON.stringify({ verdict: 'OK', detail: 'fixture' }) };
    }, settings);
    assert.deepEqual(result, { verdict: 'OK', detail: 'fixture' });
    assert.equal(invocation[0], 'bash');
    assert.deepEqual(invocation[1].slice(1, 4), ['--demo-account', 'demo@example.invalid', '--']);
    assert.equal(invocation[1].at(-1), '--login-child');
  } finally { delete process.env.TEST_CREDENTIAL_WRAPPER; }
});

test('acceptance probe intervals and HTTP classifications remain stable', async () => {
  const { PROBE_INTERVAL_MS, classifyHttpStatus, isProbeDue, probeOnce } = await import('./acceptance-login-probe.mjs');
  assert.equal(isProbeDue(null, 0), true);
  assert.equal(isProbeDue({ checkedAt: 1000 }, 1000 + PROBE_INTERVAL_MS - 1), false);
  assert.equal(isProbeDue({ checkedAt: 1000 }, 1000 + PROBE_INTERVAL_MS), true);
  assert.equal(classifyHttpStatus(200).verdict, 'OK');
  assert.notEqual(classifyHttpStatus(503).verdict, 'OK');
  const events = [];
  const result = await probeOnce(null, 1, async (state) => events.push(state.verdict), () => ({ verdict: 'OK', detail: 'fixture' }));
  assert.equal(result.verdict, 'OK');
  assert.deepEqual(events, ['UNKNOWN', 'OK']);
});
