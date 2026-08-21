// 缩略图推送测试：设备经隧道发 FT_THUMB(0x06) JPEG → 网关缓存 → GET /api/devices/:id/thumb 读回 base64
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

// ---------- 与 server/index.js 对齐的隧道帧协议 ----------
const FT_THUMB = 0x06;
function encodeFrame(type, payload) {
  const buf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || []);
  const h = Buffer.alloc(5);
  h[0] = type; h.writeUInt32BE(buf.length, 1);
  return Buffer.concat([h, buf]);
}

/** 简化假设备：注册 + 隧道握手 */
class FakeDevice {
  constructor(deviceId, name, vncPort) {
    this.deviceId = deviceId; this.name = name; this.vncPort = vncPort;
    this.regSock = null; this.tunSock = null;
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
    this.tunSock.write(JSON.stringify({ type: 'tunnel_hello', deviceId: this.deviceId }) + '\n');
    await new Promise((res, rej) => {
      let buf = '';
      const onData = (d) => {
        buf += d.toString();
        const nl = buf.indexOf('\n');
        if (nl >= 0) {
          this.tunSock.off('data', onData);
          try {
            const ack = JSON.parse(buf.slice(0, nl));
            if (!ack.ok) return rej(new Error('tunnel_ack not ok'));
          } catch (e) { return rej(e); }
          res();
        }
      };
      this.tunSock.on('data', onData);
    });
  }
  sendThumb(jpeg) { this.tunSock.write(encodeFrame(FT_THUMB, jpeg)); }
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

  // 未推送前：有隧道但无缩略图缓存 → 204
  await d1.openTunnel();
  const noThumb = await fetch(`http://127.0.0.1:${PORT}/api/devices/${d1.deviceId}/thumb`, { headers: auth });
  check('no thumbnail yet -> 204', noThumb.status === 204);

  // 设备推 FT_THUMB（JPEG 字节）→ 网关缓存
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05]);
  d1.sendThumb(jpeg);

  // 轮询读缓存端点，断言 base64 与 ts
  const thumbRes = await waitFor(async () => {
    const r = await fetch(`http://127.0.0.1:${PORT}/api/devices/${d1.deviceId}/thumb`, { headers: auth });
    if (r.status !== 200) return null;
    const j = await r.json();
    return j && j.thumb ? j : null;
  });
  check('thumb endpoint returns 200 + base64', thumbRes.thumb === jpeg.toString('base64'));
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
