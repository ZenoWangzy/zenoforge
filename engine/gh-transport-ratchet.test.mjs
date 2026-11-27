import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('..', import.meta.url));
const scanner = join(root, 'tools/gh-transport-ratchet.mjs');
const baseline = 'tools/gh-transport-baseline.txt';
const baselineHeader = '# gh transport baseline: one unwrapped script path per line; remove entries as callers load the wrapper.\n';

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'gh-transport-ratchet-'));
  mkdirSync(join(dir, 'engine'), { recursive: true });
  mkdirSync(join(dir, 'engine/lib.d'), { recursive: true });
  mkdirSync(join(dir, 'tools'), { recursive: true });
  writeFileSync(join(dir, 'engine/lib.d/transport.sh'), '#!/usr/bin/env bash\n');
  writeFileSync(join(dir, baseline), baselineHeader);
  return dir;
}

function write(dir, path, content) {
  const target = join(dir, path);
  mkdirSync(join(target, '..'), { recursive: true });
  writeFileSync(target, content);
}

function run(dir, ...args) {
  return spawnSync(process.execPath, [scanner, ...args, '--root', dir], { encoding: 'utf8' });
}

test('new gh callers fail with a wrapper and load instruction', (t) => {
  const dir = fixture();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  write(dir, 'engine/known.sh', '#!/usr/bin/env bash\ngh issue view 1\n');
  write(dir, 'engine/new.sh', '#!/usr/bin/env bash\ngh api repos/example/repo\n');
  write(dir, 'engine/late-loader.sh', '#!/usr/bin/env bash\ngh api repos/example/repo\nsource "$SCRIPT_DIR/lib.d/transport.sh"\n');
  write(dir, 'engine/here-doc-loader.sh', '#!/usr/bin/env bash\ncat <<\'DOC\'\nsource "$ENGINE_DIR/lib.d/transport.sh"\nDOC\ngh api repos/example/repo\n');
  write(dir, 'engine/unicode-loader.sh', '#!/usr/bin/env bash\nprintf \'传输模块\\n\' >/dev/null\nENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"\nsource "$ENGINE_DIR/lib.d/transport.sh"\ngh api repos/example/repo\n');
  write(dir, 'engine/function-loader.sh', '#!/usr/bin/env bash\nload_transport() { source "$ENGINE_DIR/lib.d/transport.sh"; }\ngh api repos/example/repo\n');
  write(dir, 'engine/conditional-loader.sh', '#!/usr/bin/env bash\nif false; then source "$ENGINE_DIR/lib.d/transport.sh"; fi\ngh api repos/example/repo\n');
  write(dir, 'engine/short-circuit-loader.sh', '#!/usr/bin/env bash\nfalse && source "$ENGINE_DIR/lib.d/transport.sh"\ngh api repos/example/repo\n');
  write(dir, 'engine/global-gh-options.sh', '#!/usr/bin/env bash\ngh --repo example/repo api repos/example/repo\n');
  write(dir, 'engine/unassigned-engine-dir.sh', '#!/usr/bin/env bash\nsource "$ENGINE_DIR/lib.sh" || true\ngh api repos/example/repo\n');
  write(dir, 'engine/empty-engine-dir.sh', '#!/usr/bin/env bash\nENGINE_DIR=""\nsource "$ENGINE_DIR/lib.sh" || true\ngh api repos/example/repo\n');
  write(dir, 'engine/relative-engine-dir.sh', '#!/usr/bin/env bash\nENGINE_DIR=.\nsource "$ENGINE_DIR/lib.sh" || true\ngh api repos/example/repo\n');
  write(dir, 'engine/lib.sh', '#!/usr/bin/env bash\n_AGENT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"\nsource "$_AGENT_LIB_DIR/lib.d/transport.sh"\n');
  write(dir, 'engine/wrapped-command.sh', '#!/usr/bin/env bash\nenv SERVICE=1 gh api repos/example/repo\ntimeout 5 gh api repos/example/repo\n');
  write(dir, baseline, `${baselineHeader}engine/known.sh\n`);

  const result = run(dir);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /FAIL engine\/new\.sh/);
  assert.match(result.stdout, /FAIL engine\/late-loader\.sh/);
  assert.match(result.stdout, /FAIL engine\/here-doc-loader\.sh/);
  assert.doesNotMatch(result.stdout, /FAIL engine\/unicode-loader\.sh/);
  assert.match(result.stdout, /FAIL engine\/function-loader\.sh/);
  assert.match(result.stdout, /FAIL engine\/conditional-loader\.sh/);
  assert.match(result.stdout, /FAIL engine\/short-circuit-loader\.sh/);
  assert.match(result.stdout, /FAIL engine\/global-gh-options\.sh/);
  assert.match(result.stdout, /FAIL engine\/unassigned-engine-dir\.sh/);
  assert.match(result.stdout, /FAIL engine\/empty-engine-dir\.sh/);
  assert.match(result.stdout, /FAIL engine\/relative-engine-dir\.sh/);
  assert.match(result.stdout, /FAIL engine\/wrapped-command\.sh/);
  assert.match(result.stdout, /git -C/);
  assert.match(result.stdout, /BASH_SOURCE/);
  assert.match(result.stdout, /source .*lib\.d\/transport\.sh/);
});

test('transport loads and library sources are not offenders', (t) => {
  const dir = fixture();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  write(dir, 'engine/lib.sh', '#!/usr/bin/env bash\n_AGENT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"\nprintf \'传输模块\\n\' >/dev/null\nsource "$_AGENT_LIB_DIR/lib.d/transport.sh"\nsource "$_AGENT_LIB_DIR/lib.d/sourced.sh"\nsource "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/loaded-helper.sh"\n');
  write(dir, 'engine/lib.d/sourced.sh', 'gh api repos/example/repo\n');
  write(dir, 'engine/loaded-helper.sh', '#!/usr/bin/env bash\ngh api repos/example/repo\n');
  write(dir, 'engine/subdir/uses-parent-lib.sh', '#!/usr/bin/env bash\nunused=\nSCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"\nsource "$SCRIPT_DIR/lib.sh"\ngh issue view 1\n');
  write(dir, 'engine/default-engine-path.sh', '#!/usr/bin/env bash\nROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"\nZF_ENGINE_DIR="$ROOT/engine"\nENGINE_DIR="${ZF_ENGINE_DIR:-$ROOT/engine}"\nsource "$ENGINE_DIR/lib.sh"\ngh issue view 1\n');
  write(dir, 'engine/mac-autopilot/bell.sh', '#!/usr/bin/env bash\nENGINE_DIR="${ZF_ENGINE_DIR:-$ROOT/engine}"\nsource "$ENGINE_DIR/lib.d/transport.sh"\ngh issue view 1\n');
  write(dir, 'engine/uses-lib.sh', '#!/usr/bin/env bash\nSCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"\nsource "$SCRIPT_DIR/lib.sh"\ngh issue view 1\n');
  write(dir, 'engine/uses-guarded-lib.sh', '#!/usr/bin/env bash\nENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"\nif ! declare -F agent_epoch >/dev/null; then source "$ENGINE_DIR/lib.sh"; fi\ngh issue view 1\n');
  write(dir, 'tools/uses-transport.sh', '#!/usr/bin/env bash\nROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"\nsource "$ROOT/engine/lib.d/transport.sh"\ngh pr view 1\n');
  write(dir, 'tools/documentation.sh', '#!/usr/bin/env bash\necho "gh api repos/example/repo"\ncommand echo gh api repos/example/repo\nenv MESSAGE=gh api\ntimeout 5 echo gh api repos/example/repo\n# gh issue view 1\n');

  const result = run(dir);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /gh-transport-ratchet ok/);
});

test('an unrelated or incomplete library load does not satisfy the wrapper load', (t) => {
  const dir = fixture();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  write(dir, 'engine/lib.sh', '#!/usr/bin/env bash\n');
  rmSync(join(dir, 'engine/lib.d/transport.sh'));
  write(dir, 'engine/other/lib.sh', '#!/usr/bin/env bash\n');
  write(dir, 'engine/other/engine/lib.sh', '#!/usr/bin/env bash\n');
  write(dir, 'engine/unrelated-lib-loader.sh', '#!/usr/bin/env bash\nSCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"\nOTHER_DIR="$SCRIPT_DIR/other"\nsource "$OTHER_DIR/lib.sh"\ngh api repos/example/repo\n');
  write(dir, 'engine/unrelated-engine-root-loader.sh', '#!/usr/bin/env bash\nSCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"\nOTHER_ROOT="$SCRIPT_DIR/other"\nsource "$OTHER_ROOT/engine/lib.sh"\ngh api repos/example/repo\n');
  write(dir, 'engine/library-without-transport.sh', '#!/usr/bin/env bash\nENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"\nsource "$ENGINE_DIR/lib.sh"\ngh api repos/example/repo\n');
  write(dir, 'engine/missing-transport-loader.sh', '#!/usr/bin/env bash\nENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"\nsource "$ENGINE_DIR/lib.d/transport.sh" || true\ngh api repos/example/repo\n');

  const result = run(dir);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /FAIL engine\/unrelated-lib-loader\.sh/);
  assert.match(result.stdout, /FAIL engine\/unrelated-engine-root-loader\.sh/);
  assert.match(result.stdout, /FAIL engine\/library-without-transport\.sh/);
  assert.match(result.stdout, /FAIL engine\/missing-transport-loader\.sh/);
});

test('tightening removes cleared entries and refuses to admit a new caller', (t) => {
  const dir = fixture();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  write(dir, baseline, `${baselineHeader}engine/cleared.sh\n`);

  const tightened = run(dir, '--tighten');
  assert.equal(tightened.status, 0, tightened.stdout + tightened.stderr);
  assert.equal(readFileSync(join(dir, baseline), 'utf8'), baselineHeader);

  write(dir, 'engine/new.sh', '#!/usr/bin/env bash\ngh api repos/example/repo\n');
  const before = readFileSync(join(dir, baseline), 'utf8');
  const refused = run(dir, '--tighten');
  assert.equal(refused.status, 1, refused.stdout + refused.stderr);
  assert.match(refused.stdout, /FAIL engine\/new\.sh/);
  assert.equal(readFileSync(join(dir, baseline), 'utf8'), before);
});

test('the committed baseline cannot gain entries', (t) => {
  const dir = fixture();
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  execFileSync('git', ['init', '-q', '-b', 'main', dir]);
  execFileSync('git', ['-C', dir, 'config', 'user.name', 'Ratchet Test']);
  execFileSync('git', ['-C', dir, 'config', 'user.email', 'ratchet-test@example.invalid']);
  write(dir, baseline, `${baselineHeader}engine/known.sh\n`);
  execFileSync('git', ['-C', dir, 'add', baseline]);
  execFileSync('git', ['-C', dir, 'commit', '-q', '-m', 'baseline']);
  write(dir, baseline, `${baselineHeader}engine/known.sh\nengine/new.sh\n`);

  const result = run(dir, '--base', 'main');
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /may only shrink/);
  assert.match(result.stdout, /engine\/new\.sh/);
});

test('CI runs the transport check once on shard zero', () => {
  const workflow = readFileSync(join(root, '.github/workflows/engine-tests.yml'), 'utf8');
  assert.match(workflow, /name: Check GitHub transport ratchet/);
  assert.match(workflow, /if: \$\{\{ matrix\.shard == 0 \}\}/);
  assert.match(workflow, /node tools\/gh-transport-ratchet\.mjs --base FETCH_HEAD/);
});
