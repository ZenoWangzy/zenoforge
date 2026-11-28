import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import { lessonLints } from './lesson-lints.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const indexPath = path.join(repo, 'docs/agents/practices.md');

const ruleRows = (source) => source.split(/\r?\n/)
  .filter((line) => line.startsWith('| ') && !/^\|\s*(Rule|---)/.test(line));
const ruleKeys = (source) => ruleRows(source)
  .map((line) => line.match(/<a name="(rule-[a-z0-9-]+)"><\/a>/)?.[1]);
const indexRuleKeys = (index) => [...index.matchAll(/\]\(\.\.\/enforced-rules\.md#([^)]+)\)/g)]
  .map((match) => match[1]);
const assertRuleLinks = (source, index, requiredKeys = ruleKeys(source)) => {
  const keys = ruleKeys(source);
  const links = indexRuleKeys(index);
  assert.equal(keys.filter(Boolean).length, keys.length);
  assert.equal(new Set(keys).size, keys.length);
  for (const key of requiredKeys) {
    assert.equal(links.filter((link) => link === key).length, 1, key);
  }
  assert.ok(links.every((key) => keys.includes(key)));
};
const insertBeforeRule = (source, key, row) => {
  const lines = source.split(/\r?\n/);
  const position = lines.findIndex((line) => line.includes(`<a name="${key}"></a>`));
  assert.notEqual(position, -1, key);
  lines.splice(position, 0, row);
  return lines.join('\n');
};

test('the practices index covers its source rules, lints, and links', () => {
  const index = readFileSync(indexPath, 'utf8');
  const indexDir = path.dirname(indexPath);
  const agentsPath = path.join(repo, 'AGENTS.md');
  const agents = readFileSync(agentsPath, 'utf8');
  const enforcedPath = path.join(repo, 'docs/enforced-rules.md');
  const enforced = readFileSync(enforcedPath, 'utf8');
  const rows = index.split(/\r?\n/)
    .filter((line) => line.startsWith('|') && !/^\|\s*(Practice|---)/.test(line))
    .map((line) => line.split('|').slice(1, -1).map((cell) => cell.trim()));
  const links = [...index.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)].map((match) => match[1]);
  const sourceAnchors = links
    .map((href) => {
      const [file, anchor] = href.split('#');
      if (!file || !anchor) return null;
      return [path.resolve(indexDir, file), anchor];
    })
    .filter(Boolean);
  const sourceCounts = (target) => new Map(sourceAnchors
    .filter(([file]) => file === target)
    .map(([, anchor]) => [anchor, sourceAnchors.filter(([file, sourceAnchor]) => file === target && sourceAnchor === anchor).length]));
  const agentLines = agents.split(/\r?\n/)
    .map((line, index) => [line, index + 1])
    .filter(([line]) => line.startsWith('- ') || /^(?:Goal:|Factory terms are|Work here follows|The skill files|This repository is public|Use `bash tools\/merge-pr\.sh|A merge requires|GitHub issues,|The five canonical role names|Single-context\.|Code and tests enforce)/.test(line))
    .map(([, line]) => line);
  assert.equal((agents.match(/docs\/agents\/practices\.md/g) ?? []).length, 1);
  assert.ok(rows.length > 0);
  assert.ok(rows.every((row) => row.length === 3 && row.every(Boolean)));
  assert.equal(new Set(rows.map(([practice]) => practice)).size, rows.length);
  assert.ok(rows.every(([, enforcement]) => /^(?:advisory|gap):/i.test(enforcement) || /\b(?:test|lint|ratchet|hook|skill|gate):/i.test(enforcement)));
  for (const [practice, enforcement] of rows) {
    const checkPaths = [...enforcement.matchAll(/\b(?:test|lint|ratchet|hook|gate):\s*`([^`]+)`/gi)];
    const hasCheckPath = checkPaths.some(([, file]) => existsSync(path.resolve(repo, file)));
    assert.ok(
      /^advisory:/i.test(enforcement) || hasCheckPath,
      `${practice} must name an existing check path or be marked advisory`,
    );
  }
  assert.ok(rows.every(([, , source]) => source.includes('](')));

  for (const line of agentLines) assert.equal(sourceCounts(agentsPath).get(`L${line}`), 1, `AGENTS.md line ${line}`);
  assertRuleLinks(enforced, index);

  for (const adr of readdirSync(path.join(repo, 'docs/adr')).filter((file) => /^\d{4}-.*\.md$/.test(file))) {
    assert.equal(links.filter((href) => path.resolve(indexDir, href.split('#')[0]) === path.join(repo, 'docs/adr', adr)).length, 1, adr);
  }

  const lintSource = readFileSync(path.join(repo, 'engine/lesson-lints.mjs'), 'utf8');
  const identities = new Set([
    ...lessonLints.flatMap(({ lesson, classTag }) => [lesson, classTag]),
    ...[...lintSource.matchAll(/classTag: '([^']+)'/g)].map((match) => match[1]),
    ...[...readFileSync(path.join(repo, 'engine/supervisor-hold-lesson-lint.mjs'), 'utf8').matchAll(/const classTag = '([^']+)'/g)].map((match) => match[1]),
    ...[...readFileSync(path.join(repo, 'lessons/RULES.md'), 'utf8').matchAll(/\*\*(V\d+)\*\*/g)].map((match) => match[1]),
    'V930',
  ]);
  for (const identity of identities) {
    assert.equal(rows.filter((row) => row.join(' ').includes(identity)).length, 1, identity);
  }

  for (const href of links) {
    if (/^(?:https?:|mailto:)/.test(href)) continue;
    const file = href.split('#')[0];
    assert.ok(file && existsSync(path.resolve(indexDir, file)), href);
  }

  for (const [, enforcement] of rows) {
    if (/^gap:/i.test(enforcement)) continue;
    for (const [, file] of enforcement.matchAll(/`([^`]+)`/g)) {
      assert.ok(existsSync(path.resolve(repo, file)), file);
    }
  }

  for (const [practice, enforcement, source] of rows.filter(([, enforcement]) => /\bgap\b/i.test(enforcement))) {
    assert.match(`${enforcement} ${source}`, /https:\/\/github\.com\/ZenoWangzy\/zenoforge\/issues\/\d+/i, practice);
  }
});

test('two independent rule row insertions keep every practices index link valid', () => {
  const index = readFileSync(indexPath, 'utf8');
  const enforcedPath = path.join(repo, 'docs/enforced-rules.md');
  const enforced = readFileSync(enforcedPath, 'utf8');
  const keys = ruleKeys(enforced);
  const fixture = insertBeforeRule(
    insertBeforeRule(
      enforced,
      keys[10],
      '| <a name="rule-fixture-alpha"></a> Fixture rule alpha | fixture alpha |',
    ),
    keys[50],
    '| <a name="rule-fixture-beta"></a> Fixture rule beta | fixture beta |',
  );

  assert.equal(ruleKeys(fixture).length, keys.length + 2);
  assertRuleLinks(fixture, index, keys);
});
