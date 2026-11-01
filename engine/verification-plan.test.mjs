import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import { buildVerificationPlan, DEFAULT_MAP, DEFAULT_ROOT, loadFeatureMap, validateFeatureMap } from './verification-plan.mjs';

function fixture() {
  const root = mkdtempSync(path.join(tmpdir(), 'zf-verification-plan-'));
  for (const ref of [
    'src/login.ts',
    'tests/login.test.ts',
    'ci.yml',
    'release.mjs',
    'src/chat/index.ts',
    'tests/chat.test.ts',
  ]) {
    mkdirSync(path.dirname(path.join(root, ref)), { recursive: true });
    writeFileSync(path.join(root, ref), '');
  }
  const map = {
    version: 1,
    features: [
      {
        id: 'login',
        title: 'Login',
        surfaces: ['Admin Console'],
        path_prefixes: ['src/login.ts'],
        entrypoints: ['src/login.ts'],
        invariants: ['session stays authenticated'],
        proofs: {
          owner: ['tests/login.test.ts'],
          wrapper: ['tests/login.test.ts'],
          ci: ['ci.yml'],
          review: ['review session semantics'],
          release: ['release.mjs'],
        },
      },
      {
        id: 'chat',
        title: 'Chat',
        surfaces: ['Web /chat/'],
        path_prefixes: ['src/chat'],
        entrypoints: ['src/chat/index.ts'],
        invariants: ['response is observable'],
        proofs: {
          owner: ['tests/chat.test.ts'],
          wrapper: ['tests/chat.test.ts'],
          ci: ['ci.yml'],
          review: ['review turn semantics'],
          release: ['release.mjs'],
        },
      },
    ],
  };
  return { root, map };
}

test('maps changed paths and proof ownership without hiding unmapped paths', () => {
  const { root, map } = fixture();
  const plan = buildVerificationPlan(map, {
    root,
    changedPaths: ['src/login.ts', 'src/unknown.ts'],
  });
  assert.deepEqual(plan.matched_features, ['login']);
  assert.deepEqual(plan.owner_proofs, ['tests/login.test.ts']);
  assert.ok(plan.review_invariants.includes('session stays authenticated'));
  assert.deepEqual(plan.unmapped_paths, ['src/unknown.ts']);
});

test('reads code surfaces and proofs from the catalog entries themselves', () => {
  const { root } = fixture();
  mkdirSync(path.dirname(path.join(root, DEFAULT_MAP)), { recursive: true });
  writeFileSync(path.join(root, DEFAULT_MAP), JSON.stringify({ features: [
    { id: 'login', name: 'Login', verification: { paths: ['src/login.ts'], owner: ['tests/login.test.ts'] } },
    { id: 'plain', name: 'Plain' },
  ] }));
  const plan = buildVerificationPlan(loadFeatureMap(root), { root, changedPaths: ['src/login.ts', 'src/chat/index.ts'] });
  assert.deepEqual(plan.matched_features, ['login']);
  assert.deepEqual(plan.owner_proofs, ['tests/login.test.ts']);
  assert.deepEqual(plan.unmapped_paths, ['src/chat/index.ts']);
});

test('uses expected paths and entry surface as advisory intent evidence', () => {
  const { root, map } = fixture();
  const plan = buildVerificationPlan(map, {
    root,
    expectedPaths: ['src/chat/index.ts'],
    entrySurface: 'Web /chat/',
  });
  assert.deepEqual(plan.matched_features, ['chat']);
  assert.deepEqual(plan.matched_by.chat.expected_paths, ['src/chat/index.ts']);
  assert.equal(plan.matched_by.chat.entry_surface, 'Web /chat/');
});

test('rejects duplicate feature ids', () => {
  const { root, map } = fixture();
  map.features.push(structuredClone(map.features[0]));
  assert.throws(() => validateFeatureMap(map, root), /duplicate feature id: login/);
});

test('rejects broken proof references', () => {
  const { root, map } = fixture();
  map.features[0].proofs.owner = ['tests/missing.test.ts'];
  assert.throws(() => validateFeatureMap(map, root), /does not exist/);
});

test('rejects malformed maps', () => {
  const { root } = fixture();
  assert.throws(() => validateFeatureMap({ version: 2, features: [] }, root), /version 1/);
});

test('the config root feature map wins over a retained pack copy', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'zf-verification-plan-config-'));
  const put = (ref) => {
    mkdirSync(path.dirname(path.join(root, ref)), { recursive: true });
    writeFileSync(path.join(root, ref), '');
  };
  for (const ref of ['src/login.ts', 'tests/login.test.ts', 'release.mjs', 'tests/owner-config.ts', 'tests/owner-pack.ts']) put(ref);
  put('scripts/e2e/yangfeng-regression/catalog.json');
  writeFileSync(path.join(root, 'scripts/e2e/yangfeng-regression/catalog.json'), JSON.stringify({
    features: [{
      id: 'login',
      name: 'Login',
      verification: {
        surfaces: ['Admin Console'],
        paths: ['src/login.ts'],
        owner: ['tests/login.test.ts'],
        release: ['release.mjs'],
      },
    }],
  }));
  const configRoot = path.join(root, '.zenoforge');
  const packDir = path.join(root, 'pack');
  mkdirSync(path.join(configRoot, 'state'), { recursive: true });
  mkdirSync(path.join(packDir, 'state'), { recursive: true });
  writeFileSync(path.join(configRoot, 'state/feature-map.json'), JSON.stringify({
    features: { login: { owner: ['tests/owner-config.ts'] } },
  }));
  writeFileSync(path.join(packDir, 'state/feature-map.json'), JSON.stringify({
    features: { login: { owner: ['tests/owner-pack.ts'] } },
  }));
  const code = `import(${JSON.stringify(new URL('./verification-plan.mjs', import.meta.url).href)})
    .then(({ loadFeatureMap, buildVerificationPlan }) => {
      const plan = buildVerificationPlan(loadFeatureMap(${JSON.stringify(root)}), {
        root: ${JSON.stringify(root)}, changedPaths: ['src/login.ts'],
      });
      console.log(JSON.stringify(plan.owner_proofs));
    })`;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', code], {
    encoding: 'utf8',
    env: { ...process.env, ZF_CONFIG_ROOT: configRoot, ZF_PACK_DIR: packDir },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ['tests/owner-config.ts']);
});
