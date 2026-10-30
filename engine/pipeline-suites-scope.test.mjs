import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import { CROSS_SCRIPT_TESTS, focusedTestPaths, RELATED_TESTS } from './focused-test-paths.mjs';
import { FULL_SUITE_PATHS, pipelineSuiteScope, SUITE_PATH_COVERAGE } from './pipeline-suites-scope.mjs';

const directory = dirname(fileURLToPath(import.meta.url));
const tracked = new Set(['engine/land-direct-main.test.sh']);
const repoRoot = join(directory, '..');
const allTracked = new Set(execFileSync('git', ['ls-files', '-z'], {
  cwd: repoRoot,
  encoding: 'utf8',
}).split('\0').filter(Boolean));
const CHECKOUT_JOBS = [
  ['suite-scope', 'pipeline-suites-focused'],
  ['pipeline-suites-focused', 'pipeline-suites-full'],
  ['pipeline-suites-full', 'pipeline-suites'],
];

function workflowProxySteps(workflow) {
  return CHECKOUT_JOBS.map(([name, nextName]) => {
    const start = workflow.indexOf(`  ${name}:\n`);
    const end = workflow.indexOf(`\n  ${nextName}:`, start);
    const job = workflow.slice(start, end);
    const proxyStep = job.match(/^      - name: Configure git proxy\n([\s\S]*?)^      - uses: actions\/checkout@v4/m)?.[1];
    assert.ok(proxyStep, `${name}: configure GitHub proxy before checkout`);
    const runBody = proxyStep.match(/^        run: \|\n([\s\S]*)/m)?.[1];
    assert.ok(runBody, `${name}: proxy setup has a shell body`);
    return {
      name,
      proxyStep,
      script: runBody.split('\n').map((line) => line.replace(/^          /, '')).join('\n').trimEnd(),
    };
  });
}

function runWorkflowProxySetup(script, statuses) {
  const root = mkdtempSync(join(tmpdir(), 'pipeline-git-proxy-'));
  const bin = join(root, 'bin');
  const runnerTemp = join(root, 'runner-temp');
  const githubEnv = join(root, 'github-env');
  const curlCalls = join(root, 'curl-calls');
  mkdirSync(bin);
  mkdirSync(runnerTemp);
  const curlStub = `#!/usr/bin/env bash
set -euo pipefail
proxy=''
write_out=no
while (($#)); do
  case "$1" in
    -x) proxy="$2"; shift 2 ;;
    -w) write_out=yes; shift 2 ;;
    *) shift ;;
  esac
done
case "$proxy" in
  http://127.0.0.1:3128) status="$CI_PROXY_LOCAL_STATUS" ;;
  http://198.51.100.1:8888) status="$CI_PROXY_VPS_STATUS" ;;
  *) exit 64 ;;
esac
printf '%s\\n' "$proxy" >> "$CURL_CALLS"
if [[ "$write_out" == yes ]]; then printf '%s' "$status"; fi
`;
  const stubPath = join(bin, 'curl');
  writeFileSync(stubPath, curlStub);
  chmodSync(stubPath, 0o755);
  writeFileSync(githubEnv, '');
  writeFileSync(curlCalls, '');

  try {
    const env = {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      RUNNER_TEMP: runnerTemp,
      GITHUB_ENV: githubEnv,
      GITHUB_REPOSITORY: 'example-maintainer/example-repo',
      CURL_CALLS: curlCalls,
      CI_PROXY_LOCAL_STATUS: statuses.local,
      CI_PROXY_VPS_STATUS: statuses.vps,
    };
    delete env.GIT_CONFIG_GLOBAL;
    execFileSync('bash', ['-euo', 'pipefail', '-c', script], { cwd: directory, env });

    const handoff = readFileSync(githubEnv, 'utf8');
    const configPath = handoff.match(/^GIT_CONFIG_GLOBAL=(.+)$/m)?.[1];
    assert.ok(configPath, 'proxy setup exports its isolated config path to later workflow steps');
    const nextStepEnv = { ...env, GIT_CONFIG_GLOBAL: configPath };
    const gitConfig = (key) => {
      try {
        return execFileSync('git', ['config', '--global', '--get', key], {
          cwd: directory,
          env: nextStepEnv,
          encoding: 'utf8',
        }).trim();
      } catch (error) {
        if (error.status === 1) return null;
        throw error;
      }
    };
    return {
      calls: readFileSync(curlCalls, 'utf8').trim().split('\n').filter(Boolean),
      configPath,
      lowSpeedLimit: gitConfig('http.lowSpeedLimit'),
      lowSpeedTime: gitConfig('http.lowSpeedTime'),
      httpProxy: gitConfig('http.proxy'),
      httpsProxy: gitConfig('https.proxy'),
    };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function assertProxyConfiguredBeforeCheckout(job, jobName) {
  const proxyStepIndex = job.indexOf('      - name: Configure git proxy');
  const checkoutIndex = job.indexOf('      - uses: actions/checkout@v4');
  assert.ok(
    proxyStepIndex !== -1 && checkoutIndex !== -1 && proxyStepIndex < checkoutIndex,
    `${jobName} must configure git proxy before actions/checkout`,
  );

  const proxySetup = job.slice(proxyStepIndex, checkoutIndex);
  assert.match(proxySetup, /GIT_CONFIG_GLOBAL="\$RUNNER_TEMP\/ci-git-proxy-gitconfig"/);
  assert.match(proxySetup, /echo "GIT_CONFIG_GLOBAL=\$GIT_CONFIG_GLOBAL" >> "\$GITHUB_ENV"/);
  assert.match(proxySetup, /http:\/\/127\.0\.0\.1:3128/);
  assert.match(proxySetup, /http:\/\/198\.51\.100\.1:8888/);
  assert.match(proxySetup, /git config --global http\.proxy "\$proxy"/);
  assert.match(proxySetup, /git config --global https\.proxy "\$proxy"/);
}

function workflowInputPaths(workflow, event) {
  const start = workflow.indexOf(`\n  ${event}:\n`);
  assert.ok(start >= 0, `${event} trigger missing`);
  const rest = workflow.slice(start + 1);
  const end = rest.search(/\n  [a-z_]+:\n/);
  const block = end < 0 ? rest : rest.slice(0, end);
  return [...block.matchAll(/^\s+- '([^']+)'$/gm)].map((match) => match[1]);
}

function pathPatternCovers(pattern, path) {
  return pattern === path || (pattern.endsWith('/**') && path.startsWith(pattern.slice(0, -2)));
}

test('fixture diff selects its explicitly mapped suite', () => {
  const scope = pipelineSuiteScope(['engine/land-direct-main.sh'], tracked);
  assert.equal(scope.full, false);
  assert.deepEqual(scope.testPaths, ['engine/land-direct-main.test.sh']);
  assert.ok(SUITE_PATH_COVERAGE.get('engine/land-direct-main.test.sh').has('engine/land-direct-main.sh'));
});

test('lessons fixture selects mapped suite', () => {
  const scope = pipelineSuiteScope(['lessons/pending/example.json'], tracked);
  assert.equal(scope.full, false);
  assert.deepEqual(scope.testPaths, ['engine/land-direct-main.test.sh']);
});

test('mapped Agent source retains explicit and reference-selected suites', { skip: 'needs the the product CI workflows or the product commit history, not exported' }, () => {
  const sourcePath = 'engine/run-release.sh';
  const trackedPaths = new Set(execFileSync('git', ['ls-files', '-z'], {
    cwd: repoRoot,
    encoding: 'utf8',
  }).split('\0').filter(Boolean));
  const mappedSuites = RELATED_TESTS.get(sourcePath);

  assert.ok(mappedSuites);
  assert.ok(trackedPaths.has(sourcePath));
  const scope = pipelineSuiteScope([sourcePath], trackedPaths);
  const referenceSuites = focusedTestPaths([sourcePath], trackedPaths);

  assert.equal(scope.full, false);
  assert.deepEqual(scope.testPaths, [...new Set([...mappedSuites, ...referenceSuites])].sort());
  for (const suite of referenceSuites) assert.ok(scope.testPaths.includes(suite));
  for (const suite of CROSS_SCRIPT_TESTS) assert.ok(scope.testPaths.includes(suite));
  for (const suite of mappedSuites) {
    assert.ok(SUITE_PATH_COVERAGE.get(suite).has(sourcePath));
  }
});

test('unmapped pull request paths stay focused and preserve cross-script coverage', () => {
  const crossScriptTracked = new Set([...CROSS_SCRIPT_TESTS, 'engine/foo.test.sh']);
  assert.deepEqual(pipelineSuiteScope(['engine/foo.sh'], crossScriptTracked), {
    full: false,
    testPaths: [...CROSS_SCRIPT_TESTS, 'engine/foo.test.sh'].sort(),
  });
  assert.deepEqual(pipelineSuiteScope(['docs/agents/unmapped.md'], crossScriptTracked), {
    full: false,
    testPaths: [],
  });
});

test('workflow, selector and runner changes still select the full suite', () => {
  for (const path of ['.github/workflows/pipeline-suites.yml', 'engine/run-ci-suites.sh']) {
    assert.equal(pipelineSuiteScope([path], allTracked).full, true, path);
  }
  for (const path of [
    'engine/run-ci-suites.sh',
    'engine/focused-test-paths.mjs',
    'engine/test-env.sh',
    '.github/workflows/ci.yml',
    '.github/workflows/pipeline-suites.yml',
    '.github/workflows/pipeline-suites-nightly.yml',
    'engine/lib.sh',
    ...FULL_SUITE_PATHS,
  ]) {
    assert.equal(pipelineSuiteScope([path], allTracked).full, true, path);
  }
  assert.deepEqual(pipelineSuiteScope(['packages/shared/package.json'], tracked), {
    full: false,
    testPaths: [],
  });
});

function replayPipelineSuiteDiff(commit) {
  const baseRef = `${commit}^`;
  const changedPaths = execFileSync('git', [
    'diff', '--name-only', '-z', '--no-renames', '--diff-filter=ACMRTUXBD', `${baseRef}..${commit}`,
  ], { cwd: repoRoot, encoding: 'utf8' }).split('\0').filter(Boolean);
  const trackedPaths = new Set(execFileSync('git', ['ls-tree', '-r', '--name-only', '-z', commit], {
    cwd: repoRoot,
    encoding: 'utf8',
  }).split('\0').filter(Boolean));
  return pipelineSuiteScope(changedPaths, trackedPaths, { baseRef, headRef: commit, cwd: repoRoot });
}

test('#4599 diff selects all seven suites that later failed on main', { skip: 'needs the the product CI workflows or the product commit history, not exported' }, () => {
  const scope = replayPipelineSuiteDiff('17379ad5742f4956f262706928afbc9a5accd7b7');
  assert.equal(scope.full, true);
  for (const suite of [
    'engine/fastlane-scope.test.sh',
    'engine/guarded-hand-brief.test.sh',
    'engine/run-triage.test.sh',
    'engine/detect-label-churn.test.sh',
    'engine/lesson-lints.test.mjs',
    'engine/runtime-reload.test.sh',
    'engine/stage-label-writers.test.sh',
  ]) {
    assert.ok(scope.testPaths.includes(suite), `${suite} selected`);
  }
});

test('#4543 diff selects hold, sweep-merges and ci-priority-lane', { skip: 'needs the the product CI workflows or the product commit history, not exported' }, () => {
  const scope = replayPipelineSuiteDiff('030ba618afcdec30c4284202420c65009647d5b0');
  assert.equal(scope.full, true);
  for (const suite of [
    'engine/hold.test.sh',
    'engine/sweep-merges.test.sh',
    'engine/ci-priority-lane.test.mjs',
  ]) {
    assert.ok(scope.testPaths.includes(suite), `${suite} selected`);
  }
});

test('backtested dependency, CI-tree, contract-workflow and CLAUDE.md paths merge mapped and referenced suites', () => {
  const suites = new Set([...RELATED_TESTS.values()].flat());
  const all = new Set([...suites, 'engine/land-direct-main.test.sh']);
  assert.equal(FULL_SUITE_PATHS.length, 11);
  const lock = pipelineSuiteScope(['pnpm-lock.yaml'], all);
  assert.equal(lock.full, false);
  assert.ok(lock.testPaths.includes('engine/ci-runner-lanes.test.mjs'));
  const lockReferences = focusedTestPaths(['pnpm-lock.yaml'], all);
  const lockMappings = [...SUITE_PATH_COVERAGE]
    .filter(([suite, paths]) => all.has(suite) && paths.has('pnpm-lock.yaml'))
    .map(([suite]) => suite);
  assert.deepEqual(lock.testPaths, [...new Set([...lockMappings, ...lockReferences])].sort());
  const dagger = pipelineSuiteScope(['.dagger/src/index.ts'], all);
  assert.equal(dagger.full, false);
  assert.ok(dagger.testPaths.includes('engine/ci-infrastructure-focused.test.sh'));
  assert.equal(pipelineSuiteScope(['scripts/ci/dagger-run.mjs'], all).full, false);
  assert.ok(pipelineSuiteScope(['.github/workflows/agent-workflow-contract.yml'], all)
    .testPaths.includes('scripts/deploy-regression-contract.test.mjs'));
  assert.deepEqual(pipelineSuiteScope(['CLAUDE.md'], all),
    { full: false, testPaths: ['engine/mac-autopilot/worker-rules-lanes.test.sh'] });
  for (const path of ['.github/workflows/ci.yml', 'engine/lib.sh', 'engine/run-ci-suites.sh']) {
    assert.equal(pipelineSuiteScope([path], allTracked).full, true, path);
  }
  assert.deepEqual(pipelineSuiteScope(['unmapped/file.txt'], all), { full: false, testPaths: [] });
});

test('an incident-guard registry edit selects its readers suites, not every suite', () => {
  const registry = 'engine/state/incident-guards.json';
  const all = new Set([...RELATED_TESTS.values()].flat());
  assert.ok(!FULL_SUITE_PATHS.includes(registry));
  const scope = pipelineSuiteScope([registry], all);
  const referenceSuites = focusedTestPaths([registry], all);
  assert.equal(scope.full, false);
  assert.deepEqual(scope.testPaths,
    [...new Set([...RELATED_TESTS.get(registry), ...referenceSuites])].sort());
  for (const suite of RELATED_TESTS.get(registry)) assert.ok(scope.testPaths.includes(suite));
  assert.deepEqual(RELATED_TESTS.get(registry).slice().sort(), [
    'engine/check-rulings.test.sh',
    'engine/land-direct-main.test.sh',
    'engine/lesson-fragments.test.sh',
    'engine/night/incident-guard-audit.test.mjs',
    'engine/night/maintainer-health-mail.test.sh',
    'engine/pipeline-system-deliver.test.mjs',
    'scripts/branch-delivery-preflight.test.mjs',
  ]);
});

test('workflow scopes PRs and dispatches full main shards under one aggregated check', { skip: 'needs the the product CI workflows or the product commit history, not exported' }, () => {
  const workflow = readFileSync(join(directory, '../.github/workflows/pipeline-suites.yml'), 'utf8');
  const scopeJob = workflow.match(/^  suite-scope:\n([\s\S]*?)(?=^  pipeline-suites-focused:)/m)?.[1];
  const focusedJob = workflow.match(/^  pipeline-suites-focused:\n([\s\S]*?)(?=^  pipeline-suites-full:)/m)?.[1];
  const fullJob = workflow.match(/^  pipeline-suites-full:\n([\s\S]*?)(?=^  pipeline-suites:\n)/m)?.[1];
  const aggregateJob = workflow.match(/^  pipeline-suites:\n([\s\S]*)$/m)?.[1];
  const scopeSelection = workflow.match(/^      - name: Select suite scope\n([\s\S]*?)(?=^  pipeline-suites-focused:)/m)?.[1];
  assert.ok(scopeJob);
  assert.ok(focusedJob);
  assert.ok(fullJob);
  assert.ok(aggregateJob);
  assert.ok(scopeSelection);
  assert.match(scopeJob, /^    timeout-minutes: 15$/m);
  assertProxyConfiguredBeforeCheckout(scopeJob, 'suite-scope');
  assertProxyConfiguredBeforeCheckout(focusedJob, 'pipeline-suites-focused');
  assertProxyConfiguredBeforeCheckout(fullJob, 'pipeline-suites-full');
  const proxyConfigIndex = scopeJob.indexOf('- name: Configure git proxy');
  const checkoutIndex = scopeJob.indexOf('- uses: actions/checkout@v4');
  assert.ok(proxyConfigIndex >= 0 && proxyConfigIndex < checkoutIndex,
    'suite-scope must configure GitHub egress before checkout on self-hosted runners');
  const proxyConfig = scopeJob.slice(proxyConfigIndex, checkoutIndex);
  assert.match(proxyConfig, /http:\/\/127\.0\.0\.1:3128/);
  assert.match(proxyConfig, /http:\/\/198\.51\.100\.1:8888/);
  assert.match(focusedJob, /^    timeout-minutes: 60$/m);
  assert.match(scopeSelection, /if \[ "\$\{GITHUB_EVENT_NAME\}" = pull_request \]; then/);
  assert.match(scopeSelection, /else\n\s+full=true\n\s+test_paths=""/);
  assert.match(fullJob,
    /^    if: \$\{\{ needs\.suite-scope\.outputs\.reused != 'true' && needs\.suite-scope\.outputs\.full == 'true' && \(github\.event_name != 'pull_request' \|\| startsWith\(github\.head_ref, 'agent\/issue-'\) \|\| vars\.PR_CI == 'on'\) && \(github\.event_name != 'pull_request' \|\| github\.event\.pull_request\.draft == false\) \}\}$/m);
  assert.match(fullJob, /^    timeout-minutes: 60$/m);
  assert.match(aggregateJob, /^    timeout-minutes: 5$/m);
  assert.match(fullJob, /^        shard: \[0, 1, 2, 3, 4\]$/m);
  assert.match(workflow, /git merge-base/);
  assert.match(workflow, /pipeline-suites-scope\.mjs/);
  assert.match(workflow, /test_paths<<PIPELINE_SUITE_PATHS/);
  assert.match(workflow, /node --test "\$\{suite\}"/);
  assert.match(workflow, /bash "\$\{suite\}"/);
  assert.match(workflow, /bash engine\/run-ci-suites\.sh --shard/);
  assert.match(workflow, /\.dagger\/\*\*/);
  assert.match(workflow, /scripts\/ci\/\*\*/);
  assert.equal((workflow.match(/^    name: Pipeline suites$/gm) ?? []).length, 1);
  assert.match(workflow, /^  pipeline-suites:\n    name: Pipeline suites\n    if: \$\{\{ !cancelled\(\) && \(github\.event_name != 'pull_request' \|\| startsWith\(github\.head_ref, 'agent\/issue-'\) \|\| vars\.PR_CI == 'on'\) && \(github\.event_name != 'pull_request' \|\| github\.event\.pull_request\.draft == false\) \}\}\n    needs: \[suite-scope, pipeline-suites-focused, pipeline-suites-full\]/m);
  assert.match(workflow, /name: Pipeline suites shard \$\{\{ matrix\.shard \}\}/);
  assert.match(workflow, /workflow_dispatch:/);

  const proxySteps = workflowProxySteps(workflow);
  assert.equal((workflow.match(/^      - uses: actions\/checkout@v4$/gm) ?? []).length, CHECKOUT_JOBS.length);
  for (const { name, proxyStep } of proxySteps) {
    assert.match(proxyStep, /GIT_CONFIG_GLOBAL="\$RUNNER_TEMP\/ci-git-proxy-gitconfig"/);
    assert.match(proxyStep, /echo "GIT_CONFIG_GLOBAL=\$GIT_CONFIG_GLOBAL" >> "\$GITHUB_ENV"/);
    assert.match(proxyStep, /export GIT_CONFIG_GLOBAL/);
    assert.match(proxyStep, /git config --global http\.lowSpeedLimit 1024/);
    assert.match(proxyStep, /git config --global http\.lowSpeedTime 30/);
    assert.match(proxyStep, /git config --global http\.proxy "\$proxy"/);
    assert.match(proxyStep, /git config --global https\.proxy "\$proxy"/);
    assert.match(proxyStep, /-w '%\{http_code\}'/);
    assert.match(proxyStep, /http:\/\/127\.0\.0\.1:3128/);
    assert.match(proxyStep, /http:\/\/198\.51\.100\.1:8888/);
  }
  assert.equal(new Set(proxySteps.map(({ script }) => script)).size, 1, 'all checkout jobs use the same tested proxy setup');

  const nightlyWorkflow = readFileSync(join(directory, '../.github/workflows/pipeline-suites-nightly.yml'), 'utf8');
  assert.match(nightlyWorkflow, /^name: Pipeline suites nightly$/m);
  assert.match(nightlyWorkflow, /cron: '0 3 \* \* \*'/);
  assert.match(nightlyWorkflow, /workflow_dispatch:/);
  assert.match(nightlyWorkflow, /runs-on: \[self-hosted, cihost-ci\]/);
  assert.match(nightlyWorkflow, /bash engine\/run-ci-suites\.sh --nightly/);
});

test('empty focused suite lists pass after static checks and through the aggregate job', { skip: 'needs the the product CI workflows or the product commit history, not exported' }, () => {
  const workflow = readFileSync(join(directory, '../.github/workflows/pipeline-suites.yml'), 'utf8');
  const focusedJob = workflow.match(/^  pipeline-suites-focused:\n([\s\S]*?)(?=^  pipeline-suites-full:)/m)?.[1];
  const aggregateJob = workflow.match(/^  pipeline-suites:\n([\s\S]*)$/m)?.[1];
  assert.ok(focusedJob);
  assert.ok(aggregateJob);

  const staticCheckIndex = focusedJob.indexOf('- name: Check static rulings');
  const focusedRunIndex = focusedJob.indexOf('- name: Run focused pipeline suites');
  assert.ok(staticCheckIndex >= 0 && staticCheckIndex < focusedRunIndex,
    'static rulings still run before the empty suite loop');
  const staticCheck = focusedJob.slice(staticCheckIndex, focusedJob.indexOf('\n      - ', staticCheckIndex + 1));
  assert.doesNotMatch(staticCheck, /^        if:/m, 'static checks are not skipped for empty test paths');

  const workflowScript = (job, stepName) => {
    const stepIndex = job.indexOf(`      - name: ${stepName}\n`);
    assert.ok(stepIndex >= 0, `${stepName} step exists`);
    const step = job.slice(stepIndex);
    const runMarker = '        run: |\n';
    const runStart = step.indexOf(runMarker);
    assert.ok(runStart >= 0, `${stepName} has a shell body`);
    return step.slice(runStart + runMarker.length).split('\n')
      .map((line) => line.replace(/^ {10}/, '')).join('\n').trimEnd();
  };
  const runScript = (script, env) => execFileSync('bash', ['-euo', 'pipefail', '-c', script], {
    cwd: directory,
    env: { ...process.env, ...env },
    encoding: 'utf8',
  });

  assert.equal(runScript(workflowScript(focusedJob, 'Run focused pipeline suites'), { TEST_PATHS: '' }), '');
  assert.match(runScript(workflowScript(aggregateJob, 'Aggregate suite conclusion'), {
    SCOPE_RESULT: 'success',
    SCOPE_FULL: 'false',
    REUSED: '',
    EVIDENCE_URL: '',
    FOCUSED_RESULT: 'success',
    FULL_RESULT: 'skipped',
  }), /Pipeline suites passed/);
  const summaryDirectory = mkdtempSync(join(tmpdir(), 'pipeline-suite-evidence-'));
  try {
    const summaryPath = join(summaryDirectory, 'summary.md');
    assert.match(runScript(workflowScript(aggregateJob, 'Aggregate suite conclusion'), {
      SCOPE_RESULT: 'success',
      SCOPE_FULL: '',
      REUSED: 'true',
      EVIDENCE_URL: 'https://github.com/example-maintainer/example-repo/actions/runs/42',
      FOCUSED_RESULT: 'skipped',
      FULL_RESULT: 'skipped',
      GITHUB_STEP_SUMMARY: summaryPath,
    }), /Pipeline suites passed using exact-SHA train evidence/);
    assert.match(readFileSync(summaryPath, 'utf8'), /https:\/\/github\.com\/example-maintainer\/example-repo\/actions\/runs\/42/);
  } finally {
    rmSync(summaryDirectory, { recursive: true, force: true });
  }
});

test('workflow proxy setup rejects HTTP 5xx, accepts 401 and success, and hands config to checkout', { skip: 'needs the the product CI workflows or the product commit history, not exported' }, async (t) => {
  const workflow = readFileSync(join(directory, '../.github/workflows/pipeline-suites.yml'), 'utf8');
  const [{ script }] = workflowProxySteps(workflow);

  await t.test('a local 503 falls back to the VPS proxy when it returns expected 401', () => {
    const result = runWorkflowProxySetup(script, { local: '503', vps: '401' });
    assert.deepEqual(result.calls, ['http://127.0.0.1:3128', 'http://198.51.100.1:8888']);
    assert.equal(result.httpProxy, 'http://198.51.100.1:8888');
    assert.equal(result.httpsProxy, 'http://198.51.100.1:8888');
    assert.equal(result.lowSpeedLimit, '1024');
    assert.equal(result.lowSpeedTime, '30');
  });

  await t.test('the local proxy is accepted for an expected 401 or successful response', () => {
    for (const status of ['401', '200']) {
      const result = runWorkflowProxySetup(script, { local: status, vps: '200' });
      assert.deepEqual(result.calls, ['http://127.0.0.1:3128'], `HTTP ${status}`);
      assert.equal(result.httpProxy, 'http://127.0.0.1:3128', `HTTP ${status}`);
      assert.equal(result.httpsProxy, 'http://127.0.0.1:3128', `HTTP ${status}`);
      assert.ok(result.configPath.endsWith('/ci-git-proxy-gitconfig'));
    }
  });

  await t.test('two HTTP 5xx responses leave proxy config unset', () => {
    const result = runWorkflowProxySetup(script, { local: '503', vps: '502' });
    assert.deepEqual(result.calls, ['http://127.0.0.1:3128', 'http://198.51.100.1:8888']);
    assert.equal(result.httpProxy, null);
    assert.equal(result.httpsProxy, null);
    assert.equal(result.lowSpeedLimit, '1024');
    assert.equal(result.lowSpeedTime, '30');
  });
});

test('workflow is triggered by shared package source changes', { skip: 'needs the the product CI workflows or the product commit history, not exported' }, () => {
  const workflow = readFileSync(join(directory, '../.github/workflows/pipeline-suites.yml'), 'utf8');
  const pullRequest = workflow.match(/^  pull_request:\n([\s\S]*?)(?=^  workflow_dispatch:)/m)?.[1];
  const pathBlock = pullRequest?.match(/^    paths:\n([\s\S]*)/m)?.[1];
  assert.ok(pathBlock, 'pull_request must declare paths');

  const patterns = pathBlock.split(/\r?\n/).map((line) => line.trim())
    .map((line) => line.match(/^-[ \t]*['"]?([^'"]+)['"]?$/)?.[1])
    .filter(Boolean);
  const workflowTriggersFor = (changedPath) => patterns.some((pattern) => (
    pattern === changedPath
    || (pattern.endsWith('/**') && changedPath.startsWith(pattern.slice(0, -2)))
  ));

  assert.ok(workflowTriggersFor('packages/shared/src/index.ts'));
});

// Run the real CLI: a mixed product/lesson PR must keep the lesson check without five full shards.
test('CLI crops PR diffs to declared workflow inputs and preserves forced-full edges', { skip: 'needs the the product CI workflows or the product commit history, not exported' }, () => {
  const root = mkdtempSync(join(tmpdir(), 'pipeline-scope-inputs-'));
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
  const put = (path, content) => {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), content);
  };
  try {
    git('init', '-q');
    git('config', 'user.name', 'Scope fixture');
    git('config', 'user.email', 'fixture@example.invalid');
    put('.github/workflows/pipeline-suites.yml', readFileSync(join(directory, '../.github/workflows/pipeline-suites.yml'), 'utf8'));
    put('engine/land-direct-main.test.sh', '# fixture\n');
    put('engine/foo.test.sh', '# references engine/foo.sh\n');
    put('engine/lib.test.sh', '# fixture\n');
    put('engine/run-ci-suites.test.sh', '# fixture\n');
    for (const suite of CROSS_SCRIPT_TESTS) put(suite, '# fixture\n');
    put('packages/example-gateway/src/entry.ts', 'export {};\n');
    put('lessons/full/existing.md', 'existing lesson\n');
    git('add', '.');
    git('commit', '-qm', 'base');
    let base = git('rev-parse', 'HEAD');
    put('packages/example-gateway/src/entry.ts', 'export const changed = true;\n');
    put('lessons/full/example.md', 'lesson\n');
    git('add', '.');
    git('commit', '-qm', 'product plus lesson');
    const scope = () => JSON.parse(execFileSync(process.execPath, [join(directory, 'pipeline-suites-scope.mjs'), base, 'HEAD'], {
      cwd: root, encoding: 'utf8',
    }));
    assert.deepEqual(scope(), { full: false, testPaths: ['engine/land-direct-main.test.sh'] });

    base = git('rev-parse', 'HEAD');
    put('engine/foo.sh', 'changed\n');
    git('add', '.');
    git('commit', '-qm', 'unmapped agent script');
    assert.deepEqual(scope(), {
      full: false,
      testPaths: [...CROSS_SCRIPT_TESTS, 'engine/foo.test.sh'].sort(),
    });
    git('reset', '--hard', 'HEAD~1');

    put('docs/agents/unmapped.md', 'changed\n');
    git('add', '.');
    git('commit', '-qm', 'unmapped in-scope documentation');
    assert.deepEqual(scope(), { full: false, testPaths: [] });
    git('reset', '--hard', 'HEAD~1');

    for (const path of [
      'packages/example-runtime/Dockerfile',
      'packages/example-runtime/tests/fixtures/pinned/production-image-baselines.json',
      'packages/example-pack/src/db/provision-migrator-platform-grants.sql',
    ]) {
      put(path, 'changed\n');
      git('add', '.');
      git('commit', '-qm', 'unmapped workflow input');
      assert.deepEqual(scope(), { full: false, testPaths: [] }, path);
      git('reset', '--hard', 'HEAD~1');
    }
    for (const path of ['engine/lib.sh', 'engine/run-ci-suites.sh']) {
      put(path, 'changed\n');
      git('add', '.');
      git('commit', '-qm', 'forced full runner input');
      assert.equal(scope().full, true, path);
      git('reset', '--hard', 'HEAD~1');
    }
    mkdirSync(join(root, 'packages/example-runtime'), { recursive: true });
    git('mv', 'packages/example-gateway/src/entry.ts', 'packages/example-runtime/Dockerfile');
    git('commit', '-qm', 'rename into uncovered path');
    assert.deepEqual(scope(), { full: false, testPaths: [] });
    git('reset', '--hard', 'HEAD~1');
    git('mv', 'lessons/full/existing.md', 'packages/example-gateway/src/lesson.md');
    git('commit', '-qm', 'rename out of lesson inputs');
    assert.deepEqual(scope(), { full: false, testPaths: ['engine/land-direct-main.test.sh'] });
    put('.github/workflows/pipeline-suites.yml', 'on:\n  pull_request:\n    paths:\n      - packages/**\n  workflow_dispatch:\n');
    git('add', '.');
    git('commit', '-qm', 'workflow input boundary changes');
    assert.equal(scope().full, true, 'workflow edits cannot narrow their own check');
    base = git('rev-parse', 'HEAD');
    put('lessons/full/example.md', 'changed lesson\n');
    git('add', '.');
    git('commit', '-qm', 'change with unsupported input syntax');
    assert.throws(scope, /Unsupported pipeline input path/, 'unparsed input patterns must fail closed');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('main pushes run the pipeline suites only for the paths pull requests use', { skip: 'needs the the product CI workflows or the product commit history, not exported' }, () => {
  // 2026-10-21: an unfiltered push trigger ran the full suite on every product-only merge and held the
  // five main-lane runners while hot-patch CI queued. Releases still gate on Postsubmit for every push.
  const workflow = readFileSync(join(directory, '../.github/workflows/pipeline-suites.yml'), 'utf8');
  const pushPaths = workflowInputPaths(workflow, 'push');
  const pullRequestPaths = workflowInputPaths(workflow, 'pull_request');
  assert.ok(pushPaths.length > 0, 'main push has no path filter');
  assert.deepEqual(pushPaths, pullRequestPaths);
});

test('main push and PR filters cover every direct input mapped to Pipeline suite tests', { skip: 'needs the the product CI workflows or the product commit history, not exported' }, () => {
  const workflow = readFileSync(join(directory, '../.github/workflows/pipeline-suites.yml'), 'utf8');
  const suiteInputs = [...RELATED_TESTS].filter(([, suites]) =>
    suites.some((suite) => suite.startsWith('engine/')));

  for (const event of ['push', 'pull_request']) {
    const paths = workflowInputPaths(workflow, event);
    const uncovered = suiteInputs
      .filter(([input]) => !paths.some((pattern) => pathPatternCovers(pattern, input)))
      .map(([input]) => input);
    assert.deepEqual(uncovered, [], `${event} paths omit mapped Pipeline suite inputs`);
  }
});

test('shard lifecycle suite does not nest the full release suite', { skip: 'needs the the product CI workflows or the product commit history, not exported' }, () => {
  const lifecycleSuite = readFileSync(join(directory, 'shard-lifecycle-contract.test.sh'), 'utf8');
  assert.match(lifecycleSuite, /restart-when-idle\.test\.sh/);
  assert.match(lifecycleSuite, /example-runtime-target\.test\.sh/);
  assert.match(lifecycleSuite, /restart-agent\.test\.sh/);
  assert.doesNotMatch(lifecycleSuite, /run-release\.test\.sh/);
});
