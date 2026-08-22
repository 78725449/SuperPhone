/**
 * 端到端验证（proto:2 通道复用）：多客户端并存 + 会话通道生命周期 + 通道隔离
 * 模拟设备：注册(18081) → 隧道(18181, proto:2) → WS 会话(/ws/vnc/:id)
 * 覆盖（2026-08-23 通道化）：
 *   1) 隧道握手后网关开 chan 0（缩略图通道）
 *   2) viewOnly 会话收到独立会话通道 CHAN_OPEN（不再需要「首会话重建」）
 *   3) 设备回传 RFB 字节（CHAN_DATA 按 chanId 分发）→ 对应 WS 收到（黑屏根因验证）
 *   4) viewOnly 会话上行可转发（握手必需字节；只读由 noVNC 客户端保证）
 *   5) ctrl 会话进入 → 新会话通道（viewOnly 不被顶，多客户端并存）
 *   6) 关闭会话 → 各自 CHAN_CLOSE
 */
import net from 'net';
import { WebSocket } from 'ws';

const HOST = '127.0.0.1';
const REG_PORT = 18081;
const TUN_PORT = 18181;
const WS_PORT = 8080;
const DEVICE_ID = 'E2E-VERIFY-' + Date.now().toString(36);

const FT_CHAN_OPEN = 0x08, FT_CHAN_ACK = 0x09, FT_CHAN_DATA = 0x0A, FT_CHAN_CLOSE = 0x0B;

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

// ---------- 2. 隧道握手（TCP 18181，proto:2，JSON 行 → 帧模式） ----------
const tunSock = net.connect(TUN_PORT, HOST);
await new Promise((res, rej) => { tunSock.once('connect', res); tunSock.once('error', rej); });
let framed = false;
let preFrame = Buffer.alloc(0);
let frameBuf = Buffer.alloc(0);
const frames = [];
const waiters = [];
// 按帧类型等待（可选 chanId 过滤；chanId!=0 表示会话通道）
const waitChan = (type, chanId = null) => new Promise((res) => {
  const i = frames.findIndex((f) => f.type === type && (chanId === null || f.payload.readUInt16BE(0) === chanId));
  if (i >= 0) { res(frames.splice(i, 1)[0].payload); return; }
  waiters.push({ type, chanId, res });
});
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
    const wi = waiters.findIndex((w) => w.type === f.type && (w.chanId === null || f.payload.readUInt16BE(0) === w.chanId));
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
check('2 隧道建立（进入帧模式）', framed, '');

// ---------- 2.5 隧道就绪即开 chan 0（缩略图通道） ----------
const thumbOpen = await Promise.race([waitChan(FT_CHAN_OPEN, 0), wait(4000).then(() => null)]);
check('2.5 隧道握手后网关开 chan 0（缩略图通道）', !!thumbOpen, thumbOpen ? `kind=${thumbOpen[2]}` : '无');

// ---------- 3. 首个 WS 会话（viewOnly）：独立会话通道 ----------
// 网关 8080 为 HTTPS（自签证书），wss + rejectUnauthorized:false
const wsUrl = `wss://${HOST}:${WS_PORT}/ws/vnc/${encodeURIComponent(DEVICE_ID)}`;
const ws1 = new WebSocket(wsUrl, { rejectUnauthorized: false });
await new Promise((res, rej) => { ws1.on('open', res); ws1.on('error', rej); });
const open1 = await Promise.race([waitChan(FT_CHAN_OPEN, null).then((p) => ({ chanId: p.readUInt16BE(0), kind: p[2] })), wait(4000).then(() => null)]);
check('3 viewOnly 会话收到会话通道 CHAN_OPEN（无重建语义）', !!open1 && open1.chanId !== 0, open1 ? `chan=${open1.chanId} kind=${open1.kind}` : '无');
const chan1 = open1 ? open1.chanId : 0;

// ---------- 4. 设备回传 RFB 字节（CHAN_DATA 按 chanId 分发），对应 WS 应收到 ----------
const rfbBytes = Buffer.from('RFB 003.008\n\x00\x00\x01\x00', 'latin1');
const ws1Got = new Promise((res) => { ws1.on('message', (d) => res(Buffer.from(d))); });
const chanHdr1 = Buffer.alloc(2); chanHdr1.writeUInt16BE(chan1, 0);
const body1 = Buffer.concat([chanHdr1, rfbBytes]);
const fh = Buffer.alloc(5);
fh[0] = FT_CHAN_DATA;
fh.writeUInt32BE(body1.length, 1);
tunSock.write(fh);
tunSock.write(body1);
const ws1Data = await Promise.race([ws1Got, wait(4000).then(() => null)]);
check('4 CHAN_DATA 按通道转发到对应 WS', !!ws1Data && ws1Data.equals(rfbBytes), ws1Data ? '收到字节=' + ws1Data.length : '未收到');

// ---------- 5. viewOnly 会话上行可转发（握手必需字节；viewOnly 只读由 noVNC 客户端保证） ----------
const chanDataFramesBefore = frames.filter((f) => f.type === FT_CHAN_DATA && f.payload.readUInt16BE(0) === chan1).length;
ws1.send(Buffer.from('fake input from viewOnly'));
await wait(300);
const chanDataFramesAfter = frames.filter((f) => f.type === FT_CHAN_DATA && f.payload.readUInt16BE(0) === chan1).length;
check('5 viewOnly 会话上行转发到隧道（通道通道）', chanDataFramesAfter === chanDataFramesBefore + 1, `隧道侧CHAN_DATA数=${chanDataFramesAfter}`);

// ---------- 6. ctrl 会话进入（已有 viewOnly 会话）→ 新独立通道，viewOnly 不被顶 ----------
const ws2 = new WebSocket(`${wsUrl}?ctrl=1`, { rejectUnauthorized: false });
await new Promise((res, rej) => { ws2.on('open', res); ws2.on('error', rej); });
const open2 = await Promise.race([waitChan(FT_CHAN_OPEN, null).then((p) => ({ chanId: p.readUInt16BE(0), kind: p[2] })), wait(4000).then(() => null)]);
check('6 ctrl 会话获得新会话通道（多客户端并存，viewOnly 保留）', !!open2 && open2.chanId !== 0 && open2.chanId !== chan1,
  open2 ? `ctrl chan=${open2.chanId} (viewOnly chan=${chan1})` : '无');
const ws1Alive = ws1.readyState === ws1.OPEN;
check('6b viewOnly 会话未被顶掉（4001 互斥随通道化消失）', ws1Alive);

// ---------- 7. 关闭全部会话 -> 各自 CHAN_CLOSE ----------
const closeP1 = waitChan(FT_CHAN_CLOSE, chan1);
const closeP2 = waitChan(FT_CHAN_CLOSE, open2 ? open2.chanId : -1);
ws1.close();
ws2.close();
const close1 = await Promise.race([closeP1, wait(4000).then(() => null)]);
const close2 = await Promise.race([closeP2, wait(4000).then(() => null)]);
check('7 会话关闭后网关下发各自 CHAN_CLOSE', !!close1 && !!close2,
  close1 && close2 ? `chan=${chan1}/${open2 ? open2.chanId : '?'}` : `close1=${!!close1} close2=${!!close2}`);

// ---------- 8. 清理 ----------
regSock.destroy();
tunSock.destroy();
console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
process.exit(fail ? 1 : 0);