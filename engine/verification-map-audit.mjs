#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { readPackJson } from './pack-dir.mjs';
import { buildVerificationPlan, DEFAULT_MAP, DEFAULT_ROOT, loadFeatureMap } from './verification-plan.mjs';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
// Extra path prefixes a pack counts as user surface: state/user-surface-paths.json ({ prefixes: [...] }); none without a pack.
const PACK_SURFACE_PREFIXES = readPackJson('state/user-surface-paths.json')?.prefixes ?? [];

function gitChangedPaths(root, base, head) {
  if (!base || !head) return [];
  const output = execFileSync('git', ['diff', '--name-only', `${base}...${head}`], {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return output.split(/\r?\n/).filter(Boolean);
}

function isCandidateUserSurface(file) {
  if (/\.(test|spec)\.[^.]+$/.test(file) || /(^|\/)tests?\//.test(file)) return false;
  if (file.startsWith('scripts/e2e/')) return true;
  if (PACK_SURFACE_PREFIXES.some((prefix) => file.startsWith(prefix))) return true;
  return /^packages\/[^/]+\/src\//.test(file);
}

function readStateEvidence(stateDir) {
  const result = {
    state_files: 0,
    planned: 0,
    available: 0,
    unavailable: 0,
    with_unmapped_paths: 0,
    feature_counts: {},
  };
  if (!stateDir || !existsSync(stateDir)) return result;
  for (const name of readdirSync(stateDir).filter((item) => item.endsWith('.json'))) {
    result.state_files += 1;
    let state;
    try {
      state = JSON.parse(readFileSync(path.join(stateDir, name), 'utf8'));
    } catch {
      continue;
    }
    const plan = state?.run?.evidence?.verification_plan;
    if (!plan || typeof plan !== 'object') continue;
    result.planned += 1;
    if (plan.status === 'available') result.available += 1;
    else if (plan.status === 'unavailable') result.unavailable += 1;
    if (Array.isArray(plan.unmapped_paths) && plan.unmapped_paths.length > 0) result.with_unmapped_paths += 1;
    for (const feature of Array.isArray(plan.matched_features) ? plan.matched_features : []) {
      result.feature_counts[feature] = (result.feature_counts[feature] ?? 0) + 1;
    }
  }
  return result;
}

export function buildMaintenanceReport({
  root = DEFAULT_ROOT,
  mapPath = DEFAULT_MAP,
  changedPaths = [],
  stateDir = '',
} = {}) {
  const map = loadFeatureMap(root, mapPath);
  const plan = buildVerificationPlan(map, { root, changedPaths });
  const candidates = changedPaths.filter(isCandidateUserSurface);
  const candidatePlan = buildVerificationPlan(map, { root, changedPaths: candidates });
  const mappedCandidates = candidates.filter((item) => !candidatePlan.unmapped_paths.includes(item));
  return {
    map_version: map.version,
    feature_count: map.features.length,
    changed_path_count: changedPaths.length,
    candidate_user_surface_paths: candidates.length,
    mapped_user_surface_paths: mappedCandidates.length,
    mapping_coverage_ratio: candidates.length === 0 ? null : mappedCandidates.length / candidates.length,
    mapped_features: plan.matched_features,
    unmapped_candidate_paths: candidatePlan.unmapped_paths,
    state_evidence: readStateEvidence(stateDir),
  };
}

function parseArgs(argv) {
  const result = { root: DEFAULT_ROOT, mapPath: DEFAULT_MAP, changedPaths: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    const next = () => {
      const value = argv[++i];
      if (!value) throw new Error(`missing value for ${token}`);
      return value;
    };
    if (token === '--root') result.root = path.resolve(next());
    else if (token === '--map') result.mapPath = next();
    else if (token === '--base') result.base = next();
    else if (token === '--head') result.head = next();
    else if (token === '--changed-path') result.changedPaths.push(next());
    else if (token === '--state-dir') result.stateDir = path.resolve(next());
    else throw new Error(`unknown argument: ${token}`);
  }
  return result;
}

export function runCli(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const changedPaths = args.changedPaths.length > 0
    ? args.changedPaths
    : gitChangedPaths(args.root, args.base, args.head);
  const report = buildMaintenanceReport({
    root: args.root,
    mapPath: args.mapPath,
    changedPaths,
    stateDir: args.stateDir,
  });
  process.stdout.write(`${JSON.stringify(report)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === SCRIPT_PATH) {
  try {
    runCli();
  } catch (error) {
    console.error(`verification-map-audit: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}
