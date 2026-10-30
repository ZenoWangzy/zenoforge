#!/usr/bin/env node
// zenoforge: one-command installer and operator CLI. See README.md "Quickstart".
import { parseArgs } from 'node:util';
import * as cmd from './commands.mjs';

const HELP = `zenoforge ${cmd.pkgVersion()}

Usage: zenoforge <command> [options]

Commands
  init        Check the host, set up the engine, checkout, labels and scheduler for one repository
  doctor      Check host requirements; prints the exact fix for each missing item
  start       Switch the scheduler on
  stop        Switch the scheduler off
  status      Show scheduler, engine version and pipeline switches
  logs        Show engine logs (-f to follow, -n N for the last N lines)
  upgrade     Install this package's engine as a new version and switch to it
  rollback    Switch back to the previous engine version
  uninstall   Remove scheduler units; keeps ~/.zenoforge unless --purge

Options for init
  --repo owner/name      target repository (asked for when omitted)
  --checkout-dir DIR     dedicated checkout (default ~/.zenoforge/checkout); it is reset every tick
  --implement AGENT      codex | zcode        (default: first one installed)
  --review AGENT         claude | codex       (default: first one installed)
  --max-workers N        1-16, default 2
  --required-check NAME  PR check that must pass before merge (repeatable; default: read from branch protection)
  --auto-merge           merge even when no required check is known
  --no-scheduler         install everything but switch nothing on
  --yes                  accept the security warning without asking
  --dry-run              print every file and command, change nothing

Other options: --purge (uninstall), -f/--follow, -n/--lines, -h/--help, -v/--version
`;

const options = {
  repo: { type: 'string' },
  'checkout-dir': { type: 'string' },
  implement: { type: 'string' },
  review: { type: 'string' },
  'max-workers': { type: 'string' },
  'required-check': { type: 'string', multiple: true },
  'auto-merge': { type: 'boolean' },
  'no-scheduler': { type: 'boolean' },
  yes: { type: 'boolean', short: 'y' },
  'dry-run': { type: 'boolean' },
  purge: { type: 'boolean' },
  follow: { type: 'boolean', short: 'f' },
  lines: { type: 'string', short: 'n' },
  help: { type: 'boolean', short: 'h' },
  version: { type: 'boolean', short: 'v' },
};

async function main(argv) {
  let parsed;
  try {
    parsed = parseArgs({ args: argv, options, allowPositionals: true });
  } catch (e) {
    console.error(`zenoforge: ${e.message}\n\n${HELP}`);
    return 2;
  }
  const { values: v, positionals } = parsed;
  if (v.version) { console.log(cmd.pkgVersion()); return 0; }
  const name = positionals[0];
  if (v.help || !name) { console.log(HELP); return name || v.help ? 0 : 2; }

  const opts = {
    repo: v.repo, checkoutDir: v['checkout-dir'], implement: v.implement, review: v.review,
    maxWorkers: v['max-workers'], requiredCheck: v['required-check'], autoMerge: v['auto-merge'],
    noScheduler: v['no-scheduler'], yes: v.yes, dryRun: v['dry-run'], purge: v.purge, follow: v.follow, lines: v.lines,
  };
  const io = cmd.defaultIo();
  try {
    switch (name) {
      case 'init': await cmd.init(opts, io); return 0;
      case 'doctor': return cmd.doctor(opts, io) ? 0 : 1;
      case 'start': cmd.start(opts, io); return 0;
      case 'stop': cmd.stop(opts, io); return 0;
      case 'status': cmd.status(opts, io); return 0;
      case 'logs': {
        const child = cmd.logs(opts, io);
        return await new Promise((resolve) => child.on('exit', (c) => resolve(c ?? 0)));
      }
      case 'upgrade': cmd.upgrade(opts, io); return 0;
      case 'rollback': cmd.rollback(opts, io); return 0;
      case 'uninstall': cmd.uninstall(opts, io); return 0;
      default:
        console.error(`zenoforge: unknown command "${name}"\n\n${HELP}`);
        return 2;
    }
  } catch (e) {
    if (e instanceof cmd.UserError) { console.error(`\nzenoforge: ${e.message}`); return 1; }
    throw e;
  }
}

process.exitCode = await main(process.argv.slice(2));
