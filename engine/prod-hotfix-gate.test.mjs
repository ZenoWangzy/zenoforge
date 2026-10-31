import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = fileURLToPath(new URL('..', import.meta.url));
const dir = mkdtempSync(join(root, '.git', 'gate-test-'));
const config = join(dir, 'config');
const pack = join(dir, 'pack');
mkdirSync(config); mkdirSync(pack);
const engine = join(root, 'engine', 'prod-hotfix-gate.cjs');
const env = { ...process.env, ZF_CONFIG_ROOT: config, ZF_PACK_DIR: pack };
const run = (input) => spawnSync(process.execPath, [engine], { input, env, encoding: 'utf8' });
const request = (command) => JSON.stringify({ tool_name: 'Bash', tool_input: { command } });

test('target rules win and validate; malformed tool input remains open', () => {
  writeFileSync(join(pack, 'hotfix.json'), JSON.stringify({ command_rules: [{ patterns: ['pack'], message: 'pack rule' }] }));
  writeFileSync(join(config, 'hotfix.json'), JSON.stringify({ command_rules: [{ patterns: ['danger'], require: 'remote', mask: 'safe-danger', message: 'override rule' }] }));
  assert.equal(run(request('pack')).status, 0);
  assert.equal(run(request('remote danger')).status, 2);
  assert.match(run(request('remote danger')).stderr, /override rule/);
  assert.equal(run(request('remote safe-danger')).status, 0);
  assert.equal(run(request('danger')).status, 0);
  assert.equal(run('bad json').status, 0);
  assert.equal(run(JSON.stringify({ tool_name: 'Read' })).status, 0);
  writeFileSync(join(config, 'hotfix.json'), JSON.stringify({ command_rules: [{ patterns: ['['], message: 'bad' }] }));
  assert.equal(run(request('anything')).status, 2);
});

test('pack config and legacy gate are fallbacks, absence fails closed', () => {
  const missing = join(dir, 'missing');
  const fallbackEnv = { ...env, ZF_CONFIG_ROOT: missing };
  const call = () => spawnSync(process.execPath, [engine], { input: request('pack'), env: fallbackEnv, encoding: 'utf8' });
  assert.match(call().stderr, /pack rule/);
  const emptyPack = join(dir, 'legacy'); mkdirSync(emptyPack);
  const legacyEnv = { ...fallbackEnv, ZF_PACK_DIR: emptyPack };
  const legacyCall = () => spawnSync(process.execPath, [engine], { input: request('pack'), env: legacyEnv, encoding: 'utf8' });
  assert.equal(legacyCall().status, 2);
  writeFileSync(join(emptyPack, 'prod-hotfix-gate.cjs'), 'process.stdin.resume(); process.stdin.on("end", () => process.exit(7));\n');
  assert.equal(legacyCall().status, 7);
});
