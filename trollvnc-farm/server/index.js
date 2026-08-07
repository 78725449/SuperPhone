/*
 * trollvnc-farm gateway
 * 软路由部署的 TrollVNC 群控网关：REST API + WebSocket<->VNC 桥接 + mDNS 发现 + 广播输入
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import Bonjour from 'bonjour-service';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const WEB_DIR = path.join(ROOT, 'web');
const NOVNC_DIR = path.join(ROOT, 'node_modules', '@novnc', 'novnc');
const DATA_DIR = process.env.FARM_DATA_DIR || path.join(ROOT, 'data');
const DB_FILE = path.join(DATA_DIR, 'devices.json');

const PORT = parseInt(process.env.FARM_PORT || '8080', 10);
const HOST = process.env.FARM_HOST || '0.0.0.0';
const TOKEN = process.env.FARM_TOKEN || '';          // 若设置，访问需带 token
const PROBE_INTERVAL = parseInt(process.env.FARM_PROBE_INTERVAL || '15000', 10);
const REG_PORT = parseInt(process.env.FARM_REG_PORT || '18081', 10);   // 手机注册 TCP 端口

// ---------- 设备数据库 ----------
let devices = [];
let dbSaveTimer = null;

function loadDb() {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    if (fs.existsSync(DB_FILE)) {
      devices = JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
    }
  } catch (e) {
    console.error('[db] load failed:', e.message);
    devices = [];
  }
}

function saveDb() {
  clearTimeout(dbSaveTimer);
  dbSaveTimer = setTimeout(() => {
    try {
      fs.mkdirSync(DATA_DIR, { recursive: true });
      fs.writeFileSync(DB_FILE, JSON.stringify(devices, null, 2));
    } catch (e) {
      console.error('[db] save failed:', e.message);
    }
  }, 300);
}

function findDevice(id) {
  return devices.find((d) => d.id === id);
}

function upsertDevice(input) {
  const existing = devices.find((d) => d.host === input.host && d.port === input.port);
  if (existing) {
    // 已注册设备身份优先：手动/mdns 记录不得覆盖或降级 register 记录（禁止双卡）
    if (existing.source === 'register' && input.source !== 'register') {
      return existing;
    }
    Object.assign(existing, input, { id: existing.id });
    saveDb();
    return existing;
  }
  const dev = {
    id: input.id || `d${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
    name: input.name || `${input.host}:${input.port}`,
    host: input.host,
    port: input.port,
    source: input.source || 'manual',
    group: input.group || '',
    note: input.note || '',
    online: null,
    lastSeen: null,
    addedAt: Date.now(),
  };
  devices.push(dev);
  saveDb();
  return dev;
}

// 注册设备按 deviceId 键（IP 变化不丢身份）；mdns/manual 同 host:port 记录合并为 deviceId，禁止双卡
function upsertRegistered(input) {
  let dev = devices.find((d) => d.id === input.id);
  if (!dev) {
    // 身份合并：已存在 mdns/manual 且同 host+port → 归属到 deviceId
    dev = devices.find((d) => d.source !== 'register' && d.host === input.host && d.port === input.port);
  }
  if (dev) {
    const addedAt = dev.addedAt;
    Object.assign(dev, input, { id: input.id, addedAt, source: 'register' });
  } else {
    dev = {
      id: input.id,
      name: input.name || input.id,
      host: input.host,
      port: input.port,
      source: 'register',
      group: '',
      note: '',
      online: null,
      lastSeen: null,
      addedAt: Date.now(),
    };
    devices.push(dev);
  }
  // 能力清单（v1 只上报；旧客户端缺省不报错，控制台按默认全集渲染）
  if (Array.isArray(input.capabilities)) dev.capabilities = input.capabilities;
  if (input.configs !== undefined) dev.configs = input.configs;
  if (input.screen !== undefined) dev.screen = input.screen;
  if (input.httpPort !== undefined) dev.httpPort = input.httpPort;
  saveDb();
  return dev;
}

function removeDevice(id) {
  const before = devices.length;
  devices = devices.filter((d) => d.id !== id);
  if (devices.length !== before) saveDb();
}

// ---------- mDNS 发现（TrollVNC 会广播 _rfb._tcp） ----------
let bonjour = null;
function startDiscovery() {
  try {
    bonjour = new Bonjour();
    const browser = bonjour.find({ type: 'rfb' });
    browser.on('up', (service) => {
      const host = (service.referer && service.referer.address) || (service.addresses || [])[0];
      const port = service.port;
      if (!host || !port) return;
      // 已注册设备（deviceId 为准）不重复建卡
      const reg = devices.find((d) => d.source === 'register' && d.host === host && d.port === port);
      if (reg) {
        reg.online = true;
        reg.lastSeen = Date.now();
        saveDb();
        console.log('[mdns] up (registered already): ' + service.name + ' @ ' + host + ':' + port);
        return;
      }
      const dev = upsertDevice({
        id: `mdns:${host}:${port}`,
        name: service.name || `${host}:${port}`,
        host,
        port,
        source: 'mdns',
      });
      dev.online = true;
      dev.lastSeen = Date.now();
      saveDb();
      console.log(`[mdns] up: ${service.name} @ ${host}:${port}`);
    });
    browser.on('down', (service) => {
      const host = (service.referer && service.referer.address) || (service.addresses || [])[0];
      const dev = devices.find((d) => d.source !== 'register' && d.host === host && d.port === service.port);
      if (dev) dev.online = false;
    });
    console.log('[mdns] discovering _rfb._tcp ...');
    try {
      bonjour.publish({ name: 'TrollVNCFarm', type: 'trollvnc-farm', port: REG_PORT });
      console.log('[mdns] publishing _trollvnc-farm._tcp on :' + REG_PORT);
    } catch (e) {
      console.error('[mdns] publish failed:', e.message);
    }
  } catch (e) {
    console.error('[mdns] init failed:', e.message);
  }
}

// ---------- TCP 存活探测 ----------
function probeDevice(dev, timeoutMs = 1200) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: dev.host, port: dev.port, timeout: timeoutMs });
    const done = (ok) => {
      dev.online = ok;
      if (ok) dev.lastSeen = Date.now();
      try { sock.destroy(); } catch { /* noop */ }
      resolve(ok);
    };
    sock.once('connect', () => done(true));
    sock.once('timeout', () => done(false));
    sock.once('error', () => done(false));
  });
}

async function probeAll() {
  const jobs = devices.filter((d) => d.source !== 'register').map((d) => probeDevice(d));
  await Promise.all(jobs);
  saveDb();
}

// ---------- 广播组（群控）：会话 -> 组 ----------
const sessionsByDevice = new Map();   // deviceId -> Set<ws>
const sessionGroup = new Map();       // ws -> groupName
const sessionBroadcaster = new Map(); // ws -> true
const registeredDevices = new Map(); // deviceId -> { sock, lastHeartbeat }

// 向已注册设备下发 JSON 命令（写注册 socket；v1 仅 ping 验证，set 类留 B4）
function sendToDevice(deviceId, obj) {
  const rec = registeredDevices.get(deviceId);
  if (!rec) return false;
  const sock = rec.sock || (rec.ws && rec.ws._socket);
  if (!sock || sock.destroyed) return false;
  try {
    sock.write(JSON.stringify(obj) + '\n');
    return true;
  } catch (e) {
    return false;
  }
}

// 命令通道：等待手机 ack 的挂起表（id -> { resolve, timer, cmd, deviceId }，宪法 7.4）
const pendingCmds = new Map();

function getDeviceSessions(deviceId) {
  if (!sessionsByDevice.has(deviceId)) sessionsByDevice.set(deviceId, new Set());
  return sessionsByDevice.get(deviceId);
}

// 把上游输入字节广播给同组的其它会话（写往它们各自的 TCP 连接）
function broadcastInput(fromWs, groupName, data) {
  if (!groupName) return;
  for (const [ws, grp] of sessionGroup) {
    if (ws === fromWs || grp !== groupName) continue;
    if (ws.sock && ws.sock.writable) {
      try { ws.sock.write(data); } catch { /* ignore */ }
    }
  }
}

// ---------- WebSocket <-> VNC 桥接 ----------
function handleVncSocket(ws, req, deviceId, grp, isBroadcast) {
  const dev = findDevice(deviceId);
  if (!dev) {
    ws.close(4004, 'device not found');
    return;
  }
  if (isBroadcast) sessionBroadcaster.set(ws, true);
  if (grp) sessionGroup.set(ws, grp);
  const sessions = getDeviceSessions(deviceId);
  sessions.add(ws);

  const sock = net.connect({ host: dev.host, port: dev.port });
  ws.sock = sock;

  sock.once('connect', () => {
    console.log(`[vnc] connected ${dev.name} (${dev.host}:${dev.port}) grp=${grp || '-'}${isBroadcast ? ' MASTER' : ''}`);
  });
  sock.on('data', (buf) => {
    if (ws.readyState === ws.OPEN) ws.send(buf);
  });
  sock.on('error', (err) => {
    console.error(`[vnc] tcp error ${dev.name}:`, err.message);
    try { ws.close(4003, 'tcp error'); } catch { /* noop */ }
  });
  sock.on('close', () => {
    try { ws.close(4002, 'tcp closed'); } catch { /* noop */ }
  });

  ws.on('message', (data, isBinary) => {
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
    if (sock.writable) {
      try { sock.write(buf); } catch { /* ignore */ }
    }
    if (isBroadcast && grp) broadcastInput(ws, grp, buf);
  });
  ws.on('close', () => {
    sessions.delete(ws);
    sessionGroup.delete(ws);
    sessionBroadcaster.delete(ws);
    try { sock.destroy(); } catch { /* noop */ }
  });
  ws.on('error', () => {
    sessions.delete(ws);
    sessionGroup.delete(ws);
    sessionBroadcaster.delete(ws);
    try { sock.destroy(); } catch { /* noop */ }
  });
}

// ---------- HTTP 静态文件 ----------
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.map': 'application/json',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.wasm': 'application/wasm',
};

function serveStatic(res, filePath, baseDir) {
  const safePath = String(filePath).replace(/^[/\\\\]+/, '');
  const resolved = path.resolve(baseDir, safePath);
  if (!resolved.startsWith(path.resolve(baseDir))) {
    res.writeHead(403).end('forbidden');
    return;
  }
  fs.stat(resolved, (err, st) => {
    if (err || !st.isFile()) {
      res.writeHead(404).end('not found');
      return;
    }
    const ext = path.extname(resolved).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream', 'Content-Length': st.size, 'Cache-Control': 'no-cache' });
    fs.createReadStream(resolved).pipe(res);
  });
}

// ---------- API ----------
function authOk(req) {
  if (!TOKEN) return true;
  const h = req.headers['authorization'] || '';
  if (h === `Bearer ${TOKEN}`) return true;
  const u = new URL(req.url, 'http://x');
  return u.searchParams.get('token') === TOKEN;
}

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (c) => (data += c));
    req.on('end', () => {
      try { resolve(data ? JSON.parse(data) : {}); } catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

function validPort(p) {
  const n = Number(p);
  return Number.isInteger(n) && n > 0 && n < 65536;
}

function validHost(h) {
  return typeof h === 'string' && h.trim().length > 0 && h.trim().length <= 253;
}

async function handleApi(req, res, url) {
  const parts = url.pathname.split('/').filter(Boolean); // ['api','devices',...]
  if (parts[0] !== 'api') return false;
  if (!authOk(req)) { sendJson(res, 401, { error: 'unauthorized' }); return true; }

  const [ , resource, id, sub ] = parts;

  if (resource === 'state' && req.method === 'GET') {
    sendJson(res, 200, { name: 'trollvnc-farm', version: '0.1.0', deviceCount: devices.length, uptime: Math.floor(process.uptime()) });
    return true;
  }

  if (resource === 'devices') {
    if (req.method === 'GET' && !id) {
      sendJson(res, 200, { devices });
      return true;
    }
    if (req.method === 'POST' && !id) {
      const body = await readBody(req).catch(() => ({}));
      const host = (body.host || '').trim();
      const port = Number(body.port);
      if (!validHost(host) || !validPort(port)) {
        sendJson(res, 400, { error: 'invalid host/port' });
        return true;
      }
      const dev = upsertDevice({ name: (body.name || '').trim(), host, port, group: (body.group || '').trim(), note: (body.note || '').trim(), source: 'manual' });
      probeDevice(dev).then(() => saveDb());
      sendJson(res, 201, { device: dev });
      return true;
    }
    if (id) {
      const dev = findDevice(id);
      if (!dev) { sendJson(res, 404, { error: 'device not found' }); return true; }
      if (req.method === 'GET') {
        sendJson(res, 200, { device: dev });
        return true;
      }
      if (req.method === 'DELETE') {
        removeDevice(id);
        sendJson(res, 200, { ok: true });
        return true;
      }
      if (req.method === 'PATCH') {
        const body = await readBody(req).catch(() => ({}));
        if ('name' in body) dev.name = String(body.name).trim() || dev.name;
        if ('group' in body) dev.group = String(body.group).trim();
        if ('note' in body) dev.note = String(body.note).trim();
        if ('host' in body && validHost(body.host)) dev.host = body.host.trim();
        if ('port' in body && validPort(body.port)) dev.port = Number(body.port);
        saveDb();
        probeDevice(dev).then(() => saveDb());
        sendJson(res, 200, { device: dev });
        return true;
      }
      if (req.method === 'POST' && sub === 'command') {
        const body = await readBody(req).catch(() => ({}));
        const cmd = String(body.cmd || '');
        if (!cmd) { sendJson(res, 400, { error: 'cmd required' }); return true; }
        const supported = ['ping'];
        if (!supported.includes(cmd)) { sendJson(res, 400, { error: 'unsupported command: ' + cmd }); return true; }
        const cid = 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
        const timeoutMs = Math.min(Math.max(Number(body.timeout) || 5000, 500), 15000);
        if (!sendToDevice(id, { type: 'cmd', cmd, id: cid, ts: Date.now() })) {
          sendJson(res, 409, { error: 'device not registered / offline' });
          return true;
        }
        // 等待手机 ack（宪法 7.4：网关→手机 cmd，手机→网关 ack）
        const ack = await new Promise((resolve) => {
          const timer = setTimeout(() => { pendingCmds.delete(cid); resolve(null); }, timeoutMs);
          pendingCmds.set(cid, { resolve, timer, cmd, deviceId: dev.id });
        });
        if (!ack) { sendJson(res, 504, { error: 'ack timeout', cmd, id: cid }); return true; }
        sendJson(res, 200, { ok: ack.ok !== false, cmd, id: cid, deviceId: dev.id, ack });
        return true;
      }
      if (req.method === 'POST' && sub === 'ping') {
        const ok = await probeDevice(dev);
        saveDb();
        sendJson(res, 200, { id: dev.id, online: ok });
        return true;
      }
    }
  }

  return false;
}

// ---------- Server ----------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  if (await handleApi(req, res, url)) return;

  if (req.method === 'GET' || req.method === 'HEAD') {
    // 静态资源（页面/JS/CSS/noVNC）不含敏感数据，不鉴权；
    // API 与 WebSocket 由 authOk 单独保护（见 handleApi / wss.on('connection')）
    if (url.pathname === '/') { serveStatic(res, 'index.html', WEB_DIR); return; }
    if (url.pathname.startsWith('/novnc/')) {
      serveStatic(res, url.pathname.slice('/novnc/'.length), NOVNC_DIR);
      return;
    }
    if (url.pathname.startsWith('/web/')) {
      serveStatic(res, url.pathname.slice('/web/'.length), WEB_DIR);
      return;
    }
    serveStatic(res, url.pathname, WEB_DIR);
    return;
  }

  res.writeHead(405).end('method not allowed');
});

const wss = new WebSocketServer({ server, path: undefined });

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://' + (req.headers.host || 'localhost'));
  if (TOKEN && url.searchParams.get('token') !== TOKEN) {
    ws.close(4001, 'unauthorized');
    return;
  }
  // 单通道铁律：注册只走 TCP JSON(18081)，无 WS 注册端点

  const m = url.pathname.match(/^\/ws\/vnc\/([^/]+)$/);
  if (m) {
    const deviceId = decodeURIComponent(m[1]);
    const grp = url.searchParams.get('grp') || '';
    const isBroadcast = url.searchParams.get('broadcast') === '1';
    handleVncSocket(ws, req, deviceId, grp, isBroadcast);
    return;
  }
  ws.close(4000, 'unknown ws path');
});

// keepalive
setInterval(() => {
  for (const client of wss.clients) {
    if (client.readyState === 1) client.ping();
  }
}, 30000);

// 注册设备心跳超时扫描：90s 无心跳 -> 判离线并断开
setInterval(() => {
  const now = Date.now();
  for (const [deviceId, rec] of registeredDevices) {
    if (now - rec.lastHeartbeat > 90000) {
      const dev = findDevice(deviceId);
      if (dev) { dev.online = false; dev.lastSeen = null; saveDb(); }
      try { rec.ws && rec.ws.terminate(); } catch { /* noop */ }
      try { rec.sock && rec.sock.destroy(); } catch { /* noop */ }
      registeredDevices.delete(deviceId);
    }
  }
}, 30000);

loadDb();
startDiscovery();
probeAll().catch(() => {});
setInterval(() => probeAll().catch(() => {}), PROBE_INTERVAL);

// ---- 手机注册 TCP 监听（JSON 行协议）----
const regServer = net.createServer((sock) => {
  let buffer = '';
  let deviceId = null;
  let dev = null;
  const remoteIp = (sock.remoteAddress || '').replace(/^::ffff:/, '');
  const send = (obj) => { try { sock.write(JSON.stringify(obj) + '\n'); } catch { /* noop */ } };
  const handleLine = (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.type === 'register' && msg.deviceId) {
      deviceId = msg.deviceId;
      dev = upsertRegistered({
        id: deviceId,
        name: String(msg.name || deviceId),
        host: remoteIp || '0.0.0.0',
        port: validPort(msg.vncPort) ? Number(msg.vncPort) : 5901,
        // 能力清单（宪法 7.3；旧客户端缺省不报错）
        capabilities: Array.isArray(msg.capabilities) ? msg.capabilities : undefined,
        configs: (msg.configs && typeof msg.configs === 'object') ? msg.configs : undefined,
        screen: (msg.screen && typeof msg.screen === 'object') ? msg.screen : undefined,
        httpPort: validPort(msg.httpPort) ? Number(msg.httpPort) : undefined,
      });
      dev.online = true;
      dev.lastSeen = Date.now();
      // 同设备重复注册：关闭旧连接，仅保留最新
      const oldRec = registeredDevices.get(deviceId);
      if (oldRec) {
        try { oldRec.ws && oldRec.ws.terminate(); } catch (e) { /* noop */ }
        try { oldRec.sock && oldRec.sock.destroy(); } catch (e) { /* noop */ }
      }
      registeredDevices.set(deviceId, { sock, lastHeartbeat: Date.now() });
      saveDb();
      console.log(`[reg] device registered: ${dev.name} (${deviceId}) @ ${remoteIp}:${dev.port}`);
      send({ type: 'ack', deviceId, name: dev.name });
    } else if (msg.type === 'hello' && deviceId) {
      const rec = registeredDevices.get(deviceId);
      if (rec) rec.lastHeartbeat = Date.now();
      if (dev) dev.lastSeen = Date.now();
    } else if (msg.type === 'ack') {
      // 手机对下发命令的确认（宪法 7.4）：按 id 匹配挂起命令
      const p = msg.id ? pendingCmds.get(String(msg.id)) : undefined;
      if (p) {
        clearTimeout(p.timer);
        pendingCmds.delete(String(msg.id));
        p.resolve(msg);
      }
    }
  };
  sock.on('data', (chunk) => {
    buffer += chunk.toString('utf8');
    let idx;
    while ((idx = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, idx);
      buffer = buffer.slice(idx + 1);
      if (line.trim()) handleLine(line.trim());
    }
  });
  sock.on('close', () => {
    if (deviceId) {
      const cur = registeredDevices.get(deviceId);
      if (cur && cur.sock === sock) {
        registeredDevices.delete(deviceId);
        if (dev) { dev.online = false; saveDb(); }
        console.log(`[reg] device offline: ${deviceId}`);
      }
    }
  });
  sock.on('error', () => { /* noop */ });
});
regServer.listen(REG_PORT, HOST, () => {
  console.log(`[farm] registration TCP listener on ${HOST}:${REG_PORT} (JSON lines)`);
});

server.listen(PORT, HOST, () => {
  console.log(`[farm] trollvnc-farm gateway listening on http://${HOST}:${PORT}`);
  console.log(`[farm] data dir: ${DATA_DIR}`);
  console.log(`[farm] token auth: ${TOKEN ? 'enabled' : 'disabled (LAN only!)'}`);
});
