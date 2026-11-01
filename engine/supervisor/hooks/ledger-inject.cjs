#!/usr/bin/env node
const {config: C, expand} = require('../lib/config.cjs');
const fs = require('fs'), os = require('os'), cp = require('child_process');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  try {
    const data = JSON.parse(input.replace(/^\uFEFF/, ''));
    const claim = JSON.parse(fs.readFileSync(expand(C.claim_path), 'utf8'));
    if (claim.sessionId !== data.session_id) process.exit(0);
    const script = process.env[C.ledger_env] || expand(C.ledger_script);
    if (!fs.existsSync(script)) process.exit(0);
    const r = cp.spawnSync('bash', [script], { encoding: 'utf8', timeout: 60000 });
    const ctx = C.ledger_label + String(r.stdout).trim();
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: ctx } }));
  } catch (e) { /* fail open */ }
  process.exit(0);
});
process.stdin.on('error', () => process.exit(0));
