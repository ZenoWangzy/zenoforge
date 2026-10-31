import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { PACK_DIR, zfConfigFile } from './pack-dir.mjs';

function migrationDirectory() {
  const file = zfConfigFile('release.json');
  const config = file ? JSON.parse(readFileSync(file, 'utf8')) : {};
  const path = config.migration?.path;
  if (typeof path !== 'string' || !path || path.startsWith('/') || path.split('/').includes('..')) {
    throw new Error('release.json: migration.path must be a nonempty relative path');
  }
  return path.replace(/\/+$/, '') + '/';
}
const journalPath = () => migrationDirectory() + 'meta/_journal.json';
function message(key, fallback) {
  const file = zfConfigFile('release.json');
  return (file ? JSON.parse(readFileSync(file, 'utf8')) : {}).migration?.orderMessages?.[key] ?? fallback;
}

export function fruitMigrationTag(path) {
  if (!path.startsWith(migrationDirectory())) return null;
  return /^(\d{4}_[^/]+)\.sql$/.exec(path.slice(migrationDirectory().length))?.[1] ?? null;
}

const tagNumber = (tag) => Number(tag.slice(0, 4));

// New journal entries (tags not on main) must carry a `when` later than every
// `when` already on main.
export function journalWhenErrors({ mainJournal, headJournal }) {
  const mainTags = new Set(mainJournal.entries.map((entry) => entry.tag));
  const mainMax = Math.max(...mainJournal.entries.map((entry) => entry.when));
  return headJournal.entries
    .filter((entry) => !mainTags.has(entry.tag) && !(entry.when > mainMax))
    .map((entry) => `${entry.tag} has journal when ${entry.when}, not later than main's latest ${mainMax}; `
      + message('stale', 'The migration would be skipped. Merge the base branch and renumber the migration.'));
}

// Open, non-draft PRs that add a lower-numbered migration than this PR.
// A draft cannot merge; when it is marked ready its number and `when` are
// below main's and the journal check above (plus the renumberer) forces it up.
export function lowerOpenMigrationBlockers({ prNumber, prFiles, openPrs, mainTags }) {
  const added = (files) => files.map(fruitMigrationTag).filter((tag) => tag && !mainTags.has(tag));
  const mine = added(prFiles).map(tagNumber);
  if (mine.length === 0) return [];
  const lowest = Math.min(...mine);
  const blockers = [];
  for (const pr of openPrs) {
    if (pr.number === prNumber || pr.isDraft) continue;
    for (const tag of added(pr.files.map((file) => file.path))) {
      if (tagNumber(tag) < lowest) blockers.push(`#${pr.number} (${tag})`);
    }
  }
  return blockers;
}

const runOptions = { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 };

function ghJson(run, args) {
  return JSON.parse(run('gh', args, runOptions));
}

function journalAt(run, repo, ref) {
  return JSON.parse(run('gh', [
    'api', `repos/${repo}/contents/${journalPath()}?ref=${ref}`,
    '-H', 'Accept: application/vnd.github.raw',
  ], runOptions));
}

function completePrFiles(run, repo, pr, prNumber) {
  if (pr.files.length === pr.changedFiles) return;
  // gh 2.45 supports pagination with --jq, but not --slurp (same as the reservation gate).
  pr.files = run('gh', [
    'api', `repos/${repo}/pulls/${prNumber}/files?per_page=100`, '--paginate', '--jq', '.[].filename',
  ], runOptions).split('\n').filter(Boolean).map((path) => ({ path }));
  if (pr.files.length !== pr.changedFiles) throw new Error(`incomplete file list for PR #${prNumber}`);
}

export function mergeGate({ repo, prNumber, head, run = execFileSync }) {
  const pr = ghJson(run, ['pr', 'view', String(prNumber), '--repo', repo,
    '--json', 'files,changedFiles,headRefOid']);
  completePrFiles(run, repo, pr, prNumber);
  const prFiles = pr.files.map((file) => file.path);
  if (!prFiles.some(fruitMigrationTag)) return [];
  const headSha = head || pr.headRefOid;
  const mainJournal = journalAt(run, repo, 'main');
  const mainTags = new Set(mainJournal.entries.map((entry) => entry.tag));
  const reasons = journalWhenErrors({ mainJournal, headJournal: journalAt(run, repo, headSha) });
  const openPrs = ghJson(run, ['pr', 'list', '--repo', repo, '--base', 'main', '--state', 'open',
    '--limit', '1000', '--json', 'number,isDraft,files,changedFiles']);
  if (openPrs.length >= 1000) throw new Error('open PR list reached the 1000-PR limit');
  for (const open of openPrs) {
    if (open.number !== prNumber && !open.isDraft) completePrFiles(run, repo, open, open.number);
  }
  const blockers = lowerOpenMigrationBlockers({ prNumber, prFiles, openPrs, mainTags });
  if (blockers.length > 0) {
    reasons.push(`${message('blockers', 'open PRs carry lower-numbered migrations and must merge first:')} ${blockers.join(', ')}`);
  }
  return reasons;
}

export function ciCheck({ baseRef = 'origin/main', run = execFileSync, readFile = readFileSync } = {}) {
  const mainJournal = JSON.parse(run('git', ['show', `${baseRef}:${journalPath()}`], runOptions));
  const headJournal = JSON.parse(readFile(journalPath(), 'utf8'));
  return journalWhenErrors({ mainJournal, headJournal });
}

function option(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const configFile = zfConfigFile('release.json');
    const config = configFile ? JSON.parse(readFileSync(configFile, 'utf8')) : {};
    if (!config.migration?.path && PACK_DIR) {
      const legacy = join(PACK_DIR, 'check-fruit-migration-order.mjs');
      const result = spawnSync(process.execPath, [legacy, ...process.argv.slice(2)], { stdio: 'inherit' });
      if (result.error) throw result.error;
      process.exit(result.status ?? 2);
    }
    migrationDirectory();
    let reasons;
    if (process.argv.includes('--merge-gate')) {
      const prNumber = Number(option('--pr'));
      if (!Number.isInteger(prNumber) || prNumber <= 0) throw new Error('--merge-gate needs --pr N');
      const repo = option('--repo') || process.env.REPO || process.env.GITHUB_REPOSITORY;
      if (!repo) throw new Error('--merge-gate needs --repo or REPO');
      reasons = mergeGate({ repo, prNumber, head: option('--head') });
    } else if (process.argv.includes('--ci')) {
      reasons = ciCheck({ baseRef: option('--base') ?? 'origin/main' });
    } else {
      throw new Error('usage: check-fruit-migration-order.mjs --ci [--base REF] | --merge-gate --pr N [--head SHA] [--repo R]');
    }
    for (const reason of reasons) console.log(`migration-order: ${reason}`);
    if (reasons.length > 0) process.exitCode = 1;
    else console.log(message('passed', 'migration order passed.'));
  } catch (error) {
    console.log(`migration-order: ${message('unverified', 'could not verify migration order')}: ${error.message}`);
    process.exitCode = 2;
  }
}
