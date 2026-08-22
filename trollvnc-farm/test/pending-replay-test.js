/**
 * 回归测试（proto:2 通道复用）：会话退出后重进，旧会话通道残留数据不得污染新会话
 * 背景：proto:1 时代会话 A 退出时 rfb.stop 延迟 800ms 下发，期间旧 5901 连接仍在推帧
 *       → 网关缓冲到 tun.pending；重进会话 B 时补发给新 noVNC → "Invalid server version" 黑屏。
 * proto:2 通道化后：每个会话独立通道（chanId），设备上行按 chanId 分发——会话 A 关闭后
 * 其通道即删，残留帧（设备仍推的旧通道数据）无订阅者被丢弃，天然隔离。
 * 验证点：
 *   1) 会话 A 建立（CHAN_OPEN→ACK）后收到画面帧
 *   2) 会话 A 关闭 → 网关下发 CHAN_CLOSE
 *   3) 会话 B 建立（新通道）后收到新帧；会话 A 通道的残留数据不发给会话 B
 */
import { spawn } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { WebSocket } from 'ws';

const ROOT = path.resolve(import.meta.dirname, '..');
const PORT = 19400 + Math.floor(Math.random() * 200);
const REG_PORT = PORT + 1;
const TUN_PORT = PORT + 1001;
const tmpData = fs.mkdtempSync(path.join(os.tmpdir(), 'farm-pending-test-'));
const DEVICE_ID = 'PENDING-' + Date.now().toString(36);

const child = spawn(process.execPath, [path.join(ROOT, 'server', 'index.js')], {
  env: { ...process.env, FARM_PORT: String(PORT), FARM_REG_PORT: String(REG_PORT), FARM_TUNNEL_PORT: String(TUN_PORT), FARM_DATA_DIR: tmpData, FARM_TLS: '0', FARM_HOST: '127.0.0.1' },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let childOut = '';
child.stdout.on('data', (d) => (childOut += d));
child.stderr.on('data', (d) => (childOut += d));

let pass = 0, fail = 0;
const check = (name, cond, detail = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? '  ' + detail : ''}`);
  if (!cond) fail++;
};
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn, timeoutMs = 6000, interval = 80) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try { const v = await fn(); if (v) return v; } catch { /* retry */ }
    await wait(interval);
  }
  throw new Error('waitFor timeout');
}
// 等待 WS 首条消息（Promise 一次性）
const firstMsg = (ws, timeoutMs = 4000) => new Promise((res) => {
  const t = setTimeout(() => { ws.off('message', onMsg); res(null); }, timeoutMs);
  const onMsg = (d) => { clearTimeout(t); res(Buffer.from(d)); };
  ws.on('message', onMsg);
});

const FT_CHAN_OPEN = 0x08, FT_CHAN_ACK = 0x09, FT_CHAN_DATA = 0x0A, FT_CHAN_CLOSE = 0x0B;
let regSock, tunSock, framed = false;
let preFrame = Buffer.alloc(0), frameBuf = Buffer.alloc(0);
const frames = [], waiters = [];
const chanOf = (f) => (f.type === FT_CHAN_DATA || f.type === FT_CHAN_CLOSE) && f.payload.length >= 2 ? f.payload.readUInt16BE(0) : null;
const waitChanOpen = () => new Promise((res) => {
  // 只匹配会话通道（chanId!=0；隧道建立时已有 chan 0 缩略图 OPEN）
  const i = frames.findIndex((f) => f.type === FT_CHAN_OPEN && f.payload.readUInt16BE(0) !== 0);
  if (i >= 0) { res(frames.splice(i, 1)[0]); return; }
  waiters.push({ kind: 'open', res });
});
const waitChanClose = () => new Promise((res) => {
  const i = frames.findIndex((f) => f.type === FT_CHAN_CLOSE);
  if (i >= 0) { res(frames.splice(i, 1)[0]); return; }
  waiters.push({ kind: 'close', res });
});
const sendTunnelFrame = (type, payload) => {
  const h = Buffer.alloc(5);
  h[0] = type;
  h.writeUInt32BE(payload.length, 1);
  tunSock.write(h);
  tunSock.write(payload);
};
const chanData = (chanId, data) => {
  const h = Buffer.alloc(2); h.writeUInt16BE(chanId, 0);
  return Buffer.concat([h, data]);
};
const ackChan = (payload) => {
  const ack = Buffer.from([payload[0], payload[1], 1]);
  sendTunnelFrame(FT_CHAN_ACK, ack);
};

try {
  await waitFor(async () => (await fetch(`http://127.0.0.1:${PORT}/api/state`)).ok);
  check('网关启动', true);

  // 注册通道
  regSock = net.connect(REG_PORT, '127.0.0.1');
  await new Promise((res, rej) => { regSock.once('connect', res); regSock.once('error', rej); });
  regSock.write(JSON.stringify({ type: 'register', deviceId: DEVICE_ID, name: 'PendingTest', vncPort: 5901 }) + '\n');

  // 隧道握手（proto:2）+ 帧解析 + CHAN_OPEN 自动 ack
  tunSock = net.connect(TUN_PORT, '127.0.0.1');
  await new Promise((res, rej) => { tunSock.once('connect', res); tunSock.once('error', rej); });
  tunSock.on('data', (chunk) => {
    if (!framed) {
      preFrame = Buffer.concat([preFrame, chunk]);
      const nl = preFrame.indexOf(0x0a);
      if (nl < 0) return;
      frameBuf = Buffer.from(preFrame.subarray(nl + 1));
      preFrame = Buffer.alloc(0);
      framed = true;
    } else {
      frameBuf = Buffer.concat([frameBuf, chunk]);
    }
    while (frameBuf.length >= 5) {
      const type = frameBuf[0];
      const len = frameBuf.readUInt32BE(1);
      if (frameBuf.length < 5 + len) break;
      const payload = Buffer.from(frameBuf.subarray(5, 5 + len));
      frameBuf = frameBuf.subarray(5 + len);
      const f = { type, payload };
      const wi = waiters.findIndex((w) => (w.kind === 'open' && f.type === FT_CHAN_OPEN && f.payload.readUInt16BE(0) !== 0) || (w.kind === 'close' && f.type === FT_CHAN_CLOSE));
      if (wi >= 0) waiters.splice(wi, 1)[0].res(f);
      else frames.push(f);
      if (type === FT_CHAN_OPEN && payload.length >= 3) ackChan(payload);
    }
  });
  tunSock.write(JSON.stringify({ type: 'tunnel_hello', deviceId: DEVICE_ID, proto: 2 }) + '\n');
  for (let i = 0; i < 40 && !framed; i++) await wait(50);
  check('隧道建立', framed, '');

  const wsUrl = `ws://127.0.0.1:${PORT}/ws/vnc/${encodeURIComponent(DEVICE_ID)}`;

  // ---- 会话 A（ctrl）：建立 + 画面转发 ----
  const wsA = new WebSocket(`${wsUrl}?ctrl=1`);
  await new Promise((res, rej) => { wsA.on('open', res); wsA.on('error', rej); });
  const openA = await Promise.race([waitChanOpen(), wait(4000).then(() => null)]);
  check('会话A 收到 CHAN_OPEN', !!openA, '');
  const chanA = openA ? openA.payload.readUInt16BE(0) : 0;
  const data1 = Buffer.from('RFB 003.008\n' + 'A'.repeat(16), 'latin1'); // 模拟画面帧
  const wsAFirst = firstMsg(wsA);
  sendTunnelFrame(FT_CHAN_DATA, chanData(chanA, data1));
  const got1 = await wsAFirst;
  check('会话A 收到画面帧', !!got1 && got1.equals(data1), got1 ? 'len=' + got1.length : '未收到');

  // ---- 退出会话 A：网关下发 CHAN_CLOSE ----
  wsA.close();
  const closeA = await Promise.race([waitChanClose(), wait(3000).then(() => null)]);
  check('会话A 关闭后网关下发 CHAN_CLOSE', !!closeA && chanOf(closeA) === chanA, '');

  // ---- 设备仍推旧通道残留帧（会话 A 的最后几帧）→ 按 chanId 分发，无订阅者被丢弃 ----
  const data2 = Buffer.from('OLD-LEFTOVER-FRAME-' + Date.now(), 'utf8');
  sendTunnelFrame(FT_CHAN_DATA, chanData(chanA, data2));
  await wait(100);

  // ---- 重进：会话 B（ctrl）----
  const wsB = new WebSocket(`${wsUrl}?ctrl=1`);
  await new Promise((res, rej) => { wsB.on('open', res); wsB.on('error', rej); });
  const wsBFirst = firstMsg(wsB, 600); // 600ms 观察窗口：修复前这里会立即收到 data2（乱码源头）
  const openB = await Promise.race([waitChanOpen(), wait(4000).then(() => null)]);
  check('会话B 收到 CHAN_OPEN', !!openB, '');
  const chanB = openB ? openB.payload.readUInt16BE(0) : 0;
  check('会话B 通道号不同于会话A', chanB !== chanA, `A=${chanA} B=${chanB}`);
  const replay = await wsBFirst;
  check('会话B 未收到旧会话残留数据（通道隔离）', !replay || !replay.equals(data2),
    replay ? '收到残留=' + replay.length + 'B' : '无残留数据');

  // ---- 会话 B 通道推新帧 → 正常收到 ----
  const data3 = Buffer.from('RFB 003.008\n' + 'B'.repeat(16), 'latin1');
  const wsBNew = firstMsg(wsB);
  sendTunnelFrame(FT_CHAN_DATA, chanData(chanB, data3));
  const got3 = await wsBNew;
  check('会话B 收到新画面帧', !!got3 && got3.equals(data3), got3 ? 'len=' + got3.length : '未收到');

  wsB.close();
} catch (e) {
  console.error('TEST ERROR:', e.message);
  console.log(childOut);
  fail++;
} finally {
  try { regSock && regSock.destroy(); } catch {}
  try { tunSock && tunSock.destroy(); } catch {}
  child.kill();
  await wait(300);
  try { fs.rmSync(tmpData, { recursive: true, force: true }); } catch {}
}

console.log(fail === 0 ? '\nALL PENDING-REPLAY TESTS PASSED' : `\n${fail} TEST(S) FAILED`);
process.exit(fail === 0 ? 0 : 1);