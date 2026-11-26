import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { resolveRuntimeDependency } from './runtime-dependencies.mjs';

test('runtime dependencies resolve when npm hoists them beside the CLI package', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'zf-runtime-deps-'));
  const packageRoot = path.join(root, 'node_modules', 'zenoforge');
  const dependencyRoot = path.join(root, 'node_modules', '@typesafe-ai', 'sdk');
  fs.mkdirSync(packageRoot, { recursive: true });
  fs.mkdirSync(dependencyRoot, { recursive: true });
  fs.writeFileSync(path.join(packageRoot, 'package.json'), '{"name":"zenoforge"}\n');
  fs.writeFileSync(path.join(dependencyRoot, 'package.json'), '{"name":"@typesafe-ai/sdk","exports":{"./package.json":"./package.json"}}\n');

  try {
    assert.equal(resolveRuntimeDependency(packageRoot, '@typesafe-ai/sdk'), dependencyRoot);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
