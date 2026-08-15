// ????????? -> ??? -> WS ??/??/??/?????/????
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

// ---------- ?????? server/?????? ----------
const FT_DATA = 0x01, FT_CMD = 0x04, FT_CMDACK = 0x05;
function encodeFrame(type, payload) {
  const buf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || []);
  const h = Buffer.alloc(5);
  h[0] = type; h.writeUInt32BE(buf.length, 1);
  return Buffer.concat([h, buf]);
}

/** ??????? + ??? + ??? */
class FakeDevice {
  constructor(deviceId, name, vncPort) {
    this.deviceId = deviceId; this.name = name; this.vncPort = vncPort;
    this.regSock = null; this.tunSock = null;
    this.frameBuf = Buffer.alloc(0);
    this.frames = [];           // ?????? {type, payload}
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
    this.tunSock.write(JSON.stringify({ type: 'tunnel_hello', deviceId: this.deviceId }) + '\n');
    // ? tunnel_ack?????????
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
          // ????????
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
      // 模拟设备：FT_CMD(rfb.start/stop) 自动回 ack（echo id），网关 ack 驱动据此精确放行握手字节
      if (type === FT_CMD) {
        let cmd = '', id = null;
        try { const j = JSON.parse(frame.payload.toString('utf8')); cmd = j.cmd; id = j.id; } catch { /* noop */ }
        if (cmd === 'rfb.start' || cmd === 'rfb.stop') {
          this.tunSock.write(encodeFrame(FT_CMDACK, Buffer.from(JSON.stringify({ type: 'ack', cmd, id, ok: true }))));
        }
      }
    }
  }
  sendData(data) { this.tunSock.write(encodeFrame(FT_DATA, data)); }
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

  // ???????????WS ????????
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

  // ???
  await d1.openTunnel();
  const baseWs = `ws://127.0.0.1:${PORT}/ws/vnc/${encodeURIComponent(d1.deviceId)}?token=${TOKEN}`;

  // ?????viewOnly ?? WS ???? DATA
  const sub = await wsConnect(baseWs);
  const subGot = [];
  sub.on('message', (d) => subGot.push(Buffer.from(d)));
  await new Promise((r) => setTimeout(r, 200));
  d1.sendData(Buffer.from([0x01, 0x02, 0x03]));
  await waitFor(() => subGot.some((b) => b.equals(Buffer.from([0x01, 0x02, 0x03]))));
  check('viewOnly subscriber receives tunnel DATA', true);

  // viewOnly 会话上行可转发（握手必需字节；只读由 noVNC 客户端保证）。
  // 注意：须在 ctrl 加入前验证——同设备仅 1 个活跃会话，ctrl 加入会顶掉 viewOnly（4001）
  d1.frames = [];
  sub.send(Buffer.from([0x99]));
  await new Promise((r) => setTimeout(r, 400));
  check('viewOnly subscriber upstream forwarded to tunnel', d1.frames.filter((f) => f.type === FT_DATA).length === 1);

  // ???? -> ?? FT_DATA
  d1.frames = []; // 清空 viewOnly 上行验证的旧 FT_DATA 帧（nextFrame 不消费匹配帧）
  const ctrl = await wsConnect(`${baseWs}&ctrl=1`);
  const ctrlFrameP = d1.nextFrame(FT_DATA);
  ctrl.send(Buffer.from([0x10, 0x20]));
  const got = await ctrlFrameP;
  check('controller input -> tunnel FT_DATA', got.payload.equals(Buffer.from([0x10, 0x20])));

  // ???????????????4001?
  const ctrl2 = await wsConnect(`${baseWs}&ctrl=1`);
  const preempted = await waitClose(ctrl, 4001);
  check('new controller preempts old (4001)', preempted);

  // ????????????master ???????2??
  const d2 = new FakeDevice('dev-bbbb-0002', 'PhoneB', 5901);
  await d2.register();
  await d2.openTunnel();
  // ???????? WS ??????????viewOnly ?????
  const d2sub = await wsConnect(`ws://127.0.0.1:${PORT}/ws/vnc/${encodeURIComponent(d2.deviceId)}?token=${TOKEN}&grp=wall1`);
  const master = await wsConnect(`${baseWs}&grp=wall1&broadcast=1&ctrl=1`);
  // 等 ack 驱动重建完成（设备 5901 就绪、重建窗口结束）：窗口内首个上行字节会被缓冲为握手字节，
  // 不执行广播；真实 noVNC 在握手完成前不会发输入，故此处需等待重建完成再发广播输入
  await new Promise((r) => setTimeout(r, 300));
  const d2FrameP = d2.nextFrame(FT_DATA);
  master.send(Buffer.from([0xaa, 0xbb]));
  const bcast = await d2FrameP;
  check('broadcast input -> target device tunnel frame', bcast.payload.equals(Buffer.from([0xaa, 0xbb])));

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
