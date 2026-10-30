import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { currentVersion, flipCurrent, installEngine, pickName, previousVersion, pruneEngines, rollback, SHIM_DIR, SHIM_NAMES, SHIM_TARGET } from './engine.mjs';
import { Actions } from './util.mjs';

const realEngine = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'engine');
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'zf-engine-'));

function fakeEngine(root) {
  fs.mkdirSync(path.join(root, 'systemd'), { recursive: true });
  fs.mkdirSync(path.join(root, SHIM_DIR), { recursive: true });
  fs.writeFileSync(path.join(root, 'run-tick.sh'), '#!/bin/sh\n', { mode: 0o755 });
  fs.writeFileSync(path.join(root, 'systemd', 'a.service'), 'shipped\n');
  fs.writeFileSync(path.join(root, SHIM_DIR, SHIM_TARGET), '#!/bin/sh\n', { mode: 0o755 });
}
const quiet = () => new Actions({ log: () => {} });
const install = (act, o) => installEngine(act, { overlay: { 'systemd/a.service': 'rendered\n' }, ...o });

test('install copies, applies the overlay, restores shim links and flips current', () => {
  const src = tmp(); const root = path.join(tmp(), 'engine'); fakeEngine(src);
  const name = install(quiet(), { srcEngine: src, engineRoot: root, version: '0.1.0', settings: { a: 1 } });
  assert.equal(name, '0.1.0');
  assert.equal(currentVersion(root), '0.1.0');
  assert.equal(fs.readFileSync(path.join(root, 'current', 'systemd', 'a.service'), 'utf8'), 'rendered\n');
  assert.equal(fs.readFileSync(path.join(src, 'systemd', 'a.service'), 'utf8'), 'shipped\n', 'package copy untouched');
  for (const n of SHIM_NAMES) assert.equal(fs.readlinkSync(path.join(root, 'current', SHIM_DIR, n)), SHIM_TARGET);
  assert.ok(fs.statSync(path.join(root, 'current', 'run-tick.sh')).mode & 0o111, 'exec bit kept');
  assert.deepEqual(fs.readdirSync(root).filter((e) => e.includes('stage')), [], 'no staging dir left behind');
});

test('same settings reuse the version dir; changed settings get a +N dir', () => {
  const src = tmp(); const root = path.join(tmp(), 'engine'); fakeEngine(src);
  install(quiet(), { srcEngine: src, engineRoot: root, version: '0.1.0', settings: { a: 1 } });
  assert.deepEqual(pickName(root, '0.1.0', { a: 1 }), { name: '0.1.0', reuse: true });
  assert.equal(install(quiet(), { srcEngine: src, engineRoot: root, version: '0.1.0', settings: { a: 1 } }), '0.1.0');
  assert.equal(install(quiet(), { srcEngine: src, engineRoot: root, version: '0.1.0', settings: { a: 2 } }), '0.1.0+2');
  assert.equal(currentVersion(root), '0.1.0+2');
  assert.equal(previousVersion(root), '0.1.0');
});

test('flip, rollback and prune keep exactly current and previous', () => {
  const src = tmp(); const root = path.join(tmp(), 'engine'); fakeEngine(src);
  const act = quiet();
  for (const v of ['0.1.0', '0.2.0', '0.3.0']) install(act, { srcEngine: src, engineRoot: root, version: v, settings: { v } });
  assert.equal(currentVersion(root), '0.3.0');
  assert.equal(previousVersion(root), '0.2.0');
  assert.deepEqual(pruneEngines(act, root), ['0.1.0']);
  assert.equal(rollback(act, root), '0.2.0');
  assert.equal(currentVersion(root), '0.2.0');
  assert.equal(previousVersion(root), '0.3.0');
  flipCurrent(act, root, '0.2.0'); // flipping to what is already current changes nothing
  assert.equal(previousVersion(root), '0.3.0');
});

test('rollback with no previous version reports it', () => {
  const src = tmp(); const root = path.join(tmp(), 'engine'); fakeEngine(src);
  install(quiet(), { srcEngine: src, engineRoot: root, version: '0.1.0', settings: {} });
  assert.equal(rollback(quiet(), root), null);
});

test('dry run touches nothing', () => {
  const src = tmp(); const root = path.join(tmp(), 'engine'); fakeEngine(src);
  const lines = [];
  install(new Actions({ dryRun: true, log: (l) => lines.push(l) }), { srcEngine: src, engineRoot: root, version: '0.1.0', settings: {} });
  assert.equal(fs.existsSync(root), false);
  assert.ok(lines.some((l) => l.includes('COPY')) && lines.some((l) => l.includes('LINK') && l.includes('current')));
});

test('every symlink in the packaged engine is one the installer restores (npm pack drops symlinks)', () => {
  const found = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isSymbolicLink()) found.push(path.relative(realEngine, p));
      else if (e.isDirectory()) walk(p);
    }
  };
  walk(realEngine);
  assert.deepEqual(found.sort(), SHIM_NAMES.map((n) => path.join(SHIM_DIR, n)).sort());
});
