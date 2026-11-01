import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';

import {
  focusedTestPaths,
  intersectingFocusedTestPaths,
  orderFocusedTestPaths,
  RELATED_TESTS,
} from './focused-test-paths.mjs';
import { readPackJson } from './pack-dir.mjs';

test('maps the traffic installer to its executable owner contract', () => {
  const suites = ['engine/network-traffic.test.sh'];
  assert.deepEqual(focusedTestPaths(['engine/install-traffic-monitor.sh'], new Set(suites)), suites);
});

test('maps both shared-pool provisioners to their owner suites', () => {
  const paths = [
    '.github/workflows/pipeline-suites.yml',
    'engine/ci-runner-lanes.mjs',
    'engine/provision-cihost-ci-runner.sh',
    'scripts/check-regression-contract-teeth.mjs',
  ];
  const suites = [
    'engine/ci-runner-lanes.test.mjs',
    'engine/provision-cihost-ci-runner.test.sh',
    'scripts/branch-delivery-preflight.test.mjs',
    'scripts/deploy-regression-contract.test.mjs',
  ];
  assert.deepEqual(focusedTestPaths(paths, new Set(suites)), [...suites].sort());
});

test('Python and CommonJS pipeline sources require owner coverage', () => {
  const suite = 'engine/network-traffic.test.sh';
  assert.deepEqual(focusedTestPaths(['engine/network-traffic.py'], new Set([suite])), [suite]);
  for (const extension of ['py', 'cjs', 'js', 'ts']) {
    assert.throws(() => focusedTestPaths([`engine/uncovered.${extension}`], new Set()), /No focused test exists/);
  }
});

test('a deleted pipeline script needs no focused test, a changed one still does', () => {
  const repo = mkdtempSync(join(tmpdir(), 'focused-deleted-'));
  try {
    const git = (...args) => execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { encoding: 'utf8' });
    git('init', '-q');
    mkdirSync(join(repo, 'engine'), { recursive: true });
    writeFileSync(join(repo, 'engine/retired.mjs'), 'export {};\n');
    git('add', '.');
    git('commit', '-q', '-m', 'add');
    git('rm', '-q', 'engine/retired.mjs');
    assert.deepEqual(focusedTestPaths(['engine/retired.mjs'], new Set(), { cwd: repo }), []);
    assert.throws(() => focusedTestPaths(['engine/uncovered.mjs'], new Set(), { cwd: repo }), /No focused test exists/);
    git('commit', '-q', '-m', 'delete');
    const refs = { baseRef: 'HEAD~1', headRef: 'HEAD', cwd: repo };
    assert.deepEqual(focusedTestPaths(['engine/retired.mjs'], new Set(), refs), []);
    assert.throws(() => focusedTestPaths(['engine/uncovered.mjs'], new Set(), refs), /No focused test exists/);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test('retired work-plan runner paths do not select its deleted test', () => {
  for (const path of [
    'engine/check-work-plan.sh',
    'engine/systemd/zf-work-plan-acceptance.service',
    'engine/systemd/zf-work-plan-acceptance.timer',
  ]) assert.equal(RELATED_TESTS.has(path), false, path);
});

test('maps lifecycle source to cleanup and shared phase admission coverage', () => {
  const suites = ['engine/execution-admission.test.sh', 'engine/git-fetch-bounded.test.sh', 'engine/worktree-lifecycle.test.sh'];
  assert.deepEqual(focusedTestPaths(['engine/worktree-lifecycle.sh'], new Set(suites)), suites);
});

test('maps the PR required-check aggregate and shared merge policy to their focused tests', () => {
  const aggregate = 'engine/ci/pr-required-aggregate.test.mjs';
  assert.deepEqual(focusedTestPaths(['engine/ci/pr-required-aggregate.mjs'], new Set([aggregate])), [aggregate]);
  assert.ok(RELATED_TESTS.get('engine/lib.sh').includes('engine/main-release-ready-cache.test.sh'));
});

test('maps shared merge-policy changes to aggregate-check consumer suites', () => {
  const suites = [
    'engine/ci-priority-lane.test.mjs',
    'engine/hold.test.sh',
    'engine/sweep-merges.test.sh',
  ];
  for (const source of ['engine/lib.sh', 'engine/mac-autopilot/required-pr-checks.json']) {
    const selected = focusedTestPaths([source], new Set(suites));
    assert.deepEqual([...selected].sort(), [...suites].sort(), source);
  }
});

test('maps target config data to its reader suites', () => {
  for (const [source, suites] of [
    ['.zenoforge/model-policy.default.json', ['engine/lib.test.sh', 'engine/apply-model-policy-default-view.test.sh']],
    ['.zenoforge/mac-autopilot/NODE-HEALTH.md', ['engine/mac-autopilot/dashboard-front.test.sh', 'engine/mac-autopilot/node_health.test.sh']],
    ['.zenoforge/mac-autopilot/config.template.json', ['engine/mac-autopilot/scheduler-gates.test.sh', 'engine/mac-autopilot/start.test.sh']],
    ['.zenoforge/mac-autopilot/product-lane-skills.txt', ['engine/mac-autopilot/scheduler-gates.test.sh']],
    ['.zenoforge/prompts/advisor-batch.md', ['engine/run-advisor-batch.test.sh']],
    ['.zenoforge/prompts/advisor.md', ['engine/run-advisor.test.sh', 'engine/run-advisor-batch.test.sh']],
    ['.zenoforge/prompts/advisor.schema.json', ['engine/run-advisor.test.sh', 'engine/run-advisor-batch.test.sh']],
    ['.zenoforge/prompts/agent-settings.json', [
      'engine/eval/runner.test.mjs',
      'engine/run-advisor.test.sh',
      'engine/run-advisor-batch.test.sh',
      'engine/run-recut.test.sh',
      'engine/run-triage.test.sh',
      'engine/run-triage-batch.test.sh',
    ]],
    ['.zenoforge/prompts/founder-outcome.schema.json', ['engine/notify.test.sh']],
    ['.zenoforge/prompts/implement-contract.md', ['engine/eval/runner.test.mjs']],
    ['.zenoforge/prompts/recut.md', ['engine/run-recut.test.sh']],
    ['.zenoforge/prompts/recut.schema.json', ['engine/run-recut.test.sh']],
    ['.zenoforge/prompts/review-contract.md', ['engine/mac-autopilot/scheduler.test.sh', 'engine/mac-autopilot/supervisor-arbiter.test.sh']],
    ['.zenoforge/prompts/supervisor-arbiter.md', [
      'engine/eval/runner.test.mjs',
      'engine/mac-autopilot/scheduler.test.sh',
      'engine/mac-autopilot/supervisor-arbiter.test.sh',
    ]],
    ['.zenoforge/prompts/triage.md', ['engine/run-triage.test.sh', 'engine/run-triage-batch.test.sh']],
    ['.zenoforge/prompts/triage.schema.json', ['engine/run-triage.test.sh', 'engine/run-triage-batch.test.sh']],
    ['.zenoforge/mac-autopilot/required-pr-checks.json', ['engine/lib.test.sh', 'engine/mac-autopilot/scheduler-gates.test.sh', 'engine/hotfix/hf-merge.test.sh']],
    ['.zenoforge/state/ci-known-flakes.json', ['engine/ci-flake-classification.test.sh']],
    ['.zenoforge/state/hand-priority.json', ['engine/dispatch-load-guard.test.sh']],
    ['.zenoforge/state/risk-paths.json', ['engine/risk-class.test.mjs']],
    ['.zenoforge/state/rule-files.json', ['engine/rule-lane.test.sh', 'engine/landed-incident-guards.test.sh']],
    ['.zenoforge/state/rulings.json', ['engine/check-rulings.test.sh', 'engine/pipeline-system-close-evidence.test.sh']],
    ['.zenoforge/state/scheduling-policy.json', ['engine/check-rulings.test.sh']],
    ['.zenoforge/state/incident-guards.json', ['engine/night/incident-guard-audit.test.mjs']],
    ['.zenoforge/state/deploy-culprit.json', ['engine/deploy-culprit.test.sh']],
    ['.zenoforge/state/feature-map.json', ['engine/verification-plan.test.mjs']],
    ['.zenoforge/state/focused-test-map.json', ['engine/focused-test-paths.test.mjs']],
    ['.zenoforge/state/user-surface-paths.json', ['engine/verification-map-audit.test.mjs']],
    ['.zenoforge/state/production-tenant-marker-exceptions.json', ['engine/night/production-tenant-marker-readonly.test.sh']],
    ['.zenoforge/mac-autopilot/worker-docs.json', ['engine/mac-autopilot/sched-pack-file.test.sh']],
    ['.zenoforge/fixtures/advisor-batch-broken-from-journal.ndjson', ['engine/run-advisor-batch.test.sh']],
  ]) {
    assert.deepEqual(focusedTestPaths([source], new Set(suites)), [...suites].sort(), source);
  }
});

test('the config root focused-test map wins over a retained pack copy', () => {
  const root = mkdtempSync(join(tmpdir(), 'zf-focused-map-config-'));
  const configRoot = join(root, '.zenoforge');
  const packDir = join(root, 'pack');
  mkdirSync(join(configRoot, 'state'), { recursive: true });
  mkdirSync(join(packDir, 'state'), { recursive: true });
  writeFileSync(join(configRoot, 'state/focused-test-map.json'), JSON.stringify({
    pack_root: 'scripts/agent',
    related_tests: { 'docs/config-only.md': ['scripts/agent/config-suite.test.sh'] },
  }));
  writeFileSync(join(packDir, 'state/focused-test-map.json'), JSON.stringify({
    pack_root: 'scripts/agent',
    related_tests: { 'docs/config-only.md': ['scripts/agent/pack-suite.test.sh'] },
  }));
  const code = `import(${JSON.stringify(new URL('./focused-test-paths.mjs', import.meta.url).href)})
    .then(({ focusedTestPaths }) => console.log(JSON.stringify(
      focusedTestPaths(['docs/config-only.md'], new Set(['engine/config-suite.test.sh', 'engine/pack-suite.test.sh'])))))`;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', code], {
    encoding: 'utf8',
    env: { ...process.env, ZF_CONFIG_ROOT: configRoot, ZF_PACK_DIR: packDir },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ['engine/config-suite.test.sh']);
});

test('maps Nexus retention code and unit tests to the tracked owner-classification suite', () => {
  const suite = 'engine/nexus-retention-reference-owners.test.sh';
  const tracked = new Set([suite]);
  assert.deepEqual(focusedTestPaths(['scripts/ops/nexus-retention.py'], tracked), [suite]);
  assert.deepEqual(focusedTestPaths(['scripts/ops/nexus-retention.test.py'], tracked), [suite]);
});

test('maps tick source to existing fetch and timer repair coverage', () => {
  const suites = ['engine/git-fetch-bounded.test.sh', 'engine/run-tick-timer-repair.test.sh', 'engine/run-tick.test.sh'];
  assert.deepEqual(focusedTestPaths(['engine/run-tick.sh'], new Set(suites)), suites);
});

test('helper caller coverage without a same-name suite is selectable', () => {
  const root = mkdtempSync(join(tmpdir(), 'focused-helper-owner-'));
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
  try {
    mkdirSync(join(root, 'engine'), { recursive: true });
    const helper = 'engine/shared-helper.sh';
    const suite = 'engine/consumer.test.sh';
    writeFileSync(join(root, helper), 'shared_value() { printf old; }\n');
    writeFileSync(join(root, suite), 'source engine/shared-helper.sh\nshared_value\n');
    git('init', '-q'); git('config', 'user.name', 'fixture'); git('config', 'user.email', 'fixture@example.invalid');
    git('add', '.'); git('commit', '-qm', 'base');
    const baseRef = git('rev-parse', 'HEAD');
    writeFileSync(join(root, helper), 'shared_value() { printf new; }\n');
    git('add', '.'); git('commit', '-qm', 'change helper');
    assert.deepEqual(focusedTestPaths([helper], new Set([helper, suite]), {
      baseRef, headRef: 'HEAD', cwd: root,
    }), [suite]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('routes CI infrastructure changes through focused contracts', () => {
  const suite = 'engine/ci-infrastructure-focused.test.sh';
  const tracked = new Set([suite]);
  for (const path of [
    '.dagger/src/index.ts',
    'scripts/ci/dagger-run.mjs',
    '.github/workflows/postsubmit.yml',
    'scripts/check-production-image-contract.mjs',
    'scripts/production-image-contract.json',
  ]) {
    assert.ok(focusedTestPaths([path], tracked).includes(suite), path);
  }
});

test('workflow proxy removals select their regression contract', () => {
  const regression = 'scripts/deploy-regression-contract.test.mjs';
  const tracked = new Set([regression]);
  for (const path of [
    '.github/workflows/agent-workflow-contract.yml',
    '.github/workflows/migration-sql-gate.yml',
  ]) {
    assert.ok(focusedTestPaths([path], tracked).includes(regression), path);
  }
});

test('maps shared test write guard to its refusal regression', () => {
  assert.deepEqual(focusedTestPaths([
    'engine/write-guard.sh',
  ], new Set(['engine/test-write-guard.test.sh'])), [
    'engine/test-write-guard.test.sh',
  ]);
});

test('maps direct-main files to tracked local tests', () => {
  const productTests = Object.values(readPackJson('state/focused-test-map.json')?.related_tests ?? {}).flat();
  const capacityTest = productTests.find((path) => (
    path.startsWith('scripts/ops/') && path.endsWith('build-capacity-reclaim.test.sh')
  )) ?? 'engine/systemd/cihost-build-capacity-reclaim.test.sh';
  const capacitySource = [...RELATED_TESTS.entries()].find(([, tests]) => tests.includes(capacityTest))?.[0]
    ?? 'engine/systemd/cihost-build-capacity-reclaim.sh';
  assert.deepEqual(new Set(focusedTestPaths([
    'engine/land-direct-main.sh',
    'engine/night/health-maintenance.sh',
    'engine/night/node-health-rules.sh',
    'engine/check-rulings.sh',
    'engine/probe-codex-sandbox.sh',
    'engine/pipeline-system-deliver.mjs',
    'engine/record-unit-result.sh',
    'engine/hotfix-loss-probe.sh',
    'engine/run-release.sh',
    capacitySource,
    'engine/state/rulings.json',
    'engine/systemd/zenoforge-health-maintenance.service',
    'engine/systemd/zenoforge-health-maintenance.timer',
    'engine/systemd/zenoforge-health-mail.service',
    'engine/systemd/zenoforge-health-mail.timer',
    'docs/agents/branch-delivery-preflight.md',
  ], new Set([
    'engine/land-direct-main.test.sh',
    'engine/lib.test.sh',
    'engine/night/night.test.sh',
    'engine/night/node-health-rules.test.sh',
    'engine/night/health-maintenance.test.sh',
    'engine/night/merge-lock.test.sh',
    'engine/issue-pipeline.test.sh',
    'engine/pipeline-system-deliver.test.mjs',
    'engine/check-rulings.test.sh',
    'engine/release-hotfix-snapshot.test.sh',
    'engine/run-release.test.sh',
    capacityTest,
  ]))), new Set([
    'engine/check-rulings.test.sh',
    'engine/issue-pipeline.test.sh',
    'engine/land-direct-main.test.sh',
    'engine/lib.test.sh',
    'engine/night/night.test.sh',
    'engine/night/node-health-rules.test.sh',
    'engine/night/health-maintenance.test.sh',
    'engine/pipeline-system-deliver.test.mjs',
    'engine/release-hotfix-snapshot.test.sh',
    'engine/run-release.test.sh',
    capacityTest,
  ]));
});

test('maps the maintainer rulings registry to its metadata contract test', () => {
  const suite = 'engine/state/rulings.test.mjs';
  assert.deepEqual(focusedTestPaths(
    ['engine/state/rulings.json'],
    new Set([suite]),
  ), [suite]);
});

test('routes the remote GitNexus index publisher to its fake-host test', () => {
  const productTests = Object.values(readPackJson('state/focused-test-map.json')?.related_tests ?? {}).flat();
  const indexTest = productTests.find((path) => (
    path.startsWith('scripts/ops/') && path.includes('gitnexus') && path.endsWith('index.test.sh')
  )) ?? 'engine/gitnexus-cihost-index.test.sh';
  const indexSource = [...RELATED_TESTS.entries()].find(([, tests]) => tests.includes(indexTest))?.[0]
    ?? 'engine/gitnexus-cihost-index.sh';
  assert.deepEqual(
    focusedTestPaths(
      [indexSource],
      new Set([indexTest]),
    ),
    [indexTest],
  );
});


test('maps feature verification sources to their planner coverage', () => {
  const tracked = new Set([
    'engine/verification-plan.test.mjs',
    'engine/verification-plan-runtime.test.sh',
  ]);
  assert.deepEqual(focusedTestPaths(['engine/verification-plan.mjs'], tracked), [
    'engine/verification-plan.test.mjs',
  ]);
  assert.deepEqual(focusedTestPaths(['scripts/e2e/yangfeng-regression/catalog.json'], tracked), [
    'engine/verification-plan.test.mjs',
  ]);
  const runtime = focusedTestPaths(['engine/verification-plan-runtime.sh'], tracked);
  assert.ok(runtime.includes('engine/verification-plan-runtime.test.sh'));
});

test('maps manual lesson folding to its remaining fixtures', () => {
  const tracked = new Set([
    'engine/check-rulings.test.sh',
    'engine/land-direct-main.test.sh',
    'engine/night/night.test.sh',
    'engine/pipeline-system-deliver.test.mjs',
    'scripts/branch-delivery-preflight.test.mjs',
  ]);
  for (const source of ['engine/lesson-fragments.sh']) {
    const selected = focusedTestPaths([source], tracked);
    assert.ok(selected.includes('engine/check-rulings.test.sh'));
    assert.ok(selected.includes('engine/land-direct-main.test.sh'));
    assert.ok(selected.includes('engine/night/night.test.sh'));
    assert.ok(selected.includes('engine/pipeline-system-deliver.test.mjs'));
    assert.ok(selected.includes('scripts/branch-delivery-preflight.test.mjs'));
  }
});

test('maps verification maintenance sources to map-audit coverage', () => {
  const tracked = new Set([
    'engine/verification-plan.test.mjs',
    'engine/verification-map-audit.test.mjs',
  ]);
  assert.deepEqual(focusedTestPaths(['engine/verification-map-audit.mjs'], tracked), [
    'engine/verification-map-audit.test.mjs',
  ]);
  const mapTests = focusedTestPaths(['scripts/e2e/yangfeng-regression/catalog.json'], tracked);
  assert.ok(mapTests.includes('engine/verification-plan.test.mjs'));
  assert.ok(mapTests.includes('engine/verification-map-audit.test.mjs'));
});

test('maps throughput metrics to their focused coverage', () => {
  assert.deepEqual(focusedTestPaths(
    ['engine/throughput-metrics.mjs'],
    new Set(['engine/throughput-metrics.test.mjs']),
  ), ['engine/throughput-metrics.test.mjs']);
});

test('adds cross-script scanners for any pipeline shell or module change', () => {
  const scanners = [
    'engine/jq-arg-safety.test.sh',
    'engine/notify.test.sh',
    'engine/queue-order.test.sh',
  ];
  const tracked = new Set([...scanners, 'engine/run-recut.test.sh']);

  assert.deepEqual(focusedTestPaths(['engine/run-recut.sh'], tracked), [
    ...scanners,
    'engine/run-recut.test.sh',
  ]);
  assert.deepEqual(focusedTestPaths(['engine/focused-test-paths.mjs'], new Set([
    ...scanners,
    'engine/focused-test-paths.test.mjs',
  ])), [
    'engine/focused-test-paths.test.mjs',
    ...scanners,
  ]);
});

test('adds cross-script scanners when a pipeline test file itself changes', () => {
  const scanners = [
    'engine/jq-arg-safety.test.sh',
    'engine/notify.test.sh',
    'engine/queue-order.test.sh',
  ];
  assert.deepEqual(focusedTestPaths(['engine/focused-test-paths.test.mjs'], new Set([
    ...scanners,
    'engine/focused-test-paths.test.mjs',
  ])), [
    'engine/focused-test-paths.test.mjs',
    ...scanners,
  ]);
});

test('maps supervisor hold helper to its live hold regressions', () => {
  assert.deepEqual(focusedTestPaths(['engine/supervisor-holds.sh'], new Set([
    'engine/hold.test.sh',
    'engine/issue-pipeline.test.sh',
    'engine/jq-arg-safety.test.sh',
    'engine/night/night.test.sh',
    'engine/notify.test.sh',
    'engine/queue-order.test.sh',
    'engine/run-recut.test.sh',
  ])), [
    'engine/hold.test.sh',
    'engine/issue-pipeline.test.sh',
    'engine/jq-arg-safety.test.sh',
    'engine/night/night.test.sh',
    'engine/notify.test.sh',
    'engine/queue-order.test.sh',
    'engine/run-recut.test.sh',
  ]);
});

test('maps land queue to enqueue and worker coverage', () => {
  assert.deepEqual(focusedTestPaths([
    'engine/land-queue.sh',
  ], new Set(['engine/land-direct-main.test.sh', 'engine/land-queue.test.sh'])), [
    'engine/land-direct-main.test.sh',
    'engine/land-queue.test.sh',
  ]);
});

test('maps incident guard changes to ruling and lesson allocation coverage', () => {
  assert.deepEqual(focusedTestPaths([
    'engine/state/incident-guards.json',
  ], new Set(['engine/check-rulings.test.sh', 'engine/land-direct-main.test.sh'])), [
    'engine/check-rulings.test.sh',
    'engine/land-direct-main.test.sh',
  ]);
});

test('maps the hand watchdog and production anomaly monitor to live regressions', () => {
  assert.deepEqual(new Set(focusedTestPaths([
    'engine/night/hand-agent-watchdog.sh',
    'engine/night/node-health.sh',
  ], new Set([
    'engine/night/night.test.sh',
    'engine/night/node-health-rules.test.sh',
    'engine/night/prod-errors-readonly.test.sh',
    'engine/night/prod-errors-assess.test.py',
    'engine/night/pipeline-codex-pid.test.sh',
  ]))), new Set([
    'engine/night/night.test.sh',
    'engine/night/node-health-rules.test.sh',
    'engine/night/pipeline-codex-pid.test.sh',
    'engine/night/prod-errors-assess.test.py',
    'engine/night/prod-errors-readonly.test.sh',
  ]));
});

test('maps lesson document changes to lesson ID allocation coverage', () => {
  assert.deepEqual(focusedTestPaths([
    'lessons/RULES.md',
  ], new Set(['engine/land-direct-main.test.sh'])), [
    'engine/land-direct-main.test.sh',
  ]);
});

test('maps lesson changes to a same-named suite under configured pipeline roots', () => {
  const repo = mkdtempSync(join(tmpdir(), 'focused-configured-suite-'));
  const suite = 'project-tests/land-direct-main.test.sh';
  try {
    mkdirSync(join(repo, '.zenoforge'), { recursive: true });
    writeFileSync(join(repo, '.zenoforge/ci.json'), JSON.stringify({ pipeline_suite_roots: ['project-tests'] }));
    assert.deepEqual(focusedTestPaths(['lessons/x.md'], new Set([suite]), { cwd: repo }), [suite]);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test('intersects selected suites when main changes a shared landing helper', () => {
  assert.deepEqual(intersectingFocusedTestPaths(
    ['engine/land-direct-main.sh'],
    ['engine/land-direct-main-bootstrap.sh'],
    new Set([
      'engine/land-direct-main.test.sh',
      'engine/jq-arg-safety.test.sh',
      'engine/notify.test.sh',
      'engine/queue-order.test.sh',
    ]),
  ), [
    'engine/jq-arg-safety.test.sh',
    'engine/land-direct-main.test.sh',
    'engine/notify.test.sh',
    'engine/queue-order.test.sh',
  ]);
});

test('returns no focused suites for a disjoint main advance', () => {
  assert.deepEqual(intersectingFocusedTestPaths(
    ['engine/land-direct-main.sh'],
    ['docs/agents/landing.md'],
    new Set([
      'engine/land-direct-main.test.sh',
      'engine/jq-arg-safety.test.sh',
      'engine/notify.test.sh',
      'engine/queue-order.test.sh',
    ]),
  ), []);
});

test('maps deploy culprit helper to release regression', () => {
  assert.deepEqual(focusedTestPaths([
    'engine/deploy-culprit.sh',
  ], new Set(['engine/run-release.test.sh'])), [
    'engine/run-release.test.sh',
  ]);
});

test('keeps release concurrency default regression selected when runner changes', () => {
  assert.deepEqual(focusedTestPaths([
    'engine/run-release.test.sh',
  ], new Set([
    'engine/run-release.test.sh',
    'engine/run-release-group-summary.test.sh',
  ])), [
    'engine/run-release-group-summary.test.sh',
    'engine/run-release.test.sh',
  ]);
});

test('maps maintainer health mail runner to notify contract coverage', () => {
  assert.deepEqual(focusedTestPaths([
    'engine/night/maintainer-health-mail.sh',
  ], new Set([
    'engine/night/maintainer-health-mail.test.sh',
    'engine/notify.test.sh',
    'engine/night/daily-perf-report.test.sh',
    'engine/night/maintainer-health-mail-incident.test.sh',
  ])), [
    'engine/night/daily-perf-report.test.sh',
    'engine/night/maintainer-health-mail-incident.test.sh',
    'engine/night/maintainer-health-mail.test.sh',
    'engine/notify.test.sh',
  ]);
});

test('historical ranges use current focused-test mappings', () => {
  const root = mkdtempSync(join(tmpdir(), 'focused-test-history-'));
  const mapper = join(root, 'engine/focused-test-paths.mjs');
  try {
    mkdirSync(dirname(mapper), { recursive: true });
    writeFileSync(mapper, readFileSync(new URL('./focused-test-paths.mjs', import.meta.url), 'utf8'));
    writeFileSync(join(dirname(mapper), 'pack-dir.mjs'), readFileSync(new URL('./pack-dir.mjs', import.meta.url), 'utf8'));
    writeFileSync(join(root, 'engine/roadmap.sh'), '#!/usr/bin/env bash\necho old\n');
    execFileSync('git', ['init', '-q', '-b', 'main'], { cwd: root });
    execFileSync('git', ['config', 'user.name', 'fixture'], { cwd: root });
    execFileSync('git', ['config', 'user.email', 'fixture@example.invalid'], { cwd: root });
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'base'], { cwd: root });
    const base = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
    writeFileSync(join(root, 'engine/roadmap.sh'), '#!/usr/bin/env bash\necho changed\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'historical roadmap change'], { cwd: root });
    const historicalHead = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
    writeFileSync(join(root, 'engine/roadmap-order.test.sh'), '#!/usr/bin/env bash\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'add current roadmap coverage'], { cwd: root });

    const selected = execFileSync(process.execPath, [mapper, '--range', base, historicalHead], {
      cwd: root,
      encoding: 'utf8',
    }).trim().split('\n');
    assert.deepEqual(selected, ['engine/roadmap-order.test.sh']);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('mail lifecycle changes always select the release integration regression', () => {
  const release = 'engine/run-release.test.sh';
  for (const path of [
    'engine/night/maintainer-health-mail.sh',
    'engine/night/maintainer-health-mail.test.sh',
    'engine/night/maintainer-health-mail-incident.test.sh',
    'engine/notify.sh',
    'engine/notify.test.sh',
  ]) {
    assert.ok(focusedTestPaths([path], new Set([path, release])).includes(release), path);
  }
});

test('maps release acceptance to both release regression and incident follow-up coverage', () => {
  assert.deepEqual(focusedTestPaths([
    'engine/run-release.sh',
  ], new Set([
    'engine/run-release.test.sh',
    'engine/night/maintainer-health-mail-incident.test.sh',
  ])), [
    'engine/night/maintainer-health-mail-incident.test.sh',
    'engine/run-release.test.sh',
  ]);
});

test('maps daily performance timer files and timer registry to their checks', () => {
  assert.deepEqual(focusedTestPaths([
    'engine/systemd/pipeline-timers.list',
    '.zenoforge/systemd/pipeline-timers.list',
    'engine/systemd/zenoforge-daily-perf-report.service',
    'engine/systemd/zenoforge-daily-perf-report.timer',
    'engine/systemd/zenoforge-health-maintenance.service',
    'engine/systemd/zenoforge-health-maintenance.timer',
    'engine/systemd/zenoforge-health-mail.service',
    'engine/systemd/zenoforge-health-mail.timer',
  ], new Set(['engine/run-tick.test.sh', 'engine/night/daily-perf-report.test.sh', 'engine/night/night.test.sh'])), [
    'engine/night/daily-perf-report.test.sh',
    'engine/night/night.test.sh',
    'engine/run-tick.test.sh',
  ]);
});

test('maps daily performance script to its fake-ledger suite', () => {
  assert.deepEqual(focusedTestPaths([
    'engine/night/daily-perf-report.sh',
  ], new Set(['engine/night/daily-perf-report.test.sh'])), [
    'engine/night/daily-perf-report.test.sh',
  ]);
});

test('fails closed when a changed pipeline script lacks focused test', () => {
  assert.throws(() => focusedTestPaths([
    'engine/uncovered.sh',
  ], new Set()), /No focused test exists/);
  assert.throws(() => focusedTestPaths([
    'engine/roadmap.sh',
  ], new Set()), /No focused test exists/);
});

test('adds each sourced helper caller suite for functions changed in its diff', () => {
  const root = mkdtempSync(join(tmpdir(), 'focused-test-paths-'));
  const files = {
    'engine/lib.sh': 'admit_guarded_leaf() { printf old; }\nadmit_guarded_inner() { admit_guarded_leaf "$1"; }\nadmit_guarded() { admit_guarded_inner "$1"; }\nother_helper() { :; }\n',
    'engine/lib.test.sh': '#!/usr/bin/env bash\nsource "$SCRIPT_DIR/lib.sh"\nadmit_guarded expected\n',
    'engine/run-advisor.sh': 'source "$SCRIPT_DIR/lib.sh"\nadmit_guarded "$N"\n',
    'engine/run-advisor.test.sh': '#!/usr/bin/env bash\n',
    'engine/run-advisor-batch.sh': 'source "$SCRIPT_DIR/lib.sh"\nadmit_guarded "$n"\n',
    'engine/run-advisor-batch.test.sh': '#!/usr/bin/env bash\n',
    'engine/run-recut.sh': 'source "$SCRIPT_DIR/lib.sh"\nadmit_guarded "$N"\n',
    'engine/run-recut.test.sh': '#!/usr/bin/env bash\n',
    'engine/night/merge-lock.test.sh': '#!/usr/bin/env bash\nsource "$SCRIPT_DIR/../lib.sh"\nadmit_guarded "$N"\n',
    'engine/unrelated.sh': 'source "$SCRIPT_DIR/lib.sh"\nother_helper\n',
    'engine/unrelated.test.sh': '#!/usr/bin/env bash\n',
    'engine/filename-only.test.sh': '# lib.sh appears only in this fixture note\n',
  };

  try {
    execFileSync('git', ['init', '-q', '-b', 'main'], { cwd: root });
    execFileSync('git', ['config', 'user.name', 'fixture'], { cwd: root });
    execFileSync('git', ['config', 'user.email', 'fixture@example.invalid'], { cwd: root });
    for (const [path, content] of Object.entries(files)) {
      const fullPath = join(root, path);
      mkdirSync(dirname(fullPath), { recursive: true });
      writeFileSync(fullPath, content);
    }
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'base'], { cwd: root });
    const baseRef = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
    writeFileSync(join(root, 'engine/lib.sh'), 'admit_guarded_leaf() { printf new; }\nadmit_guarded_inner() { admit_guarded_leaf "$1"; }\nadmit_guarded() { admit_guarded_inner "$1"; }\nother_helper() { :; }\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'change helper body'], { cwd: root });
    const tracked = new Set(execFileSync('git', ['ls-tree', '-r', '--name-only', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim().split('\n'));

    const selected = focusedTestPaths(['engine/lib.sh'], tracked, {
      baseRef,
      headRef: 'HEAD',
      cwd: root,
    });
    assert.deepEqual(selected, [
      'engine/lib.test.sh',
      'engine/night/merge-lock.test.sh',
      'engine/run-advisor-batch.test.sh',
      'engine/run-advisor.test.sh',
      'engine/run-recut.test.sh',
    ]);
    assert.deepEqual(intersectingFocusedTestPaths(
      ['engine/lib.sh'],
      ['engine/lib.sh'],
      tracked,
      {
        branch: { baseRef, headRef: 'HEAD', cwd: root },
        main: { baseRef, headRef: 'HEAD', cwd: root },
      },
    ), selected);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('function selection keeps caller suite that fails when changed helper function is broken', () => {
  const root = mkdtempSync(join(tmpdir(), 'focused-test-mutation-'));
  const files = {
    'engine/lib.sh': 'check_value_locked() { [[ "$1" == expected ]]; }\ncheck_value_inner() { check_value_locked "$1"; }\ncheck_value() { check_value_inner "$1"; }\n',
    'engine/caller.sh': 'SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"\nsource "$SCRIPT_DIR/lib.sh"\ncall_helper() { check_value "$1"; }\n',
    'engine/caller.test.sh': '#!/usr/bin/env bash\nset -euo pipefail\nSCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"\nsource "$SCRIPT_DIR/caller.sh"\ncall_helper expected\n',
    'engine/land-direct-main.test.sh': '# seed repo copies lib.sh\n',
    'engine/indirect-loader.test.mjs': 'import { execFileSync } from "node:child_process";\nexecFileSync("bash", ["-c", "source engine/lib.sh; check_value expected"]);\n',
    'engine/filename-only.test.sh': '# lib.sh copied as fixture; does not call check_value\n',
  };

  try {
    execFileSync('git', ['init', '-q', '-b', 'main'], { cwd: root });
    execFileSync('git', ['config', 'user.name', 'fixture'], { cwd: root });
    execFileSync('git', ['config', 'user.email', 'fixture@example.invalid'], { cwd: root });
    for (const [path, content] of Object.entries(files)) {
      const fullPath = join(root, path);
      mkdirSync(dirname(fullPath), { recursive: true });
      writeFileSync(fullPath, content);
    }
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'base'], { cwd: root });
    const baseRef = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
    execFileSync(process.execPath, ['engine/indirect-loader.test.mjs'], { cwd: root });
    writeFileSync(join(root, 'engine/lib.sh'), 'check_value_locked() { [[ "$1" != expected ]]; }\ncheck_value_inner() { check_value_locked "$1"; }\ncheck_value() { check_value_inner "$1"; }\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'mutate changed helper'], { cwd: root });

    const tracked = new Set(execFileSync('git', ['ls-tree', '-r', '--name-only', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim().split('\n'));
    const selected = focusedTestPaths(['engine/lib.sh'], tracked, {
      baseRef,
      headRef: 'HEAD',
      cwd: root,
    });
    assert.ok(selected.includes('engine/caller.test.sh'));
    assert.ok(selected.includes('engine/indirect-loader.test.mjs'));
    assert.ok(!selected.includes('engine/filename-only.test.sh'));
    assert.throws(() => execFileSync('bash', [selected[0]], {
      cwd: root,
      stdio: 'pipe',
    }), (error) => error.status === 1);
    assert.throws(() => execFileSync(process.execPath, ['engine/indirect-loader.test.mjs'], {
      cwd: root,
      stdio: 'pipe',
    }), (error) => error.status === 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

function withFilenameFixture(callback) {
  const root = mkdtempSync(join(tmpdir(), 'focused-test-filenames-'));
  const files = {
    'engine/supervise-pipeline.sh': '#!/usr/bin/env bash\n',
    'engine/supervise-pipeline.test.sh': '#!/usr/bin/env bash\n',
    'engine/supervise-exceptions.test.sh': '# references supervise-pipeline.sh through a copied fixture\n',
    'engine/lib.sh': '#!/usr/bin/env bash\n',
    'engine/lib.test.sh': '#!/usr/bin/env bash\n',
    'engine/land-direct-main.test.sh': '# seed repo copies lib.sh\n',
    'engine/filename-only.test.sh': '# lib.sh is copied into a fixture\n',
    'engine/uncovered-helper.sh': '#!/usr/bin/env bash\n',
    'engine/indirect-loader.test.mjs': '// fixture loads uncovered-helper.sh\n',
    'engine/night/maintainer-health-mail.sh': 'claim_digest() { printf old; }\n',
    'engine/night/maintainer-health-mail.test.sh': 'source "$SCRIPT_DIR/maintainer-health-mail.sh"\nclaim_digest\n',
    'engine/run-release.test.sh': '# fixture runs run-release.sh, which loads mail indirectly\n',
  };

  try {
    execFileSync('git', ['init', '-q', '-b', 'main'], { cwd: root });
    execFileSync('git', ['config', 'user.name', 'fixture'], { cwd: root });
    execFileSync('git', ['config', 'user.email', 'fixture@example.invalid'], { cwd: root });
    for (const [path, content] of Object.entries(files)) {
      const fullPath = join(root, path);
      mkdirSync(dirname(fullPath), { recursive: true });
      writeFileSync(fullPath, content);
    }
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'base'], { cwd: root });
    const tracked = new Set(execFileSync('git', ['ls-tree', '-r', '--name-only', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim().split('\n'));
    callback({
      root,
      tracked,
      refs: { baseRef: 'HEAD', headRef: 'HEAD', cwd: root },
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test('maps filename-referencing suite for indirect supervise-pipeline fixture', () => {
  withFilenameFixture(({ tracked, refs }) => {
    const selected = focusedTestPaths(['engine/supervise-pipeline.sh'], tracked, refs);
    assert.ok(selected.includes('engine/supervise-exceptions.test.sh'));
  });
});

test('shared JSON default mutations select referencing shell and Node fixtures', () => {
  withFilenameFixture(({ root, tracked }) => {
    const policy = 'engine/model-policy.default.json';
    const shellSuite = 'engine/policy-copy.test.sh';
    const nodeSuite = 'engine/policy-read.test.mjs';
    writeFileSync(join(root, policy), '{"enabled":true}\n');
    writeFileSync(join(root, shellSuite), '# fixture copies model-policy.default.json\n');
    writeFileSync(join(root, nodeSuite), 'import assert from "node:assert/strict";\nimport { readFileSync } from "node:fs";\nassert.equal(JSON.parse(readFileSync("engine/model-policy.default.json", "utf8")).enabled, true);\n');
    for (const path of [policy, shellSuite, nodeSuite]) tracked.add(path);
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'default policy fixture'], { cwd: root });
    const baseRef = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
    execFileSync(process.execPath, [nodeSuite], { cwd: root });
    writeFileSync(join(root, policy), '{"enabled":false}\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'mutate shared default'], { cwd: root });
    const selected = focusedTestPaths([policy], tracked, { baseRef, headRef: 'HEAD', cwd: root });
    assert.deepEqual(selected, [shellSuite, nodeSuite]);
    assert.throws(() => execFileSync(process.execPath, [nodeSuite], { cwd: root, stdio: 'pipe' }),
      (error) => error.status === 1);
  });
});

test('function caller selection retains the indirect release mail regression', () => {
  withFilenameFixture(({ root, tracked }) => {
    const baseRef = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
    writeFileSync(join(root, 'engine/night/maintainer-health-mail.sh'), 'claim_digest() { printf new; }\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'change digest helper'], { cwd: root });
    const selected = focusedTestPaths(['engine/night/maintainer-health-mail.sh'], tracked, {
      baseRef, headRef: 'HEAD', cwd: root,
    });
    assert.ok(selected.includes('engine/night/maintainer-health-mail.test.sh'));
    assert.ok(selected.includes('engine/run-release.test.sh'));
  });
});

test('maps filename-referencing suite for lib.sh seed repo fixture', () => {
  withFilenameFixture(({ tracked, refs }) => {
    const selected = focusedTestPaths(['engine/lib.sh'], tracked, refs);
    assert.ok(selected.includes('engine/land-direct-main.test.sh'));
  });
});

test('uses filename-referencing suites when script has no mapped or same-named test', () => {
  withFilenameFixture(({ tracked, refs }) => {
    assert.deepEqual(focusedTestPaths(['engine/uncovered-helper.sh'], tracked, refs), [
      'engine/indirect-loader.test.mjs',
    ]);
  });
});

test('falls back to filename selection outside a function and after shell parse failure', () => {
  withFilenameFixture(({ root, tracked }) => {
    const baseRef = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
    writeFileSync(join(root, 'engine/lib.sh'), '#!/usr/bin/env bash\nLIB_MODE=changed\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'change top-level setting'], { cwd: root });
    let selected = focusedTestPaths(['engine/lib.sh'], tracked, {
      baseRef,
      headRef: 'HEAD',
      cwd: root,
    });
    assert.ok(selected.includes('engine/land-direct-main.test.sh'));
    assert.ok(selected.includes('engine/filename-only.test.sh'));

    const nextBaseRef = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
    writeFileSync(join(root, 'engine/lib.sh'), '#!/usr/bin/env bash\nfunction broken() {\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'leave parse error'], { cwd: root });
    selected = focusedTestPaths(['engine/lib.sh'], tracked, {
      baseRef: nextBaseRef,
      headRef: 'HEAD',
      cwd: root,
    });
    assert.ok(selected.includes('engine/land-direct-main.test.sh'));
    assert.ok(selected.includes('engine/filename-only.test.sh'));
  });
});

function withReferenceFixture(callback) {
  const root = mkdtempSync(join(tmpdir(), 'focused-test-references-'));
  const files = {
    // #4543 shape: a suite reads a workflow file by full path.
    '.github/workflows/ci.yml': 'jobs: {}\n',
    'engine/ci-lane.test.mjs': '// pins runner lanes from .github/workflows/ci.yml\n',
    // #4599 shape: a lint registry anchors lib.sh, and only its own suite follows.
    'engine/lib.sh': '#!/usr/bin/env bash\n',
    'engine/lesson-lints.mjs': 'const lib = "engine/lib.sh";\n',
    'engine/lesson-lints.test.mjs': 'import { lessonLints } from "./lesson-lints.mjs";\n',
    'engine/policy-reader.test.sh': '# greps engine/lesson-lints.mjs for its anchors\n',
    'engine/night/queue.sh': '#!/usr/bin/env bash\n',
    'engine/queue-consumer.test.sh': '# fixture copies night/queue.sh\n',
  };
  try {
    execFileSync('git', ['init', '-q', '-b', 'main'], { cwd: root });
    execFileSync('git', ['config', 'user.name', 'fixture'], { cwd: root });
    execFileSync('git', ['config', 'user.email', 'fixture@example.invalid'], { cwd: root });
    for (const [path, content] of Object.entries(files)) {
      const fullPath = join(root, path);
      mkdirSync(dirname(fullPath), { recursive: true });
      writeFileSync(fullPath, content);
    }
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'base'], { cwd: root });
    callback({
      root,
      files,
      tracked: new Set(Object.keys(files)),
      commit: (message) => {
        execFileSync('git', ['add', '.'], { cwd: root });
        execFileSync('git', ['commit', '-qm', message], { cwd: root });
        return execFileSync('git', ['rev-parse', 'HEAD~1'], { cwd: root, encoding: 'utf8' }).trim();
      },
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test('a changed file referenced by path selects the referencing suite', () => {
  withReferenceFixture(({ root, tracked, commit }) => {
    writeFileSync(join(root, '.github/workflows/ci.yml'), 'jobs: {ci: {}}\n');
    const baseRef = commit('change workflow lanes');
    for (const refs of [{ baseRef, headRef: 'HEAD', cwd: root }, { cwd: root }]) {
      assert.deepEqual(focusedTestPaths(['.github/workflows/ci.yml'], tracked, refs), [
        'engine/ci-lane.test.mjs',
      ]);
    }
  });
});

test('a deleted file referenced by filename keeps the referencing suite selected', () => {
  withReferenceFixture(({ root, tracked, commit }) => {
    rmSync(join(root, 'engine/night/queue.sh'));
    const baseRef = commit('retire the night queue');
    assert.deepEqual(focusedTestPaths(['engine/night/queue.sh'], tracked, {
      baseRef,
      headRef: 'HEAD',
      cwd: root,
    }), ['engine/queue-consumer.test.sh']);
  });
});

test('a script anchoring a changed file carries its own suite, not every naming test', () => {
  withReferenceFixture(({ root, tracked, commit }) => {
    writeFileSync(join(root, 'engine/lib.sh'), '#!/usr/bin/env bash\nLIB_MODE=changed\n');
    const baseRef = commit('change lib.sh');
    for (const refs of [{ baseRef, headRef: 'HEAD', cwd: root }, { cwd: root }]) {
      const selected = focusedTestPaths(['engine/lib.sh'], tracked, refs);
      assert.deepEqual(selected, ['engine/lesson-lints.test.mjs']);
    }
  });
});

test('focused suites run last-failed first, then fastest first, with unknown suites at the median', () => {
  const records = {
    'engine/slow.test.sh': { duration_ms: 300000, status: 'pass' },
    'engine/fast.test.sh': { duration_ms: 6000, status: 'pass' },
    'engine/mid.test.sh': { duration_ms: 60000, status: 'pass' },
    'engine/red.test.sh': { duration_ms: 900000, status: 'fail' },
    'engine/timed-out.test.sh': { duration_ms: 120000, status: 'timeout' },
  };
  const paths = [
    'engine/slow.test.sh',
    'engine/unknown.test.sh',
    'engine/fast.test.sh',
    'engine/mid.test.sh',
    'engine/timed-out.test.sh',
    'engine/red.test.sh',
  ];
  assert.deepEqual(orderFocusedTestPaths(paths, records), [
    'engine/timed-out.test.sh',
    'engine/red.test.sh',
    'engine/fast.test.sh',
    'engine/mid.test.sh',
    'engine/unknown.test.sh',
    'engine/slow.test.sh',
  ]);
  assert.deepEqual(orderFocusedTestPaths(paths, {}), [...paths].sort(), 'no records keeps a deterministic order');
  assert.deepEqual(orderFocusedTestPaths(['engine/fast.test.sh', 'engine/fast.test.sh'], records),
    ['engine/fast.test.sh', 'engine/fast.test.sh'], 'ordering never drops a listed run');
});

test('leaves changed package vitest files to their package gate', () => {
  const root = mkdtempSync(join(tmpdir(), 'focused-vitest-'));
  try {
    const vitest = 'packages/example-runtime/tests/a.test.mjs';
    const nodeTest = 'packages/example-service/tests/b.test.mjs';
    for (const [path, text] of [[vitest, "import { test } from 'vitest';\n"], [nodeTest, "import test from 'node:test';\n"]]) {
      mkdirSync(dirname(join(root, path)), { recursive: true });
      writeFileSync(join(root, path), text);
    }
    assert.deepEqual(focusedTestPaths([vitest, nodeTest], new Set([vitest, nodeTest]), { cwd: root }), [nodeTest]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
