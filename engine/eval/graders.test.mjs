import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gradeTriage, gradeAdvisor, gradeReview, gradeSupervisor, gradeTests, gradeImplementDecision } from './graders.mjs';

test('triage compares routing fields and treats package order as a set', () => {
  const expected = { state: 'ready-for-agent', risk_class: 'P1', expected_packages: ['a', 'b'] };
  assert.equal(gradeTriage({ ...expected, expected_packages: ['b', 'a'] }, expected).pass, true);
  assert.equal(gradeTriage({ ...expected, risk_class: 'P2' }, expected).pass, false);
  assert.equal(gradeTriage({}, expected).pass, false);
});
test('triage accepts equivalent wording for the same required external target', () => {
  const expected = { external_deliverable: {
    required: true,
    location: '~/.zenoforge/model-policy.json on the landing host',
    reason: 'Migrate persistent host policy and validate the shared landing flow.',
  } };
  const actual = { external_deliverable: {
    required: true,
    location: 'operator host ~/.zenoforge/model-policy.json; validate direct-main through the shared lock',
    reason: 'The host configuration and locked landing run are outside a repository-only change.',
  } };
  assert.equal(gradeTriage(actual, expected).pass, true);
  assert.equal(gradeTriage({ ...actual, external_deliverable: { ...actual.external_deliverable, location: '/etc/other-policy.json' } }, expected).pass, false);
  assert.equal(gradeTriage({ ...actual, external_deliverable: { required: false, location: '', reason: '' } }, expected).pass, false);
});
test('advisor requires every decision fact, allows synonyms, rejects negated claims', () => {
  const rubric = [{ fact: 'atomic replacement', any: ['atomic rename', '原子替换'] }, { fact: 'flush', any: ['fsync'] }];
  assert.equal(gradeAdvisor({ decision_md: '原子替换; fsync' }, { rubric }).pass, true);
  assert.equal(gradeAdvisor({ decision_md: 'atomic rename' }, { rubric }).pass, false);
  assert.equal(gradeAdvisor({ decision_md: 'do not fsync; atomic rename' }, { rubric, forbidden: ['do not fsync'] }).pass, false);
});
test('review needs an explicit verdict and the known defect file for rejection', () => {
  const expected = { verdict: 'NOT_READY', defectFiles: ['src/write.ts'] };
  const candidate = { id: 'F1', severity: 'P1', file: 'src/write.ts', line: 12, rule: 'Defect', status: 'open',
    summary: 'Unauthorized writes cross the tenant boundary.', introduced_by: 'candidate', base_evidence: 'The base has no path to this write.',
    rerun_command: 'node write.test.mjs', rerun_output: 'FAIL cross-tenant write allowed' };
  const report = (verdict, finding = candidate) => `VERDICT: ${verdict}\n\n\`\`\`review-findings\n${JSON.stringify({ findings: [finding], dispositions: [] })}\n\`\`\``;
  assert.equal(gradeReview(report('NOT_READY'), expected).pass, true);
  assert.equal(gradeReview('NOT_READY in src/read.ts', expected).pass, false);
  assert.equal(gradeReview(report('READY'), expected).pass, false);
  const preExisting = { ...candidate, introduced_by: 'pre_existing', base_evidence: 'The same path is present at src/write.ts:8 in the base.' };
  assert.equal(gradeReview(report('READY', preExisting), { verdict: 'READY' }).pass, true);
  assert.equal(gradeReview(report('APPROVE', preExisting), { verdict: 'READY' }).pass, true);
  assert.equal(gradeReview(report('NOT_READY', preExisting), { verdict: 'NOT_READY', defectFiles: ['src/write.ts'] }).pass, false);
  const unverified = { ...candidate, rerun_output: '' };
  assert.equal(gradeReview(report('NOT_READY', unverified), expected).pass, false, 'a finding without rerun output is not a blocker');
  const missingBaseEvidence = { ...candidate, base_evidence: '' };
  assert.equal(gradeReview(report('NOT_READY', missingBaseEvidence), expected).pass, false);
  const authorDispositionInReview = `VERDICT: READY\n\n\`\`\`review-findings\n${JSON.stringify({ findings: [], dispositions: [{ id: 'F1', disposition: 'fixed', reason: 'already fixed' }] })}\n\`\`\``;
  assert.equal(gradeReview(authorDispositionInReview, { verdict: 'READY' }).pass, false);
  assert.equal(gradeReview('VERDICT: NOT_READY\nsrc/write.ts:12 broken', expected).pass, false);
});
test('supervisor arbitration maps the six actions and rejects unsafe approval', () => {
  assert.deepEqual(gradeSupervisor('ACTION: approve\nREASON: operational stalemate', { action: 'approve' }),
    { pass: true, failures: [], action: 'approve', expectedAction: 'approve', unsafeApprove: false });
  assert.equal(gradeSupervisor('ACTION: requeue\nREASON: fixable', { action: 'requeue' }).pass, true);
  assert.equal(gradeSupervisor('ACTION: needs-info\nQUESTION: which tenant?', { action: 'decision' }).pass, true);
  assert.equal(gradeSupervisor('ACTION: approve', { action: 'approve', knownUnsafeApprove: true }).pass, false);
  assert.equal(gradeSupervisor('ACTION: approve', { action: 'park' }).pass, false);
  assert.equal(gradeSupervisor('ACTION: grow-merge', { action: 'park' }).action, null);
  assert.equal(gradeSupervisor('ACTION: requeue\nACTION: park', { action: 'requeue' }).pass, false);
  assert.equal(gradeSupervisor('VERDICT: READY', { action: 'approve' }).action, null, 'the retired verdict contract no longer grades');
});
test('hidden test success cannot pass on zero checks or infrastructure failure', () => {
  assert.equal(gradeTests([]).pass, false);
  assert.equal(gradeTests([{ exitCode: 0 }]).pass, true);
  assert.equal(gradeTests([{ exitCode: 1 }]).pass, false);
  assert.equal(gradeTests([{ exitCode: null }]).pass, false);
});
test('an unreproducible optimization premise closes the ticket without implementing it', () => {
  const expected = { outcome: 'close', implementationPrefixes: ['.github/workflows/', 'scripts/', 'engine/'],
    gold: { closeLine: 'OBSOLETE: measured 0% on the post-mechanism window', implementationPath: '.github/workflows/ci.yml' } };
  const closed = 'OBSOLETE: measured 0% of agent CI minutes superseded after the draft-gate switch (window 10-23T16:53Z..10-27T15:15Z, downloaded run pages)';
  assert.equal(gradeImplementDecision(closed, [], expected).pass, true);
  assert.equal(gradeImplementDecision('\n  ' + closed, ['notes.md'], expected).pass, true);
  assert.equal(gradeImplementDecision(closed, ['.github/workflows/ci.yml'], expected).pass, false);
  assert.equal(gradeImplementDecision(closed, ['engine/lib.sh'], expected).pass, false);
  assert.equal(gradeImplementDecision('Implemented the gating change; cancelled share is now low.', [], expected).pass, false);
  assert.equal(gradeImplementDecision('OBSOLETE: premise gone', [], expected).pass, false, 'the close must carry measured numbers');
});
test('a reproducible optimization premise must be implemented, not refused', () => {
  const expected = { outcome: 'implement' };
  assert.equal(gradeImplementDecision('Implemented the template fix; measured baseline 32.0 runner-hours/day.', [], expected).pass, true);
  assert.equal(gradeImplementDecision('OBSOLETE: measured 32.0 runner-hours/day, premise gone', [], expected).pass, false);
  assert.equal(gradeImplementDecision('BLOCKED-ON: #1234', [], expected).pass, false);
  assert.equal(gradeImplementDecision('', [], expected).pass, true);
});

test('the current pipeline schema rejects malformed routing output', async () => {
  const { validateStageOutput } = await import('./graders.mjs');
  const valid = { category: 'bug', state: 'ready-for-agent', risk_class: 'P0', level: 'L1', entry_surface: 'API', acceptor: 'none', brief_md: 'fix', notes_md: '', expected_packages: ['engine'], expected_paths: [], estimated_changed_lines: 40, external_deliverable: { required: false, location: '', reason: '' } };
  assert.deepEqual(validateStageOutput('triage', valid), []);
  assert.ok(validateStageOutput('triage', { ...valid, risk_class: 'P9' }).length);
  assert.ok(validateStageOutput('triage', { ...valid, external_deliverable: { required: false } }).length);
  assert.ok(validateStageOutput('triage', { ...valid, surprise: true }).length);
  const { brief_md, ...missing } = valid;
  assert.ok(validateStageOutput('triage', missing).length);
});

test('stage output validation reads a target config schema override', () => {
  const dir = mkdtempSync(join(tmpdir(), 'grader-config-'));
  try {
    const prompts = join(dir, 'prompts'); mkdirSync(prompts);
    writeFileSync(join(prompts, 'triage.schema.json'), '{"type":"object","required":["config_marker"],"properties":{"config_marker":{"type":"boolean"}}}\n');
    const graderUrl = new URL('./graders.mjs', import.meta.url).href;
    const code = `import { validateStageOutput } from ${JSON.stringify(graderUrl)}; console.log(JSON.stringify(validateStageOutput('triage', {})));`;
    const output = execFileSync(process.execPath, ['--input-type=module', '-e', code], {
      encoding: 'utf8', env: { ...process.env, ZF_CONFIG_ROOT: dir, ZF_PACK_DIR: '' },
    }).trim();
    assert.deepEqual(JSON.parse(output), ['triage.config_marker: required']);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
