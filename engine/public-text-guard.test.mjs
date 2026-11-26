import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, test } from 'node:test';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const guardPath = join(repoRoot, 'engine/public-text-guard.mjs');
let tempRoot;

afterEach(() => {
  if (tempRoot) rmSync(tempRoot, { recursive: true, force: true });
  tempRoot = undefined;
});

function makeRepo({ baseline = '' } = {}) {
  if (tempRoot) rmSync(tempRoot, { recursive: true, force: true });
  tempRoot = mkdtempSync(join(tmpdir(), 'public-text-guard-'));
  const repo = join(tempRoot, 'repo');
  mkdirSync(join(repo, 'tools'), { recursive: true });
  execFileSync('git', ['init', '-q', '-b', 'main'], { cwd: repo });
  execFileSync('git', ['config', 'user.name', 'Public Text Test'], { cwd: repo });
  execFileSync('git', ['config', 'user.email', 'public-text-test@example.invalid'], { cwd: repo });
  if (baseline !== null) writeFileSync(join(repo, 'tools/public-text-baseline.txt'), baseline);
  writeFileSync(join(repo, 'notes.md'), 'clean text\n');
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'fixture'], { cwd: repo });
  execFileSync('git', ['tag', 'base'], { cwd: repo });
  return repo;
}

function runGuard(repo, env = {}) {
  const childEnv = { ...process.env, GITHUB_EVENT_PATH: '', ...env };
  if (!Object.hasOwn(env, 'ZF_PUBLIC_TEXT_DENYLIST')) childEnv.ZF_PUBLIC_TEXT_DENYLIST = '';
  if (env.ZF_PUBLIC_TEXT_DENYLIST === null) delete childEnv.ZF_PUBLIC_TEXT_DENYLIST;
  return spawnSync(process.execPath, [guardPath, '--base', 'base', '--head', 'HEAD'], {
    cwd: repo,
    encoding: 'utf8',
    env: childEnv,
  });
}

function baselineRow(kind, file) {
  const id = file.startsWith('name:') ? file : `name:${createHash('sha256').update(file).digest('hex')}`;
  return `${kind}\t${id}\n`;
}

test('a newly committed home path fails with its file and line only', () => {
  const repo = makeRepo();
  const homePath = ['/home', 'someone', 'x'].join('/');
  writeFileSync(join(repo, 'notes.md'), `${homePath}\n`);
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'add path'], { cwd: repo });

  const result = runGuard(repo);
  const output = `${result.stdout}${result.stderr}`;
  assert.equal(result.status, 1, output);
  assert.match(output, /notes\.md:1/);
  assert.doesNotMatch(output, /someone/);
});

test('added lines beginning with plus signs are still scanned', () => {
  const repo = makeRepo();
  const homePath = ['/home', 'someone', 'x'].join('/');
  writeFileSync(join(repo, 'notes.md'), `++ ${homePath}\n`);
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'add plus-prefixed path'], { cwd: repo });

  const result = runGuard(repo);
  assert.equal(result.status, 1, `${result.stdout}${result.stderr}`);
  assert.match(`${result.stdout}${result.stderr}`, /notes\.md:1/);
});

test('a denylisted term fails without printing the term', () => {
  const repo = makeRepo();
  const deniedTerm = 'internal-label-7c81';
  writeFileSync(join(repo, 'notes.md'), `${deniedTerm}\n`);
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'add private term'], { cwd: repo });

  const result = runGuard(repo, { ZF_PUBLIC_TEXT_DENYLIST: deniedTerm });
  const output = `${result.stdout}${result.stderr}`;
  assert.equal(result.status, 1, output);
  assert.match(output, /notes\.md:1/);
  assert.doesNotMatch(output, new RegExp(deniedTerm));
});

test('a denylisted term in a changed filename fails without printing the term', () => {
  const repo = makeRepo();
  const deniedTerm = 'internal-project-4a12';
  writeFileSync(join(repo, `${deniedTerm}.md`), 'clean text\n');
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'add named file'], { cwd: repo });

  const result = runGuard(repo, { ZF_PUBLIC_TEXT_DENYLIST: deniedTerm });
  const output = `${result.stdout}${result.stderr}`;
  assert.equal(result.status, 1, output);
  assert.match(output, /\[redacted\]\.md:filename/);
  assert.doesNotMatch(output, new RegExp(deniedTerm));
});

test('POSIX and Windows home path forms fail', () => {
  const separator = String.fromCharCode(92);
  const paths = [
    ['/Users', 'someone', 'project', ''].join('/'),
    ['/home', 'someone'].join('/'),
    ['', 'root'].join('/'),
    ['', 'root', 'project'].join('/'),
    ['', 'var', 'root', 'project'].join('/'),
    ['C:', ['Users', 'someone', 'project'].join(separator)].join(separator),
    ['C:', ['Users', 'someone'].join(separator)].join(separator),
  ];
  for (const homePath of paths) {
    const repo = makeRepo();
    writeFileSync(join(repo, 'notes.md'), `${homePath}\n`);
    execFileSync('git', ['add', '-A'], { cwd: repo });
    execFileSync('git', ['commit', '-q', '-m', 'add path'], { cwd: repo });
    const result = runGuard(repo);
    const output = `${result.stdout}${result.stderr}`;
    assert.equal(result.status, 1, output);
    assert.match(output, /notes\.md:1/);
    assert.doesNotMatch(output, /someone/);
  }
});

test('private terms in commit messages and PR bodies fail without being printed', () => {
  const deniedTerm = 'internal-label-7c81';
  const repo = makeRepo();
  execFileSync('git', ['commit', '-q', '--allow-empty', '-m', deniedTerm], { cwd: repo });
  const commitResult = runGuard(repo, { ZF_PUBLIC_TEXT_DENYLIST: deniedTerm });
  const commitOutput = `${commitResult.stdout}${commitResult.stderr}`;
  assert.equal(commitResult.status, 1, commitOutput);
  assert.match(commitOutput, /commit message [a-f0-9]{12}:1/);
  assert.doesNotMatch(commitOutput, new RegExp(deniedTerm));

  const eventPath = join(tempRoot, 'event.json');
  writeFileSync(eventPath, JSON.stringify({ pull_request: { body: deniedTerm } }));
  const bodyResult = runGuard(repo, { GITHUB_EVENT_PATH: eventPath, ZF_PUBLIC_TEXT_DENYLIST: deniedTerm });
  const bodyOutput = `${bodyResult.stdout}${bodyResult.stderr}`;
  assert.equal(bodyResult.status, 1, bodyOutput);
  assert.match(bodyOutput, /PR body:1/);
  assert.doesNotMatch(bodyOutput, new RegExp(deniedTerm));
});

test('home paths in commit messages and PR bodies fail when the denylist is absent', () => {
  const repo = makeRepo();
  const homePath = ['/home', 'someone', 'x'].join('/');
  execFileSync('git', ['commit', '-q', '--allow-empty', '-m', homePath], { cwd: repo });
  const commitResult = runGuard(repo);
  const commitOutput = `${commitResult.stdout}${commitResult.stderr}`;
  assert.equal(commitResult.status, 1, commitOutput);
  assert.match(commitOutput, /commit message [a-f0-9]{12}:1/);
  assert.doesNotMatch(commitOutput, /someone/);

  const eventPath = join(tempRoot, 'event.json');
  writeFileSync(eventPath, JSON.stringify({ pull_request: { body: homePath } }));
  const bodyResult = runGuard(repo, { GITHUB_EVENT_PATH: eventPath });
  const bodyOutput = `${bodyResult.stdout}${bodyResult.stderr}`;
  assert.equal(bodyResult.status, 1, bodyOutput);
  assert.match(bodyOutput, /PR body:1/);
  assert.doesNotMatch(bodyOutput, /someone/);
});

test('an unconfigured denylist is reported while path checking remains active', () => {
  const repo = makeRepo();
  const result = runGuard(repo);
  assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
  assert.match(result.stdout, /private denylist skipped/);

  const homePath = ['/home', 'someone', 'project', ''].join('/');
  writeFileSync(join(repo, 'notes.md'), `${homePath}\n`);
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'add path'], { cwd: repo });
  const pathResult = runGuard(repo);
  assert.equal(pathResult.status, 1, `${pathResult.stdout}${pathResult.stderr}`);
  assert.match(`${pathResult.stdout}${pathResult.stderr}`, /notes\.md:1/);
  assert.match(pathResult.stdout, /private denylist skipped/);
});

test('the local config denylist is read from the XDG config root', () => {
  const repo = makeRepo();
  const deniedTerm = 'local-private-label-61';
  writeFileSync(join(repo, 'notes.md'), `${deniedTerm}\n`);
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'add config term'], { cwd: repo });
  const configRoot = join(tempRoot, 'config');
  mkdirSync(join(configRoot, 'zenoforge'), { recursive: true });
  writeFileSync(join(configRoot, 'zenoforge/public-text-denylist'), `${deniedTerm}\n`);

  const result = runGuard(repo, { XDG_CONFIG_HOME: configRoot, ZF_PUBLIC_TEXT_DENYLIST: null });
  const output = `${result.stdout}${result.stderr}`;
  assert.equal(result.status, 1, output);
  assert.match(output, /notes\.md:1/);
  assert.doesNotMatch(output, new RegExp(deniedTerm));
  assert.doesNotMatch(output, /private denylist skipped/);
});

test('the existing-text baseline can shrink but cannot grow', () => {
  const homePath = ['/home', 'someone', 'project', ''].join('/');
  const row = baselineRow('path', 'notes.md');
  const repo = makeRepo();
  writeFileSync(join(repo, 'notes.md'), `${homePath}\n`);
  writeFileSync(join(repo, 'tools/public-text-baseline.txt'), row);
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'seed existing baseline'], { cwd: repo });
  execFileSync('git', ['tag', '-f', 'base'], { cwd: repo });

  const addedPath = ['/home', 'new-person', 'x'].join('/');
  writeFileSync(join(repo, 'notes.md'), `${homePath}\n${addedPath}\n`);
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'add path to an existing baseline file'], { cwd: repo });
  const sameFileResult = runGuard(repo);
  const sameFileOutput = `${sameFileResult.stdout}${sameFileResult.stderr}`;
  assert.equal(sameFileResult.status, 1, sameFileOutput);
  assert.match(sameFileOutput, /notes\.md:2/);
  assert.doesNotMatch(sameFileOutput, /new-person/);
  execFileSync('git', ['reset', '-q', '--hard', 'base'], { cwd: repo });

  writeFileSync(join(repo, 'notes.md'), 'clean text\n');
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'remove existing path'], { cwd: repo });
  const fixedResult = runGuard(repo);
  assert.equal(fixedResult.status, 0, `${fixedResult.stdout}${fixedResult.stderr}`);

  writeFileSync(join(repo, 'tools/public-text-baseline.txt'), '');
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '--amend', '--no-edit'], { cwd: repo });
  const shrinkResult = runGuard(repo);
  assert.equal(shrinkResult.status, 0, `${shrinkResult.stdout}${shrinkResult.stderr}`);

  execFileSync('git', ['reset', '-q', '--hard', 'base'], { cwd: repo });
  writeFileSync(join(repo, 'tools/public-text-baseline.txt'), '');
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'remove a live baseline entry'], { cwd: repo });
  const liveEntryResult = runGuard(repo);
  assert.equal(liveEntryResult.status, 1, `${liveEntryResult.stdout}${liveEntryResult.stderr}`);
  assert.match(`${liveEntryResult.stdout}${liveEntryResult.stderr}`, /baseline entry still matches/);

  execFileSync('git', ['reset', '-q', '--hard', 'base'], { cwd: repo });
  const newPath = ['/home', 'new-person', 'project', ''].join('/');
  writeFileSync(join(repo, 'other.md'), `${newPath}\n`);
  writeFileSync(join(repo, 'tools/public-text-baseline.txt'), `${baselineRow('path', 'notes.md')}${baselineRow('path', 'other.md')}`);
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'add baseline entry'], { cwd: repo });
  const growthResult = runGuard(repo);
  const growthOutput = `${growthResult.stdout}${growthResult.stderr}`;
  assert.equal(growthResult.status, 1, growthOutput);
  assert.match(growthOutput, /baseline may only shrink/);
  assert.doesNotMatch(growthOutput, /new-person/);
});

test('the first baseline can list only matches already on main', () => {
  const repo = makeRepo({ baseline: null });
  const homePath = ['/home', 'someone', 'project', ''].join('/');
  mkdirSync(join(repo, 'docs'), { recursive: true });
  writeFileSync(join(repo, 'docs/notes.md'), `${homePath}\n`);
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'existing path on main'], { cwd: repo });
  execFileSync('git', ['tag', '-f', 'base'], { cwd: repo });
  writeFileSync(join(repo, 'tools/public-text-baseline.txt'), '');
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'omit existing baseline match'], { cwd: repo });
  const missingResult = runGuard(repo);
  assert.equal(missingResult.status, 1, `${missingResult.stdout}${missingResult.stderr}`);
  assert.match(`${missingResult.stdout}${missingResult.stderr}`, /main match missing from baseline: docs\/notes\.md:1/);

  execFileSync('git', ['reset', '-q', '--hard', 'base'], { cwd: repo });
  mkdirSync(join(repo, 'tools'), { recursive: true });
  writeFileSync(join(repo, 'tools/public-text-baseline.txt'), baselineRow('path', 'docs/notes.md'));
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'seed baseline'], { cwd: repo });

  const result = runGuard(repo);
  assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
  assert.doesNotMatch(`${result.stdout}${result.stderr}`, /fatal:/);

  const newPath = ['/home', 'new-person', 'x'].join('/');
  writeFileSync(join(repo, 'other.md'), `${newPath}\n`);
  writeFileSync(join(repo, 'tools/public-text-baseline.txt'), `${baselineRow('path', 'docs/notes.md')}${baselineRow('path', 'other.md')}`);
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'seed new match'], { cwd: repo });
  const growthResult = runGuard(repo);
  assert.equal(growthResult.status, 1, `${growthResult.stdout}${growthResult.stderr}`);
  assert.match(`${growthResult.stdout}${growthResult.stderr}`, /other\.md:1/);
  assert.doesNotMatch(`${growthResult.stdout}${growthResult.stderr}`, /new-person/);
});

test('filename matches use opaque baseline ids and cannot shrink while they remain', () => {
  const repo = makeRepo({ baseline: null });
  const deniedTerm = 'internal-project-4a12';
  const filename = `${deniedTerm}.md`;
  writeFileSync(join(repo, filename), 'clean text\n');
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'existing private filename'], { cwd: repo });
  execFileSync('git', ['tag', '-f', 'base'], { cwd: repo });
  const id = `name:${createHash('sha256').update(filename).digest('hex')}`;
  writeFileSync(join(repo, 'tools/public-text-baseline.txt'), baselineRow('private', id));
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'seed filename baseline'], { cwd: repo });

  const result = runGuard(repo, { ZF_PUBLIC_TEXT_DENYLIST: deniedTerm });
  const output = `${result.stdout}${result.stderr}`;
  assert.equal(result.status, 0, output);
  assert.doesNotMatch(output, new RegExp(deniedTerm));

  execFileSync('git', ['tag', '-f', 'base', 'HEAD'], { cwd: repo });
  writeFileSync(join(repo, 'tools/public-text-baseline.txt'), '');
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'remove filename baseline'], { cwd: repo });
  const shrinkResult = runGuard(repo, { ZF_PUBLIC_TEXT_DENYLIST: deniedTerm });
  const shrinkOutput = `${shrinkResult.stdout}${shrinkResult.stderr}`;
  assert.equal(shrinkResult.status, 1, shrinkOutput);
  assert.match(shrinkOutput, /baseline entry still matches: name:[a-f0-9]{64}/);
  assert.doesNotMatch(shrinkOutput, new RegExp(deniedTerm));
});

test('existing private matches on main must be in the baseline when the denylist is configured', () => {
  const repo = makeRepo();
  const deniedTerm = 'internal-existing-label-5b73';
  writeFileSync(join(repo, 'notes.md'), `${deniedTerm}\n`);
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'existing term on main'], { cwd: repo });
  execFileSync('git', ['tag', '-f', 'base', 'HEAD'], { cwd: repo });
  writeFileSync(join(repo, 'other.md'), 'clean text\n');
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'unrelated clean change'], { cwd: repo });

  const result = runGuard(repo, { ZF_PUBLIC_TEXT_DENYLIST: deniedTerm });
  const output = `${result.stdout}${result.stderr}`;
  assert.equal(result.status, 1, output);
  assert.match(output, /main match missing from baseline: notes\.md:1/);
  assert.doesNotMatch(output, new RegExp(deniedTerm));
});

test('a renamed file with a live private match is scanned as added content', () => {
  const repo = makeRepo();
  const deniedTerm = 'internal-rename-label-18c4';
  writeFileSync(join(repo, 'notes.md'), `${deniedTerm}\n`);
  writeFileSync(join(repo, 'tools/public-text-baseline.txt'), baselineRow('private', 'notes.md'));
  execFileSync('git', ['add', '-A'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'seed private baseline'], { cwd: repo });
  execFileSync('git', ['tag', '-f', 'base', 'HEAD'], { cwd: repo });
  execFileSync('git', ['mv', 'notes.md', 'renamed.md'], { cwd: repo });
  execFileSync('git', ['commit', '-q', '-m', 'rename matching file'], { cwd: repo });

  const result = runGuard(repo, { ZF_PUBLIC_TEXT_DENYLIST: deniedTerm });
  const output = `${result.stdout}${result.stderr}`;
  assert.equal(result.status, 1, output);
  assert.match(output, /renamed\.md:1/);
  assert.doesNotMatch(output, new RegExp(deniedTerm));
});
