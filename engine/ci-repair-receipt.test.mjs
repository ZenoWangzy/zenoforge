import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
process.env.ZF_REPO ??= 'example-maintainer/example-repo';
import { appendRepairReceipt, matchesRepairReceipt, validateRepairReceipt } from './ci-repair-receipt.mjs';

const receipt = {
  version: 2, branch: 'hand/original-pr', prNumber: 123,
  failureLink: 'https://github.com/example-maintainer/example-repo/actions/runs/123/job/456',
  checkName: 'CI', failedHeadSha: '1'.repeat(40), testedHeadSha: '2'.repeat(40),
  failedAt: '2026-10-10T00:00:00Z', failedAtMs: 1791590400000,
  recordedAt: '2026-10-10T00:00:01.000Z', recordedAtMs: 1791590401000,
  status: 'focused-passed', scope: 'failing-unit', failingPath: 'engine/failure.test.mjs',
  command: 'node --test engine/failure.test.mjs',
};
const modulePath = fileURLToPath(new URL('./ci-repair-receipt.mjs', import.meta.url));

test('shared receipt contract binds branch, failed check identity and tested HEAD', () => {
  assert.equal(matchesRepairReceipt(receipt, receipt), true);
  assert.equal(matchesRepairReceipt({ ...receipt, recordedAtMs: receipt.recordedAtMs + 1 }, receipt), true, 'existing v1 timestamp reads may differ');
  for (const patch of [
    { prNumber: 124 }, { branch: 'hand/temp' }, { testedHeadSha: '3'.repeat(40) }, { failedHeadSha: '4'.repeat(40) },
    { failureLink: `${receipt.failureLink}0` }, { checkName: 'different' }, { failedAt: '2026-10-10T00:00:02Z' },
  ]) assert.equal(matchesRepairReceipt(receipt, { ...receipt, ...patch }), false);
  for (const patch of [
    { version: 1 }, { failedAtMs: 0 }, { recordedAtMs: 0 }, { recordedAt: 'invalid' },
    { command: '' }, { status: 'made-up' }, { testedHeadSha: receipt.failedHeadSha },
    { status: 'ci-only', reason: 'CI-only' },
    { prNumber: undefined }, { status: 'passed' }, { scope: 'whole-check' },
    { status: 'stale-on-main', mainHeadSha: '3'.repeat(40) },
  ]) assert.equal(matchesRepairReceipt({ ...receipt, ...patch }, receipt), false);
  assert.deepEqual(validateRepairReceipt({ ...receipt, status: 'passed', scope: 'whole-check', failingPath: undefined }),
    { ...receipt, status: 'passed', scope: 'whole-check', failingPath: undefined });
  const ciOnly = (reason) => ({ ...receipt, status: 'ci-only', scope: undefined,
    failingPath: undefined, command: undefined, reason });
  assert.equal(matchesRepairReceipt(ciOnly('Docker runtime absent on local WSL host'), receipt), true);
  assert.equal(matchesRepairReceipt(ciOnly('本机无容器运行时'), receipt), true);
  const stale = {
    ...receipt, status: 'stale-on-main', mainHeadSha: '3'.repeat(40),
  };
  assert.equal(matchesRepairReceipt(stale, { ...receipt, mainHeadSha: stale.mainHeadSha }), true);
  assert.equal(matchesRepairReceipt(stale, { ...receipt, mainHeadSha: '4'.repeat(40) }), false);
  assert.equal(matchesRepairReceipt({ ...stale, mainHeadSha: undefined }, { ...receipt, mainHeadSha: stale.mainHeadSha }), false);
  assert.throws(() => validateRepairReceipt({ ...stale, status: 'reproduces-on-main' }), /main-reproduction evidence/);
  const reproductionEvidence = {
    failingPath: stale.failingPath,
    testedHeadFailure: 'engine/failure.test.mjs :: not ok 1 - target assertion',
    mainFailure: 'engine/failure.test.mjs :: not ok 1 - target assertion',
  };
  const reproduced = { ...stale, version: 3, status: 'reproduces-on-main', reproductionEvidence };
  assert.deepEqual(validateRepairReceipt(reproduced), reproduced);
  assert.throws(() => validateRepairReceipt({ ...reproduced,
    reproductionEvidence: { ...reproductionEvidence, mainFailure: 'engine/failure.test.mjs :: not ok 1 - startup error' },
  }), /main-reproduction evidence/);
  assert.throws(() => validateRepairReceipt({ ...reproduced,
    reproductionEvidence: { ...reproductionEvidence, failingPath: 'other.test.mjs' },
  }), /main-reproduction evidence/);
  assert.throws(() => validateRepairReceipt({ ...receipt, status: 'stale-on-main', mainHeadSha: undefined }), /stale-main evidence/);
});

test('hotfix receipt requires positive original PR number', () => {
  const hotfixReceipt = { ...receipt, branch: 'hotfix/lossrate-stage-3701', prNumber: 3716 };
  assert.equal(validateRepairReceipt(hotfixReceipt), hotfixReceipt);
  for (const prNumber of [undefined, 0, 3716.5]) {
    assert.throws(() => validateRepairReceipt({ ...hotfixReceipt, prNumber }), /Invalid CI repair receipt/);
  }
});

test('locked receipt append preserves concurrent owners; malformed JSON stays refused', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ci-repair-receipt-'));
  try {
    const receiptsFile = join(root, 'records.jsonl');
    appendRepairReceipt(receiptsFile, receipt);
    const children = Array.from({ length: 4 }, (_, index) => spawn(process.execPath,
      ['--input-type=module', '-e', `import { appendRepairReceipt } from ${JSON.stringify(new URL('./ci-repair-receipt.mjs', import.meta.url).href)};
appendRepairReceipt(process.argv[1], JSON.parse(process.argv[2]));`, receiptsFile,
        JSON.stringify({ ...receipt, branch: `hand/owner-${index}`, command: `node --test ${'x'.repeat(32768)}` })], { stdio: 'ignore' }));
    await Promise.all(children.map((child) => new Promise((resolve, reject) => {
      child.on('error', reject);
      child.on('exit', (status) => status === 0 ? resolve() : reject(new Error(`writer exit ${status}`)));
    })));
    const records = readFileSync(receiptsFile, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
    assert.equal(records.length, 5);
    assert.deepEqual(new Set(records.map((record) => record.branch)),
      new Set(['hand/original-pr', 'hand/owner-0', 'hand/owner-1', 'hand/owner-2', 'hand/owner-3']));
    const args = [modulePath, '--match', receiptsFile, receipt.branch, receipt.failedHeadSha,
      receipt.testedHeadSha, receipt.failureLink, receipt.checkName, receipt.failedAt, String(receipt.prNumber), ''];
    assert.equal(spawnSync(process.execPath, args).status, 0);
    writeFileSync(receiptsFile, `${readFileSync(receiptsFile, 'utf8')}not-json\n`);
    assert.equal(spawnSync(process.execPath, args).status, 1);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
