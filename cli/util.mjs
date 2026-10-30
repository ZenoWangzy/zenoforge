// Shared helpers: process runner, PATH lookup, and the dry-run aware action sink.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

/** Run a command without a shell. Never throws; a missing binary is {ok:false, code:null}. */
export function run(cmd, args = [], opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', timeout: 30000, ...opts });
  return {
    ok: r.status === 0 && !r.error,
    code: r.status,
    stdout: r.stdout ?? '',
    stderr: r.stderr ?? '',
    missing: r.error?.code === 'ENOENT',
  };
}

/** First executable named `name` on PATH, or null. */
export function which(name, envPath = process.env.PATH ?? '') {
  for (const dir of envPath.split(path.delimiter)) {
    if (!dir) continue;
    const p = path.join(dir, name);
    try {
      fs.accessSync(p, fs.constants.X_OK);
      if (fs.statSync(p).isFile()) return p;
    } catch { /* not here */ }
  }
  return null;
}

/**
 * Every side effect of init/upgrade/uninstall goes through an Actions object so that
 * --dry-run can print exactly what a real run would write or execute.
 */
export class Actions {
  constructor({ dryRun = false, log = console.log, runner = run } = {}) {
    this.dryRun = dryRun;
    this.log = log;
    this.runner = runner;
    this.journal = [];
  }
  note(kind, text) {
    this.journal.push({ kind, text });
    if (this.dryRun) this.log(`  [dry-run] ${kind} ${text}`);
  }
  mkdir(dir) {
    this.note('MKDIR', dir);
    if (!this.dryRun) fs.mkdirSync(dir, { recursive: true });
  }
  /** Content is never echoed in dry-run, only its size, so env files cannot leak a token. */
  write(file, content, { mode = 0o644 } = {}) {
    this.note('WRITE', `${file} (mode ${mode.toString(8)}, ${Buffer.byteLength(content)} bytes)`);
    if (this.dryRun) return;
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content, { mode });
    fs.chmodSync(file, mode); // writeFileSync keeps the old mode of an existing file
  }
  /** Atomic symlink replace: build the link under a temp name, then rename over the target. */
  symlink(target, link) {
    this.note('LINK', `${link} -> ${target}`);
    if (this.dryRun) return;
    const tmp = `${link}.tmp-${process.pid}`;
    fs.mkdirSync(path.dirname(link), { recursive: true });
    fs.rmSync(tmp, { force: true });
    fs.symlinkSync(target, tmp);
    fs.renameSync(tmp, link);
  }
  copyTree(src, dest) {
    this.note('COPY', `${src}/ -> ${dest}/`);
    if (!this.dryRun) fs.cpSync(src, dest, { recursive: true, verbatimSymlinks: true });
  }
  rename(from, to) {
    this.note('RENAME', `${from} -> ${to}`);
    if (!this.dryRun) fs.renameSync(from, to);
  }
  remove(p) {
    this.note('REMOVE', p);
    if (!this.dryRun) fs.rmSync(p, { recursive: true, force: true });
  }
  /** Mutating command. Returns a result object; in dry-run it only prints and reports ok. */
  exec(cmd, args = [], opts = {}) {
    this.note('RUN', [cmd, ...args].join(' '));
    if (this.dryRun) return { ok: true, code: 0, stdout: '', stderr: '', dry: true };
    return this.runner(cmd, args, opts);
  }
}
