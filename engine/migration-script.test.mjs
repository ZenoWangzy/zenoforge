import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';

const launcher = resolve('engine/migration-script.mjs');
function exercise(key, fallback) {
  const root = mkdtempSync(join(tmpdir(), 'migration-script-'));
  const config = join(root, 'config');
  const pack = join(root, 'pack');
  mkdirSync(config); mkdirSync(pack);
  const invoke = () => spawnSync(process.execPath, [launcher, key, 'argument'], {
    cwd: root, encoding: 'utf8', env: { ...process.env, ZF_CONFIG_ROOT: config, ZF_PACK_DIR: pack },
  });
  writeFileSync(join(config, 'release.json'), JSON.stringify({ migration: { [key]: 'configured.mjs' } }));
  writeFileSync(join(pack, fallback), 'console.log("pack", process.argv[2]);\n');
  writeFileSync(join(root, 'configured.mjs'), 'console.log("target", process.argv[2]);\n');
  assert.equal(invoke().stdout.trim(), 'target argument');
  writeFileSync(join(config, 'release.json'), '{}');
  assert.equal(invoke().stdout.trim(), 'pack argument');
  writeFileSync(join(config, 'release.json'), JSON.stringify({ migration: { [key]: 'missing.mjs' } }));
  const missingPack = join(root, 'empty'); mkdirSync(missingPack);
  const missing = spawnSync(process.execPath, [launcher, key], { cwd: root, encoding: 'utf8', env: { ...process.env, ZF_CONFIG_ROOT: config, ZF_PACK_DIR: missingPack } });
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /migration script unavailable/);
}

test('role checker selects target, pack, or fails closed', () => exercise('roleCheck', 'check-fruit-migration-role.mjs'));

test('number checker selects target, pack, or fails closed', () => exercise('numberCheck', 'check-migration-numbers.mjs'));
test('renumberer selects target, pack, or fails closed', () => exercise('renumber', 'fruit-migration-renumber.mjs'));
