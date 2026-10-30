import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { collectThroughputMetrics } from './throughput-metrics.mjs';

test('computes stage p50/p95 only from states with valid timestamps', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'zf-throughput-'));
  const stateDir = path.join(root, 'state');
  mkdirSync(stateDir);
  const state = (offset) => ({
    released: true,
    run: {
      entered_at: '2026-10-05T00:00:00Z',
      implement_started_at: `2026-10-05T00:0${offset}:00Z`,
      concluded_at: `2026-10-05T00:${20 + offset}:00Z`,
      evidence: {
        pr_number: '123',
        merged_pr: { number: 123, merged_at: `2026-10-05T00:${10 + offset}:00Z` },
        review_ready_at: `2026-10-05T00:0${offset + 2}:00Z`,
        ci_completed_at: `2026-10-05T00:0${offset + 4}:00Z`,
        ci_green_at: `2026-10-05T00:0${offset + 4}:00Z`,
        production_evidence_at: `2026-10-05T00:${20 + offset}:00Z`,
        real_user_path: 'URL: https://example.test\\nVisible DOM: ready\\nSame-run network: 200',
      },
    },
    deploy_state: 'deployed',
    deployed_sha: 'a'.repeat(40),
  });
  writeFileSync(path.join(stateDir, '1.json'), JSON.stringify(state(1)));
  writeFileSync(path.join(stateDir, '2.json'), JSON.stringify(state(2)));
  writeFileSync(path.join(stateDir, 'broken.json'), '{not json');

  const result = collectThroughputMetrics(stateDir);
  assert.equal(result.state_files, 3);
  assert.equal(result.production_accepted, 2);
  assert.equal(result.stages.implement_to_review.samples, 2);
  assert.equal(result.stages.implement_to_review.p50_seconds, 120);
  assert.equal(result.stages.review_to_ci.p95_seconds, 120);
  assert.equal(result.stages.merge_to_production.p50_seconds, 600);
});

test('missing merge or production proof stays unknown instead of using close timestamps', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'zf-throughput-unknown-'));
  const stateDir = path.join(root, 'state');
  mkdirSync(stateDir);
  writeFileSync(path.join(stateDir, '3.json'), JSON.stringify({
    released: true,
    run: {
      entered_at: '2026-10-05T00:00:00Z',
      implement_started_at: '2026-10-05T00:01:00Z',
      merged_at: '2026-10-05T00:10:00Z',
      concluded_at: '2026-10-05T00:20:00Z',
      evidence: {
        pr_number: '123',
        review_ready_at: '2026-10-05T00:03:00Z',
        ci_green_at: '2026-10-05T00:05:00Z',
      },
    },
  }));
  const result = collectThroughputMetrics(stateDir);
  assert.equal(result.production_accepted, 0);
  assert.equal(result.stages.ci_to_merge.samples, 0);
  assert.equal(result.stages.end_to_end.samples, 0);
});

test('empty state directory returns zero samples instead of fabricating latency', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'zf-throughput-empty-'));
  const stateDir = path.join(root, 'state');
  mkdirSync(stateDir);
  const result = collectThroughputMetrics(stateDir);
  assert.equal(result.stages.end_to_end.samples, 0);
  assert.equal(result.stages.end_to_end.p50_seconds, null);
});

test('flow numbers: windowed merge rate, in/out conservation, per-stage WIP age', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'zf-throughput-flow-'));
  const stateDir = path.join(root, 'state');
  mkdirSync(stateDir);
  const markers = 'URL: https://example.test\\nVisible DOM: ready\\nSame-run network: 200';
  writeFileSync(path.join(stateDir, '11.json'), JSON.stringify({
    run: {
      entered_at: '2026-10-06T08:00:00Z',
      implement_started_at: '2026-10-06T08:10:00Z',
      evidence: {
        pr_number: '11',
        review_ready_at: '2026-10-06T08:20:00Z',
        ci_completed_at: '2026-10-06T08:30:00Z',
        merged_pr: { number: 11, merged_at: '2026-10-06T08:40:00Z' },
        production_evidence_at: '2026-10-06T09:00:00Z',
        real_user_path: markers,
      },
    },
    deploy_state: 'deployed',
    deployed_sha: 'a'.repeat(40),
  }));
  // Open in the implement stage since 08:40 (3 h 20 m before the fixed now).
  writeFileSync(path.join(stateDir, '12.json'), JSON.stringify({
    run: { entered_at: '2026-10-06T08:10:00Z', implement_started_at: '2026-10-06T08:40:00Z' },
  }));
  // Open in the queue stage since 11:00.
  writeFileSync(path.join(stateDir, '13.json'), JSON.stringify({
    run: { entered_at: '2026-10-06T11:00:00Z' },
  }));
  // Merged at 08:00 without production proof: open in merge_to_production since the merge.
  writeFileSync(path.join(stateDir, '14.json'), JSON.stringify({
    run: {
      entered_at: '2026-10-06T06:30:00Z',
      implement_started_at: '2026-10-06T06:40:00Z',
      evidence: {
        pr_number: '14',
        review_ready_at: '2026-10-06T06:50:00Z',
        ci_completed_at: '2026-10-06T06:55:00Z',
        merged_pr: { number: 14, merged_at: '2026-10-06T08:00:00Z' },
      },
    },
  }));

  const flow = collectThroughputMetrics(stateDir, { now: '2026-10-06T12:00:00Z', windowHours: 5 }).flow;
  assert.equal(flow.window_hours, 5);
  assert.equal(flow.entered, 3); // 11, 12, 13 entered inside the window
  assert.equal(flow.merged, 2); // 11 and 14 merged inside the window
  assert.equal(flow.merges_per_hour, 2 / 5);
  assert.equal(flow.imbalance, 1);
  assert.equal(flow.wip_age_seconds.queue_to_implement.samples, 1);
  assert.equal(flow.wip_age_seconds.queue_to_implement.p50_seconds, 3600);
  assert.equal(flow.wip_age_seconds.implement_to_review.p50_seconds, 12000);
  assert.equal(flow.wip_age_seconds.merge_to_production.p50_seconds, 14400);
  assert.equal(flow.wip_age_seconds.ci_to_merge.samples, 0);
  assert.deepEqual(flow.wip_age_seconds.implement_to_review.oldest, [{ issue: '12', seconds: 12000 }]);
});
