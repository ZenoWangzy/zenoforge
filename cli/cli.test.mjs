// End-to-end tests of the subcommands against a throwaway HOME, a local bare repo as "GitHub", and fake gh/systemctl.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import * as cmd from './commands.mjs';
import { run, which } from './util.mjs';

const FAKE_GH = `#!/usr/bin/env bash
echo "gh $*" >> "$ZF_FAKE_LOG"
case "$1 $2" in
  "auth status") echo "github.com"; echo "  ✓ Logged in to github.com account octo (keyring)"; echo "  - Token scopes: 'repo'" ;;
  "auth token") echo "ghp_FAKESECRETVALUE" ;;
  "repo view") echo '{"defaultBranchRef":{"name":"main"},"viewerPermission":"ADMIN"}' ;;
  "repo clone") git clone -q "$ZF_FAKE_ORIGIN" "$4" && git -C "$4" remote set-url origin "https://github.com/$3.git" ;;
  "label list") echo needs-triage ;;
  "variable get") echo triage ;;
  *) case "$1" in api) echo '{"contexts":["ci / test"],"checks":[]}' ;; esac ;;
esac
`;
const FAKE_SYSTEMCTL = '#!/usr/bin/env bash\necho "systemctl $*" >> "$ZF_FAKE_LOG"\n';

function sandbox({ originFiles = { 'README.md': 'hello\n' } } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zf-cli-'));
  const home = path.join(root, 'home');
  const bin = path.join(root, 'bin');
  const origin = path.join(root, 'origin.git');
  const seed = path.join(root, 'seed');
  fs.mkdirSync(home); fs.mkdirSync(bin);
  const git = (cwd, ...a) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@e', ...a], { cwd, stdio: 'pipe' });
  git(root, 'init', '-q', '--bare', '-b', 'main', origin);
  git(root, 'clone', '-q', origin, seed);
  for (const [f, body] of Object.entries(originFiles)) {
    fs.mkdirSync(path.dirname(path.join(seed, f)), { recursive: true });
    fs.writeFileSync(path.join(seed, f), body);
  }
  git(seed, 'add', '-A'); git(seed, 'commit', '-q', '-m', 'seed'); git(seed, 'push', '-q', 'origin', 'HEAD:main');
  for (const [name, body] of Object.entries({ gh: FAKE_GH, systemctl: FAKE_SYSTEMCTL, codex: '#!/bin/sh\n', claude: '#!/bin/sh\n' })) {
    fs.writeFileSync(path.join(bin, name), body, { mode: 0o755 });
  }
  const log = path.join(root, 'calls.log');
  fs.writeFileSync(log, '');
  const unitDir = path.join(home, '.config/systemd/user');
  const env = {
    ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}`, ZF_FAKE_LOG: log, ZF_FAKE_ORIGIN: origin,
    SYSTEMD_USER_UNIT_DIR: unitDir, GH_TOKEN: '', GITHUB_TOKEN: '', XDG_CONFIG_HOME: path.join(home, '.config'),
  };
  delete env.AGENT_HOME; delete env.ZF_HOME; delete env.ZF_REPO_DIR; delete env.MAC_AUTOPILOT_ROOT;
  const runner = (c, a, o = {}) => run(c, a, { env, ...o });
  const lines = [];
  const io = {
    log: (...a) => lines.push(a.join(' ')), home, cwd: home, env, platform: 'linux', interactive: false,
    find: (n) => which(n, env.PATH), exec: runner, runner, scheduler: 'systemd',
  };
  const calls = () => fs.readFileSync(log, 'utf8');
  return { root, home, io, lines, calls, unitDir, agent: path.join(home, '.zenoforge'), checkout: path.join(home, '.zenoforge/checkout'), env };
}

const REPO = 'example-maintainer/example-repo';
const mode = (p) => fs.statSync(p).mode & 0o777;

test('init refuses to proceed without --yes when there is no terminal, and writes nothing', async () => {
  const s = sandbox();
  await assert.rejects(cmd.init({ repo: REPO }, s.io), /--yes/);
  assert.equal(fs.existsSync(s.agent), false);
  assert.doesNotMatch(s.calls(), /label create|variable set|repo clone/);
});

test('init: files, modes, checkout, engine link, labels, variables and units', async () => {
  const s = sandbox();
  await cmd.init({ repo: REPO, yes: true }, s.io);

  for (const f of ['env', 'capacity.env', 'recipients.json', 'cli.json']) assert.equal(mode(path.join(s.agent, f)), 0o600, f);
  const env = fs.readFileSync(path.join(s.agent, 'env'), 'utf8');
  assert.match(env, new RegExp(`^ZF_REPO=${REPO}$`, 'm'));
  assert.match(env, /^GH_TOKEN=ghp_FAKESECRETVALUE$/m);
  assert.doesNotMatch(s.lines.join('\n') + s.calls(), /FAKESECRETVALUE/, 'token never printed or passed on a command line');
  assert.match(fs.readFileSync(path.join(s.agent, 'capacity.env'), 'utf8'), /^AGENT_GLOBAL_EXECUTION_CAP=2$/m);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(s.agent, 'recipients.json'), 'utf8')).recipients, {});

  // dedicated checkout: engine reachable through the link, invisible to git, survives git clean
  assert.equal(fs.readlinkSync(path.join(s.agent, 'engine/current')), '0.1.0');
  assert.ok(fs.existsSync(path.join(s.checkout, 'engine/run-tick.sh')));
  assert.equal(execFileSync('git', ['-C', s.checkout, 'status', '--porcelain']).toString(), '');
  execFileSync('git', ['-C', s.checkout, 'clean', '-fdq']);
  assert.ok(fs.lstatSync(path.join(s.checkout, 'engine')).isSymbolicLink());

  // rendered config: required checks read from branch protection, so auto merge is on
  const cfg = JSON.parse(fs.readFileSync(path.join(s.agent, 'engine/current/mac-autopilot/config.template.json'), 'utf8'));
  assert.equal(cfg.auto_merge, true);
  assert.equal(cfg.max_workers, 2);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(s.agent, 'engine/current/mac-autopilot/required-pr-checks.json'), 'utf8')).required, ['ci / test']);

  // GitHub side: only missing labels created, safe variables
  const calls = s.calls();
  assert.match(calls, /label create ready-for-agent --repo example-maintainer\/example-repo/);
  assert.doesNotMatch(calls, /label create needs-triage /);
  assert.match(calls, /variable set AGENT_SUPERVISOR --repo \S+ --body observe/);
  assert.match(calls, /variable set AGENT_PIPELINE --repo \S+ --body triage/);

  // scheduler: units copied, timers from the rendered list plus both loops enabled, health mail not enabled
  const agentUnit = fs.readFileSync(path.join(s.unitDir, 'zenoforge-agent.service'), 'utf8');
  assert.match(agentUnit, /^ExecStart=%h\/\.zenoforge\/checkout\/engine\/run-tick\.sh$/m);
  assert.ok(fs.existsSync(path.join(s.unitDir, 'zenoforge-autopilot-scheduler.service')));
  const enable = calls.split('\n').find((l) => l.startsWith('systemctl --user enable'));
  assert.match(enable, /zenoforge-agent\.timer/);
  assert.match(enable, /zenoforge-autopilot-bell\.service/);
  assert.doesNotMatch(enable, /health-mail|local-rescue|disk-reclaim|prod-anomaly/);
  // run-tick copies engine/systemd/*.service on every tick; the copy must already match what we installed
  for (const f of fs.readdirSync(path.join(s.agent, 'engine/current/systemd')).filter((x) => x.endsWith('.service'))) {
    assert.equal(fs.readFileSync(path.join(s.unitDir, f), 'utf8'), fs.readFileSync(path.join(s.agent, 'engine/current/systemd', f), 'utf8'), f);
  }
});

test('the real engine scripts work through the checkout link (write guard, runtime sync, config)', async () => {
  const s = sandbox();
  await cmd.init({ repo: REPO, yes: true, noScheduler: true }, s.io);
  const sh = (script) => execFileSync('bash', ['-c', script], { env: { ...s.env, ZF_REPO_DIR: s.checkout, MAC_AUTOPILOT_ROOT: s.checkout }, stdio: 'pipe' }).toString();
  assert.match(sh(`source "${s.checkout}/engine/lib.sh" && echo "repo=$REPO"`), /repo=example-maintainer\/example-repo/);
  sh(`bash "${s.checkout}/engine/mac-autopilot/start.sh" --sync-only`);
  const live = path.join(s.checkout, '.scratch-supervisor/autopi-live');
  assert.equal(fs.readlinkSync(live), 'autopi-versions/0.1.0/engine/mac-autopilot');
  assert.ok(fs.existsSync(path.join(live, 'loop.sh')));
  const runtime = JSON.parse(fs.readFileSync(path.join(s.checkout, '.scratch-supervisor/autopi/config.json'), 'utf8'));
  assert.equal(runtime.max_workers, 2);
  assert.equal(runtime.release_train.enabled, false);
  assert.equal(execFileSync('git', ['-C', s.checkout, 'status', '--porcelain']).toString(), '', 'runtime state ignored by git');
});

test('init twice is idempotent and keeps user-owned files; another repo is refused', async () => {
  const s = sandbox();
  await cmd.init({ repo: REPO, yes: true, noScheduler: true }, s.io);
  fs.appendFileSync(path.join(s.agent, 'recipients.json'), '\n');
  const before = fs.readFileSync(path.join(s.agent, 'recipients.json'), 'utf8');
  await cmd.init({ repo: REPO, yes: true, noScheduler: true }, s.io);
  assert.equal(fs.readFileSync(path.join(s.agent, 'recipients.json'), 'utf8'), before);
  assert.deepEqual(fs.readdirSync(path.join(s.agent, 'engine')).sort(), ['0.1.0', 'current']);
  await assert.rejects(cmd.init({ repo: 'other/thing', yes: true, noScheduler: true }, s.io), /already set up for example-maintainer\/example-repo/);
});

test('checkout guards: foreign directory and a repository that tracks its own engine/', async () => {
  const s = sandbox();
  fs.mkdirSync(s.checkout, { recursive: true });
  fs.writeFileSync(path.join(s.checkout, 'my-work.txt'), 'precious\n');
  await assert.rejects(cmd.init({ repo: REPO, yes: true, noScheduler: true }, s.io), /not created by zenoforge/);
  assert.equal(fs.readFileSync(path.join(s.checkout, 'my-work.txt'), 'utf8'), 'precious\n');

  const t = sandbox({ originFiles: { 'engine/main.c': 'int main(){}\n' } });
  await assert.rejects(cmd.init({ repo: REPO, yes: true, noScheduler: true }, t.io), /tracks its own top-level engine\//);
});

test('start/stop/status/upgrade/rollback/uninstall drive systemctl and keep state', async () => {
  const s = sandbox();
  await cmd.init({ repo: REPO, yes: true }, s.io);
  fs.writeFileSync(path.join(s.root, 'calls.log'), ''); // reset the call log
  cmd.stop({}, s.io);
  assert.match(s.calls(), /systemctl --user disable --now zenoforge-agent\.timer/);
  cmd.start({}, s.io);
  assert.match(s.calls(), /systemctl --user enable --now zenoforge-agent\.timer/);
  s.lines.length = 0;
  cmd.status({}, s.io);
  assert.match(s.lines.join('\n'), /repository\s+example-maintainer\/example-repo/);
  assert.match(s.lines.join('\n'), /AGENT_PIPELINE\s+triage/);
  s.lines.length = 0;
  cmd.upgrade({}, s.io);
  assert.match(s.lines.join('\n'), /already current/);
  assert.throws(() => cmd.rollback({}, s.io), /No previous engine version/);

  cmd.uninstall({}, s.io);
  assert.equal(fs.existsSync(path.join(s.unitDir, 'zenoforge-agent.service')), false);
  assert.equal(fs.existsSync(path.join(s.checkout, 'engine')), false);
  assert.ok(fs.existsSync(path.join(s.agent, 'env')), 'state kept without --purge');
  assert.equal(fs.existsSync(path.join(s.agent, 'cli.json')), false);
  assert.throws(() => cmd.status({}, s.io), /zenoforge init/);
});

test('purge needs --yes and only deletes a checkout zenoforge created', async () => {
  const s = sandbox();
  await cmd.init({ repo: REPO, yes: true, noScheduler: true }, s.io);
  assert.throws(() => cmd.uninstall({ purge: true }, s.io), /--yes/);
  assert.ok(fs.existsSync(s.agent));
  cmd.uninstall({ purge: true, yes: true }, s.io);
  assert.equal(fs.existsSync(s.agent), false);
});

test('dry run prints the plan, never prints the token, and changes nothing', async () => {
  const s = sandbox();
  await cmd.init({ repo: REPO, dryRun: true }, s.io);
  assert.deepEqual(fs.readdirSync(s.home), [], 'home is untouched');
  const out = s.lines.join('\n');
  assert.match(out, /\[dry-run\] WRITE .*\/env \(mode 600/);
  assert.match(out, /\[dry-run\] RUN gh repo clone/);
  assert.match(out, /\[dry-run\] RUN systemctl --user enable --now/);
  assert.match(out, /copy the gh token into the env file \(value hidden\)/);
  assert.doesNotMatch(out + s.calls(), /FAKESECRETVALUE/);
  assert.doesNotMatch(s.calls(), /label create|variable set|repo clone|systemctl --user (enable|disable|daemon-reload)/);
});

test('a host without a usable gh fails the real run cleanly and still produces a dry-run plan', async () => {
  const s = sandbox();
  fs.writeFileSync(path.join(s.root, 'bin/gh'), '#!/bin/sh\necho "You are not logged into any GitHub hosts." >&2\nexit 1\n', { mode: 0o755 });
  await assert.rejects(cmd.init({ repo: REPO, yes: true }, s.io), /Fix the FAIL items/);
  assert.equal(fs.existsSync(s.agent), false);
  s.lines.length = 0;
  const r = await cmd.init({ repo: REPO, dryRun: true, noScheduler: true }, s.io);
  assert.equal(r.doctorFailures, 1);
  assert.match(s.lines.join('\n'), /FAIL  gh authenticated/);
  assert.match(s.lines.join('\n'), /would stop before changing anything/);
});

test('re-running init with a changed setting installs a new engine version and restarts the loops', async () => {
  const s = sandbox();
  await cmd.init({ repo: REPO, yes: true }, s.io);
  fs.writeFileSync(path.join(s.root, 'calls.log'), '');
  await cmd.init({ repo: REPO, yes: true, maxWorkers: '4' }, s.io);
  assert.equal(fs.readlinkSync(path.join(s.agent, 'engine/current')), '0.1.0+2');
  assert.equal(fs.readlinkSync(path.join(s.agent, 'engine/previous')), '0.1.0');
  assert.equal(JSON.parse(fs.readFileSync(path.join(s.agent, 'engine/current/mac-autopilot/config.template.json'), 'utf8')).max_workers, 4);
  assert.match(s.calls(), /systemctl --user restart zenoforge-autopilot-scheduler\.service zenoforge-autopilot-bell\.service/);
  assert.match(fs.readFileSync(path.join(s.agent, 'capacity.env'), 'utf8'), /^AGENT_GLOBAL_EXECUTION_CAP=4$/m);
  // a third run without flags keeps the earlier choice and installs nothing new
  await cmd.init({ repo: REPO, yes: true }, s.io);
  assert.equal(fs.readlinkSync(path.join(s.agent, 'engine/current')), '0.1.0+2');
  assert.deepEqual(fs.readdirSync(path.join(s.agent, 'engine')).sort(), ['0.1.0', '0.1.0+2', 'current', 'previous']);
});
