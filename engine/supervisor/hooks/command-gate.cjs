#!/usr/bin/env node
const {config: C, expand} = require('../lib/config.cjs');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { input += c; });
process.stdin.on('end', () => {
  try {
    const data = JSON.parse(input.replace(/^\uFEFF/, ''));
    if (data.tool_name !== 'Bash') process.exit(0);
    const raw = String((data.tool_input || {}).command || '');
    for (const m of raw.matchAll(/<<-?\s*(\w+)[^\n]*\n([\s\S]*?)\n\1(?=\s|$)/g)) {
      if (/`|\$\(/.test(m[2])) {
        process.stderr.write(C.command_messages[0].replaceAll('{delimiter}', m[1]));
        process.exit(2);
      }
    }
    const cmd = raw
      .replace(/<<-?\s*['"]?(\w+)['"]?[^\n]*\n[\s\S]*?\n\1(?=\s|$)/g, '<<HEREDOC');

    const pushesMain = new RegExp(C.push_pattern).test(cmd);
    if (pushesMain && !new RegExp(C.command_patterns[0]).test(cmd)) {
      process.stderr.write(C.command_messages[1]);
      process.exit(2);
    }

    const touchesState = new RegExp(C.command_patterns[1]).test(cmd);
    const writes = /\bmv\b|\bsed\s+-i\b|\btee\b|\bcp\b[^\n;]*\bstate\/|(^|[^0-9&])>\s*[^&\s]/.test(cmd);
    if (touchesState && writes && !new RegExp(C.command_patterns[2]).test(cmd)) {
      process.stderr.write(C.command_messages[2]);
      process.exit(2);
    }
    const addsWorktree = /\bgit\b[^\n;&|]*\bworktree\s+add\b/.test(cmd);
    if (addsWorktree && !new RegExp(C.command_patterns[3]).test(cmd)) {
      process.stderr.write(C.command_messages[3]);
      process.exit(2);
    }
    const lines = cmd.split('\n');
    const firstCd = lines.findIndex(l => /(^|[;&|(]\s*)cd\s+\S/.test(l));
    if (firstCd >= 0 && lines.some((l, i) => i > firstCd
        && /\bgit\s+(add|commit)\b/.test(l)
        && !/(^|[;&|(]\s*)cd\s+\S+[^\n]*&&[^\n]*\bgit\s+(add|commit)\b/.test(l)
        && !/\bgit\s+-C\s/.test(l))) {
      process.stderr.write(C.command_messages[4]);
      process.exit(2);
    }
    try {
      const claim = JSON.parse(require('fs').readFileSync(expand(C.claim_path), 'utf8'));
      const handsOn = c => new RegExp(C.command_patterns[4]).test(c) || new RegExp(C.command_patterns[5]).test(c)
        || new RegExp(C.command_patterns[6]).test(c) || new RegExp(C.command_patterns[7]).test(c);
      const exempt = c => new RegExp(C.command_patterns[8]).test(c);
      if (claim.sessionId === data.session_id && cmd.split(/\n|;|&&|\|\|?/).some(c => handsOn(c) && !exempt(c))) {
        process.stderr.write(C.command_messages[5]);
        process.exit(2);
      }
    } catch (e) { /* no claim file: not a hotfix session */ }
    process.exit(0);
  } catch (e) {
    process.exit(0);
  }
});
process.stdin.on('error', () => process.exit(0));
