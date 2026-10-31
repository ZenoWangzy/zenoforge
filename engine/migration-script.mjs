import { readFileSync, statSync } from 'node:fs';
import { isAbsolute, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { PACK_DIR, zfConfigFile } from './pack-dir.mjs';

const scripts = {
  roleCheck: 'check-fruit-migration-role.mjs',
};

export function migrationScript(key, root = process.cwd()) {
  const fallback = scripts[key];
  if (!fallback) throw new Error(`unknown migration script: ${key}`);
  const configFile = zfConfigFile('release.json');
  const config = configFile ? JSON.parse(readFileSync(configFile, 'utf8')) : {};
  const configured = config.migration?.[key];
  if (configured !== undefined && (typeof configured !== 'string' || !configured || isAbsolute(configured)
      || configured.startsWith('\\') || /^[A-Za-z]:/.test(configured) || configured.split(/[\\/]/).includes('..'))) {
    throw new Error(`release.json: migration.${key} must be a relative path`);
  }
  const candidates = [configured && resolve(root, configured), PACK_DIR && join(PACK_DIR, fallback)];
  for (const candidate of candidates) {
    if (!candidate) continue;
    try { if (statSync(candidate).isFile()) return candidate; } catch (error) {
      if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
    }
  }
  throw new Error(`migration script unavailable: ${key}`);
}

if (process.argv[1] && resolve(process.argv[1]) === new URL(import.meta.url).pathname) {
  try {
    const script = migrationScript(process.argv[2]);
    const result = spawnSync(process.execPath, [script, ...process.argv.slice(3)], { stdio: 'inherit' });
    if (result.error) throw result.error;
    process.exitCode = result.status ?? 1;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
