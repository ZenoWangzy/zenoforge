import assert from 'node:assert/strict';
import test from 'node:test';

import { triage } from './failure-triage.mjs';

const suite = 'engine/lib.test.sh';
const base = { suites: [suite], prFiles: [], mainFiles: [], behind: 2, complete: true };

test('main changed the failing suite and the PR did not: stale-base', () => {
  assert.equal(triage({ ...base, prFiles: ['docs/note.md'], mainFiles: [suite] }), 'stale-base');
});

test('a PR path that covers the suite is attributable, and the worst suite wins', () => {
  assert.equal(triage({ ...base, prFiles: [suite], mainFiles: [suite] }), 'attributable');
  const other = 'engine/other.test.sh';
  assert.equal(triage({ ...base, suites: [suite, other], prFiles: [other], mainFiles: [suite, other] }), 'attributable');
});

test('a forced-full path on the PR is attributable', () => {
  assert.equal(triage({ ...base, prFiles: ['engine/lib.sh'], mainFiles: [suite] }), 'attributable');
});

test('missing evidence, not behind main, or package suites stay unknown', () => {
  assert.equal(triage({ ...base, mainFiles: [suite], complete: false }), 'unknown');
  assert.equal(triage({ ...base, mainFiles: [suite], behind: 0 }), 'unknown');
  assert.equal(triage({ ...base, mainFiles: [suite], suites: ['packages/shared/src/a.test.ts'] }), 'unknown');
  assert.equal(triage({ ...base, mainFiles: ['docs/note.md'] }), 'unknown');
  assert.equal(triage({ ...base, suites: [] }), 'unknown');
});
