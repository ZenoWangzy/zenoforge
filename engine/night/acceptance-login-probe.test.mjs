import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
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

test('main writes probe state under AGENT_HOME/state using the configured file name', () => {
  mkdirSync(resolve('.scratch'), { recursive: true });
  const dir = mkdtempSync(join(resolve('.scratch'), 'acceptance-main-state-test-'));
  const configRoot = join(dir, '.zenoforge');
  const agentHome = join(dir, 'agent-home');
  const binDir = join(dir, 'bin');
  mkdirSync(configRoot, { recursive: true });
  mkdirSync(binDir, { recursive: true });
  writeFileSync(join(configRoot, 'night.json'), JSON.stringify({
    acceptance: {
      account_ref: ['fixture-account@example.invalid'],
      account_ref_env_name: 'FIXTURE_ACCEPTANCE_ACCOUNT',
      password_env_name: 'FIXTURE_ACCEPTANCE_PASSWORD',
      state_file_name: 'fixture-acceptance-login.json',
    },
    production: { urls: { acceptance_login: 'https://fixture.invalid/login' } },
  }));
  const curl = join(binDir, 'curl');
  writeFileSync(curl, '#!/bin/sh\nprintf "%s\\n" "200|0.010|0.020|0.020|0.030|0.500|89|1024"\n');
  chmodSync(curl, 0o755);
  try {
    const child = spawnSync(process.execPath, [resolve('engine/night/acceptance-login-probe.mjs')], {
      cwd: resolve('.'), encoding: 'utf8',
      env: {
        ...process.env,
        AGENT_HOME: agentHome,
        ZF_CONFIG_ROOT: configRoot,
        ZF_PACK_DIR: '',
        FIXTURE_ACCEPTANCE_ACCOUNT: 'fixture-account@example.invalid',
        FIXTURE_ACCEPTANCE_PASSWORD: 'fixture-password',
        PATH: `${binDir}:${process.env.PATH}`,
      },
    });
    assert.equal(child.status, 0, child.stderr);
    assert.match(child.stdout, /^OK acceptance-login account-index=1/m);
    const state = JSON.parse(readFileSync(join(agentHome, 'state', 'fixture-acceptance-login.json'), 'utf8'));
    assert.equal(state.accounts['fixture-account@example.invalid'].verdict, 'OK');
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

test('credentials.wrapper_script resolves against the repository that owns night.json', async () => {
  const { loadAcceptanceSettings } = await import('./acceptance-login-probe.mjs');
  mkdirSync(resolve('.scratch'), { recursive: true });
  const dir = mkdtempSync(join(resolve('.scratch'), 'acceptance-wrapper-script-test-'));
  try {
    mkdirSync(join(dir, '.zenoforge'), { recursive: true });
    writeFileSync(join(dir, '.zenoforge', 'night.json'), JSON.stringify({
      acceptance: { account_ref: ['target-account@example.invalid'] },
      production: { urls: { acceptance_login: 'https://target.invalid/login' } },
      credentials: { wrapper_env_name: 'TEST_CREDENTIAL_WRAPPER', wrapper_script: 'ops/with-credentials.sh' },
    }));
    const child = spawnSync(process.execPath, ['--input-type=module', '-e',
      "import { loadAcceptanceSettings } from './engine/night/acceptance-login-probe.mjs'; console.log(JSON.stringify(loadAcceptanceSettings()));"], {
      cwd: resolve('.'), encoding: 'utf8',
      env: { ...process.env, ZF_CONFIG_ROOT: join(dir, '.zenoforge'), ZF_PACK_DIR: '', ZF_REPO_DIR: '' },
    });
    assert.equal(child.status, 0, child.stderr);
    const settings = JSON.parse(child.stdout);
    assert.equal(settings.wrapperScript, join(dir, 'ops', 'with-credentials.sh'));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the credential wrapper environment name wins over credentials.wrapper_script', async () => {
  const { loginDemoAccount } = await import('./acceptance-login-probe.mjs');
  const settings = {
    wrapperEnvName: 'TEST_CREDENTIAL_WRAPPER',
    wrapperScript: '/fixture/repo/ops/with-credentials.sh',
  };
  process.env.TEST_CREDENTIAL_WRAPPER = 'credential-helper-from-env';
  let invocation;
  try {
    loginDemoAccount('demo@example.invalid', (...args) => {
      invocation = args;
      return { status: 0, stdout: JSON.stringify({ verdict: 'OK', detail: 'fixture' }) };
    }, settings);
    assert.equal(invocation[1][0], 'credential-helper-from-env');
  } finally { delete process.env.TEST_CREDENTIAL_WRAPPER; }
});

test('loginDemoAccount falls back to the configured wrapper script without an environment export', async () => {
  const { loginDemoAccount } = await import('./acceptance-login-probe.mjs');
  const settings = { wrapperEnvName: 'TEST_CREDENTIAL_WRAPPER', wrapperScript: '/fixture/repo/ops/with-credentials.sh' };
  let invocation;
  const result = loginDemoAccount('demo@example.invalid', (...args) => {
    invocation = args;
    return { status: 0, stdout: JSON.stringify({ verdict: 'OK', detail: 'fixture' }) };
  }, settings);
  assert.deepEqual(result, { verdict: 'OK', detail: 'fixture' });
  assert.equal(invocation[1][0], '/fixture/repo/ops/with-credentials.sh');
});

test('requestLogin parses the pipe-separated curl write-out', async () => {
  const { requestLogin } = await import('./acceptance-login-probe.mjs');
  const ok = requestLogin('user@example.invalid', 'secret', (command, args) => {
    assert.equal(args[args.indexOf('--write-out') + 1].includes('|'), true);
    return { status: 0, stdout: '200|0.010|0.020|0.020|0.030|0.500|89|1024' };
  }, 'https://target.invalid/login');
  assert.deepEqual(ok, { verdict: 'OK', detail: 'http=200' });
  const failed = requestLogin('user@example.invalid', 'secret', () => ({
    status: 28, stdout: '000|0.010|0.000|0.000|0.000|0.000|89|0',
  }), 'https://target.invalid/login');
  assert.equal(failed.verdict, 'UNKNOWN');
  assert.equal(failed.detail.includes('phase=tcp-connect'), true, failed.detail);
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
