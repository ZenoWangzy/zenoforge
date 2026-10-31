#!/usr/bin/env node
// Evaluate configured pre-push rules inside the candidate worktree.
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const fail = (message) => { console.error(`prepush-gates: ${message}`); process.exit(2); };
let config;
try { config = JSON.parse(readFileSync(process.argv[2], 'utf8')).prepush; } catch { fail('invalid configuration'); }
const string = (x) => typeof x === 'string' && x.length > 0 && !x.includes('\0');
const vector = (x) => Array.isArray(x) && x.length > 0 && x.every(string);
const envMap = (x) => x && typeof x === 'object' && !Array.isArray(x) && Object.entries(x).every(([k, v]) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(k) && string(v));
const validRule = (r) => {
  if (!r || typeof r !== 'object') return false;
  if (r.type === 'environment') return envMap(r.env);
  if (r.type === 'command') return vector(r.command) && (r.fatal === undefined || typeof r.fatal === 'boolean');
  if (r.type === 'boolean') return string(r.name) && vector(r.selector) && string(r.error) && Array.isArray(r.when_true) && r.when_true.every(validRule);
  if (r.type === 'packages') return vector(r.selector) && string(r.error) && vector(r.before) && vector(r.test) && vector(r.special_test) && string(r.special_package) && string(r.boolean_name) && vector(r.integration_diff) && string(r.integration_pattern) && vector(r.integration_test) && envMap(r.integration_env) && envMap(r.integration_env_defaults);
  if (r.type === 'notice') return vector(r.diff) && string(r.message);
  return false;
};
if (!config || !string(config.legacy_gate) || !/^[A-Za-z0-9_.-]+\.sh$/.test(config.legacy_gate) || !envMap(config.env) || !Array.isArray(config.rules) || !config.rules.every(validRule)) fail('invalid prepush configuration');
try { for (const r of config.rules) if (r.type === 'packages') new RegExp(r.integration_pattern); } catch { fail('invalid integration pattern'); }
if (process.argv[3] === '--legacy-name') { console.log(config.legacy_gate); process.exit(0); }
if (process.argv[3] === '--exports') {
  for (const rule of config.rules) if (rule.type === 'environment') {
    for (const [key, value] of Object.entries(rule.env)) process.stdout.write(`${key}\0${value}\0`);
  }
  process.exit(0);
}

const values = { base: process.env.PREPUSH_BASE, head: process.env.PREPUSH_HEAD, repo: process.cwd() };
if (!values.base || !values.head) fail('missing candidate revisions');
let rc = 0;
const expand = (arg, local = {}) => arg.replace(/\{\{(base|head|repo|package|file|relative_file)\}\}/g, (_, key) => local[key] ?? values[key] ?? fail(`missing ${key}`));
const run = (args, { capture = false, fatal = false, env = {} } = {}) => {
  const cmd = args.map((s) => expand(s));
  if (!capture) console.log('== ' + cmd.map((s) => JSON.stringify(s)).join(' '));
  const result = spawnSync(cmd[0], cmd.slice(1), { encoding: 'utf8', stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit', env: { ...process.env, ...env } });
  if (result.status !== 0) { if (fatal) fail('command failed'); if (!capture) rc = 1; }
  return result;
};
const checks = (rules) => { for (const rule of rules) {
  if (rule.type === 'environment') { Object.assign(process.env, rule.env); continue; }
  if (rule.type === 'command') { run(rule.command, { fatal: rule.fatal }); continue; }
  if (rule.type === 'boolean') {
    const result = run(rule.selector, { capture: true });
    if (result.status !== 0) fail(rule.error);
    const value = result.stdout.replace(/\n+$/, '');
    if (value !== 'true' && value !== 'false') fail(`invalid ${rule.name} selector result`);
    values[rule.name] = value;
    if (value === 'true') checks(rule.when_true);
    continue;
  }
  if (rule.type === 'notice') {
    const result = run(rule.diff, { capture: true });
    const first = (result.stdout || '').split(/\s+/).find(Boolean);
    if (first) console.log(rule.message.replace('{{file}}', first));
    continue;
  }
  const result = run(rule.selector, { capture: true });
  if (result.status !== 0) fail(rule.error);
  let selected;
  try { selected = JSON.parse(result.stdout); } catch { fail('invalid package selection'); }
  if (!Array.isArray(selected.rootNames) || !selected.rootNames.every(string) || !Array.isArray(selected.affectedNames) || !selected.affectedNames.every(string)) fail('invalid package selection');
  if (!selected.rootNames.length) continue;
  run(rule.before);
  for (const name of selected.rootNames) {
    if (name === rule.special_package && values[rule.boolean_name] === 'true') continue;
    run(rule.test.map((s) => expand(s, { package: name })));
  }
  if (selected.rootNames.includes(rule.special_package)) run(rule.special_test);
  const diff = run(rule.integration_diff, { capture: true });
  const pattern = new RegExp(rule.integration_pattern);
  for (const file of (diff.stdout || '').split('\n')) {
    const match = pattern.exec(file);
    if (!match || !match[1] || !match[2]) continue;
    const env = { ...rule.integration_env };
    for (const [key, value] of Object.entries(rule.integration_env_defaults)) env[key] = process.env[key] || value;
    run(rule.integration_test.map((s) => expand(s, { package: match[1], file, relative_file: match[2] })), { env });
  }
} };
checks(config.rules);
process.exit(rc);
