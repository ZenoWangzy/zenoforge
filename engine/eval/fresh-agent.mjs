// Pure grader for fresh-agent runs: no model, no network, no session memory.
// The runner records facts per step; this module only reads them.

const SHA = /^[0-9a-f]{40}$/;
const CASE_KEYS = ['id', 'base_sha', 'prompt', 'hidden_check', 'expected_divergence'];
const nonEmpty = (v) => typeof v === 'string' && v.trim().length > 0;

// Returns the list of problems; an empty list means the case is valid.
// Unknown keys are rejected so a case cannot smuggle in memory or session context.
export function validateFreshCase(c) {
  if (!c || typeof c !== 'object' || Array.isArray(c)) return ['case must be an object'];
  const failures = Object.keys(c).filter((k) => !CASE_KEYS.includes(k)).map((k) => `unknown key: ${k}`);
  if (!nonEmpty(c.id)) failures.push('id: required');
  if (!SHA.test(c.base_sha ?? '')) failures.push('base_sha: expected a 40-char lowercase frozen commit SHA');
  if (!nonEmpty(c.prompt)) failures.push('prompt: required');
  if (!nonEmpty(c.hidden_check)) failures.push('hidden_check: required');
  if (!nonEmpty(c.expected_divergence)) failures.push('expected_divergence: required step id');
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
