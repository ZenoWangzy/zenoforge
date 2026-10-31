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
export function zfConfigFile(relativePath, repoRoot = process.env.ZF_REPO_DIR || dirname(ENGINE_DIR)) {
  if (typeof relativePath !== 'string'
      || isAbsolute(relativePath)
      || relativePath.startsWith('\\')
      || /^[A-Za-z]:[\\/]/.test(relativePath)
      || relativePath.split(/[\\/]/).includes('..')) {
    throw new TypeError('config path must be relative and cannot contain a .. segment');
  }

  const configRoot = process.env.ZF_CONFIG_ROOT ?? join(repoRoot, '.zenoforge');
  const candidates = [
    configRoot && join(configRoot, relativePath),
    PACK_DIR && join(PACK_DIR, relativePath),
    join(ENGINE_DIR, relativePath),
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

export function zfHostOpsFile(relativePath, fallback = join(ENGINE_DIR, relativePath.replace(/^scripts\/agent\//, ''))) {
  const agentHome = process.env.AGENT_HOME || process.env.ZF_HOME || join(homedir(), '.zenoforge');
  const candidate = join(process.env.ZF_HOST_OPS_DIR || join(agentHome, 'host-ops'), relativePath);
  try { if (statSync(candidate).isFile()) return candidate; } catch { /* use the existing path */ }
  return fallback;
}
