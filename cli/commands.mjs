// The subcommands. Each takes parsed options and an io object so tests can drive them without a terminal.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AGENT_CLIS, detectAgents, formatDoctor, hardFailures, runDoctor } from './doctor.mjs';
import { currentVersion, installEngine, previousVersion, pruneEngines, rollback as rollbackEngine } from './engine.mjs';
import * as gh from './github.mjs';
import {
  AGENT_DIR, buildPath, labelsFromLib, renderCapacityEnv, renderConfigTemplate, renderEnvFile, renderLoopServices,
  renderRecipients, renderRequiredChecks, renderService, renderTimerList,
} from './render.mjs';
import { backends, buildCtx, detectScheduler, unitsFromOverlay } from './scheduler.mjs';
import { loadState, readEnvFile, statePath } from './state.mjs';
import { Actions, run, which } from './util.mjs';

const PKG_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const PKG_ENGINE = path.join(PKG_ROOT, 'engine');
export const pkgVersion = () => JSON.parse(fs.readFileSync(path.join(PKG_ROOT, 'package.json'), 'utf8')).version;

// Which agent CLIs can do which job in the engine today (see docs/install.md, "Agents and roles"). Default first.
export const ROLE_AGENTS = { implement: ['codex', 'zcode'], review: ['claude', 'codex'] };

export class UserError extends Error {}

export const RISK_WARNING = `Read this before anything is switched on (full text: SECURITY.md):
  - Coding agents run UNSANDBOXED on this machine, with your user's permissions and your gh login.
  - Issue text is UNTRUSTED input. Anyone who can open or comment on an issue in the target
    repository can try to steer an agent. Use this only on repositories where just trusted people file issues.
  - Merges are AUTOMATIC once review and required checks pass. Protect your default branch.
  - Agents spend model quota and CI minutes.
  Use a dedicated OS account (or a machine you can rebuild) and a dedicated GitHub account or a fine-grained token.`;

// ---------------------------------------------------------------------------------------------- helpers

const packagedFile = (rel) => fs.readFileSync(path.join(PKG_ENGINE, rel), 'utf8');

/** Tool directories for the PATH baked into units; systemd and launchd do not read your shell profile. */
export function toolDirs(find = (n) => which(n), extra = []) {
  const names = ['gh', 'git', 'jq', 'node', 'python3', 'bash', 'flock', 'timeout', 'date', ...AGENT_CLIS];
  return [...extra, ...names.map(find).filter(Boolean).map((p) => path.dirname(p))];
}

export function chooseAgent(role, given, installed) {
  if (given) {
    if (!ROLE_AGENTS[role].includes(given)) throw new UserError(`--${role} must be one of: ${ROLE_AGENTS[role].join(', ')}`);
    if (!installed.includes(given)) throw new UserError(`--${role} ${given}: ${given} is not installed (run: zenoforge doctor)`);
    return given;
  }
  const allowed = ROLE_AGENTS[role].filter((a) => installed.includes(a));
  if (!allowed.length) throw new UserError(`no agent CLI installed for the ${role} role (needs one of: ${ROLE_AGENTS[role].join(', ')}). Run: zenoforge doctor`);
  return allowed[0];
}

/** Settings -> every file the engine version dir overrides. Shared by init and upgrade. */
export function buildOverlay(settings, unitCtx) {
  const shipped = fs.readdirSync(path.join(PKG_ENGINE, 'systemd'));
  const overlay = {};
  for (const f of shipped.filter((n) => n.endsWith('.service'))) overlay[`systemd/${f}`] = renderService(packagedFile(`systemd/${f}`), unitCtx);
  for (const [f, text] of Object.entries(renderLoopServices(unitCtx))) overlay[`systemd/${f}`] = text;
  overlay['systemd/pipeline-timers.list'] = renderTimerList(packagedFile('systemd/pipeline-timers.list'), new Set(shipped));
  overlay['mac-autopilot/config.template.json'] = renderConfigTemplate(packagedFile('mac-autopilot/config.template.json'), { ...settings, reviewProvider: settings.agents.review });
  overlay['mac-autopilot/required-pr-checks.json'] = renderRequiredChecks(packagedFile('mac-autopilot/required-pr-checks.json'), settings.requiredChecks);
  return overlay;
}

function gitTopLevel(dir) {
  const r = run('git', ['-C', dir, 'rev-parse', '--show-toplevel']);
  return r.ok ? fs.realpathSync(r.stdout.trim()) : null;
}

/** The dedicated checkout. The engine resets and cleans it every tick, so refuse anything we did not create. */
function prepareCheckout(act, { repo, dir, cwd }) {
  const marker = path.join(dir, '.git', 'zenoforge-checkout');
  if (fs.existsSync(dir)) {
    if (gitTopLevel(cwd) === fs.realpathSync(dir)) throw new UserError(`${dir} is the repository you are standing in. Zenoforge resets its checkout every tick; pass --checkout-dir with a new path.`);
    if (!fs.existsSync(marker) && fs.readdirSync(dir).length > 0) {
      throw new UserError(`${dir} exists and was not created by zenoforge. It would be reset every tick; pass --checkout-dir with a new path.`);
    }
  }
  if (!fs.existsSync(marker)) {
    if (fs.existsSync(dir)) act.remove(dir); // empty: gh clone wants a missing or empty target
    act.exec('gh', ['repo', 'clone', repo, dir]);
    act.write(marker, `${repo}\n`);
  } else {
    const origin = run('git', ['-C', dir, 'remote', 'get-url', 'origin']).stdout.trim();
    if (!origin.includes(repo)) throw new UserError(`${dir} belongs to another repository (${origin}).`);
  }
  if (fs.existsSync(path.join(dir, '.git'))) {
    // shortcut: the engine is linked in as <checkout>/engine, so a repository that tracks its own top-level engine/ cannot be used; upgrade to a ZF_ENGINE_DIR seam in the engine.
    if (run('git', ['-C', dir, 'ls-tree', '--name-only', 'HEAD', 'engine']).stdout.trim()) {
      throw new UserError(`${repo} tracks its own top-level engine/ directory. Zenoforge links its engine there and cannot be installed on this repository yet.`);
    }
  }
  const link = path.join(dir, 'engine');
  if (fs.existsSync(link) && !fs.lstatSync(link).isSymbolicLink()) throw new UserError(`${link} is a real directory; Zenoforge needs that name for its engine link.`);
  act.exec('git', ['-C', dir, 'checkout', 'main']);
}

// Engine link and runtime state sit in the checkout but must survive its per-tick `git clean -fd`.
const EXCLUDES = ['/engine', '/.scratch-supervisor', '/.scratch'];

export function excludeContent(existing) {
  const have = new Set(existing.split('\n'));
  const add = EXCLUDES.filter((l) => !have.has(l));
  if (!add.length) return null;
  return `${existing}${existing && !existing.endsWith('\n') ? '\n' : ''}# zenoforge: engine link and runtime state live outside git\n${add.join('\n')}\n`;
}

/** User-owned files are written once and never clobbered. */
function writeOnce(act, file, content, mode, log) {
  if (fs.existsSync(file)) { log(`kept existing ${file}`); return; }
  act.write(file, content, { mode });
}

// ---------------------------------------------------------------------------------------------- init

export async function init(opts, io) {
  const { log } = io;
  const act = new Actions({ dryRun: opts.dryRun, log, runner: io.runner });
  const agentHome = path.join(io.home, AGENT_DIR);
  const interactive = io.interactive;
  const p = interactive ? await import('@clack/prompts') : null;
  const bail = (v) => {
    if (p.isCancel(v)) { p.cancel('Cancelled. Nothing was changed.'); throw new UserError('cancelled'); }
    return v;
  };

  if (interactive) p.intro('zenoforge init');
  if (opts.dryRun) log('DRY RUN: nothing below is written or executed; read-only checks still run.\n');

  // 1. doctor
  const results = runDoctor({ platform: io.platform, find: io.find, exec: io.exec });
  log(formatDoctor(results));
  const blockers = hardFailures(results);
  if (blockers.length && !opts.dryRun) {
    throw new UserError('Fix the FAIL items above (each shows its command), then run `zenoforge init` again. Nothing was changed.');
  }
  const ghReady = results.find((r) => r.id === 'gh-auth')?.ok;

  // 2. repository
  let repo = opts.repo;
  if (!repo) {
    if (!interactive) throw new UserError('Pass --repo owner/name (no terminal to ask on).');
    const mine = ghReady ? gh.listRepos(io.exec) : [];
    const choice = mine.length
      ? bail(await p.select({ message: 'Repository the factory works on', options: [...mine.map((r) => ({ value: r, label: r })), { value: '', label: 'Other (type owner/name)' }] }))
      : '';
    repo = choice || bail(await p.text({ message: 'Repository (owner/name)', validate: (v) => (gh.REPO_RE.test(v ?? '') ? undefined : 'use owner/name') }));
  }
  if (!gh.REPO_RE.test(repo)) throw new UserError(`--repo must look like owner/name, got "${repo}"`);

  const view = ghReady ? gh.viewRepo(repo, io.exec) : { ok: false, error: 'gh is not usable (see doctor above)' };
  if (!view.ok) {
    log(`WARN  could not read ${repo}: ${view.error}`);
    if (!opts.dryRun) throw new UserError(`Cannot reach ${repo} with your gh login. Nothing was changed.`);
  } else if (view.defaultBranch !== 'main') {
    throw new UserError(`${repo} has default branch "${view.defaultBranch}". The engine currently requires "main".`);
  }

  // one host serves one repository
  const configured = readEnvFile(path.join(agentHome, 'env')).ZF_REPO;
  if (configured && configured !== repo) {
    throw new UserError(`${agentHome} is already set up for ${configured}. Run \`zenoforge uninstall --purge\` first, or use another user account for ${repo}.`);
  }

  // 3. agents (a re-run keeps what the first run chose unless a flag says otherwise)
  const prior = loadState(agentHome) ?? {};
  const installed = detectAgents(io.find);
  const agents = {};
  for (const role of Object.keys(ROLE_AGENTS)) {
    const allowed = ROLE_AGENTS[role].filter((a) => installed.includes(a));
    const before = installed.includes(prior.agents?.[role]) ? prior.agents[role] : undefined;
    if (!opts[role] && !before && allowed.length > 1 && interactive) {
      opts[role] = bail(await p.select({ message: `Agent for the ${role} role`, options: allowed.map((a) => ({ value: a, label: a })) }));
    }
    try {
      agents[role] = chooseAgent(role, opts[role] ?? before, installed);
    } catch (e) {
      if (!opts.dryRun || !(e instanceof UserError)) throw e;
      log(`WARN  ${e.message}`);
      agents[role] = ROLE_AGENTS[role][0];
    }
  }

  // 4. settings
  const maxWorkers = Number(opts.maxWorkers ?? prior.maxWorkers ?? 2);
  if (!Number.isInteger(maxWorkers) || maxWorkers < 1 || maxWorkers > 16) throw new UserError('--max-workers must be an integer from 1 to 16');
  const checkout = path.resolve(opts.checkoutDir ?? path.join(agentHome, 'checkout'));
  const checks = opts.requiredCheck?.length ? opts.requiredCheck : (view.ok ? gh.requiredChecks(repo, 'main', io.exec) : []);
  const autoMerge = Boolean(opts.autoMerge) || checks.length > 0;
  const scheduler = opts.noScheduler ? 'none' : (io.scheduler ?? detectScheduler({ platform: io.platform, find: io.find, exec: io.exec }));
  const pathValue = buildPath({ dirs: toolDirs(io.find, io.extraPathDirs), home: io.home });
  const settings = { repo, checkout, agents, maxWorkers, dailyTokenBudget: 2_000_000, autoMerge, requiredChecks: checks, pathValue, scheduler };

  // 5. plan + risk acknowledgement
  log(`\nPlan
  repository         ${repo}
  dedicated checkout ${checkout}
  implement agent    ${agents.implement}
  review agent       ${agents.review}
  max workers        ${maxWorkers}
  required checks    ${checks.join(', ') || '(none found)'}
  auto merge         ${autoMerge ? 'on' : 'OFF (no required checks known; pass --required-check NAME, or --auto-merge to merge anyway)'}
  scheduler          ${scheduler}
`);
  if (checkout !== path.join(agentHome, 'checkout')) {
    log('WARN  a few engine readers (scheduling-policy.mjs, waste_report.py) assume ~/.zenoforge/checkout. A custom --checkout-dir works, but those reports find nothing there; the default location avoids that.');
  }
  log(RISK_WARNING);
  const enable = scheduler !== 'none';
  if (!opts.dryRun && !opts.yes) {
    if (!interactive) throw new UserError('Re-run with --yes to confirm the warning above (or use a terminal).');
    const ok = bail(await p.confirm({ message: enable ? 'I understand. Install and switch the factory on now?' : 'I understand. Install (nothing will be switched on)?', initialValue: false }));
    if (!ok) throw new UserError('Not confirmed. Nothing was changed.');
  }

  // 6. execute
  act.mkdir(agentHome);
  const auth = ghReady ? io.exec('gh', ['auth', 'status']) : null;
  let ghToken = '';
  if (auth && gh.needsTokenCopy(`${auth.stdout}\n${auth.stderr}`)) {
    act.note('SECRET', 'copy the gh token into the env file (value hidden)');
    if (!act.dryRun) ghToken = io.exec('gh', ['auth', 'token']).stdout.trim();
  }
  writeOnce(act, path.join(agentHome, 'env'), renderEnvFile({ repo, worktreeRoot: path.join(agentHome, 'wt'), ghToken }), 0o600, log);
  const capacityFile = path.join(agentHome, 'capacity.env');
  const capacity = renderCapacityEnv({ maxWorkers, workerBackend: agents.implement === 'zcode' && !installed.includes('codex') ? 'zc' : '' });
  if (fs.existsSync(capacityFile)) {
    // keep the owner's other tuning; only the worker cap follows --max-workers
    const current = fs.readFileSync(capacityFile, 'utf8');
    const next = current.replace(/^AGENT_GLOBAL_EXECUTION_CAP=.*$/m, `AGENT_GLOBAL_EXECUTION_CAP=${maxWorkers}`);
    if (next !== current) act.write(capacityFile, next, { mode: 0o600 });
    else log(`kept existing ${capacityFile}`);
  } else {
    act.write(capacityFile, capacity, { mode: 0o600 });
  }
  writeOnce(act, path.join(agentHome, 'recipients.json'), renderRecipients(), 0o600, log);

  const engineRoot = path.join(agentHome, 'engine');
  const hadEngine = currentVersion(engineRoot);
  const overlay = buildOverlay(settings, { home: io.home, checkout, pathValue });
  const name = installEngine(act, { srcEngine: PKG_ENGINE, engineRoot, version: pkgVersion(), settings, overlay });

  prepareCheckout(act, { repo, dir: checkout, cwd: io.cwd });
  const excludeFile = path.join(checkout, '.git', 'info', 'exclude');
  const exclude = excludeContent(fs.existsSync(excludeFile) ? fs.readFileSync(excludeFile, 'utf8') : '');
  if (exclude !== null) act.write(excludeFile, exclude);
  act.symlink(path.join(engineRoot, 'current'), path.join(checkout, 'engine'));

  const labels = labelsFromLib(packagedFile('lib.sh'));
  const made = gh.ensureLabels(act, repo, labels, view.ok ? gh.existingLabels(repo, io.exec) : null);
  if (!act.dryRun) log(`labels: ${made.length} created, ${labels.length - made.length} already present`);

  let varsOk = true;
  for (const [k, v] of [['AGENT_SUPERVISOR', 'observe'], ['AGENT_PIPELINE', enable ? 'triage' : 'off']]) {
    if (!gh.setVariable(act, repo, k, v).ok) varsOk = false;
  }
  if (!varsOk) {
    log(`WARN  could not set repository variables (needs admin access). Set them yourself:
      gh variable set AGENT_SUPERVISOR --repo ${repo} --body observe
      gh variable set AGENT_PIPELINE --repo ${repo} --body ${enable ? 'triage' : 'off'}`);
  }

  const ctx = { ...buildCtx({ home: io.home, checkout, env: io.env }), units: unitsFromOverlay(overlay, PKG_ENGINE) };
  if (enable) {
    backends[scheduler].install(act, ctx);
    backends[scheduler].enable(act, ctx);
    // a re-run with changed settings flips to a new engine version; the resident loops only pick it up on restart
    if (hadEngine && hadEngine !== name) backends[scheduler].restartLoops(act, ctx);
  }

  const state = { version: pkgVersion(), engine: name, ...settings, installedAt: new Date().toISOString() };
  act.write(statePath(agentHome), `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });

  // 7. next steps
  log(`\n${opts.dryRun ? 'Dry run finished' : 'Installed'}: engine ${name}, ${repo}.`);
  if (opts.dryRun && blockers.length) log(`${blockers.length} required item(s) failed in the doctor check, so a real run would stop before changing anything.`);
  if (scheduler === 'none') log('Scheduler not installed (--no-scheduler). Install and start later with: zenoforge start');
  if (scheduler === 'foreground') log('No systemd or launchd here. `zenoforge start` runs the unit loop as background processes; `zenoforge stop` ends them.');
  if (scheduler === 'launchd') log('macOS runs the unit loop only: the issue loop dispatches with systemd-run, which macOS does not have.');
  if (scheduler === 'systemd') log('To keep it running after you log out: loginctl enable-linger $USER');
  log('Hand an issue to the factory by labeling it needs-triage. Watch: zenoforge status, zenoforge logs -f.');
  if (interactive) p.outro('Done.');
  return { act, name, settings, doctorFailures: blockers.length };
}

// ---------------------------------------------------------------------------------------------- operate

function requireState(io) {
  const agentHome = path.join(io.home, AGENT_DIR);
  const state = loadState(agentHome);
  if (!state) throw new UserError('Not set up on this machine. Run: zenoforge init');
  const ctx = buildCtx({ home: io.home, checkout: state.checkout, env: io.env });
  const kind = state.scheduler === 'none' ? detectScheduler({ platform: io.platform, find: io.find, exec: io.exec }) : state.scheduler;
  return { state, ctx, backend: backends[kind] };
}

export function start(opts, io) {
  const { ctx, backend, state } = requireState(io);
  const act = new Actions({ dryRun: opts.dryRun, log: io.log, runner: io.runner });
  if (state.scheduler === 'none') backend.install(act, ctx); // --no-scheduler left the units uninstalled
  const r = backend.enable(act, ctx);
  if (!r.ok) throw new UserError(`could not start: ${(r.stderr || '').trim().split('\n')[0] || 'see the command output above'}`);
  io.log('started');
}

export function stop(opts, io) {
  const { ctx, backend } = requireState(io);
  backend.disable(new Actions({ dryRun: opts.dryRun, log: io.log, runner: io.runner }), ctx);
  io.log('stopped');
}

export function status(opts, io) {
  const { state, ctx, backend } = requireState(io);
  io.log(`repository  ${state.repo}\nscheduler   ${backend.name}\nengine      ${currentVersion(ctx.engineRoot) ?? '(none)'}  previous: ${previousVersion(ctx.engineRoot) ?? '(none)'}\ncheckout    ${state.checkout}`);
  for (const { unit, state: s } of backend.status(ctx)) io.log(`  ${s.padEnd(14)} ${unit}`);
  for (const v of ['AGENT_PIPELINE', 'AGENT_SUPERVISOR']) {
    const r = io.exec('gh', ['variable', 'get', v, '--repo', state.repo]);
    io.log(`${v.padEnd(18)} ${r.ok ? r.stdout.trim() : '(unreadable)'}`);
  }
}

export function logs(opts, io) {
  const { ctx, backend } = requireState(io);
  return backend.logs({ lines: Number(opts.lines ?? 100), follow: opts.follow }, ctx);
}

/** Install this package's engine as a new version (units and config re-rendered), switch, restart the loops. */
export function upgrade(opts, io) {
  const { state, ctx, backend } = requireState(io);
  const act = new Actions({ dryRun: opts.dryRun, log: io.log, runner: io.runner });
  const before = currentVersion(ctx.engineRoot);
  const pathValue = buildPath({ dirs: toolDirs(io.find, io.extraPathDirs), home: io.home });
  const { version: _v, engine: _e, installedAt: _i, ...kept } = state;
  const settings = { ...kept, pathValue };
  const overlay = buildOverlay(settings, { home: io.home, checkout: state.checkout, pathValue });
  const name = installEngine(act, { srcEngine: PKG_ENGINE, engineRoot: ctx.engineRoot, version: pkgVersion(), settings, overlay });
  if (name === before) { io.log(`engine ${name} is already current`); return; }
  if (state.scheduler !== 'none') {
    const withUnits = { ...ctx, units: unitsFromOverlay(overlay, PKG_ENGINE) };
    backend.install(act, withUnits);
    backend.restartLoops(act, withUnits);
  }
  pruneEngines(act, ctx.engineRoot);
  act.write(statePath(ctx.agentHome), `${JSON.stringify({ ...settings, version: pkgVersion(), engine: name, installedAt: state.installedAt }, null, 2)}\n`, { mode: 0o600 });
  io.log(`engine ${before ?? '(none)'} -> ${name}. Undo with: zenoforge rollback`);
}

export function rollback(opts, io) {
  const { state, ctx, backend } = requireState(io);
  const act = new Actions({ dryRun: opts.dryRun, log: io.log, runner: io.runner });
  const to = rollbackEngine(act, ctx.engineRoot);
  if (!to) throw new UserError('No previous engine version to roll back to.');
  if (state.scheduler !== 'none') { backend.install(act, ctx); backend.restartLoops(act, ctx); }
  io.log(`engine rolled back to ${to}`);
}

export function uninstall(opts, io) {
  const agentHome = path.join(io.home, AGENT_DIR);
  const state = loadState(agentHome);
  if (!state) throw new UserError('Not set up on this machine; nothing to uninstall.');
  if (opts.purge && !opts.yes && !opts.dryRun) throw new UserError(`--purge deletes ${agentHome} and ${state.checkout}. Re-run with --yes to confirm.`);
  const act = new Actions({ dryRun: opts.dryRun, log: io.log, runner: io.runner });
  const ctx = buildCtx({ home: io.home, checkout: state.checkout, env: io.env });
  if (state.scheduler !== 'none') backends[state.scheduler].uninstall(act, ctx);
  act.remove(path.join(state.checkout, 'engine')); // the link only; engine versions stay for rollback
  if (opts.purge) {
    if (fs.existsSync(path.join(state.checkout, '.git', 'zenoforge-checkout'))) act.remove(state.checkout); // only a checkout zenoforge made
    act.remove(agentHome);
  } else {
    act.remove(statePath(agentHome));
  }
  io.log(opts.purge ? 'uninstalled and purged' : `uninstalled. State kept in ${agentHome}; add --purge to delete it.`);
}

export function doctor(opts, io) {
  const results = runDoctor({ platform: io.platform, find: io.find, exec: io.exec });
  io.log(formatDoctor(results));
  return hardFailures(results).length === 0;
}

export const defaultIo = (overrides = {}) => ({
  log: (...a) => console.log(...a),
  home: os.homedir(),
  cwd: process.cwd(),
  env: process.env,
  platform: process.platform,
  interactive: Boolean(process.stdin.isTTY && process.stdout.isTTY),
  find: (n) => which(n),
  exec: run,
  runner: run,
  ...overrides,
});
