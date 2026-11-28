import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const registerPath = fileURLToPath(new URL('./escape-suite-register.mjs', import.meta.url));
const registryPath = '.zenoforge/state/escape-suites.json';
const packagePath = 'packages/fruit';
const testPath = `${packagePath}/tests/escape.test.mjs`;
const command = ['node', '--test', testPath];

function makeRepo(context) {
  const repo = mkdtempSync(path.join(os.tmpdir(), 'escape-suite-register-'));
  context.after(() => rmSync(repo, { recursive: true, force: true }));
  mkdirSync(path.dirname(path.join(repo, testPath)), { recursive: true });
  writeFileSync(path.join(repo, testPath), '');
  execFileSync('git', ['-C', repo, 'init', '-q', '-b', 'main']);
  execFileSync('git', ['-C', repo, 'config', 'user.name', 'fixture']);
  execFileSync('git', ['-C', repo, 'config', 'user.email', 'fixture@example.invalid']);
  execFileSync('git', ['-C', repo, 'add', testPath]);
  execFileSync('git', ['-C', repo, 'commit', '-qm', 'fixture']);
  return repo;
}

function register(repo, args = ['--package', packagePath, '--test', testPath, '--', ...command]) {
  return spawnSync(process.execPath, [registerPath, '--repo', repo, ...args], { encoding: 'utf8' });
}

test('creates a version 1 registry with the escape test', (context) => {
  const repo = makeRepo(context);
  const result = register(repo);
  assert.equal(result.status, 0, `${result.stderr}${result.error ?? ''}`);
  const registry = JSON.parse(readFileSync(path.join(repo, registryPath), 'utf8'));
  assert.deepEqual(registry, {
    version: 1,
    packages: {
      [packagePath]: [{ test: testPath, command }],
    },
  });
});

test('leaves the registry bytes unchanged when the same escape test is added twice', (context) => {
  const repo = makeRepo(context);
  const first = register(repo);
  assert.equal(first.status, 0, `${first.stderr}${first.error ?? ''}`);
  const registryFile = path.join(repo, registryPath);
  const firstBytes = readFileSync(registryFile);
  const second = register(repo);
  assert.equal(second.status, 0, `${second.stderr}${second.error ?? ''}`);
  assert.deepEqual(readFileSync(registryFile), firstBytes);
});

test('rejects invalid registrations without creating the registry', async (context) => {
  const invalidRegistrations = [
    {
      name: 'test paths containing ..',
      args: ['--package', packagePath, '--test', '../x', '--', ...command],
    },
    {
      name: 'absolute test paths',
      args: ['--package', packagePath, '--test', path.join(os.tmpdir(), 'outside.mjs'), '--', ...command],
    },
    {
      name: 'tests outside their package',
      args: ['--package', packagePath, '--test', 'packages/vegetable/tests/escape.test.mjs', '--', ...command],
    },
    {
      name: 'package paths containing ..',
      args: ['--package', '../fruit', '--test', '../fruit/tests/escape.test.mjs', '--', ...command],
    },
    {
      name: 'empty commands',
      args: ['--package', packagePath, '--test', testPath, '--'],
    },
  ];
  for (const { name, args } of invalidRegistrations) {
    await context.test(name, (testContext) => {
      const repo = makeRepo(testContext);
      const result = register(repo, args);
      assert.equal(result.status, 1, `${result.stdout}${result.stderr}${result.error ?? ''}`);
      assert.equal(existsSync(path.join(repo, registryPath)), false);
    });
  }
});
