import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import { lessonLints } from './lesson-lints.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const indexPath = path.join(repo, 'docs/agents/practices.md');

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
  const sourceCounts = (target) => new Map(links
    .map((href) => {
      const [file, anchor] = href.split('#');
      if (!file || !anchor?.startsWith('L')) return null;
      return [path.resolve(indexDir, file), Number(anchor.slice(1))];
    })
    .filter((entry) => entry && entry[0] === target)
    .map(([, line]) => [line, links.filter((href) => {
      const [file, anchor] = href.split('#');
      return file && path.resolve(indexDir, file) === target && anchor === `L${line}`;
    }).length]));
  const agentLines = agents.split(/\r?\n/)
    .map((line, index) => [line, index + 1])
    .filter(([line]) => line.startsWith('- ') || /^(?:Goal:|Factory terms are|Work here follows|The skill files|This repository is public|Use `bash tools\/merge-pr\.sh|A merge requires|GitHub issues,|The five canonical role names|Single-context\.|Code and tests enforce)/.test(line))
    .map(([, line]) => line);
  const enforcedLines = enforced.split(/\r?\n/)
    .map((line, index) => [line, index + 1])
    .filter(([line]) => line.startsWith('| ') && !/^\|\s*(Rule|---)/.test(line))
    .map(([, line]) => line);

  assert.equal((agents.match(/docs\/agents\/practices\.md/g) ?? []).length, 1);
  assert.ok(rows.length > 0);
  assert.ok(rows.every((row) => row.length === 3 && row.every(Boolean)));
  assert.equal(new Set(rows.map(([practice]) => practice)).size, rows.length);
  assert.ok(rows.every(([, enforcement]) => /^gap:/i.test(enforcement) || /\b(?:test|lint|hook|skill|gate):/i.test(enforcement)));
  assert.ok(rows.every(([, , source]) => source.includes('](')));

  for (const line of agentLines) assert.equal(sourceCounts(agentsPath).get(line), 1, `AGENTS.md line ${line}`);
  for (const line of enforcedLines) assert.equal(sourceCounts(enforcedPath).get(line), 1, `docs/enforced-rules.md line ${line}`);

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
