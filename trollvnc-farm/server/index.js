/*
 * superphone-farm gateway
 * 软路由部署的 SuperPhone 群控网关：REST API + WebSocket<->VNC 桥接 + mDNS 发现 + 广播输入
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

// 端口默认固定（8080 = web/API，18081 = 注册，18181 = 隧道）；env 覆盖仅用于部署/测试隔离
const PORT = parseInt(process.env.FARM_PORT || '8080', 10);
const HOST = process.env.FARM_HOST || '0.0.0.0';
const TOKEN = process.env.FARM_TOKEN || '';          // 若设置，访问需带 token
const PROBE_INTERVAL = parseInt(process.env.FARM_PROBE_INTERVAL || '15000', 10);
const REG_PORT = parseInt(process.env.FARM_REG_PORT || '18081', 10);   // 手机注册 TCP 端口
const TUNNEL_PORT = parseInt(process.env.FARM_TUNNEL_PORT || '18181', 10); // 手机隧道 TCP 端口（RFB/命令透传）

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
  // 2026-08-13：去除能力/配置 schema 存储（前端自包含定义驱动），configs/screen/httpPort 保留
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
      bonjour.publish({ name: 'SuperPhoneFarm', type: 'superphone-farm', port: REG_PORT });
      console.log('[mdns] publishing _superphone-farm._tcp on :' + REG_PORT);
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
const sessionGroup = new Map();       // ws -> { group, deviceId }???????????
const sessionBroadcaster = new Map(); // ws -> true
const registeredDevices = new Map(); // deviceId -> { sock, lastHeartbeat }
// Phase 7：设备隧道连接（deviceId -> { sock, wsSet }），跨网络 RFB 透传 + 命令复用
const tunnels = new Map();
// 隧道帧协议常量（type:1B + length:4B BE + payload）
const FT_DATA    = 0x01;  // RFB 透传数据
const FT_PING    = 0x02;  // 心跳请求
const FT_PONG    = 0x03;  // 心跳响应
const FT_CMD     = 0x04;  // 命令 JSON（网关→设备）
const FT_CMDACK  = 0x05;  // 命令 ack JSON（设备→网关）

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

/**
 * 向隧道 socket 写入一个帧（type + 4字节大端 length + payload）
 * @param {net.Socket} sock 隧道 socket
 * @param {number} type 帧类型（FT_*）
 * @param {Buffer} payload 负载（可为空 Buffer）
 * @returns {boolean} 是否写入成功
 */
function writeTunnelFrame(sock, type, payload) {
  if (!sock || sock.destroyed || !sock.writable) return false;
  const len = payload ? payload.length : 0;
  const header = Buffer.alloc(5);
  header[0] = type;
  header.writeUInt32BE(len, 1);
  try {
    sock.write(header);
    if (len > 0) sock.write(payload);
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * 查询设备是否在线（注册通道存活 或 隧道连接存活，任一即在线）
 * @param {string} deviceId 设备 ID
 * @returns {boolean} 是否在线
 */
function isDeviceOnline(deviceId) {
  return registeredDevices.has(deviceId) || tunnels.has(deviceId);
}

// 命令通道：等待手机 ack 的挂起表（id -> { resolve, timer, cmd, deviceId }，宪法 7.4）
const pendingCmds = new Map();

/**
 * 向设备下发命令并等待 ACK（Phase 4.2：支持 query/set/invoke/restart）
 * @param deviceId  设备 ID
 * @param cmdObj    命令对象（{cmd:'set', key:'Scale', value:0.8, ...}）
 * @param timeoutMs 超时（默认 5s，restart 类可调大）
 * @returns ack 对象，超时返回 null
 */
function sendDeviceCmd(deviceId, cmdObj, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const cid = 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
    const payload = { type: 'cmd', id: cid, ts: Date.now(), ...cmdObj };
    // Phase 7：优先走隧道（CMD 帧），隧道不可用时回退到注册通道
    const tun = tunnels.get(deviceId);
    let sent = false;
    if (tun && tun.sock && !tun.sock.destroyed && tun.sock.writable) {
      sent = writeTunnelFrame(tun.sock, FT_CMD, Buffer.from(JSON.stringify(payload), 'utf8'));
    }
    if (!sent) {
      sent = sendToDevice(deviceId, payload);
    }
    if (!sent) { resolve(null); return; }
    const timer = setTimeout(() => { pendingCmds.delete(cid); resolve(null); }, timeoutMs);
    pendingCmds.set(cid, { resolve, timer, cmd: cmdObj.cmd, deviceId });
  });
}

function getDeviceSessions(deviceId) {
  if (!sessionsByDevice.has(deviceId)) sessionsByDevice.set(deviceId, new Set());
  return sessionsByDevice.get(deviceId);
}

// 把上游输入字节广播给同组的其它会话（写往它们各自的 TCP 连接）
function broadcastInput(fromWs, groupName, data) {
  if (!groupName) return;
  for (const [ws, info] of sessionGroup) {
    if (ws === fromWs || !info || info.group !== groupName) continue;
    const targetTun = tunnels.get(info.deviceId);
    if (targetTun && targetTun.sock && !targetTun.sock.destroyed && targetTun.sock.writable) {
      try { writeTunnelFrame(targetTun.sock, FT_DATA, data); } catch { /* ignore */ }
    }
  }
}

// ---------- WebSocket <-> VNC 桥接 ----------
function handleVncSocket(ws, req, deviceId, grp, isBroadcast, isCtrl) {
  const dev = findDevice(deviceId);
  if (!dev) {
    ws.close(4004, 'device not found');
    return;
  }
  // 隧道不存在（设备未注册/已掉线）时拒绝会话
  const tun = tunnels.get(deviceId);
  if (!tun || !tun.sock || tun.sock.destroyed || !tun.sock.writable) {
    ws.close(4003, 'no tunnel: device not registered');
    return;
  }
  if (isBroadcast) sessionBroadcaster.set(ws, true);
  if (grp) sessionGroup.set(ws, { group: grp, deviceId });
  const sessions = getDeviceSessions(deviceId);
  sessions.add(ws);
  // Phase 7.2 修复：WS 会话必须注册进 tun.wsSet（RFB 数据订阅集合），
  // 否则 FT_DATA 无订阅者，设备回传的画面字节只会进 pending 缓冲导致黑屏。
  // 首个会话触发 rfb.start、末个会话 rfb.stop（on-demand RFB 引用计数）。
  tun.wsSet.add(ws);
  // 新会话建立：取消延迟 rfb.stop（快速进出时避免 stop/start 乒乓抖动，提升流畅度）
  if (tun.stopTimer) {
    clearTimeout(tun.stopTimer);
    tun.stopTimer = null;
  }
  // 同设备仅保留一个活跃会话：设备端仅 1 条隧道 + 1 个 5901 连接（_localFd），
  // 多个会话（含未清理的残留、直控与同步并存等）同时上行会共同驱动 5901 协议状态机，
  // 握手/输入字节相互串扰 → noVNC 在消息循环收到非法字节 "Unexpected server message (type N)" 断开。
  // 顶掉旧会话后按"首会话"语义触发 5901 重建，新会话拿到干净握手；ctrl 间抢占由下方分支处理。
  for (const other of [...tun.wsSet]) {
    if (other === ws || other.readyState !== other.OPEN || other.isController) continue;
    tun.wsSet.delete(other);
    sessions.delete(other);
    sessionGroup.delete(other);
    sessionBroadcaster.delete(other);
    if (tun.controller === other) tun.controller = null;
    try { other.close(4001, 'preempted by new session'); } catch { /* noop */ }
  }
  const isFirstSession = tun.wsSet.size === 1;
  // ctrl 会话（唯一控制者）无条件重建设备 5901：接管场景（新 ctrl 顶掉旧 ctrl）必须重建，
  // 否则新 noVNC 的握手字节会转发到旧 5901 连接上，协议状态错乱导致黑屏；
  // viewOnly 会话仍仅在"首个会话"（wsSet 0→1）时触发，避免多会话互相打断。
  const needRfbRebuild = isCtrl || isFirstSession;

  // 无订阅期间的 RFB 握手头（pending 缓冲）补发给新会话，避免 noVNC 悬挂黑屏。
  // 注意：仅"不触发重建"的会话才可复用旧缓冲数据；触发重建（ctrl / 首会话）的
  // 会话即将 stop→start 全新 5901 连接，旧 pending 是上一个会话的残留帧
  // （退出时 rfb.stop 延迟 800ms 下发，期间旧连接仍在推帧被缓冲），
  // 直接补发会让 noVNC 把旧帧当版本响应 → "Invalid server version" 黑屏。
  if (!needRfbRebuild && tun.pending && tun.pending.length) {
    const pv = tun.pending;
    tun.pending = Buffer.alloc(0);
    try { ws.send(pv); } catch { /* ignore */ }
  }
  ws.isController = !!isCtrl;
  console.log(`[vnc] tunnel bridge ${dev.name} (${deviceId}) ctrl=${isCtrl ? 'YES' : 'viewOnly'} grp=${grp || '-'}${isBroadcast ? ' MASTER' : ''} sessions=${tun.wsSet.size}`);

  // 控制会话抢占：新 ctrl 顶掉旧 ctrl
  if (isCtrl) {
    const old = tun.controller;
    if (old && old !== ws && old.readyState === old.OPEN) {
      try { old.close(4001, 'preempted by another controller'); } catch { /* noop */ }
    }
    tun.controller = ws;
  }
  // on-demand RFB：强制设备侧重建本地 5901（stop→start），确保新会话拿到全新 RFB 握手，
  // 避免复用旧连接导致 "Invalid server version" / 协议错乱黑屏。
  // ack 驱动：设备端同步 connect 后回 ack 携带结果——收到 ack 才精确放行缓冲的握手字节
  // （替代固定 400ms 窗口，消除设备冷启动/慢连接的竞态）；connect 失败则显式断开控制会话报错，
  // 3s 超时兜底（旧设备不 ack 时强制放行，防永久卡死）。
  if (needRfbRebuild && tun.sock && !tun.sock.destroyed && tun.sock.writable) {
    const rid = 's' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
    const mkCmd = (cmd, id) => Buffer.from(JSON.stringify({ type: 'cmd', cmd, id: id || ('s' + Date.now().toString(36)) }), 'utf8');
    // 先 rfb.stop（断开设备侧可能残留的旧 5901 连接），重建窗口期内缓冲上行握手字节
    try { writeTunnelFrame(tun.sock, FT_CMD, mkCmd('rfb.stop')); } catch { /* noop */ }
    // 重建即将开始全新 RFB 连接：丢弃上一个会话残留的下行缓冲（防污染新会话握手）
    tun.pending = Buffer.alloc(0);
    tun.pendingUp = Buffer.alloc(0);
    tun.pendingUpUntil = Date.now() + 3000; // 兜底：ack 正常会在设备 connect 完成后提前结束
    tun.rebuild = { id: rid, timer: null };
    // 兜底超时：ack 丢失/旧设备不 ack 时强制放行，避免握手字节永久卡在缓冲
    tun.rebuild.timer = setTimeout(() => {
      if (tun.rebuild && tun.rebuild.id === rid) {
        tun.pendingUpUntil = 0;
        console.log(`[vnc] rfb.start ack timeout, force release (${deviceId})`);
        if (tun.pendingUp && tun.pendingUp.length) {
          try { writeTunnelFrame(tun.sock, FT_DATA, tun.pendingUp); } catch { /* noop */ }
        }
        tun.pendingUp = null;
        tun.rebuild = null;
      }
    }, 3000);
    try { writeTunnelFrame(tun.sock, FT_CMD, mkCmd('rfb.start', rid)); } catch { /* noop */ }
  }

  ws.on('message', (data, isBinary) => {
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
    // 设备 5901 重建窗口期内缓冲上行字节（等 rfb.start 重建完成后再放行），
    // 避免 noVNC 握手字节发到旧/未就绪连接
    if (tun.pendingUpUntil && Date.now() < tun.pendingUpUntil) {
      tun.pendingUp = Buffer.concat([tun.pendingUp || Buffer.alloc(0), buf]);
      if (tun.pendingUp.length > 64 * 1024) {
        tun.pendingUp = tun.pendingUp.subarray(tun.pendingUp.length - 64 * 1024);
      }
      return;
    }
    // RFB 握手必需字节（版本响应/ClientInit/PixelFormat 等）在 viewOnly 会话也要转发，
    // 否则 noVNC 握手被卡死导致黑屏。noVNC 的 viewOnly 模式本身不会发送输入事件，
    // 因此允许所有会话上行转发是安全的；输入转发仅广播主控触发。
    const ok = writeTunnelFrame(tun.sock, FT_DATA, buf);
    console.log(`[vnc] ws->tunnel ${deviceId} bytes=${buf.length} wrote=${ok}`);
    if (isBroadcast && grp) broadcastInput(ws, grp, buf);
  });

  const cleanup = () => {
    // close/error 双触发幂等保护：已清理过则直接返回
    if (!tun.wsSet.has(ws)) return;
    sessions.delete(ws);
    sessionGroup.delete(ws);
    sessionBroadcaster.delete(ws);
    tun.wsSet.delete(ws);
    if (tun.controller === ws) {
      tun.controller = null;
    }
    // 最后一个会话断开：清空 pending（旧会话残留数据失效，防补发给新会话造成握手错乱）+ 延迟 rfb.stop
    if (tun.wsSet.size === 0) {
      tun.pending = Buffer.alloc(0);
      // 会话全断：作废设备 5901 重建窗口的缓冲与 ack 等待状态
      tun.pendingUp = null;
      tun.pendingUpUntil = 0;
      if (tun.rebuild) {
        if (tun.rebuild.timer) clearTimeout(tun.rebuild.timer);
        tun.rebuild = null;
      }
      if (tun.stopTimer) clearTimeout(tun.stopTimer);
      if (tun.sock && !tun.sock.destroyed && tun.sock.writable) {
        // debounce 800ms：快速重进时设备 5901 连接保持，减少 stop/start 乒乓
        tun.stopTimer = setTimeout(() => {
          tun.stopTimer = null;
          if (!tun.sock || tun.sock.destroyed || !tun.sock.writable) return;
          const rfbStop = Buffer.from(JSON.stringify({ type: 'cmd', cmd: 'rfb.stop', id: 'e' + Date.now().toString(36) }), 'utf8');
          try { writeTunnelFrame(tun.sock, FT_CMD, rfbStop); } catch { /* noop */ }
        }, 800);
      }
    }
  };
  ws.on('close', cleanup);
  ws.on('error', cleanup);
}

function handleControlSocket(ws, req, deviceId) {
  const dev = findDevice(deviceId);
  if (!dev) {
    ws.close(4004, 'device not found');
    return;
  }
  console.log(`[control] ai tool connected: device=${deviceId} (${dev.name})`);

  /**
   * 向客户端发送一条 JSON 行 ACK
   * @param {object} obj 待发送的 ACK 对象
   * @returns {void}
   */
  const sendAck = (obj) => {
    if (ws.readyState === ws.OPEN) {
      try { ws.send(JSON.stringify(obj) + '\n'); } catch { /* noop */ }
    }
  };

  ws.on('message', async (data) => {
    const text = Buffer.isBuffer(data) ? data.toString('utf8') : String(data);
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      sendAck({ type: 'ack', ok: false, error: 'invalid json' });
      return;
    }
    if (!msg || typeof msg !== 'object' || Array.isArray(msg)) {
      sendAck({ type: 'ack', ok: false, error: 'invalid json' });
      return;
    }
    const cmd = msg.cmd;
    const id = msg.id;
    if (!cmd) {
      sendAck({ type: 'ack', id, ok: false, error: 'missing cmd' });
      return;
    }

    // 设备离线（未注册且无隧道）→ 与超时区分开，立即返回
    if (!isDeviceOnline(deviceId)) {
      sendAck({ type: 'ack', cmd, id, ok: false, error: 'device offline' });
      return;
    }

    // 按命令组装下发对象与超时（设备侧已实现 query/set/invoke/restart/ping 处理）
    const cmdObj = { cmd };
    let timeoutMs = 5000;
    switch (cmd) {
      case 'ping':
        break;
      case 'query':
        if (msg.target) cmdObj.target = msg.target;   // caps/configs/schema/status
        break;
      case 'invoke':
        if (msg.cap) cmdObj.cap = msg.cap;
        cmdObj.params = msg.params || {};
        break;
      case 'set':
        if (msg.key) cmdObj.key = msg.key;
        if (msg.value !== undefined) cmdObj.value = msg.value;
        break;
      case 'restart':
        timeoutMs = 15000;   // 重启类超时调大至 15s
        break;
      default:
        sendAck({ type: 'ack', cmd, id, ok: false, error: 'unknown cmd: ' + cmd });
        return;
    }

    const ack = await sendDeviceCmd(deviceId, cmdObj, timeoutMs);
    if (!ack) {
      sendAck({ type: 'ack', cmd, id, ok: false, error: 'device timeout' });
      return;
    }
    // 透传设备 ack 的数据字段（configs/result/reload/error 等），
    // 用本端 envelope 覆盖 type/cmd/id/ok（id 回填客户端原始 id）
    const ok = ack.ok !== false;
    sendAck({ ...ack, type: 'ack', cmd, id, ok });
  });

  ws.on('close', () => {
    console.log(`[control] ai tool disconnected: device=${deviceId}`);
  });
  ws.on('error', () => {
    console.log(`[control] ai tool socket error: device=${deviceId}`);
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
    sendJson(res, 200, { name: 'superphone-farm', version: '0.0.1', deviceCount: devices.length, uptime: Math.floor(process.uptime()) });
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
    // Phase 4.6：批量操作（invoke/configs/restart）——必须先于单设备分支，否则 id='batch' 会被 findDevice 404 拦截
    if (id === 'batch' && req.method === 'POST') {
      const body = await readBody(req).catch(() => ({}));
      const deviceIds = Array.isArray(body.deviceIds) ? body.deviceIds.filter((x) => typeof x === 'string') : [];
      if (deviceIds.length === 0) { sendJson(res, 400, { error: 'deviceIds required' }); return true; }
      // 批量调用能力
      if (sub === 'invoke') {
        const cap = String(body.cap || '');
        if (!cap) { sendJson(res, 400, { error: 'cap required' }); return true; }
        const params = body.params || {};
        const timeoutMs = Math.min(Math.max(Number(body.timeout) || 5000, 500), 15000);
        const results = await Promise.all(deviceIds.map(async (did) => {
          const ack = await sendDeviceCmd(did, { cmd: 'invoke', cap, params }, timeoutMs);
          return ack ? { deviceId: did, ok: ack.ok !== false, error: ack.error } : { deviceId: did, ok: false, error: 'timeout' };
        }));
        sendJson(res, 200, { cap, results });
        return true;
      }
      // 批量设置配置
      if (sub === 'configs') {
        const configs = (body.configs && typeof body.configs === 'object' && !Array.isArray(body.configs)) ? body.configs : null;
        if (!configs) { sendJson(res, 400, { error: 'configs object required' }); return true; }
        const results = await Promise.all(deviceIds.map(async (did) => {
          const cfgResults = {};
          for (const [key, value] of Object.entries(configs)) {
            const ack = await sendDeviceCmd(did, { cmd: 'set', key, value });
            cfgResults[key] = ack ? { ok: ack.ok !== false, reload: ack.reload, error: ack.error } : { ok: false, error: 'timeout' };
          }
          return { deviceId: did, results: cfgResults };
        }));
        sendJson(res, 200, { results });
        return true;
      }
      // 批量重启（前端需二次确认）
      if (sub === 'restart') {
        const results = await Promise.all(deviceIds.map(async (did) => {
          const ack = await sendDeviceCmd(did, { cmd: 'restart' }, 8000);
          return ack ? { deviceId: did, ok: ack.ok !== false, error: ack.error } : { deviceId: did, ok: false, error: 'timeout' };
        }));
        sendJson(res, 200, { results });
        return true;
      }
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
      // 2026-08-13：能力/配置 schema 不再上报，/caps 仅返回当前配置值
      if (req.method === 'GET' && sub === 'caps') {
        sendJson(res, 200, { deviceId: dev.id, configs: dev.configs || {} });
        return true;
      }
      // Phase 4.6：查询/设置配置
      if (req.method === 'GET' && sub === 'configs') {
        sendJson(res, 200, { deviceId: dev.id, configs: dev.configs || {} });
        return true;
      }
      if (req.method === 'POST' && sub === 'configs') {
        const body = await readBody(req).catch(() => ({}));
        if (!body || typeof body !== 'object' || Array.isArray(body)) {
          sendJson(res, 400, { error: 'expected JSON object of {key:value}' }); return true;
        }
        const results = {};
        for (const [key, value] of Object.entries(body)) {
          const ack = await sendDeviceCmd(id, { cmd: 'set', key, value });
          results[key] = ack ? { ok: ack.ok !== false, reload: ack.reload, error: ack.error } : { ok: false, error: 'timeout' };
        }
        sendJson(res, 200, { deviceId: dev.id, results });
        return true;
      }
      // Phase 4.6：调用控制型能力
      if (req.method === 'POST' && sub === 'invoke') {
        const body = await readBody(req).catch(() => ({}));
        const cap = String(body.cap || '');
        if (!cap) { sendJson(res, 400, { error: 'cap required' }); return true; }
        const timeoutMs = Math.min(Math.max(Number(body.timeout) || 5000, 500), 15000);
        const ack = await sendDeviceCmd(id, { cmd: 'invoke', cap, params: body.params || {} }, timeoutMs);
        if (!ack) { sendJson(res, 504, { error: 'ack timeout', cap }); return true; }
        sendJson(res, 200, { ok: ack.ok !== false, cap, deviceId: dev.id, ack });
        return true;
      }
      // Phase 4.6：重启设备服务（单台）
      if (req.method === 'POST' && sub === 'restart') {
        const ack = await sendDeviceCmd(id, { cmd: 'restart' }, 8000);
        if (!ack) { sendJson(res, 504, { error: 'ack timeout' }); return true; }
        sendJson(res, 200, { ok: ack.ok !== false, deviceId: dev.id, ack });
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
      const novncRel = url.pathname.slice('/novnc/'.length);
      // 内网 HTTP 环境：屏蔽 noVNC 的「requires a secure context (TLS)」警告。
      // RFB 连接本身不受影响，仅在内存中替换，不修改 node_modules。
      if (novncRel.endsWith('core/rfb.js')) {
        console.log(`[novnc] patching rfb.js (${novncRel})`);
        try {
          let rfbSrc = fs.readFileSync(path.join(NOVNC_DIR, novncRel), 'utf8');
          const before = rfbSrc.includes('secure context (TLS)');
          rfbSrc = rfbSrc.replace(
            'Log.Error("noVNC requires a secure context (TLS). Expect crashes!");',
            '/* TLS 上下文警告已屏蔽：内网 HTTP 环境，RFB 不受影响 */'
          );
          // wheel 事件显式 passive:false（noVNC 滚轮缩放需 preventDefault，消除 Chrome Violation 警告）
          rfbSrc = rfbSrc.replace(
            'this._canvas.addEventListener("wheel", this._eventHandlers.handleWheel);',
            'this._canvas.addEventListener("wheel", this._eventHandlers.handleWheel, { passive: false });'
          );
          // touchstart 聚焦监听不调用 preventDefault（focus 用 preventScroll），
          // 显式 passive:true 消除 Chrome「scroll-blocking touchstart」Violation 警告
          rfbSrc = rfbSrc.replace(
            'this._canvas.addEventListener("touchstart", this._eventHandlers.focusCanvas);',
            'this._canvas.addEventListener("touchstart", this._eventHandlers.focusCanvas, { passive: true });'
          );
          const after = rfbSrc.includes('secure context (TLS)');
          console.log(`[novnc] rfb.js patch: before=${before} after=${after}`);
          res.writeHead(200, {
            'Content-Type': 'text/javascript',
            'Content-Length': Buffer.byteLength(rfbSrc),
            'Cache-Control': 'no-cache',
          });
          res.end(rfbSrc);
          return;
        } catch (e) { console.log(`[novnc] patch failed: ${e.message}`); /* fallthrough */ }
      }
      // gesturehandler：touchstart/touchmove 处理器需 preventDefault（手势检测），
      // 显式 passive:false（语义与默认一致），消除 Chrome scroll-blocking Violation 警告
      if (novncRel.endsWith('core/input/gesturehandler.js')) {
        console.log(`[novnc] patching gesturehandler.js (${novncRel})`);
        try {
          let gSrc = fs.readFileSync(path.join(NOVNC_DIR, novncRel), 'utf8');
          const before = gSrc.includes('passive: false');
          gSrc = gSrc.replace(
            /addEventListener\('touchstart',\n(\s*)this\._boundEventHandler\);/,
            "addEventListener('touchstart',\n$1this._boundEventHandler, { passive: false });"
          );
          gSrc = gSrc.replace(
            /addEventListener\('touchmove',\n(\s*)this\._boundEventHandler\);/,
            "addEventListener('touchmove',\n$1this._boundEventHandler, { passive: false });"
          );
          // 长按 = 控制端粘贴手势（2026-08-13）：原 noVNC 长按=右键，与"屏幕上长按取控制端剪贴板"冲突。
          // 改为分发 farmlongpress 自定义事件（坐标），触摸进入忽略列表——不再产生任何鼠标/手势事件，
          // 前端 app.js 监听该事件弹出粘贴条，跨设备粘贴文本到被控设备。
          const longpressOld = `    _longpressTimeout() {
        if (this._hasDetectedGesture()) {
            throw new Error("A longpress gesture failed, conflict with a different gesture");
        }

        this._state = GH_LONGPRESS;
        this._pushEvent('gesturestart');
    }`;
          const longpressNew = `    _longpressTimeout() {
        if (this._hasDetectedGesture()) {
            throw new Error("A longpress gesture failed, conflict with a different gesture");
        }

        // [farm patch] 长按 = 控制端粘贴手势：分发 farmlongpress（不发右键），
        // 触摸进忽略列表，剩余 touchend 不再触发任何鼠标/手势事件。
        if (this._tracked.length > 0) {
            const t = this._tracked[0];
            this._target.dispatchEvent(new CustomEvent('farmlongpress', {
                detail: { x: t.firstX, y: t.firstY }
            }));
            this._ignored.push(t.id);
        }
        this._tracked = [];
        this._state = GH_NOGESTURE;
    }`;
          gSrc = gSrc.replace(longpressOld, longpressNew);
          const after = gSrc.includes('passive: false') && gSrc.includes('farmlongpress');
          console.log(`[novnc] gesturehandler.js patch: before=${before} after=${after}`);
          res.writeHead(200, {
            'Content-Type': 'text/javascript',
            'Content-Length': Buffer.byteLength(gSrc),
            'Cache-Control': 'no-cache',
          });
          res.end(gSrc);
          return;
        } catch (e) { console.log(`[novnc] gesturehandler patch failed: ${e.message}`); /* fallthrough */ }
      }
      serveStatic(res, novncRel, NOVNC_DIR);
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
    const isCtrl = url.searchParams.get('ctrl') === '1';
    handleVncSocket(ws, req, deviceId, grp, isBroadcast, isCtrl);
    return;
  }
  // Phase 4.8：AI 工具 WS 控制端点 /ws/control/:id
  const mc = url.pathname.match(/^\/ws\/control\/([^/]+)$/);
  if (mc) {
    const deviceId = decodeURIComponent(mc[1]);
    handleControlSocket(ws, req, deviceId);
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
      if (dev) {
        // Phase 7：注册心跳超时时，隧道仍存活则保持在线
        const tunnelAlive = tunnels.has(deviceId);
        dev.online = tunnelAlive;
        if (!tunnelAlive) dev.lastSeen = null;
        saveDb();
      }
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
  console.log(`[reg] TCP connection from ${remoteIp}`);
  const send = (obj) => { try { sock.write(JSON.stringify(obj) + '\n'); } catch { /* noop */ } };
  const handleLine = (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch (e) {
      console.log(`[reg] unparseable line from ${remoteIp}: ${JSON.stringify(line.slice(0, 200))}`);
      return;
    }
    console.log(`[reg] line from ${remoteIp}: ${JSON.stringify(line.slice(0, 200))}`);
    if (msg.type === 'register' && msg.deviceId) {
      console.log(`[reg] register received deviceId=${msg.deviceId} name=${String(msg.name || '')} vncPort=${msg.vncPort}`);
      deviceId = msg.deviceId;
      dev = upsertRegistered({
        id: deviceId,
        name: String(msg.name || deviceId),
        host: remoteIp || '0.0.0.0',
        port: validPort(msg.vncPort) ? Number(msg.vncPort) : 5901,
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
        if (dev) {
          // Phase 7：隧道仍存活则保持在线，仅注册通道断开
          const tunnelAlive = tunnels.has(deviceId);
          dev.online = tunnelAlive;
          if (!tunnelAlive) dev.lastSeen = Date.now();
          saveDb();
        }
        console.log(`[reg] device offline: ${deviceId}${tunnels.has(deviceId) ? ' (tunnel still alive)' : ''}`);
      }
    }
  });
  sock.on('error', () => { /* noop */ });
});
regServer.listen(REG_PORT, HOST, () => {
  console.log(`[farm] registration TCP listener on ${HOST}:${REG_PORT} (JSON lines)`);
});

// ---- 手机隧道 TCP 监听（Phase 7：跨网络 RFB/命令透传）----
// 握手阶段用 JSON 行（tunnel_hello → tunnel_ack），握手后切换为帧封装模式
const tunnelServer = net.createServer((sock) => {
  const tunRemote = (sock.remoteAddress || '').replace(/^::ffff:/, '');
  console.log(`[tunnel] TCP connection from ${tunRemote}`);
  let buf = Buffer.alloc(0);
  let deviceId = null;
  let dev = null;
  let framed = false;       // 是否已完成握手进入帧模式
  let frameBuf = Buffer.alloc(0);  // 帧解析缓冲

  /**
   * 处理一个完整帧（DATA/CMDACK/PING/PONG）
   * @param {number} type 帧类型
   * @param {Buffer} payload 负载
   * @returns {void}
   */
  const handleFrame = (type, payload) => {
    if (type === FT_DATA) {
      // DIAG: count FT_DATA frames from device
      const diag = tunnels.get(deviceId) || {};
      diag._dataCount = (diag._dataCount || 0) + 1;
      if (diag._dataCount === 1 || diag._dataCount % 50 === 0) {
        console.log(`[tunnel] FT_DATA from ${deviceId} count=${diag._dataCount} ws=${(tunnels.get(deviceId)||{wsSet:new Set()}).wsSet.size}`);
      }
      // RFB data: broadcast to subscribed WS; buffer when no subscriber yet
      // (RFB handshake head), replay on first subscribe so noVNC sees the
      // server version instead of hanging black
      const rec = tunnels.get(deviceId);
      if (rec) {
        // 设备 5901 重建窗口期：丢弃旧连接残留的下行数据（防污染新会话握手）
        if (rec.pendingUpUntil && Date.now() < rec.pendingUpUntil) return;
        if (rec.wsSet.size > 0) {
          rec.pending = Buffer.alloc(0);
          for (const ws of rec.wsSet) {
            if (ws.readyState === ws.OPEN) {
              try { ws.send(payload); } catch { /* ignore */ }
            }
          }
        } else {
          rec.pending = Buffer.concat([rec.pending, payload]);
          if (rec.pending.length > 64 * 1024) {
            rec.pending = rec.pending.subarray(rec.pending.length - 64 * 1024);
          }
        }
      }
        } else if (type === FT_CMDACK) {
      // cmd ack: match pending cmds
      let ack;
      try { ack = JSON.parse(payload.toString('utf8')); } catch { return; }
      console.log(`[tunnel] FT_CMDACK from ${deviceId} cmd=${ack && ack.cmd} ok=${ack && ack.ok}`);
      // rfb.start ack：设备 5901 就绪确认（ack 驱动精确放行握手字节）
      const tunRec = tunnels.get(deviceId);
      if (tunRec && tunRec.rebuild && ack && ack.cmd === 'rfb.start' && ack.id === tunRec.rebuild.id) {
        if (tunRec.rebuild.timer) { clearTimeout(tunRec.rebuild.timer); tunRec.rebuild.timer = null; }
        tunRec.pendingUpUntil = 0; // 结束下行丢弃窗口（设备 5901 已就绪）
        if (ack.ok) {
          // connect 成功：放行缓冲的握手字节，noVNC 必然拿到 server version 出画面
          console.log(`[vnc] rfb.start ack ok, release handshake bytes (${deviceId})`);
          if (tunRec.pendingUp && tunRec.pendingUp.length) {
            try { writeTunnelFrame(sock, FT_DATA, tunRec.pendingUp); } catch { /* noop */ }
          }
        } else {
          // connect 失败：显式断开控制会话（前端提示"画面服务不可用"），不静默黑屏
          console.log(`[vnc] rfb.start ack failed (${deviceId}), closing ctrl session`);
          if (tunRec.controller && tunRec.controller.readyState === 1) {
            try { tunRec.controller.close(4005, 'device RFB unavailable'); } catch { /* noop */ }
          }
        }
        tunRec.pendingUp = null;
        tunRec.rebuild = null;
        return;
      }
      const p = ack && ack.id ? pendingCmds.get(String(ack.id)) : undefined;
      if (p) {
        clearTimeout(p.timer);
        pendingCmds.delete(String(ack.id));
        p.resolve(ack);
      }
        } else if (type === FT_PING) {
      // 心跳请求：回 PONG（双向保活）
      writeTunnelFrame(sock, FT_PONG, Buffer.alloc(0));
    } else if (type === FT_PONG) {
      // 心跳响应：链路存活即可
    }
  };

  /**
   * 喂入隧道原始字节，解析为帧并处理
   * @param {Buffer} chunk 原始字节
   * @returns {void}
   */
  const feedFrame = (chunk) => {
    frameBuf = frameBuf.length ? Buffer.concat([frameBuf, chunk]) : chunk;
    while (frameBuf.length >= 5) {
      const type = frameBuf[0];
      const len = frameBuf.readUInt32BE(1);
      if (len > 16 * 1024 * 1024) {
        // 帧过大：异常，断开
        console.error(`[tunnel] frame too large (${len}) from ${deviceId}, closing`);
        sock.destroy();
        return;
      }
      if (frameBuf.length < 5 + len) break;  // 不完整，等更多数据
      const payload = frameBuf.subarray(5, 5 + len);
      handleFrame(type, payload);
      frameBuf = frameBuf.subarray(5 + len);
    }
  };

  const onData = (chunk) => {
    if (!framed) {
      // 握手阶段：行缓冲，等待 tunnel_hello
      buf = Buffer.concat([buf, chunk]);
      const nl = buf.indexOf('\n');
      if (nl < 0) return;
      const line = buf.slice(0, nl).toString('utf8').trim();
      buf = buf.slice(nl + 1);
      sock.off('data', onData);
      let hello;
      try { hello = JSON.parse(line); } catch (e) { sock.destroy(); return; }
      if (hello.type !== 'tunnel_hello' || !hello.deviceId) { sock.destroy(); return; }
      // 校验 deviceId 是否已注册（可选校验 token）
      deviceId = hello.deviceId;
      dev = findDevice(deviceId);
      if (!dev) {
        sock.write(JSON.stringify({ type: 'tunnel_ack', ok: false, error: 'device not registered' }) + '\n');
        sock.destroy();
        return;
      }
      // 注册隧道（同设备重复隧道：关闭旧的）
      const old = tunnels.get(deviceId);
      if (old && old.sock !== sock) {
        try { old.sock.destroy(); } catch { /* noop */ }
      }
      tunnels.set(deviceId, { sock, wsSet: new Set(), controller: null, pending: Buffer.alloc(0) });
      sock.write(JSON.stringify({ type: 'tunnel_ack', ok: true }) + '\n');
      framed = true;
      dev.online = true;
      dev.lastSeen = Date.now();
      saveDb();
      console.log(`[tunnel] established for device ${deviceId} (${dev.name})`);
      // buf 中剩余字节作为首批帧数据
      if (buf.length > 0) {
        feedFrame(buf);
        buf = Buffer.alloc(0);
      }
      // 后续数据走帧解析
      sock.on('data', feedFrame);
      sock.on('close', () => {
        const rec = tunnels.get(deviceId);
        if (rec && rec.sock === sock) {
          tunnels.delete(deviceId);
          // 关闭关联的 WS 会话，避免挂起（客户端可重连）
          if (rec.wsSet) {
            for (const ws of rec.wsSet) {
              try { ws.close(4002, 'tunnel closed'); } catch { /* noop */ }
            }
            rec.wsSet.clear();
          }
          // 注册通道仍存活则保持在线，否则判离线
          if (dev) {
            const regAlive = registeredDevices.has(deviceId);
            dev.online = regAlive;
            if (!regAlive) dev.lastSeen = Date.now();
            saveDb();
          }
          console.log(`[tunnel] closed for device ${deviceId}`);
        }
      });
      sock.on('error', () => {
        if (tunnels.get(deviceId) && tunnels.get(deviceId).sock === sock) {
          tunnels.delete(deviceId);
        }
      });
    }
  };
  sock.on('data', onData);
  sock.on('error', () => { /* noop */ });
});
tunnelServer.listen(TUNNEL_PORT, HOST, () => {
  console.log(`[farm] tunnel TCP listener on ${HOST}:${TUNNEL_PORT}`);
});

server.listen(PORT, HOST, () => {
  console.log(`[farm] superphone-farm gateway listening on http://${HOST}:${PORT}`);
  console.log(`[farm] data dir: ${DATA_DIR}`);
  console.log(`[farm] token auth: ${TOKEN ? 'enabled' : 'disabled (LAN only!)'}`);
});
