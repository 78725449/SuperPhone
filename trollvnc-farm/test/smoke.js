// 网关冒烟测试：API + WS<->TCP 桥接 + 群控广播
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';
import { FakeVncServer } from './fake-rfb-server.js';

const ROOT = path.resolve(import.meta.dirname, '..');
const PORT = 18080 + Math.floor(Math.random() * 500);
const TOKEN = 'testtoken';
const VNC_PORT = 15901 + Math.floor(Math.random() * 300);
const REG_PORT = 17081 + Math.floor(Math.random() * 400);
const TUN_PORT = 17181 + Math.floor(Math.random() * 400);
const tmpData = fs.mkdtempSync(path.join(os.tmpdir(), 'farm-test-'));

let failures = 0;
function check(name, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

async function waitFor(fn, timeoutMs = 6000, interval = 60) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try { const v = await fn(); if (v) return v; } catch { /* retry */ }
    await new Promise((r) => setTimeout(r, interval));
  }
  throw new Error('waitFor timeout');
}

const child = spawn(process.execPath, [path.join(ROOT, 'server', 'index.js')], {
  env: { ...process.env, FARM_PORT: String(PORT), FARM_REG_PORT: String(REG_PORT), FARM_TUNNEL_PORT: String(TUN_PORT), FARM_TOKEN: TOKEN, FARM_DATA_DIR: tmpData, FARM_HOST: '127.0.0.1' },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let childOut = '';
child.stdout.on('data', (d) => (childOut += d));
child.stderr.on('data', (d) => (childOut += d));

const fake = new FakeVncServer({ port: VNC_PORT, mode: 'echo' });
const auth = { Authorization: `Bearer ${TOKEN}` };

try {
  await fake.start();
  await waitFor(async () => {
    const res = await fetch(`http://127.0.0.1:${PORT}/api/state`, { headers: auth });
    return res.ok;
  });

  // 1. 添加设备
  const addRes = await fetch(`http://127.0.0.1:${PORT}/api/devices`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({ name: 'TestPhone', host: '127.0.0.1', port: VNC_PORT, group: 'demo' }),
  });
  check('POST /api/devices -> 201', addRes.status === 201);
  const dev = (await addRes.json()).device;

  // 2. 无 token 被拒
  const noAuth = await fetch(`http://127.0.0.1:${PORT}/api/devices`);
  check('no-token -> 401', noAuth.status === 401);

  // 3. 列表包含设备
  const list = await (await fetch(`http://127.0.0.1:${PORT}/api/devices`, { headers: auth })).json();
  check('GET /api/devices contains device', list.devices.some((d) => d.id === dev.id));

  // 4. ???????????WS ?????????????????
  let noTunRejected = false;
  await new Promise((res) => {
    const w2 = new WebSocket(`ws://127.0.0.1:${PORT}/ws/vnc/${encodeURIComponent(dev.id)}?token=${TOKEN}`);
    w2.on('close', (c) => { noTunRejected = c === 4003; res(); });
    w2.on('error', () => {});
    setTimeout(res, 1500);
  });
  check('no-tunnel WS rejected 4003 (no direct fallback)', noTunRejected);
  // ??WS<->???? / ????? / ??????? test/tunnel-test.js


} catch (e) {
  console.error('TEST ERROR:', e.message);
  console.log(childOut);
  failures++;
} finally {
  try { await fake.stop(); } catch { /* noop */ }
  child.kill();
  await new Promise((r) => setTimeout(r, 300));
  try { fs.rmSync(tmpData, { recursive: true, force: true }); } catch { /* noop */ }
}

console.log(failures === 0 ? '\nALL TESTS PASSED' : `\n${failures} TEST(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
