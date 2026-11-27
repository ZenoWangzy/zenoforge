import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import { checkProof } from './verify-proof-check.mjs';

const HEAD = 'a'.repeat(40);
const plan = { matched_features: ['login', 'chat'] };
const row = (feature_id, status = 'PASS') => ({ feature_id, status });
const proof = (over = {}) => JSON.stringify({ source_sha: HEAD, features: [row('login'), row('chat')], ...over });

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

test('plan without matched_features array is rejected', () => {
  assert.throws(() => checkProof({}, proof(), HEAD), /matched_features/);
});

test('cli prints one JSON line, exit 0 for every status, exit 2 for bad invocation', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'zf-proof-check-'));
  const planFile = path.join(dir, 'plan.json');
  const proofFile = path.join(dir, 'proof.json');
  writeFileSync(planFile, JSON.stringify(plan));
  const run = (...args) => spawnSync(process.execPath, [new URL('./verify-proof-check.mjs', import.meta.url).pathname, ...args], { encoding: 'utf8' });

  const missing = run('--plan', planFile, '--proof', proofFile, '--head', HEAD);
  assert.equal(missing.status, 0);
  assert.equal(JSON.parse(missing.stdout).status, 'missing');

  writeFileSync(proofFile, proof());
  const ok = run('--plan', planFile, '--proof', proofFile, '--head', HEAD);
  assert.equal(ok.status, 0);
  assert.equal(ok.stdout.trim().split('\n').length, 1);
  assert.equal(JSON.parse(ok.stdout).status, 'ok');

  const stale = run('--plan', planFile, '--proof', proofFile, '--head', 'c'.repeat(40));
  assert.equal(stale.status, 0);
  assert.equal(JSON.parse(stale.stdout).status, 'stale');

  assert.equal(run('--plan', planFile, '--proof', proofFile).status, 2);
  assert.equal(run('--bogus', 'x').status, 2);
  assert.equal(run('--plan', path.join(dir, 'nope.json'), '--proof', proofFile, '--head', HEAD).status, 2);
});
