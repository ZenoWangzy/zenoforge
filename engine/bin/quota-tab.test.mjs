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

// Replies to CDP calls like a tab whose quota call reports `week` percent, and records each method called.
function answerCdp(socket, week, seen) {
  const send = obj => {
    const text = Buffer.from(JSON.stringify(obj));
    const head = text.length < 126 ? Buffer.from([0x81, text.length]) : Buffer.from([0x81, 126, text.length >> 8, text.length & 255]);
    socket.write(Buffer.concat([head, text]));
  };
  const limits = [{ type: 'TOKENS_LIMIT', unit: 3, percentage: 10 }, { type: 'TOKENS_LIMIT', unit: 6, percentage: week, nextResetTime: 1800000000000 }];
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
      if (m.method === 'Page.navigate') {
        send({ method: 'Network.responseReceived', params: { requestId: 'q', response: { url: 'https://bigmodel.cn/api/monitor/usage/quota/limit' } } });
        send({ method: 'Network.loadingFinished', params: { requestId: 'q' } });
      }
      send({ id: m.id, result: m.method === 'Network.getResponseBody' ? { body: JSON.stringify({ data: { limits } }) } : {} });
    }
  });
}

async function run(script, tabs, files = {}, { week, env = {}, home: reuse } = {}) {
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
    if (week !== undefined) answerCdp(socket, week, seen);
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const home = reuse ?? fs.mkdtempSync(path.join(os.tmpdir(), 'quota-tab-'));
  fs.mkdirSync(path.join(home, '.zenoforge'), { recursive: true });
  for (const [file, text] of Object.entries(files)) fs.writeFileSync(path.join(home, file), text);
  const child = spawn(process.execPath, [path.join(bin, script)], {
    env: { ...process.env, HOME: home, AGENT_HOME: path.join(home, '.zenoforge'), NO_PROXY: '127.0.0.1',
      QUOTA_CDP_URL: `http://127.0.0.1:${server.address().port}`, QUOTA_CDP_CALL_TIMEOUT_MS: '300', ...env },
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
    write: id => `${id}\n`, read: t => t.trim() },
  'codex-quota': { url: 'https://chatgpt.com/settings/usage', book: '.zenoforge/codex-quota-state.json',
    write: id => JSON.stringify({ tab_id: id }), read: t => JSON.parse(t).tab_id },
};
for (const [script, { url, book, write, read }] of Object.entries(scripts)) {
  const tab = (id, at) => port => [{ id, type: 'page', url: at, webSocketDebuggerUrl: `ws://127.0.0.1:${port}/tab` }];

  const hung = await run(script, tab('hung', url), { [book]: write('hung') });
  assert.equal(hung.code, 1, hung.out);
  assert.match(hung.out, /CDP Network\.enable no reply/);
  assert.ok(hung.seen.includes('GET /json/close/hung'), hung.seen.join());

  const missing = await run(script, () => []);
  assert.ok(missing.seen.some(s => s.startsWith('PUT /json/new')), missing.seen.join());
  assert.equal(read(fs.readFileSync(path.join(missing.home, book), 'utf8')), 'new-tab');
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
const heldHome = fs.mkdtempSync(path.join(os.tmpdir(), 'quota-held-'));
const alerts = path.join(heldHome, 'alerts');
const held = { week: 98, home: heldHome, env: { ZC_WEEK_RESET_AT: '101', ZC_ALERT_FILE: alerts } };
for (let i = 0; i < 2; i++) {
  const r = await run('zc-quota', usageTab, {}, held);
  assert.equal(r.code, 0, r.out);
  assert.ok(!r.seen.includes('CDP Runtime.evaluate'), `no reset may be spent: ${r.seen.join()}`);
}
assert.equal(JSON.parse(fs.readFileSync(path.join(heldHome, '.zenoforge/zc-quota.json'))).week_pct, 98);
assert.equal(fs.readFileSync(alerts, 'utf8').match(/ZCODE-WEEK-RESET-HELD/g)?.length, 1);

console.log('ok - quota scripts end on a hung tab, close it, and open a missing one');
