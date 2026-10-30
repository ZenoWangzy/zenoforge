import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const CI_RUNNER_PREFIX = process.env.ZF_CI_RUNNER_PREFIX ?? 'cihost-ci'; // default mirrors config.sh
const POSTSUBMIT_LANE = `${CI_RUNNER_PREFIX}-postsubmit`;

export function validateReservedRunners(runners) {
  assert.ok(Array.isArray(runners), 'runner inventory must be an array');
  const counts = {};
  for (const [lane, minimum] of [[`${CI_RUNNER_PREFIX}-main`, 5], [POSTSUBMIT_LANE, 1]]) {
    const reserved = runners.filter(runner => runner.labels.some(label => label.name === lane));
    // CTO 2026-10-12: share main capacity within the 12-runner cap; reserve Postsubmit only.
    for (const runner of lane === POSTSUBMIT_LANE ? reserved : []) {
      const shared = runner.labels.filter(label => label.name !== lane &&
        [CI_RUNNER_PREFIX, ...['light', 'priority', 'main', 'postsubmit'].map(suffix => `${CI_RUNNER_PREFIX}-${suffix}`)].includes(label.name));
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
