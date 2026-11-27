// Pure grader for fresh-agent runs: no model, no network, no session memory.
// The runner records facts per step; this module only reads them.

const SHA = /^[0-9a-f]{40}$/;
const CASE_KEYS = ['id', 'source_url', 'base_sha', 'fix_sha', 'prompt', 'hidden_check', 'expected_divergence', 'remediation'];
const nonEmpty = (v) => typeof v === 'string' && v.trim().length > 0;

// Returns the list of problems; an empty list means the case is valid.
// Unknown keys are rejected so a case cannot smuggle in memory or session context.
export function validateFreshCase(c) {
  if (!c || typeof c !== 'object' || Array.isArray(c)) return ['case must be an object'];
  const failures = Object.keys(c).filter((k) => !CASE_KEYS.includes(k)).map((k) => `unknown key: ${k}`);
  if (!nonEmpty(c.id)) failures.push('id: required');
  if (c.source_url !== undefined && !/^https:\/\/github\.com\/ZenoWangzy\/zenoforge\/issues\/\d+$/.test(c.source_url)) {
    failures.push('source_url: expected a Zenoforge issue URL');
  }
  if (!SHA.test(c.base_sha ?? '')) failures.push('base_sha: expected a 40-char lowercase frozen commit SHA');
  if (c.fix_sha !== undefined) {
    if (!SHA.test(c.fix_sha)) failures.push('fix_sha: expected a 40-char lowercase known-fix commit SHA');
    else if (c.fix_sha === c.base_sha) failures.push('fix_sha: must differ from base_sha');
  }
  if (!nonEmpty(c.prompt)) failures.push('prompt: required');
  if (!nonEmpty(c.hidden_check)) failures.push('hidden_check: required');
  if (!nonEmpty(c.expected_divergence)) failures.push('expected_divergence: required step id');
  if (c.remediation !== undefined) {
    if (!c.remediation || typeof c.remediation !== 'object' || Array.isArray(c.remediation)) failures.push('remediation: expected an object');
    else {
      if (!c.remediation.doc || !nonEmpty(c.remediation.doc.path) || !nonEmpty(c.remediation.doc.line)) failures.push('remediation.doc: path and line required');
      if (!nonEmpty(c.remediation.guard)) failures.push('remediation.guard: rule required');
    }
  }
  return failures;
}

// run: { passed, steps: [{ id, ok, doc_available, guard_available }] } in run order.
// Returns null for a passing run. Otherwise the first failing step decides the class:
// no doc at base -> missing-doc; no guard at base -> missing-guard; else agent-error.
export function classifyFailedRun(run) {
  if (run.passed) return null;
  if (!Array.isArray(run.steps)) throw new TypeError('run.steps must be an array');
  const step = run.steps.find((s) => s.ok !== true);
  if (!step) return { class: 'agent-error', first_divergence: null };
  if (typeof step.doc_available !== 'boolean' || typeof step.guard_available !== 'boolean') {
    throw new TypeError(`step facts must be booleans: ${step.id}`);
  }
  if (!step.doc_available) return { class: 'missing-doc', first_divergence: step.id };
  if (!step.guard_available) return { class: 'missing-guard', first_divergence: step.id };
  return { class: 'agent-error', first_divergence: step.id };
}

export function buildFreshAgentGapIssue(c, results) {
  const rows = Array.isArray(results) ? results : [results];
  const failed = rows.filter((row) => row?.stage === 'fresh-agent' && row.caseId === c?.id && row.pass === false
    && ['missing-doc', 'missing-guard'].includes(row.class));
  if (!failed.length) return null;
  const gapClass = failed[0].class;
  if (failed.some((row) => row.class !== gapClass)) throw new Error(`fresh-agent issue mixes gap classes for ${c.id}`);
  const remediation = c.remediation;
  const detail = gapClass === 'missing-doc' ? remediation?.doc : remediation?.guard;
  if (gapClass === 'missing-doc' && (!nonEmpty(detail?.path) || !nonEmpty(detail?.line))) {
    throw new Error(`fresh-agent case ${c.id} needs a documentation remediation`);
  }
  if (gapClass === 'missing-guard' && !nonEmpty(detail)) throw new Error(`fresh-agent case ${c.id} needs a guard remediation`);
  const issueClass = `fresh-agent-${c.id}-${gapClass}`;
  if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(issueClass)) throw new Error(`fresh-agent issue class is invalid: ${issueClass}`);
  const runs = failed.map((row) => `- Run ${row.run}: \`${row.first_divergence ?? 'unknown'}\``).join('\n');
  const change = gapClass === 'missing-doc'
    ? `Doc file: \`${detail.path}\`\nLine to add: \`${detail.line}\``
    : `Rule to enforce: \`${detail}\``;
  return {
    class: issueClass,
    title: `Fresh-agent ${gapClass === 'missing-doc' ? 'missing doc' : 'missing guard'}: ${c.id}`,
    body: [
      `Fresh-agent case \`${c.id}\` failed with classification \`${gapClass}\`.`,
      `Source: ${c.source_url ?? 'not recorded'}\nTask: ${c.prompt}`,
      `First divergence:\n${runs}`,
      `## Repo change to make\n${change}`,
    ].join('\n\n'),
  };
}

export function buildFreshAgentGapIssues(results, cases) {
  const casesById = new Map(cases.map((c) => [c.id, c]));
  const grouped = new Map();
  for (const row of results) {
    if (row.stage !== 'fresh-agent' || row.pass || !['missing-doc', 'missing-guard'].includes(row.class)) continue;
    const key = `${row.caseId}/${row.class}`;
    grouped.set(key, [...(grouped.get(key) ?? []), row]);
  }
  return [...grouped.values()].map((rows) => {
    const c = casesById.get(rows[0].caseId);
    if (!c) throw new Error(`fresh-agent case is missing for result: ${rows[0].caseId}`);
    return buildFreshAgentGapIssue(c, rows);
  });
}
