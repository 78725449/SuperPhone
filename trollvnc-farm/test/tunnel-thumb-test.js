// 缩略图 RFB 流测试（proto:2）：隧道握手后网关开 chan 0（缩略图通道）→ 假设备回 CHAN_ACK →
// 网关 ThumbRfbDecoder 经 CHAN_DATA(0) 握手解码 Raw 帧 → GET /api/devices/:id/thumb 读回 base64
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';

const ROOT = path.resolve(import.meta.dirname, '..');
const PORT = 19280 + Math.floor(Math.random() * 300);
const REG_PORT = 19281 + Math.floor(Math.random() * 300);
const TUN_PORT = 19381 + Math.floor(Math.random() * 300);
const TOKEN = 'testtoken';
const tmpData = fs.mkdtempSync(path.join(os.tmpdir(), 'farm-thumb-'));

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
const FT_CHAN_ACK = 0x09, FT_CHAN_DATA = 0x0A;
const CHAN_ID_THUMB = 0;
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

// 假 RFB 服务器：模拟设备 5901，经隧道 CHAN_DATA(0) 与网关 ThumbRfbDecoder 握手并发一个 Raw 帧
class FakeRfbServer {
  constructor(sock) { this.sock = sock; this.pending = Buffer.alloc(0); this.step = 0; this.w = 2; this.h = 2; }
  send(payload) { this.sock.write(encodeFrame(FT_CHAN_DATA, chanData(CHAN_ID_THUMB, payload))); }
  start() { this.send(Buffer.from('RFB 003.008\n', 'latin1')); }
  feed(payload) { this.pending = Buffer.concat([this.pending, payload]); this._advance(); }
  _advance() {
    for (;;) {
      if (this.step === 0) { // 等客户端版本行
        if (this.pending.length < 12) return;
        if (!this.pending.subarray(0, 12).toString('latin1').startsWith('RFB 003.')) { this.pending = this.pending.subarray(1); continue; }
        this.pending = this.pending.subarray(12);
        this.send(Buffer.from([1, 1])); // security: count=1, type=None(1)
        this.step = 1; continue;
      }
      if (this.step === 1) { // 等 security type
        if (this.pending.length < 1) return;
        this.pending = this.pending.subarray(1);
        this.send(Buffer.from([0, 0, 0, 0])); // security result: ok
        this.step = 2; continue;
      }
      if (this.step === 2) { // 等 ClientInit
        if (this.pending.length < 1) return;
        this.pending = this.pending.subarray(1);
        const si = Buffer.alloc(24);
        si.writeUInt16BE(this.w, 0); si.writeUInt16BE(this.h, 2);
        si.writeUInt8(32, 4); si.writeUInt8(24, 5); si.writeUInt8(0, 6); si.writeUInt8(1, 7);
        si.writeUInt16BE(255, 8); si.writeUInt16BE(255, 10); si.writeUInt16BE(255, 12);
        si.writeUInt8(16, 14); si.writeUInt8(8, 15); si.writeUInt8(0, 16);
        si.writeUInt32BE(0, 20); // nameLen=0
        this.send(si); // ServerInit
        this.step = 3; continue;
      }
      if (this.step === 3) { // 等 SetPixelFormat(20)+SetEncodings(8)+FramebufferUpdateRequest(10)=38
        if (this.pending.length < 38) return;
        this.pending = this.pending.subarray(38);
        const fb = Buffer.alloc(4 + 12 + this.w * this.h * 4);
        fb.writeUInt8(0, 0); fb.writeUInt8(0, 1); fb.writeUInt16BE(1, 2); // FramebufferUpdate, 1 rect
        fb.writeUInt16BE(0, 4); fb.writeUInt16BE(0, 6);
        fb.writeUInt16BE(this.w, 8); fb.writeUInt16BE(this.h, 10);
        fb.writeInt32BE(0, 12); // Raw
        for (let i = 0; i < this.w * this.h; i++) {
          fb.writeUInt8(255, 16 + i * 4); fb.writeUInt8(0, 17 + i * 4); fb.writeUInt8(0, 18 + i * 4); fb.writeUInt8(0, 19 + i * 4); // BGRA 红
        }
        this.send(fb);
        this.step = 4; return;
      }
      return;
    }
  }
}

/** 简化假设备：注册 + 隧道握手（proto:2）+ 隧道帧解析（分片缓冲拼接）+ 自动应答 CHAN_OPEN */
class FakeDevice {
  constructor(deviceId, name, vncPort) {
    this.deviceId = deviceId; this.name = name; this.vncPort = vncPort;
    this.regSock = null; this.tunSock = null;
    this.tunBuf = Buffer.alloc(0);  // 隧道帧解析缓冲
    this.onFrame = null;            // (type, payload) => void
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
        if (nl >= 0) { this.regSock.off('data', onData); res(); }
      };
      this.regSock.on('data', onData);
    });
  }
  async openTunnel() {
    this.tunSock = await this._tcp(TUN_PORT);
    this.tunSock.write(JSON.stringify({ type: 'tunnel_hello', deviceId: this.deviceId, proto: 2 }) + '\n');
    let buf = Buffer.alloc(0);
    await new Promise((res, rej) => {
      const onData = (d) => {
        buf = Buffer.concat([buf, d]);
        const nl = buf.indexOf(0x0a);
        if (nl >= 0) {
          this.tunSock.off('data', onData);
          try {
            const ack = JSON.parse(buf.subarray(0, nl).toString('utf8'));
            if (!ack.ok) return rej(new Error('tunnel_ack not ok'));
            this.tunBuf = buf.subarray(nl + 1);  // ack 换行后的剩余字节作为首批帧
          } catch (e) { return rej(e); }
          res();
        }
      };
      this.tunSock.on('data', onData);
    });
    // ack 后进入帧封装透传：解析隧道帧（type 1B + length 4B BE + payload），喂给 onFrame
    this.tunSock.on('data', (d) => {
      this.tunBuf = Buffer.concat([this.tunBuf, d]);
      this._drainFrames();
    });
    this._drainFrames();
  }
  _drainFrames() {
    while (this.tunBuf.length >= 5) {
      const type = this.tunBuf[0];
      const len = this.tunBuf.readUInt32BE(1);
      if (this.tunBuf.length < 5 + len) break;  // 不完整，等更多数据
      const payload = this.tunBuf.subarray(5, 5 + len);
      this.tunBuf = this.tunBuf.subarray(5 + len);
      // 模拟设备：CHAN_OPEN 自动回 CHAN_ACK ok（缩略图通道 connect 5901 成功）
      if (type === 0x08 && payload.length >= 3) {
        const ack = Buffer.from([payload[0], payload[1], 1]);
        this.tunSock.write(encodeFrame(FT_CHAN_ACK, ack));
      }
      if (this.onFrame) this.onFrame(type, payload);
    }
  }
  close() { try { this.tunSock && this.tunSock.destroy(); } catch {} try { this.regSock && this.regSock.destroy(); } catch {} }
}

try {
  await waitFor(async () => {
    const r = await fetch(`http://127.0.0.1:${PORT}/api/state`, { headers: auth });
    return r.ok;
  });

  const d1 = new FakeDevice('dev-thumb-0001', 'ThumbA', 5901);
  await d1.register();
  await waitFor(async () => {
    const r = await fetch(`http://127.0.0.1:${PORT}/api/devices`, { headers: auth });
    const j = await r.json();
    return j.devices.some((x) => x.id === d1.deviceId && x.source === 'register');
  });
  check('register -> device source=register', true);

  // 开隧道（proto:2）后、缩略图 RFB 流到达前：无缩略图缓存 → 204
  await d1.openTunnel();
  const noThumb = await fetch(`http://127.0.0.1:${PORT}/api/devices/${d1.deviceId}/thumb`, { headers: auth });
  check('no thumbnail yet -> 204', noThumb.status === 204);

  // 假 RFB 服务器经隧道 CHAN_DATA(0) 与网关 ThumbRfbDecoder 握手并发一个 2x2 Raw 帧
  const rfb = new FakeRfbServer(d1.tunSock);
  d1.onFrame = (type, payload) => { if (type === FT_CHAN_DATA && payload.readUInt16BE(0) === CHAN_ID_THUMB) rfb.feed(payload.subarray(2)); };
  rfb.start();

  // 轮询读缓存端点：网关解码 Raw → JPEG → base64（200 + 非空 thumb）
  const thumbRes = await waitFor(async () => {
    const r = await fetch(`http://127.0.0.1:${PORT}/api/devices/${d1.deviceId}/thumb`, { headers: auth });
    if (r.status !== 200) return null;
    const j = await r.json();
    return j && j.thumb ? j : null;
  });
  check('thumb endpoint returns 200 + base64', typeof thumbRes.thumb === 'string' && thumbRes.thumb.length > 0);
  check('thumb ts is fresh number', Number.isFinite(thumbRes.ts) && thumbRes.ts > 0);

  // 未缓存设备（只注册、无隧道）→ 204
  const d2 = new FakeDevice('dev-thumb-0002', 'ThumbB', 5901);
  await d2.register();
  const noTunRes = await fetch(`http://127.0.0.1:${PORT}/api/devices/${d2.deviceId}/thumb`, { headers: auth });
  check('device without tunnel -> 204', noTunRes.status === 204);

  // 不存在设备 → 404
  const missingRes = await fetch(`http://127.0.0.1:${PORT}/api/devices/dev-thumb-9999/thumb`, { headers: auth });
  check('unknown device -> 404', missingRes.status === 404);

  d1.close(); d2.close();
} catch (e) {
  console.error('TEST ERROR:', e.message);
  console.log(childOut);
  failures++;
} finally {
  child.kill();
  await new Promise((r) => setTimeout(r, 300));
  try { fs.rmSync(tmpData, { recursive: true, force: true }); } catch { /* noop */ }
}

console.log(failures === 0 ? '\nALL THUMB TESTS PASSED' : `\n${failures} THUMB TEST(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
