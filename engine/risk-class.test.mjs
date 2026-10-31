import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { classify, classifyWithKind } from './risk-class.mjs';

const RISK_CLASS_MJS = fileURLToPath(new URL('./risk-class.mjs', import.meta.url));
const hit = (path) => assert.deepEqual(classify([path]), [path], `${path} must be classified`);
const clean = (path) => assert.deepEqual(classify([path]), [], `${path} must not be classified`);

test('blocks schema, migration and drizzle config paths', () => {
  hit('src/db/schema/accounts.ts');
  hit('migrations/0001_init.sql');
  hit('services/api/migrations/0002_add_index.sql');
  hit('drizzle.config.ts');
  hit('services/api/drizzle.config.ts');
});

test('blocks access-control files named with a suffix, not just a prefix', () => {
  hit('src/billing/refund-policy.ts');
  hit('src/permission-facts.ts');
  hit('src/rbac-guard.ts');
  hit('src/rbac/evaluator.ts');
  hit('src/org/rls.test.ts');
});

test('blocks auth and ledger source at any depth', () => {
  hit('services/api/src/auth/jwt.ts');
  hit('src/quota/ledger.ts');
  hit('ledger.ts');
});

test('blocks the pipeline control surface and build definitions', () => {
  hit('.github/workflows/ci.yml');
  hit('infra/docker/docker-compose.yml');
  hit('docker-compose.fixture.yml');
  hit('.env.example');
  hit('engine/risk-class.mjs');
  hit('scripts/ops/deploy.sh');
  hit('.claude/commands/review.md');
  hit('Dockerfile');
  hit('services/api/Dockerfile');
  hit('infra/docker/Dockerfile.runtime');
  hit('base.Dockerfile');
  hit('.dockerignore');
});

test('does not block a file that merely mentions dockerfile in its name', () => {
  clean('docs/ops/dockerfile-conventions.md');
});

test('excludes test files from durable-write rules but not from control-surface rules', () => {
  clean('src/db/schema/__tests__/accounts.test.ts');
  clean('src/rbac/evaluator.test.ts');
  clean('services/api/src/auth/jwt.test.ts');
  clean('src/quota/ledger.test.ts');
  hit('src/db/schema/accounts.ts');
  hit('engine/risk-class.test.mjs');
});

test('keeps the rls/rbac/permission/policy keyword rule\'s own test files classified', () => {
  hit('src/org/rls.test.ts');
});

test('excludes archive, plan and spike paths, even through the keyword rule', () => {
  clean('docs/archive/2026-08/ledger-repair-runbook.md');
  clean('docs/plans/2026-05-22-rls-isolation.md');
  clean('prototypes/spike/rls-isolation.ts');
});

test('an ordinary source path passes clean and a mixed diff reports only the offending paths', () => {
  clean('src/routes/webhook.ts');
  assert.deepEqual(classify(['src/routes/webhook.ts', 'migrations/0003_x.sql']), ['migrations/0003_x.sql']);
});

test('classifyWithKind tags each hit with its boundary kind', () => {
  assert.deepEqual(
    classifyWithKind(['src/db/schema/accounts.ts', 'engine/risk-class.mjs', 'src/routes/webhook.ts']),
    [
      { path: 'src/db/schema/accounts.ts', kind: 'durable-write' },
      { path: 'engine/risk-class.mjs', kind: 'control-surface' },
    ],
  );
});

test('CLI --json prints classifyWithKind() as JSON on stdout and exits 0', () => {
  // HEAD...HEAD is an empty range, so this proves flag parsing, exit code and JSON shape without needing a real diff.
  const out = execFileSync('node', [RISK_CLASS_MJS, '--json', 'HEAD...HEAD'], { encoding: 'utf8' });
  assert.deepEqual(JSON.parse(out), []);
});

test('target config risk rules override engine defaults', (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'risk-class-config-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const configRoot = path.join(root, '.zenoforge');
  mkdirSync(path.join(configRoot, 'state'), { recursive: true });
  writeFileSync(path.join(configRoot, 'state/risk-paths.json'), JSON.stringify({
    rules: [{ kind: 'control-surface', pattern: '^config-only\\.ts$' }],
    inert: [],
  }));
  const code = `import(${JSON.stringify(new URL('./risk-class.mjs', import.meta.url).href)})
    .then(({ classify }) => console.log(JSON.stringify(classify(['config-only.ts', 'migrations/engine-default.sql']))));`;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', code], {
    encoding: 'utf8',
    env: { ...process.env, ZF_CONFIG_ROOT: configRoot, ZF_PACK_DIR: '' },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ['config-only.ts']);
});
