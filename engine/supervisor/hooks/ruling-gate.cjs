#!/usr/bin/env node
const {config: C, expand} = require('../lib/config.cjs');
const fs = require('fs'), os = require('os');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  try {
    const data = JSON.parse(input.replace(/^\uFEFF/, ''));
    if (data.stop_hook_active) process.exit(0);
    const claim = JSON.parse(fs.readFileSync(expand(C.claim_path), 'utf8'));
    if (claim.sessionId !== data.session_id) process.exit(0);
    const lines = fs.readFileSync(data.transcript_path, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l));
    const textOf = j => { const c = j.message.content; return Array.isArray(c) ? c.filter(x => x.type === 'text').map(x => x.text).join('\n') : String(c); };
    let ai = -1;
    for (let i = lines.length - 1; i >= 0; i--) if (lines[i].type === 'assistant' && textOf(lines[i]).trim()) { ai = i; break; }
    if (ai < 0) process.exit(0);
    let speaker = '';
    for (let i = ai - 1; i >= 0 && !speaker; i--) {
      if (lines[i].type !== 'user') continue;
      const t = textOf(lines[i]).trim();
      if (t && !C.ignored_user_prefixes.some(p => t.startsWith(p))) speaker = t;
    }
    if (!new RegExp(C.ruling_trigger).test(speaker)) process.exit(0);
    if (new RegExp(C.ruling_carrier).test(textOf(lines[ai]))) process.exit(0);
    process.stderr.write(C.ruling_message.replace('{text}', speaker.slice(0, 40)));
    process.exit(2);
  } catch (e) { process.exit(0); }
});
process.stdin.on('error', () => process.exit(0));
