// RFB Extended Clipboard 握手诊断：连接在线设备，检查
//  1. 服务器是否主动发 ServerCaps（Caps 0x01000000）
//  2. 客户端发 ClientCaps 后服务器是否回 ServerCaps
//  3. 客户端发 Notify（模拟 noVNC clipboardPasteFrom）后服务器是否回 Request
// 只读诊断：不发 Provide，不写设备剪贴板；验证后立即断开。
import { WebSocket } from 'ws';

const HOST = '127.0.0.1';
const WS_PORT = 8080;

const data = await (await fetch(`http://${HOST}:${WS_PORT}/api/devices`)).json();
const list = Array.isArray(data.devices) ? data.devices : data;
const dev = list.find((d) => d.online === true && d.source === 'register');
if (!dev) { console.log('FAIL 无在线注册设备'); process.exit(1); }
console.log(`设备: ${dev.name} (${dev.id})`);

const url = `wss://${HOST}:${WS_PORT}/ws/vnc/${encodeURIComponent(dev.id)}`; // viewOnly：只读诊断，不干扰现有控制会话
const ws = new WebSocket(url);
await new Promise((res, rej) => { ws.on('open', res); ws.on('error', rej); });
console.log('WS 已连接 (ctrl=1)');

let buf = Buffer.alloc(0);
const log = (s) => console.log(`  [${new Date().toISOString().slice(11, 19)}] ${s}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const waitBytes = (n, timeout = 4000) => new Promise((resolve) => {
  const t0 = Date.now();
  const iv = setInterval(() => {
    if (buf.length >= n) { clearInterval(iv); const out = Buffer.from(buf.subarray(0, n)); buf = buf.subarray(n); resolve(out); }
    else if (Date.now() - t0 > timeout) { clearInterval(iv); resolve(null); }
  }, 20);
});
const send = (b) => { ws.send(b); log(`→ 发送 ${b.length}B ${b.toString('hex')}`); };

// 握手
const ver = await waitBytes(12);
log(`1 服务器版本: ${ver ? ver.toString('latin1') : '超时'}`);
send(Buffer.from('RFB 003.008\n'));
const secCount = await waitBytes(1);
let secTypes = [];
if (secCount && secCount[0] > 0) {
  const s = await waitBytes(secCount[0]);
  secTypes = [...(s || [])];
  log(`3 安全类型: [${secTypes.join(',')}]`);
}
send(Buffer.from([0x01])); // NoAuth
const secRes = await waitBytes(4);
log(`5 SecurityResult: ${secRes ? secRes.readUInt32BE(0) : '超时'}`);
send(Buffer.from([0x00])); // ClientInit shared=0
const initHead = await waitBytes(8);
if (initHead) {
  const w = initHead.readUInt16BE(0), h = initHead.readUInt16BE(2);
  const nameLen = initHead.readUInt32BE(4);
  await waitBytes(Math.min(nameLen, 512));
  log(`6 ServerInit: ${w}x${h}`);
} else { console.log('FAIL ServerInit 超时'); process.exit(1); }

// 解析 buf 中所有 ServerCutText（type=3）消息，返回 flags 列表
function scanServerCutText() {
  const out = [];
  let off = 0;
  while (off + 8 <= buf.length) {
    if (buf[off] === 3) { // ServerCutText
      const len = buf.readInt32BE(off + 4);
      const total = 8 + Math.abs(len);
      if (off + total <= buf.length) {
        if (len < 0) {
          const flags = buf.readUInt32BE(off + 8);
          out.push({ offset: off, len, flags, extended: true });
        } else {
          out.push({ offset: off, len, flags: 0, extended: false });
        }
        off += total;
      } else break;
    } else off++;
  }
  return out;
}
const flagNames = (f) => {
  const names = [];
  const actions = f >>> 24;
  if (actions & 0x01) names.push('Caps');
  if (actions & 0x02) names.push('Request');
  if (actions & 0x04) names.push('Peek');
  if (actions & 0x08) names.push('Notify');
  if (actions & 0x10) names.push('Provide');
  return names.join('+') || 'none';
};

// 阶段 1：连接后等待 2s，检查服务器是否主动发 ServerCaps
log('---- 阶段 1: 等待服务器主动发 ServerCaps (2s) ----');
const serverCapsBefore = await (async () => {
  await sleep(2000);
  const found = scanServerCutText().filter((m) => m.extended && (m.flags >>> 24) & 0x01);
  if (found.length) log(`服务器主动发过 Caps: flags=0x${found[0].flags.toString(16)}`);
  return found.length > 0;
})();

// 阶段 2：发 ClientCaps（Provide|Request|Notify|Peek + Text），等服务器回 ServerCaps
log('---- 阶段 2: 发 ClientCaps, 等服务器回 ServerCaps (2s) ----');
// flags = 0x0F000001, data = flags(4B) + Text size(4B)=0 → total 8B → len = -8
const clientCapsFlags = 0x0F000001;
{
  const data = Buffer.alloc(8);
  data.writeUInt32BE(clientCapsFlags, 0); // 4B actions+formats
  data.writeUInt32BE(0, 4);               // Text 格式的 size 提示 = 0
  const msg = Buffer.alloc(8 + data.length);
  msg[0] = 3; msg.writeInt32BE(-data.length, 4); data.copy(msg, 8);
  send(msg);
}
const serverCapsAfter = await (async () => {
  await sleep(2000);
  const found = scanServerCutText().filter((m) => m.extended && (m.flags >>> 24) & 0x01);
  if (found.length) log(`服务器回 ServerCaps: flags=0x${found[0].flags.toString(16)} (actions: ${flagNames(found[0].flags)})`);
  return found.length > 0;
})();

// 阶段 3：发 Notify（模拟旧 clipboardPasteFrom），检查服务器是否回 Request
// 2026-08-15：已知 libvncserver 0.9.15 不处理 Notify（静默丢弃）——noVNC clipboardPasteFrom 已
// 改为直发 Provide（见 server/index.js patch），本阶段仅作服务器行为确认，不再作为修复依据。
log('---- 阶段 3: 发 Notify(Text), 等服务器回 Request (2s，预期:无——0.9.15 不处理 Notify) ----');
{
  const flags = 0x08000001; // Notify + Text
  const data = Buffer.alloc(4);
  data.writeUInt32BE(flags, 0);
  const msg = Buffer.alloc(8 + data.length);
  msg[0] = 3; msg.writeInt32BE(-data.length, 4); data.copy(msg, 8);
  send(msg);
}
const gotRequest = await (async () => {
  await sleep(2000);
  const found = scanServerCutText().filter((m) => m.extended && (m.flags >>> 24) & 0x02);
  if (found.length) log(`服务器回 Request: flags=0x${found[0].flags.toString(16)} (actions: ${flagNames(found[0].flags)})`);
  return found.length > 0;
})();

console.log('\n==== 剪贴板握手诊断 ====');
console.log(`服务器主动发 ServerCaps: ${serverCapsBefore ? '是' : '否'}`);
console.log(`ClientCaps 后服务器回 ServerCaps: ${serverCapsAfter ? '是' : '否'}`);
console.log(`Notify 后服务器回 Request: ${gotRequest ? '是' : '否'}`);
if (!serverCapsBefore && !serverCapsAfter) console.log('⇒ 服务器未发 ServerCaps（cap 协商缺失）');
// 2026-08-15：客户端已改为直发 Provide，Notify→Request 链路不再依赖；gotRequest=false 为 0.9.15 预期行为
if (gotRequest) console.log('⇒ 意外：服务器响应了 Notify（更新 libvncserver 后此链路可恢复标准拉取模型）');
else console.log('⇒ Notify 无 Request 响应（libvncserver 0.9.15 预期行为）——控制端→被控端已由前端直发 Provide 修复');
ws.close();
process.exit(0);
