#!/usr/bin/env node
// Run with `node engine/main-ci-red-replay.mjs` for rolling seven-day JSONL.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const agentHome = process.env.AGENT_HOME || path.join(os.homedir(), '.zenoforge');
const now = Math.floor(Date.now() / 1000);
const windowStart = now - 7 * 24 * 60 * 60;
const episodeFile = path.join(agentHome, 'quarantine', 'main-ci-red-episodes.jsonl');
const activeFile = path.join(agentHome, 'quarantine', 'implement.json');
const faultFile = path.join(agentHome, 'env-faults', 'env:main-ci-red.log');

const readText = (file) => {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return '';
    throw error;
  }
};
const epoch = (value) => Number.isSafeInteger(value) && value >= 0 ? value : null;
const iso = (value) => epoch(value) !== null ? new Date(value * 1000).toISOString() : 'UNKNOWN';
const validPath = (value) => typeof value === 'string' && value.length > 0 && !value.startsWith('/') && !value.split('/').includes('..');
const overlap = (left, right) => left.some((a) => right.some((b) => a === b || a.startsWith(`${b}/`) || b.startsWith(`${a}/`)));

const events = [];
const malformedEvents = [];
for (const [index, line] of readText(episodeFile).split(/\r?\n/).entries()) {
  if (!line.trim()) continue;
  try {
    const event = JSON.parse(line);
    if (typeof event.episode_id !== 'string' || !event.episode_id) throw new Error('missing episode_id');
    events.push(event);
  } catch {
    malformedEvents.push(index + 1);
  }
}

let activeEpisodeId = '';
try {
  const active = JSON.parse(readText(activeFile) || '{}');
  if (active.signature === 'env:main-ci-red') {
    const runId = (active.main_run_ids || []).find((value) => epoch(value) !== null);
    activeEpisodeId = active.episode_id || `main-ci-red-${active.since ?? 0}-${runId ?? 'unknown'}`;
  }
} catch {
  // A malformed active record cannot establish that an episode is still open.
}

const groups = new Map();
for (const event of events) {
  if (!groups.has(event.episode_id)) groups.set(event.episode_id, []);
  groups.get(event.episode_id).push(event);
}

const output = [];
for (const [episodeId, rows] of groups) {
  const opened = rows.find((row) => row.event === 'open');
  const lifted = rows.find((row) => row.event === 'lift');
  const scope = [...rows].reverse().find((row) => row.event === 'extend' || row.event === 'fallback') || opened;
  const openedAt = epoch(opened?.opened_at);
  const liftedAt = epoch(lifted?.lifted_at);
  const isActive = !lifted && activeEpisodeId === episodeId;
  const endAt = liftedAt !== null ? liftedAt : isActive ? now : null;
  const intersectsWindow = openedAt !== null && openedAt <= now && (endAt === null || endAt >= windowStart);
  if (!intersectsWindow && openedAt !== null) continue;
  const startAt = openedAt !== null ? Math.max(openedAt, windowStart) : null;
  const duration = startAt !== null && endAt !== null ? Math.max(0, endAt - startAt) : 'UNKNOWN';
  const snapshot = opened?.candidate_snapshot;
  const candidatesKnown = snapshot?.status === 'complete' && Array.isArray(snapshot.candidates);
  const counts = { allowed: 0, blocked: 0, unknown: 0 };
  if (candidatesKnown) {
    for (const candidate of snapshot.candidates) {
      let result = 'unknown';
      const surface = candidate.surface;
      const blockedPaths = scope?.blocked_paths;
      const blockedEpics = scope?.blocked_epics;
      if (scope?.full_block === true) {
        result = 'blocked';
      } else if (scope?.scope_known === true && Array.isArray(blockedPaths) && blockedPaths.length > 0
        && candidate.scope_known === true && Array.isArray(surface) && surface.length > 0
        && surface.every(validPath) && blockedPaths.every(validPath)) {
        const sameEpic = typeof candidate.roadmap_epic === 'number' && Array.isArray(blockedEpics)
          && blockedEpics.includes(String(candidate.roadmap_epic));
        result = sameEpic || overlap(blockedPaths, surface) ? 'blocked' : 'allowed';
      }
      counts[result] += 1;
    }
  }
  const countValue = (key) => candidatesKnown ? counts[key] : 'UNKNOWN';
  const exposure = candidatesKnown && duration !== 'UNKNOWN'
    ? Object.fromEntries(Object.entries(counts).map(([key, count]) => [key, count * duration]))
    : 'UNKNOWN';
  output.push({
    episode_id: episodeId,
    opened_at: Number.isFinite(openedAt) ? iso(openedAt) : 'UNKNOWN',
    lifted_at: lifted ? iso(liftedAt) : isActive ? 'ACTIVE' : 'UNKNOWN',
    quarantine_seconds_in_window: duration,
    candidate_count: candidatesKnown ? snapshot.candidates.length : 'UNKNOWN',
    allowed: countValue('allowed'),
    blocked: countValue('blocked'),
    unknown: countValue('unknown'),
    candidate_exposure_seconds: exposure,
    failed_run_ids: scope?.failed_run_ids || opened?.failed_run_ids || 'UNKNOWN',
    failed_signatures: scope?.failed_signatures || opened?.failed_signatures || 'UNKNOWN',
    blocked_paths: scope?.blocked_paths || opened?.blocked_paths || 'UNKNOWN',
    blocked_epics: scope?.blocked_epics || opened?.blocked_epics || 'UNKNOWN',
    actual_saved_ticket_hours: 'UNKNOWN',
    history_status: opened && lifted && candidatesKnown ? 'recorded' : 'UNKNOWN',
  });
}

const recordedRuns = new Set(events.flatMap((event) => event.failed_run_ids || []).map(String));
const legacyFaults = new Map();
for (const line of readText(faultFile).split(/\r?\n/)) {
  const [timestamp, , issue, signature, detail = ''] = line.split('\t');
  if (signature !== 'env:main-ci-red' || !/^\d+$/.test(timestamp || '') || Number(timestamp) < windowStart || Number(timestamp) > now) continue;
  const runId = detail.match(/main ci\.yml push run ([1-9][0-9]*)/)?.[1] || '';
  if (runId && recordedRuns.has(runId)) continue;
  const key = runId ? `legacy-run-${runId}` : `legacy-fault-${timestamp}-${issue || 'unknown'}`;
  if (!legacyFaults.has(key)) legacyFaults.set(key, { runId, timestamp: Number(timestamp) });
  else legacyFaults.get(key).timestamp = Math.min(legacyFaults.get(key).timestamp, Number(timestamp));
}
for (const [episodeId, fault] of legacyFaults) {
  output.push({
    episode_id: episodeId,
    opened_at: 'UNKNOWN',
    first_fault_at: iso(fault.timestamp),
    lifted_at: 'UNKNOWN',
    quarantine_seconds_in_window: 'UNKNOWN',
    failed_run_ids: fault.runId ? [Number(fault.runId)] : 'UNKNOWN',
    candidate_count: 'UNKNOWN',
    allowed: 'UNKNOWN',
    blocked: 'UNKNOWN',
    unknown: 'UNKNOWN',
    candidate_exposure_seconds: 'UNKNOWN',
    actual_saved_ticket_hours: 'UNKNOWN',
    history_status: 'UNKNOWN',
  });
}

if (malformedEvents.length) {
  output.push({
    episode_id: 'UNKNOWN', opened_at: 'UNKNOWN', lifted_at: 'UNKNOWN',
    quarantine_seconds_in_window: 'UNKNOWN', candidate_count: 'UNKNOWN',
    allowed: 'UNKNOWN', blocked: 'UNKNOWN', unknown: 'UNKNOWN',
    candidate_exposure_seconds: 'UNKNOWN', actual_saved_ticket_hours: 'UNKNOWN',
    history_status: 'UNKNOWN', malformed_event_lines: malformedEvents,
  });
}
if (!output.length) {
  output.push({
    episode_id: 'UNKNOWN', opened_at: 'UNKNOWN', lifted_at: 'UNKNOWN',
    quarantine_seconds_in_window: 'UNKNOWN', candidate_count: 'UNKNOWN',
    allowed: 'UNKNOWN', blocked: 'UNKNOWN', unknown: 'UNKNOWN',
    candidate_exposure_seconds: 'UNKNOWN', actual_saved_ticket_hours: 'UNKNOWN',
    history_status: 'UNKNOWN', reason: 'No retained episode evidence covers the seven-day window',
  });
}

for (const row of output) process.stdout.write(`${JSON.stringify(row)}\n`);
