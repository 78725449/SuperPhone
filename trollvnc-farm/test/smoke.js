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
  env: { ...process.env, FARM_PORT: String(PORT), FARM_TOKEN: TOKEN, FARM_DATA_DIR: tmpData, FARM_HOST: '127.0.0.1' },
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

  // 4. WS <-> TCP 桥接（echo 模式）
  const wsUrl = `ws://127.0.0.1:${PORT}/ws/vnc/${encodeURIComponent(dev.id)}?token=${TOKEN}`;
  const ws = new WebSocket(wsUrl);
  await new Promise((res, rej) => { ws.on('open', res); ws.on('error', rej); });
  await waitFor(() => fake.connections.size >= 1);
  const conn = [...fake.connections][0];
  const wsGot = [];
  ws.on('message', (data) => wsGot.push(Buffer.from(data)));

  const sent = Buffer.from([1, 2, 3, 4, 5]);
  ws.send(sent);
  await waitFor(() => fake.allReceived(conn) && fake.allReceived(conn).length >= 5);
  check('WS->TCP byte passthrough', Buffer.concat(conn.received).equals(sent));

  fake.sendToAll(Buffer.from([0xde, 0xad]));
  await waitFor(() => wsGot.some((b) => b.equals(Buffer.from([0xde, 0xad]))));
  check('TCP->WS byte passthrough', wsGot.some((b) => b.equals(Buffer.from([0xde, 0xad]))));

  // 5. 群控广播：master 上游字节 -> 同组 receiver 的 TCP 连接
  const recvWs = new WebSocket(`${wsUrl}&grp=wall1`);
  await new Promise((res, rej) => { recvWs.on('open', res); recvWs.on('error', rej); });
  await waitFor(() => fake.connections.size >= 2);
  const masterWs = new WebSocket(`${wsUrl}&grp=wall1&broadcast=1`);
  await new Promise((res, rej) => { masterWs.on('open', res); masterWs.on('error', rej); });
  await waitFor(() => fake.connections.size >= 3);

  const conns = [...fake.connections];
  const recvConn = conns.find((c) => c !== conn);
  const masterConn = conns.find((c) => c !== conn && c !== recvConn);
  recvConn.received = [];
  masterConn.received = [];

  const bcast = Buffer.from([0xaa, 0xbb, 0xcc]);
  masterWs.send(bcast);
  await waitFor(() => Buffer.concat(recvConn.received).length >= 3);
  check('broadcast reaches same-group receiver', Buffer.concat(recvConn.received).equals(bcast));

  const masterGot = Buffer.concat(masterConn.received);
  let count = 0;
  for (let i = 0; i + bcast.length <= masterGot.length; i++) {
    if (masterGot.subarray(i, i + bcast.length).equals(bcast)) count++;
  }
  check('master only gets its own echo (no self-broadcast)', count === 1, `count=${count}`);

  ws.close(); recvWs.close(); masterWs.close();
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
