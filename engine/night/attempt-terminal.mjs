#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { appendMetricRecord, readMetricRows } from './efficiency-regression.mjs';

export function classifyTerminal(failure, result) {
  if (result === 'oom-kill') return 'host-memory';
  if (result === 'timeout' || Number(failure?.status) === 124) return 'local-timeout';
  if (Number(failure?.status) === 143 || ['signal', 'core-dump', 'watchdog'].includes(result)) return 'interrupted';
  const reason = failure?.reason || '';
  const detail = `${reason}\n${failure?.evidence || ''}`;
  if (failure?.stage === 'no-reviewable-diff') {
    if (/BLOCKED-ON:[^\n]*#[1-9][0-9]*/.test(detail)) return 'blocked-dependency';
    if (/SCOPE-STOP:|BLOCKED-(?:ON|CHECKS):|缺(?:少|实际)|无法(?:证明|判断|核对)|待.{0,40}提供|还需|仍未|missing (?:evidence|logs|container)|cannot (?:verify|proceed)/i.test(detail)) return 'brief-ambiguous';
    if (/无需(?:重复)?改代码|no (?:new )?(?:edits|change|code changes).{0,20}needed|(?:fix|requested (?:fix|change)).{0,40}already (?:exists|landed|on)/i.test(detail)) return 'no-change-needed';
  }
  if (/runtime-budget-before-launch/.test(reason)) return 'launch-budget-refused';
  if (/usage limit|quota exhausted|rate limit|too many requests/i.test(reason)) return 'quota';
  if (failure?.stage === 'review-verdict' || /NOT_READY/.test(reason)) return 'review-not-ready';
  if (/main did not become green|env:main-ci-red/i.test(reason)) return 'main-red';
  if (/GnuTLS|Could not resolve host|ConnectTimeout|ECONNRESET|EAI_AGAIN|TLS connection|provider outage|network (error|timeout)/i.test(detail)) return 'network-egress';
  if (/could not apply|with conflicts|did not rebase|CONFLICT \(/i.test(detail)) return 'rebase-conflict';
  if (/preflight|checkpoint|guard refused|risk.class|P2\/L4|blast.radius|no reviewable diff|awaiting live checkout|lesson-fragments|correction-enforcement/i.test(reason)) return 'guard-refused';
  if (failure?.stage === 'package-gate') return 'test-build-gate';
  if (/ambiguous|needs.info|decision request/i.test(reason)) return 'brief-ambiguous';
  if (/oversized|needs.recut|too (large|broad)|split ticket/i.test(reason)) return 'ticket-size';
  if (Number(failure?.status) === 127) return 'launch-unavailable';
  return 'unknown';
}

// Log files are model calls, not charged attempts. Match their times to unit evidence.
export function chargedRunLines(home, issue, lines, bootId) {
  const events = readMetricRows(home).filter((row) => row.issue === Number(issue));
  const terminals = events.filter((row) => row.event_type === 'attempt-terminal');
  const excluded = terminals.filter((row) => (row.terminal_cause === 'interrupted' && (row.attempt_refunded === true || Number(row.exit_status) === 143))
    || (row.terminal_cause === 'network-egress' && row.attempt_refunded === true));
  for (const start of events.filter((row) => row.event_type === 'attempt-started')) {
    if (start.boot_id && start.boot_id !== bootId && !terminals.some((row) => row.attempt_id === start.attempt_id)) {
      const next = events.filter((row) => row.event_type === 'attempt-started' && Date.parse(row.ts) > Date.parse(start.ts)).sort((a,b) => Date.parse(a.ts) - Date.parse(b.ts))[0];
      excluded.push({started_at:start.ts, ts:next ? new Date(Date.parse(next.ts) - 1000).toISOString() : new Date().toISOString()});
    }
  }
  return lines.filter((line) => {
    const stamp = line.match(/-([0-9]{8}T[0-9]{6}Z)\.log$/)?.[1];
    if (!stamp) return true;
    const at = Date.parse(`${stamp.slice(0,4)}-${stamp.slice(4,6)}-${stamp.slice(6,8)}T${stamp.slice(9,11)}:${stamp.slice(11,13)}:${stamp.slice(13,15)}Z`);
    return !excluded.some((row) => row.started_at && at >= Math.floor(Date.parse(row.started_at) / 1000) * 1000 && at <= Date.parse(row.ts));
  });
}

export function recordAttempt(home, issue, kind, env = process.env, now = new Date()) {
  if (!/^[1-9][0-9]*$/.test(String(issue))) throw new Error('invalid issue number');
  const ts = now.toISOString();
  const invocation = env.INVOCATION_ID || '';
  if (!invocation) return; // systemd owns terminal recording; manual runs have no stop hook.
  const event = { record_type: 'event', event_type: `attempt-${kind}`, issue: Number(issue),
    attempt_id: invocation, ts, event_id: `${invocation}|attempt-${kind}` };
  if (kind === 'started') {
    event.boot_id = readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
  } else if (kind === 'terminal') {
    const start = readMetricRows(home).find((row) => row.event_type === 'attempt-started' && row.attempt_id === invocation);
    const state = JSON.parse(readFileSync(path.join(home, 'state', `${issue}.json`), 'utf8'));
    const failures = [state.implement_failure, state.model_policy?.failure, state.model_policy?.retry_note,
      state.implement_decision && {stage:'no-reviewable-diff', evidence:state.implement_decision.question, recorded_at:state.implement_decision.requested_at},
      ...(state.model_policy?.failures || [])].filter((failure) => start && failure?.recorded_at
        && Date.parse(failure.recorded_at) >= Math.floor(Date.parse(start.ts) / 1000) * 1000 && Date.parse(failure.recorded_at) <= now.getTime())
      .sort((a, b) => Date.parse(a.recorded_at) - Date.parse(b.recorded_at));
    const failure = failures.at(-1);
    event.terminal_cause = classifyTerminal(Number(env.EXIT_STATUS) === 143 ? {status:143} : failure, env.SERVICE_RESULT);
    event.attempt_refunded = failure?.attempt_refunded === true;
    if (!failure && env.SERVICE_RESULT === 'success' && ['merged', 'pipeline-system', 'deployed'].includes(state.run?.outcome)) event.terminal_cause = 'completed';
    event.started_at = start?.ts || null;
    event.agent_seconds = start ? Math.max(0, (now - Date.parse(start.ts)) / 1000) : null;
    event.systemd_result = env.SERVICE_RESULT || 'unknown';
    event.exit_status = env.EXIT_STATUS || null;
    event.evidence_source = failure ? 'current-attempt-state-failure' : 'systemd-result';
    event.confidence = event.terminal_cause === 'unknown' ? 'low' : 'high';
  } else throw new Error('expected started or terminal');
  appendMetricRecord(home, event);
  return event;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === 'classify-no-diff') {
    console.log(classifyTerminal({stage:'no-reviewable-diff', evidence:readFileSync(0, 'utf8')}, 'success'));
  } else if (process.argv[2] === 'charged-runs') {
    const lines = chargedRunLines(process.env.AGENT_HOME, process.argv[3], readFileSync(0,'utf8').trim().split('\n'), readFileSync('/proc/sys/kernel/random/boot_id','utf8').trim());
    if (lines.length) console.log(lines.join('\n'));
  } else {
    recordAttempt(process.env.AGENT_HOME || path.join(process.env.HOME, '.zenoforge'), process.argv[3], process.argv[2]);
  }
}
