import assert from 'node:assert/strict';
import test from 'node:test';

import { validateRunnerLanes } from './ci-runner-lanes.mjs';

const runner = (...labels) => ({
  status: 'online',
  labels: labels.map(name => ({ name })),
});

test('validates the configured suites lane', () => {
  const lane = 'configured-suites';
  const runners = [
    ...Array.from({ length: 5 }, () => runner('cihost-ci-main')),
    runner('cihost-ci-postsubmit'),
    ...Array.from({ length: 3 }, () => runner(lane)),
  ];
  const workflows = [{ jobs: { suite: { 'runs-on': [lane] } } }];

  const result = validateRunnerLanes(runners, workflows, '', lane);

  assert.deepEqual(result, [{ job: 'suite', lane, minimum: 3, online: 3 }]);
});
