#!/usr/bin/env node
// Problem-record schema gate (issue #4657, rulings every-fix-ships-a-lesson,
// root-cause-then-classic-research, never-twice-enforced).
// state/incident-guards.json is the durable problem register;
// a record is only acceptable when it carries the verifiable chain
// root cause -> classic problem -> research sources -> compared options ->
// chosen mechanism -> runnable regression check.
// Records dated before SCHEMA_START are the historical catalog (searchable via
// lessons/CATALOG.md); they are reused, not backfilled.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { zfConfigFile } from './pack-dir.mjs';

const DEFAULT_ROOT = process.env.ZF_REPO_DIR || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REGISTRY_PATH = 'state/incident-guards.json';
const SCHEMA_START = '2026-10-30';
const DATE_FORMAT = /^\d{4}-\d{2}-\d{2}$/;
// Evidence must point at something checkable: a URL, an issue/PR/run number,
// a commit hex, or a file path. Symptom prose has none of these.
const EVIDENCE_ANCHOR = /https?:\/\/|#\d+|[0-9a-f]{7,40}|[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/;

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function nonEmptyStringArray(value) {
  return Array.isArray(value) && value.length > 0 && value.every(nonEmptyString);
}

function resolveRepoPath(raw, root) {
  if (!nonEmptyString(raw)) return null;
  const relative = raw.replaceAll('${REPO_DIR}/', '').replace(/^\.\//, '');
  const absolute = path.resolve(root, relative);
  const fromRoot = path.relative(root, absolute);
  if (fromRoot === '..' || fromRoot.startsWith(`..${path.sep}`) || path.isAbsolute(fromRoot)) return null;
  return absolute;
}

function runnableCheck(machineChecks) {
  return Array.isArray(machineChecks)
    && machineChecks.some((check) => nonEmptyStringArray(check?.command));
}

function mechanismLink(record) {
  const enforcedBy = record?.enforcement?.enforced_by;
  return nonEmptyStringArray(enforcedBy) ? enforcedBy : [];
}

function recordErrors(record, root) {
  const errors = [];
  const id = nonEmptyString(record.id) ? record.id : '(missing id)';
  const date = record.date;
  const dated = typeof date === 'string' && DATE_FORMAT.test(date);
  if (!dated) errors.push(`${id}: date must be YYYY-MM-DD`);
  // Undated records cannot prove they are historical, so the full chain applies.
  if (dated && date < SCHEMA_START) return errors;

  for (const [field, label] of [
    ['class', 'problem class'],
    ['what_happened', 'what happened'],
    ['classic_pattern', 'classic problem'],
    ['best_known_solution', 'best known solution'],
    ['lesson_id', 'lesson id'],
  ]) {
    if (!nonEmptyString(record[field])) errors.push(`${id}: missing ${label}`);
  }
  if (!nonEmptyString(record.root_cause_evidence)) {
    errors.push(`${id}: missing root cause evidence`);
  } else if (!EVIDENCE_ANCHOR.test(record.root_cause_evidence)) {
    errors.push(`${id}: root cause evidence cites nothing checkable (path, command output, issue or commit)`);
  }
  if (!nonEmptyStringArray(record.research_sources)) {
    errors.push(`${id}: missing research sources (classic-problem research the fix was chosen from)`);
  }
  if (!nonEmptyStringArray(record.options_considered)) {
    errors.push(`${id}: missing options considered (compared expert or mature solutions)`);
  }

  const hasRegression = runnableCheck(record.machine_checks);
  const enforcedBy = mechanismLink(record);
  if (!hasRegression && enforcedBy.length === 0) {
    errors.push(`${id}: fix has no runnable regression check and no mechanism link`);
  }
  for (const entry of enforcedBy) {
    const resolved = resolveRepoPath(entry, root);
    if (!resolved || !existsSync(resolved)) {
      errors.push(`${id}: mechanism link does not exist in the repository: ${entry}`);
    }
  }
  for (const check of Array.isArray(record.machine_checks) ? record.machine_checks : []) {
    if (!nonEmptyString(check?.test_file)) continue;
    const resolved = resolveRepoPath(check.test_file, root);
    if (!resolved || !existsSync(resolved)) {
      errors.push(`${id}: regression test file does not exist: ${check.test_file}`);
    }
  }
  return errors;
}

export function validateRegistry(root = DEFAULT_ROOT) {
  const registryFile = zfConfigFile(REGISTRY_PATH, root);
  if (!registryFile || !existsSync(registryFile)) {
    return { checked: 0, errors: [`${REGISTRY_PATH} is missing`] };
  }
  let registry;
  try {
    registry = JSON.parse(readFileSync(registryFile, 'utf8'));
  } catch (error) {
    return { checked: 0, errors: [`${REGISTRY_PATH} does not parse: ${error.message}`] };
  }
  const incidents = registry?.incidents;
  if (!Array.isArray(incidents)) {
    return { checked: 0, errors: [`${REGISTRY_PATH} has no incidents array`] };
  }
  const errors = incidents.flatMap((record) => recordErrors(record ?? {}, root));
  return { checked: incidents.length, errors };
}

function main(args) {
  const root = args.length > 0 ? path.resolve(args[0]) : DEFAULT_ROOT;
  const { checked, errors } = validateRegistry(root);
  if (errors.length > 0) {
    for (const error of errors) console.error(`lesson-guard-schema: ${error}`);
    console.error(`lesson-guard-schema: ${errors.length} problem(s) in ${checked} record(s); a record dated on or after ${SCHEMA_START} needs root cause evidence, problem class, classic problem, research sources, compared options and a runnable regression check or mechanism link`);
    process.exitCode = 1;
    return;
  }
  console.log(`lesson-guard-schema: ${checked} registry record(s) pass the problem-record schema`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2));
}
