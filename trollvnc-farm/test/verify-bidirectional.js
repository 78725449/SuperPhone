/**
 * 双向链路验证（ctrl 会话，proto:2 通道复用）：证明网关隧道 WS↔设备 双向 CHAN_DATA 转发均正常。
 * 模拟设备：注册+隧道（proto:2）；模拟客户端：ctrl WS 会话（独立会话通道）。
 * 1) 客户端发 RFB 版本选择 → 隧道侧应收到 CHAN_DATA(chanId, [0x01])
 * 2) 隧道侧回传模拟安全类型 → 客户端 WS 应收到
 * 3) 第二次客户端→隧道 → 再次确认（排除竞态）
 * 4) 断开 → 网关下发 CHAN_CLOSE(chanId)
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

const FT_CHAN_OPEN = 0x08, FT_CHAN_ACK = 0x09, FT_CHAN_DATA = 0x0A, FT_CHAN_CLOSE = 0x0B;

// 1. 注册
const regSock = net.connect(REG_PORT, HOST);
await new Promise((res, rej) => { regSock.once('connect', res); regSock.once('error', rej); });
regSock.write(JSON.stringify({ type: 'register', deviceId: DEVICE_ID, name: 'E2E-Bi', vncPort: 5901 }) + '\n');

// 2. 隧道 + 帧解析（proto:2，自动应答 CHAN_OPEN）
const tunSock = net.connect(TUN_PORT, HOST);
await new Promise((res, rej) => { tunSock.once('connect', res); tunSock.once('error', rej); });
let framed = false;
let preFrame = Buffer.alloc(0);
let frameBuf = Buffer.alloc(0);
const frames = [];
const waiters = [];
// 按帧类型等待（CHAN_OPEN/CHAN_DATA/CHAN_CLOSE 等）；可选 filt 过滤（如跳过 chan 0 缩略图 OPEN）
const waitFrame = (type, filt) => new Promise((res) => {
  const i = frames.findIndex((f) => f.type === type && (!filt || filt(f.payload)));
  if (i >= 0) { res(frames.splice(i, 1)[0].payload); return; }
  waiters.push({ type, filt, res });
});
const chanIdOf = (payload) => (payload && payload.length >= 2 ? payload.readUInt16BE(0) : null);
const matchWaiter = (w, f) => w.type === f.type && (!w.filt || w.filt(f.payload));
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
    // 模拟设备：CHAN_OPEN 自动回 CHAN_ACK ok（connect 5901 成功）
    if (type === FT_CHAN_OPEN && payload.length >= 3) {
      const ack = Buffer.from([payload[0], payload[1], 1]);
      const ah = Buffer.alloc(5);
      ah[0] = FT_CHAN_ACK;
      ah.writeUInt32BE(ack.length, 1);
      tunSock.write(ah);
      tunSock.write(ack);
    }
  }
});
tunSock.write(JSON.stringify({ type: 'tunnel_hello', deviceId: DEVICE_ID, proto: 2 }) + '\n');
for (let i = 0; i < 40 && !framed; i++) await wait(50);
check('1 隧道建立（proto:2）', framed);

// 3. ctrl WS 会话（通道生命周期）：网关发 CHAN_OPEN（会话通道）→ 自动 ack 后放行
// 网关 8080 为 HTTPS（自签证书），wss + rejectUnauthorized:false
const ws = new WebSocket(`wss://${HOST}:${WS_PORT}/ws/vnc/${DEVICE_ID}?ctrl=1`, { rejectUnauthorized: false });
await new Promise((res, rej) => { ws.on('open', res); ws.on('error', rej); });
const openFrame = await Promise.race([waitFrame(FT_CHAN_OPEN, (p) => p.readUInt16BE(0) !== 0), wait(4000).then(() => null)]);
const chanId = chanIdOf(openFrame);
check('2 ctrl 会话收到 CHAN_OPEN（会话通道）', !!openFrame && chanId !== 0, chanId ? `chan=${chanId}` : '无');

// 4. 客户端发版本选择(0x01) → 隧道应收到 CHAN_DATA(chanId, [0x01])
ws.send(Buffer.from([0x01]));
const up1 = await Promise.race([waitFrame(FT_CHAN_DATA), wait(4000).then(() => null)]);
check('3 客户端→隧道 CHAN_DATA 转发', !!up1 && chanIdOf(up1) === chanId && up1.subarray(2).equals(Buffer.from([0x01])),
  up1 ? 'payload=0x' + up1.subarray(2).toString('hex') : '无');

// 5. 隧道回传安全类型(1+1=NoAuth) → 客户端应收到
const wsGot = new Promise((res) => ws.once('message', (d) => res(Buffer.from(d))));
const downPayload = Buffer.from([0x01, 0x01]);
const chanHdr = Buffer.alloc(2); chanHdr.writeUInt16BE(chanId, 0);
const downBody = Buffer.concat([chanHdr, downPayload]);
const fh = Buffer.alloc(5);
fh[0] = FT_CHAN_DATA;
fh.writeUInt32BE(downBody.length, 1);
tunSock.write(fh);
tunSock.write(downBody);
const down1 = await Promise.race([wsGot, wait(4000).then(() => null)]);
check('4 隧道→客户端 CHAN_DATA 转发', !!down1 && down1.equals(downPayload), down1 ? 'payload=0x' + down1.toString('hex') : '无');

// 6. 第二次客户端→隧道（排除竞态）
ws.send(Buffer.from([0x02]));
const up2 = await Promise.race([waitFrame(FT_CHAN_DATA), wait(4000).then(() => null)]);
check('5 二次客户端→隧道', !!up2 && chanIdOf(up2) === chanId && up2.subarray(2).equals(Buffer.from([0x02])),
  up2 ? 'payload=0x' + up2.subarray(2).toString('hex') : '无');

// 7. 断开 → 网关下发 CHAN_CLOSE(chanId)
const closeP = waitFrame(FT_CHAN_CLOSE);
ws.close();
const closeFrame = await Promise.race([closeP, wait(4000).then(() => null)]);
check('6 断开后网关下发 CHAN_CLOSE', !!closeFrame && chanIdOf(closeFrame) === chanId, closeFrame ? `chan=${chanIdOf(closeFrame)}` : '无');

regSock.destroy();
tunSock.destroy();
console.log(`\n双向链路验证: ${pass} 通过, ${fail} 失败`);
process.exit(fail ? 1 : 0);