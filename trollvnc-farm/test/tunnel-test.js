// 隧道通道复用测试（proto:2）：注册 -> 隧道 -> 会话通道（CHAN_OPEN/ACK/DATA/CLOSE）
// 覆盖：viewOnly 订阅、控制器输入、ctrl 抢占 4001、同步群控广播
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import WebSocket from 'ws';

const ROOT = path.resolve(import.meta.dirname, '..');
const PORT = 19080 + Math.floor(Math.random() * 400);
const REG_PORT = 19081 + Math.floor(Math.random() * 400);
const TUN_PORT = 19181 + Math.floor(Math.random() * 400);
const TOKEN = 'testtoken';
const tmpData = fs.mkdtempSync(path.join(os.tmpdir(), 'farm-tunnel-'));

let failures = 0;
function check(name, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}
async function waitFor(fn, timeoutMs = 6000, interval = 60) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try { const v = await fn(); if (v) return v; } catch { /* retry */ }
    await new Promise((r) => setTimeout(r, interval));
  }
  throw new Error('waitFor timeout');
}

const child = spawn(process.execPath, [path.join(ROOT, 'server', 'index.js')], {
  env: {
    ...process.env,
    FARM_PORT: String(PORT), FARM_REG_PORT: String(REG_PORT), FARM_TUNNEL_PORT: String(TUN_PORT),
    FARM_TOKEN: TOKEN, FARM_DATA_DIR: tmpData, FARM_TLS: '0', FARM_HOST: '127.0.0.1',
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let childOut = '';
child.stdout.on('data', (d) => (childOut += d));
child.stderr.on('data', (d) => (childOut += d));
const auth = { Authorization: `Bearer ${TOKEN}` };

// ---------- 与 server/index.js 对齐的隧道帧协议（proto:2）----------
const FT_CHAN_OPEN = 0x08, FT_CHAN_ACK = 0x09, FT_CHAN_DATA = 0x0A, FT_CHAN_CLOSE = 0x0B;
function encodeFrame(type, payload) {
  const buf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || []);
  const h = Buffer.alloc(5);
  h[0] = type; h.writeUInt32BE(buf.length, 1);
  return Buffer.concat([h, buf]);
}
const chanData = (chanId, data) => {
  const h = Buffer.alloc(2); h.writeUInt16BE(chanId, 0);
  return Buffer.concat([h, Buffer.isBuffer(data) ? data : Buffer.from(data)]);
};

/** 假设备：注册 + 隧道握手（proto:2）+ 帧解析 + 自动应答 CHAN_OPEN */
class FakeDevice {
  constructor(deviceId, name, vncPort) {
    this.deviceId = deviceId; this.name = name; this.vncPort = vncPort;
    this.regSock = null; this.tunSock = null;
    this.frameBuf = Buffer.alloc(0);
    this.frames = [];           // 收到的帧 {type, payload}
    this._waiters = [];
  }
  _tcp(port) {
    return new Promise((res, rej) => {
      const s = net.connect({ host: '127.0.0.1', port });
      s.once('connect', () => res(s));
      s.once('error', rej);
    });
  }
  async register() {
    this.regSock = await this._tcp(REG_PORT);
    this.regSock.write(JSON.stringify({ type: 'register', deviceId: this.deviceId, name: this.name, vncPort: this.vncPort }) + '\n');
    await new Promise((res) => {
      let buf = '';
      const onData = (d) => {
        buf += d.toString();
        const nl = buf.indexOf('\n');
        if (nl >= 0) { buf = ''; this.regSock.off('data', onData); res(); }
      };
      this.regSock.on('data', onData);
    });
  }
  async openTunnel() {
    this.tunSock = await this._tcp(TUN_PORT);
    this.tunSock.write(JSON.stringify({ type: 'tunnel_hello', deviceId: this.deviceId, proto: 2 }) + '\n');
    await new Promise((res, rej) => {
      let buf = '';
      const onData = (d) => {
        buf += d.toString();
        const nl = buf.indexOf('\n');
        if (nl >= 0) {
          const line = buf.slice(0, nl);
          const rest = buf.slice(nl + 1);
          this.tunSock.off('data', onData);
          try {
            const ack = JSON.parse(line);
            if (!ack.ok) return rej(new Error('tunnel_ack not ok'));
          } catch (e) { return rej(e); }
          if (rest.length) this._feed(Buffer.from(rest, 'utf8'));
          res();
        }
      };
      this.tunSock.on('data', onData);
    });
    this.tunSock.on('data', (d) => this._feed(d));
  }
  _feed(chunk) {
    this.frameBuf = Buffer.concat([this.frameBuf, chunk]);
    while (this.frameBuf.length >= 5) {
      const type = this.frameBuf[0];
      const len = this.frameBuf.readUInt32BE(1);
      if (this.frameBuf.length < 5 + len) break;
      const payload = this.frameBuf.subarray(5, 5 + len);
      const frame = { type, payload: Buffer.from(payload) };
      this.frames.push(frame);
      this.frameBuf = this.frameBuf.subarray(5 + len);
      for (const w of [...this._waiters]) w(frame);
      // 模拟设备：CHAN_OPEN 自动回 CHAN_ACK ok（connect 5901 成功）
      if (type === FT_CHAN_OPEN && payload.length >= 3) {
        const ack = Buffer.from([payload[0], payload[1], 1]);
        this.tunSock.write(encodeFrame(FT_CHAN_ACK, ack));
      }
    }
  }
  sendChanData(chanId, data) { this.tunSock.write(encodeFrame(FT_CHAN_DATA, chanData(chanId, data))); }
  nextFrame(type, timeoutMs = 4000) {
    return new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error('nextFrame timeout')), timeoutMs);
      const check = () => {
        const f = this.frames.find((x) => x.type === type);
        if (f) { clearTimeout(t); res(f); return true; }
        return false;
      };
      if (check()) return;
      const w = (frame) => { if (frame.type === type) { clearTimeout(t); this._waiters = this._waiters.filter((x) => x !== w); res(frame); } };
      this._waiters.push(w);
    });
  }
  close() { try { this.tunSock && this.tunSock.destroy(); } catch {} try { this.regSock && this.regSock.destroy(); } catch {} }
}

function wsConnect(url) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(url);
    ws.once('open', () => res(ws));
    ws.once('error', rej);
  });
}
function waitClose(ws, code) {
  return new Promise((res) => {
    ws.once('close', (c) => res(c === code));
  });
}

try {
  await waitFor(async () => {
    const r = await fetch(`http://127.0.0.1:${PORT}/api/state`, { headers: auth });
    return r.ok;
  });

  const d1 = new FakeDevice('dev-aaaa-0001', 'PhoneA', 5901);
  await d1.register();
  await waitFor(async () => {
    const r = await fetch(`http://127.0.0.1:${PORT}/api/devices`, { headers: auth });
    const j = await r.json();
    return j.devices.some((x) => x.id === d1.deviceId && x.source === 'register');
  });
  check('register -> device source=register', true);

  // 无隧道设备 WS 拒绝 4003（无直连回退）
  const addRes = await fetch(`http://127.0.0.1:${PORT}/api/devices`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({ name: 'NoTunnel', host: '127.0.0.1', port: 5999 }),
  });
  const noTunDev = (await addRes.json()).device;
  let noTunRejected = false;
  await new Promise((res) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws/vnc/${encodeURIComponent(noTunDev.id)}?token=${TOKEN}`);
    ws.on('close', (c) => { noTunRejected = c === 4003; res(); });
    ws.on('error', () => {});
    setTimeout(res, 1500);
  });
  check('no-tunnel WS rejected 4003 (no direct fallback)', noTunRejected);

  // 开隧道（proto:2）
  await d1.openTunnel();
  const baseWs = `ws://127.0.0.1:${PORT}/ws/vnc/${encodeURIComponent(d1.deviceId)}?token=${TOKEN}`;

  // viewOnly 会话：独立通道，设备上行 CHAN_DATA(chanId) -> WS
  const sub = await wsConnect(baseWs);
  const subGot = [];
  sub.on('message', (d) => subGot.push(Buffer.from(d)));
  // 等网关下发 CHAN_OPEN（会话通道，chanId!=0；隧道建立时已有 chan 0 缩略图 OPEN）并自动 ack 后，设备推数据
  await new Promise((r) => setTimeout(r, 300));
  const subChan = d1.frames.find((f) => f.type === FT_CHAN_OPEN && f.payload.readUInt16BE(0) !== 0);
  check('viewOnly session gets CHAN_OPEN', !!subChan);
  const subChanId = subChan ? subChan.payload.readUInt16BE(0) : 0;
  d1.sendChanData(subChanId, Buffer.from([0x01, 0x02, 0x03]));
  await waitFor(() => subGot.some((b) => b.equals(Buffer.from([0x01, 0x02, 0x03]))));
  check('viewOnly subscriber receives channel DATA', true);

  // viewOnly 上行转发到设备（握手必需字节；只读由 noVNC 客户端保证）
  d1.frames = [];
  sub.send(Buffer.from([0x99]));
  await new Promise((r) => setTimeout(r, 400));
  const upFrames = d1.frames.filter((f) => f.type === FT_CHAN_DATA && f.payload.readUInt16BE(0) === subChanId);
  check('viewOnly subscriber upstream forwarded to tunnel', upFrames.length === 1);

  // 控制器输入 -> 设备通道
  d1.frames = [];
  const ctrl = await wsConnect(`${baseWs}&ctrl=1`);
  await new Promise((r) => setTimeout(r, 300));
  const ctrlChan = d1.frames.find((f) => f.type === FT_CHAN_OPEN && f.payload.readUInt16BE(0) !== 0);
  const ctrlChanId = ctrlChan ? ctrlChan.payload.readUInt16BE(0) : 0;
  const ctrlFrameP = d1.nextFrame(FT_CHAN_DATA);
  ctrl.send(Buffer.from([0x10, 0x20]));
  const got = await ctrlFrameP;
  check('controller input -> tunnel CHAN_DATA', got.payload.readUInt16BE(0) === ctrlChanId && got.payload.subarray(2).equals(Buffer.from([0x10, 0x20])));

  // 新控制器抢占旧控制器（4001）
  const ctrl2 = await wsConnect(`${baseWs}&ctrl=1`);
  const preempted = await waitClose(ctrl, 4001);
  check('new controller preempts old (4001)', preempted);

  // 同步群控：master 输入经目标设备会话通道广播
  const d2 = new FakeDevice('dev-bbbb-0002', 'PhoneB', 5901);
  await d2.register();
  await d2.openTunnel();
  const d2sub = await wsConnect(`ws://127.0.0.1:${PORT}/ws/vnc/${encodeURIComponent(d2.deviceId)}?token=${TOKEN}&grp=wall1`);
  const master = await wsConnect(`${baseWs}&grp=wall1&broadcast=1&ctrl=1`);
  await new Promise((r) => setTimeout(r, 300));
  const d2Chan = d2.frames.find((f) => f.type === FT_CHAN_OPEN && f.payload.readUInt16BE(0) !== 0);
  const d2ChanId = d2Chan ? d2Chan.payload.readUInt16BE(0) : 0;
  const d2FrameP = d2.nextFrame(FT_CHAN_DATA);
  master.send(Buffer.from([0xaa, 0xbb]));
  const bcast = await d2FrameP;
  check('broadcast input -> target device channel', bcast.payload.readUInt16BE(0) === d2ChanId && bcast.payload.subarray(2).equals(Buffer.from([0xaa, 0xbb])));

  sub.close(); ctrl2.close(); d2sub.close(); master.close(); d1.close(); d2.close();
} catch (e) {
  console.error('TEST ERROR:', e.message);
  console.log(childOut);
  failures++;
} finally {
  child.kill();
  await new Promise((r) => setTimeout(r, 300));
  try { fs.rmSync(tmpData, { recursive: true, force: true }); } catch { /* noop */ }
}

console.log(failures === 0 ? '\nALL TUNNEL TESTS PASSED' : `\n${failures} TUNNEL TEST(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);