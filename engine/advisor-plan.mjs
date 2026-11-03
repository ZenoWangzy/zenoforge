import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const schemaPath = join(dirname(fileURLToPath(import.meta.url)), 'prompts/advisor.schema.json');
const schema = JSON.parse(readFileSync(schemaPath, 'utf8'));
const planSchema = schema.properties?.plan;
const verdictSchema = schema.properties?.verdict;
const planRule = schema.allOf?.find((rule) => rule.if?.properties?.verdict);
const closeVerdicts = new Set(planRule?.if?.properties?.verdict?.enum ?? []);

function matchesSchema(value, shape) {
  if (shape.type === 'object') {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
    if ((shape.required ?? []).some((key) => !Object.hasOwn(value, key))) return false;
    if (shape.additionalProperties === false) {
      const allowed = new Set(Object.keys(shape.properties ?? {}));
      if (Object.keys(value).some((key) => !allowed.has(key))) return false;
    }
    return Object.entries(shape.properties ?? {}).every(([key, propertySchema]) =>
      !Object.hasOwn(value, key) || matchesSchema(value[key], propertySchema));
  }

  if (shape.type === 'array') {
    return Array.isArray(value)
      && value.length >= (shape.minItems ?? 0)
      && value.every((item) => matchesSchema(item, shape.items ?? {}));
  }

  if (shape.type === 'string') {
    return typeof value === 'string'
      && value.length >= (shape.minLength ?? 0)
      && (shape.pattern === undefined || new RegExp(shape.pattern).test(value))
      && (shape.enum === undefined || shape.enum.includes(value));
  }

  return true;
}

/**
 * Decide whether a parsed ruling can proceed, needs its one corrective ask,
 * or must be recorded as an advisor failure. The JSON schema remains the
 * contract; this check enforces the same plan rule at the result boundary.
 */
export function advisorPlanAction(ruling, reasked = false) {
  if (ruling === null || typeof ruling !== 'object' || Array.isArray(ruling)) return 'not-applicable';
  if (!verdictSchema?.enum?.includes(ruling.verdict)) return 'not-applicable';
  if (closeVerdicts.has(ruling.verdict)) return 'valid';
  if (!planSchema || !matchesSchema(ruling.plan, planSchema)) return reasked ? 'failure' : 'reask';
  return 'valid';
}

const planSectionStart = '<!-- advisor-plan:start -->';
const planSectionEnd = '<!-- advisor-plan:end -->';
const existingPlanSection = new RegExp(
  `(?:\\n\\s*)?${planSectionStart}[\\s\\S]*?${planSectionEnd}`,
  'g',
);

/** Append the original plan object as JSON, preserving all field values. */
export function advisorPlanBrief(brief, plan) {
  const base = String(brief ?? '').replace(existingPlanSection, '').trimEnd();
  const section = [
    planSectionStart,
    '## Advisor plan (verbatim JSON)',
    JSON.stringify(plan),
    planSectionEnd,
  ].join('\n');
  return base ? `${base}\n\n${section}` : section;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const command = process.argv[2];
  const input = JSON.parse(readFileSync(0, 'utf8'));
  if (command === 'action') {
    process.stdout.write(`${advisorPlanAction(input.ruling, input.reasked === true)}\n`);
  } else if (command === 'brief') {
    process.stdout.write(`${advisorPlanBrief(input.brief, input.plan)}\n`);
  } else {
    process.stderr.write('advisor-plan.mjs: expected action or brief\n');
    process.exitCode = 2;
  }
}
