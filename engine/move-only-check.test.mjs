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

test('a one-character function body change is reported and fails', () => {
  const repo = fixtureRepo();
  try {
    writeFileSync(join(repo.root, 'engine/change.sh'), "render() {\n  printf 'old'\n}\n");
    repo.commit('base');
    const base = repo.git('rev-parse', 'HEAD');

    writeFileSync(join(repo.root, 'engine/change.sh'), "render() {\n  printf 'new'\n}\n");
    repo.commit('change body');

    const result = repo.run(base, 'HEAD');
    assert.equal(result.status, 1, result.stderr + result.stdout);
    assert.match(result.stdout, /^changed: render$/m);
  } finally {
    rmSync(repo.root, { recursive: true, force: true });
  }
});

test('a removed function is reported and fails', () => {
  const repo = fixtureRepo();
  try {
    writeFileSync(join(repo.root, 'engine/remove.sh'), "retired() {\n  :\n}\n");
    repo.commit('base');
    const base = repo.git('rev-parse', 'HEAD');

    writeFileSync(join(repo.root, 'engine/remove.sh'), '');
    repo.commit('remove function');

    const result = repo.run(base, 'HEAD');
    assert.equal(result.status, 1, result.stderr + result.stdout);
    assert.match(result.stdout, /^removed: retired$/m);
  } finally {
    rmSync(repo.root, { recursive: true, force: true });
  }
});

test('an added function fails unless its name is allowed', () => {
  const repo = fixtureRepo();
  try {
    writeFileSync(join(repo.root, 'engine/add.sh'), '');
    repo.commit('base');
    const base = repo.git('rev-parse', 'HEAD');

    writeFileSync(join(repo.root, 'engine/add.sh'), "created() {\n  :\n}\n");
    repo.commit('add function');

    const denied = repo.run(base, 'HEAD');
    assert.equal(denied.status, 1, denied.stderr + denied.stdout);
    assert.match(denied.stdout, /^added: created$/m);

    const allowed = repo.run(base, 'HEAD', '--allow-added', 'created');
    assert.equal(allowed.status, 0, allowed.stderr + allowed.stdout);
    assert.match(allowed.stdout, /^added: created$/m);
  } finally {
    rmSync(repo.root, { recursive: true, force: true });
  }
});

test('a moved function with a top-level closing brace in its heredoc passes', () => {
  const repo = fixtureRepo();
  try {
    const body = "emit() {\n  cat <<'TEXT'\n}\nTEXT\n}\n";
    writeFileSync(join(repo.root, 'engine/a.sh'), body);
    writeFileSync(join(repo.root, 'engine/b.sh'), '');
    repo.commit('base');
    const base = repo.git('rev-parse', 'HEAD');

    writeFileSync(join(repo.root, 'engine/a.sh'), '');
    writeFileSync(join(repo.root, 'engine/b.sh'), body);
    repo.commit('move heredoc function');

    const result = repo.run(base, 'HEAD');
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /^moved-or-unchanged: 1$/m);
  } finally {
    rmSync(repo.root, { recursive: true, force: true });
  }
});

test('non-function line changes are reported without failing', () => {
  const repo = fixtureRepo();
  try {
    writeFileSync(join(repo.root, 'engine/comment.sh'), "# old note\nnoop() {\n  :\n}\n");
    repo.commit('base');
    const base = repo.git('rev-parse', 'HEAD');

    writeFileSync(join(repo.root, 'engine/comment.sh'), "# new note\nnoop() {\n  :\n}\n");
    repo.commit('change comment');

    const result = repo.run(base, 'HEAD');
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /^non-function lines changed: \+1 -1$/m);
  } finally {
    rmSync(repo.root, { recursive: true, force: true });
  }
});
