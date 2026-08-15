// P0 注册/心跳/能力清单/命令通道 冒烟测试（单通道：TCP JSON 18081；WS 注册端点已废弃）
import { spawn } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';

const ROOT = path.resolve(import.meta.dirname, '..');
const PORT = 18200 + Math.floor(Math.random() * 400);
const REG_PORT = PORT + 1;
const TUN_PORT = PORT + 1 + 1000;
const TOKEN = 'testtoken';
const tmpData = fs.mkdtempSync(path.join(os.tmpdir(), 'farm-reg-test-'));

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
  env: { ...process.env, FARM_PORT: String(PORT), FARM_REG_PORT: String(REG_PORT), FARM_TUNNEL_PORT: String(TUN_PORT), FARM_TOKEN: TOKEN, FARM_DATA_DIR: tmpData, FARM_TLS: '0', FARM_HOST: '127.0.0.1' },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let childOut = '';
child.stdout.on('data', (d) => (childOut += d));
child.stderr.on('data', (d) => (childOut += d));

const auth = { Authorization: `Bearer ${TOKEN}` };
async function getDevices() {
  return (await (await fetch(`http://127.0.0.1:${PORT}/api/devices`, { headers: auth })).json()).devices;
}

const MANIFEST = {
  configs: {
    scale: 1.0, frameRateSpec: '60', port: 5901, httpPort: 5801,
    bonjourEnabled: true, orientationSync: true, naturalScroll: true, keepAliveSec: 0,
    hasPassword: false, hasViewOnlyPassword: false, viewOnly: false,
    clipboardEnabled: true, reverseMode: 'none',
  },
  screen: { width: 1170, height: 2532 },
  httpPort: 5801,
};

// 带读器的注册连接：返回 { sock, lines }（收集服务端下发消息，含 cmd）
function openReg(deviceId, extra = {}) {
  return new Promise((resolve, reject) => {
    const s = net.connect(REG_PORT, '127.0.0.1', () => {
      const msg = Object.assign({ type: 'register', deviceId, name: deviceId + '-name', vncPort: 5901 }, extra);
      s.write(JSON.stringify(msg) + '\n');
    });
    const lines = [];
    let buf = '';
    const t = setTimeout(() => { s.destroy(); reject(new Error('ack timeout for ' + deviceId)); }, 4000);
    s.on('data', (d) => {
      buf += d.toString();
      let idx;
      while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx).trim();
        buf = buf.slice(idx + 1);
        if (!line) continue;
        let obj; try { obj = JSON.parse(line); } catch { obj = { raw: line }; }
        lines.push(obj);
        if (obj.type === 'cmd') {
          // 模拟真实手机（宪法 7.4）：收到命令立即回 ack
          try { s.write(JSON.stringify({ type: 'ack', cmd: obj.cmd, id: obj.id, ok: true }) + '\n'); } catch (e) {}
        }
        if (obj.type === 'ack') { clearTimeout(t); resolve({ sock: s, lines }); return; }
      }
    });
    s.on('error', (e) => { clearTimeout(t); reject(e); });
  });
}

let c1 = null;
let c2 = null;
try {
  await waitFor(async () => (await fetch(`http://127.0.0.1:${PORT}/api/state`, { headers: auth })).ok);
  check('网关启动 + mDNS 发布不报错', childOut.includes('publishing _superphone-farm'));
  check('TCP 注册监听已启动', childOut.includes('registration TCP listener'));

  // === 单通道：/ws/register 不再可用（非 /ws/vnc 路径被拒）===
  const wsCode = await new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws/register?deviceId=dev-ws&token=${TOKEN}`);
    ws.on('close', (code) => resolve(code));
    ws.on('error', () => {});
    setTimeout(() => resolve(null), 3000);
  });
  check('WS 注册端点已废弃（被拒 4000）', wsCode === 4000, 'code=' + wsCode);

  // === TCP 注册（含能力清单）===
  c1 = await openReg('dev-tcp', { ...MANIFEST, capabilities: ['home', 'power'], capMetadata: [{ id: 'home' }], configSchema: [{ key: 'Scale' }] });
  await waitFor(async () => {
    const d = (await getDevices()).find((x) => x.id === 'dev-tcp');
    return d && d.online === true && d.screen && d.screen.width === 1170;
  });
  const tcpDev = (await getDevices()).find((d) => d.id === 'dev-tcp');
  check('TCP 注册 ACK 返回', c1.lines.some((l) => l.type === 'ack' && l.deviceId === 'dev-tcp'));
  check('TCP 设备以 register 登记', tcpDev && tcpDev.source === 'register' && tcpDev.name === 'dev-tcp-name');
  check('能力字段被网关剥离（不入库）', tcpDev && tcpDev.capabilities === undefined && tcpDev.capMetadata === undefined && tcpDev.configSchema === undefined);
  check('清单已入库：configs', tcpDev && tcpDev.configs && tcpDev.configs.httpPort === 5801 && tcpDev.configs.scale === 1.0);
  check('清单已入库：screen(1170x2532)', tcpDev && tcpDev.screen && tcpDev.screen.width === 1170 && tcpDev.screen.height === 2532);
  check('清单已入库：httpPort', tcpDev && tcpDev.httpPort === 5801);

  // GET /api/devices/:id 完整详情
  const detail = await (await fetch(`http://127.0.0.1:${PORT}/api/devices/dev-tcp`, { headers: auth })).json();
  check('GET /api/devices/:id 返回连接信息且能力字段剥离', detail.device && detail.device.id === 'dev-tcp' && detail.device.online === true && detail.device.capabilities === undefined && typeof detail.device.configs === 'object');

  // === 命令通道：invoke（网关等待设备 ack，ack 回传）===
  const cmdRes = await fetch(`http://127.0.0.1:${PORT}/api/devices/dev-tcp/invoke`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({ cap: 'home' }),
  });
  check('POST invoke home -> 200（等 ack）', cmdRes.status === 200);
  const cmdJson = await cmdRes.json();
  check('ack 回传 ok=true', cmdJson && cmdJson.ack && cmdJson.ack.ok === true);
  check('设备收到 {"type":"cmd","cmd":"invoke","cap":"home"}', c1.lines.some((l) => l.type === 'cmd' && l.cmd === 'invoke' && l.cap === 'home'));

  // 不 ack 的手机 → 超时 504
  const silentSock = net.connect(REG_PORT, '127.0.0.1', () => {
    silentSock.write(JSON.stringify({ type: 'register', deviceId: 'dev-silent', name: 'SilentPhone', vncPort: 5902 }) + '\n');
  });
  await waitFor(async () => (await getDevices()).some((d) => d.id === 'dev-silent' && d.online === true));
  const toRes = await fetch(`http://127.0.0.1:${PORT}/api/devices/dev-silent/invoke`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({ cap: 'home', timeout: 1000 }),
  });
  check('不 ack 设备 invoke -> 504（超时）', toRes.status === 504);
  try { silentSock.destroy(); } catch (e) {}

  const setRes = await fetch(`http://127.0.0.1:${PORT}/api/devices/dev-tcp/configs`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({ Scale: 0.8 }),
  });
  check('configs set（宪法 7.4 已支持）-> 200', setRes.status === 200);
  const setJson = await setRes.json();
  check('set ack ok=true', setJson && setJson.results && setJson.results.Scale && setJson.results.Scale.ok === true);
  check('设备收到 {"type":"cmd","cmd":"set","key":"Scale"}', c1.lines.some((l) => l.type === 'cmd' && l.cmd === 'set' && l.key === 'Scale'));

  // 断开 -> 离线；离线后 invoke -> 504
  c1.sock.destroy();
  await waitFor(async () => (await getDevices()).some((d) => d.id === 'dev-tcp' && d.online === false));
  check('TCP 断开后判离线', true);
  const offCmd = await fetch(`http://127.0.0.1:${PORT}/api/devices/dev-tcp/invoke`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({ cap: 'home', timeout: 1000 }),
  });
  check('离线设备 invoke -> 504（发送失败/ack 超时）', offCmd.status === 504);

  // === TCP hello 保活 ===
  c2 = await openReg('dev-tcp2', {});
  c2.sock.write(JSON.stringify({ type: 'hello' }) + '\n');
  await waitFor(async () => (await getDevices()).some((d) => d.id === 'dev-tcp2' && d.online === true));
  check('TCP hello 保活在线', true);
  c2.sock.destroy();
  await waitFor(async () => (await getDevices()).some((d) => d.id === 'dev-tcp2' && d.online === false));
  check('TCP 断开后判离线（dev-tcp2）', true);

  // 批量端点可达性（2026-08-13 修复：batch 分支先于单设备 findDevice 拦截，否则 id='batch' 会 404）
  const bInvoke = await fetch(`http://127.0.0.1:${PORT}/api/devices/batch/invoke`, {
    method: 'POST', headers: auth,
    body: JSON.stringify({ deviceIds: ['dev-tcp'], cap: 'home' }),
  });
  check('批量 invoke 端点可达（非 404）', bInvoke.status === 200, 'status=' + bInvoke.status);
  const bCfg = await fetch(`http://127.0.0.1:${PORT}/api/devices/batch/configs`, {
    method: 'POST', headers: auth,
    body: JSON.stringify({ deviceIds: ['dev-tcp'], configs: { Scale: 1.0 } }),
  });
  check('批量 configs 端点可达（非 404）', bCfg.status === 200, 'status=' + bCfg.status);
  const bIds = await fetch(`http://127.0.0.1:${PORT}/api/devices/batch/invoke`, {
    method: 'POST', headers: auth,
    body: JSON.stringify({ cap: 'home' }),
  });
  check('批量 invoke 缺 deviceIds -> 400', bIds.status === 400, 'status=' + bIds.status);
} catch (e) {
  console.error('TEST ERROR:', e.message);
  console.log(childOut);
  failures++;
} finally {
  try { c1 && c1.sock.destroy(); } catch {}
  try { c2 && c2.sock.destroy(); } catch {}
  child.kill();
  await new Promise((r) => setTimeout(r, 300));
  try { fs.rmSync(tmpData, { recursive: true, force: true }); } catch {}
}

console.log(failures === 0 ? '\nALL REGISTER TESTS PASSED' : `\n${failures} TEST(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
