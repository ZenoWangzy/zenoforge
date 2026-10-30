#!/usr/bin/env node

import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { createHash } from 'node:crypto';
import { execFile, spawnSync } from 'node:child_process';
import path from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const LIB_PATH = path.resolve(SCRIPT_DIR, '../lib.sh');
const DAY_MS = 24 * 60 * 60 * 1000;
const HOUR_MS = 60 * 60 * 1000;
const GH_API_CALL_TIMEOUT_MS = 30_000;
const SAMPLE_FINALIZE_RESERVE_MS = 10_000;
const DEFAULT_SAMPLE_TIMEOUT_MS = 150_000;
const BASELINE_WINDOW_MS = 7 * DAY_MS;
const CI_RUN_PAGE_SIZE = 100;
const CI_RUN_SAMPLE_METHOD = 'bounded-stratified-bottom-k-run-id-v1';
const MIN_HISTORY_HOURS = 24;
const MIN_STAGE_ALERT_SAMPLES = 20;
const ALARM_INTERVAL_MS = 6 * HOUR_MS;
const TERMINAL_STAGES = new Set(['closed', 'released', 'concluded', 'duplicate', 'wontfix', 'tracker']);
const BASELINE_20261010 = Object.freeze({
  // Measured from 10/10 ticket transitions and the 10/10 CI ROI snapshot.
  closed_issues: 7,
  ci_waste_share: 0.657,
  main_green_share: 0.53,
});
const METRIC_KEYS = [
  'calls',
  'tokens',
  'released_issues',
  'merged_prs',
  'tokens_per_released_issue',
  'queue_to_implement_seconds',
  'implement_to_merge_seconds',
  'merge_to_release_seconds',
  'repeat_dispatches',
  'ci_queue_seconds',
  'ci_run_seconds',
  'closed_issues',
  'limiter_ticket_hours',
  'ci_waste_share',
  'main_green_share',
];
const STAGE_KEYS = [
  'queue_to_implement_seconds',
  'implement_to_merge_seconds',
  'merge_to_release_seconds',
];
const stageLabel = {
  queue_to_implement_seconds: '排队到实现',
  implement_to_merge_seconds: '实现到合并',
  merge_to_release_seconds: '合并到上线',
};
const DAILY_LABELS = {
  'needs-triage': '待分诊',
  'ready-for-agent': '待开发',
  'needs-advisor': '顾问评估',
  'needs-info': '等补充',
  'needs-recut': '待拆分',
  'needs-owner': '待负责人',
  'checks-blocked': '检查受阻',
  'awaiting-release': '等待发布',
  'awaiting-pipeline-sync': '等待同步',
  'on-hold': '暂停处理',
  unrouted: '未路由',
  released: '已发布',
  concluded: '已完成',
  'finish-first': '等前置事项',
  duplicate: '重复事项',
  wontfix: '不再处理',
  tracker: '需求跟踪',
  closed: '已关闭',
  'Touched packages PR gate': '改动范围检查',
  'Enforce branch delivery policy': '变更合规检查',
  'Pipeline suites': '自动化测试',
  'Pipeline suites focused': '自动化测试重点项',
  'Pipeline suites shard 0': '自动化测试第一组',
  'Pipeline suites shard 1': '自动化测试第二组',
  'Pipeline suites shard 2': '自动化测试第三组',
  'Pipeline suites shard 3': '自动化测试第四组',
  'Pipeline suites shard 4': '自动化测试第五组',
  'Select pipeline-suite scope': '自动化测试范围筛选',
  'Example pack PR gate': '示例包检查',
  'Repo-path regression PR gate': '仓库回归检查',
  'Migration SQL parse gate': '数据库变更检查',
  'NUL bytes & lone negative assertions': '文件完整性检查',
  'Postsubmit validate': '合并后验证',
  'Dagger postsubmit canary': '合并后抽查',
  'Pinned production image gates': '生产镜像检查',
  contract: '功能约定检查',
  'commit-preflight': '提交预检',
  'check-rulings': '规则检查',
  'landing-queue': '主线落地排队',
  review: '代码复核',
};

function parseTime(value) {
  const time = Date.parse(value || '');
  return Number.isFinite(time) ? time : null;
}

function median(values) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  // Match throughput-metrics.mjs p50: nearest-rank, lower middle for even sets.
  return sorted.length ? sorted[Math.ceil(sorted.length / 2) - 1] : null;
}

function readJsonlRecords(file) {
  if (!existsSync(file)) return [];
  return readFileSync(file, 'utf8').split(/\r?\n/).flatMap((line) => {
    if (!line.trim()) return [];
    try {
      return [JSON.parse(line)];
    } catch {
      return [];
    }
  });
}

function readHistory(file) {
  return readJsonlRecords(file).filter((row) => parseTime(row.sampled_at) !== null);
}

export function readMetricRows(home) {
  const metricsDir = path.join(home, 'metrics');
  let files = [];
  try {
    files = readdirSync(metricsDir)
      .filter((name) => /^efficiency-[0-9]{4}-[0-9]{2}\.jsonl$/.test(name))
      .sort()
      .map((name) => path.join(metricsDir, name));
  } catch {
    return [];
  }
  const seen = new Set();
  return files.flatMap((file) => readJsonlRecords(file)).filter((row) => {
    const key = row.event_id || row.sampled_at;
    if (!key) return true;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function appendMetricRecords(home, records) {
  const byMonth = new Map();
  for (const record of records) {
    const parsed = parseTime(record?.ts || record?.sampled_at);
    if (parsed === null) throw new TypeError('metric record needs an ISO timestamp');
    const month = new Date(parsed).toISOString().slice(0, 7);
    const rows = byMonth.get(month) || [];
    rows.push({ schema_version: 1, ...record });
    byMonth.set(month, rows);
  }
  const metricsDir = path.join(home, 'metrics');
  mkdirSync(metricsDir, { recursive: true, mode: 0o700 });
  chmodSync(metricsDir, 0o700);
  for (const [month, monthRows] of byMonth) {
    const file = path.join(metricsDir, `efficiency-${month}.jsonl`);
    const existingKeys = new Set(readJsonlRecords(file).map((row) => row.event_id || row.sampled_at).filter(Boolean));
    const fresh = monthRows.filter((row) => {
      const key = row.event_id || row.sampled_at;
      if (!key || existingKeys.has(key)) return false;
      existingKeys.add(key);
      return true;
    });
    if (!fresh.length) continue;
    const result = spawnSync('flock', ['-x', `${file}.lock`, 'tee', '-a', file], {
      input: fresh.map((row) => JSON.stringify(row)).join('\n') + '\n',
      encoding: 'utf8',
      timeout: 10_000,
      stdio: ['pipe', 'ignore', 'pipe'],
    });
    if (result.error || result.status !== 0) throw new Error('could not append efficiency metric row');
    chmodSync(file, 0o600);
  }
}

export function appendMetricRecord(home, record) {
  appendMetricRecords(home, [record]);
  const parsed = parseTime(record?.ts || record?.sampled_at);
  return path.join(home, 'metrics', `efficiency-${new Date(parsed).toISOString().slice(0, 7)}.jsonl`);
}

function migrateLegacyHistory(home) {
  const legacy = path.join(home, 'state', 'efficiency-hourly.jsonl');
  if (!existsSync(legacy)) return;
  const rows = readHistory(legacy);
  appendMetricRecords(home, rows.map((row) => ({ record_type: 'hourly', ...row })));
  const archived = `${legacy}.migrated`;
  if (existsSync(archived)) throw new Error('legacy efficiency history migration marker already exists');
  renameSync(legacy, archived);
}

function readHourlyHistory(home) {
  return readMetricRows(home).filter((row) => row.record_type === 'hourly' || row.sampled_at);
}

function transitionMetricRows(transition) {
  const id = String(transition.event_id || `${transition.issue}|${transition.ts}|${transition.from_stage}|${transition.to_stage}`);
  const common = {
    record_type: 'event',
    ts: transition.ts,
    issue: transition.issue,
    writer: transition.writer,
    kind: transition.kind,
    source_event_id: id,
  };
  const rows = [];
  if (transition.from_stage && transition.from_stage !== 'untracked') {
    rows.push({ ...common, event_type: 'stage-exited', stage: transition.from_stage, event_id: `${id}:exit` });
  } else if (transition.from_stage === 'untracked') {
    rows.push({ ...common, event_type: 'ticket-created', stage: transition.to_stage, event_id: `${id}:created` });
  }
  if (transition.to_stage && transition.to_stage !== 'untracked') {
    rows.push({ ...common, event_type: 'stage-entered', stage: transition.to_stage, event_id: `${id}:enter` });
  }
  if (transition.to_stage === 'closed') {
    rows.push({ ...common, event_type: 'ticket-closed', stage: transition.to_stage, event_id: `${id}:closed` });
  }
  if (transition.to_stage === 'released') {
    rows.push({ ...common, event_type: 'ticket-released', stage: transition.to_stage, event_id: `${id}:released` });
  }
  if (TERMINAL_STAGES.has(transition.from_stage) && transition.to_stage && !TERMINAL_STAGES.has(transition.to_stage)) {
    rows.push({ ...common, event_type: 'ticket-reopened', stage: transition.to_stage, event_id: `${id}:reopened` });
  }
  return rows;
}

function syncTicketTransitionEvents(home) {
  const transitionFile = path.join(home, 'state', 'ticket-transitions.jsonl');
  if (!existsSync(transitionFile)) return;
  const seen = new Set(readMetricRows(home).map((row) => row.source_event_id).filter(Boolean));
  const missing = readJsonlRecords(transitionFile)
    .filter((row) => parseTime(row.ts) !== null && !seen.has(String(row.event_id)))
    .flatMap(transitionMetricRows);
  if (missing.length) appendMetricRecords(home, missing);
}

function hourlyRows(rows, before, after = before - BASELINE_WINDOW_MS) {
  const byHour = new Map();
  for (const row of rows) {
    const sampled = parseTime(row.sampled_at);
    if (sampled === null || sampled >= before || sampled < after) continue;
    const hour = Math.floor(sampled / HOUR_MS);
    const previous = byHour.get(hour);
    if (!previous || sampled > parseTime(previous.sampled_at)) byHour.set(hour, row);
  }
  return [...byHour.values()].sort((a, b) => parseTime(a.sampled_at) - parseTime(b.sampled_at));
}

export function rollingBaseline(rows, before) {
  const beforeMs = typeof before === 'number' ? before : parseTime(before);
  const history = beforeMs === null ? [] : hourlyRows(rows, beforeMs);
  const ready = history.length >= MIN_HISTORY_HOURS;
  return {
    history_hours: history.length,
    baseline_ready: ready,
    ...Object.fromEntries(METRIC_KEYS.map((key) => [
      key,
      ready && (key !== 'repeat_dispatches' || history.filter((row) => row.repeat_dispatch_metric_version === 2).length >= MIN_HISTORY_HOURS)
        ? median(history.filter((row) => key !== 'repeat_dispatches' || row.repeat_dispatch_metric_version === 2)
        .map((row) => row.metrics?.[key]).filter(Number.isFinite)) : null,
    ])),
  };
}

function readJson(file, fallback) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJsonAtomic(file, value) {
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, file);
}

function insideWindow(value, since, until) {
  const parsed = parseTime(value);
  return parsed !== null && parsed >= since && parsed <= until;
}

function secondsBetween(start, end) {
  const a = parseTime(start);
  const b = parseTime(end);
  return a !== null && b !== null && b >= a ? (b - a) / 1000 : null;
}

function listStateFiles(stateDir, errors) {
  let names;
  try {
    names = readdirSync(stateDir).filter((name) => /^[1-9][0-9]*\.json$/.test(name));
  } catch {
    return [];
  }
  const states = [];
  for (const name of names) {
    try {
      states.push({ issue: name.slice(0, -5), state: JSON.parse(readFileSync(path.join(stateDir, name), 'utf8')) });
    } catch {
      errors.push(`state:${name}:invalid`);
    }
  }
  return states;
}

function readSpend(home, since, nowMs, errors) {
  const spendDir = path.join(home, 'spend');
  const days = new Set([
    new Date(since).toISOString().slice(0, 10),
    new Date(nowMs).toISOString().slice(0, 10),
  ]);
  let calls = 0;
  let tokens = 0;
  try {
    for (const day of days) {
      const file = path.join(spendDir, `${day}.log`);
      if (!existsSync(file)) continue;
      const lines = readFileSync(file, 'utf8').split(/\r?\n/);
      for (const line of lines) {
        const fields = line.split('\t');
        const at = Number(fields[0]);
        if (!Number.isFinite(at) || at < since / 1000 || at > nowMs / 1000) continue;
        calls += 1;
        if (/^[0-9]+$/.test(fields[5] || '')) tokens += Number(fields[5]);
      }
    }
  } catch {
    errors.push('spend:unreadable');
  }
  return { calls, tokens };
}

function readRepeatDispatches(home, since, nowMs, errors, events) {
  const logDir = path.join(home, 'logs');

  try {
    const dispatches = new Map();
    for (const name of existsSync(logDir) ? readdirSync(logDir) : []) {
      const match = name.match(/^(implement|repair)-([1-9][0-9]*)-([0-9]{8}T[0-9]{6}Z)\.log$/);
      if (!match) continue;
      const step = match[1];
      const issue = match[2];
      const stamp = match[3];
      const at = parseTime(`${stamp.slice(0, 4)}-${stamp.slice(4, 6)}-${stamp.slice(6, 8)}T${stamp.slice(9, 11)}:${stamp.slice(11, 13)}:${stamp.slice(13, 15)}Z`);
      if (at === null || at > nowMs) continue;
      const key = `${issue}:${step}`;
      const times = dispatches.get(key) || [];
      times.push(at);
      dispatches.set(key, times);
    }
    let repeats = 0;
    for (const key of dispatches.keys()) {
      const times = dispatches.get(key).sort((a, b) => a - b);
      const prior = times.some((at) => at < since);
      const count = times.filter((at) => at >= since && at <= nowMs).length;
      const repeatCount = Math.max(0, count - (prior ? 0 : 1));
      repeats += repeatCount;
    }
    // Model-call files include in-attempt repair and independent PR resume calls.
    // They remain diagnostics; only scheduler dispatch events count as dispatches.
    const decisions = events.filter((event) => ['dispatch', 'limiter'].includes(event.event_type));
    const covered = decisions.length > 0 && parseTime(decisions[0].ts) <= since;
    const prior = new Map();
    const causes = {};
    const byIssue = {};
    let count = 0;
    let excluded = 0;
    for (const event of events) {
      if (parseTime(event.ts) > nowMs) break;
      const issue = String(event.issue);
      if (event.event_type === 'attempt-resumed') {
        const previous = prior.get(issue);
        if (previous) previous.retry_reason = event.retry_reason;
      } else if (event.event_type === 'attempt-terminal') {
        const previous = prior.get(issue);
        if (previous && (!event.started_at || parseTime(event.started_at) >= previous.at - 5000)) previous.terminal = event;
      } else if (event.event_type === 'dispatch') {
        const previous = prior.get(issue);
        if (previous && insideWindow(event.ts, since, nowMs)) {
          const cause = previous.terminal?.terminal_cause || 'unknown';
          if (['supervisor-resume', 'host-restart', 'egress-hold-release'].includes(event.retry_reason || previous.retry_reason)
            || cause === 'launch-budget-refused'
            || (cause === 'interrupted' && (previous.terminal?.attempt_refunded === true || Number(previous.terminal?.exit_status) === 143))
            || (cause === 'network-egress' && previous.terminal?.attempt_refunded === true)
            || (previous.boot_id && event.boot_id && previous.boot_id !== event.boot_id
              && (!previous.terminal || cause === 'interrupted'))) {
            excluded += 1;
          } else {
            count += 1;
            causes[cause] = (causes[cause] || 0) + 1;
            byIssue[issue] = (byIssue[issue] || 0) + 1;
          }
        }
        prior.set(issue, { terminal: null, boot_id: event.boot_id, at: parseTime(event.ts) });
      }
    }
    return { count, causes, by_issue: byIssue, covered, excluded, model_calls: repeats };

  } catch {
    errors.push('repeat-dispatch:unreadable');
    return { count: 0, causes: {}, by_issue: {} };
  }
}

function readRunningImplementIssues(errors) {
  const result = spawnSync('systemctl', [
    '--user', 'list-units', '--no-legend', '--plain', 'zf-implement-*',
  ], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] });
  if (result.error || result.status !== 0) {
    errors.push('implement-units:unavailable');
    return null;
  }
  return [...result.stdout.matchAll(/^zf-implement-([1-9][0-9]*)\.service\s+/gm)]
    .map((match) => match[1]);
}

function limiterCategory(decision) {
  const gate = decision.gate || '';
  if (gate === 'capacity') return 'agent_cap';
  if (gate === 'budget-exhausted') return 'scan_budget';
  if (gate === 'dispatch-resources') return 'memory';
  if (gate === 'quarantine') return 'quarantine';
  if (gate.startsWith('roadmap-')) return 'roadmap_admission';
  if (/hand/.test(gate)) return 'hand_owned';
  if (/collision|scope-cap/.test(gate)) return 'scope_collision';
  if (/budget|spend|quota|repeat-cap|attempt-cap/.test(gate)) return 'budget';
  if (/block|parent/.test(gate)) return 'blocked_by';
  return decision.category || gate || 'other';
}

async function readOpenIssues(home, repo, nowMs) {
  const snapshot = readJson(path.join(home, 'night', 'open-snapshots-last-result.json'), null);
  const age = nowMs - parseTime(snapshot?.sampled_at);
  if (Array.isArray(snapshot?.open_issues) && age >= 0 && age <= 15 * 60_000) return snapshot.open_issues;
  const pages = await ghPages(`repos/${repo}/issues?state=open&per_page=100`, null);
  return pages.filter((issue) => !issue.pull_request);
}

async function readClosedIssues(home, repo, nowMs) {
  const previous = readMetricRows(home).filter((row) => row.record_type === 'closed-census'
    && parseTime(row.ts) !== null && parseTime(row.ts) <= nowMs)
    .map((row) => parseTime(row.ts)).sort((a, b) => a - b).at(-1);
  // Replay the last hour for search-index lag; canonical closure IDs deduplicate it.
  const since = new Date(Math.max(nowMs - 2 * BASELINE_WINDOW_MS, (previous ?? 0) - HOUR_MS)).toISOString();
  const issues = await ghPages(`search/issues?q=repo:${repo}+is:issue+is:closed+closed:>=${since}&per_page=100`, 'items');
  if (issues.length >= 1000) throw new Error('closed issue census reached GitHub search cap');
  return issues.filter((issue) => !issue.pull_request && issue.state === 'closed'
    && insideWindow(issue.closed_at, nowMs - 2 * BASELINE_WINDOW_MS, nowMs));
}

export function closedIssueMetricRows(issues) {
  return issues.filter((issue) => issue.state === 'closed' && !issue.pull_request)
    .flatMap((issue) => [
      ...(parseTime(issue.created_at) === null ? [] : [{ record_type: 'event', event_type: 'github-opened', issue: issue.number,
        ts: issue.created_at, writer: 'github-issue-census', event_id: `github-opened:${issue.number}:${issue.created_at}` }]),
      ...(parseTime(issue.closed_at) === null ? [] : [{ record_type: 'event', event_type: 'github-closed', issue: issue.number,
        ts: issue.closed_at, writer: 'github-closed-census', event_id: `github-closed:${issue.number}:${issue.closed_at}` }]),
    ]);
}

export function openIssueMetricRows(issues) {
  return issues.filter((issue) => issue.state === 'open' && !issue.pull_request && parseTime(issue.created_at) !== null)
    .map((issue) => ({ record_type: 'event', event_type: 'github-opened', issue: issue.number,
      ts: issue.created_at, writer: 'github-issue-census', event_id: `github-opened:${issue.number}:${issue.created_at}` }));
}

export function runLifecycleMetricRows(issue, state) {
  const run = state.run || {};
  const evidence = run.evidence || {};
  const pr = evidence.pr_number ? String(evidence.pr_number) : null;
  const directMain = state.pipeline_system?.enabled === true || run.outcome === 'pipeline-system';
  const deliveryPath = directMain ? 'pipeline-system-direct-main' : 'product-release';
  const currentAttempt = Number(state.attempts) || 0;
  const rows = [];
  const add = (eventType, ts, sha = null, extra = {}) => {
    if (parseTime(ts) === null) return;
    const attempt = Object.hasOwn(extra, 'attempt') ? extra.attempt : currentAttempt;
    if (attempt !== null && Number(attempt) !== currentAttempt) return;
    const identity = [sha, extra.run_id, extra.run_attempt, extra.job_id, extra.build_run_id, extra.roll_id]
      .filter((value) => value !== null && value !== undefined && value !== '').join(':');
    rows.push({ record_type: 'event', event_type: eventType, issue: Number(issue), pr_number: pr,
      sha: sha || null, attempt: attempt ?? null, delivery_path: deliveryPath, ts, writer: 'run-lifecycle-state',
      event_id: `delivery:${deliveryPath}:${issue}:${pr || 'none'}:${eventType}:${attempt ?? 'unknown'}:${ts}${identity ? `:${identity}` : ''}`, ...extra });
  };
  add('implementation-started', run.implement_started_at, run.implement_started_sha,
    { attempt: run.implement_started_attempt ?? null });
  add('implementation-ended', evidence.implementation_ended_at, evidence.implementation_head_sha,
    { attempt: evidence.implementation_attempt ?? null });
  add('review-ready', evidence.review_ready_at, evidence.reviewed_head_sha,
    { attempt: evidence.review_attempt ?? null });
  for (const job of evidence.ci_jobs || []) {
    const sha = job.head_sha || evidence.ci_head_sha || null;
    const context = { attempt: evidence.ci_attempt ?? null, run_id: job.run_id || null, run_attempt: job.run_attempt || null,
      job_id: job.job_id || null, job_name: job.name || null, testcontainers_job: job.testcontainers_job === true };
    add('ci-job-started', job.started_at, sha, context);
    if (parseTime(job.completed_at) !== null) add('ci-job-completed', job.completed_at, sha,
      { ...context, runner_seconds: Number.isFinite(job.runner_seconds) ? job.runner_seconds : null });
  }
  add('ci-started', evidence.ci_started_at, evidence.ci_head_sha, { attempt: evidence.ci_attempt ?? null });
  add('ci-completed', evidence.ci_completed_at, evidence.ci_head_sha, { attempt: evidence.ci_attempt ?? null });
  const mergedPr = evidence.merged_pr;
  if (mergedPr && String(mergedPr.number) === pr && parseTime(mergedPr.merged_at) !== null) {
    add('merged', mergedPr.merged_at, mergedPr.merge_sha || null);
  }
  const build = evidence.production_build || {};
  add('production-build-started', build.started_at, build.sha || null,
    { attempt: build.attempt ?? null, build_run_id: build.run_id || null, outcome: build.outcome || null });
  add('production-build-completed', build.completed_at, build.sha || null,
    { attempt: build.attempt ?? null, build_run_id: build.run_id || null, outcome: build.outcome || null });
  const roll = evidence.production_roll || {};
  add('production-roll-started', roll.started_at, roll.deployed_sha || null,
    { attempt: roll.attempt ?? null, roll_id: roll.roll_id || null });
  add('production-roll-completed', roll.completed_at, roll.deployed_sha || null,
    { attempt: roll.attempt ?? null, roll_id: roll.roll_id || null });
  if (directMain) {
    add('pipeline-system-landed', state.pipeline_system?.landed_at, state.pipeline_system?.commit_sha || null,
      { attempt: state.pipeline_system?.landed_attempt ?? null });
  } else if (state.deploy_state === 'deployed' && /^[0-9a-f]{40,64}$/i.test(state.deployed_sha || '')
    && parseTime(evidence.production_evidence_at) !== null
    && ['URL:', 'Visible DOM:', 'Same-run network:'].every((marker) => (evidence.real_user_path || '').includes(marker))) {
    add('production-proof', evidence.production_evidence_at, state.deployed_sha,
      { attempt: evidence.production_evidence_attempt ?? null });
  }
  return rows;
}

function syncRunLifecycleEvents(home, now = new Date()) {
  const errors = [];
  const events = listStateFiles(path.join(home, 'state'), errors)
    .flatMap(({ issue, state }) => runLifecycleMetricRows(issue, state));
  const hour = Math.floor(now.getTime() / HOUR_MS);
  appendMetricRecords(home, [...events, { record_type: 'event', event_type: 'lifecycle-census',
    ts: now.toISOString(), writer: 'run-lifecycle-state', event_id: `lifecycle-census:${hour}` }]);
}

export function syncIssueLifecycleEvents(home, issue) {
  const state = readJson(path.join(home, 'state', `${issue}.json`), null);
  if (!state || typeof state !== 'object' || Array.isArray(state)) return 0;
  const events = runLifecycleMetricRows(issue, state);
  appendMetricRecords(home, events);
  return events.length;
}

function semanticMetricStage(state, stage, enteredAt) {
  if (stage !== 'unrouted') return stage;
  if (state?.tracker_parent === true || state?.state === 'tracker' || state?.recut_children?.length > 0) return 'tracker';
  // shortcut: match existing label-stripping transitions within 60s; emit semantic stages at source if they take longer.
  return ['closed', 'released', 'concluded', 'awaiting-release'].includes(state?.state)
    && Math.abs(parseTime(state.state_changed_at) - enteredAt) <= 60_000 ? state.state : stage;
}

function collectTicketTracking(home, states, since, nowMs, errors, runningIssues, openIssues) {
  const records = readMetricRows(home);
  const events = records.filter((row) => row.record_type === 'event' && parseTime(row.ts) !== null)
    .sort((a, b) => parseTime(a.ts) - parseTime(b.ts));
  const stageCounts = {};
  const stageSeconds = {};
  const issueEvents = new Map();
  const stateByIssue = new Map(states.map((entry) => [entry.issue, entry.state]));
  const openIssueIds = new Set((openIssues || []).map((issue) => String(issue.number)));
  const isTracker = (issue) => {
    const state = stateByIssue.get(String(issue));
    return state?.tracker_parent === true || state?.state === 'tracker' || state?.recut_children?.length > 0;
  };
  const liveStates = openIssues?.map((issue) => {
    const labels = (issue.labels || []).map((label) => typeof label === 'string' ? label : label.name);
    const stage = labels.includes('on-hold') ? 'on-hold'
      : isTracker(issue.number) || labels.some((label) => ['roadmap', 'roadmap-theme', 'roadmap-epic'].includes(label)) ? 'tracker'
        : labels.find((label) => ['needs-triage', 'needs-info', 'ready-for-agent', 'ready-for-human', 'needs-owner',
          'checks-blocked', 'duplicate', 'finish-first', 'wontfix', 'needs-advisor', 'needs-recut',
          'awaiting-release', 'awaiting-pipeline-sync', 'awaiting-pipeline-health', 'released', 'concluded'].includes(label)) || 'unrouted';
    return { issue: String(issue.number), state: { ...stateByIssue.get(String(issue.number)), state: stage } };
  });
  for (const { state } of liveStates || []) {
    const stage = state.state;
    stageCounts[stage] = (stageCounts[stage] || 0) + 1;
  }
  for (const event of events) {
    if (!event.issue) continue;
    const items = issueEvents.get(String(event.issue)) || [];
    items.push(event);
    issueEvents.set(String(event.issue), items);
  }
  const addStageTime = (stage, start, end) => {
    const from = Math.max(start, since);
    const to = Math.min(end, nowMs);
    if (to <= from) return;
    stageSeconds[stage] = (stageSeconds[stage] || 0) + (to - from) / 1000;
  };
  for (const [issue, history] of issueEvents) {
    const semanticStage = (stage, enteredAt) => semanticMetricStage(stateByIssue.get(issue), stage, enteredAt);
    let active = null;
    for (const event of history) {
      const at = parseTime(event.ts);
      if (event.event_type === 'stage-entered') {
        if (active) addStageTime(semanticStage(active.stage, active.at), active.at, at);
        active = { stage: event.stage || 'unknown', at };
      } else if (event.event_type === 'stage-exited' && active?.stage === event.stage) {
        addStageTime(semanticStage(active.stage, active.at), active.at, at);
        active = null;
      }
    }
    if (active && !['closed', 'released', 'concluded'].includes(semanticStage(active.stage, active.at))) {
      if (openIssueIds.has(issue)) addStageTime(semanticStage(active.stage, active.at), active.at, nowMs);
    } else if (!history.some((event) => event.event_type === 'stage-entered')) {
      const current = stateByIssue.get(issue);
      const entered = parseTime(current?.state_changed_at);
      if (current && entered !== null && openIssueIds.has(issue)) {
        addStageTime(String(current.state || 'unknown'), entered, nowMs);
      }
    }
  }

  const ready = (liveStates || []).filter(({ state }) => state.state === 'ready-for-agent');
  const running = runningIssues === null ? null : new Set(runningIssues);
  const readyNotRunning = running === null ? [] : ready.filter(({ issue }) => !running.has(issue));
  const lastDecision = new Map();
  const lastStageEntered = new Map();
  for (const event of events) {
    if (event.event_type === 'stage-entered') lastStageEntered.set(String(event.issue), event);
    if (event.event_type === 'limiter' || event.event_type === 'dispatch') {
      lastDecision.set(String(event.issue), event);
    }
  }
  const limiterCounts = {};
  const limiterTicketHours = {};
  const limiterDecisions = {};
  for (const { issue, state } of readyNotRunning) {
    let decision = lastDecision.get(issue);
    const persisted = state.implement_tick_decision;
    if (parseTime(persisted?.recorded_at) !== null && (!decision || parseTime(persisted.recorded_at) > parseTime(decision.ts))) {
      decision = { ...persisted, ts: persisted.recorded_at, event_type: persisted.outcome === 'dispatched' ? 'dispatch' : 'limiter' };
    }
    const entered = lastStageEntered.get(issue);
    const enteredAt = Math.max(parseTime(entered?.ts) || 0, parseTime(state.state_changed_at) || 0);
    const decisionIsCurrent = decision && parseTime(decision.ts) <= nowMs && parseTime(decision.ts) >= enteredAt;
    const category = decisionIsCurrent ? decision.event_type === 'limiter' ? limiterCategory(decision) : 'dispatch_finished' : 'unknown';
    limiterDecisions[issue] = { category, gate: decisionIsCurrent ? decision.gate : null,
      recorded_at: decisionIsCurrent ? decision.ts : null, reason: decisionIsCurrent ? decision.reason : null,
      object: decisionIsCurrent ? decision.object : null };
    limiterCounts[category] = (limiterCounts[category] || 0) + 1;
    const lastAt = decisionIsCurrent ? parseTime(decision.ts) : null;
    const start = Math.max(since, lastAt === null ? since : lastAt);
    limiterTicketHours[category] = (limiterTicketHours[category] || 0) + Math.max(0, nowMs - start) / HOUR_MS;
  }
  const eventCount = (type) => events.filter((event) => event.event_type === type && insideWindow(event.ts, since, nowMs)).length;
  const repeats = readRepeatDispatches(home, since, nowMs, errors, events);
  const waitingTicketHours = Object.values(stageSeconds).reduce((sum, value) => sum + value, 0) / 3600
    - (['in-progress', 'implementing'].reduce((sum, stage) => sum + (stageSeconds[stage] || 0), 0) / 3600);
  const workingTicketHours = ['in-progress', 'implementing']
    .reduce((sum, stage) => sum + (stageSeconds[stage] || 0), 0) / 3600;
  return {
    stage_counts: stageCounts,
    stage_ticket_hours: Object.fromEntries(Object.entries(stageSeconds).map(([stage, seconds]) => [stage, seconds / 3600])),
    waiting_ticket_hours: waitingTicketHours,
    working_ticket_hours: workingTicketHours,
    running_implement_count: runningIssues === null ? null : new Set(runningIssues).size,
    ready_ticket_count: liveStates === undefined ? null : ready.length,
    ready_not_running_count: runningIssues === null || liveStates === undefined ? null : readyNotRunning.length,
    limiter_counts: limiterCounts,
    limiter_decisions: limiterDecisions,
    ticket_tracking_metric_version: 2,
    limiter_ticket_hours_by_reason: limiterTicketHours,
    limiter_ticket_hours: Object.values(limiterTicketHours).reduce((sum, value) => sum + value, 0),
    creations: eventCount('ticket-created'),
    closures: eventCount('ticket-closed'),
    releases: eventCount('ticket-released'),
    repeat_runs: repeats.count,
    repeat_dispatch_metric_version: 2,
    repeat_dispatches_covered: repeats.covered,
    repeat_dispatches_excluded: repeats.excluded,
    repeat_model_calls: repeats.model_calls,
    repeat_run_causes: repeats.causes,
    repeat_runs_by_issue: repeats.by_issue,
  };
}

function stageStart(state, stage) {
  const run = state.run || {};
  if (stage === 'queue_to_implement_seconds') return run.entered_at || state.state_changed_at;
  if (stage === 'implement_to_merge_seconds') return run.implement_started_at;
  return mergedAt(run);
}

function mergedAt(run) {
  const proof = run.evidence?.merged_pr;
  return proof && String(proof.number) === String(run.evidence.pr_number) && parseTime(proof.merged_at) !== null
    ? proof.merged_at : null;
}

function collectStateMetrics(home, nowMs, runningIssues, openIssues) {
  const since = nowMs - DAY_MS;
  const errors = [];
  const states = listStateFiles(path.join(home, 'state'), errors);
  const openIssueIds = new Set((openIssues || []).map((issue) => String(issue.number)));
  const spend = readSpend(home, since, nowMs, errors);
  const stageValues = Object.fromEntries(STAGE_KEYS.map((key) => [key, []]));
  const stageTickets = Object.fromEntries(STAGE_KEYS.map((key) => [key, []]));
  const stuckTickets = Object.fromEntries(STAGE_KEYS.map((key) => [key, []]));
  const mergedPrs = new Set();
  let releasedIssues = 0;

  for (const { issue, state } of states) {
    const run = state.run || {};
    const evidence = run.evidence || {};
    const hasProductionProof = state.deploy_state === 'deployed'
      && /^[0-9a-f]{40,64}$/i.test(state.deployed_sha || '')
      && ['URL:', 'Visible DOM:', 'Same-run network:'].every((marker) => (evidence.real_user_path || '').includes(marker));
    const releasedAt = hasProductionProof ? evidence.production_evidence_at || null : null;
    const isReleased = state.released === true && state.closed_by_pipeline === true && Boolean(releasedAt);
    if (isReleased && insideWindow(releasedAt, since, nowMs)) releasedIssues += 1;

    const pr = String(evidence.pr_number || '');
    if (run.outcome === 'merged' && /^[1-9][0-9]*$/.test(pr)
      && insideWindow(mergedAt(run), since, nowMs)) mergedPrs.add(pr);

    const stageEnds = {
      queue_to_implement_seconds: run.implement_started_at,
      implement_to_merge_seconds: mergedAt(run),
      merge_to_release_seconds: isReleased ? releasedAt : null,
    };
    for (const stage of STAGE_KEYS) {
      const end = stageEnds[stage];
      if (insideWindow(end, since, nowMs)) {
        const duration = secondsBetween(stageStart(state, stage), end);
        if (duration !== null) {
          stageValues[stage].push(duration);
          stageTickets[stage].push({ issue, seconds: duration });
        }
      }
    }

    if (!isReleased && openIssueIds.has(String(issue))) {
      const stage = run.outcome === 'merged' || state.state === 'awaiting-release'
        ? 'merge_to_release_seconds'
        : run.implement_started_at || state.state === 'in-progress'
          ? 'implement_to_merge_seconds'
          : state.state === 'queued' || state.state === 'ready-for-agent'
            ? 'queue_to_implement_seconds'
            : null;
      const started = stage && stageStart(state, stage);
      const age = started ? secondsBetween(started, new Date(nowMs).toISOString()) : null;
      // A ticket is stuck after a full day without leaving its current stage.
      if (stage && age !== null && age >= DAY_MS / 1000) stuckTickets[stage].push({ issue, seconds: age });
    }
  }

  const stages = Object.fromEntries(STAGE_KEYS.map((key) => [key, median(stageValues[key])]));
  const tracking = collectTicketTracking(home, states, since, nowMs, errors, runningIssues, openIssues);
  const topIssues = (items) => items.sort((a, b) => b.seconds - a.seconds || Number(a.issue) - Number(b.issue))
    .slice(0, 5).map((item) => item.issue);
  return {
    metrics: {
      calls: spend.calls,
      tokens: spend.tokens,
      released_issues: releasedIssues,
      merged_prs: mergedPrs.size,
      tokens_per_released_issue: releasedIssues ? spend.tokens / releasedIssues : null,
      ...stages,
      repeat_dispatches: tracking.repeat_dispatches_covered ? tracking.repeat_runs : null,
      closed_issues: tracking.closures,
      limiter_ticket_hours: tracking.limiter_ticket_hours,
      ci_queue_seconds: null,
      ci_run_seconds: null,
      ci_waste_share: null,
      main_green_share: null,
    },
    ...tracking,
    stage_samples: Object.fromEntries(STAGE_KEYS.map((key) => [key, stageValues[key].length])),
    stage_tickets: Object.fromEntries(STAGE_KEYS.map((key) => [key, topIssues(stageTickets[key])])),
    stuck_by_stage: Object.fromEntries(STAGE_KEYS.map((key) => [key, {
      count: stuckTickets[key].length,
      tickets: topIssues(stuckTickets[key]),
    }])),
    source_errors: errors,
  };
}

export async function ghPages(endpoint, collection, timeoutMs = GH_API_CALL_TIMEOUT_MS, { paginate = true, includeTotalCount = false } = {}) {
  // Project before buffering: 848 full workflow runs already occupied 10.5 MB.
  const fields = collection === 'workflow_runs' ? 'id,run_attempt,created_at,conclusion,event'
    : collection === 'jobs' ? 'name,status,conclusion,runner_id,steps_count:(.steps|length),created_at,started_at,completed_at'
      : 'number,labels,pull_request,state,created_at,closed_at';
  const projection = includeTotalCount
    ? `{total_count, ${collection}: [.${collection}[] | {${fields}}]} | @json`
    : collection ? `${collection === 'items' ? 'if .incomplete_results then error("incomplete issue census") else . end | ' : ''}[.${collection}[] | {${fields}}] | @json` : `map({${fields}}) | @json`;
  const args = ['api', endpoint];
  if (paginate) args.push('--paginate');
  args.push('--jq', projection);
  const { stdout } = await execFileAsync('gh', args, {
    encoding: 'utf8', timeout: Math.max(1, Math.floor(Math.min(GH_API_CALL_TIMEOUT_MS, timeoutMs))), maxBuffer: 12 * 1024 * 1024,
    windowsHide: true,
  });
  const pages = stdout.trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
  if (includeTotalCount) {
    if (pages.length !== 1 || !pages[0] || typeof pages[0] !== 'object' || Array.isArray(pages[0])) {
      throw new TypeError('invalid GitHub workflow-runs count page');
    }
    return pages[0];
  }
  if (pages.some((page) => !Array.isArray(page))) {
    throw new TypeError('invalid GitHub API page shape');
  }
  return pages.flat();
}

function validCiCacheEntry(entry, since, until) {
  const created = parseTime(entry?.created_at);
  const timingsValid = (values) => Array.isArray(values) && values.every((value) => Number.isFinite(value) && value >= 0);
  return created !== null && created >= since && created <= until
    && timingsValid(entry.queue_seconds) && timingsValid(entry.run_seconds)
    && typeof entry.conclusion === 'string'
    && (entry.jobs === undefined || Array.isArray(entry.jobs));
}

function readCiJobCache(file, since, until) {
  const value = readJson(file, null);
  if (![2, 3].includes(value?.version) || !value.runs || typeof value.runs !== 'object' || Array.isArray(value.runs)) return new Map();
  return new Map(Object.entries(value.runs).filter(([, entry]) => validCiCacheEntry(entry, since, until)));
}

function readCiWorkflowRunCache(file, since, until) {
  const value = readJson(file, null);
  if (![2, 3].includes(value?.version) || !value.workflow_runs
    || typeof value.workflow_runs !== 'object' || Array.isArray(value.workflow_runs)) return new Map();
  return new Map(Object.entries(value.workflow_runs).filter(([, run]) => {
    const id = Number(run?.id);
    const attempt = Number(run?.run_attempt);
    return Number.isSafeInteger(id) && id > 0 && Number.isSafeInteger(attempt) && attempt > 0
      && ['pr', 'main'].includes(run.cohort) && insideWindow(run.created_at, since, until);
  }));
}

function ciJobTimings(run, jobs) {
  const queueSeconds = [];
  const runSeconds = [];
  const details = [];
  for (const job of jobs) {
    const createdAt = job.created_at || run.created_at;
    const runnerId = job.runner_id === null || job.runner_id === undefined || job.runner_id === ''
      ? null : Number(job.runner_id);
    const stepsCount = Number.isFinite(job.steps_count) ? job.steps_count
      : Array.isArray(job.steps) ? job.steps.length : null;
    const neverStarted = runnerId === 0 && stepsCount === 0;
    const queued = neverStarted
      ? secondsBetween(createdAt, job.completed_at) ?? secondsBetween(createdAt, job.started_at)
      : secondsBetween(createdAt, job.started_at);
    const duration = neverStarted ? null : secondsBetween(job.started_at, job.completed_at);
    if (queued !== null) queueSeconds.push(queued);
    if (duration !== null) runSeconds.push(duration);
    details.push({
      name: job.name || '',
      status: job.status || '',
      conclusion: job.conclusion || '',
      runner_id: Number.isSafeInteger(runnerId) ? runnerId : null,
      steps_count: stepsCount,
      never_started: neverStarted,
      queue_seconds: queued,
      run_seconds: duration,
    });
  }
  return {
    created_at: run.created_at,
    conclusion: run.conclusion || 'unknown',
    event: run.event || '',
    head_branch: run.head_branch || '',
    queue_seconds: queueSeconds,
    run_seconds: runSeconds,
    jobs: details,
  };
}

function sampledRuns(runs, sinceMs, untilMs, limit = 20) {
  const inWindow = runs.filter((run) => {
    const created = parseTime(run.created_at);
    return created !== null && created >= sinceMs && created <= untilMs;
  });
  const selected = inWindow.length <= limit ? inWindow : inWindow
    .map((run) => ({ run, rank: createHash('sha256').update(String(run.id)).digest('hex') }))
    .sort((a, b) => a.rank.localeCompare(b.rank) || String(a.run.id).localeCompare(String(b.run.id)))
    .slice(0, limit)
    .map(({ run }) => run);
  return selected.sort((a, b) => parseTime(a.created_at) - parseTime(b.created_at));
}

async function sampledWorkflowRuns(endpoint, fetchPage, deadlineMs, sinceMs, untilMs, cachedRuns = [], limit = 20) {
  const pageUrl = (page) => `${endpoint}&per_page=${CI_RUN_PAGE_SIZE}&page=${page}`;
  const firstTimeout = Math.min(GH_API_CALL_TIMEOUT_MS, deadlineMs - Date.now());
  if (firstTimeout <= 0) throw Object.assign(new Error('CI run sample deadline exceeded'), { code: 'ETIMEDOUT' });
  const first = await fetchPage(pageUrl(1), 'workflow_runs', firstTimeout, { paginate: false, includeTotalCount: true });
  const firstRuns = Array.isArray(first) ? first : first?.workflow_runs;
  if (!Array.isArray(firstRuns)) throw new TypeError('invalid GitHub workflow-runs page');
  const total = Array.isArray(first) ? first.length : Number(first.total_count);
  const population = Number.isSafeInteger(total) && total >= 0 ? total : firstRuns.length;
  const count = Math.min(limit, population);
  if (!count) return { runs: [], population };
  const positions = count === 1 ? [0]
    : Array.from({ length: count }, (_, index) => Math.round(index * (population - 1) / (count - 1)));
  const neededPages = [...new Set(positions.map((position) => Math.floor(position / CI_RUN_PAGE_SIZE) + 1))];
  const pages = new Map([[1, firstRuns]]);
  await Promise.all(neededPages.filter((page) => page !== 1).map(async (page) => {
    const timeoutMs = Math.min(GH_API_CALL_TIMEOUT_MS, deadlineMs - Date.now());
    if (timeoutMs <= 0) throw Object.assign(new Error('CI run sample deadline exceeded'), { code: 'ETIMEDOUT' });
    const result = await fetchPage(pageUrl(page), 'workflow_runs', timeoutMs, { paginate: false });
    const runs = Array.isArray(result) ? result : result?.workflow_runs;
    if (!Array.isArray(runs)) throw new TypeError('invalid GitHub workflow-runs page');
    pages.set(page, runs);
  }));
  // Keep the existing bounded page set, then rank every run on those pages by stable identity.
  const candidates = [...pages.entries()].sort(([a], [b]) => a - b).flatMap(([, runs]) => runs);
  const byId = new Map(cachedRuns.map((run) => [String(run.id), run]));
  for (const run of candidates) byId.set(String(run.id), run);
  return {
    runs: sampledRuns([...byId.values()], sinceMs, untilMs, limit),
    population,
  };
}

export async function collectGitHubCiSamples(repo, since, {
  cacheFile,
  deadlineMs = Date.now() + 140_000,
  nowMs,
  fetchPages = ghPages,
} = {}) {
  const errors = [];
  const errorReasons = {};
  const unreadable = (source, error) => {
    errors.push(`${source}:unreadable`);
    errorReasons[source] = error.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER' ? 'child-buffer-limit'
      : error.killed || error.code === 'ETIMEDOUT' ? 'timeout'
        : /Bad Gateway/.test(error.stderr || '') ? 'bad-gateway'
          : error instanceof TypeError || error instanceof SyntaxError ? 'invalid-response' : 'api-error';
  };
  const sinceMs = typeof since === 'number' ? since : parseTime(since);
  if (!Number.isFinite(sinceMs)) return { queue_seconds: [], run_seconds: [], errors: ['ci-runs:invalid-window'] };
  const sampleNowMs = Number.isFinite(nowMs) ? nowMs : Date.now();
  let cacheWritable = Boolean(cacheFile);
  if (cacheWritable) {
    try {
      mkdirSync(path.dirname(cacheFile), { recursive: true, mode: 0o700 });
    } catch {
      cacheWritable = false;
      errors.push('ci-cache:unwritable');
    }
  }
  const cache = cacheFile ? readCiJobCache(cacheFile, sinceMs, sampleNowMs) : new Map();
  const workflowRunCache = cacheFile ? readCiWorkflowRunCache(cacheFile, sinceMs, sampleNowMs) : new Map();
  const sinceIso = new Date(sinceMs).toISOString();
  const cohorts = [];
  let workflowRunPageRequests = 0;
  let jobRequests = 0;
  for (const [name, query] of [
    ['pr', `event=pull_request&status=completed&created=>=${sinceIso}`],
    ['main', `event=push&branch=main&status=completed&created=>=${sinceIso}`],
  ]) {
    try {
      const timeoutMs = Math.min(GH_API_CALL_TIMEOUT_MS, deadlineMs - Date.now());
      if (timeoutMs <= 0) {
        errors.push(`ci-${name}-runs:deferred`);
        cohorts.push({ name, runs: [], population: null });
        continue;
      }
      const endpoint = `repos/${repo}/actions/runs?${query}`;
      const fullUtcDay = sinceMs % DAY_MS === 0 && sampleNowMs === sinceMs + DAY_MS - 1;
      const boundedEndpoint = fullUtcDay
        ? endpoint.replace(`created=>=${sinceIso}`, `created=${sinceIso.slice(0, 10)}..${sinceIso.slice(0, 10)}`)
        : endpoint;
      const cachedRuns = [...workflowRunCache.values()].filter((run) => run.cohort === name);
      const fetchRunPage = (...args) => {
        workflowRunPageRequests += 1;
        return fetchPages(...args);
      };
      const sampled = await sampledWorkflowRuns(
        boundedEndpoint, fetchRunPage, deadlineMs, sinceMs, sampleNowMs, cachedRuns,
      );
      for (const [key, run] of workflowRunCache) {
        if (run.cohort === name) workflowRunCache.delete(key);
      }
      for (const run of sampled.runs) {
        const id = Number(run.id);
        const attempt = Number(run.run_attempt);
        if (Number.isSafeInteger(id) && id > 0 && Number.isSafeInteger(attempt) && attempt > 0
          && insideWindow(run.created_at, sinceMs, sampleNowMs)) {
          workflowRunCache.set(`${name}:${id}`, { ...run, cohort: name });
        }
      }
      cohorts.push({ name, ...sampled });
    } catch (error) {
      unreadable(`ci-${name}-runs`, error);
      cohorts.push({ name, runs: [], population: null });
    }
  }
  const validRuns = [];
  const missing = [];
  const missingKeys = new Set();
  const validKeys = new Set();
  const cohortCounts = { pr: { success: 0, total: 0 }, main: { success: 0, total: 0 } };
  for (const cohort of cohorts) for (const run of cohort.runs) {
    const id = Number(run.id);
    if (!Number.isSafeInteger(id) || id <= 0) {
      errors.push('ci-run:invalid-id');
      continue;
    }
    const attempt = Number(run.run_attempt);
    if (!Number.isSafeInteger(attempt) || attempt <= 0) {
      errors.push(`ci-run:${id}:invalid-attempt`);
      continue;
    }
    const counts = cohortCounts[cohort.name];
    // A cancelled main run has no green/red verdict; its runner time still counts as CI waste below.
    if (!(cohort.name === 'main' && run.conclusion === 'cancelled')) {
      counts.total += 1;
      if (run.conclusion === 'success') counts.success += 1;
    }
    const key = `${id}:${attempt}`;
    if (!validKeys.has(key)) validRuns.push({ run, key, cohort: cohort.name });
    validKeys.add(key);
    if ((!cache.has(key) || !Array.isArray(cache.get(key).jobs)) && !missingKeys.has(key)) {
      missingKeys.add(key);
      missing.push({ run, id, key });
    }
  }

  let deferred = 0;
  for (let index = 0; index < missing.length;) {
    if (Date.now() >= deadlineMs) {
      deferred += missing.length - index;
      break;
    }
    const batchRuns = missing.slice(index, index + 8);
    const batch = await Promise.all(batchRuns.map(async (item) => {
      try {
        const timeoutMs = Math.min(GH_API_CALL_TIMEOUT_MS, deadlineMs - Date.now());
        if (timeoutMs <= 0) return { deferred: true };
        jobRequests += 1;
        const jobs = await fetchPages(`repos/${repo}/actions/runs/${item.id}/jobs?per_page=100`, 'jobs', timeoutMs);
        return { item, entry: ciJobTimings(item.run, jobs) };
      } catch (error) {
        return { error, source: `ci-jobs:${item.id}` };
      }
    }));
    for (const result of batch) {
      if (result.deferred) {
        deferred += 1;
        continue;
      }
      if (result.error) {
        unreadable(result.source, result.error);
        continue;
      }
      cache.set(result.item.key, result.entry);
    }
    index += batchRuns.length;
    if (Date.now() >= deadlineMs) {
      deferred += missing.length - index;
      break;
    }
  }
  if (deferred) errors.push(`ci-jobs:deferred:${deferred}`);

  const queueSeconds = [];
  const runSeconds = [];
  const wastedRunSeconds = [];
  const jobSamples = [];
  for (const { key, cohort } of validRuns) {
    const entry = cache.get(key);
    if (!entry) continue;
    queueSeconds.push(...entry.queue_seconds);
    runSeconds.push(...entry.run_seconds);
    const runId = Number(key.split(':')[0]);
    jobSamples.push(...(entry.jobs || []).map((job) => ({
      ...job, cohort, workflow_run_id: runId, workflow_conclusion: entry.conclusion,
    })));
    if (entry.conclusion === 'failure' || entry.conclusion === 'cancelled') {
      wastedRunSeconds.push(...entry.run_seconds);
    }
  }
  if (cacheWritable) {
    try {
      writeJsonAtomic(cacheFile, {
        version: 3,
        runs: Object.fromEntries(cache),
        workflow_runs: Object.fromEntries(workflowRunCache),
      });
    } catch {
      errors.push('ci-cache:unwritable');
    }
  }
  const ratios = ciRatios(runSeconds, wastedRunSeconds, cohortCounts.main.total, cohortCounts.main.success);
  return {
    queue_seconds: queueSeconds,
    run_seconds: runSeconds,
    ci_waste_share: ratios.ci_waste_share,
    main_green_share: ratios.main_green_share,
    sampled_runs: Object.fromEntries(Object.entries(cohortCounts).map(([key, value]) => [key, value.total])),
    sampled_workflow_runs: Object.fromEntries(cohorts.map(({ name, runs }) => [name, runs.length])),
    workflow_population: Object.fromEntries(cohorts.map(({ name, population }) => [name, population])),
    sample_method: CI_RUN_SAMPLE_METHOD,
    workflow_run_page_requests: workflowRunPageRequests,
    jobs_requests: jobRequests,
    job_samples: jobSamples,
    errors,
    error_reasons: errorReasons,
  };
}

function metricRules() {
  return [
    { key: 'released_issues', direction: 'low', threshold: 0.70, broken: 0.50 },
    { key: 'closed_issues', direction: 'low', threshold: 0.70, broken: 0.50 },
    { key: 'merged_prs', direction: 'low', threshold: 0.70, broken: 0.50 },
    { key: 'tokens_per_released_issue', direction: 'high', threshold: 1.40, broken: 2.00 },
    ...STAGE_KEYS.map((key) => ({ key, direction: 'high', threshold: 1.50, broken: 3.00 })),
    { key: 'repeat_dispatches', direction: 'high', threshold: 1.50, broken: 3.00 },
    { key: 'limiter_ticket_hours', direction: 'high', threshold: 1.50, broken: 3.00, floor: 4, broken_floor: 8 },
    { key: 'ci_waste_share', direction: 'high', delta: 0.10, broken_delta: 0.20 },
    { key: 'main_green_share', direction: 'low', threshold: 0.75, broken: 0.50 },
  ];
}

function violates(rule, current, baseline) {
  if (typeof current !== 'number' || Number.isNaN(current)) return false;
  if (rule.floor !== undefined) return current > Math.max(rule.floor, Number.isFinite(baseline) ? baseline * rule.threshold : 0);
  if (rule.delta !== undefined) return Number.isFinite(baseline) && current > baseline + rule.delta;
  if (!Number.isFinite(baseline)) return false;
  return rule.direction === 'low'
    ? current < baseline * rule.threshold
    : current > baseline * rule.threshold;
}

function isSevere(rule, current, baseline) {
  if (rule.broken_floor !== undefined) return current > Math.max(rule.broken_floor, Number.isFinite(baseline) ? baseline * rule.broken : 0);
  if (rule.broken_delta !== undefined) return Number.isFinite(baseline) && current > baseline + rule.broken_delta;
  return rule.direction === 'low'
    ? current < baseline * rule.broken
    : current > baseline * rule.broken;
}

function chooseStage(row, baseline) {
  const current = row.metrics || {};
  const stageSamples = STAGE_KEYS.map((key) => ({
    key,
    increase: Number.isFinite(current[key]) && Number.isFinite(baseline[key]) ? current[key] - baseline[key] : null,
    baseline: baseline[key],
    seconds: current[key],
    stuck: row.stuck_by_stage?.[key]?.count || 0,
    samples: row.stage_samples?.[key] || 0,
  }));
  const reliable = stageSamples.filter((item) => item.samples >= MIN_STAGE_ALERT_SAMPLES);
  const increased = reliable.filter((item) => item.increase > 0).sort((a, b) => b.increase - a.increase);
  const stuck = reliable.filter((item) => item.stuck > 0).sort((a, b) => b.stuck - a.stuck);
  const slowest = reliable.filter((item) => Number.isFinite(item.seconds)).sort((a, b) => b.seconds - a.seconds);
  const selected = increased[0] || stuck[0] || slowest[0] || {
    key: 'unknown', increase: null, baseline: null, seconds: null, stuck: 0, samples: 0,
  };
  const reason = increased[0] ? 'largest-latency-increase'
    : stuck[0] ? 'most-stuck-tickets'
      : slowest[0] ? 'slowest-stage' : 'insufficient-stage-samples';
  const tickets = reason === 'most-stuck-tickets'
    ? row.stuck_by_stage?.[selected.key]?.tickets || []
    : row.stage_tickets?.[selected.key]?.length
      ? row.stage_tickets[selected.key]
      : row.stuck_by_stage?.[selected.key]?.tickets || [];
  return { ...selected, label: stageLabel[selected.key] || '样本不足', reason, tickets: tickets.slice(0, 5) };
}

function formatMetric(value) {
  if (value === 'infinite') return 'infinite';
  if (!Number.isFinite(value)) return 'unknown';
  return Number.isInteger(value) ? String(value) : String(Number(value.toFixed(1)));
}

export function assessEfficiency(rows) {
  const sorted = [...rows].sort((a, b) => parseTime(a.sampled_at) - parseTime(b.sampled_at));
  const currentRow = sorted.at(-1);
  if (!currentRow) {
    return { status: 'UNKNOWN', detail: 'reason=no-hourly-history', current: null, baseline: null, violations: [] };
  }
  const baseline = rollingBaseline(sorted, currentRow.sampled_at);
  const current = currentRow.metrics || {};
  if (!baseline.baseline_ready) {
    return {
      status: 'UNKNOWN', detail: `reason=insufficient-history hours=${baseline.history_hours}/24`,
      current, baseline, violations: [],
    };
  }
  const targetPrevious = parseTime(currentRow.sampled_at) - DAY_MS;
  const previousRow = sorted.filter((row) => {
    const at = parseTime(row.sampled_at);
    return at !== null && at <= targetPrevious && at >= targetPrevious - 6 * HOUR_MS;
  }).at(-1);
  const violationsByMetric = new Map();
  const addComparison = (rule, baselineValue, comparison) => {
    const rawCurrent = rule.key === 'tokens_per_released_issue' && current.released_issues === 0 && current.tokens > 0
      ? Infinity : current[rule.key];
    if (!violates(rule, rawCurrent, baselineValue)) return;
    const violation = {
      metric: rule.key,
      current: rawCurrent === Infinity ? 'infinite' : rawCurrent,
      baseline: baselineValue,
      comparison,
      severe: isSevere(rule, rawCurrent, baselineValue),
    };
    const previous = violationsByMetric.get(rule.key);
    if (!previous || (!previous.severe && violation.severe)) violationsByMetric.set(rule.key, violation);
  };
  // 24-hour medians from fewer than 20 merged issues can be dominated by a few long-lived tickets.
  // Daily node rollups still cover lower-volume stage changes with paired event samples.
  const stageCohortIsLargeEnough = (rule) => !STAGE_KEYS.includes(rule.key)
    || (currentRow.stage_samples?.[rule.key] || 0) >= MIN_STAGE_ALERT_SAMPLES;
  for (const rule of metricRules()) {
    if (stageCohortIsLargeEnough(rule)) addComparison(rule, baseline[rule.key], 'rolling-7d');
  }
  if (previousRow) {
    for (const rule of metricRules()) {
      if (!stageCohortIsLargeEnough(rule)) continue;
      if (rule.key === 'repeat_dispatches' && previousRow.repeat_dispatch_metric_version !== currentRow.repeat_dispatch_metric_version) continue;
      addComparison(rule, previousRow.metrics?.[rule.key], 'previous-24h');
    }
  }
  for (const key of ['closed_issues', 'ci_waste_share', 'main_green_share']) {
    const rule = metricRules().find((candidate) => candidate.key === key);
    addComparison(rule, BASELINE_20261010[key], 'baseline-2026-10-10');
  }
  const violations = [...violationsByMetric.values()];
  if (!violations.length) {
    if (currentRow.source_errors?.length) {
      return {
        status: 'UNKNOWN', detail: `reason=source-unavailable sources=${currentRow.source_errors.join(',')}`,
        current, baseline, violations,
      };
    }
    return { status: 'OK', detail: `history_hours=${baseline.history_hours} regression=none`, current, baseline, violations };
  }

  const driver = chooseStage(currentRow, baseline);
  const status = violations.some((item) => item.severe) ? 'BROKEN' : 'SLOW';
  const sourceStatus = currentRow.source_errors?.length ? ` source-errors=${currentRow.source_errors.join(',')}` : '';
  const detail = `history_hours=${baseline.history_hours} regression=${violations.map((item) => `${item.metric}@${item.comparison}`).join(',')} stage=${driver.key.replace(/_seconds$/, '')} stage-label=${driver.label} driver=${driver.reason}${sourceStatus}`;
  return { status, detail, current, baseline, violations, driver };
}

// Ticket-hours overlap runner-hours. Keep CI consumption separate; never add the two.
export function weeklyTimeSinks(rows, now, states = []) {
  const stateByIssue = new Map(states.map(({ issue, state }) => [String(issue), state]));
  const until = typeof now === 'number' ? now : parseTime(now);
  if (!Number.isFinite(until)) throw new TypeError('weekly sinks need a valid end time');
  const labels = { 'ready-for-agent': '待实现与执行', 'awaiting-release': '等待上线',
    'on-hold': '暂缓事项', unrouted: '状态未分段', 'needs-advisor': '等待顾问',
    'needs-triage': '等待分诊', 'finish-first': '等前置事项', 'checks-blocked': '检查阻塞',
    'needs-info': '等待补充信息', 'awaiting-pipeline-sync': '等待流水线同步',
    'needs-recut': '等待拆分', 'needs-owner': '等待负责人', 'in-progress': '执行实现', implementing: '执行实现' };
  const events = rows.filter((row) => row.record_type === 'event' && row.issue
    && parseTime(row.ts) !== null && parseTime(row.ts) < until)
    .sort((a, b) => parseTime(a.ts) - parseTime(b.ts));
  const periods = [until - BASELINE_WINDOW_MS, until - 2 * BASELINE_WINDOW_MS]
    .map((since) => ({ since, until: since + BASELINE_WINDOW_MS, hours: new Map() }));
  const active = new Map();
  const ended = new Set();
  const add = (interval, end) => {
    if (!interval) return;
    for (const period of periods) {
      const hours = Math.max(0, Math.min(end, period.until) - Math.max(interval.at, period.since)) / HOUR_MS;
      if (hours) period.hours.set(interval.stage, (period.hours.get(interval.stage) || 0) + hours);
    }
  };
  for (const event of events) {
    const issue = String(event.issue);
    const at = parseTime(event.ts);
    if (event.event_type === 'stage-entered') {
      const stage = semanticMetricStage(stateByIssue.get(issue), event.stage, at);
      add(active.get(issue), at);
      active.delete(issue);
      if (TERMINAL_STAGES.has(stage)) ended.add(issue);
      // Label stripping after a terminal transition is not a reopened ticket.
      else if (stage !== 'unrouted' || !ended.has(issue)) {
        ended.delete(issue);
        active.set(issue, { stage: stage || 'unknown', at, sourceStage: event.stage });
      }
    } else if (event.event_type === 'stage-exited' && active.get(issue)?.sourceStage === event.stage) {
      add(active.get(issue), at);
      active.delete(issue);
    } else if (['ticket-closed', 'ticket-released', 'github-closed'].includes(event.event_type)) {
      add(active.get(issue), at);
      active.delete(issue);
      ended.add(issue);
    }
  }
  for (const interval of active.values()) add(interval, until);
  const [current, previous] = periods;
  const total = [...current.hours.values()].reduce((sum, hours) => sum + hours, 0);
  const first = events[0]?.ts || null;
  const coverage = (period) => ({ since: new Date(period.since).toISOString(),
    until: new Date(period.until).toISOString(),
    history_spans_window: first !== null && parseTime(first) <= period.since,
    observed_ticket_hours: [...period.hours.values()].reduce((sum, hours) => sum + hours, 0) });
  const currentCoverage = coverage(current);
  const hoursFor = (matches) => [...current.hours].filter(([stage]) => matches(stage))
    .reduce((sum, [, hours]) => sum + hours, 0);
  const containerStages = [...current.hours.keys()].filter((stage) => /container|testcontainers|docker|容器/i.test(stage));
  return { unit: 'observed-ticket-hours/day', first_event_at: first,
    current: currentCoverage, previous: coverage(previous),
    special_waits: {
      advisor_issue_hours_per_day: currentCoverage.history_spans_window ? hoursFor((stage) => stage === 'needs-advisor') / 7 : null,
      hold_issue_hours_per_day: currentCoverage.history_spans_window ? hoursFor((stage) => stage === 'on-hold') / 7 : null,
      container_issue_hours_per_day: containerStages.length
        ? containerStages.reduce((sum, stage) => sum + current.hours.get(stage), 0) / 7
        : currentCoverage.history_spans_window ? 0 : null,
      container_stages: containerStages,
    },
    closed_census_at: rows.filter((row) => row.record_type === 'closed-census'
      && parseTime(row.ts) !== null && parseTime(row.ts) <= until).map((row) => row.ts).sort().at(-1) || null,
    top5: [...current.hours].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 5)
      .map(([stage, hours]) => ({ stage, label: labels[stage] || '其他状态',
        hours_per_day: hours / 7, share: total ? hours / total : null,
        previous_hours_per_day: previous.hours.has(stage) ? previous.hours.get(stage) / 7
          : coverage(previous).history_spans_window ? 0 : null })) };
}

export function weeklyDeliveryMetrics(rows, now) {
  const until = typeof now === 'number' ? now : parseTime(now);
  if (!Number.isFinite(until)) throw new TypeError('weekly delivery metrics need a valid end time');
  const since = until - BASELINE_WINDOW_MS;
  const events = rows.filter((row) => row.record_type === 'event' && (row.issue || row.event_type === 'lifecycle-census')
    && parseTime(row.ts) !== null && parseTime(row.ts) < until)
    .sort((a, b) => parseTime(a.ts) - parseTime(b.ts));
  const byIssue = new Map();
  for (const event of events) {
    const key = String(event.issue);
    if (!byIssue.has(key)) byIssue.set(key, []);
    byIssue.get(key).push(event);
  }
  const productReleases = events.filter((event) => event.event_type === 'production-proof'
    && event.delivery_path === 'product-release' && insideWindow(event.ts, since, until));
  const directLands = events.filter((event) => event.event_type === 'pipeline-system-landed'
    && event.delivery_path === 'pipeline-system-direct-main' && insideWindow(event.ts, since, until));
  const definitions = [
    ['implementation', 'implementation-started', 'implementation-ended'],
    ['checks', 'implementation-ended', 'ci-completed'],
    ['merge', 'ci-completed', 'merged'],
    ['build_roll', 'merged', 'production-roll-completed'],
    ['production_proof', 'production-roll-completed', 'production-proof'],
  ];
  const stageRows = Object.fromEntries(definitions.map(([stage]) => [stage, []]));
  const openToRelease = [];
  for (const proof of productReleases) {
    const issueEvents = byIssue.get(String(proof.issue)) || [];
    const pr = proof.pr_number ? String(proof.pr_number) : null;
    if (!pr) continue;
    const attempt = Number(proof.attempt) || 0;
    const relevant = issueEvents.filter((event) => event.delivery_path === 'product-release'
      && parseTime(event.ts) <= parseTime(proof.ts)
      && String(event.pr_number || '') === pr
      && event.attempt !== null && event.attempt !== undefined && Number(event.attempt) === attempt);
    const latest = (type, before, after = -Infinity, sha = null) => relevant.filter((event) => event.event_type === type
      && parseTime(event.ts) >= after && parseTime(event.ts) <= before
      && (!sha || event.sha === sha)).at(-1) || null;
    const merged = latest('merged', parseTime(proof.ts));
    const reviewReady = latest('review-ready', parseTime(merged?.ts || proof.ts));
    const ciEnd = latest('ci-completed', parseTime(merged?.ts || proof.ts), -Infinity,
      reviewReady?.sha || null);
    const implementationEnd = latest('implementation-ended', parseTime(ciEnd?.ts || merged?.ts || proof.ts));
    const implementationStart = latest('implementation-started', parseTime(implementationEnd?.ts || proof.ts));
    const rollEnd = latest('production-roll-completed', parseTime(proof.ts), -Infinity, proof.sha || null);
    const rollStart = latest('production-roll-started', parseTime(rollEnd?.ts || proof.ts), -Infinity, proof.sha || null);
    const buildEnd = latest('production-build-completed', parseTime(rollStart?.ts || rollEnd?.ts || proof.ts), -Infinity, proof.sha || null);
    const buildStart = latest('production-build-started', parseTime(buildEnd?.ts || rollStart?.ts || proof.ts), -Infinity, proof.sha || null);
    const reviewAt = reviewReady ? parseTime(reviewReady.ts) : null;
    const implementationEndAt = implementationEnd ? parseTime(implementationEnd.ts) : null;
    const ciEndAt = ciEnd ? parseTime(ciEnd.ts) : null;
    const mergedAtMs = merged ? parseTime(merged.ts) : null;
    const buildEndAt = buildEnd ? parseTime(buildEnd.ts) : null;
    const rollStartAt = rollStart ? parseTime(rollStart.ts) : null;
    const rollEndAt = rollEnd ? parseTime(rollEnd.ts) : null;
    const checksComplete = implementationEndAt !== null && reviewAt !== null && ciEndAt !== null
      && reviewAt >= implementationEndAt && ciEndAt >= reviewAt;
    const buildRollComplete = mergedAtMs !== null && buildStart && buildEnd && rollStart && rollEnd
      && parseTime(buildStart.ts) >= mergedAtMs && buildEndAt >= parseTime(buildStart.ts)
      && rollStartAt >= buildEndAt && rollEndAt >= rollStartAt;
    const checkStart = implementationEnd;
    const intervals = {
      implementation: [implementationStart, implementationEnd],
      checks: [checksComplete ? checkStart : null, checksComplete ? ciEnd : null],
      merge: [ciEnd, merged],
      build_roll: [buildRollComplete ? merged : null, buildRollComplete ? rollEnd : null],
      production_proof: [rollEnd, proof],
    };
    for (const [stage, [start, end]] of Object.entries(intervals)) {
      const from = parseTime(start?.ts);
      const to = parseTime(end?.ts);
      if (from === null || to === null || to < from) continue;
      stageRows[stage].push({ issue: String(proof.issue), from, to,
        clipped_ms: Math.max(0, Math.min(to, until) - Math.max(from, since)) });
    }
    let openAt = null;
    for (const event of issueEvents) {
      const at = parseTime(event.ts);
      if (at > parseTime(proof.ts)) break;
      if (event.event_type === 'github-opened' || event.event_type === 'ticket-reopened') openAt = at;
      if (event.event_type === 'github-closed' && at < parseTime(proof.ts)) openAt = null;
    }
    if (openAt !== null && parseTime(proof.ts) >= openAt) openToRelease.push((parseTime(proof.ts) - openAt) / 1000);
  }
  const cohort = productReleases.length;
  const stages = Object.fromEntries(definitions.map(([key]) => {
    const samples = stageRows[key];
    return [key, { samples: samples.length, coverage: cohort ? samples.length / cohort : null,
      issue_hours_per_day: samples.length
        ? samples.reduce((sum, row) => sum + row.clipped_ms, 0) / HOUR_MS / 7 : null }];
  }));
  const censusTimes = events.filter((event) => event.event_type === 'lifecycle-census')
    .map((event) => parseTime(event.ts)).filter(Number.isFinite).sort((a, b) => a - b);
  const censusHours = new Set(censusTimes.filter((at) => at >= since && at <= until)
    .map((at) => Math.floor(at / HOUR_MS)));
  const censusStart = [...censusTimes].reverse().find((at) => at <= since) ?? null;
  const censusTimeline = censusStart === null ? [] : [censusStart, ...censusTimes.filter((at) => at > censusStart && at < until)];
  const completeCensus = censusStart !== null && since - censusStart <= 90 * 60_000
    && censusTimeline.length >= 168 && until - censusTimeline.at(-1) <= 90 * 60_000
    && censusTimeline.every((at, index) => index === 0 || at - censusTimeline[index - 1] <= 90 * 60_000);
  const runnerSeconds = events.filter((event) => event.event_type === 'ci-job-completed'
    && insideWindow(event.ts, since, until) && Number.isFinite(event.runner_seconds))
    .reduce((sum, event) => sum + event.runner_seconds, 0);
  const testcontainersRunnerSeconds = events.filter((event) => event.event_type === 'ci-job-completed'
    && event.testcontainers_job === true && insideWindow(event.ts, since, until)
    && Number.isFinite(event.runner_seconds))
    .reduce((sum, event) => sum + event.runner_seconds, 0);
  return {
    window: { since: new Date(since).toISOString(), until: new Date(until).toISOString(),
      complete: completeCensus,
      census_hours: censusHours.size,
      history_gap: completeCensus ? null
        : 'pre-rollout lifecycle timestamps are unavailable; labels and close times are not backfilled' },
    product_release_count: cohort,
    open_to_released: { median_seconds: median(openToRelease), samples: openToRelease.length,
      coverage: cohort ? openToRelease.length / cohort : null },
    stages,
    ci_runner_seconds: runnerSeconds,
    testcontainers_job_runner_seconds: testcontainersRunnerSeconds,
    pipeline_system_direct_main_count: directLands.length,
  };
}

export function efficiencySummary(home, now = new Date().toISOString()) {
  const metricRows = readMetricRows(home);
  const rows = metricRows.filter((row) => row.record_type === 'hourly' || row.sampled_at).sort((a, b) => parseTime(a.sampled_at) - parseTime(b.sampled_at));
  const current = rows.at(-1) || null;
  const target = current ? parseTime(current.sampled_at) - DAY_MS : null;
  const previous = current ? rows.filter((row) => {
    const at = parseTime(row.sampled_at);
    return at !== null && at <= target && at >= target - 6 * HOUR_MS;
  }).at(-1) || null : null;
  const baselineStart = Date.parse('2026-10-10T00:00:00Z');
  const baselineEnd = baselineStart + DAY_MS;
  const baselineRows = rows.filter((row) => {
    const at = parseTime(row.sampled_at);
    return at !== null && at >= baselineStart && at < baselineEnd;
  });
  const baselineMetrics = Object.fromEntries(METRIC_KEYS.map((key) => [
    key,
    baselineRows.length ? median(baselineRows.map((row) => row.metrics?.[key]).filter(Number.isFinite)) : null,
  ]));
  return {
    sampled_at: current?.sampled_at || null,
    weekly_time_sinks: weeklyTimeSinks(metricRows, now, listStateFiles(path.join(home, 'state'), [])),
    weekly_delivery: weeklyDeliveryMetrics(metricRows, now),
    current_24h: current ? { sampled_at: current.sampled_at, metrics: current.metrics, stage_counts: current.stage_counts,
      limiter_counts: current.limiter_counts, limiter_ticket_hours_by_reason: current.limiter_ticket_hours_by_reason,
      repeat_run_causes: current.repeat_run_causes } : null,
    previous_24h: previous ? { sampled_at: previous.sampled_at, metrics: previous.metrics } : null,
    baseline_2026_10_10: {
      measured_rows: baselineRows.length,
      metrics: {
        ...baselineMetrics,
        ...BASELINE_20261010,
      },
      source: '7 closures from 2026-10-10 ticket-transition baseline; CI shares from 2026-10-10 research',
    },
  };
}

function maintainerMailWindows(nowMs, intervalMs) {
  return {
    current: { start: nowMs - intervalMs, end: nowMs },
    previous: { start: nowMs - 2 * intervalMs, end: nowMs - intervalMs },
    yesterday: { start: nowMs - DAY_MS - intervalMs, end: nowMs - DAY_MS },
  };
}

function inWindow(value, window) {
  const at = typeof value === 'number' ? value : parseTime(value);
  return at !== null && at >= window.start && at < window.end;
}

function readMaintainerJournal(home, nowMs, windows, journalFile) {
  const earliest = Math.min(...Object.values(windows).map((window) => window.start));
  const since = new Date(earliest).toISOString();
  const until = new Date(nowMs).toISOString();
  let output = '';
  if (journalFile) {
    try {
      output = readFileSync(journalFile, 'utf8');
    } catch {
      return [];
    }
  } else {
    const result = spawnSync('journalctl', [
      '--user', '-u', 'zenoforge-agent.service', '--since', since, '--until', until, '--output=json',
    ], { encoding: 'utf8', timeout: 12_000, maxBuffer: 16 * 1024 * 1024 });
    if (result.status !== 0) return [];
    output = result.stdout;
  }
  return output.split(/\r?\n/).flatMap((line) => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
}

function maintainerTickSamples(home, nowMs, windows, journalFile) {
  const ticks = new Map();
  for (const row of readMaintainerJournal(home, nowMs, windows, journalFile)) {
    const message = String(row.MESSAGE || '');
    const match = message.match(/\btiming tick=(\S+) section=\S+ elapsed_sec=(\d+(?:\.\d+)?)(?:\s|$)/);
    if (!match) continue;
    const at = Number(row.__REALTIME_TIMESTAMP) / 1000;
    if (!Number.isFinite(at)) continue;
    const tick = ticks.get(match[1]) || { at, seconds: 0 };
    tick.at = Math.min(tick.at, at);
    tick.seconds += Number(match[2]);
    ticks.set(match[1], tick);
  }
  return Object.fromEntries(Object.entries(windows).map(([name, window]) => {
    const values = [...ticks.values()].filter((tick) => inWindow(tick.at, window)).map((tick) => tick.seconds);
    return [name, values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null];
  }));
}

function ciRatios(runSeconds, wastedRunSeconds, mainTotal, mainSuccess) {
  const totalRunnerSeconds = runSeconds.reduce((sum, value) => sum + value, 0);
  return {
    ci_waste_share: totalRunnerSeconds ? wastedRunSeconds.reduce((sum, value) => sum + value, 0) / totalRunnerSeconds : null,
    main_green_share: mainTotal ? mainSuccess / mainTotal : null,
  };
}

function maintainerCiSamples(home, windows) {
  const cache = readJson(path.join(home, 'night/efficiency-ci-jobs.json'), null);
  const rows = Object.values(cache?.runs || {});
  return Object.fromEntries(Object.entries(windows).map(([name, window]) => {
    const runSeconds = [];
    const wastedRunSeconds = [];
    let mainTotal = 0;
    let mainSuccess = 0;
    for (const row of rows) {
      if (!inWindow(row.created_at, window)) continue;
      const seconds = (row.run_seconds || []).filter(Number.isFinite);
      runSeconds.push(...seconds);
      if (['failure', 'cancelled'].includes(row.conclusion)) wastedRunSeconds.push(...seconds);
      if (row.event === 'push' && row.head_branch === 'main' && row.conclusion !== 'cancelled') {
        mainTotal += 1;
        if (row.conclusion === 'success') mainSuccess += 1;
      }
    }
    const ratios = ciRatios(runSeconds, wastedRunSeconds, mainTotal, mainSuccess);
    return [name, { ciWaste: ratios.ci_waste_share, mainGreen: ratios.main_green_share }];
  }));
}

function maintainerReceiptSamples(home, windows) {
  const dir = path.join(home, 'land-queue/logs');
  let files = [];
  try { files = readdirSync(dir).filter((name) => name.endsWith('.log')).sort(); } catch { /* no receipts yet */ }
  const receipts = new Map();
  for (const file of files) {
    let contents = '';
    try { contents = readFileSync(path.join(dir, file), 'utf8'); } catch { continue; }
    for (const line of contents.split(/\r?\n/)) {
      if (!line.includes('post-land-verify: receipt ')) continue;
      const ticket = line.match(/\bticket=(\S+)/)?.[1];
      const outcome = line.match(/\boutcome=(\S+)/)?.[1];
      const at = line.match(/\bat=(\S+)/)?.[1];
      if (!ticket || !outcome || !at || parseTime(at) === null) continue;
      const key = `${ticket}\0${at}`;
      const previous = receipts.get(key);
      const conclusive = outcome === 'green' || outcome === 'pre-existing' || outcome.startsWith('culprit-');
      receipts.set(key, { at, conclusive: Boolean(previous?.conclusive || conclusive) });
    }
  }
  return Object.fromEntries(Object.entries(windows).map(([name, window]) => {
    const rows = [...receipts.values()].filter((row) => inWindow(row.at, window));
    const good = rows.filter((row) => row.conclusive).length;
    return [name, rows.length ? good / rows.length : null];
  }));
}

function maintainerDispatchSamples(home, windows) {
  // TSV dispatch ledger is line-oriented, not JSON. Parse its small fixed schema separately.
  const file = path.join(home, 'night/supervisor-dispatch-queue.tsv.done');
  let lines = [];
  try { lines = readFileSync(file, 'utf8').split(/\r?\n/); } catch { /* missing input stays unknown */ }
  const available = existsSync(file);
  return Object.fromEntries(Object.entries(windows).map(([name, window]) => {
    if (!available) return [name, { failures: null, repeatedDispatches: null }];
    let failures = 0;
    let dispatches = 0;
    const hands = new Set();
    for (const line of lines) {
      const [stamp, hand, state] = line.split('\t');
      if (!inWindow(stamp, window)) continue;
      if ((state || '').startsWith('FAILED')) failures += 1;
      if ((state || '').startsWith('dispatched')) {
        dispatches += 1;
        if (hand?.startsWith('hand-')) hands.add(hand);
      }
    }
    return [name, { failures, repeatedDispatches: hands.size ? dispatches / hands.size : null }];
  }));
}

function maintainerLandFailureSamples(home, windows) {
  const dir = path.join(home, 'land-queue/requests');
  let files = [];
  try { files = readdirSync(dir).filter((name) => name.endsWith('.json')); } catch { /* missing input stays unknown */ }
  const available = existsSync(dir);
  const rows = files.flatMap((file) => {
    try { return [JSON.parse(readFileSync(path.join(dir, file), 'utf8'))]; } catch { return []; }
  });
  return Object.fromEntries(Object.entries(windows).map(([name, window]) => [name, available
    ? rows.filter((row) => row.state === 'failed' && inWindow(Number(row.updated_epoch) * 1000, window)).length
    : null]));
}

function maintainerPipelineIssueSamples(home, windows) {
  const source = readJson(path.join(home, 'night/ps-issues.json'), null);
  const issues = Array.isArray(source) ? source : source?.issues;
  if (!Array.isArray(issues)) return Object.fromEntries(Object.keys(windows).map((name) => [name, null]));
  const pipelineIssues = issues.filter((issue) => (issue.labels || []).some((label) => (label.name || label) === 'pipeline-system'));
  return Object.fromEntries(Object.entries(windows).map(([name, window]) => [name, {
    created: pipelineIssues.filter((issue) => inWindow(issue.createdAt, window)).length,
    closed: pipelineIssues.filter((issue) => inWindow(issue.closedAt, window)).length,
  }]));
}

export function maintainerMailEfficiencySummary(home, now = new Date().toISOString(), { journalFile } = {}) {
  const nowMs = parseTime(now);
  if (nowMs === null) throw new Error('--now must be an ISO timestamp');
  const policy = readJson(path.join(SCRIPT_DIR, '../state/maintainer-health-mail.json'), null);
  const intervalMs = Number(policy?.digest_interval_seconds) * 1000;
  if (!Number.isSafeInteger(intervalMs) || intervalMs <= 0) throw new Error('maintainer mail digest interval is invalid');
  const windows = maintainerMailWindows(nowMs, intervalMs);
  const ticks = maintainerTickSamples(home, nowMs, windows, journalFile);
  const ci = maintainerCiSamples(home, windows);
  const receipts = maintainerReceiptSamples(home, windows);
  const dispatch = maintainerDispatchSamples(home, windows);
  const landFailures = maintainerLandFailureSamples(home, windows);
  const issues = maintainerPipelineIssueSamples(home, windows);
  return {
    windows,
    metrics: Object.fromEntries(Object.keys(windows).map((name) => [name, {
      tickSeconds: ticks[name],
      ciWaste: ci[name].ciWaste,
      mainGreen: ci[name].mainGreen,
      postLandEffective: receipts[name],
      dispatchFailures: dispatch[name].failures,
      repeatedDispatches: dispatch[name].repeatedDispatches,
      landFailures: landFailures[name],
      pipelineIssues: issues[name],
    }])),
  };
}

function maintainerMetricValue(metric, key) {
  const value = metric?.[key];
  if (key === 'pipelineIssues') {
    if (!value) return null;
    return [value.created, value.closed];
  }
  return Number.isFinite(value) ? value : null;
}

function maintainerMetricLabelValue(value, key) {
  if (value === null) return '样本待补';
  if (Array.isArray(value)) return `${value[0]} / ${value[1]} 次`;
  if (['ciWaste', 'mainGreen', 'postLandEffective'].includes(key)) return `${Math.round(value * 100)}%`;
  if (key === 'tickSeconds') return `${Math.round(value)} 秒`;
  if (key === 'repeatedDispatches') return `${value.toFixed(1)} 次/人`;
  return `${value} 次`;
}

function maintainerMetricMovement(current, baseline, key) {
  if (current === null || baseline === null) return null;
  const delta = current - baseline;
  if (!delta) return null;
  if (baseline === 0) return { magnitude: Infinity, text: `从 ${maintainerMetricLabelValue(baseline, key)} 变为 ${maintainerMetricLabelValue(current, key)}` };
  const change = Math.abs(delta / baseline);
  if (change <= 0.2) return null;
  return { magnitude: change, percent: Math.round(change * 100), direction: delta > 0 ? '增加' : '下降' };
}

export function renderMaintainerMailEfficiency(summary) {
  const order = [
    ['调度一轮耗时', 'tickSeconds'],
    ['自动检查浪费占比', 'ciWaste'],
    ['主干检查通过率', 'mainGreen'],
    ['上线后复核有效率', 'postLandEffective'],
    ['派活失败次数', 'dispatchFailures'],
    ['重复派活', 'repeatedDispatches'],
    ['提交失败次数', 'landFailures'],
    ['系统自动开单 / 关单', 'pipelineIssues'],
  ];
  const metrics = summary.metrics || {};
  const lines = [
    '**效率（最近六小时）**',
    '| 指标 | 当前六小时 | 前六小时 | 昨日同时段 |',
    '| --- | ---: | ---: | ---: |',
  ];
  for (const [label, key] of order) {
    lines.push(`| ${label} | ${maintainerMetricLabelValue(maintainerMetricValue(metrics.current, key), key)} | ${maintainerMetricLabelValue(maintainerMetricValue(metrics.previous, key), key)} | ${maintainerMetricLabelValue(maintainerMetricValue(metrics.yesterday, key), key)} |`);
  }
  const changes = [];
  for (const [label, key] of order) {
    const current = maintainerMetricValue(metrics.current, key);
    if (current === null) continue;
    const candidates = ['previous', 'yesterday'].flatMap((period) => {
      const baseline = maintainerMetricValue(metrics[period], key);
      if (Array.isArray(current) && Array.isArray(baseline)) {
        const movements = current.map((value, index) => maintainerMetricMovement(value, baseline[index], key)).filter(Boolean);
        return movements.length ? [{ period, magnitude: Math.max(...movements.map((move) => move.magnitude)), text: `从 ${baseline.join(' / ')} 变为 ${current.join(' / ')}` }] : [];
      }
      const movement = maintainerMetricMovement(current, baseline, key);
      return movement ? [{ period, ...movement }] : [];
    });
    if (!candidates.length) continue;
    candidates.sort((a, b) => (b.magnitude || 0) - (a.magnitude || 0));
    const change = candidates[0];
    const period = change.period === 'previous' ? '前六小时' : '昨日同时段';
    changes.push(Array.isArray(current)
      ? `${label}较${period}${change.text}。`
      : `${label}较${period}${change.magnitude === Infinity ? change.text : `${change.direction}${change.percent}%`}。`);
  }
  lines.push('', ...(changes.length ? changes : ['近六小时指标没有单项变动超过20%。']));
  return lines.join('\n');
}

const MISSING_NODE_DAYS = new Set(['2026-10-07', '2026-10-08', '2026-10-09']);
const MISSING_NODE_START = Date.parse('2026-10-07T00:00:00Z');
const MISSING_NODE_END = Date.parse('2026-10-10T00:00:00Z');

function dailyDayStart(day) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error('--day must be YYYY-MM-DD');
  const start = Date.parse(`${day}T00:00:00Z`);
  if (!Number.isFinite(start) || new Date(start).toISOString().slice(0, 10) !== day) throw new Error('--day must be a real UTC date');
  return start;
}

function efficiencyInboxPath(home) {
  return path.join(home, 'night/efficiency-inbox');
}

function appendDailyAnomalies(home, row) {
  const stateFile = path.join(home, 'night/efficiency', `alerts-${row.day}.json`);
  const sent = new Set(readJson(stateFile, { keys: [] }).keys || []);
  for (const anomaly of row.anomalies || []) {
    if (!['SLOW', 'BROKEN'].includes(anomaly.status)) continue;
    if (anomaly.excess_hours < 0.5 && !anomaly.reasons.includes('fail-cancel-rate')) continue;
    if (sent.has(anomaly.key)) continue;
    const metrics = anomaly.evidence.map((item) => {
      if (item.metric === 'run') return `runner_mean_seconds=${item.mean_seconds} runner_baseline_seconds=${item.seven_day_mean_seconds} runner_excess_hours=${item.excess_hours.toFixed(3)}`;
      if (item.metric === 'queue') return `queue_mean_seconds=${item.mean_seconds} queue_baseline_seconds=${item.seven_day_mean_seconds} queue_excess_hours=${item.excess_hours.toFixed(3)}`;
      if (item.metric === 'fail-cancel-rate') return `fail_cancel_rate=${item.rate} fail_cancel_baseline=${item.seven_day_mean_rate}`;
      return `stage_mean_seconds=${item.mean_seconds} stage_baseline_seconds=${item.seven_day_mean_seconds} stage_excess_hours=${item.excess_hours.toFixed(3)}`;
    }).join(' ');
    const detail = `day=${row.day} status=${anomaly.status} type=${anomaly.kind} label=${anomaly.label} rank_excess_hours=${anomaly.excess_hours.toFixed(3)} reasons=${anomaly.reasons.join(',')} ${metrics}`;
    appendSupervisorAlert(home, detail, 'efficiency-anomaly', efficiencyInboxPath(home));
    sent.add(anomaly.key);
    writeJsonAtomic(stateFile, { day: row.day, keys: [...sent] });
  }
}

function checkStaleEfficiencyInbox(home, nowMs = Date.now()) {
  const inbox = efficiencyInboxPath(home);
  const marker = path.join(home, 'night/efficiency', 'inbox-escalation.json');
  mkdirSync(path.dirname(marker), { recursive: true, mode: 0o700 });
  const result = existsSync(inbox)
    ? spawnSync('flock', ['-s', `${inbox}.lock`, 'cat', inbox], { encoding: 'utf8', timeout: 10_000 })
    : { status: 0, stdout: '' };
  if (result.error || result.status !== 0) throw new Error('could not read efficiency inbox');
  const stale = String(result.stdout || '').split(/\r?\n/).find((line) => {
    const at = parseTime(line.match(/^(\S+)/)?.[1]);
    return at !== null && nowMs - at > DAY_MS;
  });
  if (!stale) {
    if (existsSync(marker)) unlinkSync(marker);
    return;
  }
  const fingerprint = createHash('sha256').update(stale).digest('hex');
  if (readJson(marker, {}).fingerprint === fingerprint) return;
  const oldestAt = stale.slice(0, stale.indexOf(' '));
  appendSupervisorAlert(home,
    `效率监督收件箱有未确认异常超过24小时，当前没有有效读取者 oldest_at=${oldestAt} signature=${fingerprint.slice(0, 12)}`,
    'efficiency-inbox-unread');
  writeJsonAtomic(marker, { fingerprint, escalated_at: new Date(nowMs).toISOString() });
}

function dailyStats(values) {
  const sorted = values.filter((value) => Number.isFinite(value) && value >= 0).sort((a, b) => a - b);
  return {
    samples: sorted.length,
    mean_seconds: sorted.length ? sorted.reduce((sum, value) => sum + value, 0) / sorted.length : null,
    p50_seconds: median(sorted),
    p90_seconds: sorted.length ? sorted[Math.ceil(sorted.length * 0.9) - 1] : null,
  };
}

function crossesMissingNodeDays(start, end) {
  return start < MISSING_NODE_END && end > MISSING_NODE_START;
}

export function dailyNodeMetrics(rows, day) {
  const dayStart = dailyDayStart(day);
  if (MISSING_NODE_DAYS.has(day)) {
    return { status: 'missing', reason: 'event history lost during disk rollback', stages: [], terminal: [] };
  }
  const dayEnd = dayStart + DAY_MS;
  const events = rows.map((row, index) => ({ row, index, at: parseTime(row.ts) }))
    .filter(({ row, at }) => at !== null && at < dayEnd
      && row.record_type === 'event' && ['stage-entered', 'stage-exited'].includes(row.event_type))
    .sort((a, b) => a.at - b.at || a.index - b.index);
  const stages = new Set();
  const active = new Map();
  const durations = new Map();
  for (const { row, at } of events) {
    const issue = String(row.issue ?? '');
    const stage = String(row.stage ?? '');
    if (!issue || !stage) continue;
    stages.add(stage);
    if (row.event_type === 'stage-entered') {
      active.set(issue, { stage, at });
      continue;
    }
    const entered = active.get(issue);
    if (entered?.stage !== stage) continue;
    active.delete(issue);
    if (at >= dayStart && !crossesMissingNodeDays(entered.at, at)) {
      const values = durations.get(stage) || [];
      values.push((at - entered.at) / 1000);
      durations.set(stage, values);
    }
  }
  const open = new Map();
  const uncertain = new Map();
  for (const { stage, at } of active.values()) {
    const counts = crossesMissingNodeDays(at, dayEnd) ? uncertain : open;
    counts.set(stage, (counts.get(stage) || 0) + 1);
  }
  const stageRows = [...stages].sort().map((stage) => ({
    key: stage,
    label: DAILY_LABELS[stage] || '其他环节',
    ...dailyStats(durations.get(stage) || []),
    open_at_end: open.get(stage) || 0,
    open_uncertain_due_to_missing_days: uncertain.get(stage) || 0,
  }));
  return {
    status: 'available',
    stages: stageRows.filter((stage) => !TERMINAL_STAGES.has(stage.key)),
    terminal: stageRows.filter((stage) => TERMINAL_STAGES.has(stage.key)),
  };
}

function utcDay(epochSeconds) {
  return Number.isFinite(epochSeconds) ? new Date(epochSeconds * 1000).toISOString().slice(0, 10) : null;
}

function jsonFiles(directory) {
  try {
    return readdirSync(directory).filter((name) => name.endsWith('.json')).map((name) => path.join(directory, name));
  } catch {
    return [];
  }
}

function localDailyChecks(home, day) {
  const checks = new Map([
    ['commit-preflight', { run: [], queue: [], source: path.join(home, 'land-queue/logs') }],
    ['check-rulings', { run: [], queue: [], source: path.join(home, 'land-queue/logs') }],
    ['landing-queue', { run: [], queue: [], source: path.join(home, 'land-queue/requests') }],
    ['review', { run: [], queue: [], source: path.join(home, 'logs') }],
  ]);
  const requests = new Map();
  for (const file of jsonFiles(path.join(home, 'land-queue/requests'))) {
    const request = readJson(file, null);
    if (request?.ticket) requests.set(String(request.ticket), request);
    if (request?.state !== 'landed' || utcDay(request.finished_epoch) !== day) continue;
    const seconds = Number.isFinite(request.enqueue_to_main_seconds) ? request.enqueue_to_main_seconds
      : request.finished_epoch - request.enqueued_epoch;
    if (Number.isFinite(seconds) && seconds >= 0) checks.get('landing-queue').run.push(seconds);
  }
  const landLogs = path.join(home, 'land-queue/logs');
  try {
    for (const name of readdirSync(landLogs).filter((item) => /^[0-9]{20}\.log$/.test(item))) {
      const request = requests.get(name.slice(0, -4));
      if (utcDay(request?.finished_epoch) !== day) continue;
      const body = readFileSync(path.join(landLogs, name), 'utf8');
      for (const match of body.matchAll(/land-direct-main: preflight (?:finished|failed) ticket=\S+ stage=\S+ duration_ms=([\d.]+)/g)) {
        checks.get('commit-preflight').run.push(Number(match[1]) / 1000);
      }
      for (const match of body.matchAll(/Preflight stage (?:finished|failed): ticket=\S+ stage=check-rulings\S* duration_ms=([\d.]+)/g)) {
        checks.get('check-rulings').run.push(Number(match[1]) / 1000);
      }
    }
  } catch {
    // Missing log directory is reported as a missing source below.
  }
  const reviewLogs = path.join(home, 'logs');
  try {
    for (const name of readdirSync(reviewLogs).filter((item) => /^review-.*-\d{8}T\d{6}Z\.log$/.test(item))) {
      const stamp = name.match(/-(\d{8})T/)[1];
      if (`${stamp.slice(0, 4)}-${stamp.slice(4, 6)}-${stamp.slice(6, 8)}` !== day) continue;
      const body = readFileSync(path.join(reviewLogs, name), 'utf8');
      for (const match of body.matchAll(/"codex_elapsed_seconds"\s*:\s*(\d+)/g)) checks.get('review').run.push(Number(match[1]));
    }
  } catch {
    // Missing review logs are reported as a missing source below.
  }
  return [...checks].map(([name, value]) => ({
    key: `local:${name}`,
    name,
    label: DAILY_LABELS[name],
    category: 'local',
    source_status: existsSync(value.source) ? 'available' : 'no timing source',
    run: dailyStats(value.run),
    queue: dailyStats(value.queue),
    fail_cancel_rate: null,
    status_samples: 0,
    runner_minutes: null,
  }));
}

function dailyCiChecks(ci) {
  const groups = new Map();
  for (const job of ci.job_samples || []) {
    const name = String(job.name || '').trim();
    if (!name || !['pr', 'main'].includes(job.cohort)) continue;
    const key = `ci:${job.cohort}:${name}`;
    const samples = groups.get(key) || { key, name, cohort: job.cohort, jobs: [] };
    samples.jobs.push(job);
    groups.set(key, samples);
  }
  return [...groups.values()].map(({ key, name, cohort, jobs }) => {
    const rated = jobs.filter((job) => job.status === 'completed' && job.conclusion);
    const failed = rated.filter((job) => ['failure', 'cancelled', 'timed_out', 'action_required'].includes(job.conclusion)).length;
    const run = dailyStats(jobs.map((job) => job.run_seconds));
    return {
      key,
      name,
      label: DAILY_LABELS[name] || `其他检查：${name}`,
      category: 'ci',
      cohort,
      source_status: 'available',
      samples: run.samples,
      run,
      queue: dailyStats(jobs.map((job) => job.queue_seconds)),
      status_samples: rated.length,
      fail_cancel_rate: rated.length ? failed / rated.length : null,
      runner_minutes: run.samples ? jobs.reduce((sum, job) => sum + (Number.isFinite(job.run_seconds) ? job.run_seconds : 0), 0) / 60 : 0,
    };
  }).sort((a, b) => a.cohort.localeCompare(b.cohort) || a.name.localeCompare(b.name));
}

function dailyResourceUtilization(home, day, rows, ci = null) {
  const start = dailyDayStart(day);
  const end = start + DAY_MS;
  const inDay = (value) => {
    const at = parseTime(value);
    return at !== null && at >= start && at < end;
  };
  const events = rows.filter((row) => row.record_type === 'event' && inDay(row.ts));
  const limiter = events.filter((row) => row.event_type === 'limiter' && row.outcome === 'skipped');
  const dispatches = events.filter((row) => row.event_type === 'dispatch');
  const attemptTerminals = events.filter((row) => row.event_type === 'attempt-terminal');
  const gates = {};
  const categories = {};
  for (const row of limiter) {
    gates[row.gate || 'unknown'] = (gates[row.gate || 'unknown'] || 0) + 1;
    categories[row.category || 'unknown'] = (categories[row.category || 'unknown'] || 0) + 1;
  }
  const byIssue = new Map();
  for (const row of dispatches) {
    const issue = String(row.issue ?? '');
    if (issue) byIssue.set(issue, (byIssue.get(issue) || 0) + 1);
  }
  const repeatedDispatches = [...byIssue.values()].reduce((sum, count) => sum + Math.max(0, count - 1), 0);
  const killedHands = attemptTerminals.filter((row) =>
    /kill|watchdog|signal:?\s*9|oom|timeout/i.test(`${row.terminal_cause || ''} ${row.systemd_result || ''}`)).length;

  const memoryMb = [];
  const nightLog = path.join(home, 'night/night.log');
  if (existsSync(nightLog)) {
    let tickDay = null;
    for (const line of readFileSync(nightLog, 'utf8').split('\n')) {
      const tick = line.match(/tick=(\d{4})(\d{2})(\d{2})T/);
      if (tick) tickDay = `${tick[1]}-${tick[2]}-${tick[3]}`;
      if (tickDay !== day) continue;
      const match = line.match(/refusing:\s+MemAvailable\s+(\d+)MB/i);
      if (match) memoryMb.push(Number(match[1]));
    }
  }
  const memory = memoryMb.sort((a, b) => a - b);
  const memoryAtRefusal = {
    samples_M: memory.length,
    min_mb_M: memory.length ? memory[0] : null,
    p50_mb_M: memory.length ? median(memory) : null,
    max_mb_M: memory.length ? memory.at(-1) : null,
  };

  let liveHandsSnapshot = null;
  const agentsFile = path.join(home, 'night/agents.txt');
  if (day === new Date().toISOString().slice(0, 10) && existsSync(agentsFile)) {
    const pids = [...readFileSync(agentsFile, 'utf8').matchAll(/^\d+:(\d+)\t/gm)].map((match) => match[1]);
    liveHandsSnapshot = { observed_at: new Date().toISOString(), count_M: pids.filter((pid) => existsSync(`/proc/${pid}`)).length };
  }

  let ciJobs = Array.isArray(ci?.job_samples) ? ci.job_samples : null;
  let cachedSampleRuns = { pr: null, main: null };
  if (!ciJobs) {
    const cache = readCiJobCache(path.join(home, 'night/efficiency-ci-jobs.json'), start, end - 1);
    ciJobs = [];
    const seen = { pr: new Set(), main: new Set() };
    for (const [key, entry] of cache) {
      const cohort = entry.event === 'pull_request' ? 'pr' : entry.event === 'push' ? 'main' : null;
      if (!cohort) continue;
      seen[cohort].add(key);
      const runId = Number(key.split(':')[0]);
      ciJobs.push(...(entry.jobs || []).map((job) => ({
        ...job, cohort, workflow_run_id: runId, workflow_conclusion: entry.conclusion,
      })));
    }
    if (cache.size) cachedSampleRuns = { pr: seen.pr.size, main: seen.main.size };
  }
  const queue = ciJobs.map((job) => job.queue_seconds).filter(Number.isFinite);
  queue.sort((a, b) => a - b);
  const runnerSecondsSampled = ciJobs.reduce((sum, job) => sum + (Number.isFinite(job.run_seconds) ? job.run_seconds : 0), 0);
  const sampledWorkflowRuns = ci?.sampled_workflow_runs || ci?.sampled_runs || cachedSampleRuns;
  const population = ci?.workflow_population || { pr: null, main: null };
  const requestCounts = { landed: 0, failed: 0, cancelled: 0, running: 0 };
  const landingFailures = {};
  const requestSeconds = [];
  for (const file of jsonFiles(path.join(home, 'land-queue/requests'))) {
    const request = readJson(file, null);
    if (!request) continue;
    const requestStateDay = request.state === 'running' ? utcDay(request.updated_epoch) : utcDay(request.finished_epoch);
    if (requestStateDay === day && Object.hasOwn(requestCounts, request.state)) {
      requestCounts[request.state] += 1;
      if (request.state === 'failed') {
        const detail = request.reason || '';
        const reason = /rebase.*conflict|conflict.*rebase/i.test(detail) ? 'rebase-conflict'
          : /auth|permission|credential/i.test(detail) ? 'authorization'
            : /fetch|network|gateway|timeout/i.test(detail) ? 'network-or-timeout'
              : /preflight|test|suite|ruling/i.test(detail) ? 'preflight-or-check' : 'other';
        landingFailures[reason] = (landingFailures[reason] || 0) + 1;
      }
    }
    if (request.state === 'landed' && utcDay(request.finished_epoch) === day) {
      const duration = request.finished_epoch - request.enqueued_epoch;
      if (Number.isFinite(duration) && duration >= 0) requestSeconds.push(duration);
    }
  }

  const mainJobs = ciJobs.filter((job) => job.cohort === 'main');
  const mainRunVerdicts = new Map();
  for (const job of mainJobs) {
    const key = job.workflow_run_id ?? job.workflow_conclusion;
    if (key !== undefined && job.workflow_conclusion) mainRunVerdicts.set(String(key), job.workflow_conclusion);
  }
  const mainRedRuns = [...mainRunVerdicts.values()].filter((value) => ['failure', 'timed_out', 'action_required'].includes(value)).length;
  const mainVerdictCount = [...mainRunVerdicts.values()].filter((value) => value !== 'cancelled').length;
  const mainGreenShare = Number.isFinite(ci?.main_green_share) ? ci.main_green_share
    : mainVerdictCount ? (mainVerdictCount - mainRedRuns) / mainVerdictCount : null;

  return {
    status: 'partial',
    dispatch: {
      dispatches_M: dispatches.length || null,
      refusals_by_category_M: limiter.length ? categories : null,
      refusals_by_gate_M: limiter.length ? gates : null,
      repeat_issue_dispatches_M: dispatches.length ? repeatedDispatches : null,
    },
    codex: {
      provider_quota_holds_M: limiter.length ? gates['provider-quota'] || 0 : null,
      scan_budget_holds_M: limiter.length ? gates['budget-exhausted'] || 0 : null,
      other_budget_holds_M: limiter.length ? categories.budget || 0 : null,
    },
    wsl: {
      memavailable_at_refusal_M: memoryAtRefusal,
      live_hands_snapshot_M: liveHandsSnapshot,
      live_hands_reason: liveHandsSnapshot ? null : 'no current-day agents.txt snapshot',
    },
    cihost_ci: {
      runner_busy_pct_M: null,
      runner_slot_demand_pct_E: null,
      runner_slot_demand_reason: 'needs a current enabled-runner capacity snapshot and workflow population count',
      runner_slots_M: null,
      sampled_workflow_runs_M: sampledWorkflowRuns,
      workflow_population_M: population,
      runner_seconds_sampled_M: ciJobs.length ? runnerSecondsSampled : null,
      queue_p50_seconds_M: median(queue),
      queue_p90_seconds_M: queue.length ? queue[Math.ceil(queue.length * 0.9) - 1] : null,
    },
    landing: {
      ...requestCounts,
      landed_per_hour_M: requestCounts.landed / 24,
      busy_pct_M: null,
      failure_reasons_M: landingFailures,
      landed_duration_seconds_M: dailyStats(requestSeconds),
    },
    post_land: {
      live_depth_M: null,
      oldest_live_seconds_M: null,
    },
    main: {
      red_hours_M: null,
      red_hours_reason: 'no timestamped main-red to main-green transitions',
      sampled_red_runs_M: mainRedRuns,
      sampled_runs_M: mainVerdictCount,
      green_share_M: mainGreenShare,
    },
    rework: {
      repeat_issue_dispatches_M: dispatches.length ? repeatedDispatches : null,
      dispatches_M: dispatches.length || null,
      repeat_dispatch_share_M: dispatches.length ? repeatedDispatches / dispatches.length : null,
      watchdog_killed_hands_M: attemptTerminals.length ? killedHands : null,
      attempt_terminals_M: attemptTerminals.length || null,
      watchdog_killed_share_M: attemptTerminals.length ? killedHands / attemptTerminals.length : null,
      retried_landings_M: null,
      retried_landings_reason: 'queue request records do not link retry generations',
    },
    source_coverage: {
      event_rows_M: events.length,
      event_first_at_M: events.length ? events.map((row) => row.ts).sort()[0] : null,
      event_last_at_M: events.length ? events.map((row) => row.ts).sort().at(-1) : null,
      event_counts_are_observed_only: true,
      refusal_mem_samples_M: memory.length,
      runner_job_cache: ciJobs.length ? 'sampled' : 'missing',
    },
  };
}

function dayBefore(day) {
  return new Date(dailyDayStart(day) - DAY_MS).toISOString().slice(0, 10);
}

function attachComparison(stat, day, history, getValue) {
  const previousDay = dayBefore(day);
  const previousRow = history.find((row) => row.day === previousDay);
  const previous = previousRow ? getValue(previousRow) : null;
  const baselineStart = dailyDayStart(day) - 7 * DAY_MS;
  const baselineRows = history.filter((row) => {
    const at = dailyDayStart(row.day);
    return at >= baselineStart && at < dailyDayStart(day);
  });
  const baseline = baselineRows.map(getValue).filter(Number.isFinite);
  stat.comparison = {
    previous_day: previousDay,
    previous_mean_seconds: Number.isFinite(previous) ? previous : null,
    seven_day_days: baselineRows.filter((row) => Number.isFinite(getValue(row))).map((row) => row.day),
    seven_day_mean_seconds: baseline.length ? baseline.reduce((sum, value) => sum + value, 0) / baseline.length : null,
  };
}

function attachRateComparison(check, day, history) {
  if (!Number.isFinite(check.fail_cancel_rate)) return;
  const previousDay = dayBefore(day);
  const prior = history.find((row) => row.day === previousDay);
  const priorCheck = [...(prior?.checks?.ci || [])].find((item) => item.key === check.key);
  const baselineRows = history.filter((row) => {
    const at = dailyDayStart(row.day);
    return at >= dailyDayStart(day) - 7 * DAY_MS && at < dailyDayStart(day);
  });
  const rates = baselineRows.map((row) => row.checks?.ci?.find((item) => item.key === check.key)?.fail_cancel_rate)
    .filter(Number.isFinite);
  check.fail_cancel_comparison = {
    previous_day: previousDay,
    previous_rate: Number.isFinite(priorCheck?.fail_cancel_rate) ? priorCheck.fail_cancel_rate : null,
    seven_day_days: baselineRows.filter((row) => Number.isFinite(row.checks?.ci?.find((item) => item.key === check.key)?.fail_cancel_rate)).map((row) => row.day),
    seven_day_mean_rate: rates.length ? rates.reduce((sum, value) => sum + value, 0) / rates.length : null,
  };
}

function dailyAnomalies(row) {
  const anomalies = new Map();
  const severity = { WATCH: 0, SLOW: 1, BROKEN: 2 };
  const record = (key, kind, label, status, extraHours, reason, evidence) => {
    const value = anomalies.get(key) || { key, kind, label, status, excess_hours: 0, reasons: [], evidence: [] };
    if (severity[status] > severity[value.status]) value.status = status;
    value.excess_hours += extraHours;
    value.reasons.push(reason);
    value.evidence.push(evidence);
    anomalies.set(key, value);
  };
  const addDuration = (key, kind, label, stat, metric) => {
    const baseline = stat?.comparison?.seven_day_mean_seconds;
    if (!stat || stat.samples < 5 || !Number.isFinite(stat.mean_seconds) || !Number.isFinite(baseline) || baseline <= 0) return;
    if (stat.mean_seconds <= baseline) return;
    const status = stat.mean_seconds > baseline * 3 ? 'BROKEN'
      : stat.mean_seconds > baseline * 1.5 ? 'SLOW' : 'WATCH';
    const extraHours = ((stat.mean_seconds - baseline) * stat.samples) / 3600;
    record(key, kind, label, status, extraHours, metric, {
      metric, samples: stat.samples, mean_seconds: stat.mean_seconds,
      seven_day_mean_seconds: baseline, excess_hours: extraHours,
    });
  };
  for (const stage of row.nodes.stages || []) {
    if (TERMINAL_STAGES.has(stage.key)) continue;
    addDuration(`node:${stage.key}`, 'node', stage.label, stage, 'run');
  }
  for (const check of [...row.checks.ci, ...row.checks.local]) {
    addDuration(check.key, 'check', checkMailLabel(check), check.run, 'run');
    addDuration(check.key, 'check', checkMailLabel(check), check.queue, 'queue');
    const comparison = check.fail_cancel_comparison;
    if (check.status_samples >= 5 && Number.isFinite(check.fail_cancel_rate)
      && Number.isFinite(comparison?.seven_day_mean_rate)
      && check.fail_cancel_rate > comparison.seven_day_mean_rate + 0.10) {
      const delta = check.fail_cancel_rate - comparison.seven_day_mean_rate;
      record(check.key, 'check', checkMailLabel(check), delta > 0.20 ? 'BROKEN' : 'SLOW', 0, 'fail-cancel-rate', {
        metric: 'fail-cancel-rate', samples: check.status_samples, rate: check.fail_cancel_rate,
        seven_day_mean_rate: comparison.seven_day_mean_rate,
      });
    }
  }
  return [...anomalies.values()].sort((a, b) => b.excess_hours - a.excess_hours
    || severity[b.status] - severity[a.status] || a.label.localeCompare(b.label));
}

function slowestChecks(checks) {
  const mean = (stat) => Number.isFinite(stat?.mean_seconds) ? stat.mean_seconds : -1;
  return checks.filter((item) => item.run.samples > 0 || item.queue.samples > 0)
    .map((item) => ({ ...item, slowest_metric: mean(item.queue) > mean(item.run) ? 'queue' : 'run' }))
    .sort((a, b) => Math.max(mean(b.run), mean(b.queue)) - Math.max(mean(a.run), mean(a.queue))
      || a.label.localeCompare(b.label))
    .slice(0, 3);
}

export function compareDailyMetrics(current, history) {
  separateTerminalNodeStages(current.nodes);
  const previousRows = history.filter((row) => row.record_type === 'daily' && row.day < current.day);
  for (const stage of current.nodes.stages || []) {
    attachComparison(stage, current.day, previousRows, (row) => {
      if (row.nodes?.status !== 'available') return null;
      return row.nodes.stages?.find((item) => item.key === stage.key)?.mean_seconds ?? null;
    });
  }
  for (const check of [...current.checks.ci, ...current.checks.local]) {
    const findCheck = (row) => [...(row.checks?.ci || []), ...(row.checks?.local || [])].find((item) => item.key === check.key);
    for (const metric of ['run', 'queue']) {
      attachComparison(check[metric], current.day, previousRows, (row) => findCheck(row)?.[metric]?.mean_seconds ?? null);
    }
    attachRateComparison(check, current.day, previousRows);
  }
  current.anomalies = dailyAnomalies(current);
  current.slowest_nodes = [...(current.nodes.stages || [])]
    .filter((item) => !TERMINAL_STAGES.has(item.key) && item.samples > 0)
    .sort((a, b) => b.mean_seconds - a.mean_seconds).slice(0, 3);
  current.slowest_checks = slowestChecks([...current.checks.ci, ...current.checks.local]);
  current.mail_summary = dailyMailSummary(current);
  return current;
}

function checkMailLabel(check) {
  const label = DAILY_LABELS[check.name] || DAILY_LABELS[check.key.replace(/^local:/, '')]
    || (check.name ? `其他检查：${check.name}` : '其他检查');
  if (check.category !== 'ci') return label;
  return `${check.cohort === 'pr' ? '合并请求' : '主线'}${label}`;
}

function separateTerminalNodeStages(nodes) {
  const terminal = new Map((nodes.terminal || []).map((stage) => [stage.key, stage]));
  const stages = [];
  for (const stage of nodes.stages || []) {
    if (TERMINAL_STAGES.has(stage.key)) terminal.set(stage.key, stage);
    else stages.push(stage);
  }
  nodes.stages = stages;
  nodes.terminal = [...terminal.values()].sort((a, b) => a.key.localeCompare(b.key));
}

function refreshDailyLabels(row) {
  separateTerminalNodeStages(row.nodes);
  for (const stage of [...(row.nodes.stages || []), ...(row.nodes.terminal || [])]) {
    stage.label = DAILY_LABELS[stage.key] || '其他环节';
  }
  for (const check of [...(row.checks.ci || []), ...(row.checks.local || [])]) check.label = DAILY_LABELS[check.name] || `其他检查：${check.name}`;
  row.anomalies = dailyAnomalies(row);
  row.slowest_nodes = [...(row.nodes.stages || [])]
    .filter((item) => !TERMINAL_STAGES.has(item.key) && item.samples > 0)
    .sort((a, b) => b.mean_seconds - a.mean_seconds).slice(0, 3);
  row.slowest_checks = slowestChecks([...(row.checks.ci || []), ...(row.checks.local || [])]);
  row.mail_summary = dailyMailSummary(row);
  return row;
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds)) return '暂无数据';
  if (seconds >= 3600) return `${Number((seconds / 3600).toFixed(1))}小时`;
  if (seconds >= 60) return `${Number((seconds / 60).toFixed(1))}分钟`;
  return `${Math.round(seconds)}秒`;
}

function formatChange(seconds, baseline) {
  if (!Number.isFinite(seconds) || !Number.isFinite(baseline) || baseline <= 0) return '无对比';
  const change = Math.round((seconds / baseline - 1) * 100);
  return change === 0 ? '持平' : `${change > 0 ? '+' : ''}${change}%`;
}

function dailyMailSummary(row) {
  const lines = ['**流程环节与检查耗时**'];
  const changeLine = (label, stat) => `- ${label}：均值 ${formatDuration(stat.mean_seconds)}；较前日 ${formatChange(stat.mean_seconds, stat.comparison?.previous_mean_seconds)}，较七日均值 ${formatChange(stat.mean_seconds, stat.comparison?.seven_day_mean_seconds)}。`;
  const checkLine = (check) => `- ${checkMailLabel(check)}（${check.slowest_metric === 'queue' ? '排队较久' : '运行较久'}）：运行均值 ${formatDuration(check.run.mean_seconds)}（较前日 ${formatChange(check.run.mean_seconds, check.run.comparison?.previous_mean_seconds)}，较七日均值 ${formatChange(check.run.mean_seconds, check.run.comparison?.seven_day_mean_seconds)}）；排队均值 ${formatDuration(check.queue.mean_seconds)}（较前日 ${formatChange(check.queue.mean_seconds, check.queue.comparison?.previous_mean_seconds)}，较七日均值 ${formatChange(check.queue.mean_seconds, check.queue.comparison?.seven_day_mean_seconds)}）。`;
  if (row.slowest_nodes?.length) {
    lines.push('环节：', ...row.slowest_nodes.map((item) => changeLine(item.label, item)));
  } else lines.push('环节：暂无可比数据。');
  if (row.slowest_checks?.length) {
    lines.push('检查：', ...row.slowest_checks.map(checkLine));
  } else lines.push('检查：暂无可比数据。');
  if (row.anomalies?.length) {
    lines.push('主要异常：', ...row.anomalies.slice(0, 3).map((item) => {
      const status = item.status === 'BROKEN' ? '明显变慢'
        : item.status === 'SLOW' ? '偏慢' : '略高于七日均值';
      const extra = item.kind === 'check'
        ? item.evidence.filter((entry) => ['run', 'queue'].includes(entry.metric) && entry.excess_hours > 0)
          .map((entry) => `${entry.metric === 'run' ? '运行' : '排队'}比平时多耗 ${Number(entry.excess_hours.toFixed(1))}小时`).join('，')
        : item.excess_hours > 0 ? `比平时多耗 ${Number(item.excess_hours.toFixed(1))}小时` : '';
      const failures = item.reasons.includes('fail-cancel-rate') ? '，失败或取消比例升高' : '';
      return `- ${status}：${item.label}${extra ? `，${extra}` : ''}${failures}。`;
    }));
  } else lines.push('主要异常：无明显异常。');
  return lines.join('\n');
}

function persistDailyJson(home, row) {
  const directory = path.join(home, 'night/efficiency');
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  chmodSync(directory, 0o700);
  writeJsonAtomic(path.join(directory, `daily-${row.day}.json`), row);
}

export async function dailyEfficiency({ home, repo, day, readOnly = false, fetchCi = collectGitHubCiSamples, nowMs = Date.now() } = {}) {
  if (!home || !day || (!repo && !readOnly)) throw new TypeError('home, day, and repo are required');
  if (!Number.isFinite(nowMs)) throw new TypeError('nowMs must be a valid epoch timestamp');
  const dayStart = dailyDayStart(day);
  const isReportingDay = day === new Date(nowMs - DAY_MS).toISOString().slice(0, 10);
  if (!readOnly && isReportingDay) checkStaleEfficiencyInbox(home, nowMs);
  const rows = readMetricRows(home);
  const existing = rows.find((row) => row.record_type === 'daily' && row.day === day);
  if (existing) {
    existing.resource_utilization = dailyResourceUtilization(home, day, rows, existing.sources?.ci || null);
    const result = refreshDailyLabels(existing);
    if (!readOnly) {
      persistDailyJson(home, result);
      if (isReportingDay) appendDailyAnomalies(home, result);
    }
    return result;
  }
  if (readOnly) {
    return {
      day, status: 'unavailable', nodes: { status: 'missing', reason: 'daily row not recorded', stages: [], terminal: [] },
      checks: { ci: [], local: [] }, anomalies: [], slowest_nodes: [], slowest_checks: [],
      mail_summary: '**流程环节与检查耗时**\n环节：暂无可比数据。\n检查：暂无可比数据。\n主要异常：暂无可比数据。',
    };
  }
  const ci = await fetchCi(repo, dayStart, {
    cacheFile: path.join(home, 'night/efficiency-ci-jobs.json'),
    deadlineMs: Date.now() + DEFAULT_SAMPLE_TIMEOUT_MS,
    nowMs: dayStart + DAY_MS - 1,
  });
  const nodes = dailyNodeMetrics(rows, day);
  const local = localDailyChecks(home, day);
  const resources = dailyResourceUtilization(home, day, rows, ci);
  const record = compareDailyMetrics({
    schema_version: 1,
    record_type: 'daily',
    event_id: `daily:${day}`,
    ts: new Date(dayStart).toISOString(),
    day,
    nodes,
    resource_utilization: resources,
    checks: { ci: dailyCiChecks(ci), local },
    sources: {
      ci: {
        sampled_runs: ci.sampled_runs || {},
        sampled_workflow_runs: ci.sampled_workflow_runs || {},
        workflow_population: ci.workflow_population || {},
        errors: ci.errors,
        error_reasons: ci.error_reasons || {},
      },
      local: Object.fromEntries(local.map((check) => [check.name, { status: check.source_status, samples: check.run.samples }])),
    },
  }, rows);
  appendMetricRecord(home, record);
  persistDailyJson(home, record);
  if (isReportingDay) appendDailyAnomalies(home, record);
  return record;
}

function alertMessage(violation, driver) {
  const ids = driver.tickets.map((issue) => `#${issue}`).join(',') || 'none';
  const stageCurrent = formatMetric(driver.seconds);
  const stageBaseline = formatMetric(driver.key ? driver.baseline : null);
  const status = violation.severe ? 'BROKEN' : 'SLOW';
  return `status=${status} metric=${violation.metric} comparison=${violation.comparison} current=${formatMetric(violation.current)} baseline=${formatMetric(violation.baseline)} stage=${driver.key.replace(/_seconds$/, '')} stage-label=${driver.label} stage-current=${stageCurrent} stage-baseline=${stageBaseline} driver=${driver.reason} tickets=${ids}`;
}

function appendSupervisorAlert(home, message, kind = 'efficiency-regression', inbox = path.join(home, 'supervisor-inbox')) {
  const result = spawnSync('bash', [
    '-c', 'source "$1" && supervisor_inbox_append "$2" "$3" "$4"',
    'bash', LIB_PATH, kind, message, inbox,
  ], {
    encoding: 'utf8', timeout: 10_000, stdio: ['ignore', 'ignore', 'pipe'],
    env: { ...process.env, AGENT_HOME: home },
  });
  if (result.error || result.status !== 0) throw new Error('supervisor inbox append failed');
}

function addSourceErrors(row, ci) {
  row.source_errors.push(...ci.errors);
  row.metrics.ci_queue_seconds = median(ci.queue_seconds);
  row.metrics.ci_run_seconds = median(ci.run_seconds);
  row.metrics.ci_waste_share = ci.ci_waste_share ?? null;
  row.metrics.main_green_share = ci.main_green_share ?? null;
  row.ci_sampled_runs = ci.sampled_runs || {};
  row.ci_sample_method = ci.sample_method || null;
  row.ci_run_list_page_requests = Number.isSafeInteger(ci.workflow_run_page_requests)
    ? ci.workflow_run_page_requests : null;
  row.ci_job_requests = Number.isSafeInteger(ci.jobs_requests) ? ci.jobs_requests : null;
  row.ci_source_error_reasons = ci.error_reasons || {};
}

export async function sampleEfficiency({
  home,
  repo,
  now = new Date(),
  fetchCi = collectGitHubCiSamples,
  getRunningIssues = readRunningImplementIssues,
  getOpenIssues = readOpenIssues,
  getClosedIssues = readClosedIssues,
  sendAlert = (message) => appendSupervisorAlert(home, message, 'efficiency-regression', efficiencyInboxPath(home)),
} = {}) {
  if (!home || !repo) throw new TypeError('home and repo are required');
  const nowDate = now instanceof Date ? now : new Date(now);
  const nowMs = nowDate.getTime();
  if (!Number.isFinite(nowMs)) throw new TypeError('now must be a valid date');
  const configuredTimeoutSeconds = Number(process.env.EFFICIENCY_SAMPLE_TIMEOUT_SECONDS);
  const timeoutMs = Number.isFinite(configuredTimeoutSeconds) && configuredTimeoutSeconds > 0
    ? configuredTimeoutSeconds * 1000 : DEFAULT_SAMPLE_TIMEOUT_MS;
  const ciDeadlineMs = Date.now() + Math.max(0, timeoutMs - SAMPLE_FINALIZE_RESERVE_MS);
  const stateDir = path.join(home, 'state');
  const alarmStateFile = path.join(stateDir, 'efficiency-alarm-state.json');
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  migrateLegacyHistory(home);
  syncTicketTransitionEvents(home);
  syncRunLifecycleEvents(home, nowDate);
  const rows = readHourlyHistory(home);
  const hour = Math.floor(nowMs / HOUR_MS);
  let currentRow = [...rows].sort((a, b) => parseTime(a.sampled_at) - parseTime(b.sampled_at)).at(-1);
  if (!currentRow || currentRow.repeat_dispatch_metric_version !== 2
    || currentRow.ticket_tracking_metric_version !== 2
    || Math.floor(parseTime(currentRow.sampled_at) / HOUR_MS) !== hour) {
    const sourceErrors = [];
    const runningIssues = getRunningIssues(sourceErrors);
    let openIssues;
    const [openResult, closedResult] = await Promise.allSettled([
      getOpenIssues(home, repo, nowMs), getClosedIssues(home, repo, nowMs),
    ]);
    if (openResult.status === 'fulfilled' && Array.isArray(openResult.value)) {
      openIssues = openResult.value;
      appendMetricRecords(home, openIssueMetricRows(openResult.value));
    }
    else sourceErrors.push('open-issues:unreadable');
    if (closedResult.status === 'fulfilled' && Array.isArray(closedResult.value)) {
      appendMetricRecords(home, [...closedIssueMetricRows(closedResult.value), {
        record_type: 'closed-census', ts: nowDate.toISOString(), event_id: `closed-census:${hour}`,
      }]);
    } else sourceErrors.push('closed-issues:unreadable');
    currentRow = {
      sampled_at: nowDate.toISOString(),
      ...collectStateMetrics(home, nowMs, runningIssues, openIssues),
    };
    currentRow.source_errors.push(...sourceErrors);
    try {
      const ci = await fetchCi(repo, nowMs - DAY_MS, {
        cacheFile: path.join(home, 'night', 'efficiency-ci-jobs.json'),
        deadlineMs: ciDeadlineMs,
        nowMs,
      });
      addSourceErrors(currentRow, ci);
    } catch {
      currentRow.source_errors.push('ci:unreadable');
    }
    appendMetricRecord(home, { record_type: 'hourly', ...currentRow });
    rows.push(currentRow);
  }

  const assessment = assessEfficiency(rows);
  const alertState = readJson(alarmStateFile, { last_alerted_at: {} });
  const lastAlerted = alertState.last_alerted_at && typeof alertState.last_alerted_at === 'object'
    ? alertState.last_alerted_at : {};
  const emitted = [];
  if (assessment.status !== 'UNKNOWN') {
    const active = new Set(assessment.violations.map((item) => item.metric));
    let stateChanged = false;
    for (const key of Object.keys(lastAlerted)) {
      if (!active.has(key)) {
        delete lastAlerted[key];
        stateChanged = true;
      }
    }
    for (const violation of assessment.violations) {
      const last = parseTime(lastAlerted[violation.metric]);
      if (last !== null && nowMs - last < ALARM_INTERVAL_MS) continue;
      const message = alertMessage(violation, assessment.driver);
      await sendAlert(message, violation);
      emitted.push({ metric: violation.metric, message });
      lastAlerted[violation.metric] = nowDate.toISOString();
      writeJsonAtomic(alarmStateFile, { last_alerted_at: lastAlerted });
    }
    if (!assessment.violations.length || emitted.length || stateChanged) {
      writeJsonAtomic(alarmStateFile, { last_alerted_at: lastAlerted });
    }
  }
  return { ...assessment, row: currentRow, alerts: emitted };
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = {};
  for (let index = 0; index < rest.length; index += 1) {
    const key = rest[index];
    if (key === '--read-only') {
      options.readOnly = true;
      continue;
    }
    if (!['--home', '--repo', '--history', '--before', '--now', '--day', '--journal-file', '--issue'].includes(key)) throw new Error(`unknown argument: ${key}`);
    options[key.slice(2)] = rest[++index] || '';
  }
  if (command === 'sample') {
    if (!options.home || !options.repo) throw new Error('usage: efficiency-regression.mjs sample --home DIR --repo OWNER/REPO [--now ISO]');
  } else if (command === 'baseline') {
    if ((!options.history && !options.home) || !options.before) throw new Error('usage: efficiency-regression.mjs baseline (--history FILE|--home DIR) --before ISO');
  } else if (command === 'summary') {
    if (!options.home) throw new Error('usage: efficiency-regression.mjs summary --home DIR');
  } else if (command === 'sync-issue') {
    if (!options.home || !/^\d+$/.test(options.issue || '')) throw new Error('usage: efficiency-regression.mjs sync-issue --home DIR --issue N');
  } else if (command === 'maintainer-mail') {
    if (!options.home) throw new Error('usage: efficiency-regression.mjs maintainer-mail --home DIR [--now ISO] [--journal-file FILE]');
  } else if (command === 'daily') {
    if (!options.home || !options.day || (!options.repo && !options.readOnly)) {
      throw new Error('usage: efficiency-regression.mjs daily --home DIR --day YYYY-MM-DD [--repo OWNER/REPO] [--read-only]');
    }
  } else {
    throw new Error('usage: efficiency-regression.mjs sample|baseline|summary|daily|maintainer-mail ...');
  }
  return { command, options };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { command, options } = parseArgs(process.argv.slice(2));
    if (command === 'sample') {
      const result = await sampleEfficiency({
        home: path.resolve(options.home),
        repo: options.repo,
        now: options.now ? new Date(options.now) : new Date(),
      });
      process.stdout.write(`${JSON.stringify(result)}\n`);
    } else if (command === 'baseline') {
      const before = parseTime(options.before);
      if (before === null) throw new Error('--before must be an ISO timestamp');
      if (options.home) migrateLegacyHistory(path.resolve(options.home));
      const history = options.home
        ? readHourlyHistory(path.resolve(options.home))
        : readHistory(path.resolve(options.history));
      const result = rollingBaseline(history, before);
      process.stdout.write(`${JSON.stringify(result)}\n`);
    } else if (command === 'daily') {
      const result = await dailyEfficiency({
        home: path.resolve(options.home),
        repo: options.repo,
        day: options.day,
        readOnly: options.readOnly,
      });
      process.stdout.write(`${JSON.stringify(result)}\n`);
    } else if (command === 'sync-issue') {
      syncIssueLifecycleEvents(path.resolve(options.home), options.issue);
    } else if (command === 'maintainer-mail') {
      const summary = maintainerMailEfficiencySummary(path.resolve(options.home), options.now || new Date().toISOString(), {
        journalFile: options['journal-file'] ? path.resolve(options['journal-file']) : undefined,
      });
      process.stdout.write(`${renderMaintainerMailEfficiency(summary)}\n`);
    } else {
      const result = efficiencySummary(path.resolve(options.home), options.now || new Date().toISOString());
      process.stdout.write(`${JSON.stringify(result)}\n`);
    }
  } catch (error) {
    process.stderr.write(`efficiency-regression: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
