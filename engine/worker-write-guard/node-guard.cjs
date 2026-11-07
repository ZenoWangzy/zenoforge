// Preloaded (NODE_OPTIONS --require, set by worker_write_guard_env) into every
// node process a dispatched worker starts: refuse write-mode file access below
// ZF_WORKER_WRITE_GUARD_ROOT, whatever path the script spells. The 2026-11-07
// incident (unit issue-5573) wrote an incident-guard row into the deployment
// checkout from a heredoc script whose target path never appeared on any command
// line, so argument checks alone cannot catch this class. Allow roots
// (ZF_WORKER_WRITE_GUARD_ALLOW, the supervisor scratch) stay writable.
'use strict';

const fs = require('fs');
const path = require('path');
const { fileURLToPath } = require('url');

const resolveBase = (entry) => {
  try { return fs.realpathSync(entry); } catch { return path.resolve(entry); }
};
const ROOTS = (process.env.ZF_WORKER_WRITE_GUARD_ROOT || '')
  .split(path.delimiter).filter(Boolean).map(resolveBase);
const ALLOWS = (process.env.ZF_WORKER_WRITE_GUARD_ALLOW || '')
  .split(path.delimiter).filter(Boolean).map(resolveBase);

if (ROOTS.length > 0) {
  const asPath = (value) => {
    if (typeof value === 'string') return value;
    if (Buffer.isBuffer(value)) return value.toString();
    if (value && typeof value.href === 'string' && value.protocol === 'file:') {
      try { return fileURLToPath(value); } catch { return null; }
    }
    return null;
  };

  const under = (absolute, base) => absolute === base || absolute.startsWith(base + path.sep);

  // Resolve through symlinks: a link to a deployment file must not smuggle a write
  // past the root check. A not-yet-existing target resolves through its parent.
  const resolveReal = (absolute) => {
    try { return fs.realpathSync(absolute); } catch { /* target does not exist yet */ }
    try { return path.join(fs.realpathSync(path.dirname(absolute)), path.basename(absolute)); } catch { return absolute; }
  };

  const guardHit = (value) => {
    const raw = asPath(value);
    if (!raw) return null;
    const absolute = resolveReal(path.resolve(raw));
    if (ALLOWS.some((allow) => under(absolute, allow))) return null;
    return ROOTS.find((root) => under(absolute, root)) || null;
  };

  const refuse = (value) => {
    const shown = typeof value === 'object' && value !== null ? String(value) : value;
    throw new Error(
      `worker write guard: refusing write into the deployment checkout: ${shown} `
        + '(edit this unit\'s own worktree; deployment files change only through a landed PR)',
    );
  };

  const guardPath = (value) => {
    if (guardHit(value)) refuse(value);
  };

  const flagsWrite = (flags) => {
    if (flags === undefined || flags === null) return false;
    if (typeof flags === 'number') return (flags & 0x3) !== 0; // O_ACCMODE: O_WRONLY | O_RDWR
    return /[wax+]/.test(String(flags));
  };

  const wrap = (holder, name, check) => {
    const original = holder[name];
    if (typeof original !== 'function' || original.__zfWorkerWriteGuard) return;
    const patched = function patched(...args) {
      check(args);
      return original.apply(this, args);
    };
    patched.__zfWorkerWriteGuard = true;
    holder[name] = patched;
  };

  // [name] -> indices of the path arguments the call writes; the sync forms on fs
  // are derived (<name>Sync), promises carry only the async spelling. open also
  // inspects the flags so reads through the public fs API stay untouched.
  const WRITES = {
    appendFile: [0], chmod: [0], chown: [0], copyFile: [1], cp: [1], link: [1],
    lchmod: [0], lchown: [0], lutimes: [0], mkdir: [0], mkdtemp: [0], rename: [0, 1],
    rm: [0], rmdir: [0], symlink: [1], truncate: [0], unlink: [0], utimes: [0],
    writeFile: [0],
  };
  const pathCheck = (indices) => (args) => indices.forEach((index) => index < args.length && guardPath(args[index]));
  const flagsCheck = (args) => {
    if (flagsWrite(args[1])) guardPath(args[0]);
  };
  const patchHolder = (holder, name, check, withSync) => {
    const spellings = withSync ? [name, `${name}Sync`] : [name];
    for (const spelling of spellings) {
      if (typeof holder[spelling] === 'function') wrap(holder, spelling, check);
    }
  };
  for (const [name, indices] of Object.entries(WRITES)) {
    patchHolder(fs, name, pathCheck(indices), true);
    if (fs.promises) patchHolder(fs.promises, name, pathCheck(indices), false);
  }
  patchHolder(fs, 'open', flagsCheck, true);
  if (fs.promises) patchHolder(fs.promises, 'open', flagsCheck, false);
  try {
    const fsp = require('fs/promises');
    if (fsp !== fs.promises) {
      for (const [name, indices] of Object.entries(WRITES)) patchHolder(fsp, name, pathCheck(indices), false);
      patchHolder(fsp, 'open', flagsCheck, false);
    }
  } catch { /* fs/promises unavailable: the fs patches still hold */ }

  if (typeof fs.createWriteStream === 'function') {
    wrap(fs, 'createWriteStream', (args) => guardPath(args[0]));
  }
}
