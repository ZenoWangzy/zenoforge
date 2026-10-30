const key = (r) => `${r.stage}/${r.caseId}/${r.run}`;
const supervisorActions = ['approve', 'requeue', 'park', 'close', 'reroute', 'decision'];
const percent = (numerator, denominator) => denominator ? `${(100 * numerator / denominator).toFixed(1)}%` : 'n/a';
function index(rows) {
  const map = new Map();
  for (const row of rows) {
    if (map.has(key(row))) throw new Error(`duplicate result: ${key(row)}`);
    if (typeof row.pass !== 'boolean') throw new Error(`invalid pass: ${key(row)}`);
    map.set(key(row), row);
  }
  return map;
}
function inconsistent(rows) {
  const groups = new Map();
  for (const row of rows) {
    const id = `${row.stage}/${row.caseId}`;
    if (!groups.has(id)) groups.set(id, []);
    groups.get(id).push(row);
  }
  return [...groups].filter(([, rs]) => new Set(rs.map((r) => r.pass)).size > 1)
    .map(([id, runs]) => ({ id, runs: runs.map(({ run, pass }) => ({ run, pass })) }));
}
export function compareResults(baseline, candidate) {
  const a = index(baseline.results), b = index(candidate.results);
  // Only case/runs present in both labels are compared; the paired ids are reported so a
  // partial label (--case runs, --resume fills) shows exactly what the comparison covered.
  const paired = [...a.keys()].filter((id) => b.has(id)).sort();
  const regressions = [], improvements = [], unpaired = [];
  for (const id of new Set([...a.keys(), ...b.keys()])) {
    const before = a.get(id), after = b.get(id);
    if (!before || !after) { unpaired.push({ id, onlyIn: before ? baseline.label : candidate.label }); continue; }
    if (before.pass && !after.pass) regressions.push({ ...after, before: true, after: false });
    if (!before.pass && after.pass) improvements.push({ ...after, before: false, after: true });
  }
  const total = (rows) => ({ passed: rows.filter((r) => r.pass).length, total: rows.length });
  const pairedRows = paired.map((id) => a.get(id)).filter((row) => row.stage === 'supervisor');
  return { baseline: baseline.label, candidate: candidate.label,
    totals: { baseline: total(baseline.results), candidate: total(candidate.results) },
    supervisor: { baseline: summarizeSupervisor(baseline.results), candidate: summarizeSupervisor(candidate.results),
      alwaysRequeue: summarizeSupervisor(pairedRows).alwaysRequeue },
    paired, regressions, improvements, unpaired,
    inconsistency: { baseline: inconsistent(baseline.results), candidate: inconsistent(candidate.results) } };
}
export function summarizeSupervisor(rows) {
  const decisions = rows.filter((row) => row.stage === 'supervisor' && supervisorActions.includes(row.expectedAction));
  const byAction = Object.fromEntries(supervisorActions.map((action) => {
    const cases = decisions.filter((row) => row.expectedAction === action);
    return [action, { correct: cases.filter((row) => row.pass).length, total: cases.length }];
  }));
  const correct = decisions.filter((row) => row.expectedAction === 'requeue').length;
  return { total: decisions.length, byAction,
    unsafeApproves: decisions.filter((row) => row.unsafeApprove).length,
    alwaysRequeue: { correct, total: decisions.length } };
}
function formatActionAccuracy(label, summary) {
  if (!summary.total) return `supervisor action accuracy ${label}: no supervisor results`;
  return `supervisor action accuracy ${label}: ${supervisorActions.map((action) => {
    const row = summary.byAction[action];
    return `${action} ${row.correct}/${row.total} (${percent(row.correct, row.total)})`;
  }).join('; ')}; unsafe approve ${summary.unsafeApproves}`;
}
function formatRequeueReference(row) {
  return `supervisor constant-requeue reference (paired cases): ${row.correct}/${row.total} (${percent(row.correct, row.total)})`;
}
export function formatComparison(r) {
  const supervisorLines = r.supervisor.baseline.total || r.supervisor.candidate.total
    ? [formatActionAccuracy(r.baseline, r.supervisor.baseline),
      formatActionAccuracy(r.candidate, r.supervisor.candidate),
      formatRequeueReference(r.supervisor.alwaysRequeue)]
    : [];
  return [
    ...r.regressions.map((x) => `REGRESSION pass→fail ${x.stage}/${x.caseId} run ${x.run}`),
    ...(r.regressions.length ? [] : ['pass→fail: none']),
    `${r.baseline}: ${r.totals.baseline.passed}/${r.totals.baseline.total}; ${r.candidate}: ${r.totals.candidate.passed}/${r.totals.candidate.total}`,
    ...supervisorLines,
    ...r.improvements.map((x) => `fail→pass ${x.stage}/${x.caseId} run ${x.run}`),
    ...r.unpaired.map((x) => `UNPAIRED ${x.id} only in ${x.onlyIn}`),
    ...['baseline', 'candidate'].map((label) => `inconsistency ${r[label]}: ${r.inconsistency[label].length} cases${r.inconsistency[label].map((x) => `\n  ${x.id}: ${x.runs.map((run) => `${run.run}=${run.pass ? 'pass' : 'fail'}`).join(', ')}`).join('')}`),
    `compared in both labels: ${r.paired.length ? r.paired.join(', ') : 'none'}`,
  ].join('\n');
}

export function compareArms(result) {
  const rows = result.results.filter((r) => r.repair_arms);
  const paired = rows.filter((r) => ['cold', 'resume'].every((arm) => typeof r.repair_arms[arm].pass === 'boolean'));
  const resources = (values) => {
    if (!values.length || !values.every(Number.isFinite)) return { median: null, sum: null };
    const sorted = [...values].sort((a, b) => a - b), mid = Math.floor(sorted.length / 2);
    return { median: sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2,
      sum: values.reduce((sum, value) => sum + value, 0) };
  };
  return { label: result.label, chains: rows.length, paired: paired.length,
    arms: Object.fromEntries(['cold', 'resume'].map((name) => {
      const arms = rows.map((r) => r.repair_arms[name]);
      const ran = arms.filter((arm) => typeof arm.pass === 'boolean');
      return [name, { passed: ran.filter((arm) => arm.pass).length, total: ran.length,
        skipped: arms.filter((arm) => arm.status === 'skipped').length,
        tokens: resources(ran.map((arm) => arm.tokens)), wall_ms: resources(ran.map((arm) => arm.wall_ms)) }];
    })),
    discordant: {
      coldOnly: paired.filter((r) => r.repair_arms.cold.pass && !r.repair_arms.resume.pass).map(key),
      resumeOnly: paired.filter((r) => !r.repair_arms.cold.pass && r.repair_arms.resume.pass).map(key),
    } };
}
export function formatArmComparison(r) {
  const metric = (m) => `median=${m.median ?? 'unknown'} sum=${m.sum ?? 'unknown'}`;
  return [
    `${r.label}: chains with arms=${r.chains}; complete pairs=${r.paired}`,
    ...['cold', 'resume'].map((name) => {
      const arm = r.arms[name];
      return `${name}: pass ${arm.passed}/${arm.total}; skipped=${arm.skipped}; tokens ${metric(arm.tokens)}; wall_ms ${metric(arm.wall_ms)}`;
    }),
    `cold pass, resume fail: ${r.discordant.coldOnly.length}${r.discordant.coldOnly.map((id) => `\n  ${id}`).join('')}`,
    `resume pass, cold fail: ${r.discordant.resumeOnly.length}${r.discordant.resumeOnly.map((id) => `\n  ${id}`).join('')}`,
  ].join('\n');
}
