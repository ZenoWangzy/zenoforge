import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { getTask, issueTransitionRecords, listActiveTasks, readRecord, taskStateRoot, unitTransitionRecords, writeTaskRecord, writeTransitionRecords } from './task-state.mjs';

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

test('transition records keep one current task and append handoffs and decisions', async () => {
  const { rollbackTransitionRecords, writeTransitionRecords } = await import('./task-state.mjs');
  const root = join(fresh(), 'task-state');
  const first = writeTransitionRecords(root, {
    task: task({ stage: 'triage' }),
    events: [{ record_type: 'decision', id: 'task-991', decision: 'admit', by: 'advisor', why: 'scope fits' }],
  });
  const second = writeTransitionRecords(root, {
    task: task({ stage: 'merge' }),
    events: [{ record_type: 'handoff', id: 'task-991', from: 'worker-1', to: 'reviewer-1', reason: 'review', next_step: 'merge' }],
  });

  assert.equal(getTask(root, 'task-991').stage, 'merge');
  assert.deepEqual(readFileSync(join(root, 'task-991', 'events.jsonl'), 'utf8').trim().split('\n').map((line) => JSON.parse(line).record_type), ['decision', 'handoff']);

  rollbackTransitionRecords(root, second);
  assert.equal(getTask(root, 'task-991').stage, 'triage');
  assert.equal(readFileSync(join(root, 'task-991', 'events.jsonl'), 'utf8').trim().split('\n').length, 1);
  rollbackTransitionRecords(root, first);
  assert.equal(getTask(root, 'task-991'), null);
  assert.equal(existsSync(join(root, 'task-991', 'events.jsonl')), false);
});

test('transition adapters retain dependency blockers and plain supervisor rulings', () => {
  const issue = issueTransitionRecords({ issue: 992, stage: 'needs-triage', reason: 'triage', after: {
    hand_blocked_on: { blocker: 991 },
  } });
  assert.equal(issue.task.blocker, '991');
  assert.deepEqual(issueTransitionRecords({ issue: 992, stage: 'ready-for-agent', reason: 'ruling-ready:comment-1',
    after: { supervisor_decision: 'approve' } }).events, []);

  const unit = unitTransitionRecords({
    unit: { id: 'unit-992', stage: 'implement-pending', blocked_on: 778, parked_reason: 'waiting-predecessor', history: [
      { stage: 'supervisor-approve', result: 'supervisor ruling via hold.sh --rule: comment-1' },
    ] },
    from_stage: 'implement-pending', old_owner: 'unit-992', old_history: 0,
  });
  assert.equal(unit.task.blocker, '778');
  assert.deepEqual(unit.events, [{
    record_type: 'decision', id: 'unit-992', decision: 'approve',
    by: 'supervisor', why: 'supervisor ruling via hold.sh --rule: comment-1',
  }]);
});

test('guarded admission records only a stored advisor decision', () => {
  const result = issueTransitionRecords({ issue: 992, stage: 'ready-for-agent', reason: 'guarded-admission', after: {
    advisor_decision: 'admit with safeguards',
    guard_reason: 'required checks remain enabled',
  } });
  assert.deepEqual(result.events, [{
    record_type: 'decision', id: 'issue-992', decision: 'admit with safeguards', by: 'advisor',
    why: 'required checks remain enabled',
  }]);
  assert.deepEqual(issueTransitionRecords({ issue: 992, stage: 'ready-for-agent', reason: 'guarded-admission', after: {
    guard_reason: 'recut refused without an advisor ruling',
  } }).events, []);
});

test('duplicate conclusion records its stored advisor run decision', () => {
  const result = issueTransitionRecords({ issue: 993, stage: 'concluded', reason: 'conclude:duplicate',
    before: { run: { decisions: [{ by: 'advisor', what: 'duplicate of #17' }] } },
    after: { run: { outcome: 'duplicate', decisions: [{ by: 'advisor', what: 'duplicate of #17' }] } },
  });
  assert.deepEqual(result.events, [{
    record_type: 'decision', id: 'issue-993', decision: 'duplicate', by: 'advisor', why: 'duplicate of #17',
  }]);
});

test('an empty state snapshot still writes its transition records', () => {
  const root = join(fresh(), 'task-state');
  const result = issueTransitionRecords({ issue: 994, stage: 'concluded', reason: 'conclude:deployed', before: null, after: null });
  assert.equal(result.task.stage, 'concluded');
  writeTransitionRecords(root, result);
  assert.equal(getTask(root, 'issue-994').stage, 'concluded');
});

test('resume prints every active task with its latest handoff and decision', () => {
  const root = join(fresh(), 'task-state');
  writeTransitionRecords(root, {
    task: task({ goal: 'recover parser', done_when: 'parser acceptance passes', stage: 'implement', next_step: 'inspect parser' }),
    events: [
      { record_type: 'handoff', id: 'task-991', from: 'coordinator', to: 'worker-1', reason: 'start', next_step: 'inspect parser' },
      { record_type: 'decision', id: 'task-991', decision: 'admit', by: 'advisor', why: 'ticket is in scope' },
    ],
  });
  writeTransitionRecords(root, {
    task: task({ goal: 'recover parser', done_when: 'parser acceptance passes', owner: 'worker-2', stage: 'implement', next_step: 'run parser acceptance' }),
    events: [
      { record_type: 'handoff', id: 'task-991', from: 'worker-1', to: 'worker-2', reason: 'session restart', next_step: 'run parser acceptance' },
      { record_type: 'decision', id: 'task-991', decision: 'continue', by: 'supervisor', why: 'session died during implementation' },
    ],
  });
  writeTaskRecord(root, task({ id: 'task-992', goal: 'review deployment', stage: 'review', owner: 'reviewer', next_step: 'inspect the deployment diff' }));

  const result = spawnSync(process.execPath, [modulePath, 'resume', root], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, [
    'Active task: task-991',
    '  goal: recover parser',
    '  done-when: parser acceptance passes',
    '  owner: worker-2',
    '  stage: implement',
    '  blocker: none',
    '  next step: run parser acceptance',
    '  latest handoff: from=worker-1; to=worker-2; reason=session restart; next step=run parser acceptance',
    '  latest decision: decision=continue; by=supervisor; why=session died during implementation',
    '',
    'Active task: task-992',
    '  goal: review deployment',
    '  done-when: tests green',
    '  owner: reviewer',
    '  stage: review',
    '  blocker: none',
    '  next step: inspect the deployment diff',
    '  latest handoff: none',
    '  latest decision: none',
    '',
  ].join('\n'));
});

test('resume prints a clear line when the store is empty', () => {
  const root = join(fresh(), 'task-state');
  const result = spawnSync(process.execPath, [modulePath, 'resume', root], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'No active tasks.\n');
});

test('resume refuses an unknown schema version in the event log', () => {
  const root = join(fresh(), 'task-state');
  writeTransitionRecords(root, {
    task: task(),
    events: [{ record_type: 'decision', id: 'task-991', decision: 'admit', by: 'advisor', why: 'in scope' }],
  });
  const file = join(root, 'task-991', 'events.jsonl');
  const event = JSON.parse(readFileSync(file, 'utf8'));
  writeFileSync(file, JSON.stringify({ ...event, schema_version: 2 }) + '\n');

  const result = spawnSync(process.execPath, [modulePath, 'resume', root], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /unsupported schema_version 2 .* understands 1/);
});
