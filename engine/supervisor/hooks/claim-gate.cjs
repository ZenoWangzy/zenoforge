#!/usr/bin/env node
const {config: C, expand} = require('../lib/config.cjs');
const fs = require('fs'), os = require('os'), cp = require('child_process');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  try {
    const data = JSON.parse(input.replace(/^\uFEFF/, ''));
    if (data.stop_hook_active) process.exit(0);
    const claim = JSON.parse(fs.readFileSync(expand(C.claim_path), 'utf8'));
    if (claim.sessionId !== data.session_id) process.exit(0);
    let text = '';
    const lines = fs.readFileSync(data.transcript_path, 'utf8').split('\n').filter(Boolean);
    for (let i = lines.length - 1; i >= 0 && !text; i--) {
      const j = JSON.parse(lines[i]);
      if (j.type !== 'assistant') continue;
      const c = j.message.content;
      text = Array.isArray(c) ? c.filter(x => x.type === 'text').map(x => x.text).join('\n') : String(c);
    }
    const positive = new RegExp(C.readiness_pattern);
    if (!positive.test(text)) process.exit(0);
    const gate = process.env[C.demo_gate_env] || expand(C.demo_gate);
    if (!fs.existsSync(gate)) process.exit(0);
    const r = cp.spawnSync('bash', [gate], { encoding: 'utf8' });
    if (r.status === 0) process.exit(0);
    process.stderr.write(C.claim_message.replace('{result}', String(r.stdout).trim()));
    process.exit(2);
  } catch (e) {
    process.exit(0);
  }
});
process.stdin.on('error', () => process.exit(0));
