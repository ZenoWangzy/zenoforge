import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execute } from './run-eval.mjs';
import { validateFreshCase, classifyFailedRun, buildFreshAgentGapIssue, buildFreshAgentGapIssues } from './fresh-agent.mjs';

const SHA = 'a'.repeat(40);
const validCase = { id: 'fresh-1', source_url: 'https://github.com/ZenoWangzy/zenoforge/issues/984', base_sha: SHA, fix_sha: 'b'.repeat(40), prompt: 'Add a retry guard.', hidden_check: 'node check.mjs', expected_divergence: 'read-doc' };
const step = (id, ok, doc = true, guard = true) => ({ id, ok, doc_available: doc, guard_available: guard });

test('case schema accepts a complete frozen case and rejects memory or bad SHA', () => {
  assert.deepEqual(validateFreshCase(validCase), []);
  const legacyCase = { ...validCase };
  delete legacyCase.fix_sha;
  delete legacyCase.source_url;
  assert.deepEqual(validateFreshCase(legacyCase), []);
  assert.ok(validateFreshCase({ ...validCase, base_sha: 'HEAD' }).some((f) => f.startsWith('base_sha')));
  assert.ok(validateFreshCase({ ...validCase, fix_sha: 'HEAD' }).some((f) => f.startsWith('fix_sha')));
  assert.ok(validateFreshCase({ ...validCase, fix_sha: SHA }).some((f) => f.startsWith('fix_sha')));
  assert.ok(validateFreshCase({ ...validCase, source_url: 'fixture' }).some((f) => f.startsWith('source_url')));
  assert.ok(validateFreshCase({ ...validCase, memory: 'earlier chat' }).includes('unknown key: memory'));
  assert.ok(validateFreshCase({ ...validCase, prompt: '' }).some((f) => f.startsWith('prompt')));
});

test('frozen fresh-agent corpus has five to eight valid cases with unique ids', () => {
  const set = JSON.parse(readFileSync(new URL('./cases/fresh-agent.json', import.meta.url), 'utf8'));
  assert.equal(set.stage, 'fresh-agent');
  assert.ok(set.cases.length >= 5 && set.cases.length <= 8);
  assert.equal(new Set(set.cases.map((c) => c.id)).size, set.cases.length);
  assert.ok(set.cases.every((c) => c.source_url));
  assert.ok(set.cases.every((c) => c.remediation?.doc?.path && c.remediation?.doc?.line && c.remediation?.guard));
  assert.ok(set.cases.every((c) => validateFreshCase(c).length === 0));
});

test('classifies missing-doc when the first failing step had no doc at base', () => {
  const run = { passed: false, steps: [step('read-doc', false, false, true)] };
  assert.deepEqual(classifyFailedRun(run), { class: 'missing-doc', first_divergence: 'read-doc' });
});

test('classifies missing-guard when a doc existed but no guard would have caught the step', () => {
  const run = { passed: false, steps: [step('edit', false, true, false)] };
  assert.deepEqual(classifyFailedRun(run), { class: 'missing-guard', first_divergence: 'edit' });
});

test('routes a missing-doc result to an actionable tracked issue body', () => {
  const id = 'zf-1049-lesson-enforcers';
  const issue = buildFreshAgentGapIssue({ id, source_url: 'https://github.com/ZenoWangzy/zenoforge/issues/1049',
    prompt: 'Keep the lesson-enforcer index aligned.', remediation: {
      doc: { path: 'docs/enforced-rules.md', line: 'The index covers every registry incident.' },
      guard: 'Reject stale lesson-enforcer indexes.',
    } }, { stage: 'fresh-agent', caseId: id, run: 1, pass: false, class: 'missing-doc', first_divergence: 'read-doc' });
  assert.equal(issue.class, 'fresh-agent-zf-1049-lesson-enforcers-missing-doc');
  assert.equal(issue.title, 'Fresh-agent missing doc: zf-1049-lesson-enforcers');
  assert.match(issue.body, /First divergence:\n- Run 1: `read-doc`/);
  assert.match(issue.body, /Doc file: `docs\/enforced-rules\.md`/);
  assert.match(issue.body, /Line to add: `The index covers every registry incident\.`/);
  assert.match(issue.body, /https:\/\/github\.com\/ZenoWangzy\/zenoforge\/issues\/1049/);
});

test('routes a missing-guard result with the rule to enforce', () => {
  const id = 'zf-1049-lesson-enforcers';
  const issue = buildFreshAgentGapIssue({ id, prompt: 'Keep the lesson-enforcer index complete.', remediation: {
    doc: { path: 'docs/enforced-rules.md', line: 'The index covers every registry incident.' },
    guard: 'Reject a lesson-enforcer index that omits a registry incident or differs from the generated output.',
    lesson_lint: 'If this rule can be expressed as a lesson, add it through engine/lesson-lints.mjs in observe mode; move it to enforce only in a change that cites its ledger counts.',
  } }, { stage: 'fresh-agent', caseId: id, run: 1, pass: false, class: 'missing-guard', first_divergence: 'complete-incident-coverage' });
  assert.equal(issue.class, 'fresh-agent-zf-1049-lesson-enforcers-missing-guard');
  assert.equal(issue.title, 'Fresh-agent missing guard: zf-1049-lesson-enforcers');
  assert.match(issue.body, /Rule to enforce: `Reject a lesson-enforcer index that omits a registry incident or differs from the generated output\.`/);
  assert.match(issue.body, /engine\/lesson-lints\.mjs in observe mode; move it to enforce only in a change that cites its ledger counts/);
});

test('groups repeated gap results into one routed issue body', () => {
  const c = { id: 'zf-1049-lesson-enforcers', prompt: 'Keep the index current.', remediation: {
    doc: { path: 'docs/enforced-rules.md', line: 'The index covers every registry incident.' },
    guard: 'Reject stale lesson-enforcer indexes.',
  } };
  const rows = [1, 2].map((run) => ({ stage: 'fresh-agent', caseId: c.id, run, pass: false,
    class: 'missing-doc', first_divergence: 'read-doc' }));
  const [issue] = buildFreshAgentGapIssues(rows, [c]);
  assert.equal(issue.class, 'fresh-agent-zf-1049-lesson-enforcers-missing-doc');
  assert.match(issue.body, /Run 1: `read-doc`[\s\S]*Run 2: `read-doc`/);
});

test('classifies agent-error when doc and guard were both available', () => {
  const run = { passed: false, steps: [step('edit', false)] };
  assert.deepEqual(classifyFailedRun(run), { class: 'agent-error', first_divergence: 'edit' });
});

test('first divergence is the earliest failing step, not a later gap', () => {
  const run = { passed: false, steps: [step('read', true), step('edit', false), step('test', false, false, false)] };
  assert.deepEqual(classifyFailedRun(run), { class: 'agent-error', first_divergence: 'edit' });
});

test('passing run has no class, and a failed run with no failing step is agent-error with no divergence', () => {
  assert.equal(classifyFailedRun({ passed: true, steps: [step('edit', true)] }), null);
  assert.deepEqual(classifyFailedRun({ passed: false, steps: [step('edit', true)] }), { class: 'agent-error', first_divergence: null });
});

test('non-boolean step facts are rejected instead of guessed', () => {
  assert.throws(() => classifyFailedRun({ passed: false, steps: [{ id: 'edit', ok: false }] }), TypeError);
});

test('fresh-agent runner gives the backend only the prompt and records pass or classified failure', () => {
  const dir = mkdtempSync(join(tmpdir(), 'fresh-agent-test-'));
  const sourceRepo = join(dir, 'repo'); mkdirSync(sourceRepo);
  const git = (...args) => execFileSync('git', args, { cwd: sourceRepo, stdio: 'ignore' });
  try {
    git('init', '-q'); git('config', 'user.name', 'Eval fixture'); git('config', 'user.email', 'eval@example.invalid');
    writeFileSync(join(sourceRepo, 'base.txt'), 'frozen\n'); git('add', '.'); git('commit', '-qm', 'frozen base');
    const base_sha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: sourceRepo, encoding: 'utf8' }).trim();
    writeFileSync(join(sourceRepo, 'result.txt'), 'ready\n'); git('add', '.'); git('commit', '-qm', 'known fix');
    const fix_sha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: sourceRepo, encoding: 'utf8' }).trim();
    const stageCall = join(dir, 'fake-stage-call.sh');
    writeFileSync(stageCall, `#!/usr/bin/env bash
set -euo pipefail
stage=$1; wt=$3; prompt=$4; artifact=$5; input=$6
[[ "$stage" == fresh-agent ]]
grep -qx 'TASK_ONLY_PASS' "$prompt" || grep -qx 'TASK_ONLY_FAIL' "$prompt"
! grep -Eq 'hidden_check|expected_divergence|fix_sha|source_url|memory' "$prompt"
grep -q '"sessionId":null' "$input"
printf 'codex:fixture:high\\n' > "$artifact/identity.txt"
printf '{"tokens":23}\\n' > "$artifact/usage.json"
printf 'tokens used\\n23\\n' > "$artifact/worker.log"
grep -q PASS "$prompt" && printf 'ready\\n' > "$wt/result.txt"
printf 'fake output\\n'
`, { mode: 0o755 });
    const check = join(dir, 'check.mjs');
    writeFileSync(check, `import { existsSync } from 'node:fs';
const ok = existsSync('result.txt');
console.log(JSON.stringify({ steps: [{ id: 'read-doc', ok, doc_available: false, guard_available: true }] }));
process.exitCode = ok ? 0 : 1;
`);
    const run = (id, prompt) => {
      const attemptDir = join(dir, id); mkdirSync(attemptDir);
      return execute({ id, base_sha, fix_sha, source_url: 'https://github.com/ZenoWangzy/zenoforge/issues/984', prompt, hidden_check: `node ${check}`, expected_divergence: 'read-doc' },
        'fresh-agent', attemptDir, 'unused-policy', { sourceRepo, stageCall });
    };
    const passing = run('pass', 'TASK_ONLY_PASS');
    const failing = run('fail', 'TASK_ONLY_FAIL');
    assert.equal(passing.pass, true);
    assert.equal(passing.class, null);
    assert.equal(passing.first_divergence, null);
    assert.equal(failing.pass, false);
    assert.equal(failing.class, 'missing-doc');
    assert.equal(failing.first_divergence, 'read-doc');
    assert.equal(failing.calls[0].tokens, 23);
    assert.equal(failing.calls[0].identity, 'codex:fixture:high');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
