import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  buildLessonRecurrenceRanking,
  parseIncidentHistory,
  parseRecordCommitHistory,
} from './lesson-recurrence-ranking.mjs';
import {
  buildHoldLessonVerdict,
  fixGuidance,
  holdLintPaths,
  inspectSupervisorHoldSource,
} from './supervisor-hold-lesson-lint.mjs';

const rankingScript = fileURLToPath(new URL('./lesson-recurrence-ranking.mjs', import.meta.url));

const holdSource = `
supervisor_holds_snapshot() {
  case "$kind" in
    await-recurrence|manual|no-production-caller|no-reachable-path|production-access) owner_state=waiting ;;
    dependency)
      if [[ "$holder" =~ ^issue- ]] \\
        && jq -e "$impl_blocker_graph_json" >/dev/null; then owner_state=waiting
      elif [[ "$holder" =~ ^hand- ]]; then owner_state=waiting; fi
      ;;
    conclusion|implement-evidence)
      if [[ "$holder" == supervisor-inbox ]]; then owner_state=waiting; fi
      ;;
    awaiting-pr)
      pr_number="\${SUPERVISOR_HOLD_PR_NUMBER_BY_ISSUE[$n]:-}"
      pr_check_outcome="\${SUPERVISOR_HOLD_PR_CHECKS_OUTCOME_BY_ISSUE[$n]:-fail}"
      if [[ "$holder" == "pr-$pr_number" && -n "$pr_number" ]] \\
        && [[ "$pr_check_outcome" == pass || "$pr_check_outcome" == pending ]]; then
        owner_state=waiting
      fi
      ;;
  esac
  if (( expiry_epoch <= now_epoch )); then owner_state=none; fi
}

supervisor_hold_sweep() {
  if [ "$owner_state" = unknown ]; then supervisor_hold_alert_once; fi
  [[ "$age" =~ ^[0-9]+$ ]] || return 1
}
`;

function v930Ranking(count = 6) {
  return {
    ranking: [{
      lesson_id: 'V930',
      incident_class_tag: 'supervisor-hold-without-owner',
      recurrence_count: count,
    }],
  };
}

test('ranking groups direct and transitive recurrences by root lesson and keeps issue and commit evidence', () => {
  const registry = { incidents: [
    { id: 'hold-root', lesson_id: 'V930', class: 'Supervisor hold loses its owner' },
    { id: 'hold-one', lesson_id: 'V1090', recurs_of: 'hold-root', incident_class: 'supervisor-hold-without-owner', observed_refs: ['#1684'], what_happened: 'Wait state was lost.' , fix_commits: ['f5422e7'] },
    { id: 'hold-two', lesson_id: 'V1116', recurs_of: 'hold-one', observed_refs: ['#2681'], revert_commits: ['a1b2c3d'] },
    { id: 'other-root', lesson_id: 'V900', class: 'Other incident' },
    { id: 'other-one', lesson_id: 'V901', recurs_of: 'other-root', what_happened: 'Issue #777 and commit 1234567 fixed it.' },
  ] };
  const history = {
    recordCommits: new Map([
      ['hold-root', { sha: '0'.repeat(40), subject: 'record original hold incident' }],
      ['hold-one', { sha: '1'.repeat(40), subject: 'record explicit wait recurrence' }],
    ]),
    commitSubjects: new Map([
      ['f5422e7'.padEnd(40, 'a'), 'fix(agent): classify explicit supervisor holds as waiting'],
      ['a1b2c3d'.padEnd(40, 'b'), 'Revert "hold change"'],
      ['1234567'.padEnd(40, 'c'), 'fix evidence from issue 777'],
    ]),
  };
  const result = buildLessonRecurrenceRanking(registry, history);
  assert.equal(result.ranking[0].lesson_id, 'V930');
  assert.equal(result.ranking[0].recurrence_count, 2);
  assert.ok(result.ranking[0].recurrences[0].evidence.some((item) => item.ref === '#1684'));
  assert.ok(result.ranking[0].recurrences[0].evidence.some((item) => item.type === 'fix-commit' && item.ref.startsWith('f5422e7')));
  assert.ok(result.ranking[0].recurrences[0].evidence.some((item) => item.type === 'incident-record-commit' && item.ref === '1'.repeat(40)));
  assert.ok(result.ranking[0].recurrences[1].evidence.some((item) => item.type === 'revert-commit' && item.ref.startsWith('a1b2c3d')));
  assert.equal(result.recurrence_event_count, 3);
});

test('ranking puts zero-count lessons after recurring lessons and records unresolved links', () => {
  const result = buildLessonRecurrenceRanking({ incidents: [
    { id: 'zero', lesson_id: 'V1', recurs_of: 'none' },
    { id: 'recurring', lesson_id: 'V2', recurs_of: 'zero' },
    { id: 'no-recurrence', lesson_id: 'V4', recurs_of: 'none' },
    { id: 'dangling', lesson_id: 'V3', recurs_of: 'missing-root' },
  ] });
  assert.equal(result.ranking[0].lesson_id, 'V1');
  assert.equal(result.ranking[0].recurrence_count, 1);
  assert.equal(result.ranking[1].rank, null);
  assert.deepEqual(result.unresolved_recurrences, [{ id: 'dangling', lesson_id: 'V3', recurs_of: 'missing-root' }]);
});

test('ranking resolves a lesson-id recurrence when its incident record was retired', () => {
  const result = buildLessonRecurrenceRanking({ incidents: [
    { id: 'current-recurrence', lesson_id: 'V1039', recurs_of: 'D24', what_happened: 'Issues #3012 and #3013.' },
  ] }, {
    lessonAliases: new Map([['D24', { id: 'D24', lesson_id: 'D24', incident_class: 'D24', class: 'Example tools must be usable', recurs_of: 'none' }]]),
  });
  assert.equal(result.unresolved_recurrences.length, 0);
  assert.equal(result.ranking[0].lesson_id, 'D24');
  assert.equal(result.ranking[0].recurrence_count, 1);
  assert.deepEqual(result.ranking[0].recurrences[0].evidence
    .filter((item) => item.type === 'issue-or-pr').map((item) => item.ref), ['#3012', '#3013']);
});

test('ranking rejects duplicate incident ids because their recurrence evidence would be ambiguous', () => {
  assert.throws(() => buildLessonRecurrenceRanking({ incidents: [
    { id: 'duplicate', lesson_id: 'V1' },
    { id: 'duplicate', lesson_id: 'V2' },
  ] }), /duplicate incident id/);
});

test('ranking CLI reads the target incident registry before engine defaults', (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'lesson-ranking-config-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, '.zenoforge/state'), { recursive: true });
  mkdirSync(path.join(root, 'engine/state'), { recursive: true });
  mkdirSync(path.join(root, 'lessons'), { recursive: true });
  writeFileSync(path.join(root, 'lessons/RULES.md'), '**V900** config lesson\n');
  writeFileSync(path.join(root, '.zenoforge/state/incident-guards.json'),
    '{"incidents":[{"id":"config-root","lesson_id":"V900","class":"config root"}]}\n');
  writeFileSync(path.join(root, 'engine/state/incident-guards.json'),
    '{"incidents":[{"id":"engine-only","lesson_id":"V901","class":"engine default"}]}\n');
  execFileSync('git', ['init', '-q', root]);
  execFileSync('git', ['-C', root, 'config', 'user.name', 'ranking fixture']);
  execFileSync('git', ['-C', root, 'config', 'user.email', 'ranking@example.invalid']);
  execFileSync('git', ['-C', root, 'add', '.']);
  execFileSync('git', ['-C', root, 'commit', '-q', '-m', 'fixture']);

  const result = spawnSync(process.execPath, [rankingScript, '--repo', root], {
    encoding: 'utf8',
    env: {
      ...process.env,
      ZF_REPO_DIR: root,
      ZF_CONFIG_ROOT: path.join(root, '.zenoforge'),
      ZF_PACK_DIR: '',
    },
  });
  assert.equal(result.status, 0, result.stderr);
  const ranking = JSON.parse(result.stdout);
  assert.equal(ranking.source, '.zenoforge/state/incident-guards.json');
  assert.deepEqual(ranking.ranking.map((row) => row.incident_id), ['config-root']);
});

test('commit-history parser associates added incident records with their recording commit', () => {
  const history = [
    `${'a'.repeat(40)}\trecord newer incident`,
    '+      "id": "incident-two",',
    `${'b'.repeat(40)}\trecord older incident`,
    '+      "id": "incident-one",',
    '+      "id": "incident-two",',
  ].join('\n');
  const commits = parseRecordCommitHistory(history);
  assert.equal(commits.get('incident-two').sha, 'a'.repeat(40));
  assert.equal(commits.get('incident-one').subject, 'record older incident');
});

test('historical incident records keep their lesson and class when a registry row was retired', () => {
  const history = [
    `${'c'.repeat(40)}\trecord legacy class`,
    '+      "id": "legacy-root",',
    '+      "lesson_id": "V900",',
    '+      "class": "Legacy class label",',
    '+      "recurs_of": "none",',
    '+      },',
  ].join('\n');
  const parsed = parseIncidentHistory(history);
  const result = buildLessonRecurrenceRanking({ incidents: [
    { id: 'legacy-recurrence', lesson_id: 'V901', recurs_of: 'legacy-root', what_happened: 'Issue #777.' },
  ] }, parsed);
  assert.equal(result.ranking[0].lesson_id, 'V900');
  assert.equal(result.ranking[0].incident_class, 'Legacy class label');
  assert.equal(result.ranking[0].historical_root, true);
  assert.equal(result.ranking[0].root_record_commit.sha, 'c'.repeat(40));
});

test('V930 lint skips unrelated diffs and passes a structurally complete wait contract', () => {
  assert.equal(holdLintPaths(['docs/agents/issue-pipeline.md']), false);
  assert.deepEqual(inspectSupervisorHoldSource(holdSource), []);
  assert.deepEqual(buildHoldLessonVerdict({
    paths: ['engine/land-direct-main-bootstrap.sh'],
    source: holdSource,
    ranking: v930Ranking(),
  }), { verdict: 'pass', missing: [], recurrence_count: 6 });
});

test('V930 lint refuses removal of an explicit wait and prints actionable fix guidance', () => {
  const broken = holdSource.replace('manual|', '');
  const verdict = buildHoldLessonVerdict({
    paths: ['engine/supervisor-holds.sh'],
    source: broken,
    ranking: v930Ranking(),
  });
  assert.equal(verdict.verdict, 'fail');
  assert.match(verdict.missing.join('\n'), /explicit evidence wait kinds/);
  assert.match(verdict.fix_guidance, /owner_state=waiting/);
  assert.match(fixGuidance, /hold.test.sh/);
});

test('V930 lint refuses an awaiting-PR classification that ignores failed checks', () => {
  const broken = holdSource.replace('== pass || "$pr_check_outcome" == pending', '== pending');
  assert.match(inspectSupervisorHoldSource(broken).join('\n'), /matching PR and pass or pending checks/);
});

test('V930 lint detects missing dependency, inbox, expiry, unknown-alert, and age-sweep guards', () => {
  const regressions = [
    ['elif [[ "$holder" =~ ^hand- ]]; then owner_state=waiting; fi', 'elif [[ "$holder" == unrelated ]]; then owner_state=waiting; fi', /dependency waits must match/],
    ['supervisor-inbox', 'unrelated-owner', /inbox evidence waits must keep/],
    ['expiry_epoch <= now_epoch', 'expiry_epoch < now_epoch', /expired holds must remain eligible/],
    ['supervisor_hold_alert_once', 'supervisor_hold_record_merged_resolution', /unknown or unreadable holds must remain alertable/],
    ['[[ "$age" =~ ^[0-9]+$ ]]', '[[ "$age" == readable ]]', /age-based ownerless-hold sweep was removed/],
  ];
  for (const [before, after, expected] of regressions) {
    const broken = holdSource.replace(before, after);
    assert.notEqual(broken, holdSource, `fixture mutation should find ${before}`);
    assert.match(inspectSupervisorHoldSource(broken).join('\n'), expected);
  }
});

test('V930 lint refuses a missing recurrence ranking with repair guidance', () => {
  const result = buildHoldLessonVerdict({
    paths: ['lessons/recurrence-ranking.json'],
    source: holdSource,
    ranking: { ranking: [] },
  });
  assert.equal(result.verdict, 'fail');
  assert.match(result.missing.join('\n'), /recurrence ranking is missing V930/);
  assert.match(result.fix_guidance, /manual and no-reachable-path/);
});
