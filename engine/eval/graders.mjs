import { readFileSync } from 'node:fs';
import { zfConfigFile } from '../pack-dir.mjs';

// Case expectations are independent historical evidence, never model scores.
const result = (failures) => ({ pass: failures.length === 0, failures });
const canonical = (value) => JSON.stringify(value, (_, v) => Array.isArray(v) ? [...new Set(v)].sort() : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => a.localeCompare(b))) : v);
function gradeExternalDeliverable(actual, expected) {
  if (!expected.required) {
    return canonical(actual) === canonical(expected) ? [] : [
      'external_deliverable: expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual),
    ];
  }
  const failures = [];
  if (actual?.required !== true) failures.push('external_deliverable.required: expected true');
  const location = typeof actual?.location === 'string' ? actual.location : '';
  const reason = typeof actual?.reason === 'string' ? actual.reason : '';
  if (!location.trim()) failures.push('external_deliverable.location: required external target is missing');
  const expectedPath = expected.location.match(/(?:~\/|\/)[^\s,，;；]+/)?.[0];
  if (expectedPath && !location.includes(expectedPath)) {
    failures.push('external_deliverable.location: expected target ' + expectedPath);
  }
  if (!reason.trim()) failures.push('external_deliverable.reason: required external-work reason is missing');
  return failures;
}
export function gradeTriage(actual, expected) {
  if (Object.hasOwn(expected, 'external_deliverable')) {
    const { external_deliverable: externalExpected, ...otherExpected } = expected;
    const failures = Object.entries(otherExpected).filter(([key, value]) => canonical(actual?.[key]) !== canonical(value))
      .map(([key, value]) => key + ': expected ' + JSON.stringify(value) + ', got ' + JSON.stringify(actual?.[key]));
    return result([...failures, ...gradeExternalDeliverable(actual?.external_deliverable, externalExpected)]);
  }
  return result(Object.entries(expected).filter(([key, value]) => canonical(actual?.[key]) !== canonical(value))
    .map(([key, value]) => `${key}: expected ${JSON.stringify(value)}, got ${JSON.stringify(actual?.[key])}`));
}
export function gradeAdvisor(actual, expected) {
  const text = Object.values(actual ?? {}).filter((v) => typeof v === 'string').join('\n').normalize('NFKC').toLowerCase();
  const failures = (expected.rubric ?? []).filter((item) => !item.any.some((s) => text.includes(s.normalize('NFKC').toLowerCase())))
    .map((item) => `missing decision: ${item.fact}`);
  for (const phrase of expected.forbidden ?? []) if (text.includes(phrase.toLowerCase())) failures.push(`contradiction: ${phrase}`);
  if (expected.verdict && actual?.verdict !== expected.verdict) failures.push(`verdict: expected ${expected.verdict}`);
  return result(failures);
}
function reviewFindingsBlock(text) {
  const blocks = [...String(text).matchAll(/(?:^|\n)```review-findings[ \t]*\r?\n([\s\S]*?)\r?\n```[ \t]*(?=\n|$)/g)];
  if (!blocks.length) return { error: 'missing review-findings block' };
  let value;
  try { value = JSON.parse(blocks.at(-1)[1]); } catch { return { error: 'invalid review-findings JSON' }; }
  if (Array.isArray(value)) return { legacy: true, findings: value, dispositions: [] };
  const keys = (object) => Object.keys(object ?? {}).sort().join(',');
  if (!value || typeof value !== 'object' || keys(value) !== 'dispositions,findings'
    || !Array.isArray(value.findings) || !Array.isArray(value.dispositions)) {
    return { error: 'review-findings must contain findings and dispositions arrays' };
  }
  const findingKeys = 'base_evidence,file,id,introduced_by,line,rule,severity,status,summary';
  const findingsValid = value.findings.every((finding) => finding && typeof finding === 'object'
    && keys(Object.fromEntries(Object.entries(finding).filter(([key]) => !key.startsWith('rerun_')))) === findingKeys
    && typeof finding.id === 'string' && finding.id.length > 0
    && ['P0', 'P1', 'P2', 'P3'].includes(finding.severity)
    && typeof finding.file === 'string' && finding.file.length > 0
    && Number.isInteger(finding.line) && finding.line > 0
    && typeof finding.rule === 'string' && finding.rule.length > 0
    && ['open', 'resolved', 'inherited'].includes(finding.status)
    && typeof finding.summary === 'string' && finding.summary.length > 0
    && ['candidate', 'pre_existing', 'unknown'].includes(finding.introduced_by)
    && typeof finding.base_evidence === 'string' && finding.base_evidence.trim().length > 0);
  const dispositionsValid = value.dispositions.every((disposition) => disposition && typeof disposition === 'object'
    && keys(disposition) === 'disposition,id,reason'
    && typeof disposition.id === 'string' && disposition.id.length > 0
    && ['fixed', 'disproved', 'intentional', 'out-of-scope'].includes(disposition.disposition)
    && typeof disposition.reason === 'string' && disposition.reason.trim().length > 0
    && !/[\r\n]/.test(disposition.reason));
  if (!findingsValid || !dispositionsValid) return { error: 'review-findings fields do not match the contract' };
  if (new Set(value.findings.map((finding) => finding.id)).size !== value.findings.length
    || new Set(value.dispositions.map((disposition) => disposition.id)).size !== value.dispositions.length) {
    return { error: 'review-findings IDs must be unique within each array' };
  }
  return value;
}
export function gradeReview(text, expected) {
  const verdicts = [...String(text).matchAll(/^\s*(?:VERDICT:\s*)?(READY|NOT_READY|INPUT_INCOMPLETE|APPROVE|REQUEST-CHANGES|BLOCK)\s*$/gm)]
    .map((m) => ({ APPROVE: 'READY', 'REQUEST-CHANGES': 'NOT_READY', BLOCK: 'INPUT_INCOMPLETE' })[m[1]] ?? m[1]);
  const failures = verdicts.length === 1 && verdicts[0] === expected.verdict ? [] : [`expected one ${expected.verdict} verdict, got ${verdicts.join(',') || 'none'}`];
  const block = reviewFindingsBlock(text);
  if (block.error) failures.push(block.error);
  else if (block.legacy) failures.push('legacy review-findings array has no provenance fields');
  else {
    if (block.dispositions.length) failures.push('reviewer report must leave author dispositions empty');
    const blockers = block.findings.filter((finding) => String(finding.rerun_command ?? '').trim() && String(finding.rerun_output ?? '').trim())
      .filter((finding) => finding.severity === 'P0' || finding.severity === 'P1')
      .filter((finding) => finding.status !== 'resolved' && finding.introduced_by === 'candidate');
    if (expected.verdict === 'READY' && blockers.length) failures.push('READY report contains a candidate P0/P1 finding');
    if (expected.verdict === 'NOT_READY') for (const file of expected.defectFiles ?? []) {
      if (!blockers.some((finding) => finding.file === file)) failures.push(`missing candidate defect finding: ${file}`);
    }
  }
  return result(failures);
}
export function gradeSupervisor(text, expected) {
  // #4369 six-action contract: exactly one standalone ACTION line. The frozen f11 case set labels the
  // human-only exit 'decision'; the shipped prompt calls that same action needs-info.
  const actions = [...String(text).matchAll(/^\s*ACTION:\s*(requeue|approve|park|close|reroute|needs-info)\s*$/gm)].map((match) => match[1]);
  const action = actions.length === 1 ? actions[0] : null;
  const failures = [];
  if (!action) failures.push(`expected one ACTION line, got ${actions.join(',') || 'none'}`);
  else if (action !== expected.action && !(action === 'needs-info' && expected.action === 'decision')) {
    failures.push(`action: expected ${expected.action}, got ${action}`);
  }
  const unsafeApprove = action === 'approve' && expected.knownUnsafeApprove === true;
  if (unsafeApprove) failures.push('approve is unsafe for a unit with known main-red or reverted evidence');
  return { ...result(failures), action, expectedAction: expected.action, unsafeApprove };
}
export function gradeTests(checks) {
  return result(checks.length ? checks.filter((c) => c.exitCode !== 0).map((c) => `hidden check failed: ${c.command ?? 'test'} (${c.exitCode})`) : ['no hidden tests executed']);
}
// Premise-verified optimization tickets decide before implementing: an unreproducible
// claim closes the ticket (the pipeline's OBSOLETE protocol), a reproducible one implements.
export function gradeImplementDecision(report, changedPaths, expected) {
  const text = String(report ?? '');
  const firstLine = text.split(/\r?\n/).map((line) => line.trim()).find((line) => line.length) ?? '';
  const failures = [];
  if (expected.outcome === 'close') {
    if (!/^OBSOLETE:/i.test(firstLine)) failures.push(`expected an OBSOLETE: first line closing the ticket with the measured numbers, got ${JSON.stringify(firstLine.slice(0, 80))}`);
    if (!/\d/.test(text)) failures.push('the close report must carry the measured numbers');
    const implemented = changedPaths.filter((path) => (expected.implementationPrefixes ?? []).some((prefix) => path.startsWith(prefix)));
    if (implemented.length) failures.push(`a ticket whose premise does not reproduce must not be implemented; changed ${implemented.join(', ')}`);
  } else if (expected.outcome === 'implement') {
    if (/^\s*(OBSOLETE|BLOCKED-ON|NEEDS-PR):/i.test(firstLine)) failures.push(`the ticket's numbers reproduce; expected implementation, got the refusal ${JSON.stringify(firstLine.slice(0, 60))}`);
  } else failures.push(`unknown implement outcome ${JSON.stringify(expected.outcome)}`);
  return result(failures);
}

// The pipeline schemas use these JSON Schema primitives; the files own the fields.
export function validateStageOutput(stage, value) {
  const schemaFile = zfConfigFile(`prompts/${stage}.schema.json`);
  if (!schemaFile) throw new Error(`missing schema for stage ${stage}`);
  const schema = JSON.parse(readFileSync(schemaFile, 'utf8'));
  const failures = [];
  function visit(v, s, path) {
    const type = Array.isArray(v) ? 'array' : v === null ? 'null' : typeof v;
    if (s.type && type !== s.type && !(s.type === 'integer' && Number.isInteger(v))) { failures.push(`${path}: expected ${s.type}`); return; }
    if (s.minimum !== undefined && (typeof v !== 'number' || v < s.minimum)) failures.push(`${path}: below minimum ${s.minimum}`);
    if (s.enum && !s.enum.includes(v)) failures.push(`${path}: invalid enum ${v}`);
    if (type === 'object') {
      for (const key of s.required ?? []) if (!Object.hasOwn(v, key)) failures.push(`${path}.${key}: required`);
      for (const [key, field] of Object.entries(v)) {
        if (s.properties?.[key]) visit(field, s.properties[key], `${path}.${key}`);
        else if (s.additionalProperties === false) failures.push(`${path}.${key}: unexpected`);
      }
    }
    if (type === 'array' && s.items) v.forEach((item, i) => visit(item, s.items, `${path}[${i}]`));
  }
  visit(value, schema, stage);
  return failures;
}
