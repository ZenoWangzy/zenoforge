import { spawnSync } from 'node:child_process';
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Shared by the official writer and the canonical installed pre-push guard.
// v2 distinguishes focused checks; v3 binds main-reproduction receipts to the same observed test failure on both heads.
export const REPAIR_RECEIPT_VERSION = 3;
const modulePath = fileURLToPath(import.meta.url);
const fullSha = (value) => /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(value ?? '');
const text = (value) => typeof value === 'string' && value.trim().length > 0;
const timestamp = (value) => typeof value === 'string'
  && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(value)
  && Number.isFinite(Date.parse(value));
export const fullCheckCommandFor = (checkName) => {
  const shard = /^Pipeline suites shard ([0-4])$/.exec(checkName ?? '');
  return shard ? `bash engine/run-ci-suites.sh --shard ${shard[1]}/5` : undefined;
};

// The failing check must belong to the configured repository (ZF_REPO, owner/name).
const failureLinkPattern = () => new RegExp(
  `^https://github\\.com/${(process.env.ZF_REPO ?? '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/actions/runs/\\d+(?:/job/\\d+)?$`,
);

export function validateRepairReceipt(receipt) {
  const agentRepairBranch = /^(?:agent\/issue-.+|hand(?:\/|-).+)$/.test(receipt?.branch ?? '');
  const hotfixRepairBranch = /^hotfix\/[^/]+$/.test(receipt?.branch ?? '');
  const validPullRequestNumber = Number.isSafeInteger(receipt?.prNumber) && receipt.prNumber > 0;
  if (!receipt || ![2, REPAIR_RECEIPT_VERSION].includes(receipt.version)
      || (!agentRepairBranch && !(hotfixRepairBranch && validPullRequestNumber))
      || !validPullRequestNumber
      || !failureLinkPattern().test(receipt.failureLink ?? '')
      || !text(receipt.checkName) || !fullSha(receipt.failedHeadSha) || !fullSha(receipt.testedHeadSha)
      || receipt.failedHeadSha === receipt.testedHeadSha
      || !timestamp(receipt.failedAt) || !timestamp(receipt.recordedAt)
      || receipt.failedAtMs !== Date.parse(receipt.failedAt)
      // Older v1 writers read ISO time and milliseconds separately.
      || !Number.isSafeInteger(receipt.recordedAtMs)
      || Date.parse(receipt.recordedAt) > receipt.recordedAtMs
      || Date.parse(receipt.recordedAt) <= receipt.failedAtMs
      || receipt.recordedAtMs <= receipt.failedAtMs) {
    throw new Error('Invalid CI repair receipt identity or timestamps.');
  }
  const validFailingPath = text(receipt.failingPath)
    && !/^(?:\/|[A-Za-z]:)/.test(receipt.failingPath)
    && !receipt.failingPath.split(/[\\/]/).includes('..');
  const fullCheckCommand = fullCheckCommandFor(receipt.checkName);
  if (receipt.status === 'passed' && receipt.scope === 'whole-check' && text(receipt.command)
      && (!fullCheckCommand || receipt.command === fullCheckCommand)
      && receipt.reason === undefined && receipt.failingPath === undefined && receipt.mainHeadSha === undefined) return receipt;
  if (receipt.status === 'focused-passed' && receipt.scope === 'failing-unit'
      && text(receipt.command) && validFailingPath
      && receipt.reason === undefined && receipt.mainHeadSha === undefined) return receipt;
  if (receipt.status === 'ci-only' && text(receipt.reason)
      && !/^(?:ci[- ]only|(?:local )?infrastructure unavailable|not available locally|<.*>)$/i.test(receipt.reason.trim())
      && receipt.command === undefined && receipt.scope === undefined
      && receipt.failingPath === undefined && receipt.mainHeadSha === undefined) return receipt;
  if (receipt.status === 'stale-on-main'
      && receipt.scope === 'failing-unit' && text(receipt.command)
      && fullSha(receipt.mainHeadSha) && validFailingPath && receipt.reason === undefined) return receipt;
  const evidence = receipt.reproductionEvidence;
  if (receipt.status === 'reproduces-on-main' && receipt.version === REPAIR_RECEIPT_VERSION
      && receipt.scope === 'failing-unit' && text(receipt.command)
      && fullSha(receipt.mainHeadSha) && validFailingPath && receipt.reason === undefined
      && evidence && evidence.failingPath === receipt.failingPath
      && text(evidence.testedHeadFailure) && evidence.testedHeadFailure.length <= 1000
      && text(evidence.mainFailure) && evidence.mainFailure.length <= 1000
      && evidence.testedHeadFailure === evidence.mainFailure
      && evidence.testedHeadFailure.startsWith(`${receipt.failingPath.split(/[\\/]/).slice(-2).join('/')} :: `)) return receipt;
  throw new Error('CI repair receipt needs a whole-check pass, focused-unit pass, specific CI-only limitation, stale-main evidence, or main-reproduction evidence.');
}

export function matchesRepairReceipt(receipt, wanted) {
  try { validateRepairReceipt(receipt); } catch { return false; }
  if (!['branch', 'prNumber', 'failureLink', 'checkName', 'failedHeadSha', 'testedHeadSha', 'failedAt']
    .every((key) => receipt[key] === wanted[key])) return false;
  return !['stale-on-main', 'reproduces-on-main'].includes(receipt.status)
    || (fullSha(wanted.mainHeadSha) && receipt.mainHeadSha === wanted.mainHeadSha);
}

export function appendRepairReceipt(receiptsFile, receipt) {
  validateRepairReceipt(receipt);
  mkdirSync(dirname(receiptsFile), { recursive: true, mode: 0o700 });
  const result = spawnSync('flock', ['-w', '30', `${receiptsFile}.lock`, process.execPath,
    modulePath, '--append', receiptsFile], {
    input: JSON.stringify(receipt), encoding: 'utf8', timeout: 35000,
  });
  if (result.error || result.status !== 0) throw new Error(`CI repair receipt append failed: ${result.error?.message ?? result.stderr}`);
}

if (process.argv[1] && resolve(process.argv[1]) === modulePath) {
  try {
    const [operation, receiptsFile, branch, failedHeadSha, testedHeadSha, failureLink, checkName, failedAt, prNumber, mainHeadSha] = process.argv.slice(2);
    if (operation === '--append') {
      const receipt = validateRepairReceipt(JSON.parse(readFileSync(0, 'utf8')));
      const fd = openSync(receiptsFile, 'a', 0o600);
      try {
        writeFileSync(fd, `${JSON.stringify(receipt)}\n`);
        fsyncSync(fd);
      } finally { closeSync(fd); }
      const directory = openSync(dirname(receiptsFile), 'r');
      try { fsyncSync(directory); } finally { closeSync(directory); }
    } else if (operation === '--match') {
      const receipts = readFileSync(receiptsFile, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line));
      process.exitCode = receipts.some((receipt) => matchesRepairReceipt(receipt,
        { branch, failedHeadSha, testedHeadSha, failureLink, checkName, failedAt,
          prNumber: Number(prNumber), mainHeadSha })) ? 0 : 1;
    } else throw new Error('Unknown CI repair receipt operation.');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
