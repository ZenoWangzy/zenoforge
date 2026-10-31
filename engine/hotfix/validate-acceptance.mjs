#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { zfConfigFile } from '../pack-dir.mjs';

const START = '<!-- vecta-hotfix-acceptance:start -->';
const END = '<!-- vecta-hotfix-acceptance:end -->';
const ACCEPTANCE_USER = process.env.ZF_ACCEPTANCE_USER ?? '验收用户'; // default mirrors config.sh
const TEST_ONLY_PATH = /(^|\/)(tests?|__tests__|fixtures?)\/|\.test\.[^/]+$|(^|\/)test_[^/]+\.py$|_test\.py$/;

function validateAcceptance(body, headSha, changedFiles = '') {
  const startCount = body.split(START).length - 1;
  const endCount = body.split(END).length - 1;
  if (startCount !== 1 || endCount !== 1) {
    throw new Error('PR body must contain exactly one structured hotfix acceptance record');
  }

  const start = body.indexOf(START) + START.length;
  const end = body.indexOf(END);
  if (end <= start) throw new Error('structured hotfix acceptance record is malformed');

  let record;
  try {
    record = JSON.parse(body.slice(start, end).trim());
  } catch {
    throw new Error('structured hotfix acceptance record must be valid JSON');
  }

  if (record?.schema !== 'example.hotfix-acceptance/v1') {
    throw new Error('acceptance record schema must be example.hotfix-acceptance/v1');
  }
  // A test-only hotfix (fixtures/tests, no production behaviour) has nothing for 验收用户 to accept in prod;
  // it declares not_applicable instead of a false "passed" record (10-29 #4689).
  if (record?.status === 'not_applicable') {
    const files = String(changedFiles).split('\n').map((f) => f.trim()).filter(Boolean);
    if (record?.reason !== 'test-only') throw new Error('not_applicable acceptance needs reason test-only');
    if (!files.length || !files.every((f) => TEST_ONLY_PATH.test(f))) {
      throw new Error('not_applicable acceptance is only valid when every changed file is a test or fixture');
    }
  } else if (record?.status === 'deferred-to-release') {
    // A dist that needs an unreleased migration cannot be hot-installed, so 验收用户 accepts it on the released images.
    // Only PRs the release owner names in release-deferred.json (read from main in CI) qualify (head 10-29, #4687).
    if (record?.reason !== 'needs-unreleased-migration') throw new Error('deferred-to-release needs reason needs-unreleased-migration');
    const pr = process.env.PR_NUMBER || /^refs\/pull\/(\d+)\//.exec(process.env.GITHUB_REF ?? '')?.[1];
    const deferredFile = zfConfigFile('hotfix/release-deferred.json');
    if (!deferredFile) throw new Error('release-deferred.json is not configured');
    const named = JSON.parse(readFileSync(deferredFile, 'utf8'));
    if (!pr || !Object.hasOwn(named, pr)) throw new Error(`deferred-to-release is only valid for PRs named in release-deferred.json (PR ${pr ?? 'unknown'})`);
  } else {
    if (record?.status !== 'passed') throw new Error(`${ACCEPTANCE_USER} acceptance status must be passed`);
    if (record?.accepted_by !== ACCEPTANCE_USER) throw new Error(`accepted_by must be ${ACCEPTANCE_USER}`);
  }
  if (typeof record?.accepted_head_sha !== 'string'
    || !/^[0-9a-f]{40,64}$/i.test(record.accepted_head_sha)
    || record.accepted_head_sha.toLowerCase() !== String(headSha).toLowerCase()) {
    throw new Error('accepted_head_sha must match the current PR head SHA');
  }
  if (record.status === 'passed' && (typeof record?.evidence !== 'string' || !record.evidence.trim())) {
    throw new Error('acceptance evidence must be a non-empty string');
  }
  return record.status;
}

try {
  const status = validateAcceptance(process.env.PR_BODY ?? '', process.env.PR_HEAD_SHA ?? '', process.env.PR_CHANGED_FILES ?? '');
  process.stdout.write({
    passed: `hotfix acceptance: ${ACCEPTANCE_USER} passed for ${process.env.PR_HEAD_SHA}\n`,
    not_applicable: `hotfix acceptance: test-only change, ${ACCEPTANCE_USER} acceptance not applicable for ${process.env.PR_HEAD_SHA}\n`,
  }[status] ?? `hotfix acceptance: deferred to release (needs unreleased migration) for ${process.env.PR_HEAD_SHA}\n`);
} catch (error) {
  process.stderr.write(`hotfix acceptance: ${error.message}\n`);
  process.exitCode = 1;
}
