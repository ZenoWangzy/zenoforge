import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  buildPath, EXTRA_LABELS, labelsFromLib, parseDuration, parseUnit, renderCapacityEnv, renderConfigTemplate, renderEnvFile,
  renderLoopServices, renderPlist, renderRecipients, renderRequiredChecks, renderService, renderTimerList, tilde, timersFromList, unitValues,
} from './render.mjs';

const engine = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'engine');
const read = (rel) => fs.readFileSync(path.join(engine, rel), 'utf8');
const home = '/home/alice';
const pathValue = '%h/.local/bin:/usr/bin';

test('env file: repo, worktree root, token only when given', () => {
  const plain = renderEnvFile({ repo: 'o/r', worktreeRoot: '/h/.zenoforge/wt' });
  assert.match(plain, /^ZF_REPO=o\/r$/m);
  assert.match(plain, /^ZF_GH_REPO=o\/r$/m);
  assert.match(plain, /^ZF_WORKTREE_ROOT=\/h\/\.zenoforge\/wt$/m);
  assert.doesNotMatch(plain, /^GH_TOKEN=/m);
  assert.match(renderEnvFile({ repo: 'o/r', worktreeRoot: '/w', ghToken: 'tok' }), /^GH_TOKEN=tok$/m);
});

test('capacity env and recipients stay safe by default', () => {
  assert.equal(renderCapacityEnv({ maxWorkers: 3 }), '# Written by `zenoforge init`. Capacity gate read by engine/lib.sh. Bad values make the gate defer.\nAGENT_GLOBAL_EXECUTION_CAP=3\n');
  assert.match(renderCapacityEnv({ maxWorkers: 3, workerBackend: 'zc' }), /^WORKER_BACKEND=zc$/m);
  assert.deepEqual(JSON.parse(renderRecipients()), { maintainer_login: '', recipients: {} });
});

test('config template: caps, kill switches for unshipped parts, review provider', () => {
  const tpl = read('mac-autopilot/config.template.json');
  const base = { maxWorkers: 2, dailyTokenBudget: 1000, autoMerge: false };
  const claude = JSON.parse(renderConfigTemplate(tpl, { ...base, reviewProvider: 'claude' }));
  assert.equal(claude.max_workers, 2);
  assert.equal(claude.implement_cap, 2);
  assert.equal(claude.daily_token_budget, 1000);
  assert.equal(claude.auto_merge, false);
  assert.equal(claude.release_train.enabled, false);
  assert.equal(claude.supervisor_arbiter.enabled, false);
  assert.match(claude.models.review[0], /^claude-/);
  const codex = JSON.parse(renderConfigTemplate(tpl, { ...base, reviewProvider: 'codex', autoMerge: true }));
  assert.deepEqual(codex.models.review, codex.models.implement);
  assert.equal(codex.auto_merge, true);
  assert.equal(JSON.parse(renderConfigTemplate(tpl, { ...base, maxWorkers: 16, reviewProvider: 'claude' })).implement_cap, 8, 'cap never raised above the template');
});

test('required checks replace the originating project names', () => {
  const out = JSON.parse(renderRequiredChecks(read('mac-autopilot/required-pr-checks.json'), ['ci / test']));
  assert.deepEqual(out.required, ['ci / test']);
  assert.equal(out.min_gh_version, '2.50.0');
});

test('label set is read from the engine and covers the extra labels', () => {
  const labels = labelsFromLib(read('lib.sh'));
  for (const l of ['needs-triage', 'ready-for-agent', 'needs-info', 'ready-for-human', 'concluded', ...EXTRA_LABELS]) assert.ok(labels.includes(l), l);
  assert.equal(new Set(labels).size, labels.length);
  assert.throws(() => labelsFromLib('nothing here'), /ALL_STATE_LABELS/);
});

test('tilde maps the home prefix to %h only on a path boundary', () => {
  assert.equal(tilde('/home/alice/.zenoforge/checkout', home), '%h/.zenoforge/checkout');
  assert.equal(tilde('/home/alice', home), '%h');
  assert.equal(tilde('/home/alice2/x', home), '/home/alice2/x');
  assert.equal(tilde('/srv/zf', home), '/srv/zf');
});

test('service unit: paths, PATH, env file, no inherited proxy', () => {
  const shipped = read('systemd/zenoforge-health-maintenance.service');
  assert.match(shipped, /http_proxy=/);
  const inHome = renderService(shipped, { home, checkout: '/home/alice/.zenoforge/checkout', pathValue });
  assert.doesNotMatch(inHome, /proxy/i);
  assert.match(inHome, /^Environment=PATH=%h\/\.local\/bin:\/usr\/bin$/m);
  assert.ok(inHome.includes('exec "${e:-%h/.zenoforge/checkout/engine}/night/health-maintenance.sh" maintenance'));
  assert.match(inHome, /^Environment=ZF_WORKTREE_ROOT=%h\/\.zenoforge\/wt$/m);
  assert.equal(inHome.match(/^EnvironmentFile=/gm).length, 1);
  const elsewhere = renderService(shipped, { home, checkout: '/srv/zf/co', pathValue });
  assert.match(elsewhere, /^WorkingDirectory=\/srv\/zf\/co$/m);
  assert.ok(elsewhere.includes('exec "${e:-/srv/zf/co/engine}/night/health-maintenance.sh" maintenance'));
  assert.doesNotMatch(elsewhere, /\.zenoforge\/checkout/);
});

test('agent unit keeps its single EnvironmentFile after the commented example is dropped', () => {
  const out = renderService(read('systemd/zenoforge-agent.service'), { home, checkout: '/home/alice/.zenoforge/checkout', pathValue });
  assert.equal(out.match(/^#?EnvironmentFile=/gm).length, 1);
  assert.match(out, /^\[Service\]\nEnvironmentFile=-%h\/\.zenoforge\/env$/m);
  assert.match(out, /^TimeoutStartSec=20min$/m);
});

test('timer list drops entries the engine does not ship, so run-tick never alerts on them', () => {
  const list = read('systemd/pipeline-timers.list');
  const shipped = new Set(fs.readdirSync(path.join(engine, 'systemd')));
  const out = renderTimerList(list, shipped);
  const timers = timersFromList(out);
  assert.ok(timers.includes('zenoforge-agent.timer'));
  assert.ok(!timers.includes('zenoforge-local-rescue.timer'));
  assert.ok(timers.every((t) => shipped.has(t)));
});

test('loop services: sync before the scheduler, bell after it, both restart', () => {
  const units = renderLoopServices({ home, checkout: '/home/alice/.zenoforge/checkout', pathValue });
  const sched = parseUnit(units['zenoforge-autopilot-scheduler.service']);
  assert.equal(unitValues(sched, 'Service', 'ExecStartPre')[0], '/usr/bin/env bash %h/.zenoforge/checkout/engine/mac-autopilot/start.sh --sync-only');
  assert.match(unitValues(sched, 'Service', 'ExecStart')[0], /autopi-live\/loop\.sh$/);
  assert.equal(unitValues(sched, 'Service', 'Restart')[0], 'always');
  const bell = parseUnit(units['zenoforge-autopilot-bell.service']);
  assert.equal(unitValues(bell, 'Unit', 'After')[0], 'zenoforge-autopilot-scheduler.service');
  assert.match(unitValues(bell, 'Service', 'ExecStart')[0], /bell-loop\.sh$/);
});

test('buildPath dedups, keeps tool dirs first, abbreviates home', () => {
  assert.equal(buildPath({ dirs: ['/home/alice/bin', '/usr/bin', '/home/alice/bin'], home }).split(':')[0], '%h/bin');
  assert.equal(buildPath({ dirs: ['/usr/bin'], home }).split(':').filter((d) => d === '/usr/bin').length, 1);
});

test('launchd plist from the shipped agent service and timer', () => {
  const svc = renderService(read('systemd/zenoforge-agent.service'), { home, checkout: '/home/alice/.zenoforge/checkout', pathValue });
  const plist = renderPlist({ name: 'zenoforge-agent.service', serviceText: svc, timerText: read('systemd/zenoforge-agent.timer'), home, logDir: '/home/alice/.zenoforge/logs' });
  assert.match(plist, /<key>Label<\/key>\s*<string>com\.zenoforge\.agent<\/string>/);
  assert.match(plist, /<key>StartInterval<\/key>\s*<integer>300<\/integer>/);
  assert.match(plist, /<string>\$\{e:-\/home\/alice\/\.zenoforge\/checkout\/engine\}\/run-tick\.sh<\/string>/);
  assert.match(plist, /<key>ZF_REPO_DIR<\/key><string>\/home\/alice\/\.zenoforge\/checkout<\/string>/);
  assert.match(plist, /\. '\/home\/alice\/\.zenoforge\/env'/, 'env file is sourced by the wrapper');
  assert.doesNotMatch(plist, /%h/);
  assert.doesNotMatch(plist, /KeepAlive/);
});

test('launchd plist for a resident loop: KeepAlive, pre-step, no interval', () => {
  const units = renderLoopServices({ home, checkout: '/home/alice/.zenoforge/checkout', pathValue });
  const plist = renderPlist({ name: 'zenoforge-autopilot-scheduler.service', serviceText: units['zenoforge-autopilot-scheduler.service'], home, logDir: '/l' });
  assert.match(plist, /<key>KeepAlive<\/key>\s*<true\/>/);
  assert.doesNotMatch(plist, /StartInterval/);
  assert.match(plist, /start\.sh' '--sync-only' &amp;&amp; exec "\$@"/);
});

test('launchd daily calendar converts UTC with the host offset; durations parse', () => {
  const svc = renderService(read('systemd/zenoforge-daily-perf-report.service'), { home, checkout: '/c', pathValue });
  const plist = renderPlist({ name: 'zenoforge-daily-perf-report.service', serviceText: svc, timerText: read('systemd/zenoforge-daily-perf-report.timer'), home, logDir: '/l', utcOffsetMinutes: -420 });
  assert.match(plist, /<key>Hour<\/key><integer>18<\/integer><key>Minute<\/key><integer>0<\/integer>/);
  assert.equal(parseDuration('5min'), 300);
  assert.equal(parseDuration('6h'), 21600);
  assert.equal(parseDuration('45s'), 45);
  assert.throws(() => parseDuration('soon'), /unsupported/);
});
