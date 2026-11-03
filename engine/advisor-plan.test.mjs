import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { advisorPlanAction, advisorPlanBrief } from './advisor-plan.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const schema = JSON.parse(readFileSync(join(here, 'prompts/advisor.schema.json'), 'utf8'));

test('advisor schema defines the plan contract and exempts terminal close verdicts', () => {
  const plan = schema.properties?.plan;
  assert.ok(plan, 'advisor schema is missing the plan contract');
  assert.deepEqual(plan.required, ['changes', 'tests_fail_first', 'non_goals']);
  assert.deepEqual(Object.keys(plan.properties), ['changes', 'tests_fail_first', 'non_goals']);
  assert.deepEqual(plan.properties.changes.items.required, ['file', 'symbol', 'change']);

  const conditional = schema.allOf?.find((rule) => rule.if?.properties?.verdict);
  assert.ok(conditional, 'advisor schema must conditionally require plans');
  assert.deepEqual(conditional.if.properties.verdict.enum, ['tracker', 'duplicate']);
  assert.deepEqual(conditional.then.required, undefined);
  assert.ok(conditional.else.required.includes('plan'));
  assert.equal(advisorPlanAction({ verdict: 'tracker' }), 'valid');
  assert.equal(advisorPlanAction({ verdict: 'duplicate' }), 'valid');
  assert.equal(advisorPlanAction({ verdict: 'advised' }), 'reask');
  assert.equal(advisorPlanAction({
    verdict: 'advised',
    plan: {
      changes: [{ file: 'engine/advisor-core.sh', symbol: 'advisor_plan_action', change: 'Validate before apply.' }],
      tests_fail_first: ['node --test engine/advisor-plan.test.mjs'],
      non_goals: ['Do not change provider selection.'],
    },
  }), 'valid');
});

test('a missing or malformed non-close plan gets one re-ask, then becomes an advisor failure', () => {
  const missing = { verdict: 'advised', decision_md: 'Use the existing boundary.' };
  assert.equal(advisorPlanAction(missing), 'reask');
  assert.equal(advisorPlanAction(missing, true), 'failure');

  const incomplete = {
    verdict: 'recut',
    plan: { changes: [], tests_fail_first: ['bash engine/example.test.sh'], non_goals: ['docs'] },
  };
  assert.equal(advisorPlanAction(incomplete), 'reask');
  assert.equal(advisorPlanAction(incomplete, true), 'failure');
});

test('the dispatched worker brief carries the plan object verbatim and replaces an older plan', () => {
  const plan = {
    changes: [{ file: 'engine/worker.sh', symbol: 'dispatch_worker', change: 'Keep the routed plan intact.' }],
    tests_fail_first: ['bash engine/worker.test.sh --case missing-plan'],
    non_goals: ['Do not change the provider tier ladder.'],
  };
  const brief = advisorPlanBrief('Existing issue brief.', plan);
  assert.ok(brief.includes(JSON.stringify(plan)));
  assert.ok(brief.startsWith('Existing issue brief.'));

  const nextPlan = { ...plan, non_goals: ['Do not change provider selection.'] };
  const replaced = advisorPlanBrief(brief, nextPlan);
  assert.equal(replaced.split('<!-- advisor-plan:start -->').length - 1, 1);
  assert.ok(replaced.includes(JSON.stringify(nextPlan)));
  assert.ok(!replaced.includes(JSON.stringify(plan)));
});
