#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readPackJson } from './pack-dir.mjs';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
export const DEFAULT_ROOT = path.resolve(path.dirname(SCRIPT_PATH), '..');
export const DEFAULT_MAP = 'scripts/e2e/yangfeng-regression/catalog.json';
const PROOF_PATH_STAGES = ['owner', 'wrapper', 'ci', 'release'];

// The catalog owns feature IDs. A catalog entry may carry a `verification`
// object ({ paths, owner, release, surfaces, invariants }) that associates its
// code surfaces and proofs. A pack may add the same for features whose catalog
// entry says nothing: state/feature-map.json ({ release, surfaces, features }),
// which wins over the catalog entry. With neither, a feature has no proofs.
const PACK_FEATURE_MAP = readPackJson('state/feature-map.json') ?? {};
const packSurfaces = (caseFeature) => (PACK_FEATURE_MAP.surfaces ?? []).find((rule) =>
  (!rule.kind || rule.kind === caseFeature.kind) && (!rule.pathPrefix || caseFeature.path?.startsWith(rule.pathPrefix)))?.surfaces;

const emptyProofs = () => ({ owner: [], wrapper: [], ci: [], review: [], release: [] });

function catalogFeatureMap(catalog) {
  if (!catalog || !Array.isArray(catalog.features)) throw new Error('Acceptance catalog must contain a features array');
  return {
    version: 1,
    features: catalog.features.map((caseFeature) => {
      const metadata = { ...(caseFeature.verification ?? {}), ...(PACK_FEATURE_MAP.features?.[caseFeature.id] ?? {}) };
      const proofs = emptyProofs();
      proofs.owner = metadata.owner ?? [];
      proofs.release = metadata.release ?? PACK_FEATURE_MAP.release ?? [];
      return {
        id: caseFeature.id,
        title: caseFeature.name,
        surfaces: metadata.surfaces ?? packSurfaces(caseFeature) ?? [],
        path_prefixes: metadata.paths ?? [],
        entrypoints: metadata.paths ?? [],
        invariants: metadata.invariants ?? [],
        proofs,
      };
    }),
  };
}

function stringArray(value, label) {
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string' || item.length === 0)) {
    throw new Error(`${label} must be a non-empty-string array`);
  }
  return value;
}

function featureList(map) {
  if (!map || map.version !== 1 || !Array.isArray(map.features)) {
    throw new Error('feature map must be version 1 with a features array');
  }
  const seen = new Set();
  for (const [index, feature] of map.features.entries()) {
    const prefix = `features[${index}]`;
    if (!feature || typeof feature !== 'object') throw new Error(`${prefix} must be an object`);
    if (typeof feature.id !== 'string' || !feature.id) throw new Error(`${prefix}.id is required`);
    if (seen.has(feature.id)) throw new Error(`duplicate feature id: ${feature.id}`);
    seen.add(feature.id);
    if (typeof feature.title !== 'string' || !feature.title) throw new Error(`${feature.id}.title is required`);
    stringArray(feature.surfaces, `${feature.id}.surfaces`);
    stringArray(feature.path_prefixes, `${feature.id}.path_prefixes`);
    stringArray(feature.entrypoints, `${feature.id}.entrypoints`);
    stringArray(feature.invariants, `${feature.id}.invariants`);
    if (!feature.proofs || typeof feature.proofs !== 'object') throw new Error(`${feature.id}.proofs is required`);
    for (const stage of [...PROOF_PATH_STAGES, 'review']) {
      stringArray(feature.proofs[stage], `${feature.id}.proofs.${stage}`);
    }
  }
  return map.features;
}

function assertRepoPath(root, ref, label) {
  if (path.isAbsolute(ref) || ref.includes('..')) throw new Error(`${label} must stay inside the repo: ${ref}`);
  if (!existsSync(path.join(root, ref))) throw new Error(`${label} does not exist: ${ref}`);
}

export function validateFeatureMap(map, root = DEFAULT_ROOT) {
  const features = featureList(map);
  for (const feature of features) {
    for (const ref of feature.entrypoints) assertRepoPath(root, ref, `${feature.id}.entrypoint`);
    for (const stage of PROOF_PATH_STAGES) {
      for (const ref of feature.proofs[stage]) assertRepoPath(root, ref, `${feature.id}.proofs.${stage}`);
    }
    for (const prefix of feature.path_prefixes) {
      assertRepoPath(root, prefix, `${feature.id}.path_prefix`);
    }
  }
  return features;
}

export function loadFeatureMap(root = DEFAULT_ROOT, mapPath = DEFAULT_MAP) {
  const absolute = path.resolve(root, mapPath);
  if (!absolute.startsWith(path.resolve(root) + path.sep)) throw new Error('feature map must stay inside the repo');
  const parsed = JSON.parse(readFileSync(absolute, 'utf8'));
  const map = mapPath === DEFAULT_MAP ? catalogFeatureMap(parsed) : parsed;
  validateFeatureMap(map, root);
  return map;
}

function pathMatches(changedPath, prefix) {
  return changedPath === prefix || changedPath.startsWith(prefix.endsWith('/') ? prefix : `${prefix}/`);
}

function unique(values) {
  return [...new Set(values)];
}

function gitChangedPaths(root, base, head) {
  if (!base || !head) throw new Error('--base and --head are required when --changed-path is not supplied');
  const output = execFileSync('git', ['diff', '--name-only', `${base}...${head}`], {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return output.split(/\r?\n/).filter(Boolean);
}

export function buildVerificationPlan(map, {
  root = DEFAULT_ROOT,
  changedPaths = [],
  expectedPaths = [],
  entrySurface = '',
} = {}) {
  const features = validateFeatureMap(map, root);
  const candidates = unique([...changedPaths, ...expectedPaths]);
  const matches = [];
  const matchedChanged = new Set();

  for (const feature of features) {
    const changed = changedPaths.filter((candidate) => feature.path_prefixes.some((prefix) => pathMatches(candidate, prefix)));
    const expected = expectedPaths.filter((candidate) => feature.path_prefixes.some((prefix) => pathMatches(candidate, prefix)));
    if (changed.length === 0 && expected.length === 0) continue;
    const surface = entrySurface && feature.surfaces.includes(entrySurface);
    changed.forEach((item) => matchedChanged.add(item));
    matches.push({
      id: feature.id,
      title: feature.title,
      matched_by: {
        changed_paths: changed,
        expected_paths: expected,
        entry_surface: surface ? entrySurface : null,
      },
      invariants: feature.invariants,
      proofs: feature.proofs,
    });
  }

  const flatten = (stage) => unique(matches.flatMap((item) => item.proofs[stage] ?? []));
  return {
    map_version: map.version,
    matched_features: matches.map((item) => item.id),
    matched_by: Object.fromEntries(matches.map((item) => [item.id, item.matched_by])),
    owner_proofs: flatten('owner'),
    wrapper_proofs: flatten('wrapper'),
    ci_proofs: flatten('ci'),
    review_invariants: unique(matches.flatMap((item) => item.invariants).concat(flatten('review'))),
    release_proofs: flatten('release'),
    unmapped_paths: changedPaths.filter((item) => !matchedChanged.has(item)),
    input: {
      changed_paths: changedPaths,
      expected_paths: expectedPaths,
      entry_surface: entrySurface || null,
      candidate_count: candidates.length,
    },
  };
}

function parseArgs(argv) {
  const args = { changedPaths: [], expectedPaths: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    const next = () => {
      const value = argv[++i];
      if (!value) throw new Error(`missing value for ${token}`);
      return value;
    };
    if (token === '--root') args.root = next();
    else if (token === '--map') args.mapPath = next();
    else if (token === '--base') args.base = next();
    else if (token === '--head') args.head = next();
    else if (token === '--entry-surface') args.entrySurface = next();
    else if (token === '--expected-path') args.expectedPaths.push(next());
    else if (token === '--changed-path') args.changedPaths.push(next());
    else throw new Error(`unknown argument: ${token}`);
  }
  return args;
}

export function runCli(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const root = path.resolve(args.root ?? DEFAULT_ROOT);
  const map = loadFeatureMap(root, args.mapPath ?? DEFAULT_MAP);
  if ((args.base && !args.head) || (!args.base && args.head)) {
    throw new Error('--base and --head must be supplied together');
  }
  const changedPaths = args.changedPaths.length > 0
    ? args.changedPaths
    : (args.base && args.head ? gitChangedPaths(root, args.base, args.head) : []);
  const plan = buildVerificationPlan(map, {
    root,
    changedPaths,
    expectedPaths: args.expectedPaths,
    entrySurface: args.entrySurface ?? '',
  });
  process.stdout.write(`${JSON.stringify(plan)}\n`);
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(SCRIPT_PATH)) {
  try {
    runCli();
  } catch (error) {
    console.error(`verification-plan: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}
