import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  addIncidentGuard, incidentGuardFragmentDir, mergeIncidentGuards, readIncidentGuards, readIncidentGuardsAtRev, splitIncidentGuards,
} from './incident-guards.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const helper = path.join(here, 'incident-guards.mjs');
const rec = (id, extra = {}) => ({ id, lesson_id: `V-${id}`, class: `class of ${id}`, ...extra });

function fixture(t, monolith = { incidents: [] }) {
  const root = mkdtempSync(path.join(tmpdir(), 'zf-incident-guards-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, '.zenoforge/state'), { recursive: true });
  const file = path.join(root, '.zenoforge/state/incident-guards.json');
  writeFileSync(file, `${JSON.stringify(monolith, null, 2)}\n`);
  return { root, file };
}
const ids = (doc) => doc.incidents.map((row) => row.id);

test('merged set: monolith in file order, then fragments by name; same record twice is read once', (t) => {
  const { file } = fixture(t, { incidents: [rec('zeta'), rec('alpha')] });
  addIncidentGuard(file, rec('mid'));
  addIncidentGuard(file, rec('beta'));
  addIncidentGuard(file, rec('alpha')); // already in the monolith with the same content
  assert.deepEqual(ids(readIncidentGuards(file)), ['zeta', 'alpha', 'beta', 'mid']);
});

test('the same id with different content, a wrong file name and a bad shape fail with a clear error', (t) => {
  const { file } = fixture(t, { incidents: [rec('dup')] });
  const dir = incidentGuardFragmentDir(file);
  const put = (name, doc) => { mkdirSync(dir, { recursive: true }); writeFileSync(path.join(dir, name), JSON.stringify(doc)); };
  put('dup.json', { incidents: [rec('dup', { class: 'other' })] });
  assert.throws(() => readIncidentGuards(file), /id "dup" is defined twice with different content/);
  rmSync(path.join(dir, 'dup.json'));
  put('other.json', { incidents: [rec('not-other')] });
  assert.throws(() => readIncidentGuards(file), /must be named <id>\.json/);
  rmSync(path.join(dir, 'other.json'));
  put('two.json', { incidents: [rec('two'), rec('three')] });
  assert.throws(() => readIncidentGuards(file), /must be \{"incidents": \[one record\]\}/);
  assert.throws(() => addIncidentGuard(file, rec('bad/id')), /needs an id/);
  assert.throws(() => mergeIncidentGuards({ incidents: 1 }, []), /no incidents array/);
});

test('add refuses to replace a fragment with different content', (t) => {
  const { file } = fixture(t);
  addIncidentGuard(file, rec('once'));
  addIncidentGuard(file, rec('once'));
  assert.throws(() => addIncidentGuard(file, rec('once', { class: 'changed' })), /already exists with different content/);
});

test('a fragment dir with no monolith still reads; a missing registry still throws', (t) => {
  const { file } = fixture(t);
  rmSync(file);
  assert.throws(() => readIncidentGuards(file), /ENOENT/);
  addIncidentGuard(file, rec('only-fragment'));
  assert.deepEqual(ids(readIncidentGuards(file)), ['only-fragment']);
});

test('reading at a git revision merges the monolith and the fragments of that revision', (t) => {
  const { root, file } = fixture(t, { incidents: [rec('old')] });
  const git = (...args) => execFileSync('git', ['-C', root, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...args], { encoding: 'utf8' });
  git('init', '-q');
  git('add', '.'); git('commit', '-q', '-m', 'one');
  const first = git('rev-parse', 'HEAD').trim();
  addIncidentGuard(file, rec('new'));
  git('add', '.'); git('commit', '-q', '-m', 'two');
  const relative = '.zenoforge/state/incident-guards.json';
  assert.deepEqual(ids(readIncidentGuardsAtRev(root, first, relative)), ['old']);
  assert.deepEqual(ids(readIncidentGuardsAtRev(root, 'HEAD', relative)), ['old', 'new']);
  const cli = spawnSync('node', [helper, 'read-rev', root, 'HEAD', relative], { encoding: 'utf8' });
  assert.deepEqual(ids(JSON.parse(cli.stdout)), ['old', 'new']);
});

test('split moves every record into a fragment and the merged set equals the old records exactly', (t) => {
  const rows = [rec('one', { nested: { b: 1, a: [1, 'two'] } }), rec('two', { text: 'ünïcode / "quotes"' }), rec('three')];
  const { file } = fixture(t, { incidents: rows });
  assert.equal(splitIncidentGuards(file), 3);
  assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')), { incidents: [] });
  assert.deepEqual(readdirSync(incidentGuardFragmentDir(file)).sort(), ['one.json', 'three.json', 'two.json']);
  assert.deepEqual(new Map(readIncidentGuards(file).incidents.map((row) => [row.id, row])), new Map(rows.map((row) => [row.id, row])));
});

// Run with ZF_VECTA_GUARDS_FILE=<path to the product's .zenoforge/state/incident-guards.json at origin/main>.
test('split of the product registry keeps every record: same ids, same content', { skip: !process.env.ZF_VECTA_GUARDS_FILE }, (t) => {
  const original = JSON.parse(readFileSync(process.env.ZF_VECTA_GUARDS_FILE, 'utf8')).incidents;
  const { file } = fixture(t);
  writeFileSync(file, readFileSync(process.env.ZF_VECTA_GUARDS_FILE));
  assert.equal(splitIncidentGuards(file), original.length);
  const merged = readIncidentGuards(file).incidents;
  assert.equal(merged.length, original.length);
  const byId = new Map(merged.map((row) => [row.id, JSON.stringify(row)]));
  for (const row of original) assert.equal(byId.get(row.id), JSON.stringify(row), row.id);
  console.log(`incident-guards: product registry split equal, ${original.length} records`);
});

// One test per reader: a guard that exists only in a fragment must be seen.
test('zfIncidentGuards (pack-dir.mjs, reports and the audit) sees a fragment-only guard in the target and in the engine', (t) => {
  const { root, file } = fixture(t, { incidents: [rec('target-mono')] });
  addIncidentGuard(file, rec('target-fragment'));
  const engine = path.join(root, 'engine-dir');
  mkdirSync(path.join(engine, 'state'), { recursive: true });
  writeFileSync(path.join(engine, 'state/incident-guards.json'), '{"incidents":[]}\n');
  addIncidentGuard(path.join(engine, 'state/incident-guards.json'), rec('engine-fragment'));
  const script = `import { zfIncidentGuards } from ${JSON.stringify(path.join(here, 'pack-dir.mjs'))};
    console.log(JSON.stringify(zfIncidentGuards(${JSON.stringify(root)}).incidents.map((row) => row.id)));`;
  const result = spawnSync('node', ['--input-type=module', '-e', script], {
    encoding: 'utf8', env: { ...process.env, ZF_ENGINE_DIR: engine, ZF_CONFIG_ROOT: path.join(root, '.zenoforge'), ZF_PACK_DIR: '' },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ['target-mono', 'target-fragment', 'engine-fragment']);
});

test('validateRegistry (lesson-guard-schema.mjs) checks a fragment-only guard and reports a broken fragment', (t) => {
  const { root, file } = fixture(t);
  addIncidentGuard(file, rec('schema-victim'));
  const env = { ...process.env, ZF_CONFIG_ROOT: path.join(root, '.zenoforge'), ZF_PACK_DIR: '', ZF_ENGINE_DIR: path.join(root, 'none') };
  const script = (extra = '') => `import { validateRegistry } from ${JSON.stringify(path.join(here, 'lesson-guard-schema.mjs'))};
    ${extra}console.log(JSON.stringify(validateRegistry(${JSON.stringify(root)})));`;
  const seen = JSON.parse(spawnSync('node', ['--input-type=module', '-e', script()], { encoding: 'utf8', env }).stdout);
  assert.equal(seen.checked, 1);
  assert.ok(seen.errors.some((error) => error.includes('schema-victim')), `a fragment guard is validated: ${seen.errors}`);
  writeFileSync(path.join(incidentGuardFragmentDir(file), 'wrong-name.json'), JSON.stringify({ incidents: [rec('schema-victim')] }));
  const broken = JSON.parse(spawnSync('node', ['--input-type=module', '-e', script()], { encoding: 'utf8', env }).stdout);
  assert.match(broken.errors.join('\n'), /must be named <id>\.json/);
});

test('config_paths.py (node_health and the health mail) sees a fragment-only guard', (t) => {
  const { root, file } = fixture(t);
  addIncidentGuard(file, rec('python-fragment'));
  const python = `import json, sys
sys.path.insert(0, ${JSON.stringify(path.join(here, 'mac-autopilot'))})
from config_paths import zf_incident_guards
print(json.dumps([row['id'] for row in zf_incident_guards(${JSON.stringify(file)})['incidents']]))`;
  const result = spawnSync('python3', ['-I', '-c', python], { encoding: 'utf8', env: { ...process.env, ZF_ENGINE_DIR: path.join(root, 'none') } });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ['python-fragment']);
  const cli = spawnSync('python3', ['-I', path.join(here, 'mac-autopilot/config_paths.py'), '--incident-guards', file], { encoding: 'utf8', env: { ...process.env, ZF_ENGINE_DIR: path.join(root, 'none') } });
  assert.deepEqual(JSON.parse(cli.stdout).incidents.map((row) => row.id), ['python-fragment']);
});

test('the bash reader zf_incident_guards_read prints the merged registry', (t) => {
  const { file } = fixture(t, { incidents: [rec('mono')] });
  addIncidentGuard(file, rec('bash-fragment'));
  const result = spawnSync('bash', ['-c', `ZF_ENGINE_DIR=${JSON.stringify(here)}; source ${JSON.stringify(path.join(here, 'config.sh'))}; ZF_ENGINE_DIR=${JSON.stringify(here)}; zf_incident_guards_read ${JSON.stringify(file)}`], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(ids(JSON.parse(result.stdout)), ['mono', 'bash-fragment']);
});
