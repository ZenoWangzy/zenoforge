#!/usr/bin/env node
// Evaluate configured command rules in order; the first matching rule denies the command.
const { readFileSync } = require('node:fs');
const { spawnSync } = require('node:child_process');
const { join } = require('node:path');

function compileRules(data) {
  if (!Array.isArray(data) || data.length === 0) throw new Error('rules must be a nonempty array');
  return data.map((rule) => {
    if (!rule || typeof rule !== 'object' || !Array.isArray(rule.patterns) || !rule.patterns.length
      || !rule.patterns.every((s) => typeof s === 'string' && s.length > 0)
      || typeof rule.message !== 'string' || !rule.message.trim()
      || (rule.require !== undefined && typeof rule.require !== 'string')
      || (rule.mask !== undefined && typeof rule.mask !== 'string')) throw new Error('invalid rule');
    return {
      patterns: rule.patterns.map((s) => new RegExp(s)),
      require: rule.require === undefined ? null : new RegExp(rule.require),
      mask: rule.mask === undefined ? null : new RegExp(rule.mask, 'g'),
      message: rule.message,
    };
  });
}

function verdict(command, rules) {
  const cmd = String(command || '');
  for (const rule of rules) {
    if (rule.require && !rule.require.test(cmd)) continue;
    const subject = rule.mask ? cmd.replace(rule.mask, '') : cmd;
    if (rule.patterns.some((pattern) => pattern.test(subject))) return rule.message;
  }
  return null;
}
module.exports = { verdict, compileRules };

async function main() {
  const { zfConfigFile, PACK_DIR } = await import('./pack-dir.mjs');
  const config = zfConfigFile('hotfix.json');
  if (!config) {
    if (PACK_DIR) {
      const legacy = join(PACK_DIR, 'prod-hotfix-gate.cjs');
      try {
        require('node:fs').accessSync(legacy);
        const result = spawnSync(process.execPath, [legacy, ...process.argv.slice(2)], { stdio: 'inherit' });
        return result.status ?? 1;
      } catch { /* no legacy gate */ }
    }
    process.stderr.write('prod-hotfix-gate: configure command rules in hotfix.json\n');
    return 2;
  }
  let rules;
  try { rules = compileRules(JSON.parse(readFileSync(config, 'utf8')).command_rules); }
  catch { process.stderr.write('prod-hotfix-gate: invalid command rules\n'); return 2; }
  let input = '';
  process.stdin.setEncoding('utf8');
  try {
    for await (const chunk of process.stdin) input += chunk;
    const data = JSON.parse(input.replace(/^\uFEFF/, ''));
    if (data.tool_name !== 'Bash') return 0;
    const message = verdict((data.tool_input || {}).command, rules);
    if (message) { process.stderr.write(`${message}\n`); return 2; }
    return 0;
  } catch { return 0; }
}
if (require.main === module) main().then((status) => { process.exitCode = status; }, () => { process.exitCode = 2; });
