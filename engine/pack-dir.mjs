// The deployment's pack directory for node scripts (Line B pack seam; same setting as ZF_PACK_DIR in config.sh).
// A pack holds optional modules and data the engine reads by relative path. No pack (empty directory) = every caller
// uses its generic default. Default here = this directory, where the the product pack is laid over the engine today.
import { readFileSync, statSync } from 'node:fs';
import { dirname, isAbsolute, join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const DEFAULT_PACK_DIR = ''; // PACK_DIR_DEFAULT: the public export rewrites this default to empty
export const PACK_DIR = process.env.ZF_PACK_DIR ?? DEFAULT_PACK_DIR;
const ENGINE_DIR = process.env.ZF_ENGINE_DIR || dirname(fileURLToPath(import.meta.url));
const ENV_NAME = /^[A-Z][A-Z0-9_]*$/;

function resolveConfigFile(relativePath, repoRoot, environment) {
  if (typeof relativePath !== 'string'
      || isAbsolute(relativePath)
      || relativePath.startsWith('\\')
      || /^[A-Za-z]:[\\/]/.test(relativePath)
      || relativePath.split(/[\\/]/).includes('..')) {
    throw new TypeError('config path must be relative and cannot contain a .. segment');
  }

  const configRoot = environment.ZF_CONFIG_ROOT ?? join(repoRoot, '.zenoforge');
  const packDir = environment.ZF_PACK_DIR ?? (environment === process.env ? PACK_DIR : DEFAULT_PACK_DIR);
  const engineDir = environment.ZF_ENGINE_DIR || ENGINE_DIR;
  const candidates = [
    configRoot && join(configRoot, relativePath),
    packDir && join(packDir, relativePath),
    join(engineDir, relativePath),
  ];
  for (const candidate of candidates) {
    if (!candidate) continue;
    try {
      if (statSync(candidate).isFile()) return candidate;
    } catch {
      // A missing candidate is expected while resolving through the fallback order.
    }
  }
  return null;
}

// Resolve one deployment setting without embedding a deployment prefix in engine code.
// A present empty value wins too; each reader keeps its existing empty-value fallback.
export function zfEnv(name, defaultValue = undefined, environment = process.env) {
  if (typeof name !== 'string' || !ENV_NAME.test(name)) {
    throw new TypeError('environment name must be an uppercase suffix');
  }

  const repoRoot = environment.ZF_REPO_DIR || dirname(ENGINE_DIR);
  const configFile = resolveConfigFile('config.json', repoRoot, environment);
  let prefix = '';
  if (configFile) {
    const config = JSON.parse(readFileSync(configFile, 'utf8'));
    if (typeof config?.env_prefix === 'string') prefix = config.env_prefix;
  }

  if (prefix) {
    const deploymentName = `${prefix}${name}`;
    if (Object.prototype.hasOwnProperty.call(environment, deploymentName)) {
      return environment[deploymentName];
    }
  }
  const publicName = `ZF_${name}`;
  if (Object.prototype.hasOwnProperty.call(environment, publicName)) return environment[publicName];
  return defaultValue;
}

// readPackJson('state/x.json') -> parsed JSON, or null when there is no pack or the pack has no such file.
// A file that exists but does not parse throws: a damaged pack must not read as "no pack".
export function readPackJson(relativePath) {
  if (!PACK_DIR) return null;
  try {
    return JSON.parse(readFileSync(join(PACK_DIR, relativePath), 'utf8'));
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
}

// Resolve target overrides first, then pack values retained during migration, then engine defaults.
export function zfConfigFile(relativePath, repoRoot = zfEnv('REPO_DIR') || dirname(ENGINE_DIR)) {
  return resolveConfigFile(relativePath, repoRoot, process.env);
}

export function zfHostOpsFile(relativePath, fallback = join(ENGINE_DIR, relativePath.replace(/^scripts\/agent\//, ''))) {
  const agentHome = process.env.AGENT_HOME || process.env.ZF_HOME || join(homedir(), '.zenoforge');
  const candidate = join(process.env.ZF_HOST_OPS_DIR || join(agentHome, 'host-ops'), relativePath);
  try { if (statSync(candidate).isFile()) return candidate; } catch { /* use the existing path */ }
  return fallback;
}
