import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const REPO_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const CHECKER = join(REPO_ROOT, 'tools/move-only-check.mjs');
const TEMP_ROOT = join(REPO_ROOT, '.tmp');

function fixtureRepo() {
  mkdirSync(TEMP_ROOT, { recursive: true });
  const root = mkdtempSync(join(TEMP_ROOT, 'move-only-check-'));
  mkdirSync(join(root, 'engine'), { recursive: true });
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
  git('init', '-q');
  git('config', 'user.name', 'fixture');
  git('config', 'user.email', 'fixture@example.invalid');
  const commit = (message) => {
    git('add', '-A');
    git('commit', '-q', '-m', message);
  };
  const run = (...args) => spawnSync(process.execPath, [CHECKER, ...args], {
    cwd: root,
    encoding: 'utf8',
  });
  return { root, git, commit, run };
}

test('an unchanged function moved between shell files passes', () => {
  const repo = fixtureRepo();
  try {
    writeFileSync(join(repo.root, 'engine/a.sh'), "shared() {\n  printf 'moved\\n'\n}\n");
    writeFileSync(join(repo.root, 'engine/b.sh'), "kept() {\n  printf 'kept\\n'\n}\n");
    repo.commit('base');
    const base = repo.git('rev-parse', 'HEAD');

    writeFileSync(join(repo.root, 'engine/a.sh'), '');
    writeFileSync(join(repo.root, 'engine/b.sh'), "kept() {\n  printf 'kept\\n'\n}\nshared() {\n  printf 'moved\\n'\n}\n");
    repo.commit('move function');

    const result = repo.run(base, 'HEAD');
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /^moved-or-unchanged: 2$/m);
  } finally {
    rmSync(repo.root, { recursive: true, force: true });
  }
});
