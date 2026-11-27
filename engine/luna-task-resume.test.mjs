import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { writeTransitionRecords } from './task-state.mjs';

const engine = fileURLToPath(new URL('.', import.meta.url));
const root = mkdtempSync(join(tmpdir(), 'luna-task-resume-'));
const home = join(root, 'home');
const agentHome = join(root, 'agent');
const bin = join(root, 'bin');
const capture = join(root, 'capture');
const scratch = join(root, 'scratch');
const worktree = join(root, 'worktree');
const prompt = join(root, 'prompt.md');
const meminfo = join(root, 'meminfo');
const pressure = join(root, 'pressure');
mkdirSync(home, { recursive: true });
mkdirSync(agentHome, { recursive: true });
mkdirSync(bin, { recursive: true });
mkdirSync(capture, { recursive: true });
mkdirSync(worktree, { recursive: true });
writeFileSync(meminfo, 'MemAvailable: 6144000 kB\n');
writeFileSync(pressure, 'some avg10=0 avg60=0 avg300=0 total=0\nfull avg10=0 avg60=0 avg300=0 total=0\n');
writeFileSync(prompt, 'Continue the stored task.\n');

const stub = (name, source) => {
  const path = join(bin, name);
  writeFileSync(path, `#!/usr/bin/env bash\n${source}\n`);
  chmodSync(path, 0o755);
};

stub('systemd-run', 'while (($#)); do [[ "$1" == -- ]] && { shift; exec "$@"; }; shift; done; exit 90');
stub('systemctl', 'exit 0');
stub('pgrep', 'exit 1');
stub('sleep', 'exit 0');
stub('codex', 'set -euo pipefail\ncat > "$TASK_RESUME_CAPTURE_DIR/$LUNA_INVOCATION"\n[[ "$LUNA_INVOCATION" != killed ]] || kill -KILL "$$"');

const env = {
  ...process.env,
  HOME: home,
  AGENT_HOME: agentHome,
  ZF_HOME: agentHome,
  ZF_ENGINE_DIR: engine,
  ZF_WORKER_HOST: 'local',
  WORKER_SCRATCH_ROOT: scratch,
  LUNA_SLOTS: join(root, 'slots'),
  LUNA_WORKER_SLICE_DIR: join(root, 'no-slice'),
  LUNA_PROC_MEMINFO: meminfo,
  LUNA_PROC_PSI_MEMORY: pressure,
  LUNA_MIN: '1',
  LUNA_MAX: '10',
  LUNA_AGE_ADMIT_SECONDS: '0',
  LUNA_ADMIT_AVAIL_MB: '1',
  LUNA_CPU_TARGET: '101',
  CODEX_HOME: join(home, '.codex'),
  TASK_RESUME_CAPTURE_DIR: capture,
  TMPDIR: root,
  ZF_AGENT_TEST_MODE: '1',
  ZF_AGENT_TEST_ROOT: root,
  PATH: `${bin}:${process.env.PATH}`,
};

test.after(() => rmSync(root, { recursive: true, force: true }));

test('a fresh luna session recovers task state after the previous session is killed', () => {
  const nextStep = 'run parser acceptance from the saved worktree';
  writeTransitionRecords(join(agentHome, 'task-state'), {
    task: {
      record_type: 'task', id: 'task-596', goal: 'recover parser', done_when: 'parser acceptance passes',
      owner: 'worker-2', stage: 'implement', blocker: 'none', next_step: nextStep,
    },
    events: [
      { record_type: 'handoff', id: 'task-596', from: 'worker-1', to: 'worker-2', reason: 'session restart', next_step: nextStep },
      { record_type: 'decision', id: 'task-596', decision: 'continue', by: 'supervisor', why: 'session died during implementation' },
    ],
  });
  const startingPrompt = readFileSync(prompt, 'utf8');
  for (const value of ['task-596', 'recover parser', 'implement', 'worker-2', 'none', nextStep, 'session restart', 'continue']) {
    assert.equal(startingPrompt.includes(value), false, `initial prompt contains stored value ${value}`);
  }

  const first = spawnSync('bash', [join(engine, 'bin/luna'), 'dead-session', worktree, prompt], {
    encoding: 'utf8', env: { ...env, LUNA_INVOCATION: 'killed' }, timeout: 10000,
  });
  assert.equal(first.status, 137, first.stderr);
  assert.ok(existsSync(join(capture, 'killed')));
  assert.equal(readFileSync(prompt, 'utf8').includes(nextStep), false);

  const second = spawnSync('bash', [join(engine, 'bin/luna'), 'fresh-session', worktree, prompt], {
    encoding: 'utf8', env: { ...env, LUNA_INVOCATION: 'fresh' }, timeout: 10000,
  });
  assert.equal(second.status, 0, second.stderr);
  const output = readFileSync(join(capture, 'fresh'), 'utf8');
  assert.match(output, /Active task: task-596/);
  assert.match(output, /  goal: recover parser/);
  assert.match(output, /  done-when: parser acceptance passes/);
  assert.match(output, /  owner: worker-2/);
  assert.match(output, /  stage: implement/);
  assert.match(output, /  blocker: none/);
  assert.match(output, new RegExp(`  next step: ${nextStep}`));
  assert.match(output, /latest handoff: from=worker-1; to=worker-2; reason=session restart/);
  assert.match(output, /latest decision: decision=continue; by=supervisor; why=session died during implementation/);
});
