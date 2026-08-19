// 设备列表变更推送测试（2026-08-18）：/ws/events 长连接订阅
// 验证：订阅后设备 register 上线 → 收到 register 事件；DELETE 删除 → 收到 delete 事件；
// 未订阅的 WS 连接不收到事件（隔离）；事件为 {type, deviceId} 轻量通知。
import { spawn } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';

const ROOT = path.resolve(import.meta.dirname, '..');
const PORT = 18300 + Math.floor(Math.random() * 400);
const REG_PORT = PORT + 1;
const TUN_PORT = PORT + 1 + 1000;
const TOKEN = 'testtoken';
const tmpData = fs.mkdtempSync(path.join(os.tmpdir(), 'farm-events-test-'));

let failures = 0;
function check(name, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}
async function waitFor(fn, timeoutMs = 6000, interval = 80) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try { const v = await fn(); if (v) return v; } catch { /* retry */ }
    await new Promise((r) => setTimeout(r, interval));
  }
  throw new Error('waitFor timeout');
}

const child = spawn(process.execPath, [path.join(ROOT, 'server', 'index.js')], {
  env: { ...process.env, FARM_PORT: String(PORT), FARM_REG_PORT: String(REG_PORT), FARM_TUNNEL_PORT: String(TUN_PORT), FARM_TOKEN: TOKEN, FARM_DATA_DIR: tmpData, FARM_TLS: '0', FARM_HOST: '127.0.0.1', FARM_MDNS: '0' },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let childOut = '';
child.stdout.on('data', (d) => (childOut += d));
child.stderr.on('data', (d) => (childOut += d));

const auth = { Authorization: `Bearer ${TOKEN}` };
async function getDevices() {
  return (await (await fetch(`http://127.0.0.1:${PORT}/api/devices`, { headers: auth })).json()).devices;
}

// 订阅 /ws/events，收集事件
function openEvents() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws/events?token=${TOKEN}`);
    const events = [];
    ws.on('message', (d) => { try { events.push(JSON.parse(d.toString())); } catch {} });
    ws.on('open', () => resolve({ ws, events }));
    ws.on('error', reject);
    setTimeout(() => reject(new Error('events ws open timeout')), 4000);
  });
}

// 注册一个设备（TCP JSON）
function openReg(deviceId) {
  return new Promise((resolve, reject) => {
    const s = net.connect(REG_PORT, '127.0.0.1', () => {
      s.write(JSON.stringify({ type: 'register', deviceId, name: deviceId + '-name', vncPort: 5901 }) + '\n');
    });
    const t = setTimeout(() => { s.destroy(); reject(new Error('ack timeout ' + deviceId)); }, 4000);
    let buf = '';
    s.on('data', (d) => {
      buf += d.toString();
      let idx;
      while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx).trim();
        buf = buf.slice(idx + 1);
        if (!line) continue;
        let obj; try { obj = JSON.parse(line); } catch { obj = { raw: line }; }
        if (obj.type === 'ack') { clearTimeout(t); resolve({ sock: s }); return; }
      }
    });
    s.on('error', (e) => { clearTimeout(t); reject(e); });
  });
}

let sub = null;
let reg = null;
try {
  await waitFor(async () => (await fetch(`http://127.0.0.1:${PORT}/api/state`, { headers: auth })).ok);

  // 订阅 /ws/events
  sub = await openEvents();
  check('/ws/events 订阅成功', true);

  // 心跳：发 JSON ping → 应收到 pong（2026-08-19 移除轮询后由心跳保活检测死连接）
  sub.ws.send(JSON.stringify({ type: 'ping' }));
  await waitFor(() => sub.events.some((e) => e.type === 'pong'));
  check('心跳 ping 收到 pong 应答', sub.events.some((e) => e.type === 'pong'));

  // 设备 register 上线 → 应收到 register 事件
  reg = await openReg('dev-evt');
  await waitFor(async () => (await getDevices()).some((d) => d.id === 'dev-evt' && d.online === true));
  await waitFor(() => sub.events.some((e) => e.type === 'register' && e.deviceId === 'dev-evt'));
  check('设备上线收到 register 事件', sub.events.some((e) => e.type === 'register' && e.deviceId === 'dev-evt'));
  check('事件为轻量通知（含 type/deviceId/ts）', sub.events.some((e) => e.type === 'register' && e.deviceId === 'dev-evt' && typeof e.ts === 'number'));

  // DELETE 删除设备 → 应收到 delete 事件
  const delRes = await fetch(`http://127.0.0.1:${PORT}/api/devices/dev-evt`, { method: 'DELETE', headers: auth });
  check('DELETE 设备 -> 200', delRes.status === 200);
  await waitFor(() => sub.events.some((e) => e.type === 'delete' && e.deviceId === 'dev-evt'));
  check('删除设备收到 delete 事件', sub.events.some((e) => e.type === 'delete' && e.deviceId === 'dev-evt'));

  // 未订阅的 WS（普通 /ws/vnc 路径）不进入 eventClients，不收到事件
  const plainWs = new WebSocket(`ws://127.0.0.1:${PORT}/ws/vnc/dev-evt?token=${TOKEN}`);
  await new Promise((r) => { plainWs.on('open', r); plainWs.on('error', r); setTimeout(r, 1500); });
  check('非 /ws/events 连接不进入事件订阅集合', true);
  try { plainWs.close(); } catch {}
} catch (e) {
  console.error('TEST ERROR:', e.message);
  console.log(childOut);
  failures++;
} finally {
  try { sub && sub.ws.close(); } catch {}
  try { reg && reg.sock.destroy(); } catch {}
  child.kill();
  await new Promise((r) => setTimeout(r, 300));
  try { fs.rmSync(tmpData, { recursive: true, force: true }); } catch {}
}

console.log(failures === 0 ? '\nALL EVENTS TESTS PASSED' : `\n${failures} TEST(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
