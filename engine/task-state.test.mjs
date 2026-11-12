import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { getTask, listActiveTasks, readRecord, taskStateRoot, writeTaskRecord } from './task-state.mjs';

const modulePath = fileURLToPath(new URL('./task-state.mjs', import.meta.url));
const task = (overrides = {}) => ({
  record_type: 'task', id: 'task-991', goal: 'ship store', done_when: 'tests green',
  owner: 'worker', stage: 'implement', blocker: 'none', next_step: 'open PR', ...overrides,
});
const fresh = () => mkdtempSync(join(tmpdir(), 'task-state-'));

test('write then read round-trips a task and lists only active tasks', () => {
  const root = join(fresh(), 'task-state');
  writeTaskRecord(root, task());
  writeTaskRecord(root, task({ id: 'task-old', stage: 'done' }));
  assert.equal(getTask(root, 'task-991').goal, 'ship store');
  assert.equal(getTask(root, 'task-991').schema_version, 1);
  assert.deepEqual(listActiveTasks(root).map((t) => t.id), ['task-991']);
  assert.equal(getTask(root, 'missing-1'), null);
});

test('reader ignores an unknown extra field', () => {
  const root = join(fresh(), 'task-state');
  writeTaskRecord(root, task());
  const file = join(root, 'task-991', 'task.json');
  writeFileSync(file, JSON.stringify({ ...JSON.parse(readFileSync(file)), future_field: 'x' }));
  assert.equal(getTask(root, 'task-991').future_field, 'x');
  assert.equal(getTask(root, 'task-991').goal, 'ship store');
});

test('reader refuses an unknown schema_version with a clear error', () => {
  const root = join(fresh(), 'task-state');
  writeTaskRecord(root, task());
  const file = join(root, 'task-991', 'task.json');
  writeFileSync(file, JSON.stringify({ ...JSON.parse(readFileSync(file)), schema_version: 2 }));
  assert.throws(() => getTask(root, 'task-991'), /unsupported schema_version 2 .* understands 1/);
  assert.throws(() => listActiveTasks(root), /unsupported schema_version 2/);
});

test('a writer killed between temp write and rename leaves the previous record readable', () => {
  const root = join(fresh(), 'task-state');
  writeTaskRecord(root, task({ goal: 'old goal' }));
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', `
    import { writeTaskRecord } from ${JSON.stringify(modulePath)};
    writeTaskRecord(${JSON.stringify(root)}, ${JSON.stringify(task({ goal: 'new goal' }))},
      { beforeRename: () => process.kill(process.pid, 'SIGKILL') });
  `], { encoding: 'utf8' });
  assert.equal(child.signal, 'SIGKILL');
  assert.equal(getTask(root, 'task-991').goal, 'old goal');
  assert.equal(listActiveTasks(root).length, 1);
  assert.ok(readdirSync(join(root, 'task-991')).some((name) => name.endsWith('.tmp')));
});

test('an in-process failure before rename removes the temp file and keeps the old record', () => {
  const root = join(fresh(), 'task-state');
  writeTaskRecord(root, task({ goal: 'old goal' }));
  assert.throws(() => writeTaskRecord(root, task({ goal: 'new goal' }), {
    beforeRename: () => { throw new Error('injected'); },
  }), /injected/);
  assert.equal(getTask(root, 'task-991').goal, 'old goal');
  assert.deepEqual(readdirSync(join(root, 'task-991')), ['task.json']);
});

test('writer rejects unsafe ids, unknown record types and missing required fields', () => {
  const root = join(fresh(), 'task-state');
  assert.throws(() => writeTaskRecord(root, task({ id: '../escape' })), /unsafe task id/);
  assert.throws(() => writeTaskRecord(root, { ...task(), record_type: 'note' }), /unknown record_type note/);
  assert.throws(() => writeTaskRecord(root, task({ owner: '' })), /missing owner/);
  assert.equal(existsSync(join(root, '..', 'escape')), false);
});

test('store root comes from AGENT_HOME, never /tmp', () => {
  assert.equal(taskStateRoot('/x/agent'), '/x/agent/task-state');
  assert.throws(() => taskStateRoot(''), /AGENT_HOME is not set/);
  assert.equal(readRecord(join(fresh(), 'nothing'), 'task-991'), null);
});
