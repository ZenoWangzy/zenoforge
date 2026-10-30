import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function validateReservedRunners(runners) {
  assert.ok(Array.isArray(runners), 'runner inventory must be an array');
  const counts = {};
  for (const [lane, minimum] of [['cihost-ci-main', 5], ['cihost-ci-postsubmit', 1]]) {
    const reserved = runners.filter(runner => runner.labels.some(label => label.name === lane));
    // CTO 2026-10-12: share main capacity within the 12-runner cap; reserve Postsubmit only.
    for (const runner of lane === 'cihost-ci-postsubmit' ? reserved : []) {
      const shared = runner.labels.filter(label => label.name !== lane &&
        ['cihost-ci', 'cihost-ci-light', 'cihost-ci-priority', 'cihost-ci-main', 'cihost-ci-postsubmit'].includes(label.name));
      assert.equal(shared.length, 0, `${runner.name}: ${lane} overlaps PR labels`);
    }
    counts[lane] = reserved.filter(runner => runner.status === 'online').length;
    assert.ok(counts[lane] >= minimum, `${lane}: need ${minimum} online runners, found ${counts[lane]}`);
  }
  return counts;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const inventory = JSON.parse(readFileSync(0, 'utf8'));
  console.log(JSON.stringify(validateReservedRunners(inventory.runners)));
}
