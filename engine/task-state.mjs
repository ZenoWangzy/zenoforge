// Task state store, schema v1 (#991, slice of #596). Keyed by task id, no live session needed.
// Layout: <root>/<task id>/<record_type>.json, root = $AGENT_HOME/task-state.
// record_type and required fields (readers ignore any other field; a new field is additive):
//   intent   id goal done_when
//   task     id goal done_when owner stage blocker next_step   (active unless stage is terminal)
//   handoff  id from to reason next_step
//   decision id decision by why
// Every file carries schema_version 1. A reader refuses any other version.
// Writes go to a temp file in the same directory, fsync, rename, fsync dir: a crash before rename keeps the old file.
// task.json is current; handoffs and decisions append to events.jsonl.
import { closeSync, existsSync, fsyncSync, ftruncateSync, mkdirSync, openSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, rmdirSync, statSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const SCHEMA_VERSION = 1;
export const RECORD_TYPES = {
  intent: ['goal', 'done_when'],
  task: ['goal', 'done_when', 'owner', 'stage', 'blocker', 'next_step'],
  handoff: ['from', 'to', 'reason', 'next_step'],
  decision: ['decision', 'by', 'why'],
};
export const TERMINAL_STAGES = ['done', 'cancelled'];

const safeId = (id) => typeof id === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(id);
const textOr = (value, fallback) => typeof value === 'string' && value.trim() ? value
  : typeof value === 'number' && Number.isFinite(value) ? String(value) : fallback;
export const taskStateRoot = (agentHome = process.env.AGENT_HOME) => {
  if (!agentHome) throw new Error('task-state: AGENT_HOME is not set');
  return join(agentHome, 'task-state');
};
const recordFile = (root, id, type) => join(root, id, `${type}.json`);
const eventsFile = (root, id) => join(root, id, 'events.jsonl');

export function issueTransitionRecords({ issue, stage, reason, before = {}, after = {} }) {
  const id = `issue-${issue}`;
  const owner = textOr(after.owner_id ?? after.worker_id, id);
  const previousOwner = textOr(before.owner_id ?? before.worker_id, id);
  const nextStep = textOr(after.next_step ?? after.model_policy?.step, stage);
  const events = [];
  if ((stage === 'on-hold' && before.state !== stage) || owner !== previousOwner) {
    events.push({ record_type: 'handoff', id, from: previousOwner, to: stage === 'on-hold' ? 'hold' : owner, reason, next_step: nextStep });
  }
  const advisorDecision = textOr(after.advisor_decision ?? after.model_policy?.advisor_decision, '');
  if (reason === 'guarded-admission' && advisorDecision) {
    events.push({ record_type: 'decision', id, decision: advisorDecision, by: 'advisor', why: textOr(after.guard_reason, reason) });
  } else if (reason === 'advisor-admission' && advisorDecision) {
    events.push({ record_type: 'decision', id, decision: advisorDecision, by: 'advisor', why: reason });
  }
  const runDecision = Array.isArray(after.run?.decisions) ? after.run.decisions.at(-1) : null;
  if (reason === 'conclude:duplicate' && runDecision?.by === 'advisor') {
    events.push({ record_type: 'decision', id, decision: textOr(after.run?.outcome, 'duplicate'), by: 'advisor',
      why: textOr(runDecision.what, reason) });
  }
  return {
    task: {
      record_type: 'task', id,
      goal: textOr(after.goal ?? after.title, `issue #${issue}`),
      done_when: textOr(after.done_when, 'issue completed'), owner, stage,
      blocker: textOr(after.blocker ?? after.guard_reason ?? after.hold?.release_condition ?? after.hand_blocked_on?.blocker, 'none'),
      next_step: nextStep,
    },
    events,
  };
}

export function unitTransitionRecords({ unit, from_stage, old_owner, old_history = 0 }) {
  const id = unit.id;
  const stage = textOr(unit.stage, from_stage);
  const owner = textOr(unit.owner_id ?? unit.worker_id, id);
  const nextStep = textOr(unit.next_step, stage);
  const held = ['supervisor-review', 'parked', 'blocked-external', 'needs-human'].includes(stage);
  const movedToHold = held && stage !== from_stage;
  const history = Array.isArray(unit.history) ? unit.history : [];
  const last = history.at(-1) ?? {};
  const events = [];
  if (movedToHold || (old_owner && old_owner !== owner)) {
    events.push({ record_type: 'handoff', id, from: textOr(old_owner, id), to: old_owner && old_owner !== owner ? owner : 'hold',
      reason: textOr(last.result ?? last.why, stage), next_step: nextStep });
  }
  const manualRuling = typeof last.result === 'string' && /supervisor ruling/i.test(last.result);
  if (history.length > old_history && (last.decision || manualRuling)) {
    const decision = typeof last.decision === 'string' ? last.decision
      : textOr(last.decision?.decision, manualRuling ? textOr(last.stage, '').replace(/^supervisor-/, '') : '');
    if (typeof decision === 'string' && decision.trim()) {
      events.push({ record_type: 'decision', id, decision,
        by: textOr(last.decision?.owner ?? last.decision?.by, 'supervisor'),
        why: textOr(last.decision?.why ?? last.decision?.evidence ?? last.result, last.stage ?? stage) });
    }
  }
  return {
    task: {
      record_type: 'task', id, goal: textOr(unit.goal ?? unit.task ?? unit.title, `unit ${id}`),
      done_when: textOr(unit.done_when, 'unit complete'), owner, stage,
      blocker: textOr(unit.blocker ?? unit.blocked_on ?? unit.parked_reason ?? unit.note, 'none'), next_step: nextStep,
    },
    events,
  };
}

function validateRecord(record) {
  const fields = RECORD_TYPES[record?.record_type];
  if (!fields) throw new Error(`task-state: unknown record_type ${record?.record_type}`);
  if (!safeId(record.id)) throw new Error(`task-state: unsafe task id ${record.id}`);
  const missing = fields.filter((field) => typeof record[field] !== 'string' || record[field].trim() === '');
  if (missing.length) throw new Error(`task-state: ${record.record_type} ${record.id} missing ${missing.join(', ')}`);
}

export function writeAtomic(file, text, { beforeRename } = {}) {
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
  const fd = openSync(tmp, 'wx', 0o600);
  try {
    writeFileSync(fd, text);
    fsyncSync(fd);
  } finally { closeSync(fd); }
  try {
    beforeRename?.(tmp);
    renameSync(tmp, file);
  } catch (error) {
    rmSync(tmp, { force: true });
    throw error;
  }
  const dir = openSync(dirname(file), 'r');
  try { fsyncSync(dir); } finally { closeSync(dir); }
}

export function writeTaskRecord(root, record, options) {
  validateRecord(record);
  writeAtomic(recordFile(root, record.id, record.record_type),
    `${JSON.stringify({ ...record, schema_version: SCHEMA_VERSION })}\n`, options);
}

export function writeTransitionRecords(root, { task, events = [] }, options) {
  validateRecord(task);
  if (task.record_type !== 'task') throw new Error('task-state: transition requires a task record');
  if (!Array.isArray(events)) throw new Error('task-state: transition events must be an array');
  for (const event of events) {
    validateRecord(event);
    if (event.id !== task.id || !['handoff', 'decision'].includes(event.record_type)) {
      throw new Error(`task-state: invalid transition event for ${task.id}`);
    }
  }

  const taskPath = recordFile(root, task.id, 'task');
  const logPath = eventsFile(root, task.id);
  const eventText = events.map((event) => `${JSON.stringify({ ...event, schema_version: SCHEMA_VERSION })}\n`).join('');
  const snapshot = {
    id: task.id,
    task: existsSync(taskPath) ? readFileSync(taskPath, 'utf8') : null,
    events_size: existsSync(logPath) ? statSync(logPath).size : null,
    written_task: `${JSON.stringify({ ...task, schema_version: SCHEMA_VERSION })}\n`,
    appended_events: eventText,
  };

  try {
    writeTaskRecord(root, task, options);
    if (eventText) {
      const existed = existsSync(logPath);
      const fd = openSync(logPath, 'a', 0o600);
      try { writeFileSync(fd, eventText); fsyncSync(fd); } finally { closeSync(fd); }
      if (!existed) {
        const dir = openSync(dirname(logPath), 'r');
        try { fsyncSync(dir); } finally { closeSync(dir); }
      }
    }
  } catch (error) {
    rollbackTransitionRecords(root, snapshot);
    throw error;
  }
  return snapshot;
}

export function rollbackTransitionRecords(root, snapshot) {
  if (!safeId(snapshot?.id) || (snapshot.task !== null && typeof snapshot.task !== 'string')
    || (snapshot.events_size !== null && (!Number.isSafeInteger(snapshot.events_size) || snapshot.events_size < 0))) {
    throw new Error('task-state: invalid transition rollback snapshot');
  }
  const taskPath = recordFile(root, snapshot.id, 'task');
  const logPath = eventsFile(root, snapshot.id);
  if (snapshot.written_task && existsSync(taskPath) && readFileSync(taskPath, 'utf8') === snapshot.written_task) {
    if (snapshot.task === null) {
      rmSync(taskPath, { force: true });
      try { rmdirSync(dirname(taskPath)); } catch {}
    } else writeAtomic(taskPath, snapshot.task);
  }
  if (snapshot.appended_events && existsSync(logPath)) {
    const current = readFileSync(logPath);
    const oldSize = snapshot.events_size ?? 0;
    const suffix = current.subarray(oldSize);
    const appended = Buffer.from(snapshot.appended_events);
    if (suffix.length <= appended.length && appended.subarray(0, suffix.length).equals(suffix)) {
      if (snapshot.events_size === null) rmSync(logPath, { force: true });
      else {
        const fd = openSync(logPath, 'r+');
        try { ftruncateSync(fd, snapshot.events_size); fsyncSync(fd); } finally { closeSync(fd); }
      }
    }
  }
  if (snapshot.task === null) {
    try { rmdirSync(dirname(taskPath)); } catch {}
  }
}

export function readRecord(root, id, type = 'task') {
  if (!safeId(id)) throw new Error(`task-state: unsafe task id ${id}`);
  const file = recordFile(root, id, type);
  if (!existsSync(file)) return null;
  const record = JSON.parse(readFileSync(file, 'utf8'));
  if (record.schema_version !== SCHEMA_VERSION) {
    throw new Error(`task-state: unsupported schema_version ${record.schema_version} in ${file}; this reader understands ${SCHEMA_VERSION}`);
  }
  return record;
}

export const getTask = (root, id) => readRecord(root, id, 'task');

export function listActiveTasks(root) {
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && safeId(entry.name))
    .map((entry) => getTask(root, entry.name))
    .filter((task) => task && !TERMINAL_STAGES.includes(task.stage))
    .sort((a, b) => a.id.localeCompare(b.id));
}

if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  try {
    const [operation, root] = process.argv.slice(2);
    const input = JSON.parse(readFileSync(0, 'utf8'));
    if (operation === 'write-transition') process.stdout.write(`${JSON.stringify(writeTransitionRecords(root, input))}\n`);
    else if (operation === 'write-issue-transition') process.stdout.write(`${JSON.stringify(writeTransitionRecords(root, issueTransitionRecords(input)))}\n`);
    else if (operation === 'write-unit-transition') process.stdout.write(`${JSON.stringify(writeTransitionRecords(root, unitTransitionRecords(input)))}\n`);
    else if (operation === 'rollback-transition') rollbackTransitionRecords(root, input);
    else throw new Error(`unknown writer operation ${operation}`);
  } catch (error) {
    console.error(`task-state: ${error.message}`);
    process.exitCode = 1;
  }
}
