import assert from 'node:assert/strict';
import test from 'node:test';
import { assessReviewSkip, countChangedLines, mergeUnitSnapshots, recordEscapeInvalidations, riskTieredReviewStats } from './risk-tiered-review.mjs';

const head = 'a'.repeat(40);
const path = 'packages/fruit/src/config.js';
const packagePath = 'packages/fruit';
const testPath = 'packages/fruit/tests/tenant-timezone.test.sh';

test('small diffs skip review only with green escape and lint checks on the same head', () => {
  const result = assessReviewSkip({
    paths: [path],
    changedLines: 8,
    escapePackages: { [packagePath]: [{ test: testPath, command: ['bash', testPath] }] },
    lintScopes: { [path]: [{ name: 'V936/state-single-writer', mode: 'enforce' }] },
    escapeResults: [{ packagePath, test: testPath, rc: 0 }],
    lessonLintRc: 0,
    selfCheckStatus: 'pass',
    selfCheckSha: head,
    headSha: head,
  });

  assert.deepEqual(result, {
    eligible: true,
    changedLines: 8,
    paths: [path],
    checks: [
      { kind: 'escape-suite', name: `${packagePath}:${testPath}`, rc: 0 },
      { kind: 'lesson-lint', name: 'V936/state-single-writer', rc: 0 },
    ],
  });
});

test('an escape invalidates a path until its package registers a new escape test', () => {
  const input = {
    paths: [path],
    changedLines: 8,
    escapePackages: { [packagePath]: [{ test: testPath, command: ['bash', testPath] }] },
    lintScopes: { [path]: [{ name: 'V936/state-single-writer', mode: 'enforce' }] },
    escapeResults: [{ packagePath, test: testPath, rc: 0 }],
    lessonLintRc: 0,
    selfCheckStatus: 'pass',
    selfCheckSha: head,
    headSha: head,
    invalidations: [{ path, packagePath, tests: [testPath] }],
  };

  assert.equal(assessReviewSkip(input).eligible, false);

  const newTest = 'packages/fruit/tests/config-regression.test.sh';
  input.escapePackages[packagePath].push({ test: newTest, command: ['bash', newTest] });
  input.escapeResults.push({ packagePath, test: newTest, rc: 0 });
  assert.equal(assessReviewSkip(input).eligible, true);
});

test('nested package paths require every matching escape suite', () => {
  const nestedPath = 'packages/fruit/src/config.js';
  const packages = {
    'packages': [{ test: 'packages/tests/core.test.sh', command: ['bash', 'packages/tests/core.test.sh'] }],
    'packages/fruit': [{ test: 'packages/fruit/tests/tenant-timezone.test.sh', command: ['bash', 'packages/fruit/tests/tenant-timezone.test.sh'] }],
  };
  const input = {
    paths: [nestedPath],
    changedLines: 8,
    escapePackages: packages,
    lintScopes: { [nestedPath]: [{ name: 'V936/state-single-writer', mode: 'enforce' }] },
    escapeResults: [
      { packagePath: 'packages', test: 'packages/tests/core.test.sh', rc: 0 },
      { packagePath: 'packages/fruit', test: 'packages/fruit/tests/tenant-timezone.test.sh', rc: 0 },
    ],
    lessonLintRc: 0,
    selfCheckStatus: 'pass',
    selfCheckSha: head,
    headSha: head,
  };

  assert.equal(assessReviewSkip(input).eligible, true);
  input.escapeResults.pop();
  assert.equal(assessReviewSkip(input).eligible, false);
  assert.equal(recordEscapeInvalidations([nestedPath], packages, packages).length, 2);
});

test('protected paths and diffs above the small-diff limit retain review', () => {
  const input = {
    paths: [path],
    changedLines: 8,
    escapePackages: { [packagePath]: [{ test: testPath, command: ['bash', testPath] }] },
    lintScopes: { [path]: [{ name: 'V936/state-single-writer', mode: 'enforce' }] },
    escapeResults: [{ packagePath, test: testPath, rc: 0 }],
    lessonLintRc: 0,
    selfCheckStatus: 'pass',
    selfCheckSha: head,
    headSha: head,
    protectedPaths: [`${packagePath}/`],
  };

  assert.equal(assessReviewSkip(input).eligible, false);
  input.protectedPaths = [];
  input.changedLines = 81;
  assert.equal(assessReviewSkip(input).eligible, false);
});

test('binary diffs cannot count as a zero-line small diff', () => {
  assert.equal(countChangedLines('-\t-\tpackages/fruit/assets/fixture.test.sh'), null);
});

test('incident paths stay invalidated until the escape registry adds a package test', () => {
  const basePackages = { [packagePath]: [{ test: testPath, command: ['bash', testPath] }] };
  const invalidations = recordEscapeInvalidations([path], basePackages, basePackages);
  assert.deepEqual(invalidations, [{ path, packagePath, tests: [testPath] }]);

  const newTest = 'packages/fruit/tests/config-regression.test.sh';
  const headPackages = {
    [packagePath]: [...basePackages[packagePath], { test: newTest, command: ['bash', newTest] }],
  };
  assert.deepEqual(recordEscapeInvalidations([path], basePackages, headPackages), []);
});

test('seven-day reporting counts merged skips and linked escapes after their observation window', () => {
  const units = [
    { stage: 'merged', approved_sha: head, history: [
      { stage: 'review-skip', result: head, at: '2026-11-10T00:00:00Z', paths: [path] },
      { stage: 'merged', at: '2026-11-10T01:00:00Z' },
      { stage: 'review-skip-escape', at: '2026-11-13T00:00:00Z', paths: [path] },
    ] },
    { stage: 'merged', approved_sha: 'b'.repeat(40), history: [
      { stage: 'review-skip', result: 'b'.repeat(40), at: '2026-11-20T00:00:00Z', paths: [path] },
      { stage: 'merged', at: '2026-11-20T01:00:00Z' },
    ] },
  ];

  assert.deepEqual(riskTieredReviewStats(units, Date.parse('2026-11-26T00:00:00Z')), {
    maturedMergedUnits: 1,
    skippedUnits: 1,
    escapedSkippedUnits: 1,
    skipShare: 1,
    escapeShare: 1,
  });
});

test('report inputs merge archived and live units with the live copy winning', () => {
  const archived = { id: 'unit-1', stage: 'closed', history: [] };
  const live = { id: 'unit-1', stage: 'merged', history: [{ stage: 'merged' }] };
  const retired = { id: 'unit-2', stage: 'merged', history: [{ stage: 'merged' }] };

  assert.deepEqual(mergeUnitSnapshots(
    { units: [archived, retired] },
    { units: [live] },
  ), [live, retired]);
});

test('a later LLM approval means the merged unit did not skip review', () => {
  const unit = { stage: 'merged', approved_sha: head, history: [
    { stage: 'review-skip', result: head, at: '2026-11-10T00:00:00Z', paths: [path] },
    { stage: 'review-approve', result: head, at: '2026-11-10T00:30:00Z' },
    { stage: 'merged', at: '2026-11-10T01:00:00Z' },
  ] };

  assert.deepEqual(riskTieredReviewStats([unit], Date.parse('2026-11-26T00:00:00Z')), {
    maturedMergedUnits: 1,
    skippedUnits: 0,
    escapedSkippedUnits: 0,
    skipShare: 0,
    escapeShare: null,
  });
});
