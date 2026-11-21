import assert from 'node:assert/strict';
import test from 'node:test';

import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { entryCheckFailures, exactSecondFailures, lessonLints, runLessonLints, utcStampFailures } from './lesson-lints.mjs';

function lintRepoFixture() {
  const repo = mkdtempSync(path.join(os.tmpdir(), 'lesson-lints-'));
  const git = (...args) => execFileSync('git', ['-C', repo, ...args], { stdio: 'ignore' });
  mkdirSync(path.join(repo, 'engine/lib.d'), { recursive: true });
  mkdirSync(path.join(repo, 'lessons'), { recursive: true });
  writeFileSync(path.join(repo, 'engine/lib.d/issue-state.sh'), 'old state writer\n');
  writeFileSync(path.join(repo, 'lessons/recurrence-ranking.json'), JSON.stringify({ ranking: [
    { lesson_id: 'V936', incident_class_tag: 'state-single-writer', recurrence_count: 2 },
  ] }));
  git('init', '-q');
  git('config', 'user.name', 'Lesson lint test');
  git('config', 'user.email', 'lesson-lint-test@example.invalid');
  git('add', '.');
  git('commit', '-qm', 'base');
  const base = execFileSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  writeFileSync(path.join(repo, 'engine/lib.d/issue-state.sh'), 'unguarded state writer\n');
  git('add', '.');
  git('commit', '-qm', 'head');
  return { repo, base, head: 'HEAD', cleanup: () => rmSync(repo, { recursive: true, force: true }) };
}

test('a Z stamp formatted in local time fails; a line with date -u, TZ=UTC0 or no Z passes', () => {
  const sources = {
    'engine/a.sh': [
      "printf -v now '%(%Y-%m-%dT%H:%M:%SZ)T' -1",
      "hit=1; printf -v now '%(%Y-%m-%dT%H:%M:%SZ)T' -1",
      'stamp=$(date +%Y-%m-%dT%H:%M:%SZ)',
      'stamp=$(date -d "@$t" +%FT%TZ)',
      'now=$(date -u +%Y-%m-%dT%H:%M:%SZ)',
      "TZ=UTC0 printf -v now '%(%Y-%m-%dT%H:%M:%SZ)T' -1",
      'n=$(date +%s)',
    ].join('\n'),
  };
  assert.deepEqual(utcStampFailures(Object.keys(sources), (file) => sources[file]), ['engine/a.sh:1', 'engine/a.sh:2', 'engine/a.sh:3', 'engine/a.sh:4']);
});

test('exact-second grep on an elapsed-seconds message fails; a regex over [0-9]+s passes', () => {
  const sources = {
    'engine/a.test.sh': [
      'grep -Fq "pid 9 still holds .scheduler.lock after 2s; starting anyway" "$log"',
      "grep -Fq 'intake budget spent at 3s: rows wait' \"$LOG\"",
      'grep -Eq "after [0-9]+s; starting anyway" "$log"',
      "grep -Fq 'intake skip counts refill=true' \"$LOG\"",
    ].join('\n'),
    'engine/b.mjs': 'grep -Fq "after 2s" x\n',
  };
  const failures = exactSecondFailures(Object.keys(sources), (file) => sources[file]);
  assert.deepEqual(failures, ['engine/a.test.sh:1', 'engine/a.test.sh:2']);
});

test('a deleted changed test file is skipped instead of failing the lint', () => {
  assert.deepEqual(exactSecondFailures(['engine/gone.test.sh'], () => { throw new Error('missing'); }), []);
});

test('an entry check comparing argv[1] without existsSync and realpathSync fails, in every plain form', () => {
  const sources = {
    'engine/a.mjs': 'if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {',
    'engine/b.mjs': 'if (import.meta.url === `file://${process.argv[1]}`) {',
    'engine/c.js': 'if (process.argv[1] && path.resolve(process.argv[1]) === SCRIPT_PATH) {',
    'engine/d.mjs': 'if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(SCRIPT_PATH)) {',
    'engine/e.mjs': 'if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(SCRIPT_PATH)) {',
    'engine/f.test.mjs': 'if (process.argv[1] === x) {',
  };
  assert.deepEqual(entryCheckFailures(Object.keys(sources), (file) => sources[file]), ['engine/a.mjs:1', 'engine/b.mjs:1', 'engine/c.js:1', 'engine/e.mjs:1']);
});

test('no engine script keeps a symlink-blind entry check', () => {
  const files = execFileSync('git', ['ls-files', 'engine'], { encoding: 'utf8' }).split('\n').filter(Boolean);
  assert.deepEqual(entryCheckFailures(files, (file) => readFileSync(file, 'utf8')), []);
});

test('an observe lint prints would-fail and does not fail the run', () => {
  const fixture = lintRepoFixture();
  const lint = lessonLints[0];
  const originalMode = lint.mode;
  const lines = [];
  try {
    assert.equal(runLessonLints({ ...fixture, log: (line) => lines.push(line) }), 1, 'missing mode defaults to enforce');
    lint.mode = 'observe';
    assert.equal(runLessonLints({ ...fixture, log: (line) => lines.push(line) }), 0);
    assert(lines.some((line) => line.includes('lesson=V936') && line.includes('verdict=would-fail')));
  } finally {
    if (originalMode === undefined) delete lint.mode;
    else lint.mode = originalMode;
    fixture.cleanup();
  }
});

test('the ledger appends one row for each triggered lesson and standalone lint', () => {
  const fixture = lintRepoFixture();
  const ledger = path.join(fixture.repo, 'state/lesson-lints.jsonl');
  try {
    assert.equal(runLessonLints({ ...fixture, ledger, log: () => {} }), 1);
    const rows = readFileSync(ledger, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
    assert.deepEqual(rows.map(({ lesson, classTag, verdict }) => ({ lesson, classTag, verdict })), [
      { lesson: 'V936', classTag: 'state-single-writer', verdict: 'fail' },
      { lesson: 'none', classTag: 'local-tz-z-stamp', verdict: 'pass' },
    ]);
    assert(rows.every((row) => /^[0-9a-f]{40}$/.test(row.head_sha) && Number.isFinite(Date.parse(row.utc_time))));
  } finally {
    fixture.cleanup();
  }
});

test('a ledger write failure is logged once and does not change the lint verdict', () => {
  const fixture = lintRepoFixture();
  const blocker = path.join(fixture.repo, 'not-a-directory');
  const lines = [];
  try {
    writeFileSync(blocker, 'file blocks ledger directory creation');
    assert.equal(runLessonLints({
      ...fixture,
      ledger: path.join(blocker, 'lesson-lints.jsonl'),
      log: (line) => lines.push(line),
    }), 1);
    assert.equal(lines.filter((line) => line.includes('ledger-write-failed')).length, 1);
  } finally {
    fixture.cleanup();
  }
});
