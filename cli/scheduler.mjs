// Scheduler backends: systemd user units (Linux, WSL2), launchd LaunchAgents (macOS), detached processes (anything else).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { renderPlist, timersFromList } from './render.mjs';
import { readEnvFile } from './state.mjs';
import { run, which } from './util.mjs';

export const LOOP_SERVICES = ['zenoforge-autopilot-scheduler.service', 'zenoforge-autopilot-bell.service'];

export function detectScheduler({ platform = process.platform, find = (n) => which(n), exec = run } = {}) {
  if (platform === 'darwin') return find('launchctl') ? 'launchd' : 'foreground';
  if (find('systemctl') && exec('systemctl', ['--user', 'show-environment']).ok) return 'systemd';
  return 'foreground';
}

const listDir = (dir, ext) => {
  try { return fs.readdirSync(dir).filter((f) => f.endsWith(ext)).sort(); } catch { return []; }
};

/**
 * Units this backend manages. During init and upgrade the engine version dir may not exist yet
 * (dry run), so callers hand in the rendered texts as ctx.units; otherwise they are read from `current`.
 */
export function managedUnits(ctx) {
  if (ctx.units) return ctx.units;
  const unitsDir = path.join(ctx.engineRoot, 'current', 'systemd');
  let list = '';
  try { list = fs.readFileSync(path.join(unitsDir, 'pipeline-timers.list'), 'utf8'); } catch { /* not installed yet */ }
  return {
    files: [...listDir(unitsDir, '.service'), ...listDir(unitsDir, '.timer')],
    read: (f) => fs.readFileSync(path.join(unitsDir, f), 'utf8'),
    timers: timersFromList(list),
    services: LOOP_SERVICES,
  };
}

/** The same shape, built from the overlay and the packaged timers before anything is on disk. */
export function unitsFromOverlay(overlay, pkgEngine) {
  const rendered = Object.fromEntries(Object.entries(overlay).filter(([k]) => k.startsWith('systemd/')).map(([k, v]) => [k.slice(8), v]));
  const shipped = listDir(path.join(pkgEngine, 'systemd'), '.timer');
  const read = (f) => rendered[f] ?? fs.readFileSync(path.join(pkgEngine, 'systemd', f), 'utf8');
  const files = [...new Set([...Object.keys(rendered).filter((f) => f.endsWith('.service')), ...shipped])].sort();
  return { files, read, timers: timersFromList(rendered['pipeline-timers.list'] ?? ''), services: LOOP_SERVICES };
}

// ---------------------------------------------------------------- systemd

export const systemd = {
  name: 'systemd',
  install(act, ctx) {
    const m = managedUnits(ctx);
    for (const f of m.files) {
      act.write(path.join(ctx.unitDir, f), m.read(f));
    }
    return act.exec('systemctl', ['--user', 'daemon-reload']);
  },
  enable(act, ctx) {
    const m = managedUnits(ctx);
    return act.exec('systemctl', ['--user', 'enable', '--now', ...m.timers, ...m.services]);
  },
  disable(act, ctx) {
    const m = managedUnits(ctx);
    return act.exec('systemctl', ['--user', 'disable', '--now', ...m.timers, ...m.services]);
  },
  uninstall(act, ctx) {
    const m = managedUnits(ctx);
    systemd.disable(act, ctx);
    for (const f of m.files) act.remove(path.join(ctx.unitDir, f));
    act.exec('systemctl', ['--user', 'daemon-reload']);
  },
  restartLoops(act) {
    return act.exec('systemctl', ['--user', 'restart', ...LOOP_SERVICES]);
  },
  status(ctx) {
    const m = managedUnits(ctx);
    const out = [];
    for (const u of [...m.timers, ...m.services]) {
      const r = run('systemctl', ['--user', 'is-active', u]);
      out.push({ unit: u, state: r.stdout.trim() || (r.missing ? 'no systemctl' : 'unknown') });
    }
    return out;
  },
  logs({ lines = 100, follow = false }) {
    const args = ['--user', '-u', 'zenoforge-*', '-n', String(lines), '--no-pager', ...(follow ? ['-f'] : [])];
    return spawn('journalctl', args, { stdio: 'inherit' });
  },
};

// ---------------------------------------------------------------- launchd

const jobLabel = (file) => `com.zenoforge.${file.replace(/^zenoforge-/, '').replace(/\.service$/, '')}`;

export const launchd = {
  name: 'launchd',
  // shortcut: macOS gets the unit loop only. The issue loop dispatches stages with systemd-run, which macOS lacks; upgrade when the engine drops that call.
  jobs(ctx) {
    return LOOP_SERVICES.map((file) => ({ file, label: jobLabel(file) }));
  },
  install(act, ctx) {
    const m = managedUnits(ctx);
    const offset = -new Date().getTimezoneOffset();
    for (const { file, label } of launchd.jobs(ctx)) {
      const text = renderPlist({
        name: file,
        serviceText: m.read(file),
        home: ctx.home,
        logDir: path.join(ctx.agentHome, 'logs'),
        utcOffsetMinutes: offset,
      });
      act.write(path.join(ctx.plistDir, `${label}.plist`), text);
    }
    act.mkdir(path.join(ctx.agentHome, 'logs'));
  },
  enable(act, ctx) {
    let last = { ok: true };
    for (const { label } of launchd.jobs(ctx)) {
      act.exec('launchctl', ['bootout', `gui/${ctx.uid}/${label}`]); // not loaded yet is fine
      last = act.exec('launchctl', ['bootstrap', `gui/${ctx.uid}`, path.join(ctx.plistDir, `${label}.plist`)]);
    }
    return last;
  },
  disable(act, ctx) {
    for (const { label } of launchd.jobs(ctx)) act.exec('launchctl', ['bootout', `gui/${ctx.uid}/${label}`]);
    return { ok: true };
  },
  uninstall(act, ctx) {
    launchd.disable(act, ctx);
    for (const { label } of launchd.jobs(ctx)) act.remove(path.join(ctx.plistDir, `${label}.plist`));
  },
  restartLoops(act, ctx) {
    return launchd.enable(act, ctx);
  },
  status(ctx) {
    return launchd.jobs(ctx).map(({ label }) => ({
      unit: label,
      state: run('launchctl', ['print', `gui/${ctx.uid}/${label}`]).ok ? 'loaded' : 'not loaded',
    }));
  },
  logs({ lines = 100, follow = false }, ctx) {
    const files = launchd.jobs(ctx).map(({ label }) => path.join(ctx.agentHome, 'logs', `${label}.log`)).filter((f) => fs.existsSync(f));
    return spawn('tail', ['-n', String(lines), ...(follow ? ['-F'] : []), ...files], { stdio: 'inherit' });
  },
};

// ---------------------------------------------------------------- foreground (detached processes + pid files)

const pidDir = (ctx) => path.join(ctx.agentHome, 'run');
const pidFile = (ctx, n) => path.join(pidDir(ctx), `${n}.pid`);
const FG_LOOPS = [['scheduler', 'loop.sh'], ['bell', 'bell-loop.sh']];

const alive = (pid) => {
  try { process.kill(pid, 0); return true; } catch { return false; }
};
const readPid = (file) => {
  const n = Number(fs.readFileSync(file, 'utf8').trim());
  return Number.isInteger(n) && n > 0 ? n : null;
};

export const foreground = {
  name: 'foreground',
  install() { /* nothing to install: processes are started by `zenoforge start` */ },
  enable(act, ctx) {
    act.mkdir(pidDir(ctx));
    const sync = act.exec('bash', [path.join(ctx.checkout, 'engine/mac-autopilot/start.sh'), '--sync-only'], { env: ctx.env });
    if (!sync.ok) return sync;
    for (const [name, script] of FG_LOOPS) {
      const pf = pidFile(ctx, name);
      if (fs.existsSync(pf) && alive(readPid(pf))) continue;
      act.note('SPAWN', `bash ${path.join(ctx.checkout, '.scratch-supervisor/autopi-live', script)} (log ${ctx.agentHome}/logs/${name}.log)`);
      if (act.dryRun) continue;
      fs.mkdirSync(path.join(ctx.agentHome, 'logs'), { recursive: true });
      const fd = fs.openSync(path.join(ctx.agentHome, 'logs', `${name}.log`), 'a');
      const child = spawn('bash', [path.join(ctx.checkout, '.scratch-supervisor/autopi-live', script)], {
        cwd: ctx.checkout, env: ctx.env, detached: true, stdio: ['ignore', fd, fd],
      });
      child.unref();
      act.write(pf, `${child.pid}\n`);
    }
    return { ok: true };
  },
  disable(act, ctx) {
    for (const [name] of FG_LOOPS) {
      const pf = pidFile(ctx, name);
      if (!fs.existsSync(pf)) continue;
      const pid = readPid(pf);
      act.note('KILL', `process group ${pid} (${name})`);
      if (!act.dryRun && pid && alive(pid)) {
        try { process.kill(-pid, 'SIGTERM'); } catch { /* already gone */ }
      }
      act.remove(pf);
    }
    return { ok: true };
  },
  uninstall(act, ctx) { foreground.disable(act, ctx); },
  restartLoops(act, ctx) { foreground.disable(act, ctx); return foreground.enable(act, ctx); },
  status(ctx) {
    return FG_LOOPS.map(([name]) => {
      const pf = pidFile(ctx, name);
      const pid = fs.existsSync(pf) ? readPid(pf) : null;
      return { unit: `zenoforge-${name}`, state: pid && alive(pid) ? `running (pid ${pid})` : 'stopped' };
    });
  },
  logs({ lines = 100, follow = false }, ctx) {
    const files = FG_LOOPS.map(([n]) => path.join(ctx.agentHome, 'logs', `${n}.log`)).filter((f) => fs.existsSync(f));
    return spawn('tail', ['-n', String(lines), ...(follow ? ['-F'] : []), ...files], { stdio: 'inherit' });
  },
};

export const backends = { systemd, launchd, foreground };

export function buildCtx({ home = os.homedir(), checkout, env = process.env } = {}) {
  const agentHome = path.join(home, '.zenoforge');
  return {
    home,
    agentHome,
    engineRoot: path.join(agentHome, 'engine'),
    checkout,
    uid: process.getuid?.() ?? 0,
    unitDir: env.SYSTEMD_USER_UNIT_DIR ?? path.join(env.XDG_CONFIG_HOME ?? path.join(home, '.config'), 'systemd', 'user'),
    plistDir: path.join(home, 'Library', 'LaunchAgents'),
    // same precedence as systemd: the env file beats the inherited environment
    env: { ...env, ...readEnvFile(path.join(agentHome, 'env')), ZF_REPO_DIR: checkout, MAC_AUTOPILOT_ROOT: checkout },
  };
}
