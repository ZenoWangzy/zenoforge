import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { buildLessonEnforcers } from './generate-lesson-enforcers.mjs';

function write(root, relativePath, content) {
  const absolute = path.join(root, relativePath);
  mkdirSync(path.dirname(absolute), { recursive: true });
  writeFileSync(absolute, content);
}

test('maps rules to behavioral, existence, weak, and prose enforcement from a small repository', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'zf-lesson-enforcers-'));
  try {
    write(root, 'lessons/RULES.md', [
      '**V90001** source-only rule',
      '**V90002** behavior-checked rule',
      '**V90003** existence-only rule',
      '**V90004** prose-only rule',
      '**V90004** duplicate prose-only rule ID',
      '### **V90006** heading-form rule with a bash test guard',
      '**V90007** unittest-discover rule',
      '**V90008** dot-directory test path rule',
      '**V90009** enforced_by rule',
      '<a id="v90010"></a> **V90010** html-anchor rule',
      '**V90011** missing explicit test file rule',
      '',
    ].join('\n'));
    write(root, 'scripts/check.mjs', '// V90001\n');
    write(root, 'scripts/behavior.test.mjs', '// V90002\nassert.equal(run(), "accepted");\n');
    write(root, 'scripts/exists.test.sh', 'test -f lessons/full/old-incident.md\n');
    write(root, 'scripts/night-guard.test.sh', 'test -f lessons/RULES.md\n');
    write(root, 'scripts/anchor-guard.test.sh', 'test -f lessons/RULES.md\n');
    write(root, 'packages/hooks/tests/test_receipt_wording.py', 'def test_wording():\n    assert True\n');
    write(root, '.agents/skills/fake-advisor/ask.test.cjs', '// V90008\n');
    write(root, 'packages/gateway/src/routes/team-admin.test.ts', '// V90009\n');
    write(root, 'lessons/full/old-incident.md', 'An earlier incident for V90003.\n');
    write(root, 'engine/state/incident-guards.json', `${JSON.stringify({ incidents: [
      {
        id: 'behavior-incident',
        lesson_id: 'V90002',
        machine_checks: [{
          command: ['node', '${REPO_DIR}/scripts/behavior.test.mjs'],
          why: 'The behavior fixture exercises the affected seam.',
        }],
      },
      {
        id: 'presence-incident',
        lesson_id: 'V90003',
        machine_checks: [{
          command: ['test', '-f', 'lessons/full/old-incident.md'],
          why: 'Keep the incident file available.',
        }],
      },
      {
        id: 'heading-incident',
        lesson_id: 'V90006',
        machine_checks: [{
          command: ['bash', '${REPO_DIR}/scripts/night-guard.test.sh'],
          test_file: 'scripts/night-guard.test.sh',
          why: 'Bash guard for a rule written as a section heading.',
        }],
      },
      {
        id: 'discover-incident',
        lesson_id: 'V90007',
        machine_checks: [{
          command: [
            'python3', '-m', 'unittest', 'discover',
            '-s', '${REPO_DIR}/packages/hooks/tests',
            '-p', 'test_receipt_wording.py',
          ],
          why: 'Behavior fixture selected by unittest discover.',
        }],
      },
      {
        id: 'dot-path-incident',
        lesson_id: 'V90008',
        machine_checks: [{
          command: ['node', '--test', '${REPO_DIR}/.agents/skills/fake-advisor/ask.test.cjs'],
          why: 'Behavior fixture at a dot-directory path.',
        }],
      },
      {
        id: 'enforced-by-incident',
        lesson_id: 'V90009',
        machine_checks: [{
          command: ['pnpm', '--filter', 'gateway', 'test', '--', 'team-admin'],
          why: 'Package-suite selection whose concrete files the enforcement block names.',
        }],
        enforcement: {
          level: 'test',
          enforced_by: ['packages/gateway/src/routes/team-admin.test.ts'],
        },
      },
      {
        id: 'anchor-incident',
        lesson_id: 'V90010',
        machine_checks: [{
          command: ['bash', '${REPO_DIR}/scripts/anchor-guard.test.sh'],
          test_file: 'scripts/anchor-guard.test.sh',
          why: 'Bash guard for a rule behind an HTML anchor.',
        }],
      },
      {
        id: 'missing-test-file-incident',
        lesson_id: 'V90011',
        machine_checks: [{
          command: ['bash', '${REPO_DIR}/scripts/missing-guard.test.sh'],
          test_file: 'scripts/missing-guard.test.sh',
          why: 'The referenced regression test is absent.',
        }],
      },
    ] }, null, 2)}\n`);

    execFileSync('git', ['init', '-q', root]);
    execFileSync('git', ['-C', root, 'add', '.']);

    const map = buildLessonEnforcers(root);

    assert.deepEqual(map.counts, {
      enforced: 6,
      weak: 2,
      'existence-check': 1,
      prose: 1,
    });
    assert.equal(map.rule_entries, 11);
    assert.equal(map.unique_rule_ids, 10);
    assert.deepEqual(map.duplicate_rule_ids, { V90004: 2 });
    assert.equal(map.rules.V90001.enforcer, 'prose');
    assert.deepEqual(map.rules.V90001.source_refs, ['scripts/check.mjs']);
    assert.equal(map.rules.V90001.classification, 'weak');
    assert.deepEqual(map.rules.V90002.enforcer, ['scripts/behavior.test.mjs']);
    assert.equal(map.rules.V90002.classification, 'enforced');
    assert.deepEqual(map.rules.V90006.enforcer, ['scripts/night-guard.test.sh']);
    assert.equal(map.rules.V90006.classification, 'enforced');
    assert.deepEqual(map.rules.V90006.incident_refs, ['heading-incident']);
    assert.deepEqual(map.rules.V90007.enforcer, ['packages/hooks/tests/test_receipt_wording.py']);
    assert.equal(map.rules.V90007.classification, 'enforced');
    assert.deepEqual(map.rules.V90008.enforcer, ['.agents/skills/fake-advisor/ask.test.cjs']);
    assert.equal(map.rules.V90008.classification, 'enforced');
    assert.deepEqual(map.rules.V90009.enforcer, ['packages/gateway/src/routes/team-admin.test.ts']);
    assert.equal(map.rules.V90009.classification, 'enforced');
    assert.equal(map.rules.V90010.classification, 'enforced');
    assert.equal(map.rules.V90003.classification, 'existence-check');
    assert.equal(map.rules.V90003.enforcer, 'prose');
    assert.deepEqual(map.rules.V90003.incident_refs, ['presence-incident']);
    assert.equal(map.rules.V90004.enforcer, 'prose');
    assert.equal(map.rules.V90011.classification, 'weak');
    assert.equal(map.rules.V90011.enforcer, 'prose');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
