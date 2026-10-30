// ~/.zenoforge/cli.json: what `init` decided, so start/upgrade/uninstall do not ask again.
import fs from 'node:fs';
import path from 'node:path';

export const statePath = (agentHome) => path.join(agentHome, 'cli.json');

export function loadState(agentHome) {
  try { return JSON.parse(fs.readFileSync(statePath(agentHome), 'utf8')); } catch { return null; }
}

/** KEY=VALUE lines (what the env files contain), comments ignored. */
export function parseEnvFile(text) {
  const env = {};
  for (const line of text.split('\n')) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line.trim());
    if (m) env[m[1]] = m[2];
  }
  return env;
}

export function readEnvFile(file) {
  try { return parseEnvFile(fs.readFileSync(file, 'utf8')); } catch { return {}; }
}
