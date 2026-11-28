import assert from 'node:assert/strict';
import test from 'node:test';

import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  entryCheckFailures,
  exactSecondFailures,
  formatLintRefusal,
  lessonLints,
  lessonLintRegistry,
  runLessonLints,
  utcStampLint,
  utcStampFailures,
} from './lesson-lints.mjs';

function lintRepoFixture({ headFiles = {}, rankingRows = [], touchRanking = false } = {}) {
  const repo = mkdtempSync(path.join(os.tmpdir(), 'lesson-lints-'));
  const git = (...args) => execFileSync('git', ['-C', repo, ...args], { stdio: 'ignore' });
  const now = Date.now();
  const daysAgo = (days) => new Date(now - days * 24 * 60 * 60 * 1000).toISOString();
  const commitAt = (date, message) => execFileSync('git', ['-C', repo, 'commit', '-qm', message], {
    stdio: 'ignore',
    env: { ...process.env, GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date },
  });
  mkdirSync(path.join(repo, 'engine/lib.d'), { recursive: true });
  mkdirSync(path.join(repo, 'lessons'), { recursive: true });
  writeFileSync(path.join(repo, 'engine/lib.d/issue-state.sh'), 'old state writer\njq_arg_file() { :; }\n');
  writeFileSync(path.join(repo, 'engine/lesson-lints.mjs'), "classTag: 'exact-second-elapsed-grep'\n");
  mkdirSync(path.join(repo, 'engine'), { recursive: true });
  writeFileSync(path.join(repo, 'engine/jq-arg-safety.test.sh'), 'scan_files() { :; }\njq --slurpfile data file\n');
  const defaultSources = new Set(['engine/lib.d/issue-state.sh', 'engine/jq-arg-safety.test.sh']);
  for (const file of new Set(lessonLints.flatMap((lint) => Object.keys(lint.files)))) {
    if (defaultSources.has(file)) continue;
    const fixturePath = path.join(repo, file);
    mkdirSync(path.dirname(fixturePath), { recursive: true });
    writeFileSync(fixturePath, 'baseline fixture\n');
  }
  const rankingByLesson = new Map([
    { lesson_id: 'V936', incident_class_tag: 'state-single-writer', recurrence_count: 2 },
    { lesson_id: 'V975', incident_class_tag: 'large-json-never-on-argv', recurrence_count: 2 },
    ...rankingRows,
  ].map((row) => [row.lesson_id, row]));
  const ranking = { ranking: [...rankingByLesson.values()] };
  writeFileSync(path.join(repo, 'lessons/recurrence-ranking.json'), JSON.stringify(ranking));
  for (const file of Object.keys(headFiles)) {
    const fixturePath = path.join(repo, file);
    mkdirSync(path.dirname(fixturePath), { recursive: true });
    writeFileSync(fixturePath, 'baseline fixture\n');
  }
  git('init', '-q');
  git('config', 'user.name', 'Lesson lint test');
  git('config', 'user.email', 'lesson-lint-test@example.invalid');
  git('add', '.');
  commitAt(daysAgo(61), 'old lint');
  writeFileSync(path.join(repo, 'engine/lesson-lints.mjs'), "classTag: 'exact-second-elapsed-grep'\nlesson: 'V936'\n");
  git('add', '.');
  commitAt(daysAgo(10), 'young lint');
  const base = execFileSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  writeFileSync(path.join(repo, 'engine/lib.d/issue-state.sh'), 'unguarded state writer\njq_arg_file() { :; }\nstamp=$(date +%Y-%m-%dT%H:%M:%SZ)\n');
  for (const [file, source] of Object.entries(headFiles)) {
    writeFileSync(path.join(repo, file), source);
  }
  if (touchRanking) {
    writeFileSync(path.join(repo, 'lessons/recurrence-ranking.json'), JSON.stringify({ ...ranking, fixture_head: true }));
  }
  git('add', '.');
  commitAt(new Date(now).toISOString(), 'head');
  return { repo, base, head: 'HEAD', cleanup: () => rmSync(repo, { recursive: true, force: true }) };
}

const lessonLintFixtures = [
  {
    classTag: 'state-single-writer',
    sources: {
      'engine/lib.d/issue-state.sh': 'issue_transition_allowed() { :; }\nISSUE_TRANSITION_TABLE[open]=ready\n__issue_transition_lock_held=1\njq_arg_file() { :; }\n',
    },
  },
  {
    classTag: 'land-queue-serializes-nonproduct-landings',
    sources: {
      'engine/land-direct-main.sh': 'mem_mb >= 3072\nrequired_mb=3072\n',
      'engine/land-queue.sh': 'bash "${ZF_ENGINE_LIVE:-$QUEUE_ENGINE_DIR}/land-direct-main.sh" "$@"\n',
    },
  },
  {
    classTag: 'ci-runner-label-pool',
    sources: {
      'scripts/ops/provision-cihost-ci-runner.sh': 'runner_labels="cihost-ci,cihost-ci-testcontainers,cihost-ci-light,vecta-suites"\ninstall -d -o "$runner_user" -g "$runner_user" -m 0700 "$runner_home/.config"\n',
    },
  },
  {
    classTag: 'large-json-never-on-argv',
    sources: {
      'engine/lib.d/issue-state.sh': 'jq_arg_file() { :; }\n',
      'engine/jq-arg-safety.test.sh': 'scan_files() { :; }\njq --slurpfile data file\n',
    },
  },
  {
    classTag: 'postsubmit-in-progress-masks-red',
    sources: {
      'engine/lib.d/ci-checks.sh': 'ci_main_completed_push_runs() { :; }\nstatus=completed&per_page=25&page=1\n',
    },
  },
  {
    classTag: 'commit-preflight-lone-negative',
    sources: {
      'scripts/branch-delivery-preflight.mjs': "option('--mode') ?? 'commit'\n['commit', 'push', 'release']\n",
    },
    touchRanking: true,
  },
  {
    classTag: 'worktree-stats-per-worktree-scans',
    sources: {
      'engine/worktree-lifecycle.sh': 'load_live_state() { :; }\nPROCESS_ARGS="$(ps -eo pid=,args=)"\nstats() {\n  load_live_state || return 1\n}\n',
    },
  },
  {
    classTag: 'worktree-reap-issue-query-failure',
    sources: {
      'engine/worktree-lifecycle.sh': 'load_rescue_issue_states() { :; }\nif ! load_rescue_issue_states; then\n  echo "rescue-ref sweep aborted"\n  phase=worktree-reap:rescue-issue-query\nfi\n',
    },
  },
  {
    classTag: 'write-guard-blocked-scratch-homes',
    sources: {
      'engine/write-guard.sh': '[[ -e "$agent_home/checkout" ]] || return 0\n',
    },
  },
  {
    classTag: 'github-egress-transient-fetch-retry',
    sources: {
      'engine/lib.d/transport.sh': 'git_fetch_bounded() { :; }\nZF_GIT_FETCH_TRANSIENT_RETRIES:-2\nhttp.lowSpeedTime=20\n',
    },
  },
  {
    classTag: 'hand-addendum-delivery-1011',
    sources: {
      'engine/land-queue.sh': 'hand_addendum_pending_for_report() { :; }\nqueue_hand_pending_addendum() { :; }\n.addenda.lock\n',
    },
  },
  {
    classTag: 'cihost-ci-rootless-anonymous-volume-age-bound',
    sources: {
      'engine/systemd/cihost-ci-rootless-volume-reclaim.sh': '24 hours ago\nlabel=com.docker.volume.anonymous\ndangling=true\n',
    },
  },
  {
    classTag: 'cihost-nexus-soft-deleted-blobs-fill-root',
    sources: {
      'scripts/ops/nexus-retention.py': 'blobstore.compact\nassetBlob.cleanup\n',
    },
  },
  {
    classTag: 'focused-test-filename-reference-miss',
    sources: {
      'engine/focused-test-paths.mjs': 'function filenameReferencedTests(files, filename) {\n  args.push(\'-F\', filename);\n}\n',
    },
  },
  {
    classTag: 'transient-github-reads-in-direct-main-landing',
    sources: {
      'engine/land-direct-main.sh': 'land_git_transport_retry() { :; }\n',
      'engine/land-queue.sh': '-E "http_proxy=$proxy_url"\nEnvironmentFile=$AGENT_HOME/env\n',
    },
  },
  {
    classTag: 'postsubmit-read-failed-landed-push',
    sources: {
      'engine/land-direct-main.sh': 'land_git_transport_retry land_git_network push\nlanding remains successful\n',
    },
  },
  {
    classTag: 'land-queue-network-and-worktree-recovery',
    sources: {
      'engine/land-queue.sh': 'QUEUE_SNAPSHOT_ERROR\ncould not recreate missing worktree from branch=\n',
    },
  },
  {
    classTag: 'failure-decisive-line-blind-rerun',
    sources: {
      'engine/lib.d/implement-gates.sh': 'implement_failure_class_key() { :; }\nblind_rerun_failure_paths() { :; }\n',
      'engine/lib.sh': 'last two implement failures share a stage\n',
    },
  },
  {
    classTag: 'cihost-units-landed-never-installed',
    sources: {
      'engine/land-direct-main.sh': 'cihost_sync_path() { :; }\nlanded but not installed on cihost\n',
    },
  },
  {
    classTag: 'hand-efficiency-regression-alarm',
    sources: {
      'engine/night/efficiency-regression.mjs': 'MIN_HISTORY_HOURS = 24\nfunction violates() { return false; }\n',
    },
  },
  {
    classTag: 'paused-implement-held-hands-redispatch',
    sources: {
      'engine/lib.d/holds.sh': 'scheduler_requeue_issue "$n" "hold owner $dead_owner is inactive"\nscheduler_requeue_issue "$n" "hold expired; $release_condition"\n',
      'engine/supervisor-holds.sh': 'scheduler_requeue_issue "$n" "supervisor hold $kind has no live owner"\n',
    },
  },
  {
    classTag: 'release-chain-gate-blames-preexisting-owner-content',
    sources: {
      'scripts/release/run-release.sh': 'record_preexisting_timing_miss() { :; }\nrecord_preexisting_e2e_failure() { :; }\n',
    },
  },
  {
    classTag: 'direct-main-dagger-prepush-suites',
    sources: {
      'engine/land-direct-main.sh': 'dispatch_pipeline_suites_after_landing "$main_sha"\nland_main_rebase_after_advance() { :; }\n',
    },
  },
  {
    classTag: 'worktree-reap-multi-commit-patch-equivalence',
    sources: {
      'engine/worktree-lifecycle.sh': 'main_patch_index_write_state\npatches_in_main\nmerged_pr_content_is_reachable\n',
    },
  },
];

function runLintClassFixture(lint, sources, touchRanking = false) {
  const fixture = lintRepoFixture({
    headFiles: sources,
    rankingRows: [{
      lesson_id: lint.lesson,
      incident_class_tag: lint.classTag,
      recurrence_count: 2,
    }],
    touchRanking,
  });
  const lines = [];
  try {
    runLessonLints({ ...fixture, log: (line) => lines.push(line) });
    const line = lines.find((entry) => entry.includes(`incident_class=${lint.classTag} `));
    assert.ok(line, `${lint.classTag} should be evaluated`);
    return line;
  } finally {
    fixture.cleanup();
  }
}

test('each registered lesson lint refuses a bad fixture and passes a good fixture', async (t) => {
  assert.deepEqual(
    lessonLintFixtures.map(({ classTag }) => classTag).sort(),
    lessonLints.map(({ classTag }) => classTag).sort(),
  );
  for (const lint of lessonLints) {
    const fixture = lessonLintFixtures.find(({ classTag }) => classTag === lint.classTag);
    const badSources = Object.fromEntries(Object.keys(fixture.sources).map((file) => [file, 'bad fixture\n']));
    await t.test(lint.classTag, () => {
      assert.match(runLintClassFixture(lint, badSources, fixture.touchRanking), /verdict=fail\b/);
      assert.match(runLintClassFixture(lint, fixture.sources, fixture.touchRanking), /verdict=pass\b/);
    });
  }
});

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

test('every registered lesson lint names its alternative and documentation when it refuses', () => {
  for (const lint of lessonLintRegistry) {
    assert.equal(typeof lint.alternative, 'string', `${lint.classTag} must register an alternative`);
    assert.notEqual(lint.alternative.trim(), '', `${lint.classTag} must register a non-empty alternative`);
    const refusal = formatLintRefusal(lint.alternative, 'fixture finding');
    assert(refusal.includes('found="fixture finding"'));
    assert(refusal.includes(`alternative=${JSON.stringify(lint.alternative)}`));
    assert(refusal.includes('documented_in=engine/lesson-lints.mjs'));
  }
  assert.throws(() => formatLintRefusal('', 'fixture finding'), /blessed alternative/);
  assert.throws(() => formatLintRefusal(undefined, 'fixture finding'), /blessed alternative/);
  const fixture = lintRepoFixture();
  const lines = [];
  try {
    assert.equal(runLessonLints({ ...fixture, log: (line) => lines.push(line) }), 2);
    assert(lines.some((line) => line.includes('REFUSAL found=')
      && line.includes('alternative=')
      && line.includes('documented_in=engine/lesson-lints.mjs')));
  } finally {
    fixture.cleanup();
  }
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

test('a lesson lint without a mode prints would-fail and does not fail the run', () => {
  const fixture = lintRepoFixture();
  const lint = lessonLints[0];
  const standaloneLint = utcStampLint;
  const originalMode = lint.mode;
  const originalStandaloneMode = standaloneLint.mode;
  const lines = [];
  try {
    delete lint.mode;
    delete standaloneLint.mode;
    assert.equal(runLessonLints({ ...fixture, log: (line) => lines.push(line) }), 0, 'missing mode defaults to observe');
    assert(lines.some((line) => line.includes('lesson=V936') && line.includes('verdict=would-fail')));
    assert(lines.some((line) => line.includes('local-tz-z-stamp') && line.includes('verdict=would-fail')));
  } finally {
    if (originalMode === undefined) delete lint.mode;
    else lint.mode = originalMode;
    if (originalStandaloneMode === undefined) delete standaloneLint.mode;
    else standaloneLint.mode = originalStandaloneMode;
    fixture.cleanup();
  }
});

test('the ledger appends one row for each triggered lesson and standalone lint', () => {
  const fixture = lintRepoFixture();
  const ledger = path.join(fixture.repo, 'state/lesson-lints.jsonl');
  try {
    assert.equal(runLessonLints({ ...fixture, ledger, log: () => {} }), 2);
    const rows = readFileSync(ledger, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
    assert.deepEqual(rows.map(({ lesson, classTag, verdict }) => ({ lesson, classTag, verdict })), [
      { lesson: 'V936', classTag: 'state-single-writer', verdict: 'fail' },
      { lesson: 'V975', classTag: 'large-json-never-on-argv', verdict: 'pass' },
      { lesson: 'none', classTag: 'local-tz-z-stamp', verdict: 'fail' },
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
    }), 2);
    assert.equal(lines.filter((line) => line.includes('ledger-write-failed')).length, 1);
  } finally {
    fixture.cleanup();
  }
});

test('the lifecycle report lists old zero-trigger lints and excludes a young lint', () => {
  const fixture = lintRepoFixture();
  const ledger = path.join(fixture.repo, 'state/empty.jsonl');
  try {
    const script = fileURLToPath(new URL('./lesson-lints.mjs', import.meta.url));
    const report = execFileSync(process.execPath, [
      script,
      '--lifecycle',
      '--repo', fixture.repo,
      '--ledger', ledger,
      '--days', '30',
    ], { encoding: 'utf8' });
    assert(report.includes('classTag=exact-second-elapsed-grep mode=enforce triggers=0 fails=0 would-fails=0 age_days=61 age_source=git-log-class'));
    assert(report.includes('lesson=V936 classTag=state-single-writer mode=enforce triggers=0 fails=0 would-fails=0 age_days=10 age_source=git-log-lesson'));
    const retirementCandidates = report.split('candidates-to-retire:\n')[1];
    assert(retirementCandidates.includes('classTag=exact-second-elapsed-grep'));
    assert(!retirementCandidates.includes('classTag=state-single-writer'));
  } finally {
    fixture.cleanup();
  }
});
