#!/usr/bin/env node
import { readFileSync, readdirSync, statSync, writeFileSync, mkdirSync } from 'node:fs';
import configModule from '../lib/config.cjs';
const { config: C, expand } = configModule;
import { join } from 'node:path';


const role = process.env[C.role_env] || '';
const sources = {
  policy: expand(C.sources.policy),
  claude_quota: expand(C.sources.claude_quota),
  zcode_quota: expand(C.sources.zcode_quota),
  ...(role ? { role: join(expand(C.sources.role_dir), `${role}.md`) } : {}),
};
const mtime = (p) => { try { return statSync(p).mtimeMs; } catch { return 0; } };
const read = (p) => { try { return readFileSync(p, 'utf8').trim(); } catch { return null; } };

let input = {};
try { input = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch {}
const event = input.hook_event_name || 'SessionStart';
const seenFile = join(expand(C.state_dir), C.seen_state_template.replace('{session}', input.session_id || 'none'));
let seen = {};
try { seen = JSON.parse(readFileSync(seenFile, 'utf8')); } catch {}

const watched = event === 'UserPromptSubmit' ? ['policy', 'role'] : Object.keys(sources);
const changed = watched.filter((k) => sources[k] && mtime(sources[k]) !== (seen[k] || 0));

const coach = [];
if (C.coach.enabled && role === C.coach.role) {
  const dir = expand(C.coach.report_dir);
  let newest = '';
  try { newest = readdirSync(dir).filter((f) => f.endsWith('.md')).sort().pop() || ''; } catch {}
  const announced = expand(C.coach.marker_file);
  let said = '';
  try { said = readFileSync(announced, 'utf8').trim(); } catch {}
  if (newest && said !== newest) {
    coach.push(C.coach.new.replace('{path}', join(dir, newest)));
    mkdirSync(expand(C.state_dir), { recursive: true });
    writeFileSync(announced, newest);
  } else if (event === 'SessionStart' && Date.now() - mtime(newest ? join(dir, newest) : dir) > C.coach.stale_days * 86400000) {
    coach.push(C.coach.stale);
  }
}
if (event === 'UserPromptSubmit' && changed.length === 0) {
  if (coach.length) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: event, additionalContext: coach.join('\n') } }));
  process.exit(0);
}

const pct = (q) => {
  const j = q && JSON.parse(q);
  if (!j) return 'unknown';
  const left = (t) => (t ? `${Math.max(0, Math.round((t * 1000 - Date.now()) / 3600000))}h` : '?');
  return `5h ${j.five_h_pct}% (reset in ${left(j.five_h_reset)}), week ${j.week_pct}% (reset in ${left(j.week_reset)})`;
};
const parts = [];
const policy = read(sources.policy);
if (policy) parts.push(C.labels.policy.replace('{path}', sources.policy) + policy);
let quotas = [];
try { quotas.push(`${C.labels.quotas[0]} ${pct(read(sources.claude_quota))}`); } catch {}
try { quotas.push(`${C.labels.quotas[1]} ${pct(read(sources.zcode_quota))}`); } catch {}
if (event === 'SessionStart' && quotas.length) parts.push(C.labels.quota + quotas.join('; '));
const roleText = sources.role && read(sources.role);
if (roleText) parts.push(C.labels.role.replace('{role}', role) + roleText);
parts.push(...coach);
if (!parts.length) process.exit(0);

mkdirSync(expand(C.state_dir), { recursive: true });
for (const k of Object.keys(sources)) seen[k] = mtime(sources[k]);
writeFileSync(seenFile, JSON.stringify(seen));
process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: event, additionalContext: parts.join('\n\n') } }));
