// A quota script must end on a usage tab that never answers, close that tab, and open one when none is listed.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const bin = path.dirname(fileURLToPath(import.meta.url));

// The quota reply a script reads: zc-quota the GLM limit list, codex-quota the ChatGPT rate_limit windows.
function quotaReply(script, week, codexWindows) {
  if (script === 'codex-quota') {
    const rateLimit = codexWindows === undefined ? {
      primary_window: { limit_window_seconds: 18000, used_percent: 10, reset_at: 1800000000 },
      secondary_window: { limit_window_seconds: 604800, used_percent: week, reset_at: 1800000000 },
    } : { primary_window: codexWindows[0] ?? null, secondary_window: codexWindows[1] ?? null };
    return { hit: 'https://chatgpt.com/backend-api/wham/usage', body: JSON.stringify({ rate_limit: rateLimit }) };
  }
  const limits = [{ type: 'TOKENS_LIMIT', unit: 3, percentage: 10 }, { type: 'TOKENS_LIMIT', unit: 6, percentage: week, nextResetTime: 1800000000000 }];
  return { hit: 'https://bigmodel.cn/api/monitor/usage/quota/limit', body: JSON.stringify({ data: { limits } }) };
}

// Replies to CDP calls like a usage tab: its quota reply is `reply.hit`/`reply.body`, the first `reply.miss` navigations never
// get one, and the tab sits at `reply.atUrl`. Records each method called.
function answerCdp(socket, reply, seen) {
  const send = obj => {
    const text = Buffer.from(JSON.stringify(obj));
    const head = text.length < 126 ? Buffer.from([0x81, text.length]) : Buffer.from([0x81, 126, text.length >> 8, text.length & 255]);
    socket.write(Buffer.concat([head, text]));
  };
  let navigations = 0;
  let buf = Buffer.alloc(0);
  socket.on('data', chunk => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 6) {  // client frames are masked and under 64k here
      const len7 = buf[1] & 127, at = len7 === 126 ? 4 : 2, len = len7 === 126 ? buf.readUInt16BE(2) : len7;
      if (buf.length < at + 4 + len) return;
      const mask = buf.subarray(at, at + 4), text = Buffer.from(buf.subarray(at + 4, at + 4 + len).map((b, i) => b ^ mask[i % 4]));
      const opcode = buf[0] & 15;
      buf = buf.subarray(at + 4 + len);
      if (opcode !== 1) continue;
      const m = JSON.parse(text);
      seen.push(`CDP ${m.method}`);
      if (m.method === 'Page.navigate' && ++navigations > (reply.miss || 0)) {
        send({ method: 'Network.responseReceived', params: { requestId: 'q', response: { url: reply.hit } } });
        send({ method: 'Network.loadingFinished', params: { requestId: 'q' } });
      }
      const result = m.method === 'Network.getResponseBody' ? { body: reply.body }
        : m.method === 'Runtime.evaluate' ? { result: { value: reply.atUrl } } : {};
      send({ id: m.id, result });
    }
  });
}

async function run(script, tabs, files = {}, { week, windows, miss, atUrl, env = {}, home: reuse } = {}) {
  const seen = [];
  const server = http.createServer((req, res) => {
    seen.push(`${req.method} ${req.url}`);
    const port = server.address().port;
    const tab = { id: 'new-tab', type: 'page', url: 'about:blank', webSocketDebuggerUrl: `ws://127.0.0.1:${port}/tab` };
    if (req.url === '/json/version') return res.end(JSON.stringify({ webSocketDebuggerUrl: `ws://127.0.0.1:${port}/browser` }));
    if (req.url.startsWith('/json/new')) return res.end(JSON.stringify(tab));
    if (req.url.startsWith('/json/close')) return res.end('Target is closing');
    res.end(JSON.stringify(seen.some(s => s.startsWith('PUT')) ? [tab] : tabs(port)));
  });
  // Accepts the upgrade, then never answers a CDP call unless a week is given: a hung renderer.
  server.on('upgrade', (req, socket) => {
    const accept = createHash('sha1').update(`${req.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.on('error', () => {});
    if (week !== undefined || windows !== undefined) answerCdp(socket, { ...quotaReply(script, week, windows), miss, atUrl }, seen);
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const home = reuse ?? fs.mkdtempSync(path.join(os.tmpdir(), 'quota-tab-'));
  fs.mkdirSync(path.join(home, '.zenoforge'), { recursive: true });
  for (const [file, text] of Object.entries(files)) fs.writeFileSync(path.join(home, file), text);
  const child = spawn(process.execPath, [path.join(bin, script)], {
    env: { ...process.env, HOME: home, AGENT_HOME: path.join(home, '.zenoforge'), NO_PROXY: '127.0.0.1',
      QUOTA_CDP_URL: `http://127.0.0.1:${server.address().port}`, QUOTA_CDP_CALL_TIMEOUT_MS: '300', QUOTA_RESPONSE_WAIT_MS: '1000', ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  child.stdout.on('data', d => { out += d; });
  child.stderr.on('data', d => { out += d; });
  const killer = setTimeout(() => child.kill('SIGKILL'), 15000);
  const code = await new Promise(r => child.on('close', r));
  clearTimeout(killer);
  server.closeAllConnections();
  server.close();
  return { code, out, seen, home };
}

const scripts = {
  'zc-quota': { url: 'https://bigmodel.cn/coding-plan/personal/usage', book: '.zenoforge/zc-quota.json.tab',
    write: id => `${id}\n`, read: t => t.trim(), signIn: 'https://bigmodel.cn/login' },
  'codex-quota': { url: 'https://chatgpt.com/settings/usage', book: '.zenoforge/codex-quota-state.json',
    write: id => JSON.stringify({ tab_id: id }), read: t => JSON.parse(t).tab_id, signIn: 'https://chatgpt.com/auth/login' },
};
for (const [script, { url, book, write, read, signIn }] of Object.entries(scripts)) {
  const tab = (id, at) => port => [{ id, type: 'page', url: at, webSocketDebuggerUrl: `ws://127.0.0.1:${port}/tab` }];

  const hung = await run(script, tab('hung', url), { [book]: write('hung') });
  assert.equal(hung.code, 1, hung.out);
  assert.match(hung.out, /CDP Network\.enable no reply/);
  assert.ok(hung.seen.includes('GET /json/close/hung'), hung.seen.join());

  const missing = await run(script, () => []);
  assert.ok(missing.seen.some(s => s.startsWith('PUT /json/new')), missing.seen.join());
  assert.equal(read(fs.readFileSync(path.join(missing.home, book), 'utf8')), 'new-tab');

  // A reply missed once is retried once: the second reload answers and the read succeeds.
  const retried = await run(script, tab('read', url), { [book]: write('read') }, { week: 13, miss: 1, env: { ZC_WEEK_PACE_PCT: '0' } });
  assert.equal(retried.code, 0, retried.out);
  assert.equal(retried.seen.filter(s => s === 'CDP Page.navigate').length, 2, retried.seen.join());
  assert.equal(retried.out.match(/retrying the reload once/g)?.length, 1, retried.out);

  // A signed-out tab is an immediate failure with its own line: no second reload.
  const signedOut = await run(script, tab('read', url), { [book]: write('read') }, { week: 13, miss: 99, atUrl: signIn, env: { ZC_WEEK_PACE_PCT: '0' } });
  assert.equal(signedOut.code, 1, signedOut.out);
  assert.match(signedOut.out, /signed out: the usage tab is at/);
  assert.ok(!/retrying the reload once/.test(signedOut.out), signedOut.out);
  assert.equal(signedOut.seen.filter(s => s === 'CDP Page.navigate').length, 1, signedOut.seen.join());
}

const redirected = await run('zc-quota', port => [{ id: 'mine', type: 'page', url: 'https://bigmodel.cn/coding-plan/personal/overview',
  webSocketDebuggerUrl: `ws://127.0.0.1:${port}/tab` }], { '.zenoforge/zc-quota.json.tab': 'mine\n' });
assert.ok(!redirected.seen.some(s => s.startsWith('PUT')), `a redirected booked tab is reused: ${redirected.seen.join()}`);
assert.ok(redirected.seen.includes('GET /json/close/mine'), redirected.seen.join());

const reused = await run('zc-quota', port => [{ id: 'mine', type: 'page', url: 'https://example.com/',
  webSocketDebuggerUrl: `ws://127.0.0.1:${port}/tab` }], { '.zenoforge/zc-quota.json.tab': 'mine\n' });
assert.ok(reused.seen.some(s => s.startsWith('PUT /json/new')), `a booked tab that left the site is not ours: ${reused.seen.join()}`);
assert.ok(!reused.seen.includes('GET /json/close/mine'), reused.seen.join());

// Reset line above 100: at 98% nothing is spent, and head hears once for this weekly window.
const usageTab = port => [{ id: 'read', type: 'page', url: 'https://bigmodel.cn/coding-plan/personal/usage',
  webSocketDebuggerUrl: `ws://127.0.0.1:${port}/tab` }];
const codexUsageTab = port => [{ id: 'read', type: 'page', url: 'https://chatgpt.com/settings/usage',
  webSocketDebuggerUrl: `ws://127.0.0.1:${port}/tab` }];

const monthlyHome = fs.mkdtempSync(path.join(os.tmpdir(), 'quota-monthly-'));
const monthly = await run('codex-quota', codexUsageTab, {}, { home: monthlyHome, windows: [
  { limit_window_seconds: 2592000, used_percent: 62, reset_at: 1800000000 },
] });
assert.equal(monthly.code, 0, monthly.out);
const monthlySnapshot = JSON.parse(fs.readFileSync(path.join(monthlyHome, '.zenoforge/codex-quota.json')));
assert.equal(monthlySnapshot.window_seconds, 2592000);
assert.equal(monthlySnapshot.used_percent, 62);
assert.equal(monthlySnapshot.reset_at, 1800000000);
assert.equal(monthlySnapshot.week_pct, 62, 'legacy week_pct remains populated for a lone pacing window');
assert.equal(monthlySnapshot.week_reset, 1800000000, 'legacy week_reset remains populated for a lone pacing window');
assert.equal(monthlySnapshot.five_h_pct, null);

const heldHome = fs.mkdtempSync(path.join(os.tmpdir(), 'quota-held-'));
const alerts = path.join(heldHome, 'alerts');
const held = { week: 98, home: heldHome, env: { ZC_WEEK_RESET_AT: '101', ZC_ALERT_FILE: alerts } };
for (let i = 0; i < 2; i++) {
  const r = await run('zc-quota', usageTab, {}, held);
  assert.equal(r.code, 0, r.out);
  assert.ok(!r.seen.includes('CDP Runtime.evaluate'), `no reset may be spent: ${r.seen.join()}`);
}
assert.equal(JSON.parse(fs.readFileSync(path.join(heldHome, '.zenoforge/zc-quota.json'))).week_pct, 98);

// A symlinked marker: readers use the target, so a release must clear it and a later hold must reach it. Removing the link read as released with the hold still on.
const linkHome = fs.mkdtempSync(path.join(os.tmpdir(), 'quota-link-'));
const target = path.join(linkHome, 'readers-zcode-exhausted-until');
const link = path.join(linkHome, '.zenoforge/zcode-exhausted-until');
fs.mkdirSync(path.dirname(link), { recursive: true });
fs.symlinkSync(target, link);
// Pace off: the fixture's week reset is years ahead, so the pace line would hold (glm_factory_cap_2026_11_08 has its own self-test).
const linked = env => run('zc-quota', usageTab, {}, { week: 13, home: linkHome, env: { ZC_WEEK_PACE_PCT: '0', ...env } });
await linked({ ZC_WEEK_CAP: '0' });
assert.ok(Number(fs.readFileSync(target, 'utf8')) > Date.now() / 1000, 'a hold must reach the symlink target');
await linked({});
assert.equal(fs.existsSync(target), false, 'a release must clear the symlink target');
assert.ok(fs.lstatSync(link).isSymbolicLink(), 'a release must keep the symlink');
await linked({ ZC_WEEK_CAP: '0' });
assert.ok(fs.existsSync(target), 'a hold after a release must reach the symlink target');
assert.equal(fs.readFileSync(alerts, 'utf8').match(/ZCODE-WEEK-RESET-HELD/g)?.length, 1);

console.log('ok - quota scripts end on a hung tab, close it, and open a missing one');
