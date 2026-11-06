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

async function run(script, tabs, files = {}) {
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
  // Accepts the upgrade, then never answers a CDP call: a hung renderer.
  server.on('upgrade', (req, socket) => {
    const accept = createHash('sha1').update(`${req.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.on('error', () => {});
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'quota-tab-'));
  fs.mkdirSync(path.join(home, '.zenoforge'));
  for (const [file, text] of Object.entries(files)) fs.writeFileSync(path.join(home, file), text);
  const child = spawn(process.execPath, [path.join(bin, script)], {
    env: { ...process.env, HOME: home, AGENT_HOME: path.join(home, '.zenoforge'), NO_PROXY: '127.0.0.1',
      QUOTA_CDP_URL: `http://127.0.0.1:${server.address().port}`, QUOTA_CDP_CALL_TIMEOUT_MS: '300' },
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

console.log('ok - quota scripts end on a hung tab, close it, and open a missing one');
