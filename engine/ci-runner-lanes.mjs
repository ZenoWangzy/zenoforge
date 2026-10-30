import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { validateReservedRunners } from './ci-reserved-runners.mjs';

// shortcut: inline runs-on selectors only; add YAML parsing when block selectors appear.
export function workflowSelectors(source) {
  const jobs = {};
  for (const [index, line] of source.split('\n').entries()) {
    const match = line.match(/^\s*runs-on:[ \t]*(.*)$/);
    if (!match) continue;
    const selector = match[1].trim();
    const labels = [];
    assert.ok(selector.startsWith('[') && selector.endsWith(']'), `line ${index + 1}: unsupported runs-on selector`);
    const content = selector.slice(1, -1);
    const token = /\s*(?:"([^"]*)"|'([^']*)'|([^,'"\s][^,]*?))\s*(?:,|$)/gy;
    while (token.lastIndex < content.length) {
      const value = token.exec(content);
      assert.ok(value, `line ${index + 1}: unsupported runs-on labels`);
      labels.push(value[1] ?? value[2] ?? value[3]);
    }
    jobs[`line-${index + 1}`] = { 'runs-on': labels };
  }
  return { jobs };
}

export function validateRunnerLanes(runners, workflows, priorityPr = '') {
  validateReservedRunners(runners);
  const minimums = { 'cihost-ci-main': 5, 'cihost-ci-postsubmit': 1, 'cihost-ci-light': 4, 'cihost-ci-priority': 1, 'zf-suites': 3 };
  const counts = [];
  for (const workflow of workflows) {
    for (const [job, config] of Object.entries(workflow.jobs ?? {})) {
      const selector = config['runs-on'];
      const labels = Array.isArray(selector) ? selector : [selector];
      assert.ok(labels.every(label => typeof label === 'string'), `${job}: unresolved runs-on`);
      const fixed = labels.filter(label => !label.startsWith('${{'));
      const alternatives = labels.flatMap(label => label.match(/\b(?:cihost-ci(?:-[a-z0-9-]+)?|zf-suites)\b/g) ?? []);
      assert.ok(!labels.some(label => label.startsWith('${{')) || alternatives.length, `${job}: unresolved runs-on`);
      for (const lane of new Set(alternatives.filter(label => label !== 'cihost-ci-testcontainers'))) {
        if (lane === 'cihost-ci-priority' && !priorityPr) continue;
        const required = [...new Set([...fixed, lane])];
        const online = runners.filter(runner => runner.status === 'online' &&
          required.every(label => runner.labels.some(actual => actual.name === label))).length;
        const minimum = minimums[lane] ?? 2;
        assert.ok(online >= minimum, `${job}/${lane}: need ${minimum} online runners, found ${online} (labels: ${required.join(',')})`);
        counts.push({ job, lane, minimum, online });
      }
    }
  }
  return counts;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const inventory = JSON.parse(readFileSync(0, 'utf8'));
  const directory = fileURLToPath(new URL('../.github/workflows/', import.meta.url));
  const workflows = readdirSync(directory).filter(file => /\.ya?ml$/.test(file))
    .map(file => workflowSelectors(readFileSync(`${directory}/${file}`, 'utf8')));
  console.log(JSON.stringify(validateRunnerLanes(inventory.runners, workflows, process.env.CI_PRIORITY_PR)));
}
