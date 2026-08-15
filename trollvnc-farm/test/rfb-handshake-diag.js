/**
 * RFB 完整握手诊断：模拟 noVNC 走大屏路径（/ws/vnc/:id?ctrl=1）
 * 逐步执行 RFB 003.008 握手，打印每步收/发，定位黑屏环节。
 * 只读诊断，不发送任何输入事件；验证后立即断开（触发 rfb.stop）。
 */
import { WebSocket } from 'ws';

const HOST = '127.0.0.1';
const WS_PORT = 8080;

// ---------- 拉取在线设备 ----------
const data = await (await fetch(`http://${HOST}:${WS_PORT}/api/devices`)).json();
const list = Array.isArray(data.devices) ? data.devices : data;
const dev = list.find((d) => d.online === true && d.source === 'register');
if (!dev) {
  console.log('FAIL  无在线注册设备');
  process.exit(1);
}
console.log(`设备: ${dev.name} (${dev.id}) host=${dev.host}:${dev.port}`);

// ---------- 连接（WS_URL 直连 / CTRL=0 viewOnly / 默认隧道 ctrl） ----------
const WS_URL = process.env.WS_URL;
const CTRL = process.env.CTRL !== '0';
let url, label;
if (WS_URL) {
  url = WS_URL;
  label = '直连模式';
} else if (CTRL) {
  url = `ws://${HOST}:${WS_PORT}/ws/vnc/${encodeURIComponent(dev.id)}?ctrl=1`;
  label = '隧道模式(ctrl)';
} else {
  url = `ws://${HOST}:${WS_PORT}/ws/vnc/${encodeURIComponent(dev.id)}`;
  label = '隧道模式(viewOnly)';
}
console.log(`连接(${label}): ${url}`);
const ws = new WebSocket(url);
await new Promise((res, rej) => { ws.on('open', res); ws.on('error', rej); });
console.log('WS 已连接（ctrl=1）');

// ---------- 消息接收队列 ----------
let buf = Buffer.alloc(0);
const steps = [];
const log = (s) => { steps.push(s); console.log(`  [${new Date().toISOString().slice(11, 19)}] ${s}`); };
const waitBytes = (n, timeout = 5000) => new Promise((resolve) => {
  const t0 = Date.now();
  const iv = setInterval(() => {
    if (buf.length >= n) {
      clearInterval(iv);
      const out = Buffer.from(buf.subarray(0, n));
      buf = buf.subarray(n);
      resolve(out);
    } else if (Date.now() - t0 > timeout) {
      clearInterval(iv);
      resolve(null);
    }
  }, 20);
});
ws.on('message', (d) => {
  const b = Buffer.from(d);
  buf = Buffer.concat([buf, b]);
  log(`WS 收到 ${b.length} 字节: ${b.toString('hex')}`);
});
ws.on('close', (code, reason) => log(`WS 断开 code=${code} reason=${reason}`));
ws.on('error', (e) => log(`WS 错误: ${e.message}`));

const hex = (b, n = 16) => b.length <= n ? b.toString('hex') : b.subarray(0, n).toString('hex') + '...';
let failed = false;
const check = (name, cond, detail = '') => {
  if (cond) log(`PASS ${name} ${detail}`);
  else { log(`FAIL ${name} ${detail}`); failed = true; }
};

// ---------- 1. 服务器版本行 ----------
const ver = await waitBytes(12);
check('1 服务器版本行', ver && ver.toString('latin1').includes('RFB'), ver ? JSON.stringify(ver.toString('latin1')) : '超时无数据');

// ---------- 2. 客户端版本选择 ----------
// libvncserver 读取 12 字节（sz_rfbProtocolVersionMsg），noVNC 发 1 字节会卡住服务器。
// 回显完整版本字符串 "RFB 003.008\n"（12 字节）测试。
const verResp = process.env.VER_RESP === '1byte'
  ? Buffer.from([0x08])
  : Buffer.from('RFB 003.008\n');
ws.send(verResp);
log(`发送版本响应: ${verResp.toString('hex')} (${verResp.length}字节)`);

// ---------- 3. 安全类型数组 ----------
const secCount = await waitBytes(1);
check('3 安全类型数', secCount !== null, secCount ? 'count=' + secCount[0] : '超时');
let secTypes = [];
if (secCount && secCount[0] > 0) {
  const sec = await waitBytes(secCount[0]);
  secTypes = [...(sec || [])];
  log(`安全类型: [${secTypes.join(',')}] (1=NoAuth)`);
}

// ---------- 4. 客户端选择安全类型（NoAuth=1） ----------
const hasNoAuth = secTypes.includes(1);
if (hasNoAuth) {
  ws.send(Buffer.from([0x01]));
  log('发送安全类型选择 0x01 (NoAuth)');
} else if (secTypes.length === 0) {
  // 服务器可能直接发 SecurityResult（VNC auth 无则直发）
  log('无安全类型列表，等待 SecurityResult');
} else {
  log(`WARN 无 NoAuth 选项，安全类型=${secTypes}（可能需要密码）`);
}

// ---------- 5. SecurityResult（4B big-endian, 0=OK） ----------
const secRes = await waitBytes(4);
check('5 SecurityResult', secRes !== null, secRes ? 'value=' + secRes.readUInt32BE(0) : '超时');

// ---------- 6. ServerInit（2B 宽 + 2B 高 + 4B 名字长 + 名字） ----------
// libvncserver 在 SecurityResult 后可能先收 ClientInit 再发 ServerInit，先发再等
log('先发 ClientInit(shared=0) 再等 ServerInit');
ws.send(Buffer.from([0x00]));
const initHead = await waitBytes(8);
if (initHead) {
  const w = initHead.readUInt16BE(0);
  const h = initHead.readUInt16BE(2);
  const nameLen = initHead.readUInt32BE(4);
  const name = await waitBytes(Math.min(nameLen, 512));
  log(`ServerInit: ${w}x${h} 名称=${name ? name.toString('utf8') : ''}`);
  check('6 ServerInit 分辨率', w > 0 && h > 0, `${w}x${h}`);

  // ---------- 7. ClientInit（1B shared=0） ----------
  ws.send(Buffer.from([0x00]));
  log('发送 ClientInit (shared=0)');

  // ---------- 8. 等待首帧数据（FramebufferUpdate 或 SetPixelFormat 等） ----------
  const t0 = Date.now();
  let got = false;
  while (Date.now() - t0 < 6000) {
    if (buf.length > 0) {
      const first = buf[0];
      log(`收到首条服务器消息 type=0x${first.toString(16)} (2=FramebufferUpdate, 0=SetPixelFormat, 1=ColourMapEntries, 2=fbUpdate, 255=Bell?) 数据字节=${buf.length}`);
      got = true;
      break;
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  check('8 收到服务器后续消息', got, got ? `首字节0x${buf[0]?.toString(16)}` : '6s 内无后续消息');
} else {
  check('6 ServerInit', false, '超时无 ServerInit');
}

// ---------- 清理 ----------
ws.close();
log(`断开（触发 rfb.stop）。握手${failed ? '失败' : '成功'}`);
console.log(`\n诊断结果: ${failed ? '握手失败' : '握手成功'}（若失败，黑屏根因在步骤 ${steps.filter(s => s.startsWith('FAIL')).map(s => s.slice(0, 20)).join(' / ') || '未知'}）`);
process.exit(failed ? 1 : 0);
