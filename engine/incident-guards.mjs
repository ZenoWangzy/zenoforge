#!/usr/bin/env node
// The one reader and writer of incident-guard records. A registry is state/incident-guards.json (the
// monolith) plus one fragment per guard in the directory next to it, state/incident-guards.d/<id>.json.
// Each fragment is {"incidents": [one record]}. Every reader goes through readIncidentGuards, in node
// directly and from bash and python through the CLI below.
//
// Merged order is fixed: monolith records in file order, then fragments sorted by file name. A record
// that exists in both with the same content is read once; the same id with different content throws.
// While both exist the monolith stays readable, so product and engine can land in either order.
//
// CLI: read <file> | read-rev <repo> <rev> <repo-relative-file> | add <file> <record.json> | split <file>
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

export const incidentGuardFragmentDir = (file) => file.replace(/\.json$/, '.d');

const canonical = (value) => JSON.stringify(value, (_key, v) => (v && typeof v === 'object' && !Array.isArray(v)
  ? Object.fromEntries(Object.keys(v).sort().map((key) => [key, v[key]])) : v));

// shortcut: JSON.stringify spells a number or an escape one way, so a rewritten fragment equals its record.
export const serializeIncidentGuardFragment = (record) => `${JSON.stringify({ incidents: [record] }, null, 2)}\n`;

function fragmentRecord(name, text, where) {
  let doc;
  try { doc = JSON.parse(text); } catch (error) { throw new Error(`incident guard fragment ${where} does not parse: ${error.message}`); }
  const keys = doc && typeof doc === 'object' ? Object.keys(doc) : [];
  if (keys.length !== 1 || keys[0] !== 'incidents' || !Array.isArray(doc.incidents) || doc.incidents.length !== 1) {
    throw new Error(`incident guard fragment ${where} must be {"incidents": [one record]}`);
  }
  const record = doc.incidents[0];
  if (!record || typeof record.id !== 'string' || !ID_PATTERN.test(record.id) || `${record.id}.json` !== name) {
    throw new Error(`incident guard fragment ${where} must be named <id>.json for the id inside it`);
  }
  return record;
}

// monolith: parsed document or null; fragments: [{ name, where, text }] in any order.
export function mergeIncidentGuards(monolith, fragments, monolithWhere = 'monolith') {
  const doc = monolith ?? { incidents: [] };
  if (!Array.isArray(doc.incidents)) throw new Error(`${monolithWhere} has no incidents array`);
  const incidents = [...doc.incidents];
  const owner = new Map();
  for (const record of incidents) if (typeof record?.id === 'string' && !owner.has(record.id)) owner.set(record.id, { record, where: monolithWhere });
  for (const { name, where, text } of [...fragments].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))) {
    const record = fragmentRecord(name, text, where);
    const seen = owner.get(record.id);
    if (seen) {
      if (canonical(seen.record) !== canonical(record)) {
        throw new Error(`incident guard id "${record.id}" is defined twice with different content: ${seen.where} and ${where}`);
      }
      continue;
    }
    owner.set(record.id, { record, where });
    incidents.push(record);
  }
  return { ...doc, incidents };
}

export function readIncidentGuards(file) {
  const dir = incidentGuardFragmentDir(file);
  const hasDir = existsSync(dir);
  const monolith = !hasDir || existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : null;
  const fragments = hasDir
    ? readdirSync(dir).filter((name) => name.endsWith('.json')).map((name) => ({ name, where: path.join(dir, name), text: readFileSync(path.join(dir, name), 'utf8') }))
    : [];
  return mergeIncidentGuards(monolith, fragments, file);
}

// The registry as it is at a git revision (landing reads the base, not the working tree). A missing
// monolith reads as empty; the caller decides what a missing registry means.
export function readIncidentGuardsAtRev(repo, rev, relativeFile) {
  const git = (args, input) => execFileSync('git', ['-C', repo, ...args], { input, maxBuffer: 256 * 1024 * 1024 });
  const dir = incidentGuardFragmentDir(relativeFile);
  const names = git(['ls-tree', '-r', '--name-only', '-z', rev, '--', `${dir}/`]).toString('utf8').split('\0').filter((name) => name.endsWith('.json'));
  const wanted = [relativeFile, ...names];
  const out = git(['cat-file', '--batch'], Buffer.from(wanted.map((name) => `${rev}:${name}\n`).join('')));
  const blobs = [];
  for (let offset = 0, i = 0; i < wanted.length; i += 1) {
    const eol = out.indexOf(0x0a, offset);
    const [, type, size] = out.subarray(offset, eol).toString('utf8').split(' ');
    if (type !== 'blob') { blobs.push(null); offset = eol + 1; continue; }
    blobs.push(out.subarray(eol + 1, eol + 1 + Number(size)).toString('utf8'));
    offset = eol + 1 + Number(size) + 1;
  }
  const monolith = blobs[0] === null ? null : JSON.parse(blobs[0]);
  const fragments = names.map((name, i) => ({ name: path.basename(name), where: `${rev}:${name}`, text: blobs[i + 1] }));
  return mergeIncidentGuards(monolith, fragments, `${rev}:${relativeFile}`);
}

// Writer: a new guard is a new file, so two incidents never edit the same lines.
export function addIncidentGuard(file, record) {
  if (!record || typeof record.id !== 'string' || !ID_PATTERN.test(record.id)) throw new Error('incident guard record needs an id of letters, digits, dot, underscore and dash');
  const dir = incidentGuardFragmentDir(file);
  const target = path.join(dir, `${record.id}.json`);
  const text = serializeIncidentGuardFragment(record);
  if (existsSync(target) && readFileSync(target, 'utf8') !== text) throw new Error(`incident guard fragment already exists with different content: ${target}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(target, text);
  return target;
}

// Migration: every monolith record becomes a fragment and the monolith keeps no records. The merged
// set must equal the old records one for one, or nothing is left rewritten.
export function splitIncidentGuards(file) {
  const before = readIncidentGuards(file);
  for (const record of before.incidents) addIncidentGuard(file, record);
  const emptied = { ...JSON.parse(readFileSync(file, 'utf8')), incidents: [] };
  const temp = `${file}.tmp`;
  writeFileSync(temp, `${JSON.stringify(emptied, null, 2)}\n`);
  renameSync(temp, file);
  const after = readIncidentGuards(file);
  const key = (rows) => new Map(rows.map((row) => [row.id, canonical(row)]));
  const a = key(before.incidents);
  const b = key(after.incidents);
  if (a.size !== b.size || [...a].some(([id, text]) => b.get(id) !== text)) throw new Error('split changed the merged incident guard set');
  return before.incidents.length;
}

if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  try {
    const [command, ...args] = process.argv.slice(2);
    if (command === 'read' && args.length === 1) process.stdout.write(JSON.stringify(readIncidentGuards(args[0])));
    else if (command === 'read-rev' && args.length === 3) process.stdout.write(JSON.stringify(readIncidentGuardsAtRev(...args)));
    else if (command === 'add' && args.length === 2) console.log(addIncidentGuard(args[0], JSON.parse(readFileSync(args[1], 'utf8'))));
    else if (command === 'split' && args.length === 1) console.log(`incident-guards: split ${splitIncidentGuards(args[0])} record(s) into ${incidentGuardFragmentDir(args[0])}`);
    else throw new Error('usage: incident-guards.mjs read <file> | read-rev <repo> <rev> <repo-relative-file> | add <file> <record.json> | split <file>');
  } catch (error) {
    console.error(`incident-guards: ${error.message}`);
    process.exitCode = 1;
  }
}
