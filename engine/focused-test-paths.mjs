import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readPackJson } from './pack-dir.mjs';

// Where the pack sits in the target repository (ZF_PACK_REL, config.sh). The tables and rules below name pack paths as
// engine/...; packPath re-roots one onto PACK_PREFIX. Same string unless the deployment moved the pack.
const PACK_REL = process.env.ZF_PACK_REL || 'engine';
const PACK_PREFIX = `${PACK_REL}/`;
const packPath = (path) => path.startsWith('engine/') ? PACK_PREFIX + path.slice('engine/'.length) : path;

const DEPENDENCY_FILE_TESTS = Object.freeze([
  // Suites that import an installed package (yaml) or spawn loaders, plus suites naming the files.
  'engine/ci-priority-lane.test.mjs',
  'engine/ci-runner-lanes.test.mjs',
  'engine/check-rulings.test.sh',
  'engine/ci-toolchain-preflight.test.mjs',
  'engine/landing-fast-path.test.mjs',
  'engine/ci-infrastructure-focused.test.sh',
  'engine/link-worktree-dependencies.test.sh',
  'scripts/ci/dagger-input.test.mjs',
  'scripts/ensure-ci-runner-disk.test.mjs',
  'scripts/deploy-regression-contract.test.mjs',
].map(packPath));

const CI_TREE_TESTS = Object.freeze([
  'engine/ci-infrastructure-focused.test.sh',
  'engine/ci-toolchain-preflight.test.mjs',
  'engine/ci-wiring-pr-skips-full-plane.test.mjs',
  'scripts/ci/dagger-input.test.mjs',
  'scripts/ci/dagger-run.test.mjs',
  'scripts/ci/prepare-dagger-input.test.mjs',
].map(packPath));

export const RELATED_TESTS = new Map([
  ['engine/eval/graders.mjs', ['engine/eval/graders.test.mjs', 'engine/eval/compare.test.mjs', 'engine/eval/runner.test.mjs', 'engine/eval/cases.test.mjs']],
  ['engine/eval/compare.mjs', ['engine/eval/graders.test.mjs', 'engine/eval/compare.test.mjs', 'engine/eval/runner.test.mjs', 'engine/eval/cases.test.mjs']],
  ['engine/eval/run-eval.mjs', ['engine/eval/graders.test.mjs', 'engine/eval/compare.test.mjs', 'engine/eval/runner.test.mjs', 'engine/eval/cases.test.mjs']],
  ['engine/eval/stage-call.sh', ['engine/eval/graders.test.mjs', 'engine/eval/compare.test.mjs', 'engine/eval/runner.test.mjs', 'engine/eval/cases.test.mjs']],
  ['engine/eval/cases/triage.json', ['engine/eval/graders.test.mjs', 'engine/eval/compare.test.mjs', 'engine/eval/runner.test.mjs', 'engine/eval/cases.test.mjs']],
  ['engine/eval/cases/advisor.json', ['engine/eval/graders.test.mjs', 'engine/eval/compare.test.mjs', 'engine/eval/runner.test.mjs', 'engine/eval/cases.test.mjs']],
  ['engine/eval/cases/implement.json', ['engine/eval/graders.test.mjs', 'engine/eval/compare.test.mjs', 'engine/eval/runner.test.mjs', 'engine/eval/cases.test.mjs']],
  ['engine/eval/cases/review.json', ['engine/eval/graders.test.mjs', 'engine/eval/compare.test.mjs', 'engine/eval/runner.test.mjs', 'engine/eval/cases.test.mjs']],
  ['engine/eval/cases/end-to-end.json', ['engine/eval/graders.test.mjs', 'engine/eval/compare.test.mjs', 'engine/eval/runner.test.mjs', 'engine/eval/cases.test.mjs']],
  ['engine/eval/README.md', ['engine/eval/graders.test.mjs', 'engine/eval/compare.test.mjs', 'engine/eval/runner.test.mjs', 'engine/eval/cases.test.mjs']],
  ['engine/codex-repair-run.sh', ['engine/repair-resume.test.sh']],
  ['engine/mac-autopilot/scheduler.sh', [
    'engine/repair-resume.test.sh',
    'engine/mac-autopilot/scheduler.test.sh',
    'engine/mac-autopilot/scheduler-gates.test.sh',
    'engine/mac-autopilot/scheduler-self-check.test.sh',
    'engine/mac-autopilot/worker-rules-lanes.test.sh',
    'engine/mac-autopilot/usage_reader.test.sh',
  ]],
  ['docs/agents/issue-pipeline.md', ['engine/repair-resume.test.sh']],
  ['package.json', DEPENDENCY_FILE_TESTS],
  ['pnpm-lock.yaml', DEPENDENCY_FILE_TESTS],
  ['pnpm-workspace.yaml', DEPENDENCY_FILE_TESTS],
  ['.dagger/**', CI_TREE_TESTS],
  ['scripts/ci/**', [...CI_TREE_TESTS, 'engine/blind-rerun-gate.test.sh']],
  ['.github/workflows/agent-workflow-contract.yml', [
    'engine/ci-priority-lane.test.mjs',
    'engine/pipeline-system-deliver.test.mjs',
    'scripts/deploy-regression-contract.test.mjs',
  ]],
  // The worker prompt reads the product-boundary lines from CLAUDE.md.
  ['CLAUDE.md', ['engine/mac-autopilot/worker-rules-lanes.test.sh']],
  ['CONTRIBUTING.md', ['engine/mac-autopilot/worker-rules-lanes.test.sh']],
  ['GLOSSARY.md', ['engine/mac-autopilot/worker-rules-lanes.test.sh']],
  ['docs/adr/**', ['engine/mac-autopilot/worker-rules-lanes.test.sh']],
  ['.trellis/spec/**', ['engine/mac-autopilot/worker-rules-lanes.test.sh']],
  ['engine/mac-autopilot/required-pr-checks.json', [
    'engine/ci-priority-lane.test.mjs',
    'engine/hold.test.sh',
    'engine/lib.test.sh',
    'engine/merge-gate-checks-fail-closed.test.sh',
    'engine/mac-autopilot/scheduler-gates.test.sh',
    'engine/sweep-merges.test.sh',
    'scripts/deploy-regression-contract.test.mjs',
  ]],
  ['engine/execution-admission.py', ['engine/execution-admission.test.sh', 'engine/execution-admission-metrics.test.sh']],
  ['engine/mac-autopilot/roi_ledger.py', ['engine/mac-autopilot/worker_cost.test.sh']],
  ['engine/mac-autopilot/roi_collect.py', ['engine/mac-autopilot/worker_cost.test.sh']],
  ['engine/mac-autopilot/roi_rollup.py', ['engine/mac-autopilot/worker_cost.test.sh']],
  ['engine/execution-admission.test.py', ['engine/execution-admission.test.sh']],
  ['engine/execution-admission-metrics.test.py', ['engine/execution-admission-metrics.test.sh']],
  ['engine/execution-shim/systemd-run', ['engine/execution-admission.test.sh']],
  ['engine/open-pr-snapshot.py', ['engine/tick-speed.test.sh']],
  ['engine/open-pr-snapshot.test.py', ['engine/tick-speed.test.sh']],
  // The test wrapper delegates to Python, which executes the installer in an isolated HOME.
  ['engine/install-traffic-monitor.sh', ['engine/network-traffic.test.sh']],
  ['engine/network-traffic.py', ['engine/network-traffic.test.sh']],
  ['engine/network-traffic-check.py', ['engine/network-traffic.test.sh']],
  // This gate and its suite were retired; the preflight contracts prove its removal.
  ['engine/ci-runner-lanes.mjs', ['engine/ci-runner-lanes.test.mjs']],
  ['engine/ci-reserved-runners.mjs', ['engine/ci-priority-lane.test.mjs']],
  ['.github/workflows/pipeline-suites.yml', [
    'engine/ci-runner-lanes.test.mjs',
    'engine/pipeline-suites-scope.test.mjs',
    'scripts/deploy-regression-contract.test.mjs',
  ]],
  ['scripts/check-regression-contract-teeth.mjs', [
    'scripts/branch-delivery-preflight.test.mjs',
    'scripts/deploy-regression-contract.test.mjs',
  ]],
  ['scripts/ops/nexus-retention.py', ['engine/nexus-retention-reference-owners.test.sh']],
  ['scripts/ops/nexus-retention.test.py', ['engine/nexus-retention-reference-owners.test.sh']],
  // #2774 wrapped the Postsubmit runner call and turned this incident probe red on main unnoticed.
  // pipeline-suites-scope.test.mjs pins the workflow structure and FULL_SUITE_PATHS membership;
  // 845f5cb1b landed a ci.yml edit with that suite stale and main stayed red ~2h (#4359).
  ['.github/workflows/ci.yml', [
    'engine/pipeline-suites-scope.test.mjs',
    'scripts/deploy-regression-contract.test.mjs',
    'scripts/ensure-ci-runner-disk.test.mjs',
  ]],
  ['engine/ci/pr-required-aggregate.mjs', ['engine/ci/pr-required-aggregate.test.mjs']],
  ['.github/workflows/migration-sql-gate.yml', ['scripts/deploy-regression-contract.test.mjs']],
  ['engine/git-merge-state-json.sh', ['engine/state-json-merge.test.sh', 'engine/land-direct-main.test.sh']],
  ['engine/land-direct-main-bootstrap.sh', ['engine/land-direct-main.test.sh', 'engine/pipeline-system-deliver.test.mjs']],
  ['engine/land-direct-main.sh', ['engine/land-direct-main.test.sh', 'engine/pipeline-system-deliver.test.mjs']],
  ['engine/rule-lane.sh', ['engine/land-direct-main.test.sh']],
  ['engine/state/rule-files.json', ['engine/land-direct-main.test.sh']],
  ['engine/state/rulings.json', ['engine/state/rulings.test.mjs']],
  ['engine/land-queue.sh', ['engine/land-queue.test.sh', 'engine/land-direct-main.test.sh', 'engine/land-queue-completed-rebase.test.sh']],
  ['engine/roadmap.sh', ['engine/roadmap-order.test.sh']],
  ['engine/check-rulings.sh', [
    'engine/check-rulings.test.sh',
    'engine/night/night.test.sh',
    'scripts/branch-delivery-preflight.test.mjs',
  ]],
  // Remaining readers of the incident registry data.
  ['engine/state/incident-guards.json', [
    'engine/check-rulings.test.sh',
    'engine/land-direct-main.test.sh',
    'engine/lesson-fragments.test.sh',
    'engine/night/founder-health-mail.test.sh',
    'engine/night/incident-guard-audit.test.mjs',
    'engine/pipeline-system-deliver.test.mjs',
    'scripts/branch-delivery-preflight.test.mjs',
  ]],
  ['engine/gh-auto-merge-guard.sh', ['engine/night/merge-lock.test.sh']],
  ['engine/install-gitnexus-wrapper.sh', ['engine/gitnexus-wrapper.test.sh']],
  ['engine/record-unit-result.sh', ['engine/issue-pipeline.test.sh']],
  ['engine/advisor-core.sh', [
    'engine/run-advisor.test.sh',
    'engine/run-advisor-batch.test.sh',
  ]],
  ['engine/night/dispatch.sh', ['engine/night/night.test.sh', 'engine/night/hand-handoff-chain.test.sh']],
  ['engine/night/hand-exit-handoff.sh', ['engine/night/hand-handoff-chain.test.sh', 'engine/night/night.test.sh']],
  ['engine/night/night-test-progress.mjs', [
    'engine/night/night-test-progress.test.mjs',
    'engine/night/night.test.sh',
    'scripts/branch-delivery-preflight.test.mjs',
  ]],
  ['engine/night/night.test.sh', ['engine/night/night-test-progress.test.mjs']],
  ['engine/night/hand-agent-watchdog.sh', [
    'engine/night/night.test.sh',
    'engine/night/pipeline-codex-pid.test.sh',
  ]],
  ['engine/night/daily-perf-report.sh', ['engine/night/daily-perf-report.test.sh']],
  ['engine/night/efficiency-regression.mjs', ['engine/night/efficiency-regression.test.mjs']],
  ['engine/night/founder-health-mail.sh', [
    'engine/night/founder-health-mail.test.sh',
    'engine/night/founder-health-mail-incident.test.sh',
    'engine/notify.test.sh',
    'engine/night/daily-perf-report.test.sh',
    'engine/run-release.test.sh',
  ]],
  ['engine/night/founder-health-mail.test.sh', ['engine/run-release.test.sh']],
  ['engine/night/founder-health-mail-incident.test.sh', ['engine/run-release.test.sh']],
  ['engine/notify.sh', ['engine/notify.test.sh', 'engine/run-release.test.sh']],
  ['engine/notify.test.sh', ['engine/run-release.test.sh']],
  ['engine/run-release.sh', [
    'engine/run-release-shard-profiles.test.sh',
    'engine/run-release.test.sh',
    'engine/night/founder-health-mail-incident.test.sh',
    'engine/container-audit.test.sh',
  ]],
  ['engine/run-release.test.sh', ['engine/run-release-group-summary.test.sh']],
  ['engine/hotfix-loss-probe.sh', ['engine/release-hotfix-snapshot.test.sh']],
  ['engine/release-drift-capture.sh', ['engine/release-drift-capture.test.sh']],
  ['engine/release-drift-carried.sh', ['engine/release-drift-capture.test.sh']],
  ['engine/systemd/pipeline-timers.list', [
    'engine/run-tick.test.sh',
    'engine/night/daily-perf-report.test.sh',
    'engine/night/night.test.sh',
    'engine/night/node-health-rules.test.sh',
    'engine/rescue-local-writes.test.sh',
  ]],
  ['engine/rescue-local-writes.sh', ['engine/rescue-local-writes.test.sh']],
  ['engine/night/node-health.sh', [
    'engine/night/node-health-rules.test.sh',
    'engine/night/prod-errors-readonly.test.sh',
    'engine/night/prod-errors-assess.test.py',
  ]],
  ['scripts/ensure-ci-runner-disk.sh', ['scripts/ensure-ci-runner-disk.test.mjs']],
  ['engine/night/node-health-rules.sh', [
    'engine/night/node-health-rules.test.sh',
    'engine/night/prod-errors-readonly.test.sh',
    'engine/night/prod-errors-assess.test.py',
  ]],
  ['engine/night/prod-errors-readonly.sh', ['engine/night/prod-errors-readonly.test.sh', 'engine/night/node-health-rules.test.sh']],
  ['engine/night/health-maintenance.sh', ['engine/night/health-maintenance.test.sh']],
  ['engine/probe-codex-sandbox.sh', ['engine/lib.test.sh']],
  ['engine/deploy-culprit.sh', ['engine/run-release.test.sh']],
  ['engine/post-deploy-migrations.mjs', ['engine/post-deploy-migrations.test.mjs', 'engine/run-release.test.sh']],
  ['engine/post-deploy-migrations.test.mjs', ['engine/post-deploy-migrations.test.mjs']],
  // git-fetch-bounded.test.sh greps these scripts for network git calls that escalate after 10s.
  ['engine/worktree-lifecycle.sh', ['engine/worktree-lifecycle.test.sh', 'engine/git-fetch-bounded.test.sh', 'engine/execution-admission.test.sh']],
  ['engine/worktree-backlog-sweep.sh', ['engine/worktree-lifecycle.test.sh']],
  ['engine/supervise-pipeline.sh', ['engine/supervise-pipeline.test.sh', 'engine/git-fetch-bounded.test.sh']],
  ['engine/run-tick.sh', ['engine/run-tick.test.sh', 'engine/git-fetch-bounded.test.sh', 'engine/run-tick-timer-repair.test.sh']],
  ['engine/main-ci-red-replay.mjs', ['engine/main-ci-red-scope.test.sh']],
  ['engine/lib.sh', [
    'engine/ci-priority-lane.test.mjs',
    'engine/ci-flake-classification.test.sh',
    'engine/hold.test.sh',
    'engine/lib.test.sh',
    'engine/main-release-ready-cache.test.sh',
    'engine/pipeline-system-close-evidence.test.sh',
    'engine/main-ci-red-scope.test.sh',
    'engine/sweep-merges.test.sh',
    'engine/optimistic-merge.test.sh',
    'engine/main-red-bisect.test.sh',
    'engine/night/merge-lock.test.sh',
    'engine/guarded-hand-brief.test.sh',
    'engine/git-fetch-bounded.test.sh',
  ]],
  ['engine/prompts/guarded-recut-hand.md', [
    'engine/guarded-hand-brief.test.sh',
    'engine/run-recut.test.sh',
    'engine/hold.test.sh',
  ]],
  ['engine/supervisor-holds.sh', [
    'engine/hold.test.sh',
    'engine/issue-pipeline.test.sh',
    'engine/night/night.test.sh',
    'engine/run-recut.test.sh',
    'engine/guarded-hand-brief.test.sh',
  ]],
  ['engine/write-guard.sh', ['engine/test-write-guard.test.sh']],
  ['engine/lesson-guard-schema.mjs', ['engine/check-rulings.test.sh']],
  ['engine/lesson-fragments.sh', [
    'engine/check-rulings.test.sh',
    'engine/land-direct-main.test.sh',
    'engine/night/night.test.sh',
    'engine/pipeline-system-deliver.test.mjs',
    'scripts/branch-delivery-preflight.test.mjs',
  ]],
  ['engine/verification-plan.mjs', ['engine/verification-plan.test.mjs']],
  ['engine/verification-plan-runtime.sh', [
    'engine/verification-plan-runtime.test.sh',
  ]],
  ['engine/verification-map-audit.mjs', ['engine/verification-map-audit.test.mjs']],
  ['engine/throughput-metrics.mjs', ['engine/throughput-metrics.test.mjs']],
  ['scripts/e2e/yangfeng-regression/catalog.json', [
    'engine/verification-plan.test.mjs',
    'engine/verification-map-audit.test.mjs',
    'scripts/e2e/yangfeng-regression/verify-feature.test.mjs',
  ]],
  ['engine/prod-e2e.mjs', [
    'engine/production-e2e-taxonomy.test.sh',
    'engine/prod-e2e-reporting.test.mjs',
  ]],
  ['engine/ticket-progress.sh', [
    'engine/ticket-progress.test.sh',
    'engine/night/night.test.sh',
  ]],
  ['engine/test-advisor-convergence.sh', ['engine/advisor-convergence.test.mjs']],
  ['scripts/branch-delivery-policy.mjs', ['scripts/branch-delivery-policy.test.mjs']],
  ['engine/ci-repair-receipt.mjs', ['engine/ci-repair-receipt.test.mjs', 'scripts/branch-delivery-preflight.test.mjs', 'engine/pre-push-guard.test.sh']],
  ['scripts/branch-delivery-preflight.mjs', ['scripts/branch-delivery-preflight.test.mjs', 'engine/landing-fast-path.test.mjs']],
  ['engine/focused-test-paths.mjs', ['engine/focused-test-paths.test.mjs', 'engine/landing-fast-path.test.mjs']],
  ['engine/pack-dir.mjs', ['engine/risk-class.test.mjs', 'engine/verification-plan.test.mjs']],
].map(([key, tests]) => [packPath(key), tests.map(packPath)]));

// A pack's state/focused-test-map.json adds or replaces entries; its pack_root lets the same data follow a relocated pack.
// No pack, no file: the generic map stands.
const packTestMap = readPackJson('state/focused-test-map.json') ?? {};
const packDataPrefix = packTestMap.pack_root ? `${packTestMap.pack_root}/` : '';
const packDataPath = (path) => packDataPrefix && path.startsWith(packDataPrefix) ? PACK_PREFIX + path.slice(packDataPrefix.length) : path;
for (const [path, tests] of Object.entries(packTestMap.related_tests ?? {})) RELATED_TESTS.set(packDataPath(path), tests.map(packDataPath));

export const CROSS_SCRIPT_TESTS = Object.freeze([
  // Repo-wide scan: a direct (unaudited) run cancellation anywhere under engine turned main red (2026-10-20).
  'engine/closed-pr-ci.test.mjs',
  'engine/jq-arg-safety.test.sh',
  'engine/notify.test.sh',
  'engine/queue-order.test.sh',
].map(packPath));

function gitText(args, cwd) {
  try {
    return execFileSync('git', args, {
      cwd,
      encoding: 'utf8',
      maxBuffer: 8 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch (error) {
    if ((args[0] === 'grep' && error.status === 1) || (args[0] === 'show' && error.status === 128)) {
      return '';
    }
    throw error;
  }
}

function hereDocAt(line, index) {
  if (line.startsWith('<<<', index)) return undefined;
  let cursor = index + 2;
  const stripTabs = line[cursor] === '-';
  if (stripTabs) cursor += 1;
  while (/\s/.test(line[cursor] ?? '')) cursor += 1;

  const quote = line[cursor] === "'" || line[cursor] === '"' ? line[cursor++] : '';
  let delimiter = '';
  while (cursor < line.length) {
    const char = line[cursor];
    if (quote ? char === quote : /[\s;&|()<>]/.test(char)) break;
    if (char === '\\' && cursor + 1 < line.length) cursor += 1;
    delimiter += line[cursor++];
  }
  return delimiter ? { delimiter, stripTabs, end: cursor + (quote && line[cursor] === quote ? 1 : 0) } : null;
}

function shellFunctionRanges(source) {
  try {
    execFileSync('bash', ['-n'], { input: source, stdio: ['pipe', 'ignore', 'ignore'] });
  } catch {
    return null;
  }

  const ranges = [];
  const pendingHereDocs = [];
  let quote = '';
  let depth = 0;
  let currentFunction = null;

  for (const [index, rawLine] of source.split('\n').entries()) {
    const line = rawLine.replace(/\r$/, '');
    if (pendingHereDocs.length > 0) {
      const { delimiter, stripTabs } = pendingHereDocs[0];
      const content = stripTabs ? line.replace(/^\t+/, '') : line;
      if (content === delimiter) pendingHereDocs.shift();
      continue;
    }

    const declaration = depth === 0 && !quote
      ? /^\s*(?:function\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*\(\s*\))?|([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\))\s*\{/.exec(line)
      : null;
    const functionLike = depth === 0 && !quote
      && /^\s*function\s+[A-Za-z_][A-Za-z0-9_]*(?:\s*\(\s*\))?\b/.test(line);
    if (functionLike && !declaration) return null;
    if (declaration) currentFunction = { name: declaration[1] ?? declaration[2], start: index + 1 };

    let lineDelta = 0;
    for (let cursor = 0; cursor < line.length; cursor += 1) {
      const char = line[cursor];
      if (quote === "'") {
        if (char === "'") quote = '';
        continue;
      }
      if (quote === '"' || quote === '`') {
        if (char === '\\') cursor += 1;
        else if (char === quote) quote = '';
        continue;
      }
      if (char === '\\') {
        cursor += 1;
        continue;
      }
      if (char === "'" || char === '"' || char === '`') {
        quote = char;
        continue;
      }
      if (char === '#' && (cursor === 0 || /\s|[;&|()]/.test(line[cursor - 1]))) break;
      if (char === '<' && line[cursor + 1] === '<') {
        if (line.startsWith('<<<', cursor)) {
          cursor += 2;
          continue;
        }
        const arithmeticOpen = line.lastIndexOf('((', cursor);
        const arithmeticClose = line.lastIndexOf('))', cursor);
        if (arithmeticOpen > arithmeticClose) {
          cursor += 1;
          continue;
        }
        const hereDoc = hereDocAt(line, cursor);
        if (hereDoc === null) return null;
        if (hereDoc) {
          pendingHereDocs.push(hereDoc);
          cursor = hereDoc.end - 1;
          continue;
        }
      }
      if (char === '{') lineDelta += 1;
      if (char === '}') lineDelta -= 1;
    }

    depth += lineDelta;
    if (depth < 0) return null;
    if (currentFunction && depth === 0) {
      ranges.push({ ...currentFunction, end: index + 1 });
      currentFunction = null;
    }
  }

  if (quote || depth !== 0 || currentFunction || pendingHereDocs.length > 0) return null;
  return ranges;
}

function functionForRange(ranges, start, count) {
  let name;
  for (let line = start; line < start + count; line += 1) {
    const range = ranges.find((candidate) => candidate.start <= line && line <= candidate.end);
    if (!range || (name && name !== range.name)) return null;
    name = range.name;
  }
  return name ?? null;
}

function changedFunctions(diff, before, after) {
  const oldFunctions = shellFunctionRanges(before);
  const newFunctions = shellFunctionRanges(after);
  if (!oldFunctions || !newFunctions) return null;

  const names = new Set();
  let changedLineCount = 0;
  for (const match of diff.matchAll(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/gm)) {
    const oldStart = Number(match[1]);
    const oldCount = Number(match[2] ?? 1);
    const newStart = Number(match[3]);
    const newCount = Number(match[4] ?? 1);
    if (oldCount > 0) {
      const name = functionForRange(oldFunctions, oldStart, oldCount);
      if (!name) return null;
      names.add(name);
      changedLineCount += oldCount;
    }
    if (newCount > 0) {
      const name = functionForRange(newFunctions, newStart, newCount);
      if (!name) return null;
      names.add(name);
      changedLineCount += newCount;
    }
  }
  return changedLineCount > 0 && names.size > 0 ? [...names] : null;
}

function hasFunctionCall(source, name) {
  const call = new RegExp(`(^|[^A-Za-z0-9_])${name}(?=$|[\\s;&|()])`);
  const declaration = new RegExp(`^\\s*(?:function\\s+)?${name}\\s*\\(\\s*\\)\\s*\\{`);
  return source.split('\n').some((line) => {
    const code = line.replace(/(^|\s)#.*$/, '$1');
    return code.trim() && !declaration.test(code) && call.test(code);
  });
}

function shellFunctionCallers(source, functions) {
  const ranges = shellFunctionRanges(source);
  if (!ranges) return null;

  const lines = source.split('\n');
  const callersByFunction = new Map(functions.map((name) => [name, new Set([name])]));
  let changed = true;
  while (changed) {
    changed = false;
    for (const range of ranges) {
      const body = lines.slice(range.start - 1, range.end).join('\n');
      for (const callers of callersByFunction.values()) {
        if (![...callers].some((name) => hasFunctionCall(body, name)) || callers.has(range.name)) continue;
        callers.add(range.name);
        changed = true;
      }
    }
  }
  return callersByFunction;
}

function sourcesHelper(source, helperPath) {
  const basename = helperPath.split('/').at(-1).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const sourceLine = new RegExp(`^\\s*(?:source|\\.)\\s+.*\\b${basename}\\b`);
  return source.split('\n').some((line) => sourceLine.test(line.replace(/(^|\s)#.*$/, '$1')));
}

const REFERENCE_SOURCE_PATTERN = /\.(?:sh|[cm]?js|ts|py|json|ya?ml)$/;

function isSelectableTestPath(path) {
  return !path.startsWith('packages/') && !path.startsWith('apps/')
    && (/\.test\.(?:sh|mjs)$/.test(path) || /(^|\/)test-[^/]+\.sh$/.test(path));
}

// A script that pins another file carries its own same-named suite into the
// selection when the pinned file changes (#4599: lesson-lints.mjs anchors
// lib.sh and supervisor-holds.sh, so lesson-lints.test.mjs must run too).
function sameNameOwnerTests(scriptPath, tracked) {
  const stem = scriptPath.replace(/\.[^/]+$/, '');
  return ['.test.sh', '.test.mjs']
    .map((suffix) => `${stem}${suffix}`)
    .filter((candidate) => tracked.has(candidate));
}

function readTracked(path, cwd) {
  try {
    return readFileSync(join(cwd, path), 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return undefined;
    throw error;
  }
}

function referencingPaths(filename, tracked, { suiteRef, cwd }) {
  if (suiteRef) {
    return gitText(['grep', '-l', '-I', '-F', filename, suiteRef, '--'], cwd)
      .split('\n')
      .filter(Boolean)
      .map((path) => path.startsWith(`${suiteRef}:`) ? path.slice(suiteRef.length + 1) : path);
  }
  // Without refs, select against the working tree (staged files count) by
  // reading the tracked tests and the tracked scripts that own one.
  return [...tracked].filter((path) => (
    (isSelectableTestPath(path) || sameNameOwnerTests(path, tracked).length > 0)
    && (readTracked(path, cwd) ?? '').includes(filename)
  ));
}

function filenameReferencedTests(changedPaths, tracked, { headRef, mappingRef, cwd }) {
  const suiteRef = mappingRef ?? headRef;
  const testsByScript = new Map();

  for (const changedPath of changedPaths) {
    if (
      !REFERENCE_SOURCE_PATTERN.test(changedPath)
      || isSelectableTestPath(changedPath)
    ) continue;

    const filename = changedPath.split('/').at(-1);
    const references = referencingPaths(filename, tracked, { suiteRef, cwd });
    const tests = new Set(references.filter(isSelectableTestPath));
    for (const reference of references) {
      if (isSelectableTestPath(reference)) continue;
      for (const owner of sameNameOwnerTests(reference, tracked)) tests.add(owner);
    }

    testsByScript.set(changedPath, [...tests].filter((path) => tracked.has(path)));
  }

  return testsByScript;
}

// ponytail: dynamic shell dispatch has no static caller edge; it falls back to filename selection.
function helperCallerTests(changedPaths, tracked, { baseRef, headRef, mappingRef, cwd }) {
  const tests = new Set();
  const mappedPaths = new Set();
  if (!baseRef || !headRef) return { tests, mappedPaths };
  const suiteRef = mappingRef ?? headRef;

  for (const helperPath of changedPaths) {
    if (!helperPath.startsWith(PACK_PREFIX) || !helperPath.endsWith('.sh') || helperPath.endsWith('.test.sh')) {
      continue;
    }
    const diff = gitText(['diff', '--unified=0', `${baseRef}..${headRef}`, '--', helperPath], cwd);
    const before = gitText(['show', `${baseRef}:${helperPath}`], cwd);
    const after = gitText(['show', `${headRef}:${helperPath}`], cwd);
    const functions = changedFunctions(diff, before, after);
    if (!functions) continue;

    const callersByChangedFunction = shellFunctionCallers(after, functions);
    if (!callersByChangedFunction) continue;
    const searchableFunctions = [...new Set([...callersByChangedFunction.values()].flatMap((names) => [...names]))];
    const pattern = `(^|[^[:alnum:]_])(${searchableFunctions.join('|')})([^[:alnum:]_]|$)`;
    const candidates = gitText(['grep', '-l', '-I', '-E', pattern, suiteRef, '--', PACK_REL], cwd)
      .split('\n')
      .filter(Boolean)
      .map((path) => path.startsWith(`${suiteRef}:`) ? path.slice(suiteRef.length + 1) : path);
    const coveredFunctions = new Set();
    for (const ownerPath of candidates) {
      if (ownerPath === helperPath || !tracked.has(ownerPath)) continue;
      const isTest = /\.test\.(?:sh|mjs)$/.test(ownerPath);
      if (!isTest && (!ownerPath.endsWith('.sh') || ownerPath.endsWith('.test.sh'))) continue;
      const source = gitText(['show', `${suiteRef}:${ownerPath}`], cwd);
      if (!sourcesHelper(source, helperPath)) continue;

      for (const name of functions) {
        if (![...callersByChangedFunction.get(name)].some((caller) => hasFunctionCall(source, caller))) continue;
        if (isTest) {
          tests.add(ownerPath);
          coveredFunctions.add(name);
          continue;
        }

        const candidatesForOwner = RELATED_TESTS.get(ownerPath)
          ?? [ownerPath.replace(/\.sh$/, '.test.sh')];
        const matched = candidatesForOwner.filter((candidate) => tracked.has(candidate));
        if (matched.length === 0) throw new Error(`No focused test exists for changed helper caller ${ownerPath}.`);
        for (const candidate of matched) tests.add(candidate);
        coveredFunctions.add(name);
      }
    }

    if (functions.every((name) => coveredFunctions.has(name))) mappedPaths.add(helperPath);
  }
  return { tests, mappedPaths };
}

// node --test cannot run vitest files; their package's own gate (Touched packages PR gate) runs them.
function isPackageVitestFile(path, cwd) {
  if (!path.startsWith('packages/')) return false;
  try {
    return /from ['"]vitest['"]/.test(readFileSync(join(cwd, path), 'utf8'));
  } catch {
    return false;
  }
}

export function focusedTestPaths(changedPaths, trackedPaths, refs = {}) {
  const tracked = trackedPaths instanceof Set ? trackedPaths : new Set(trackedPaths);
  const tests = new Set();
  const helperTests = helperCallerTests(changedPaths, tracked, {
    cwd: process.cwd(),
    ...refs,
  });
  const filenameTests = filenameReferencedTests(
    changedPaths,
    tracked,
    { cwd: process.cwd(), ...refs },
  );

  // A pipeline script the change deletes has nothing left to cover.
  let deletedPaths = new Set();
  try {
    const range = refs.baseRef && refs.headRef ? `${refs.baseRef}..${refs.headRef}` : refs.baseRef ?? 'HEAD';
    deletedPaths = new Set(gitText(['diff', '--name-only', '--diff-filter=D', '--no-renames', range], refs.cwd ?? process.cwd())
      .split(/\r?\n/).filter(Boolean));
  } catch {
    // Unresolvable refs: nothing is known to be deleted, so every changed script still needs coverage.
  }

  for (const path of changedPaths) {
    if (path.startsWith(PACK_PREFIX) && /\.(?:sh|[cm]?js|ts|py)$/.test(path)) {
      for (const candidate of CROSS_SCRIPT_TESTS) {
        if (tracked.has(candidate)) tests.add(candidate);
      }
    }

    if (/\.test\.(?:sh|mjs)$/.test(path)) {
      if (tracked.has(path) && !isPackageVitestFile(path, refs.cwd ?? process.cwd())) tests.add(path);
      for (const candidate of RELATED_TESTS.get(path) ?? []) {
        if (tracked.has(candidate)) tests.add(candidate);
      }
      continue;
    }

    // Release fixtures load mail indirectly, beyond the shell function caller scan.
    const functionMapped = helperTests.mappedPaths.has(path)
      && !['engine/night/founder-health-mail.sh', 'engine/notify.sh'].map(packPath).includes(path);
    let candidates = functionMapped ? undefined : RELATED_TESTS.get(path);
    if (!candidates && path.startsWith('lessons/')) {
      candidates = [packPath('engine/land-direct-main.test.sh')];
    }
    if (!candidates && path.startsWith(PACK_PREFIX) && /\.(?:sh|[cm]?js|ts|py)$/.test(path)) {
      candidates = [path.replace(/\.(?:sh|[cm]?js|ts|py)$/, path.endsWith('.sh') || path.endsWith('.py') ? '.test.sh' : '.test.mjs')];
    } else if (!candidates && path.startsWith(`${PACK_PREFIX}prompts/`)) {
      const prompt = path.slice(`${PACK_PREFIX}prompts/`.length);
      const promptOwner = new Map([
        ['triage.md', 'run-triage'],
        ['advisor.md', 'run-advisor'],
        ['advisor-batch.md', 'run-advisor-batch'],
        ['advisor.schema.json', ['run-advisor', 'run-advisor-batch']],
        ['recut.md', 'run-recut'],
        ['recut.schema.json', 'run-recut'],
      ]).get(prompt);
      if (promptOwner) {
        candidates = (Array.isArray(promptOwner) ? promptOwner : [promptOwner])
          .map((owner) => `${PACK_PREFIX}${owner}.test.sh`);
      }
    }
    if (!candidates && path === 'scripts/code-intelligence-preflight.mjs') {
      candidates = ['scripts/code-intelligence-preflight.test.mjs'];
    }

    if (!candidates) continue;
    const matched = candidates.filter((candidate) => tracked.has(candidate));
    if (
      path.startsWith(PACK_PREFIX)
      && /\.(?:sh|[cm]?js|ts|py)$/.test(path)
      && !deletedPaths.has(path)
      && matched.length === 0
      && (filenameTests.get(path)?.length ?? 0) === 0
      && !helperTests.mappedPaths.has(path)
      && !RELATED_TESTS.get(path)?.some((candidate) => tracked.has(candidate))
    ) {
      throw new Error(`No focused test exists for changed pipeline script ${path}.`);
    }
    for (const candidate of matched) tests.add(candidate);
  }

  for (const testPath of helperTests.tests) tests.add(testPath);

  for (const [sourcePath, scriptTests] of filenameTests) {
    for (const testPath of scriptTests) {
      // Shell caller coverage cannot see Node harnesses dynamically loading the helper.
      if (!helperTests.mappedPaths.has(sourcePath) || testPath.endsWith('.test.mjs')) tests.add(testPath);
    }
  }

  if (tracked.has(packPath('engine/ci-infrastructure-focused.test.sh')) && changedPaths.some((path) => (
    path.startsWith('.dagger/')
    || path.startsWith('scripts/ci/')
    || path.startsWith('.github/workflows/')
    || path === 'scripts/check-production-image-contract.mjs'
    || path === 'scripts/production-image-contract.json'
  ))) {
    tests.add(packPath('engine/ci-infrastructure-focused.test.sh'));
  }

  return [...tests].sort();
}

// A suite that failed last time runs first; then fastest first. Unknown suites take the median slot.
export function orderFocusedTestPaths(testPaths, records = {}) {
  const durationOf = (path) => {
    const value = records[path]?.duration_ms;
    return Number.isFinite(value) ? value : undefined;
  };
  const known = testPaths.map(durationOf).filter((value) => value !== undefined).sort((a, b) => a - b);
  const middle = Math.floor(known.length / 2);
  const median = known.length === 0 ? 0 : known.length % 2 ? known[middle] : (known[middle - 1] + known[middle]) / 2;
  const key = (path) => [['fail', 'timeout'].includes(records[path]?.status) ? 0 : 1, durationOf(path) ?? median];
  return [...testPaths].sort((a, b) => {
    const [failedA, durationA] = key(a);
    const [failedB, durationB] = key(b);
    return failedA - failedB || durationA - durationB || (a < b ? -1 : a > b ? 1 : 0);
  });
}

export function intersectingFocusedTestPaths(branchChangedPaths, mainChangedPaths, trackedPaths, refs = {}) {
  const branchTests = new Set(focusedTestPaths(branchChangedPaths, trackedPaths, refs.branch));
  return focusedTestPaths(mainChangedPaths, trackedPaths, refs.main)
    .filter((testPath) => branchTests.has(testPath))
    .sort();
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [mode, oldBase, newMain] = process.argv.slice(2);
  if (!['--intersection', '--range'].includes(mode) || !oldBase || !newMain || process.argv.length !== 5) {
    console.error(`Usage: node ${process.argv[1]} --intersection OLD_MAIN NEW_MAIN | --range FROM TO`);
    process.exit(2);
  }

  const changedPaths = (range) => execFileSync('git', ['diff', '--name-only', '--no-renames', range], {
    encoding: 'utf8',
  }).trim().split('\n').filter(Boolean);
  if (mode === '--range') {
    // Apply today's suite map and tracked tests to historical ranges.
    const mappingRef = 'HEAD';
    const tracked = new Set(execFileSync('git', ['ls-tree', '-r', '--name-only', mappingRef], { encoding: 'utf8' })
      .trim().split('\n').filter(Boolean));
    const selected = focusedTestPaths(changedPaths(`${oldBase}..${newMain}`), tracked, {
      baseRef: oldBase, headRef: newMain, mappingRef, cwd: process.cwd(),
    });
    // Wait for the write: process.exit() drops a piped stdout past 64 KiB (10-29 census incident).
    if (selected.length > 0) await new Promise((resolve) => process.stdout.write(`${selected.join('\n')}\n`, resolve));
    process.exit(0);
  }
  const trackedPaths = new Set([
    ...execFileSync('git', ['ls-files'], { encoding: 'utf8' }).trim().split('\n').filter(Boolean),
    ...execFileSync('git', ['ls-tree', '-r', '--name-only', oldBase], { encoding: 'utf8' }).trim().split('\n').filter(Boolean),
  ]);
  const selected = intersectingFocusedTestPaths(
    changedPaths(`${newMain}..HEAD`),
    changedPaths(`${oldBase}..${newMain}`),
    trackedPaths,
    {
      branch: { baseRef: newMain, headRef: 'HEAD', cwd: process.cwd() },
      main: { baseRef: oldBase, headRef: newMain, cwd: process.cwd() },
    },
  );
  if (selected.length > 0) process.stdout.write(`${selected.join('\n')}\n`);
}
