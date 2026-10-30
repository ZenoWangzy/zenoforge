#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const defaultRepo = path.resolve(scriptDir, '..');
const registryPath = 'engine/state/incident-guards.json';
const outputPath = 'lessons/recurrence-ranking.json';

function textValues(value) {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value)) return value.flatMap(textValues);
  if (value && typeof value === 'object') {
    return Object.entries(value)
      .filter(([key]) => !['siblings', 'recurrence_candidates_checked', 'machine_checks'].includes(key))
      .flatMap(([, child]) => textValues(child));
  }
  return [];
}

function refsFor(incident) {
  const sources = [
    incident.observed_refs,
    incident.what_happened,
    incident.recurrence_difference,
    incident.fix_commits,
    incident.repair_commits,
    incident.revert_commits,
    incident.commit_refs,
  ];
  const text = sources.flatMap(textValues).join('\n');
  const issueRefs = new Set();
  for (const match of text.matchAll(/#([1-9][0-9]{1,})\b/g)) issueRefs.add(`#${match[1]}`);
  for (const match of text.matchAll(/\b(?:issue|PR)\s+([1-9][0-9]{1,})\b/gi)) issueRefs.add(`#${match[1]}`);
  const commitRefs = new Set();
  for (const match of text.matchAll(/\b([0-9a-f]{7,40})\b/gi)) commitRefs.add(match[1].toLowerCase());
  return {
    issue_refs: [...issueRefs].sort((a, b) => Number(a.slice(1)) - Number(b.slice(1))),
    commit_refs: [...commitRefs].sort(),
  };
}

export function parseIncidentHistory(history) {
  const commits = new Map();
  const records = new Map();
  let currentCommit = null;
  let currentSubject = '';
  let currentRecord = null;
  const saveRecord = () => {
    if (!currentRecord) return;
    if (!records.has(currentRecord.id)) records.set(currentRecord.id, {
      ...currentRecord,
      record_commit: { sha: currentCommit, subject: currentSubject },
    });
    currentRecord = null;
  };
  for (const line of history.split(/\r?\n/)) {
    const header = line.match(/^([0-9a-f]{40})\t(.*)$/i);
    if (header) {
      saveRecord();
      currentCommit = header[1].toLowerCase();
      currentSubject = header[2];
      continue;
    }
    const addedIncident = line.match(/^\+ {6}"id": "([^"]+)"\s*,?\s*$/);
    if (currentCommit && addedIncident) {
      saveRecord();
      currentRecord = { id: addedIncident[1] };
      if (!commits.has(addedIncident[1])) {
        commits.set(addedIncident[1], { sha: currentCommit, subject: currentSubject });
      }
      continue;
    }
    const addedField = line.match(/^\+ {6}"(lesson_id|class|incident_class|recurs_of)":\s*(.+?)\s*,?\s*$/);
    if (currentRecord && addedField) {
      try {
        currentRecord[addedField[1]] = JSON.parse(addedField[2].replace(/,$/, ''));
      } catch {
        // Malformed historical fragments do not replace a row from the current registry.
      }
    }
    if (currentRecord && /^\+ {6}\},?$/.test(line)) {
      saveRecord();
    }
  }
  saveRecord();
  return { recordCommits: commits, historicalRecords: records };
}

export function parseRecordCommitHistory(history) {
  return parseIncidentHistory(history).recordCommits;
}

export function buildLessonRecurrenceRanking(registry, history = {}) {
  if (!registry || !Array.isArray(registry.incidents)) {
    throw new Error('incident registry must contain an incidents array');
  }
  const recordCommits = history instanceof Map ? history : (history.recordCommits ?? new Map());
  const historicalRecords = history instanceof Map ? new Map() : (history.historicalRecords ?? new Map());
  const lessonAliases = history instanceof Map ? new Map() : (history.lessonAliases ?? new Map());
  const commitSubjects = history instanceof Map ? new Map() : (history.commitSubjects ?? new Map());
  const incidents = registry.incidents;
  const byId = new Map();
  const byLessonId = new Map();
  for (const incident of incidents) {
    if (typeof incident.id !== 'string' || incident.id.length === 0) {
      throw new Error('every incident needs a non-empty id');
    }
    if (byId.has(incident.id)) throw new Error(`duplicate incident id: ${incident.id}`);
    byId.set(incident.id, incident);
    if (typeof incident.lesson_id === 'string') {
      const matches = byLessonId.get(incident.lesson_id) ?? [];
      matches.push(incident);
      byLessonId.set(incident.lesson_id, matches);
    }
  }

  const rootsById = new Map(incidents
    .filter((incident) => !incident.recurs_of || incident.recurs_of === 'none')
    .map((incident) => [incident.id, incident]));
  const rootByIncident = new Map();
  const unresolved = [];
  const parentFor = (reference) => {
    if (byId.has(reference)) return byId.get(reference);
    const lessonMatches = byLessonId.get(reference) ?? [];
    const lessonRoot = lessonMatches.find((incident) => !incident.recurs_of || incident.recurs_of === 'none');
    if (lessonRoot) return lessonRoot;
    if (lessonMatches.length === 1) return lessonMatches[0];
    if (historicalRecords.has(reference)) return historicalRecords.get(reference);
    const historicalLesson = [...historicalRecords.values()]
      .find((incident) => incident.lesson_id === reference && (!incident.recurs_of || incident.recurs_of === 'none'));
    return historicalLesson ?? lessonAliases.get(reference) ?? null;
  };
  function rootFor(incident) {
    if (rootByIncident.has(incident.id)) return rootByIncident.get(incident.id);
    const parentId = incident.recurs_of;
    if (!parentId || parentId === 'none') return incident;
    const parent = parentFor(parentId);
    if (!parent) return null;
    const resolved = rootFor(parent);
    if (resolved) rootByIncident.set(incident.id, resolved);
    return resolved;
  }

  const grouped = new Map([...rootsById.keys()].map((id) => [id, []]));
  for (const incident of incidents) {
    if (!incident.recurs_of || incident.recurs_of === 'none') continue;
    const root = rootFor(incident);
    if (!root) {
      unresolved.push({ id: incident.id, lesson_id: incident.lesson_id ?? null, recurs_of: incident.recurs_of });
      continue;
    }
    if (!grouped.has(root.id)) {
      rootsById.set(root.id, root);
      grouped.set(root.id, []);
    }
    grouped.get(root.id).push(incident);
  }

  const rows = [...rootsById.values()].map((root) => {
    const recurrences = (grouped.get(root.id) ?? []).map((incident) => {
      const refs = refsFor(incident);
      const explicitFixes = Array.isArray(incident.fix_commits) ? incident.fix_commits : [];
      const explicitRepairs = Array.isArray(incident.repair_commits) ? incident.repair_commits : [];
      const explicitReverts = Array.isArray(incident.revert_commits) ? incident.revert_commits : [];
      const fixes = [...new Set([...explicitFixes, ...explicitRepairs].map(String))].sort();
      const reverts = [...new Set(explicitReverts.map(String))].sort();
      const recordCommit = recordCommits.get(incident.id) ?? null;
      const referencedCommits = [...new Set([...refs.commit_refs, ...fixes, ...reverts])].sort();
      const commitEvidence = referencedCommits.map((reference) => {
        const matches = [...commitSubjects.entries()].filter(([sha]) => sha === reference
          || (sha.startsWith(reference) && reference.length >= 7)
          || (reference.startsWith(sha) && sha.length >= 7));
        const commit = matches.length === 1 ? matches[0] : null;
        const fullSha = commit?.[0] ?? reference;
        const subject = commit?.[1] ?? null;
        const role = reverts.includes(reference) || /^revert\b/i.test(subject ?? '')
          ? 'revert'
          : fixes.includes(reference) ? 'fix' : 'evidence';
        return {
          type: role === 'fix' ? 'fix-commit' : role === 'revert' ? 'revert-commit' : 'commit',
          ref: fullSha,
          ...(subject ? { subject } : {}),
        };
      });
      return {
        incident_id: incident.id,
        lesson_id: incident.lesson_id ?? null,
        incident_class_tag: incident.incident_class ?? root.incident_class ?? root.id,
        date: incident.date ?? null,
        evidence: [
          ...refs.issue_refs.map((ref) => ({ type: 'issue-or-pr', ref })),
          ...commitEvidence,
          ...(recordCommit ? [{ type: 'incident-record-commit', ref: recordCommit.sha, subject: recordCommit.subject }] : []),
        ],
      };
    }).sort((a, b) => (a.date ?? '').localeCompare(b.date ?? '') || a.incident_id.localeCompare(b.incident_id));
    return {
      lesson_id: root.lesson_id ?? null,
      incident_id: root.id,
      historical_root: !byId.has(root.id),
      incident_class_tag: root.incident_class ?? root.id,
      incident_class: root.class ?? null,
      recurrence_count: recurrences.length,
      ...(recurrences.length ? {
        recurrences,
        root_record_commit: recordCommits.get(root.id) ?? null,
      } : {}),
    };
  });

  rows.sort((a, b) => {
    const aNumber = a.lesson_id?.match(/^V([0-9]+)$/)?.[1];
    const bNumber = b.lesson_id?.match(/^V([0-9]+)$/)?.[1];
    return b.recurrence_count - a.recurrence_count
      || (aNumber && bNumber ? Number(aNumber) - Number(bNumber) : String(a.lesson_id ?? '').localeCompare(String(b.lesson_id ?? '')))
      || String(a.incident_id).localeCompare(String(b.incident_id));
  });
  let rank = 0;
  for (const row of rows) {
    if (row.recurrence_count > 0) row.rank = ++rank;
    else row.rank = null;
  }
  return {
    schema: 'zf-lesson-recurrence-ranking/v1',
    source: registryPath,
    count_rule: 'One incident registry record with recurs_of resolving to this lesson class is one recurrence.',
    recurrent_class_count: rows.filter((row) => row.recurrence_count > 0).length,
    recurrence_event_count: rows.reduce((total, row) => total + row.recurrence_count, 0),
    unresolved_recurrences: unresolved.sort((a, b) => a.id.localeCompare(b.id)),
    ranking: rows,
  };
}

function collectRecordCommits(repo) {
  const history = execFileSync('git', [
    '-C', repo,
    'log', '--all', '--format=%H%x09%s', '--unified=0', '-p', '--', registryPath,
  ], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const subjects = execFileSync('git', ['-C', repo, 'log', '--all', '--format=%H%x09%s'], {
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
  });
  const commitSubjects = new Map();
  for (const line of subjects.split(/\r?\n/)) {
    const match = line.match(/^([0-9a-f]{40})\t(.*)$/i);
    if (match && !commitSubjects.has(match[1].toLowerCase())) {
      commitSubjects.set(match[1].toLowerCase(), match[2]);
    }
  }
  return { ...parseIncidentHistory(history), lessonAliases: collectLessonAliases(repo), commitSubjects };
}

function collectLessonAliases(repo) {
  const rules = readFileSync(path.join(repo, 'lessons/RULES.md'), 'utf8');
  const aliases = new Map();
  for (const match of rules.matchAll(/^\*\*((?:V|D)[0-9]+)\*\*\s*(.+)$/gm)) {
    const lessonId = match[1];
    if (!aliases.has(lessonId)) {
      aliases.set(lessonId, {
        id: lessonId,
        lesson_id: lessonId,
        incident_class: lessonId,
        class: match[2].replace(/\*+/g, '').trim(),
        recurs_of: 'none',
      });
    }
  }
  return aliases;
}

function parseArgs(args) {
  const options = { repo: defaultRepo, output: outputPath, write: false };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--repo' || arg === '--output') {
      const value = args[index + 1];
      if (!value) throw new Error(`${arg} requires a value`);
      options[arg === '--repo' ? 'repo' : 'output'] = value;
      index += 1;
    } else if (arg === '--write') {
      options.write = true;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return options;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const repo = path.resolve(options.repo);
    const registry = JSON.parse(readFileSync(path.join(repo, registryPath), 'utf8'));
    const ranking = buildLessonRecurrenceRanking(registry, collectRecordCommits(repo));
    const target = path.resolve(repo, options.output);
    const serialized = `${JSON.stringify(ranking, null, 2)}\n`;
    if (options.write) {
      writeFileSync(target, serialized);
      console.log(`lesson-ranking: lessons=${ranking.ranking.length} recurrent=${ranking.recurrent_class_count} recurrences=${ranking.recurrence_event_count} unresolved=${ranking.unresolved_recurrences.length} output=${path.relative(repo, target)}`);
    } else {
      process.stdout.write(serialized);
    }
  } catch (error) {
    console.error(`lesson-ranking: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
