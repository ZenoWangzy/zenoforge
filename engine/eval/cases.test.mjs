import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { execute, loadEvalCaseSet } from './run-eval.mjs';

test('stage calls keep pipeline writes inside their isolated artifact directory', () => {
  const repo = resolve('.');
  const scratch = join(repo, '.tmp');
  mkdirSync(scratch, { recursive: true });
  const dir = mkdtempSync(join(scratch, 'eval-stage-guard-'));
  try {
    const baseSha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).trim();
    const stageCall = join(dir, 'stage-call.sh');
    writeFileSync(stageCall, `#!/usr/bin/env bash
set -euo pipefail
if [[ "${'${ZF_AGENT_TEST_MODE:-}'}" != 1 || "${'${ZF_AGENT_TEST_ROOT:-}'}" != "$(dirname "$5")" ]]; then
  printf '%s\\n' 'missing isolated stage guard environment' >&2
  exit 91
fi
printf '%s\\n' 'codex:fixture:high' > "$5/identity.txt"
printf '%s\\n' 'implemented'
`);
    const row = execute({ id: 'fixture', base_sha: baseSha, prompt: 'fixture', hidden_check: 'true', expected_divergence: 'fixture' },
      'fresh-agent', join(dir, 'out'), 'unused-policy', { sourceRepo: repo, stageCall });
    assert.equal(row.pass, true, JSON.stringify(row));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('stage call seeds the isolated eval state fixture from its input', () => {
  const repo = resolve('.');
  const scratch = join(repo, '.tmp');
  mkdirSync(scratch, { recursive: true });
  const dir = mkdtempSync(join(scratch, 'eval-state-seed-'));
  try {
    const home = join(dir, 'home'), artifact = join(dir, 'artifact');
    mkdirSync(home, { recursive: true });
    const input = join(dir, 'input.json'), prompt = join(dir, 'prompt.md');
    const fixture = { issue: { number: 77 }, priorState: { state: 'ready-for-agent', source: 'fixture' }, failure: 'seed failure' };
    writeFileSync(input, JSON.stringify(fixture));
    writeFileSync(prompt, 'fixture');
    execFileSync('bash', [join(repo, 'engine/eval/stage-call.sh'), 'fixture', repo, repo, prompt, artifact, input], {
      env: { ...process.env, HOME: home, AGENT_HOME: join(dir, 'host-agent'), GH_TOKEN: '', GITHUB_TOKEN: '',
        EVAL_POLICY_FILE: join(repo, 'engine/model-policy.default.json'), ZF_REPO_DIR: repo,
        ZF_AGENT_TEST_MODE: '1', ZF_AGENT_TEST_ROOT: dir, AGENT_EXECUTION_MIN_MEM_MB: '1', AGENT_EXECUTION_MAX_LOAD: '1000000' },
      encoding: 'utf8',
    });
    const stateDir = join(artifact, 'agent-home', 'state');
    assert.deepEqual(JSON.parse(readFileSync(join(stateDir, '77.json'), 'utf8')),
      { ...fixture.priorState, last_failure_reason: fixture.failure, last_failure_tail: fixture.failure });
    assert.deepEqual(readdirSync(stateDir), ['77.json']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('paired repair case set uses frozen, hidden-check task inputs', () => {
  const set = loadEvalCaseSet('end-to-end');
  assert.ok(set);
  assert.equal(set.stage, 'end-to-end');
  assert.deepEqual(set.cases.map((item) => item.id), [
    'zf-1049-lesson-enforcers',
    'zf-1050-merge-boundary',
    'zf-1051-shortcut-ratchet',
    'zf-1037-eval-plugins-off',
    'zf-1047-review-verification',
  ]);
  for (const item of set.cases) {
    assert.match(item.baseSha, /^[a-f0-9]{40}$/);
    assert.match(item.hidden.ref, /^[a-f0-9]{40}$/);
    assert.equal(item.source.fixSha, item.hidden.ref);
    assert.match(item.sourceUrl, /^https:\/\/github\.com\/ZenoWangzy\/zenoforge\/issues\/\d+$/);
    assert.equal(item.priorState.state, 'ready-for-agent');
    assert.ok(item.hidden.files.length > 0);
    assert.ok(item.hidden.commands.length > 0);
  }
});
