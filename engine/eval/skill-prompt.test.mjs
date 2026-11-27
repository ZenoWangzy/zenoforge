import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { renderPrompt } from './run-eval.mjs';

test('paired eval names target config skills before migration skills and uses target review skill content', () => {
  const productRoot = mkdtempSync(join(tmpdir(), 'zf-eval-skill-'));
  const candidate = { baseSha: 'a'.repeat(40), phase: 3, issue: { number: 1495, title: 'candidate', body: '' } };
  try {
    mkdirSync(join(productRoot, '.zenoforge/skills/tdd'), { recursive: true });
    mkdirSync(join(productRoot, '.agents/skills/tdd'), { recursive: true });
    mkdirSync(join(productRoot, '.zenoforge/skills/code-review'), { recursive: true });
    mkdirSync(join(productRoot, '.agents/skills/code-review'), { recursive: true });
    writeFileSync(join(productRoot, '.zenoforge/skills/tdd/SKILL.md'), 'candidate config tdd');
    writeFileSync(join(productRoot, '.agents/skills/tdd/SKILL.md'), 'migration tdd');
    writeFileSync(join(productRoot, '.zenoforge/skills/code-review/SKILL.md'), 'candidate config review');
    writeFileSync(join(productRoot, '.agents/skills/code-review/SKILL.md'), 'migration review');

    const implement = renderPrompt('implement', candidate, { productRoot });
    assert.ok(implement.includes(`tdd=${join(productRoot, '.zenoforge/skills/tdd/SKILL.md')}`));
    assert.ok(!implement.includes(`tdd=${join(productRoot, '.agents/skills/tdd/SKILL.md')}`));
    assert.ok(renderPrompt('review', candidate, { productRoot }).startsWith('candidate config review\n'));

    rmSync(join(productRoot, '.zenoforge/skills/tdd/SKILL.md'));
    assert.ok(renderPrompt('implement', candidate, { productRoot }).includes(`tdd=${join(productRoot, '.agents/skills/tdd/SKILL.md')}`));
  } finally {
    rmSync(productRoot, { recursive: true, force: true });
  }
});

test('root AGENTS.override.md changes select the paired product stages', () => {
  const stages = execFileSync('bash', [fileURLToPath(new URL('./decision-stages.sh', import.meta.url))], {
    input: 'AGENTS.override.md\n', encoding: 'utf8',
  }).trim().split(' ');
  assert.deepEqual(stages, ['triage', 'advisor', 'implement', 'review', 'supervisor', 'end-to-end']);
});
