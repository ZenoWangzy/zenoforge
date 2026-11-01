#!/usr/bin/env bash
# run-ci-suites.sh selects and executes local, shard or nightly suites.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT
runner="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/run-ci-suites.sh"
grep -qF -- "-name '*.test.sh'" "$runner"
grep -qF -- "-name 'test-*.sh'" "$runner"
grep -qF -- "! -name 'test-env.sh'" "$runner"
grep -qF -- "-name '*.test.mjs'" "$runner"
grep -qF 'node --test --test-concurrency=1 "$suite"' "$runner"
grep -qF 'source "$SCRIPT_DIR/config.sh"' "$runner"
grep -qF 'zf_config_file ci.json' "$runner"
grep -qF 'find "$suite_root"' "$runner"
grep -qF 'suite_jobs="${RUN_CI_SUITES_JOBS:-1}"' "$runner"
grep -qF 'nightly_suite_paths=(' "$runner"
grep -qF 'engine/land-direct-main.test.sh' "$runner"
grep -qF 'product_timers_policy="$(zf_config_file systemd/pipeline-timers.list || true)"' "$runner"
grep -qF 'find "$product_systemd_dir" -maxdepth 1 -type f' "$runner"
grep -qF 'run-ci-suites.sh [--shard INDEX/COUNT | --nightly]' "$runner"
grep -qF 'if [[ ! "$suite_jobs" =~ ^[1-4]$ ]]' "$runner"
grep -qF 'if ((suite_count == 0)); then' "$runner"
grep -qF 'xargs -0 -r -n1 -P "$suite_jobs"' "$runner"
grep -qF 'duration=' "$runner"
grep -qF "! -path 'engine/run-release.test.sh'" "$runner"

# Execution belongs to the runner's own lane, not deploy-regression-contract.
# Only synthetic suites run below. The real discovery/execution loop must run
# the selected suites and propagate their failures.
node --input-type=module - "$runner" <<'NODE'
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';

const runnerSource = readFileSync(process.argv[2], 'utf8');
const configSource = readFileSync(join(dirname(process.argv[2]), 'config.sh'), 'utf8');
const releaseSuites = [
  ['engine/run-release-suite-postdeploy.test.sh', 'release-postdeploy'],
  ['engine/run-release-suite-reconcile.test.sh', 'release-reconcile'],
  ['engine/run-release-suite-release-entry.test.sh', 'release-entry'],
  ['engine/run-release-suite-rollback.test.sh', 'release-rollback'],
];
const lastReleaseSuite = releaseSuites.at(-1)[0];
const expected = ['nested-node', 'nested-shell', ...releaseSuites.map(([, name]) => name)].sort();
const nightlySuites = [
  ['engine/land-direct-main.test.sh', 'nightly-land-direct'],
  ['engine/run-advisor.test.sh', 'nightly-advisor'],
];
const expectedNightly = nightlySuites.map(([, name]) => name);
const bash = ['/opt/homebrew/bin/bash', '/usr/local/bin/bash', 'bash'].find(command => {
  const result = spawnSync(command, ['--version'], { encoding: 'utf8', timeout: 5000 });
  return result.status === 0 && /GNU bash, version (?:[4-9]|\d{2,})\./.test(result.stdout);
});
assert.ok(bash, 'Pipeline suite discovery requires Bash 4+');

function runFixture({ runner = runnerSource, shellExit = 0, nodeExit = 0, emptySuites = false, shard, tier, includeNightlySuites = false, includeNightlyViaEnv = false, includeMovedNightlySuite = false, includeNightTest = false, includeLoadFixtures = false, includeConfiguredSuites = false, includeProductSystemdSuite = false, emptyProductSystemd = false, shellFailures = [], slowSuite, leakSuite = false } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'pipeline-runner-fixture-'));
  const log = join(root, 'executed.log');
  const preflightLog = join(root, 'preflights.log');
  const put = (file, content) => {
    const path = join(root, file);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, content, { mode: 0o755 });
  };
  try {
    put('engine/run-ci-suites.sh', runner);
    put('engine/config.sh', configSource);
    put('engine/check-rulings.sh', `#!/bin/sh\nprintf 'rulings\n' >> '${preflightLog}'\n`);
    put('engine/test-env.sh', '#!/bin/sh\nexit 91\n');
    put('scripts/ops/ops-only.test.sh', '#!/bin/sh\nprintf "ops-only\\n" >> "$PIPELINE_FIXTURE_LOG"\n');
    put('scripts/ops/reclaim-disk.test.sh', '#!/bin/sh\nprintf "reclaim-weight\\n" >> "$PIPELINE_FIXTURE_LOG"\n');
    put('scripts/checks/check-only.test.mjs', 'import {appendFileSync} from "node:fs"; appendFileSync(process.env.PIPELINE_FIXTURE_LOG, "check-only\\n");\n');
    if (includeConfiguredSuites) {
      put('.zenoforge/ci.json', JSON.stringify({ pipeline_suite_roots: ['scripts/ops', 'scripts/checks'] }));
    }
    if (includeProductSystemdSuite || emptyProductSystemd) {
      mkdirSync(join(root, '.zenoforge/systemd'), { recursive: true });
      put('.zenoforge/systemd/pipeline-timers.list', '# product timer policy fixture\n');
    }
    if (includeProductSystemdSuite) {
      put('.zenoforge/systemd/product-suite.test.sh', '#!/bin/sh\nprintf "product-systemd\\n" >> "$PIPELINE_FIXTURE_LOG"\n');
    }
    if (!emptySuites) {
      put('engine/run-release.test.sh', '#!/bin/sh\nprintf "release\\n" >> "$PIPELINE_FIXTURE_LOG"\nprintf "%s\\n" "$TMPDIR" >> "$PIPELINE_FIXTURE_TMP_LOG"\n');
      for (const [path, name] of releaseSuites) {
        put(path, `#!/bin/sh\nprintf "%s\\n" "${name}" >> "$PIPELINE_FIXTURE_LOG"\nprintf "%s\\n" "$TMPDIR" >> "$PIPELINE_FIXTURE_TMP_LOG"\n`);
      }
      put('engine/nested/test-child.sh', `#!/bin/sh\nprintf "nested-shell\\n" >> "$PIPELINE_FIXTURE_LOG"\nprintf "%s\\n" "$TMPDIR" >> "$PIPELINE_FIXTURE_TMP_LOG"\nexit ${shellExit}\n`);
      put('engine/nested/child.test.mjs', `import {appendFileSync} from "node:fs"; appendFileSync(process.env.PIPELINE_FIXTURE_LOG, "nested-node\\n"); process.exit(${nodeExit});\n`);
    }
    if (includeNightlySuites) {
      for (const [path, name] of nightlySuites) {
        put(path, `#!/bin/sh\nprintf "%s\\n" "${name}" >> "$PIPELINE_FIXTURE_LOG"\n`);
      }
    }
    if (includeMovedNightlySuite) {
      put('engine/run-advisor.test.sh', '#!/bin/sh\nprintf "nightly-advisor\\n" >> "$PIPELINE_FIXTURE_LOG"\n');
      put('scripts/ci/land-direct-main.test.sh', '#!/bin/sh\nprintf "nightly-land-direct\\n" >> "$PIPELINE_FIXTURE_LOG"\n');
      put('.zenoforge/ci.json', JSON.stringify({ pipeline_suite_roots: ['scripts/ci'] }));
    }
    if (includeNightTest) {
      put('engine/night/night.test.sh', '#!/bin/sh\nprintf "night-test\\n" >> "$PIPELINE_FIXTURE_LOG"\n');
    }
    if (includeLoadFixtures) {
      put('engine/night/night.test.sh', '#!/bin/sh\nprintf "night-test\\n" >> "$PIPELINE_FIXTURE_LOG"\n');
      put('engine/lib.test.sh', '#!/bin/sh\nprintf "lib-test\\n" >> "$PIPELINE_FIXTURE_LOG"\n');
    }
    for (const { name, exitCode, lines } of shellFailures) {
      const output = lines.map(line => "printf '%s\\n' '" + line + "'").join('\n');
      put('engine/nested/test-' + name + '.sh',
        '#!/bin/sh\nprintf "%s\\n" "shell-' + name + '" >> "$PIPELINE_FIXTURE_LOG"\n' + output + '\nexit ' + exitCode + '\n');
    }
    if (slowSuite) {
      // Descendant ignores TERM; runner must kill its own process group.
      const slow = 'require("node:fs").writeFileSync(process.env.PIPELINE_FIXTURE_PID_FILE, String(process.pid)); process.on("SIGTERM", () => {}); setInterval(() => {}, 100);';
      const slowModule = 'import { writeFileSync } from "node:fs"; writeFileSync(process.env.PIPELINE_FIXTURE_PID_FILE, String(process.pid)); process.on("SIGTERM", () => {}); setInterval(() => {}, 100);';
      if (slowSuite === 'shell') {
        put('engine/nested/test-a-slow.sh', `#!/bin/sh\nnode -e '${slow}' &\nwait\n`);
      } else {
        put('engine/nested/a-slow.test.mjs', slowModule);
      }
    }
    if (leakSuite) {
      // The suite passes, but a background child keeps the runner's output pipe open after it exits.
      put('engine/nested/test-a-leak.sh', '#!/bin/sh\nsleep 60 &\necho $! > "$PIPELINE_FIXTURE_PID_FILE"\nexit 0\n');
    }
    const tmpLog = join(root, 'suite-tmps.log');
    const pidFile = join(root, 'slow.pid');
    const args = [
      'engine/run-ci-suites.sh',
      ...(tier === 'nightly' ? ['--nightly'] : shard ? ['--shard', shard] : []),
    ];
    const result = spawnSync(bash, args, {
      cwd: root, encoding: 'utf8', timeout: slowSuite || leakSuite ? 8000 : 15000,
      env: {
        PATH: `${join(root, 'bin')}:${process.env.PATH}`,
        HOME: root,
        PIPELINE_FIXTURE_LOG: log,
        PIPELINE_FIXTURE_TMP_LOG: tmpLog,
        PIPELINE_FIXTURE_PID_FILE: pidFile,
        ...(includeNightlyViaEnv ? { RUN_CI_SUITES_INCLUDE_NIGHTLY: '1' } : {}),
      },
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, result.stderr);
    if (slowSuite || leakSuite) {
      assert.ok(existsSync(pidFile), 'slow child must start');
      const pid = readFileSync(pidFile, 'utf8');
      const stat = `/proc/${pid}/stat`;
      if (existsSync(stat)) assert.match(readFileSync(stat, 'utf8'), /\) Z /, 'timed-out descendant still running');
    }
    const temporaryPaths = existsSync(tmpLog) ? readFileSync(tmpLog, 'utf8').trim().split('\n') : [];
    for (const path of temporaryPaths) assert.equal(existsSync(path), false, `suite scratch remains: ${path}`);
    return {
      ...result,
      executed: existsSync(log) ? readFileSync(log, 'utf8').trim().split('\n') : [],
      temporaryPaths,
      preflights: existsSync(preflightLog) ? readFileSync(preflightLog, 'utf8').trim().split('\n') : [],
    };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function requireCompleteExecution(result) {
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.deepEqual([...result.executed].sort(), expected);
  assert.equal(result.temporaryPaths.length, releaseSuites.length + 1);
}

test('runner executes split release suites and omits the unsplit runner, not test-env', () => {
  const result = runFixture();
  requireCompleteExecution(result);
  assert.ok(result.stdout.includes('engine/run-release-suite-release-entry.test.sh timeout=1260s'), result.stdout);
  assert.ok(result.stdout.includes('engine/run-release-suite-rollback.test.sh timeout=1230s'), result.stdout);
  assert.ok(result.stdout.includes('engine/run-release-suite-postdeploy.test.sh timeout=1500s'), result.stdout);
  assert.ok(result.stdout.includes('engine/run-release-suite-reconcile.test.sh timeout=1200s'), result.stdout);
  assert.doesNotMatch(result.stdout, /done suite=engine\/run-release\.test\.sh/);
  assert.ok(result.stdout.includes('engine/nested/test-child.sh timeout=300s'), result.stdout);
});

test('configured repository suite roots join the pipeline lane', () => {
  const result = runFixture({ includeConfiguredSuites: true });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.deepEqual([...result.executed].sort(), [...expected, 'ops-only', 'reclaim-weight', 'check-only'].sort());
  assert.ok(result.stdout.includes('scripts/ops/reclaim-disk.test.sh timeout=435s'), result.stdout);
});

test('runner discovers systemd tests from config and tolerates an empty config directory', () => {
  const included = runFixture({ includeProductSystemdSuite: true });
  assert.equal(included.status, 0, `${included.stderr}\n${included.stdout}`);
  assert.deepEqual([...included.executed].sort(), [...expected, 'product-systemd'].sort());

  const empty = runFixture({ emptyProductSystemd: true });
  assert.equal(empty.status, 0, `${empty.stderr}\n${empty.stdout}`);
  assert.deepEqual([...empty.executed].sort(), expected);
});

test('night suite timeout matches the measured full-run weight', () => {
  const result = runFixture({ includeNightTest: true });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.deepEqual([...result.executed].sort(), [...expected, 'night-test'].sort());
  assert.ok(result.stdout.includes('engine/night/night.test.sh timeout=3276s'), result.stdout);
});

test('unsharded local run omits nightly suites by default', () => {
  const result = runFixture({ includeNightlySuites: true });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.deepEqual([...result.executed].sort(), expected);
});

test('RUN_CI_SUITES_INCLUDE_NIGHTLY retains the full local suite set', () => {
  const result = runFixture({ includeNightlySuites: true, includeNightlyViaEnv: true });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.deepEqual([...result.executed].sort(), [...expected, ...expectedNightly].sort());
});

test('shards omit nightly suites and run every PR-tier suite once', () => {
  const results = [
    runFixture({ shard: '0/2', includeNightlySuites: true }),
    runFixture({ shard: '1/2', includeNightlySuites: true }),
  ];
  for (const result of results) assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.deepEqual(results.flatMap(result => result.preflights), ['rulings']);
  const executed = results.flatMap(result => result.executed);
  assert.deepEqual([...executed].sort(), expected);
  assert.equal(new Set(executed).size, expected.length);
});

test('release stage suites occupy four different shards alongside the heavy shared suites', () => {
  const results = Array.from({ length: 5 }, (_, index) =>
    runFixture({ shard: `${index}/5`, includeLoadFixtures: true }));
  for (const result of results) assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  const executed = results.flatMap(result => result.executed);
  assert.deepEqual([...executed].sort(), [...expected, 'lib-test', 'night-test'].sort());
  assert.equal(new Set(executed).size, executed.length);

  const releaseShardIndexes = releaseSuites.map(([, name]) =>
    results.findIndex(result => result.executed.includes(name)));
  assert.ok(releaseShardIndexes.every(index => index >= 0), 'every release suite is scheduled');
  assert.equal(new Set(releaseShardIndexes).size, releaseSuites.length,
    `release suite shard indexes: ${releaseShardIndexes.join(', ')}`);
});

test('--nightly runs every migrated suite and excludes the PR tier', () => {
  const result = runFixture({ tier: 'nightly', includeNightlySuites: true });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.deepEqual([...result.executed].sort(), [...expectedNightly].sort());
});

test('--nightly finds a moved suite under a configured root by its basename', () => {
  const result = runFixture({ tier: 'nightly', includeMovedNightlySuite: true });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.deepEqual([...result.executed].sort(), [...expectedNightly].sort());
  assert.ok(result.stdout.includes('scripts/ci/land-direct-main.test.sh timeout=471s'), result.stdout);
});

test('--nightly fails closed if a migrated suite is missing', () => {
  const result = runFixture({ tier: 'nightly' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /nightly suite is missing or not scheduled/);
  assert.deepEqual(result.executed, []);
});

test('runner reports shell failure and still runs remaining shell and node suites', () => {
  const serialRunner = runnerSource.replace('suite_jobs="' + '$' + '{RUN_CI_SUITES_JOBS:-1}"', 'suite_jobs=1');
  assert.notEqual(serialRunner, runnerSource);
  const result = runFixture({ runner: serialRunner, shellExit: 37 });
  // xargs reports an aggregate failure; remaining suites must still run.
  assert.ok(Number.isInteger(result.status) && result.status > 0, result.stderr);
  assert.deepEqual([...result.executed].sort(), expected);
  const summary = '[pipeline suites] FAILED suite=engine/nested/test-child.sh exit_code=37 first_error=no matching failure evidence';
  assert.ok(result.stdout.endsWith(summary + '\n'), result.stdout + '\n' + result.stderr);
  assert.ok(result.stdout.indexOf(`done suite=${lastReleaseSuite}`) < result.stdout.indexOf(summary), result.stdout);
});

test('runner summarizes every failed child at shard end with raw exits and first evidence', () => {
  const serialRunner = runnerSource.replace('suite_jobs="' + '$' + '{RUN_CI_SUITES_JOBS:-1}"', 'suite_jobs=1');
  const result = runFixture({
    runner: serialRunner,
    shellFailures: [
      { name: 'a-fail', exitCode: 37, lines: ['setup output', 'FAIL: synthetic first error', 'ERROR: later error'] },
      { name: 'z-fail', exitCode: 6, lines: ['plain output without a failure marker'] },
    ],
  });
  assert.ok(Number.isInteger(result.status) && result.status > 0, result.stderr);
  assert.deepEqual([...result.executed].sort(), [...expected, 'shell-a-fail', 'shell-z-fail']);
  const summary = [
    '[pipeline suites] FAILED suite=engine/nested/test-a-fail.sh exit_code=37 first_error=FAIL: synthetic first error',
    '[pipeline suites] FAILED suite=engine/nested/test-z-fail.sh exit_code=6 first_error=no matching failure evidence',
  ];
  const lines = result.stdout.trimEnd().split('\n');
  assert.deepEqual(lines.slice(-2), summary, result.stdout + '\n' + result.stderr);
  assert.ok(lines.at(-3).includes('shell suites duration='), result.stdout);
  assert.ok(result.stdout.indexOf(`done suite=${lastReleaseSuite}`) < result.stdout.indexOf(summary[0]), result.stdout);
});

test('runner propagates node suite failure after shell suites ran', () => {
  const result = runFixture({ nodeExit: 38 });
  assert.ok(result.status > 0, `${result.stderr}\n${result.stdout}`);
  assert.deepEqual([...result.executed].sort(), expected);
});

for (const kind of ['shell', 'node']) {
  test(`${kind} timeout names failed suite, kills descendants and continues shard`, () => {
    const shortRunner = runnerSource.replace('suite_timeout_floor=300', 'suite_timeout_floor=3')
      .replace('suite_timeout_multiplier=3', 'suite_timeout_multiplier=0');
    const result = runFixture({ runner: shortRunner, slowSuite: kind });
    assert.ok(result.status > 0, result.stdout);
    assert.deepEqual([...result.executed].sort(), expected);
    const suite = kind === 'shell' ? 'nested/test-a-slow.sh' : 'nested/a-slow.test.mjs';
    assert.ok(result.stdout.includes(`suite engine/${suite} timed out after 3s`), result.stdout);
  });
}

test('runner kills a descendant that outlives a passing suite instead of waiting on the output pipe', () => {
  const result = runFixture({ leakSuite: true });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.deepEqual([...result.executed].sort(), expected);
  assert.ok(result.stdout.includes('engine/nested/test-a-leak.sh left running descendants'), result.stdout);
});


test('runner rejects zero discovered suites instead of reporting success', () => {
  const result = runFixture({ emptySuites: true });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /No pipeline test suites found/);
  assert.deepEqual(result.executed, []);
});

for (const [kind, execution] of [
  ['shell', 'LC_ALL=C TMPDIR="$suite_tmp" timeout --verbose -s KILL "$suite_timeout" bash "$suite"'],
  ['node', 'LC_ALL=C TMPDIR="$suite_tmp" timeout --verbose -s KILL "$suite_timeout" node --test --test-concurrency=1 "$suite"'],
]) {
  test(`execution proof rejects a runner mutated to omit ${kind} invocation`, () => {
    const mutated = runnerSource.replace(execution, '  true');
    assert.notEqual(mutated, runnerSource, 'mutation must change the actual invocation');
    const result = runFixture({ runner: mutated });
    assert.equal(result.status, 0, result.stderr);
    assert.throws(() => requireCompleteExecution(result), assert.AssertionError);
  });
}
NODE

echo 'run-ci-suites.test.sh: PASS'
