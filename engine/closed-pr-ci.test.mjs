import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';
import test from 'node:test';

const run = (id, number, overrides = {}) => ({
  id, event: 'pull_request', status: 'in_progress', path: '.github/workflows/ci.yml',
  pull_requests: [{ number }], ...overrides,
});

function sweep(t, fixture, dryRun = false) {
  const root = mkdtempSync(join(tmpdir(), 'closed-pr-ci-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'bin'));
  writeFileSync(join(root, 'fixture.json'), JSON.stringify(fixture));
  writeFileSync(join(root, 'calls.jsonl'), '');
  const snapshotPath = join(root, 'open-prs.json');
  if (!fixture.snapshotMissing) {
    const openPrs = fixture.openPrs ?? Object.entries(fixture.states ?? {})
      .filter(([, state]) => state === 'open')
      .map(([number]) => {
        const pr = fixture.associated?.find((entry) => entry.number === Number(number));
        return { number: Number(number), headRefName: pr?.head?.ref ?? `agent/issue-${number}`,
          headRepository: { nameWithOwner: pr?.head?.repo?.full_name ?? 'test/repo' } };
      });
    writeFileSync(snapshotPath, JSON.stringify(fixture.snapshot ?? {
      sampled_at: fixture.invalidSnapshot ? '1970-01-01T00:00:00Z'
        : new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), open_prs: openPrs,
    }));
  }
  if (fixture.auditFailure) mkdirSync(join(root, 'agent/logs/actions-run-cancellations.jsonl'), { recursive: true });
  writeFileSync(join(root, 'bin/gh'), `#!/usr/bin/env node
const fs = require('node:fs');
const root = process.env.CLOSED_PR_FIXTURE;
const fixture = JSON.parse(fs.readFileSync(root + '/fixture.json', 'utf8'));
const args = process.argv.slice(2);
fs.appendFileSync(root + '/calls.jsonl', JSON.stringify(args) + '\\n');
if (args[0] === 'run' && args[1] === 'cancel') {
  process.exit(fixture.cancelFailure === Number(args[2]) ? 1 : 0);
}
let value;
const endpoint = args[1];
if (endpoint.includes('/actions/runs?')) {
  if (fixture.listFailure) process.exit(1);
  const status = new URL('https://example.invalid/' + endpoint).searchParams.get('status');
  value = fixture[status] ?? [{ workflow_runs: [] }];
} else if (endpoint.includes('/pulls?')) {
  if (new URL('https://example.invalid/' + endpoint).searchParams.get('state') !== 'all') process.exit(2);
  value = [fixture.associated ?? []];
} else if (endpoint.includes('/pulls/')) {
  const number = endpoint.split('/').at(-1);
  if (!fixture.states[number]) process.exit(1);
  value = { number: Number(number), state: fixture.states[number] };
} else {
  process.exit(2);
}
process.stdout.write(args.includes('--jq') ? value.state : JSON.stringify(value));
`, { mode: 0o755 });
  const env = Object.fromEntries(Object.entries(process.env)
    .filter(([key]) => !/^(AGENT_|ZF_)/.test(key)));
  const result = spawnSync('bash', ['engine/night/main-ci-recovery.sh', 'cancel-closed-pr-runs'], {
    encoding: 'utf8', timeout: 20_000,
    env: { ...env, PATH: `${root}/bin:${env.PATH}`, CLOSED_PR_FIXTURE: root,
      AGENT_HOME: join(root, 'agent'), ZF_REPO: 'test/repo',
      ZF_OPEN_ISSUES_CACHE_FILE: snapshotPath,
      AGENT_DRY_RUN: dryRun ? '1' : '0', GH_CALL_TIMEOUT_SEC: '2' },
  });
  const calls = readFileSync(join(root, 'calls.jsonl'), 'utf8').trim()
    .split('\n').filter(Boolean).map((line) => JSON.parse(line));
  return { root, result, calls, cancelled: calls.filter(([verb, action]) => verb === 'run' && action === 'cancel').map((args) => Number(args[2])) };
}

function cancellationSources(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return cancellationSources(path);
    if (!/\.(?:mjs|sh|py)$/.test(entry.name) || /\.test\.(?:mjs|sh)$/.test(entry.name)) return [];
    return readFileSync(path, 'utf8').split('\n')
      .flatMap((line, index) => /^\s*(?:#|\/\/)/.test(line) ? []
        : /gh\s+run\s+cancel|actions\/runs\/[^"'\s]*\/cancel/.test(line)
          ? [{ path, line: index + 1 }] : []);
  });
}

test('closed and merged PRs cancel running and queued CI only; main evidence and open PRs survive', (t) => {
  const { root, result, calls, cancelled } = sweep(t, {
    in_progress: [{ workflow_runs: [
      run(36409061096, 1931),
      run(2, 1935),
      run(3, 1931, { event: 'push', head_branch: 'main' }),
      run(4, 1931, { event: 'workflow_dispatch' }),
      run(5, 1931, { path: '.github/workflows/unrelated.yml' }),
      run(6, 1931, { status: 'completed' }),
      run(12, 1931, { path: '.github/workflows/pipeline-suites.yml' }),
    ] }, { workflow_runs: [run(7, 1944, { event: 'pull_request_target' })] }],
    queued: [{ workflow_runs: [
      run(8, 1944, { status: 'queued', path: '.github/workflows/pipeline-suites.yml' }),
      run(9, 1931, { status: 'queued', event: 'push', head_branch: 'main' }),
      run(10, 1931, { pull_requests: [{ number: 1931 }, { number: 1935 }] }),
      run(13, 1944, { status: 'queued' }),
    ] }],
    states: { 1931: 'closed', 1935: 'open', 1944: 'closed' },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(cancelled, [36409061096, 12, 7, 8, 13]);
  const auditPath = join(root, 'agent/logs/actions-run-cancellations.jsonl');
  const audit = readFileSync(auditPath, 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(audit.map((entry) => Number(entry.run_id)), cancelled);
  for (const entry of audit) {
    assert.deepEqual(Object.keys(entry).sort(), ['reason', 'repo', 'run_id', 'when']);
    assert.equal(entry.reason, 'closed pr');
    assert.equal(entry.repo, 'test/repo');
    assert.match(entry.when, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  }
  assert.equal(calls.filter((args) => args[1].includes('/actions/runs?')).length, 2);
  assert.ok(calls.filter((args) => args[1].includes('/actions/runs?'))
    .every((args) => args.includes('--paginate') && args.includes('--slurp')));
});

test('missing run associations use PRs with matching repository and branch', (t) => {
  const { result, cancelled } = sweep(t, {
    in_progress: [{ workflow_runs: [run(11, 1931, {
      pull_requests: [], head_sha: 'a'.repeat(40), head_branch: 'pr/release-feature-acceptance',
      head_repository: { full_name: 'test/repo' },
    })] }],
    associated: [
      { number: 1931, head: { ref: 'pr/release-feature-acceptance', repo: { full_name: 'test/repo' } } },
      { number: 1935, head: { ref: 'other', repo: { full_name: 'test/repo' } } },
      { number: 1936, head: { ref: 'pr/release-feature-acceptance', repo: { full_name: 'fork/repo' } } },
    ],
    states: { 1931: 'closed', 1935: 'open', 1936: 'open' },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(cancelled, [11]);
});

test('unmerged closed PR with missing run associations still releases its runner', (t) => {
  const { result, cancelled } = sweep(t, {
    in_progress: [{ workflow_runs: [run(14, 1944, {
      pull_requests: [], head_sha: 'b'.repeat(40), head_branch: 'agent/issue-1944',
      head_repository: { full_name: 'test/repo' },
    })] }],
    associated: [{ number: 1944, state: 'closed', merged_at: null,
      head: { ref: 'agent/issue-1944', repo: { full_name: 'test/repo' } } }],
    states: { 1944: 'closed' },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(cancelled, [14]);
});

test('dry-run skips writes; invalid snapshots, API reads, and cancellation errors fail', (t) => {
  const fixture = { in_progress: [{ workflow_runs: [run(11, 1931)] }], states: { 1931: 'closed' } };
  const dry = sweep(t, fixture, true);
  assert.equal(dry.result.status, 0, dry.result.stderr);
  assert.deepEqual(dry.cancelled, []);
  assert.equal(existsSync(join(dry.root, 'agent/logs/actions-run-cancellations.jsonl')), false);
  assert.match(dry.result.stderr, /\[dry-run\] gh run cancel 11 --repo test\/repo/);

  for (const failure of [{ listFailure: true }, { invalidSnapshot: true }, { snapshotMissing: true },
    { snapshot: { sampled_at: '2000-01-01T00:00:00Z', open_prs: [] } },
    { snapshot: { sampled_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), open_prs: [{}] } },
    { cancelFailure: 11 }]) {
    const actual = sweep(t, { ...fixture, ...failure });
    assert.equal(actual.result.status, 1, actual.result.stderr);
    assert.deepEqual(actual.cancelled, failure.cancelFailure ? [11] : []);
  }
});

test('run cancellation fails closed when audit append fails', (t) => {
  const fixture = { in_progress: [{ workflow_runs: [run(11, 1931)] }], states: { 1931: 'closed' } };
  const { result, calls } = sweep(t, { ...fixture, auditFailure: true });
  assert.equal(result.status, 1, result.stderr);
  assert.deepEqual(calls.filter(([verb, action]) => verb === 'run' && action === 'cancel'), []);
});

test('every repository run cancellation uses the audited helper', () => {
  const sources = cancellationSources('engine');
  assert.equal(sources.length, 1);
  assert.equal(relative(process.cwd(), sources[0].path), 'engine/night/main-ci-recovery.sh');
});

test('cancellation source scan ignores comment-only examples', (t) => {
  const root = mkdtempSync(join(tmpdir(), 'closed-pr-source-scan-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeFileSync(join(root, 'example.sh'), '# gh run cancel 11 --repo test/repo\n');
  writeFileSync(join(root, 'example.mjs'), '// actions/runs/11/cancel\n');
  assert.deepEqual(cancellationSources(root), []);
});
