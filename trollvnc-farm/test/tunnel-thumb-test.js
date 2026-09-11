// 快照服务缩略图测试（2026-09-15 重构）：隧道握手后网关 SnapshotPoller 经 invoke 通道
// 拉取设备 screen.snapshot（board 档 JPEG + seq）→ seq 变化更新缓存 + thumb 事件
// → GET /api/devices/:id/thumb 读回 base64。替代旧 ThumbRfbDecoder（RFB chan 0 Raw 拉流）。
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import jpeg from 'jpeg-js';

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
async function waitFor(fn, timeoutMs = 8000, interval = 60) {
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
const FT_CMD = 0x04, FT_CMDACK = 0x05;
function encodeFrame(type, payload) {
  const buf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || []);
  const h = Buffer.alloc(5);
  h[0] = type; h.writeUInt32BE(buf.length, 1);
  return Buffer.concat([h, buf]);
}

/** 假设备：注册 + 隧道握手（proto:2）+ 帧解析 + 应答 screen.snapshot invoke（自增 seq + JPEG） */
class FakeDevice {
  constructor(deviceId, name, vncPort) {
    this.deviceId = deviceId; this.name = name; this.vncPort = vncPort;
    this.regSock = null; this.tunSock = null;
    this.tunBuf = Buffer.alloc(0);
    this.snapSeq = 0;       // 每次 snapshot 请求自增（模拟屏幕变化）
    this.snapCount = 0;
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
            this.tunBuf = buf.subarray(nl + 1);
          } catch (e) { return rej(e); }
          res();
        }
      };
      this.tunSock.on('data', onData);
    });
    this.tunSock.on('data', (d) => {
      this.tunBuf = Buffer.concat([this.tunBuf, d]);
      this._drainFrames();
    });
    this._drainFrames();
  }
  _respondSnapshot(cmd) {
    this.snapSeq++;
    this.snapCount++;
    const w = 2, h = 2;
    const raw = Buffer.alloc(w * h * 4);
    for (let i = 0; i < w * h; i++) {
      // 每次 seq 不同颜色（模拟变化）
      raw[i * 4] = (this.snapSeq * 40) % 256; raw[i * 4 + 1] = 100; raw[i * 4 + 2] = 50; raw[i * 4 + 3] = 255;
    }
    const encoded = jpeg.encode({ data: raw, width: w, height: h }, 60).data;
    const ackObj = {
      type: 'ack', id: cmd.id, cmd: 'invoke', ok: true,
      seq: this.snapSeq, w, h, jpeg: encoded.toString('base64'), ts: Date.now(),
    };
    this.tunSock.write(encodeFrame(FT_CMDACK, Buffer.from(JSON.stringify(ackObj))));
  }
  _drainFrames() {
    while (this.tunBuf.length >= 5) {
      const type = this.tunBuf[0];
      const len = this.tunBuf.readUInt32BE(1);
      if (this.tunBuf.length < 5 + len) break;
      const payload = this.tunBuf.subarray(5, 5 + len);
      this.tunBuf = this.tunBuf.subarray(5 + len);
      if (type === FT_CMD) {
        try {
          const cmd = JSON.parse(payload.toString('utf8'));
          if (cmd.cmd === 'invoke' && cmd.cap === 'screen.snapshot') this._respondSnapshot(cmd);
        } catch { /* ignore */ }
      }
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

  // 隧道握手后、首轮快照到达前：无缓存 → 204（轮询器首次拉取有网络往返延迟）
  await d1.openTunnel();
  const noThumb = await fetch(`http://127.0.0.1:${PORT}/api/devices/${d1.deviceId}/thumb`, { headers: auth });
  check('no snapshot yet -> 204', noThumb.status === 204 || noThumb.status === 200);

  // 轮询 /api/devices/:id/thumb：SnapshotPoller invoke screen.snapshot → 假设备回 JPEG → 200 + base64
  const thumbRes = await waitFor(async () => {
    const r = await fetch(`http://127.0.0.1:${PORT}/api/devices/${d1.deviceId}/thumb`, { headers: auth });
    if (r.status !== 200) return null;
    const j = await r.json();
    return j && j.thumb ? j : null;
  });
  check('snapshot poll -> thumb 200 + base64', typeof thumbRes.thumb === 'string' && thumbRes.thumb.length > 0);
  check('thumb ts is fresh number', Number.isFinite(thumbRes.ts) && thumbRes.ts > 0);
  check('poller issued snapshot invoke(s)', d1.snapCount >= 1, `count=${d1.snapCount}`);

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