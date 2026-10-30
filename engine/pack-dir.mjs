// The deployment's pack directory for node scripts (Line B pack seam; same setting as ZF_PACK_DIR in config.sh).
// A pack holds optional modules and data the engine reads by relative path. No pack (empty directory) = every caller
// uses its generic default. Default here = this directory, where the the product pack is laid over the engine today.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const DEFAULT_PACK_DIR = ''; // PACK_DIR_DEFAULT: the public export rewrites this default to empty
export const PACK_DIR = process.env.ZF_PACK_DIR ?? DEFAULT_PACK_DIR;

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
