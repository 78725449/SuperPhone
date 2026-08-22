/**
 * 端到端验证：黑屏修复 + on-demand RFB 引用计数 + 会话清理增强
 * 模拟设备：注册(18081) → 隧道(18181) → WS 会话(/ws/vnc/:id)
 * 覆盖（2026-08-10 会话增强）：
 *   1) 首个会话（含 viewOnly）触发设备 5901 重建：先 rfb.stop 再 rfb.start（全新握手，防 Invalid server version）
 *   2) FT_DATA 转发到 WS（wsSet 注册生效，黑屏根因）
 *   3) viewOnly 会话上行可转发（握手必需字节；只读由 noVNC 客户端保证）
 *   4) ctrl 会话在已有会话时无条件触发重建（唯一控制者语义，治愈"有时黑屏"）
 *   5) 末个会话断开触发 rfb.stop
 */
import net from 'net';
import { WebSocket } from 'ws';

const HOST = '127.0.0.1';
const REG_PORT = 18081;
const TUN_PORT = 18181;
const WS_PORT = 8080;
const DEVICE_ID = 'E2E-VERIFY-' + Date.now().toString(36);

let pass = 0, fail = 0;
const check = (name, cond, detail = '') => {
  if (cond) { pass++; console.log(`  PASS  ${name}  ${detail}`); }
  else { fail++; console.log(`  FAIL  ${name}  ${detail}`); }
};
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- 1. 注册通道（TCP 18081） ----------
const regSock = net.connect(REG_PORT, HOST);
await new Promise((res, rej) => { regSock.once('connect', res); regSock.once('error', rej); });
const regAckP = new Promise((res) => {
  let b = '';
  regSock.on('data', (c) => { b += c.toString('utf8'); const i = b.indexOf('\n'); if (i >= 0) res(b.slice(0, i)); });
});
regSock.write(JSON.stringify({ type: 'register', deviceId: DEVICE_ID, name: 'E2E-Test', vncPort: 5901 }) + '\n');
const ra = await Promise.race([regAckP, wait(4000).then(() => '')]);
check('1 注册 ack', ra.includes('"type":"ack"'), ra.slice(0, 80));

// ---------- 2. 隧道握手（TCP 18181，JSON 行 → 帧模式） ----------
const tunSock = net.connect(TUN_PORT, HOST);
await new Promise((res, rej) => { tunSock.once('connect', res); tunSock.once('error', rej); });
let framed = false;
let preFrame = Buffer.alloc(0);  // 握手阶段缓冲（字节流，避免 ack 行残留破坏帧解析）
let frameBuf = Buffer.alloc(0);
const frames = [];
const waiters = [];
// FT_CMD(type=4) 帧的 cmd 字段解析
const parseCmd = (f) => { try { return f.type === 4 ? JSON.parse(f.payload.toString('utf8')).cmd : null; } catch { return null; } };
// 按命令名等待 FT_CMD 帧（支持缓存帧优先匹配）
const waitCmd = (cmd) => new Promise((res) => {
  const i = frames.findIndex((f) => parseCmd(f) === cmd);
  if (i >= 0) { res(frames.splice(i, 1)[0].payload); return; }
  waiters.push({ cmd, res });
});
tunSock.on('data', (chunk) => {
  if (!framed) {
    preFrame = Buffer.concat([preFrame, chunk]);
    const nl = preFrame.indexOf(0x0a); // '\n'
    if (nl < 0) return;
    // 丢弃 tunnel_ack 行（含换行），其后字节全部视为帧数据（可能与 ack 同 chunk）
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
    // 模拟设备：FT_CMD(rfb.start/stop) 自动回 ack（echo id, ok:true），
    // 网关 ack 驱动据此精确放行缓冲的握手字节
    if (cmd === 'rfb.start' || cmd === 'rfb.stop') {
      let rid = null;
      try { rid = JSON.parse(payload.toString('utf8')).id; } catch { /* noop */ }
      const ackBuf = Buffer.from(JSON.stringify({ type: 'ack', cmd, id: rid, ok: true }));
      const ah = Buffer.alloc(5);
      ah[0] = 0x05; // FT_CMDACK
      ah.writeUInt32BE(ackBuf.length, 1);
      tunSock.write(ah);
      tunSock.write(ackBuf);
    }
  }
});
tunSock.write(JSON.stringify({ type: 'tunnel_hello', deviceId: DEVICE_ID }) + '\n');
for (let i = 0; i < 40 && !framed; i++) await wait(50);
check('2 隧道建立（进入帧模式）', framed, '');

// ---------- 3. 首个 WS 会话（viewOnly，验证不区分 ctrl） ----------
const wsUrl = `ws://${HOST}:${WS_PORT}/ws/vnc/${encodeURIComponent(DEVICE_ID)}`;
const ws1 = new WebSocket(wsUrl);
await new Promise((res, rej) => { ws1.on('open', res); ws1.on('error', rej); });
console.log('  ...WS(viewOnly) 已连接，等待 5901 重建（rfb.start）');
const start1 = await Promise.race([waitCmd('rfb.start'), wait(4000).then(() => null)]);
check('3 首会话（viewOnly）触发 5901 重建 rfb.start', !!start1,
  `${start1 ? 'start' : '无start'}`);

// ---------- 4. 设备回传 RFB 字节，WS 应收到（黑屏根因验证） ----------
const rfbBytes = Buffer.from('RFB 003.008\n\x00\x00\x01\x00', 'latin1');
const ws1Got = new Promise((res) => { ws1.on('message', (d) => res(Buffer.from(d))); });
const fh = Buffer.alloc(5);
fh[0] = 0x01; // FT_DATA
fh.writeUInt32BE(rfbBytes.length, 1);
tunSock.write(fh);
tunSock.write(rfbBytes);
const ws1Data = await Promise.race([ws1Got, wait(4000).then(() => null)]);
check('4 FT_DATA 转发到 WS（wsSet 注册生效）', !!ws1Data && ws1Data.equals(rfbBytes), ws1Data ? '收到字节=' + ws1Data.length : '未收到');

// ---------- 5. viewOnly 会话上行可转发（握手必需字节；viewOnly 只读由 noVNC 客户端保证） ----------
const dataFramesBefore = frames.filter((f) => f.type === 1).length;
ws1.send(Buffer.from('fake input from viewOnly'));
await wait(300);
const dataFramesAfter = frames.filter((f) => f.type === 1).length;
check('5 viewOnly 会话上行转发到隧道（握手兼容）', dataFramesAfter === dataFramesBefore + 1, `隧道侧FT_DATA数=${dataFramesAfter}`);

// ---------- 6. ctrl 会话进入（已有 viewOnly 会话）→ 无条件重建 ----------
console.log('  ...WS(ctrl) 已连接，验证非首会话也触发重建');
const ws2 = new WebSocket(`${wsUrl}?ctrl=1`);
await new Promise((res, rej) => { ws2.on('open', res); ws2.on('error', rej); });
const start2 = await Promise.race([waitCmd('rfb.start'), wait(4000).then(() => null)]);
check('6 ctrl 会话无条件重建（非首会话仍 rfb.start）', !!start2,
  `${start2 ? 'start' : '无start'}`);

// ---------- 7. 关闭全部会话 -> rfb.stop ----------
const stopP = waitCmd('rfb.stop');
ws1.close();
ws2.close();
const stopFrame = await Promise.race([stopP, wait(4000).then(() => null)]);
let stopCmd = null;
try { stopCmd = stopFrame ? JSON.parse(stopFrame.toString('utf8')) : null; } catch { /* noop */ }
check('7 末会话断开触发 rfb.stop', !!stopCmd && stopCmd.cmd === 'rfb.stop', stopCmd ? stopCmd.cmd : '无帧');

// ---------- 8. 清理 ----------
regSock.destroy();
tunSock.destroy();
console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
process.exit(fail ? 1 : 0);
