import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

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
