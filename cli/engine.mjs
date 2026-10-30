// Versioned engine installs under ~/.zenoforge/engine/<version>/ with an atomically flipped `current`.
import fs from 'node:fs';
import path from 'node:path';

// npm pack drops symlinks, so the engine's PATH shim loses its links. Restored from this list;
// engine.test.mjs fails if the engine tree grows a symlink that is not listed.
// shortcut: fixed list, upgrade to a generated manifest when the engine gains more symlinks.
export const SHIM_DIR = 'non-product-test-shim';
export const SHIM_TARGET = 'command';
export const SHIM_NAMES = ['bash', 'node', 'pnpm', 'python', 'python3', 'sh'];

const INSTALL_META = '.install.json';

const readJson = (file) => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
};
const readLink = (p) => {
  try { return fs.readlinkSync(p); } catch { return null; }
};

export const currentVersion = (engineRoot) => readLink(path.join(engineRoot, 'current'));
export const previousVersion = (engineRoot) => readLink(path.join(engineRoot, 'previous'));

/** Pick the version dir name: reuse an identical install, else add a +N suffix for changed settings. */
export function pickName(engineRoot, version, settings) {
  for (let n = 1; ; n++) {
    const name = n === 1 ? version : `${version}+${n}`;
    const meta = readJson(path.join(engineRoot, name, INSTALL_META));
    if (!meta) return { name, reuse: false };
    if (JSON.stringify(meta.settings) === JSON.stringify(settings)) return { name, reuse: true };
  }
}

/**
 * Copy the packaged engine into a new immutable version dir and flip `current` to it.
 * `overlay` maps engine-relative paths to rendered text that replaces the packaged file.
 */
export function installEngine(act, { srcEngine, engineRoot, version, settings, overlay }) {
  const { name, reuse } = pickName(engineRoot, version, settings);
  const dest = path.join(engineRoot, name);
  if (!reuse) {
    const stage = `${dest}.stage-${process.pid}`;
    act.mkdir(engineRoot);
    act.copyTree(srcEngine, stage);
    for (const n of SHIM_NAMES) act.symlink(SHIM_TARGET, path.join(stage, SHIM_DIR, n));
    for (const [rel, text] of Object.entries(overlay)) act.write(path.join(stage, rel), text, { mode: modeOf(srcEngine, rel) });
    act.write(path.join(stage, INSTALL_META), `${JSON.stringify({ version, settings }, null, 2)}\n`);
    act.rename(stage, dest);
  }
  flipCurrent(act, engineRoot, name);
  return name;
}

/** Keep the file mode of the packaged file when an overlay replaces it. */
function modeOf(srcEngine, rel) {
  try { return fs.statSync(path.join(srcEngine, rel)).mode & 0o777; } catch { return 0o644; }
}

/** Point `current` at `name`; the old target becomes `previous` (the rollback target). */
export function flipCurrent(act, engineRoot, name) {
  const old = currentVersion(engineRoot);
  if (old === name) return;
  if (old) act.symlink(old, path.join(engineRoot, 'previous'));
  act.symlink(name, path.join(engineRoot, 'current'));
}

/** Swap current and previous. Returns the new current name, or null when there is nothing to roll back to. */
export function rollback(act, engineRoot) {
  const prev = previousVersion(engineRoot);
  const cur = currentVersion(engineRoot);
  if (!prev || !fs.existsSync(path.join(engineRoot, prev))) return null;
  act.symlink(prev, path.join(engineRoot, 'current'));
  if (cur) act.symlink(cur, path.join(engineRoot, 'previous'));
  return prev;
}

/** Remove version dirs that are neither current nor previous. */
export function pruneEngines(act, engineRoot) {
  const keep = new Set([currentVersion(engineRoot), previousVersion(engineRoot), 'current', 'previous']);
  let entries = [];
  try { entries = fs.readdirSync(engineRoot); } catch { return []; }
  const gone = entries.filter((e) => !keep.has(e));
  for (const e of gone) act.remove(path.join(engineRoot, e));
  return gone;
}
