import assert from 'node:assert/strict';
import test from 'node:test';

import { exactSecondFailures } from './lesson-lints.mjs';

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
