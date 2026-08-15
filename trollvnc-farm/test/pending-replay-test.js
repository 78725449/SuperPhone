/**
 * 复现/回归测试：会话退出后重进，网关不得把旧会话残留数据（tun.pending）补发给新会话
 * 背景：退出会话 A 时 rfb.stop 延迟 800ms 下发，期间设备 5901 旧连接仍在推最后几帧
 *       → 网关 wsSet.size==0 缓冲到 tun.pending；重进会话 B 时 handleVncSocket 把
 *       tun.pending 直接 ws.send 给新 noVNC → noVNC 当版本响应解析 → "Invalid server version" 黑屏。
 * 验证点：
 *   1) 会话 B 建立后不得收到会话 A 的残留数据（旧帧 = 乱码源头）
 *   2) 会话 B 重建（rfb.start ack）后，设备推的新数据正常转发
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

let regSock, tunSock, framed = false;
let preFrame = Buffer.alloc(0), frameBuf = Buffer.alloc(0);
const frames = [], waiters = [];
const parseCmd = (f) => { try { return f.type === 4 ? JSON.parse(f.payload.toString('utf8')).cmd : null; } catch { return null; } };
const waitCmd = (cmd) => new Promise((res) => {
  const i = frames.findIndex((f) => parseCmd(f) === cmd);
  if (i >= 0) { res(frames.splice(i, 1)[0].payload); return; }
  waiters.push({ cmd, res });
});
const sendTunnelFrame = (type, payload) => {
  const h = Buffer.alloc(5);
  h[0] = type;
  h.writeUInt32BE(payload.length, 1);
  tunSock.write(h);
  tunSock.write(payload);
};
const ackRfb = (payload) => {
  let rid = null;
  try { rid = JSON.parse(payload.toString('utf8')).id; } catch { /* noop */ }
  const ackBuf = Buffer.from(JSON.stringify({ type: 'ack', cmd: parseCmd({ type: 4, payload }) || '', id: rid, ok: true }));
  const h = Buffer.alloc(5);
  h[0] = 0x05;
  h.writeUInt32BE(ackBuf.length, 1);
  tunSock.write(h);
  tunSock.write(ackBuf);
};

try {
  await waitFor(async () => (await fetch(`http://127.0.0.1:${PORT}/api/state`)).ok);
  check('网关启动', true);

  // 注册通道
  regSock = net.connect(REG_PORT, '127.0.0.1');
  await new Promise((res, rej) => { regSock.once('connect', res); regSock.once('error', rej); });
  regSock.write(JSON.stringify({ type: 'register', deviceId: DEVICE_ID, name: 'PendingTest', vncPort: 5901 }) + '\n');

  // 隧道握手 + 帧解析 + rfb.start/stop 自动 ack
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
      const cmd = parseCmd(f);
      const wi = waiters.findIndex((w) => (cmd !== null ? w.cmd === cmd : false));
      if (wi >= 0) waiters.splice(wi, 1)[0].res(payload);
      else frames.push(f);
      if (cmd === 'rfb.start' || cmd === 'rfb.stop') ackRfb(payload);
    }
  });
  tunSock.write(JSON.stringify({ type: 'tunnel_hello', deviceId: DEVICE_ID }) + '\n');
  for (let i = 0; i < 40 && !framed; i++) await wait(50);
  check('隧道建立', framed, '');

  const wsUrl = `ws://127.0.0.1:${PORT}/ws/vnc/${encodeURIComponent(DEVICE_ID)}`;

  // ---- 会话 A（ctrl）：正常建立 + 画面转发 ----
  const wsA = new WebSocket(`${wsUrl}?ctrl=1`);
  await new Promise((res, rej) => { wsA.on('open', res); wsA.on('error', rej); });
  const s1 = await Promise.race([waitCmd('rfb.stop'), wait(4000).then(() => null)]);
  const t1 = await Promise.race([waitCmd('rfb.start'), wait(4000).then(() => null)]);
  check('会话A 触发重建 stop→start', !!s1 && !!t1, '');
  const data1 = Buffer.from('RFB 003.008\n' + 'A'.repeat(16), 'latin1'); // 模拟画面帧
  const wsAFirst = firstMsg(wsA);
  sendTunnelFrame(0x01, data1);
  const got1 = await wsAFirst;
  check('会话A 收到画面帧', !!got1 && got1.equals(data1), got1 ? 'len=' + got1.length : '未收到');

  // ---- 退出会话 A ----
  wsA.close();
  await wait(100); // < 800ms：rfb.stop 尚未下发，旧连接仍在推帧

  // ---- 设备推旧连接残留帧（会话 A 的最后几帧）→ 网关应缓冲而非转发 ----
  const data2 = Buffer.from('OLD-LEFTOVER-FRAME-' + Date.now(), 'utf8'); // 旧残留数据（修复前会被补发给会话 B）
  sendTunnelFrame(0x01, data2);
  await wait(100);
  // 等 debounce 的 rfb.stop 到达设备（网关清理阶段结束）
  const debounceStop = await Promise.race([waitCmd('rfb.stop'), wait(3000).then(() => null)]);
  check('退出后 debounce rfb.stop 下发', !!debounceStop, '');

  // ---- 重进：会话 B（ctrl）----
  const wsB = new WebSocket(`${wsUrl}?ctrl=1`);
  await new Promise((res, rej) => { wsB.on('open', res); wsB.on('error', rej); });
  const wsBFirst = firstMsg(wsB, 600); // 600ms 观察窗口：修复前这里会立即收到 data2（乱码源头）
  const s2 = await Promise.race([waitCmd('rfb.stop'), wait(4000).then(() => null)]);
  const t2 = await Promise.race([waitCmd('rfb.start'), wait(4000).then(() => null)]);
  check('会话B 触发重建 stop→start', !!s2 && !!t2, '');
  const replay = await wsBFirst;
  check('会话B 未收到旧会话残留数据（pending 不补发）', !replay || !replay.equals(data2),
    replay ? '收到残留=' + replay.length + 'B' : '无残留数据');

  // ---- 重建完成（ack 已回）后，设备推新帧 → 会话 B 应正常收到 ----
  const data3 = Buffer.from('RFB 003.008\n' + 'B'.repeat(16), 'latin1');
  const wsBNew = firstMsg(wsB);
  sendTunnelFrame(0x01, data3);
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
