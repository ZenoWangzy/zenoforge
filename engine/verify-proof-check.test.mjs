import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import { checkProof } from './verify-proof-check.mjs';

const HEAD = 'a'.repeat(40);
const plan = { matched_features: ['login', 'chat'] };
const row = (feature_id, status = 'PASS') => ({ feature_id, status });
const proof = (over = {}) => JSON.stringify({ source_sha: HEAD, features: [row('login'), row('chat')], ...over });
const performance = (over = {}) => ({
  first_paint_ms: 100,
  largest_contentful_paint_ms: 400,
  js_heap_used_mb: 80,
  long_task_count: 0,
  run_count: 5,
  error_count: 0,
  work_count: 3,
  ...over,
});
const performanceProof = (over = {}) => JSON.stringify({
  source_sha: HEAD,
  features: [
    { ...row('login'), performance: performance(over.login) },
    { ...row('chat'), performance: performance(over.chat) },
  ],
});
const budgetEntry = (over = {}) => ({
  basis: 'Measured fixture values across five completed runs.',
  first_paint_ms: 200,
  largest_contentful_paint_ms: 600,
  js_heap_used_mb: 100,
  long_task_count: 1,
  ...over,
});
const performanceBudgets = (over = {}) => JSON.stringify({ default: budgetEntry(), ...over });

test('no matched feature is not-required whatever the proof holds', () => {
  for (const text of [null, '', 'not json', proof()]) {
    assert.equal(checkProof({ matched_features: [] }, text, HEAD).status, 'not-required');
  }
});

test('absent or empty proof is missing', () => {
  assert.equal(checkProof(plan, null, HEAD).status, 'missing');
  assert.equal(checkProof(plan, '  \n', HEAD).status, 'missing');
});

test('malformed or shapeless proof is invalid and names the field', () => {
  assert.equal(checkProof(plan, '{oops', HEAD).status, 'invalid');
  assert.equal(checkProof(plan, '[]', HEAD).status, 'invalid');
  const noFeatures = checkProof(plan, JSON.stringify({ source_sha: HEAD }), HEAD);
  assert.equal(noFeatures.status, 'invalid');
  assert.match(noFeatures.reasons[0], /proof\.features/);
  const noSha = checkProof(plan, JSON.stringify({ features: [row('login')] }), HEAD);
  assert.equal(noSha.status, 'invalid');
  assert.match(noSha.reasons[0], /source_sha/);
});

test('proof for another sha is stale', () => {
  const out = checkProof(plan, proof({ source_sha: 'b'.repeat(40) }), HEAD);
  assert.equal(out.status, 'stale');
  assert.match(out.reasons[0], /source_sha/);
  assert.equal(checkProof(plan, proof({ source_sha: 'unknown' }), HEAD).status, 'stale');
});

test('abbreviated sha of at least 7 chars matches, shorter does not', () => {
  assert.equal(checkProof(plan, proof({ source_sha: HEAD.slice(0, 12) }), HEAD).status, 'ok');
  assert.equal(checkProof(plan, proof({ source_sha: HEAD.slice(0, 4) }), HEAD).status, 'stale');
});

test('a matched feature without a result is missing and named', () => {
  const out = checkProof(plan, proof({ features: [row('login')] }), HEAD);
  assert.equal(out.status, 'missing');
  assert.deepEqual(out.features, { login: 'ok', chat: 'missing' });
  assert.match(out.reasons[0], /chat/);
});

test('a failed or held feature is invalid and named', () => {
  for (const status of ['FAIL', 'HOLD']) {
    const out = checkProof(plan, proof({ features: [row('login'), row('chat', status)] }), HEAD);
    assert.equal(out.status, 'invalid');
    assert.deepEqual(out.features, { login: 'ok', chat: 'failed' });
    assert.match(out.reasons[0], new RegExp(`chat.*${status}`));
  }
});

test('every matched feature passing is ok, extra results ignored', () => {
  const out = checkProof(plan, proof({ features: [row('login'), row('chat'), row('other', 'FAIL')] }), HEAD);
  assert.deepEqual(out, { status: 'ok', features: { login: 'ok', chat: 'ok' }, reasons: [] });
});

test('performance inside each feature budget keeps the proof ok', () => {
  const out = checkProof(plan, performanceProof(), HEAD, performanceBudgets());
  assert.deepEqual(out, { status: 'ok', features: { login: 'ok', chat: 'ok' }, reasons: [] });
});

test('a performance metric over budget names its feature, measurement and limit', () => {
  const out = checkProof(plan, performanceProof({ login: { largest_contentful_paint_ms: 700 } }), HEAD, performanceBudgets());
  assert.equal(out.status, 'over-budget');
  assert.deepEqual(out.features, { login: 'over-budget', chat: 'ok' });
  assert.match(out.reasons.join(' '), /login.*largest_contentful_paint_ms.*700.*600/);
});

test('too few runs, errors or no completed work make performance invalid', () => {
  for (const [field, value] of [['run_count', 4], ['error_count', 1], ['work_count', 0]]) {
    const out = checkProof(plan, performanceProof({ login: { [field]: value } }), HEAD, performanceBudgets());
    assert.equal(out.status, 'invalid');
    assert.match(out.reasons.join(' '), new RegExp('login.*' + field));
  }
});

test('a budget entry without a basis is rejected', () => {
  const out = checkProof(plan, performanceProof(), HEAD, performanceBudgets({ login: { first_paint_ms: 180 } }));
  assert.equal(out.status, 'invalid');
  assert.match(out.reasons.join(' '), /login.*basis/);
});

test('without a budget file the functional result ignores performance fields', () => {
  const out = checkProof(plan, proof(), HEAD);
  assert.deepEqual(out, { status: 'ok', features: { login: 'ok', chat: 'ok' }, reasons: [] });
});

test('plan without matched_features array is rejected', () => {
  assert.throws(() => checkProof({}, proof(), HEAD), /matched_features/);
});

test('cli prints one JSON line, exit 0 for every status, exit 2 for bad invocation', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'zf-proof-check-'));
  const planFile = path.join(dir, 'plan.json');
  const proofFile = path.join(dir, 'proof.json');
  const env = { ...process.env, ZF_CONFIG_ROOT: path.join(dir, 'config') };
  delete env.ZF_PACK_DIR;
  mkdirSync(env.ZF_CONFIG_ROOT, { recursive: true });
  writeFileSync(planFile, JSON.stringify(plan));
  const run = (...args) => spawnSync(process.execPath, [new URL('./verify-proof-check.mjs', import.meta.url).pathname, ...args], { encoding: 'utf8', env });

  const missing = run('--plan', planFile, '--proof', proofFile, '--head', HEAD);
  assert.equal(missing.status, 0);
  assert.equal(JSON.parse(missing.stdout).status, 'missing');
  assert.equal(missing.stderr.trim().split('\n').length, 1);
  assert.match(missing.stderr, /no performance budget file/);

  writeFileSync(proofFile, proof());
  const ok = run('--plan', planFile, '--proof', proofFile, '--head', HEAD);
  assert.equal(ok.status, 0);
  assert.equal(ok.stdout.trim().split('\n').length, 1);
  assert.equal(JSON.parse(ok.stdout).status, 'ok');
  assert.equal(ok.stderr.trim().split('\n').length, 1);
  assert.match(ok.stderr, /no performance budget file/);

  const stale = run('--plan', planFile, '--proof', proofFile, '--head', 'c'.repeat(40));
  assert.equal(stale.status, 0);
  assert.equal(JSON.parse(stale.stdout).status, 'stale');

  assert.equal(run('--plan', planFile, '--proof', proofFile).status, 2);
  assert.equal(run('--bogus', 'x').status, 2);
  assert.equal(run('--plan', path.join(dir, 'nope.json'), '--proof', proofFile, '--head', HEAD).status, 2);

  mkdirSync(path.join(env.ZF_CONFIG_ROOT, 'state'), { recursive: true });
  writeFileSync(path.join(env.ZF_CONFIG_ROOT, 'state', 'perf-budget.json'), performanceBudgets());
  writeFileSync(proofFile, performanceProof({ login: { first_paint_ms: 250 } }));
  const overBudget = run('--plan', planFile, '--proof', proofFile, '--head', HEAD);
  assert.equal(overBudget.status, 0);
  assert.equal(JSON.parse(overBudget.stdout).status, 'over-budget');
});
