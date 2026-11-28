import assert from 'node:assert/strict';
import test from 'node:test';

import { findForbiddenVectaNames } from './vecta-name-lint.mjs';

test('finds added Vecta names in production engine files outside config defaults', () => {
  const diff = [
    'diff --git a/engine/new-runner.mjs b/engine/new-runner.mjs',
    '--- a/engine/new-runner.mjs',
    '+++ b/engine/new-runner.mjs',
    '@@ -0,0 +1 @@',
    "+const user = 'vecta-new-runner';",
    '+++const extra = "vecta-prefixed";',
    'diff --git a/engine/new-runner.test.mjs b/engine/new-runner.test.mjs',
    '--- a/engine/new-runner.test.mjs',
    '+++ b/engine/new-runner.test.mjs',
    '@@ -0,0 +1 @@',
    "+assert.equal(user, 'vecta-test-runner');",
    'diff --git a/engine/ci-target-config.mjs b/engine/ci-target-config.mjs',
    '--- a/engine/ci-target-config.mjs',
    '+++ b/engine/ci-target-config.mjs',
    '@@ -0,0 +1 @@',
    "const CI_RUNNER_USER_DEFAULT = 'vecta-ci';",
  ].join('\n');

  assert.deepEqual(findForbiddenVectaNames(diff), [
    'engine/new-runner.mjs: vecta-new-runner',
    'engine/new-runner.mjs: vecta-prefixed',
  ]);
});
