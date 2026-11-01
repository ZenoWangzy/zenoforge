import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { buildMaintenanceReport } from './verification-map-audit.mjs';

function fixture() {
  const root = mkdtempSync(path.join(tmpdir(), 'zf-map-audit-'));
  const refs = [
    'packages/app/src/login.ts',
    'packages/app/tests/login.test.ts',
    'ci.yml',
    'release.mjs',
  ];
  for (const ref of refs) {
    mkdirSync(path.dirname(path.join(root, ref)), { recursive: true });
    writeFileSync(path.join(root, ref), '');
  }
  mkdirSync(path.join(root, 'docs/verification'), { recursive: true });
  writeFileSync(path.join(root, 'docs/verification/features.json'), JSON.stringify({
    version: 1,
    features: [{
      id: 'login',
      title: 'Login',
      surfaces: ['Admin Console'],
      path_prefixes: ['packages/app/src/login.ts'],
      entrypoints: ['packages/app/src/login.ts'],
      invariants: ['session remains valid'],
      proofs: {
        owner: ['packages/app/tests/login.test.ts'],
        wrapper: ['packages/app/tests/login.test.ts'],
        ci: ['ci.yml'],
        review: ['review session'],
        release: ['release.mjs'],
      },
    }],
  }));
  return root;
}

test('reports mapped and unmapped user-surface churn without treating tests as product paths', () => {
  const root = fixture();
  const report = buildMaintenanceReport({
    root,
    mapPath: 'docs/verification/features.json',
    changedPaths: [
      'packages/app/src/login.ts',
      'packages/app/src/new-screen.ts',
      'packages/app/tests/login.test.ts',
    ],
  });
  assert.equal(report.candidate_user_surface_paths, 2);
  assert.equal(report.mapped_user_surface_paths, 1);
  assert.equal(report.mapping_coverage_ratio, 0.5);
  assert.deepEqual(report.unmapped_candidate_paths, ['packages/app/src/new-screen.ts']);
});

test('aggregates exact-head planner evidence from existing issue state', () => {
  const root = fixture();
  const stateDir = path.join(root, 'state');
  mkdirSync(stateDir);
  writeFileSync(path.join(stateDir, '1.json'), JSON.stringify({
    run: { evidence: { verification_plan: {
      status: 'available',
      matched_features: ['login'],
      unmapped_paths: [],
    } } },
  }));
  writeFileSync(path.join(stateDir, '2.json'), JSON.stringify({
    run: { evidence: { verification_plan: {
      status: 'unavailable',
      matched_features: [],
      unmapped_paths: ['packages/app/src/new-screen.ts'],
    } } },
  }));
  const report = buildMaintenanceReport({ root, mapPath: 'docs/verification/features.json', stateDir });
  assert.equal(report.state_evidence.planned, 2);
  assert.equal(report.state_evidence.available, 1);
  assert.equal(report.state_evidence.unavailable, 1);
  assert.equal(report.state_evidence.with_unmapped_paths, 1);
  assert.equal(report.state_evidence.feature_counts.login, 1);
});

test('the config root surface prefixes win over a retained pack copy', () => {
  const root = fixture();
  const configRoot = path.join(root, '.zenoforge');
  const packDir = path.join(root, 'pack');
  mkdirSync(path.join(configRoot, 'state'), { recursive: true });
  mkdirSync(path.join(packDir, 'state'), { recursive: true });
  writeFileSync(path.join(configRoot, 'state/user-surface-paths.json'), JSON.stringify({
    prefixes: ['docs/config-surface'],
  }));
  writeFileSync(path.join(packDir, 'state/user-surface-paths.json'), JSON.stringify({
    prefixes: ['docs/pack-surface'],
  }));
  const script = fileURLToPath(new URL('./verification-map-audit.mjs', import.meta.url));
  const result = spawnSync(process.execPath, [
    script, '--root', root, '--map', 'docs/verification/features.json',
    '--changed-path', 'docs/config-surface/guide.md', '--changed-path', 'docs/pack-surface/notes.md',
  ], {
    encoding: 'utf8',
    env: { ...process.env, ZF_CONFIG_ROOT: configRoot, ZF_PACK_DIR: packDir },
  });
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.deepEqual(report.unmapped_candidate_paths, ['docs/config-surface/guide.md']);
});
