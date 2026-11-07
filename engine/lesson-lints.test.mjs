import assert from 'node:assert/strict';
import test from 'node:test';

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

import { entryCheckFailures, exactSecondFailures } from './lesson-lints.mjs';

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

test('an entry check comparing argv[1] without realpathSync fails, in every plain form', () => {
  const sources = {
    'engine/a.mjs': 'if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {',
    'engine/b.mjs': 'if (import.meta.url === `file://${process.argv[1]}`) {',
    'engine/c.js': 'if (process.argv[1] && path.resolve(process.argv[1]) === SCRIPT_PATH) {',
    'engine/d.mjs': 'if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(SCRIPT_PATH)) {',
    'engine/f.test.mjs': 'if (process.argv[1] === x) {',
  };
  assert.deepEqual(entryCheckFailures(Object.keys(sources), (file) => sources[file]), ['engine/a.mjs:1', 'engine/b.mjs:1', 'engine/c.js:1']);
});

test('no engine script keeps a symlink-blind entry check', () => {
  const files = execFileSync('git', ['ls-files', 'engine'], { encoding: 'utf8' }).split('\n').filter(Boolean);
  assert.deepEqual(entryCheckFailures(files, (file) => readFileSync(file, 'utf8')), []);
});
