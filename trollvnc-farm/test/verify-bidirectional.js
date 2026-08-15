/**
 * 双向链路验证（ctrl 会话）：证明网关隧道 WS↔设备 双向 FT_DATA 转发均正常。
 * 模拟设备：注册+隧道；模拟客户端：ctrl WS 会话。
 * 1) 客户端发 RFB 版本选择 → 隧道侧应收到 FT_DATA(payload=[0x01])
 * 2) 隧道侧回传模拟安全类型 → 客户端 WS 应收到
 * 3) 第二次客户端→隧道 → 再次确认（排除竞态）
 */
import net from 'net';
import { WebSocket } from 'ws';

const HOST = '127.0.0.1';
const REG_PORT = 18081;
const TUN_PORT = 18181;
const WS_PORT = 8080;
const DEVICE_ID = 'E2E-BI-' + Date.now().toString(36);

let pass = 0, fail = 0;
const check = (n, c, d = '') => { if (c) { pass++; console.log(`  PASS  ${n} ${d}`); } else { fail++; console.log(`  FAIL  ${n} ${d}`); } };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// 1. 注册
const regSock = net.connect(REG_PORT, HOST);
await new Promise((res, rej) => { regSock.once('connect', res); regSock.once('error', rej); });
regSock.write(JSON.stringify({ type: 'register', deviceId: DEVICE_ID, name: 'E2E-Bi', vncPort: 5901 }) + '\n');

// 2. 隧道 + 帧解析
const tunSock = net.connect(TUN_PORT, HOST);
await new Promise((res, rej) => { tunSock.once('connect', res); tunSock.once('error', rej); });
let framed = false;
let preFrame = Buffer.alloc(0);
let frameBuf = Buffer.alloc(0);
const frames = [];
const waiters = [];
// FT_CMD(type=4) 帧的 cmd 字段解析
const parseCmd = (f) => { try { return f.type === 4 ? JSON.parse(f.payload.toString('utf8')).cmd : null; } catch { return null; } };
// 按帧类型等待（FT_DATA 等非命令帧）
const waitFrame = (type) => new Promise((res) => {
  const i = frames.findIndex((f) => f.type === type);
  if (i >= 0) { res(frames.splice(i, 1)[0].payload); return; }
  waiters.push({ type, res });
});
// 按命令名等待 FT_CMD 帧（支持缓存帧优先匹配）
const waitCmd = (cmd) => new Promise((res) => {
  const i = frames.findIndex((f) => parseCmd(f) === cmd);
  if (i >= 0) { res(frames.splice(i, 1)[0].payload); return; }
  waiters.push({ cmd, res });
});
// 等待器双模式匹配：type 模式匹配帧类型；cmd 模式匹配 FT_CMD 命令名
const matchWaiter = (w, f) => {
  if (w.type !== undefined) return f.type === w.type;
  const cmd = parseCmd(f);
  return cmd !== null && w.cmd === cmd;
};
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
    const wi = waiters.findIndex((w) => matchWaiter(w, f));
    if (wi >= 0) waiters.splice(wi, 1)[0].res(payload);
    else frames.push(f);
    // 模拟设备：FT_CMD(rfb.start/stop) 自动回 ack（echo id, ok:true），
    // 网关 ack 驱动据此精确放行缓冲的握手字节
    const cmd = parseCmd(f);
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
check('1 隧道建立', framed);

// 3. ctrl WS 会话（首会话：先 rfb.stop 再 rfb.start 重建，全新握手）
const ws = new WebSocket(`ws://${HOST}:${WS_PORT}/ws/vnc/${DEVICE_ID}?ctrl=1`);
await new Promise((res, rej) => { ws.on('open', res); ws.on('error', rej); });
const stopCmd1 = await Promise.race([waitCmd('rfb.stop'), wait(4000).then(() => null)]);
const startFrame = await Promise.race([waitCmd('rfb.start'), wait(4000).then(() => null)]);
let startCmd = null;
try { startCmd = startFrame ? JSON.parse(startFrame.toString('utf8')) : null; } catch { /* noop */ }
check('2 首会话触发 5901 重建 stop→start', !!stopCmd1 && !!startCmd && startCmd.cmd === 'rfb.start',
  startCmd ? startCmd.cmd : '无');

// 4. 客户端发版本选择(0x01) → 隧道应收到 FT_DATA
ws.send(Buffer.from([0x01]));
const up1 = await Promise.race([waitFrame(1), wait(4000).then(() => null)]);
check('3 客户端→隧道 FT_DATA 转发', !!up1 && up1.equals(Buffer.from([0x01])), up1 ? 'payload=0x' + up1.toString('hex') : '无');

// 5. 隧道回传安全类型(1+1=NoAuth) → 客户端应收到
const wsGot = new Promise((res) => ws.once('message', (d) => res(Buffer.from(d))));
const downPayload = Buffer.from([0x01, 0x01]);
const fh = Buffer.alloc(5);
fh[0] = 0x01;
fh.writeUInt32BE(downPayload.length, 1);
tunSock.write(fh);
tunSock.write(downPayload);
const down1 = await Promise.race([wsGot, wait(4000).then(() => null)]);
check('4 隧道→客户端 FT_DATA 转发', !!down1 && down1.equals(downPayload), down1 ? 'payload=0x' + down1.toString('hex') : '无');

// 6. 第二次客户端→隧道（排除竞态）
ws.send(Buffer.from([0x02]));
const up2 = await Promise.race([waitFrame(1), wait(4000).then(() => null)]);
check('5 二次客户端→隧道', !!up2 && up2.equals(Buffer.from([0x02])), up2 ? 'payload=0x' + up2.toString('hex') : '无');

// 7. 断开 → rfb.stop
const stopP = waitCmd('rfb.stop');
ws.close();
const stopFrame = await Promise.race([stopP, wait(4000).then(() => null)]);
let stopCmd = null;
try { stopCmd = stopFrame ? JSON.parse(stopFrame.toString('utf8')) : null; } catch { /* noop */ }
check('6 断开触发 rfb.stop', !!stopCmd && stopCmd.cmd === 'rfb.stop', stopCmd ? stopCmd.cmd : '无');

regSock.destroy();
tunSock.destroy();
console.log(`\n双向链路验证: ${pass} 通过, ${fail} 失败`);
process.exit(fail ? 1 : 0);
