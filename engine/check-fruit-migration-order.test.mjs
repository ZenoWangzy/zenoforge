import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
const root = mkdtempSync(join(process.cwd(), '.git/order-test-'));
const config = join(root, 'config');
const pack = join(root, 'pack');
mkdirSync(config); mkdirSync(pack);
writeFileSync(join(config, 'release.json'), JSON.stringify({ migration: { path: 'packages/sample/migrations', orderMessages: { stale: 'configured stale', blockers: 'configured blockers:', passed: 'configured pass', unverified: 'configured error' } } }));
writeFileSync(join(pack, 'release.json'), JSON.stringify({ migration: { path: 'packages/other/migrations' } }));
process.env.ZF_CONFIG_ROOT = config;
process.env.ZF_PACK_DIR = pack;
const {
  ciCheck,
  journalWhenErrors,
  lowerOpenMigrationBlockers,
  mergeGate,
} = await import('./check-fruit-migration-order.mjs');

const dir = 'packages/sample/migrations/';
const entry = (idx, tag, when) => ({ idx, version: '7', when, tag, breakpoints: true });
const mainJournal = {
  entries: [entry(64, '0064_a', 100), entry(65, '0066_b', 200)],
};
const mainTags = new Set(mainJournal.entries.map((e) => e.tag));

test('a new journal entry must carry a when later than everything on main', () => {
  assert.deepEqual(journalWhenErrors({
    mainJournal,
    headJournal: { entries: [...mainJournal.entries, entry(66, '0067_c', 201)] },
  }), []);
  const errors = journalWhenErrors({
    mainJournal,
    headJournal: { entries: [entry(64, '0064_a', 100), entry(65, '0065_x', 150), entry(66, '0066_b', 200)] },
  });
  assert.equal(errors.length, 1);
  assert.match(errors[0], /configured stale$/);
  assert.match(errors[0], /0065_x has journal when 150, not later than main's latest 200/);
  assert.equal(journalWhenErrors({
    mainJournal,
    headJournal: { entries: [...mainJournal.entries, entry(66, '0067_c', 200)] },
  }).length, 1, 'equal when is skipped by Drizzle too');
});

test('an open non-draft PR with a lower-numbered migration blocks the merge', () => {
  const openPrs = [
    { number: 1, isDraft: false, files: [{ path: dir + '0065_x.sql' }] },
    { number: 2, isDraft: true, files: [{ path: dir + '0066_old_draft.sql' }] },
    { number: 3, isDraft: false, files: [{ path: dir + '0070_later.sql' }] },
    { number: 4, isDraft: false, files: [{ path: dir + '0066_b.sql' }] },
    { number: 5, isDraft: false, files: [{ path: dir + 'rollback/0060_r.sql' }] },
  ];
  assert.deepEqual(lowerOpenMigrationBlockers({
    prNumber: 9, prFiles: [dir + '0067_c.sql', dir + 'meta/_journal.json'], openPrs, mainTags,
  }), ['#1 (0065_x)']);
  assert.deepEqual(lowerOpenMigrationBlockers({
    prNumber: 1, prFiles: [dir + '0065_x.sql'], openPrs, mainTags,
  }), []);
  assert.deepEqual(lowerOpenMigrationBlockers({
    prNumber: 9, prFiles: ['scripts/x.sh', dir + '0066_b.sql'], openPrs, mainTags,
  }), [], 'editing a migration already on main reserves nothing');
});

function fakeGh({ prFiles, headJournal, openPrs, prChangedFiles = prFiles.length, paginatedFiles = {} }) {
  const calls = [];
  const run = (command, args) => {
    calls.push([command, ...args].join(' '));
    assert.equal(command, 'gh');
    if (args[0] === 'pr' && args[1] === 'view') {
      return JSON.stringify({
        files: prFiles.map((path) => ({ path })), changedFiles: prChangedFiles, headRefOid: 'abc',
      });
    }
    if (args[0] === 'pr' && args[1] === 'list') return JSON.stringify(openPrs);
    if (args[0] === 'api') {
      const prFilesMatch = /\/pulls\/(\d+)\/files\?per_page=100$/.exec(args[1]);
      if (prFilesMatch) {
        assert.deepEqual(args.slice(2), ['--paginate', '--jq', '.[].filename']);
        return (paginatedFiles[prFilesMatch[1]] ?? []).join('\n');
      }
      return JSON.stringify(args[1].endsWith('?ref=main') ? mainJournal : headJournal);
    }
    throw new Error('unexpected gh call ' + args.join(' '));
  };
  return { run, calls };
}

test('merge gate reports both the stale when and the blocking PRs', () => {
  const { run, calls } = fakeGh({
    prFiles: [dir + '0067_c.sql', dir + 'meta/_journal.json'],
    headJournal: { entries: [...mainJournal.entries, entry(66, '0067_c', 50)] },
    openPrs: [
      { number: 7, isDraft: false, files: [{ path: dir + '0065_x.sql' }], changedFiles: 1 },
      { number: 9, isDraft: false, files: [{ path: dir + '0067_c.sql' }], changedFiles: 1 },
    ],
  });
  const reasons = mergeGate({ repo: 'o/r', prNumber: 9, head: 'deadbeef', run });
  assert.equal(reasons.length, 2);
  assert.match(reasons[0], /0067_c has journal when 50/);
  assert.match(reasons[1], /configured blockers: #7 \(0065_x\)/);
  assert.ok(calls.some((call) => call.includes('_journal.json?ref=deadbeef')), 'reads the journal at the merge head');
});

test('merge gate passes an in-order PR and skips PRs without migrations', () => {
  const ordered = fakeGh({
    prFiles: [dir + '0067_c.sql'],
    headJournal: { entries: [...mainJournal.entries, entry(66, '0067_c', 300)] },
    openPrs: [{ number: 8, isDraft: false, files: [{ path: dir + '0068_d.sql' }], changedFiles: 1 }],
  });
  assert.deepEqual(mergeGate({ repo: 'o/r', prNumber: 9, run: ordered.run }), []);
  const unrelated = fakeGh({ prFiles: ['scripts/agent/lib.sh'], headJournal: mainJournal, openPrs: [] });
  assert.deepEqual(mergeGate({ repo: 'o/r', prNumber: 9, run: unrelated.run }), []);
  assert.equal(unrelated.calls.length, 1, 'no journal or open-PR reads for an unrelated PR');
});

test('merge gate recovers truncated files and detects a later-page lower migration', () => {
  const manyFiles = Array.from({ length: 101 }, (_, i) => `docs/file-${i}.md`);
  const { run, calls } = fakeGh({
    prFiles: manyFiles.slice(0, 100), prChangedFiles: 102,
    headJournal: { entries: [...mainJournal.entries, entry(66, '0067_c', 300)] },
    openPrs: [
      { number: 8, isDraft: false, files: manyFiles.slice(0, 100).map(path => ({ path })), changedFiles: 102 },
      { number: 9, isDraft: false, files: [], changedFiles: 102 },
      { number: 10, isDraft: true, files: [], changedFiles: 102 },
    ],
    paginatedFiles: { 9: [...manyFiles, dir + '0067_c.sql'], 8: [...manyFiles, dir + '0065_x.sql'] },
  });
  assert.deepEqual(mergeGate({ repo: 'o/r', prNumber: 9, run }), [
    'configured blockers: #8 (0065_x)',
  ]);
  assert.equal(calls.filter(call => call.includes('/pulls/')).length, 2,
    'only truncated current and non-draft peers need pagination');
});

test('merge gate refuses incomplete pagination for its own PR', () => {
  const { run } = fakeGh({ prFiles: [], prChangedFiles: 102, openPrs: [] });
  assert.throws(() => mergeGate({ repo: 'o/r', prNumber: 9, run }), /incomplete file list for PR #9/);
});

test('merge gate refuses to guess from an incomplete open-PR file list', () => {
  const { run } = fakeGh({
    prFiles: [dir + '0067_c.sql'],
    headJournal: { entries: [...mainJournal.entries, entry(66, '0067_c', 300)] },
    openPrs: [{ number: 8, isDraft: false, files: [], changedFiles: 120 }],
  });
  assert.throws(() => mergeGate({ repo: 'o/r', prNumber: 9, run }), /incomplete file list for PR #8/);
});

test('CI check compares the working-tree journal with the base ref', () => {
  const run = (command, args) => {
    assert.deepEqual([command, ...args], ['git', 'show', 'origin/main:' + dir + 'meta/_journal.json']);
    return JSON.stringify(mainJournal);
  };
  const stale = () => JSON.stringify({ entries: [...mainJournal.entries, entry(66, '0065_x', 199)] });
  assert.equal(ciCheck({ run, readFile: stale }).length, 1);
  const fresh = () => JSON.stringify({ entries: [...mainJournal.entries, entry(66, '0067_c', 201)] });
  assert.deepEqual(ciCheck({ run, readFile: fresh }), []);
});


test('config override wins over pack and missing config fails closed or delegates', () => {
  const script = join(process.cwd(), 'engine/check-fruit-migration-order.mjs');
  const run = (extra) => spawnSync(process.execPath, [script, '--ci'], {
    encoding: 'utf8', env: { ...process.env, ...extra },
  });
  const selected = run({});
  assert.match(selected.stdout, /packages\/sample\/migrations/);
  const fallback = run({ ZF_CONFIG_ROOT: join(root, 'missing') });
  assert.match(fallback.stdout, /packages\/other\/migrations/);
  const legacy = join(root, 'legacy'); mkdirSync(legacy);
  writeFileSync(join(legacy, 'check-fruit-migration-order.mjs'), "console.log('legacy');");
  assert.equal(run({ ZF_CONFIG_ROOT: join(root, 'missing'), ZF_PACK_DIR: legacy }).stdout.trim(), 'legacy');
  const missing = run({ ZF_CONFIG_ROOT: join(root, 'missing'), ZF_PACK_DIR: '' });
  assert.equal(missing.status, 2);
  assert.match(missing.stdout, /migration.path must be a nonempty relative path/);
});
