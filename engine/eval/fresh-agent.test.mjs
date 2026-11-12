import test from 'node:test';
import assert from 'node:assert/strict';
import { validateFreshCase, classifyFailedRun } from './fresh-agent.mjs';

const SHA = 'a'.repeat(40);
const validCase = { id: 'fresh-1', base_sha: SHA, prompt: 'Add a retry guard.', hidden_check: 'node check.mjs', expected_divergence: 'read-doc' };
const step = (id, ok, doc = true, guard = true) => ({ id, ok, doc_available: doc, guard_available: guard });

test('case schema accepts a complete frozen case and rejects memory or bad SHA', () => {
  assert.deepEqual(validateFreshCase(validCase), []);
  assert.ok(validateFreshCase({ ...validCase, base_sha: 'HEAD' }).some((f) => f.startsWith('base_sha')));
  assert.ok(validateFreshCase({ ...validCase, memory: 'earlier chat' }).includes('unknown key: memory'));
  assert.ok(validateFreshCase({ ...validCase, prompt: '' }).some((f) => f.startsWith('prompt')));
});

test('classifies missing-doc when the first failing step had no doc at base', () => {
  const run = { passed: false, steps: [step('read-doc', false, false, true)] };
  assert.deepEqual(classifyFailedRun(run), { class: 'missing-doc', first_divergence: 'read-doc' });
});

test('classifies missing-guard when a doc existed but no guard would have caught the step', () => {
  const run = { passed: false, steps: [step('edit', false, true, false)] };
  assert.deepEqual(classifyFailedRun(run), { class: 'missing-guard', first_divergence: 'edit' });
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
