#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const defaultRepo = path.resolve(scriptDir, '..');
const lintPath = 'engine/supervisor-hold-lesson-lint.mjs';
const rankingPath = 'lessons/recurrence-ranking.json';
const holdPath = 'engine/supervisor-holds.sh';
const lessonId = 'V930';
const classTag = 'supervisor-hold-without-owner';
export const fixGuidance = 'Update engine/hold.test.sh and engine/land-direct-main.test.sh with the hold contract. In supervisor_holds_snapshot, classify valid, unexpired evidence waits (including manual and no-reachable-path) as owner_state=waiting; keep expired, invalid, failed, and unreadable holds alertable.';

export function holdLintPaths(paths) {
  const exact = new Set([
    holdPath,
    'engine/land-direct-main-bootstrap.sh',
    lintPath,
    rankingPath,
  ]);
  return paths.some((file) => exact.has(file));
}

function extractFunction(source, name) {
  const start = source.search(new RegExp(`^${name}\\(\\) \\{$`, 'm'));
  if (start < 0) return '';
  const tail = source.slice(start);
  const end = tail.indexOf('\n}\n', 1);
  return end < 0 ? tail : tail.slice(0, end + 2);
}

function caseBranch(source, name, nextName) {
  const escapePattern = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const start = source.search(new RegExp(`^\\s*${escapePattern(name)}\\)\\s*$`, 'm'));
  if (start < 0) return '';
  const tail = source.slice(start);
  const nextSuffix = nextName === 'esac' ? '' : '\\)';
  const end = tail.search(new RegExp(`^\\s*${escapePattern(nextName)}${nextSuffix}\\s*$`, 'm'));
  return end < 0 ? tail : tail.slice(0, end);
}

export function inspectSupervisorHoldSource(source) {
  const snapshot = extractFunction(source, 'supervisor_holds_snapshot');
  const sweep = extractFunction(source, 'supervisor_hold_sweep');
  const missing = [];
  const explicitWaits = /await-recurrence\|manual\|no-production-caller\|no-reachable-path\|production-access\)\s+owner_state=waiting/;
  if (!snapshot) missing.push('supervisor_holds_snapshot is missing');
  else {
    if (!explicitWaits.test(snapshot)) missing.push('explicit evidence wait kinds must set owner_state=waiting');
    const dependency = caseBranch(snapshot, 'dependency', 'conclusion|implement-evidence');
    const inbox = caseBranch(snapshot, 'conclusion|implement-evidence', 'awaiting-pr');
    const awaitingPr = caseBranch(snapshot, 'awaiting-pr', 'esac');
    if (!/holder.*issue-/.test(dependency) || !/impl_blocker_graph_json[\s\S]*?owner_state=waiting/.test(dependency)
      || !/holder.*hand-/.test(dependency)) {
      missing.push('dependency waits must match a live dependency or hand holder before waiting');
    }
    if (!/supervisor-inbox[\s\S]*?owner_state=waiting/.test(inbox)) {
      missing.push('inbox evidence waits must keep their supervisor-inbox holder check');
    }
    if (!/SUPERVISOR_HOLD_PR_NUMBER_BY_ISSUE[\s\S]*?"\$holder"\s*==\s*"pr-\$pr_number"[\s\S]*?\[\[\s*"\$pr_check_outcome"\s*==\s*pass\s*\|\|\s*"\$pr_check_outcome"\s*==\s*pending\s*\]\][\s\S]*?owner_state=waiting/.test(awaitingPr)) {
      missing.push('awaiting-pr waits must require the matching PR and pass or pending checks');
    }
    if (!/expiry_epoch <= now_epoch/.test(snapshot) || !/owner_state=none/.test(snapshot)) {
      missing.push('expired holds must remain eligible for the age-based sweep');
    }
  }
  if (!sweep) missing.push('supervisor_hold_sweep is missing');
  else {
    if (!/(?:owner_state=unknown|\$owner_state"\s*=\s*unknown)/.test(sweep) || !/supervisor_hold_alert_once/.test(sweep)) {
      missing.push('unknown or unreadable holds must remain alertable');
    }
    if (!/\[\[\s*"\$age"\s*=~\s*\^\[0-9\]\+\$\s*\]\]/.test(sweep)) {
      missing.push('age-based ownerless-hold sweep was removed');
    }
  }
  return missing;
}

export function buildHoldLessonVerdict({ paths, source, ranking }) {
  if (!holdLintPaths(paths)) return { verdict: 'skip', missing: [] };
  const row = ranking?.ranking?.find((entry) => entry.lesson_id === lessonId && entry.incident_class_tag === classTag);
  const missing = [];
  if (!row || !Number.isInteger(row.recurrence_count) || row.recurrence_count < 1) {
    missing.push('recurrence ranking is missing V930 supervisor-hold-without-owner evidence');
  }
  missing.push(...inspectSupervisorHoldSource(source));
  return {
    verdict: missing.length ? 'fail' : 'pass',
    missing,
    recurrence_count: row?.recurrence_count ?? 0,
    ...(missing.length ? { fix_guidance: fixGuidance } : {}),
  };
}

function parseArgs(args) {
  const options = { repo: defaultRepo, base: '', head: 'HEAD' };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--repo' || arg === '--base' || arg === '--head') {
      const value = args[index + 1];
      if (!value) throw new Error(`${arg} requires a value`);
      options[arg.slice(2)] = value;
      index += 1;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!options.base) throw new Error('--base is required');
  return options;
}

function git(repo, args, encoding = 'utf8') {
  return execFileSync('git', ['-C', repo, ...args], { encoding, maxBuffer: 8 * 1024 * 1024 });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const repo = path.resolve(options.repo);
    const paths = git(repo, ['diff', '--name-only', `${options.base}...${options.head}`, '--']).split(/\r?\n/).filter(Boolean);
    if (!holdLintPaths(paths)) process.exit(0);
    const source = git(repo, ['show', `${options.head}:${holdPath}`]);
    const ranking = JSON.parse(git(repo, ['show', `${options.head}:${rankingPath}`]));
    const result = buildHoldLessonVerdict({ paths, source, ranking });
    const line = `lesson-lint: lesson=${lessonId} incident_class=${classTag} recurrence_count=${result.recurrence_count ?? 0} verdict=${result.verdict}`;
    console.log(result.missing?.length ? `${line} missing=${result.missing.join('; ')}` : line);
    if (result.verdict === 'fail') {
      console.error(`lesson-lint: fix: ${fixGuidance}`);
      process.exitCode = 1;
    }
  } catch (error) {
    console.error(`lesson-lint: lesson=${lessonId} incident_class=${classTag} verdict=fail error=${error instanceof Error ? error.message : String(error)}`);
    console.error(`lesson-lint: fix: ${fixGuidance}`);
    process.exitCode = 1;
  }
}
