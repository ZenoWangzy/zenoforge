import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./pr-required-aggregate.mjs', import.meta.url));

const run = (...args) => {
  try {
    const stdout = execFileSync('node', [script, ...args], { encoding: 'utf8' });
    return { code: 0, stdout };
  } catch (error) {
    return { code: error.status, stdout: String(error.stderr || '') };
  }
};

const buildArgs = (expected, pairs, { always = 'false-green-guards', conditional = 'example-pr-gate,pr-touched-packages,pr-repo-path-regression' } = {}) => [
  '--expected', expected,
  ...(always ? ['--always', always] : []),
  ...(conditional ? ['--conditional', conditional] : []),
  ...pairs,
];

test('all gates green passes regardless of the expected flag', () => {
  const pairs = ['false-green-guards=success', 'example-pr-gate=success', 'pr-touched-packages=success', 'pr-repo-path-regression=success'];
  for (const expected of ['true', 'false']) {
    const { code, stdout } = run(...buildArgs(expected, pairs));
    assert.equal(code, 0, `expected=${expected}: ${stdout}`);
  }
});

test('a failed always-required gate fails the aggregate', () => {
  const { code, stdout } = run(...buildArgs('true', ['false-green-guards=failure', 'example-pr-gate=success', 'pr-touched-packages=success', 'pr-repo-path-regression=success']));
  assert.equal(code, 1);
  assert.match(stdout, /false-green-guards: failure/);
});

test('the #4484 class: a conditional gate skipped while the run condition held fails loudly', () => {
  const { code, stdout } = run(...buildArgs('true', ['false-green-guards=success', 'example-pr-gate=skipped', 'pr-touched-packages=skipped', 'pr-repo-path-regression=skipped']));
  assert.equal(code, 1);
  assert.match(stdout, /example-pr-gate: skipped although the run condition says it should have run/);
  assert.match(stdout, /pr-touched-packages: skipped although the run condition says it should have run/);
  assert.match(stdout, /pr-repo-path-regression: skipped although the run condition says it should have run/);
});

test('conditional gates may legitimately skip when the run condition was false', () => {
  const { code, stdout } = run(...buildArgs('false', ['false-green-guards=success', 'example-pr-gate=skipped', 'pr-touched-packages=skipped', 'pr-repo-path-regression=skipped']));
  assert.equal(code, 0, stdout);
});

test('a failed conditional gate never passes, even when others succeeded', () => {
  const { code, stdout } = run(...buildArgs('true', ['false-green-guards=success', 'example-pr-gate=success', 'pr-touched-packages=cancelled', 'pr-repo-path-regression=success']));
  assert.equal(code, 1);
  assert.match(stdout, /pr-touched-packages: cancelled/);
});

test('a gate with no reported result fails closed', () => {
  const { code, stdout } = run(...buildArgs('false', ['false-green-guards=success', 'example-pr-gate=skipped', 'pr-repo-path-regression=skipped']));
  assert.equal(code, 1);
  assert.match(stdout, /pr-touched-packages: no result reported/);
});

test('the contract aggregate shape: one conditional gate, no always list', () => {
  assert.equal(run(...buildArgs('true', ['contract=success'], { always: '', conditional: 'contract' })).code, 0);
  assert.equal(run(...buildArgs('true', ['contract=skipped'], { always: '', conditional: 'contract' })).code, 1);
  assert.equal(run(...buildArgs('false', ['contract=skipped'], { always: '', conditional: 'contract' })).code, 0);
});

test('bad argv exits 2 without reading as a verdict', () => {
  assert.equal(run(...buildArgs('yes', ['a=success'])).code, 2);
  assert.equal(run('a=success').code, 2);
  assert.equal(run('--expected', 'true', 'novalue').code, 2);
});
