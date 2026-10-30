// Pure text generation: env files, engine config, systemd units, launchd plists, label set.
// Nothing here touches the disk, so every function is unit-testable.
import path from 'node:path';

export const AGENT_DIR = '.zenoforge'; // the engine hardcodes ~/.zenoforge as its state root

/** Replace a leading home directory with systemd's %h specifier. */
export function tilde(p, home) {
  if (p === home) return '%h';
  return p.startsWith(`${home}/`) ? `%h${p.slice(home.length)}` : p;
}
export const untilde = (p, home) => p.replaceAll('%h', home);

// ---------- env and config files ----------

export function renderEnvFile({ repo, worktreeRoot, ghToken = '' }) {
  const lines = [
    '# Written by `zenoforge init`. Read by every Zenoforge service (EnvironmentFile).',
    '# Keep this file mode 600 and out of any repository.',
    `ZF_REPO=${repo}`,
    `ZF_GH_REPO=${repo}`,
    `ZF_WORKTREE_ROOT=${worktreeRoot}`,
  ];
  if (ghToken) {
    lines.push('# Copy of your gh token: systemd and launchd jobs cannot read the gh keyring.', `GH_TOKEN=${ghToken}`);
  } else {
    lines.push('# GH_TOKEN=   (only needed when gh keeps its token in a keyring that background jobs cannot read)');
  }
  return `${lines.join('\n')}\n`;
}

export function renderCapacityEnv({ maxWorkers, workerBackend = '' }) {
  const lines = [
    '# Written by `zenoforge init`. Capacity gate read by engine/lib.sh. Bad values make the gate defer.',
    `AGENT_GLOBAL_EXECUTION_CAP=${maxWorkers}`,
  ];
  if (workerBackend) lines.push(`WORKER_BACKEND=${workerBackend}`);
  return `${lines.join('\n')}\n`;
}

/** Recipients stay empty: no mail leaves the host until the owner fills this in. */
export const renderRecipients = () => `${JSON.stringify({ maintainer_login: '', recipients: {} }, null, 2)}\n`;

/**
 * Engine unit-loop config. The runtime copy is overwritten from this template, so the
 * template is the only place a setting can live.
 * Safe defaults: the release train and the arbiter need pieces this checkout does not ship.
 */
export function renderConfigTemplate(templateText, { maxWorkers, dailyTokenBudget, reviewProvider, autoMerge }) {
  const cfg = JSON.parse(templateText);
  cfg.max_workers = maxWorkers;
  cfg.implement_cap = Math.min(cfg.implement_cap ?? maxWorkers, maxWorkers);
  cfg.daily_token_budget = dailyTokenBudget;
  cfg.auto_merge = Boolean(autoMerge);
  cfg.release_train = { ...(cfg.release_train ?? {}), enabled: false };
  cfg.supervisor_arbiter = { ...(cfg.supervisor_arbiter ?? {}), enabled: false };
  if (reviewProvider === 'codex') cfg.models.review = [...cfg.models.implement];
  // claude keeps the template's own claude review entry
  return `${JSON.stringify(cfg, null, 2)}\n`;
}

export function renderRequiredChecks(templateText, checks) {
  const cfg = JSON.parse(templateText);
  cfg.required = checks;
  delete cfg._comment;
  return `${JSON.stringify(cfg, null, 2)}\n`;
}

// ---------- GitHub labels ----------

// Labels the engine uses that are not in ALL_STATE_LABELS (engine/lib.sh, hold_issue, tracker, hotfix lane, categories).
export const EXTRA_LABELS = ['on-hold', 'tracker', 'hotfix', 'bug', 'enhancement'];

/** Read the label array out of engine/lib.sh so the CLI cannot drift from the engine. */
export function labelsFromLib(libText) {
  const m = /^ALL_STATE_LABELS=\(([^)]*)\)/m.exec(libText);
  if (!m) throw new Error('ALL_STATE_LABELS not found in engine/lib.sh');
  const state = m[1].trim().split(/\s+/).filter(Boolean);
  return [...new Set([...state, ...EXTRA_LABELS])];
}

// ---------- systemd unit files ----------

/** Parse systemd unit syntax into {Section: [[key, value], ...]}; repeated keys are kept. */
export function parseUnit(text) {
  const out = {};
  let section = null;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#') || line.startsWith(';')) continue;
    const s = /^\[(.+)\]$/.exec(line);
    if (s) { section = s[1]; out[section] ??= []; continue; }
    const kv = /^([A-Za-z0-9]+)=(.*)$/.exec(line);
    if (kv && section) out[section].push([kv[1], kv[2]]);
  }
  return out;
}
export const unitValues = (unit, section, key) => (unit[section] ?? []).filter(([k]) => k === key).map(([, v]) => v);

/**
 * Turn a shipped engine/systemd/*.service into one for this host: checkout path, repo env,
 * a PATH that contains the real tool locations, no inherited proxy of the original deployment.
 */
export function renderService(text, { home, checkout, pathValue }) {
  const shipped = '%h/.zenoforge/checkout';
  let out = text.replaceAll(shipped, tilde(checkout, home));
  out = out
    .split('\n')
    .filter((l) => !/^Environment=(http|https|no)_proxy=/i.test(l))
    .filter((l) => !/^#?EnvironmentFile=/.test(l))
    .map((l) => (l.startsWith('Environment=PATH=') ? `Environment=PATH=${pathValue}` : l))
    .map((l) => (l === 'Environment=ZF_WORKTREE_ROOT=%h/wt' ? `Environment=ZF_WORKTREE_ROOT=%h/${AGENT_DIR}/wt` : l))
    .join('\n');
  return out.replace(/^\[Service\]$/m, `[Service]\nEnvironmentFile=-%h/${AGENT_DIR}/env`);
}

/** Drop timers that pipeline-timers.list names but the engine does not ship; run-tick would alert on them forever. */
export function renderTimerList(listText, shippedUnits) {
  return listText
    .split('\n')
    .filter((l) => {
      const name = l.trim().split(/\s+/)[0];
      return !name || name.startsWith('#') || shippedUnits.has(name);
    })
    .join('\n');
}
export const timersFromList = (listText) =>
  listText.split('\n').map((l) => l.trim().split(/\s+/)[0]).filter((n) => n && !n.startsWith('#') && n.endsWith('.timer'));

/** The unit loop has no shipped units. These two keep scheduler and bell running, resynced from `current`. */
export function renderLoopServices({ home, checkout, pathValue }) {
  const co = tilde(checkout, home);
  const unit = (desc, after, exec) => `[Unit]
Description=${desc}
${after}
[Service]
EnvironmentFile=-%h/${AGENT_DIR}/env
WorkingDirectory=${co}
Environment=ZF_REPO_DIR=${co}
Environment=MAC_AUTOPILOT_ROOT=${co}
Environment=PATH=${pathValue}
${exec}Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
`;
  const live = `${co}/.scratch-supervisor/autopi-live`;
  return {
    'zenoforge-autopilot-scheduler.service': unit(
      'Zenoforge unit loop (scheduler)',
      '',
      `ExecStartPre=/usr/bin/env bash ${co}/engine/mac-autopilot/start.sh --sync-only\nExecStart=/usr/bin/env bash ${live}/loop.sh\n`,
    ),
    // After= only orders startup; Restart=always covers the first start losing the race to the version sync.
    'zenoforge-autopilot-bell.service': unit(
      'Zenoforge unit loop (bell)',
      'After=zenoforge-autopilot-scheduler.service\n',
      `ExecStart=/usr/bin/env bash ${live}/bell-loop.sh\n`,
    ),
  };
}

export function buildPath({ dirs, home }) {
  const fixed = [`${home}/.local/bin`, `${home}/.npm-global/bin`, '/usr/local/sbin', '/usr/local/bin', '/usr/sbin', '/usr/bin', '/sbin', '/bin'];
  return [...new Set([...dirs, ...fixed])].map((d) => tilde(d, home)).join(':');
}

// ---------- launchd ----------

const xml = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const sq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

export function parseDuration(text) {
  const m = /^(\d+)\s*(s|sec|m|min|h|hr|d)?$/.exec(text.trim());
  if (!m) throw new Error(`unsupported duration: ${text}`);
  const n = Number(m[1]);
  return n * { s: 1, sec: 1, m: 60, min: 60, h: 3600, hr: 3600, d: 86400, undefined: 1 }[m[2]];
}

/** Split an Environment= value on spaces, honoring double quotes. */
export function splitAssignments(value) {
  return [...value.matchAll(/"([^"]*)"|(\S+)/g)].map((m) => m[1] ?? m[2]);
}

/**
 * Build a LaunchAgent plist from the same unit text systemd uses.
 * shortcut: TimeoutStartSec, RandomizedDelaySec and OnActiveSec have no launchd equivalent and are dropped; upgrade if macOS users need them.
 */
export function renderPlist({ name, serviceText, timerText = '', home, logDir, utcOffsetMinutes = 0 }) {
  const svc = parseUnit(serviceText);
  const tmr = timerText ? parseUnit(timerText) : {};
  const resolve = (v) => untilde(v, home);
  const label = `com.zenoforge.${name.replace(/^zenoforge-/, '').replace(/\.service$/, '')}`;
  const env = {};
  for (const v of unitValues(svc, 'Service', 'Environment')) {
    for (const a of splitAssignments(v)) {
      const i = a.indexOf('=');
      if (i > 0) env[a.slice(0, i)] = resolve(a.slice(i + 1));
    }
  }
  const envFile = unitValues(svc, 'Service', 'EnvironmentFile').map((v) => resolve(v.replace(/^-/, '')))[0];
  const argv = (v) => splitAssignments(resolve(v));
  const pres = unitValues(svc, 'Service', 'ExecStartPre').map(argv);
  const exec = argv(unitValues(svc, 'Service', 'ExecStart')[0]);
  const prefix = `set -a; ${envFile ? `[ -r ${sq(envFile)} ] && . ${sq(envFile)}; ` : ''}set +a; `;
  const script = `${prefix}${pres.map((a) => `${a.map(sq).join(' ')} && `).join('')}exec "$@"`;
  const args = ['/bin/bash', '-c', script, 'zenoforge', ...exec];

  const keepAlive = unitValues(svc, 'Service', 'Restart')[0] === 'always';
  const interval = unitValues(tmr, 'Timer', 'OnUnitActiveSec')[0];
  const calendar = unitValues(tmr, 'Timer', 'OnCalendar')[0];
  let schedule = '';
  if (interval) {
    schedule = `  <key>StartInterval</key>\n  <integer>${parseDuration(interval)}</integer>\n`;
  } else if (calendar) {
    const m = /\b(\d{2}):(\d{2}):\d{2} UTC$/.exec(calendar);
    if (!m) throw new Error(`unsupported OnCalendar: ${calendar}`);
    // launchd runs in local time; convert the UTC wall time with the host's current offset
    const total = (Number(m[1]) * 60 + Number(m[2]) + utcOffsetMinutes + 1440) % 1440;
    schedule = `  <key>StartCalendarInterval</key>\n  <dict><key>Hour</key><integer>${Math.floor(total / 60)}</integer><key>Minute</key><integer>${total % 60}</integer></dict>\n`;
  }
  const wd = unitValues(svc, 'Service', 'WorkingDirectory')[0];
  const envXml = Object.entries(env).map(([k, v]) => `    <key>${xml(k)}</key><string>${xml(v)}</string>\n`).join('');
  const log = path.join(logDir, `${label}.log`);
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${xml(label)}</string>
  <key>ProgramArguments</key>
  <array>
${args.map((a) => `    <string>${xml(a)}</string>\n`).join('')}  </array>
${wd ? `  <key>WorkingDirectory</key>\n  <string>${xml(resolve(wd))}</string>\n` : ''}  <key>EnvironmentVariables</key>
  <dict>
${envXml}  </dict>
${schedule}  <key>RunAtLoad</key>
  <true/>
${keepAlive ? '  <key>KeepAlive</key>\n  <true/>\n' : ''}  <key>StandardOutPath</key>
  <string>${xml(log)}</string>
  <key>StandardErrorPath</key>
  <string>${xml(log)}</string>
</dict>
</plist>
`;
}
