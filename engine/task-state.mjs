// Task state store, schema v1 (#991, slice of #596). Keyed by task id, no live session needed.
// Layout: <root>/<task id>/<record_type>.json, root = $AGENT_HOME/task-state.
// record_type and required fields (readers ignore any other field; a new field is additive):
//   intent   id goal done_when
//   task     id goal done_when owner stage blocker next_step   (active unless stage is terminal)
//   handoff  id from to reason next_step
//   decision id decision by why
// Every file carries schema_version 1. A reader refuses any other version.
// Writes go to a temp file in the same directory, fsync, rename, fsync dir: a crash before rename keeps the old file.
// shortcut: one file per record_type per task, so a second handoff or decision replaces the first; add an append log before #992 wires writers.
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { dirname, join } from 'node:path';

export const SCHEMA_VERSION = 1;
export const RECORD_TYPES = {
  intent: ['goal', 'done_when'],
  task: ['goal', 'done_when', 'owner', 'stage', 'blocker', 'next_step'],
  handoff: ['from', 'to', 'reason', 'next_step'],
  decision: ['decision', 'by', 'why'],
};
export const TERMINAL_STAGES = ['done', 'cancelled'];

const safeId = (id) => typeof id === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(id);
export const taskStateRoot = (agentHome = process.env.AGENT_HOME) => {
  if (!agentHome) throw new Error('task-state: AGENT_HOME is not set');
  return join(agentHome, 'task-state');
};
const recordFile = (root, id, type) => join(root, id, `${type}.json`);

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
  const fields = RECORD_TYPES[record?.record_type];
  if (!fields) throw new Error(`task-state: unknown record_type ${record?.record_type}`);
  if (!safeId(record.id)) throw new Error(`task-state: unsafe task id ${record.id}`);
  const missing = fields.filter((field) => typeof record[field] !== 'string' || record[field].trim() === '');
  if (missing.length) throw new Error(`task-state: ${record.record_type} ${record.id} missing ${missing.join(', ')}`);
  writeAtomic(recordFile(root, record.id, record.record_type),
    `${JSON.stringify({ ...record, schema_version: SCHEMA_VERSION })}\n`, options);
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
