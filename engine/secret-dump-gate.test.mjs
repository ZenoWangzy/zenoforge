import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const hook = 'engine/secret-dump-gate.py';
function run(command, tool = 'Bash', extra = {}) {
  return spawnSync('python3', [hook], { encoding: 'utf8', input: JSON.stringify({
    tool_name: tool, tool_input: { command, ...extra },
  }) });
}

test('observed diagnostic leaks and shell/ssh variants are refused before execution', () => {
  const commands = [
    'systemctl show proxy.service -p ExecStart',
    'systemctl --user show proxy.service --property=Environment',
    'systemctl show proxy.service',
    'systemctl cat proxy.service',
    'ssh cihost "systemctl show proxy.service -p ExecStart"',
    'sed -n "1,80p" ~/.bashrc', 'head -80 ~/.bashrc',
    'cat ~/.zshrc', 'tail ~/.profile', 'cat /etc/profile',
    'cat .env', 'cat .env.production', 'cat credentials.env',
    'cat < .env', 'grep TOKEN /home/fake/.zenoforge/env',
    'bash -lc "cat ~/.bashrc"', 'rtk cat ~/.bashrc',
    'ssh cihost "cat /srv/app/agent-runtime.json"',
    'cat /srv/app/migration-compose.config.yml',
    'cat /srv/app/config.yaml | head -20',
    'jq . /srv/app/config.json',
    'jq "., .token | length" /srv/app/config.json',
    'jq ".services[]" /srv/app/config.json',
    'yq . /srv/app/config.yaml',
    'jq ".headers" /srv/app/config.json',
    'jq -r ".headers[\"x-service-token\"]" /srv/app/config.json',
    'docker inspect gateway', 'docker inspect --format "{{json .}}" gateway',
    'docker inspect -f "{{.Config.Env}}" gateway',
    'docker --context prod inspect gateway',
    'docker exec gateway env', 'docker exec -u root gateway printenv',
    'docker exec gateway printenv SERVICE_TOKEN',
    'docker exec gateway sh -c "env | sort"',
    'ssh cihost \'docker exec gateway env\'',
    'python3 -c \'import json; data=json.load(open("/srv/app/config.json")); print(json.dumps(data))\'',
  ];
  for (const command of commands) {
    const result = run(command);
    assert.equal(result.status, 2, command);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /redacted-config-reader\.sh/);
  }
});

test('source reads and targeted non-secret diagnostics still pass', () => {
  for (const command of [
    'cat packages/api/src/config.ts', 'head -80 CLAUDE.md',
    'sed -n "1,80p" engine/dispatch-codex.sh',
    'cat package.json', 'rg token packages/api/src',
    'jq .version package.json', 'jq ".host" /srv/app/config.json',
    'jq ".services.gateway.image" /srv/app/config.json',
    'jq ".headers[\"x-service-token\"] | length" /srv/app/config.json',
    'systemctl show proxy.service -p ActiveState -p SubState',
    'systemctl --user show proxy.service --property=MainPID,ActiveState',
    'docker inspect --format "{{.State.Running}}" gateway',
    'docker inspect -f "{{.Config.Image}}" gateway',
    'docker exec gateway node --version',
    'ssh cihost \'jq ".host" /srv/app/config.json\'',
    'bash scripts/ops/redacted-config-reader.sh presence --source file --path .env --key TOKEN',
    'bash scripts/ops/redacted-config-reader.sh presence --source container --container gateway --key TOKEN',
    'printf "%s" "cat ~/.bashrc"',
  ]) assert.equal(run(command).status, 0, command);
});

test('arbitrary local JSON/YAML with token keys is protected; fake values never escape', () => {
  const dir = mkdtempSync(join(tmpdir(), 'secret-dump-gate-'));
  const fake = 'FAKE_ONLY_DO_NOT_ECHO_5291';
  try {
    writeFileSync(join(dir, 'settings.json'), JSON.stringify({ headers: { 'x-internal-token': fake }, host: 'localhost' }));
    writeFileSync(join(dir, 'settings.yaml'), `x-service-token: ${fake}\n`);
    for (const file of ['settings.json', 'settings.yaml']) {
      const result = run(`cat ${file}`, 'Bash', { workdir: dir });
      assert.equal(result.status, 2);
      assert.ok(!`${result.stdout}${result.stderr}`.includes(fake));
    }
    assert.equal(run('jq .host settings.json', 'Bash', { workdir: dir }).status, 0);
    const marker = join(dir, 'ran');
    const command = `touch ${marker}; cat ${join(dir, 'settings.json')}`;
    const gate = run(command);
    if (gate.status === 0) spawnSync('bash', ['-c', command]);
    assert.equal(gate.status, 2);
    assert.equal(existsSync(marker), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('Codex hook wiring and input contracts', () => {
  assert.equal(run('cat .env', 'exec_command').status, 2);
  assert.equal(run(undefined, 'exec_command', { cmd: 'cat .env' }).status, 2);
  assert.equal(run('cat .env', 'Read').status, 0);
  const bad = spawnSync('python3', [hook], { encoding: 'utf8', input: 'not json' });
  assert.equal(bad.status, 2);
});
