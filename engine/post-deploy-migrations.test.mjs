import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const root = mkdtempSync(join(process.cwd(), '.git/post-deploy-test-'));
const config = join(root, 'config');
const pack = join(root, 'pack');
mkdirSync(config); mkdirSync(pack);
writeFileSync(join(config, 'release.json'), JSON.stringify({ postDeploy: { marker: '-- sample:post', ledger: 'audit.applied' } }));
writeFileSync(join(pack, 'release.json'), JSON.stringify({ postDeploy: { marker: '-- other:post', ledger: 'audit.other' } }));
process.env.ZF_CONFIG_ROOT = config;
process.env.ZF_PACK_DIR = pack;
const { postDeployMigrations, postDeploySql, isAdditiveMigration } = await import('./post-deploy-migrations.mjs');

test('target marker and ledger win over pack configuration', () => {
  const journal = { entries: [{ tag: '0001_a' }, { tag: '0002_b' }] };
  const found = postDeployMigrations(journal, tag => tag === '0001_a' ? '-- sample:post\nCREATE TABLE IF NOT EXISTS t (id int);' : '-- other:post\nSELECT 1;');
  assert.deepEqual(found.map(item => item.tag), ['0001_a']);
  assert.match(postDeploySql(found, 'abc'), /audit\.applied/);
  assert.equal(isAdditiveMigration(found[0].sql), true);
  assert.throws(() => postDeployMigrations(journal, () => '-- sample:post\nDROP TABLE t;'), /RAISE EXCEPTION/);
});

test('CLI delegates to pack when configuration is absent and fails closed without it', () => {
  const legacy = join(root, 'legacy'); mkdirSync(legacy);
  writeFileSync(join(legacy, 'post-deploy-migrations.mjs'), "console.log('legacy');\n");
  const script = join(process.cwd(), 'engine/post-deploy-migrations.mjs');
  const run = packDir => spawnSync(process.execPath, [script], { encoding: 'utf8', env: { ...process.env, ZF_CONFIG_ROOT: join(root, 'missing'), ZF_PACK_DIR: packDir } });
  assert.equal(run(legacy).stdout.trim(), 'legacy');
  assert.match(run('').stderr, /postDeploy.marker is required/);
});
