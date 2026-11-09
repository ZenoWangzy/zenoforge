#!/usr/bin/env node
// The web-advisor-provider skill (ZF_WEB_ADVISOR_PROVIDER_SCRIPT, engine/config.sh) requires the page registry at
// startup via zfHostOpsFile('engine/cdp-page-registry.cjs'). With no host-ops copy the engine-dir fallback must
// resolve to a shipped file exposing the exports that skill destructures (2026-11-03: the pack shrink dropped it and
// a demo harness crashed on the require).
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { zfHostOpsFile } from './pack-dir.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fixture = mkdtempSync(join(tmpdir(), 'zf-cdp-registry-'));
// An empty host-ops root: the resolution must land on the engine dir's own copy, never on the host's.
process.env.ZF_HOST_OPS_DIR = join(fixture, 'host-ops');
try {
  const resolved = zfHostOpsFile('engine/cdp-page-registry.cjs');
  assert.equal(resolved, join(here, 'cdp-page-registry.cjs'), 'no host-ops copy falls back to the engine tree');
  const registry = createRequire(import.meta.url)(resolved);
  for (const name of ['registerCreatedPage', 'isRegisteredPage', 'retainCreatedPage', 'releaseCreatedPage'])
    assert.equal(typeof registry[name], 'function', `export ${name}`);
} finally {
  rmSync(fixture, { recursive: true, force: true });
}
console.log('cdp-page-registry.test.mjs: PASS');
