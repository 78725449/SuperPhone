// SuperPhone 群控台前端：设备墙(实时画面) -> 聚焦视图(左画面+右操作列) -> 移动端悬浮操作簇
// rfb.js?v=2：noVNC 核心为 server 内存 patch，URL 带版本号强制浏览器重新拉取 patch 后的内容避免旧缓存
import RFB from '/novnc/core/rfb.js?v=4';
import { invokeCap, setConfigs, batchInvoke, batchSetConfigs, KEY_DEFS, BATCH_CAPS, CONFIG_BY_KEY, CONFIG_DEFS } from './caps.js?v=11';
import { attachPress } from './press.js';
import { attachFarmGesture, attachRightHome, resolveGesture } from './gesture.js';

const $ = (id) => document.getElementById(id);
const isMobile = () => window.matchMedia('(max-width: 900px)').matches;

// ---------- token ----------
const url = new URL(location.href);
let TOKEN = url.searchParams.get('token') || localStorage.getItem('farm_token') || '';
function setToken(t) {
  TOKEN = t || '';
  if (TOKEN) localStorage.setItem('farm_token', TOKEN);
  else localStorage.removeItem('farm_token');
}

// ---------- 容器参数（IPA WKWebView 容器 / 普通浏览器 双模） ----------
// IPA 控制端整 Tab 由 WKWebView 加载本页面（Web 容器化），经 URL 传入：
//   ?selfId=<DeviceUUID>   本设备标识：从设备墙过滤自身，避免卡片墙显示自己（与原生 handleDevices 一致）
//   ?container=ipa         容器模式标记：后续容器差异行为（如全屏接管/隐藏）按此分支
// 普通浏览器访问不带这些参数，行为与现状完全一致。
const SELF_ID = url.searchParams.get('selfId') || '';
const IS_IPA_CONTAINER = url.searchParams.get('container') === 'ipa';
// 暴露到 body data 属性与全局：CSS 可用 body[data-container="ipa"] 做容器样式差异，JS 模块可直接引用
document.body.dataset.container = IS_IPA_CONTAINER ? 'ipa' : 'web';
window.__FARM_CONTAINER = IS_IPA_CONTAINER;
if (IS_IPA_CONTAINER) console.info(`[farm] IPA container mode: selfId=${SELF_ID || '(none)'}`);

// ---------- api ----------
async function api(path, opts = {}) {
  const headers = { 'Content-Type': 'application/json', ...(opts.headers || {}) };
  if (TOKEN) headers['Authorization'] = `Bearer ${TOKEN}`;
  const res = await fetch(path, { ...opts, headers });
  if (res.status === 401) { showLogin(); throw new Error('unauthorized'); }
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}
function wsUrl(path, extra = {}) {
  const u = new URL(path, location.href);
  u.protocol = u.protocol === 'https:' ? 'wss:' : 'ws:';
  if (TOKEN) u.searchParams.set('token', TOKEN);
  for (const [k, v] of Object.entries(extra)) if (v) u.searchParams.set(k, v);
  return u.toString();
}

// ---------- state ----------
let devices = [];
let wallSession = 'wall-' + Date.now();
let wallInstances = new Map();   // deviceId -> { rfb, tile, statusEl, paused }
let focus = null;                // { device, rfb }
let selectedDevices = new Set(); // 批量操作选中的设备 ID 集合（Phase 10.2）
let fabSigTimer = null;          // 移动端 FAB 延迟轮询定时器

// ---------- login ----------
function showLogin() {
  if (document.getElementById('loginBox')) return;
  const wrap = document.createElement('div');
  wrap.id = 'loginBox';
  wrap.className = 'login';
  wrap.innerHTML = `
    <h3>控制台</h3>
    <input id="loginToken" type="password" placeholder="访问令牌 (FARM_TOKEN)" />
    <button id="btnLogin" class="primary">进入</button>`;
  document.body.prepend(wrap);
  $('btnLogin').onclick = async () => {
    setToken($('loginToken').value.trim());
    wrap.remove();
    try { await refreshDevices(); restoreFocusFromUrl(); } catch { showLogin(); }
  };
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// ---------- 设备墙（实时画面卡片） ----------
/**
 * 生成虚拟预览设备：用于本地查看卡片墙布局与多数比例自适应效果。
 * 比例分布：9:16 占多数（体现自适应选型），另含 16:9 / 3:4 / 20:9（体现 contain 黑边）。
 * @param {number} n 生成的虚拟设备数量
 * @returns {object[]} 虚拟设备数组（mock:true 标记，不参与真实拉流/批量操作）
 */
function makeMockDevices(n) {
  const sizes = [
    { w: 1080, h: 1920 }, { w: 1080, h: 1920 }, { w: 1080, h: 1920 }, // 9:16 占多数
    { w: 1920, h: 1080 }, { w: 1620, h: 2160 }, { w: 1080, h: 2400 }, // 16:9 / 3:4 / 20:9
  ];
  const arr = [];
  for (let i = 0; i < n; i++) {
    const s = sizes[i % sizes.length];
    arr.push({
      id: 'mock-' + (i + 1),
      name: '测试设备 ' + (i + 1),
      online: true,
      source: 'register',
      mock: true,
      screen: { width: s.w, height: s.h },
      lastSeen: Date.now(),
    });
  }
  return arr;
}
const MOCK_COUNT = 0;  // 虚拟预览设备数量，置 0 即关闭预览
const MOCK_DEVICES = makeMockDevices(MOCK_COUNT);

/**
 * 渲染虚拟设备占位画面：按设备屏幕尺寸生成等比 SVG 色块画面，
 * 复用 .thumb 的 object-fit:contain，直观展示不同比例在统一卡片中的黑边效果。
 * @param {HTMLElement} tv 卡片 .tv 容器元素
 * @param {object} d 虚拟设备对象（mock:true）
 * @returns {void}
 */
function renderMockScreen(tv, d) {
  const w = (d.screen && d.screen.width) || 1080;
  const h = (d.screen && d.screen.height) || 1920;
  const fs = Math.round(Math.min(w, h) / 16);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}">` +
    `<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">` +
    `<stop offset="0" stop-color="#1c2a44"/><stop offset="1" stop-color="#35527f"/>` +
    `</linearGradient></defs>` +
    `<rect width="${w}" height="${h}" fill="url(#g)"/>` +
    `<rect x="2" y="2" width="${w - 4}" height="${h - 4}" fill="none" stroke="#4a6ea8" stroke-width="${Math.max(3, Math.round(Math.min(w, h) / 120))}"/>` +
    `<text x="50%" y="48%" text-anchor="middle" dominant-baseline="middle" fill="#8fa8cf" font-size="${fs}" font-family="sans-serif">${escapeHtml(d.name)}</text>` +
    `<text x="50%" y="${48 + fs * 1.6}%" text-anchor="middle" dominant-baseline="middle" fill="#6d87b3" font-size="${Math.round(fs * 0.72)}" font-family="sans-serif">${w}×${h}</text>` +
    `</svg>`;
  tv.innerHTML = `<img class="thumb" src="data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}" alt="" />`;
}

let lastDevSig = ''; // 上次已应用比例的设备集合签名

/**
 * 生成在线设备集合签名：设备 id + 屏幕尺寸 + 在线状态。
 * 仅当签名变化时才重算卡片比例（变化驱动，替代每轮轮询重算）。
 * @returns {string} 排序拼接后的签名
 */
function devicesSignature() {
  return devices
    .filter((d) => d.online === true)
    .map((d) => d.id + ':' + ((d.screen && d.screen.width) || 0) + 'x' + ((d.screen && d.screen.height) || 0))
    .sort()
    .join('|');
}

async function refreshDevices() {
  const data = await api('/api/devices');
  // 容器模式（?selfId=）过滤自身设备：卡片墙不显示本设备（与 IPA 原生 handleDevices 的 UUID 去重一致）
  const remote = SELF_ID ? (data.devices || []).filter((d) => String(d.id) !== SELF_ID) : (data.devices || []);
  // 注入虚拟预览设备（MOCK_COUNT=0：预览关闭；置 >0 可查看卡片墙布局）
  devices = remote.concat(MOCK_DEVICES);
  const onlineCount = devices.filter((d) => d.online === true).length;
  $('empty').classList.toggle('hidden', devices.length > 0);
  $('meta').textContent = `共 ${devices.length} 台 · ${onlineCount} 在线 · ${devices.length - onlineCount} 离线`;

  // 聚焦中的设备掉线 -> 退出聚焦，回到墙（离线可见）
  if (focus) {
    const fdev = devices.find((d) => d.id === focus.device.id);
    if (!fdev || fdev.online === false) exitFocus();
  }

  // 移除已不存在的设备卡片（仅手动删除才会消失）
  for (const [id, inst] of wallInstances) {
    if (!devices.find((d) => d.id === id)) {
      stopWallRfb(inst);
      inst.tile.remove();
      wallInstances.delete(id);
      // 同步清理批量选中集合（Phase 10.2）
      selectedDevices.delete(id);
      // 直控模式：设备被移除应立即清理其直控 RFB（stopWallRfb 不处理 directRfbs）
      if (directRfbs.has(id)) {
        closeRfb(directRfbs.get(id));
        directRfbs.delete(id);
        updateDirectBtn();
      }
    }
  }
  updateBatchBar();
  // 渲染全部设备（在线=实时画面；离线=置灰占位+上次在线）
  for (const d of devices) {
    let inst = wallInstances.get(d.id);
    if (!inst) inst = createWallTile(d);
    updateWallTile(inst, d);
  }
  // 缩略图兜底（2026-08-21）：事件驱动之外，列表刷新后每张在线卡片补拉一次网关缓存
  // （首次加载 / WS 断线重连全量补齐；离线/聚焦/直控/同步卡片由 fetchThumb 内部跳过）
  for (const inst of wallInstances.values()) {
    fetchThumb(inst).catch(() => {});
  }
  // 卡片比例自适应：仅当在线设备集合/屏幕尺寸签名变化才更新 --tile-pb
  // （变化驱动，避免每次轮询都重算；轮询本身仍是设备发现机制）
  const sig = devicesSignature();
  if (sig !== lastDevSig) { lastDevSig = sig; applyAutoTileRatio(); }
  // 直控模式：新上线的在线真实设备自动补建直控 RFB，保持"所有在线设备直达控制"语义
  if (directMode) {
    let added = 0;
    for (const d of devices) {
      if (!d.online || d.mock || d.source !== 'register') continue;
      if (!directRfbs.has(d.id) && startDirectRfb(d)) added++;
    }
    if (added > 0) {
      updateDirectBtn();
      toast(`直控模式：新增 ${added} 台设备推流`, 'info');
    }
  }
}

// 设备列表变更推送订阅（2026-08-18）：后端经 /ws/events 广播设备上线/离线/删除/改名/排序，
// 前端收到后重拉 /api/devices，替代 6s 轮询（2026-08-19 轮询已移除）。
// 事件通知+前端重拉：后端只推 {type, deviceId}，前端 refreshDevices 拉全量保证一致性；
// thumb 事件特例（2026-08-21）：卡片存在时直接补拉该设备缩略图缓存，不触发全量刷新。
let eventsWS = null;
let eventsWSRetry = 0;
function connectEventsWS() {
  try { if (eventsWS) eventsWS.close(); } catch { /* noop */ }
  eventsWS = new WebSocket(wsUrl('/ws/events'));
  eventsWS.onopen = () => {
    eventsWSRetry = 0;
    // 重连成功后补拉全量：WS 断线期间的事件已错过（事件即推即弃，无重放），
    // 主动 refreshDevices 补齐（取代已移除的手动刷新按钮，2026-08-19）
    refreshDevices().catch(() => {});
  };
  eventsWS.onmessage = (ev) => {
    // 缩略图事件：设备 5901 经隧道发 RFB Raw 流 → 网关 ThumbRfbDecoder 解码 → 广播 {type:'thumb', deviceId}。
    // 卡片存在则直接补拉该设备缩略图（避免全量刷新）；未知事件类型保持原逻辑（refreshDevices 重拉全量）
    let msg = null;
    try { msg = JSON.parse(ev.data); } catch { /* 非 JSON 事件按全量刷新处理 */ }
    if (msg && msg.type === 'thumb') {
      const inst = wallInstances.get(msg.deviceId);
      if (inst) { fetchThumb(inst).catch(() => {}); return; }
    }
    if (msg && msg.type === 'state') {
      // 被控状态上报（2026-08-22）：设备控制开始/结束，重拉设备列表以刷新「被控制中」遮罩
      // （遮罩渲染在 updateWallTile 根据设备 controlled 字段叠加）
      refreshDevices().catch(() => {});
      return;
    }
    refreshDevices().catch(() => {});
  };
  eventsWS.onclose = () => {
    eventsWS = null;
    // WS 断线退避重连（2s 起，上限 30s）；死连接检测由后端心跳 ping/pong 负责
    // （长连接被 NAT/代理静默掐断时 TCP 层无感知，后端 terminate 会触发这里的 onclose）
    const delay = Math.min(2000 * Math.pow(2, eventsWSRetry++), 30000);
    setTimeout(connectEventsWS, delay);
  };
  eventsWS.onerror = () => { try { eventsWS.close(); } catch { /* noop */ } };
}

// 卡片墙横/竖屏显示偏好（2026-08-19）：按设备持久化（localStorage），仅影响该卡片在墙上的
// 显示比例。语义：竖屏=跟随全局统一比例（所有卡片一样大，现状）；横屏=设备 screen 比例倒置
// （inline --tile-pb 覆盖全局）。聚焦画面不受此影响——始终用设备实时帧尺寸自动适配方向。
const TILE_ORIENT_KEY = 'farm_tile_orient';
function getTileOrientMap() {
  try { return JSON.parse(localStorage.getItem(TILE_ORIENT_KEY) || '{}'); } catch { return {}; }
}
function getTileOrient(id) {
  return getTileOrientMap()[id] || 'portrait';
}
function setTileOrient(id, orient) {
  const m = getTileOrientMap();
  if (orient === 'portrait') delete m[id]; else m[id] = orient;
  localStorage.setItem(TILE_ORIENT_KEY, JSON.stringify(m));
}
/**
 * 应用卡片显示方向：横屏偏好 → 该卡片 --tile-pb 用设备比例倒置（(w/h)*100%），缩略图
 * 旋转 90° 铺满横容器（--tile-land-h 供 CSS 反算旋转前布局盒）；否则移除 inline 回全局
 * 统一比例。仅卡片视图（.wall-grid）生效——列表视图 padding 已被覆盖为固定行高。
 * @param {HTMLElement} tile 卡片元素
 * @param {object} d 设备对象
 * @returns {void}
 */
function applyTileOrient(tile, d) {
  if (!tile) return;
  if (getTileOrient(d.id) !== 'landscape') {
    tile.classList.remove('orient-land');
    tile.style.removeProperty('--tile-pb');
    tile.style.removeProperty('--tile-land-h');
    return;
  }
  const w = (d.screen && d.screen.width) || 1080;
  const h = (d.screen && d.screen.height) || 1920;
  tile.classList.add('orient-land');
  tile.style.setProperty('--tile-pb', ((w / h) * 100).toFixed(4) + '%');
  tile.style.setProperty('--tile-land-h', (w / h).toFixed(4));
}

function createWallTile(d) {
  const tile = document.createElement('div');
  tile.className = 'tile' + (d.online ? '' : ' tile-offline') + (d.mock ? ' tile-mock' : '');
  tile.innerHTML = `
    <div class="tv"></div>
    <input type="checkbox" class="tile-checkbox" title="勾选加入批量操作" />
    <div class="tile-bar">
      <span class="dot ${d.online ? 'on' : 'off'}"></span>
      <span class="tname">${escapeHtml(d.name)}</span>
      <span class="tstate">${d.online ? '已连接' : '离线'}</span>
      <button class="tmore" title="更多操作">⋯</button>
    </div>`;
  const tv = tile.querySelector('.tv');
  const statusEl = tile.querySelector('.tstate');
  const cb = tile.querySelector('.tile-checkbox');
  // 卡片墙画面获取：读网关缩略图缓存（设备 5901 经隧道发 RFB Raw 流 → 网关解码 → 事件驱动前端拉取），
  // 无轮询定时器；rfb 字段名沿用历史，实为缩略图获取状态标记（kind='thumb'）。
  const inst = { device: d, tile, statusEl, paused: false, rfb: null, checkbox: cb };
  // 恢复已选中状态（设备刷新后保持勾选）
  if (selectedDevices.has(d.id)) {
    cb.checked = true;
    tile.classList.add('tile-selected');
  }
  // 记录设备上报屏幕比例（仅供聚焦面板 prefit 使用；卡片墙本身统一 9:16 尺寸规格，
  // 不再按设备分辨率差异化 --tile-ratio，保证所有卡片一样大、画面 contain 完整显示）
  if (d.screen && d.screen.width && d.screen.height) {
    tile.dataset.wh = d.screen.width + 'x' + d.screen.height;
  }
  // 卡片墙横/竖屏显示偏好（2026-08-19）：按设备持久化，仅影响该卡片在墙上的显示比例
  // （竖屏=跟随全局统一比例；横屏=设备 screen 比例倒置）。聚焦画面始终实时跟随设备方向。
  applyTileOrient(tile, d);
  if (d.online) {
    tv.innerHTML = '<div class="offline-ph">已连接</div>';
    startWallRfb(inst);
  } else {
    tv.innerHTML = '<div class="offline-ph">离线</div>';
    statusEl.textContent = d.lastSeen ? '离线 · ' + fmtTime(d.lastSeen) : '离线';
  }
  wallInstances.set(d.id, inst);

  // checkbox 勾选切换：阻止冒泡避免触发卡片点击；同步模式下切换同步，否则切换批量选中
  cb.addEventListener('click', (e) => {
    e.stopPropagation();
    if (syncMode) toggleSync(d.id);
    else toggleSelect(d.id);
  });
  tile.addEventListener('click', (e) => {
    if (e.target.closest('.tmore')) return;
    if (e.target.closest('.tile-checkbox')) return;
    const dev = inst.device;
    if (dev.mock) { alert('虚拟设备仅用于布局预览，不可控制'); return; }
    // 批量选择模式：点卡片=切换选中（与复选框一致），不进入卡片控制（2026-08-19 用户拍板）
    if (batchMode) { toggleSelect(d.id); return; }
    if (directMode) return; // 直控模式：点击卡片直达 RFB 控制（canvas 输入事件由 noVNC 处理），不聚焦、无悬停提示
    if (syncMode) { toggleSync(d.id); return; } // 同步选择模式：点卡片切换同步（选中态=边框高亮+同步中）
    // 2026-08-22：被控制中（5801 直连 / 隧道）→ 卡片浮层显示「断开/接管」按钮（替代 confirm）
    if (dev.controlled) {
      showCtrlActions(dev, tile);
      return;
    }
    enterFocus(dev); // 离线设备由 enterFocus 收编进连接态浮层（不再弹 alert）
  });
  tile.querySelector('.tmore').addEventListener('click', (e) => {
    e.stopPropagation();
    if (d.mock) { alert('虚拟设备仅用于布局预览'); return; }
    showTileMenu(tile, d, e.clientX, e.clientY);
  });
  $('wall').appendChild(tile);
  return inst;
}

/**
 * 启动卡片墙画面获取（读网关缩略图缓存）
 * 功能：设备 5901 经隧道发 RFB Raw 流 → 网关 ThumbRfbDecoder 解码产 JPEG 缓存；前端事件驱动 GET /api/devices/:id/thumb 拉取渲染。
 *       无轮询定时器（2026-08-21 起 screen.hash/screenshot 轮询整体移除）：静止零流量，
 *       画面更新由网关 thumb 事件广播 + 设备列表刷新兜底驱动。卡片墙不建 RFB 持久连接。
 * @param {object} inst 卡片墙实例 { device, tile, statusEl, rfb, paused }
 * @returns {void}
 */
function startWallRfb(inst) {
  if (!inst || inst.paused || inst.rfb) return;
  const tv = inst.tile.querySelector('.tv');
  if (!tv) return;
  // 虚拟预览设备：不读取网关缓存，直接渲染等比 SVG 占位画面
  if (inst.device.mock) {
    renderMockScreen(tv, inst.device);
    if (inst.statusEl) inst.statusEl.textContent = '预览';
    return;
  }
  // 仅隧道设备（source=register）支持画面获取
  if (inst.device.source !== 'register') {
    tv.innerHTML = '<div class="offline-ph">未注册 · 请先配置网关</div>';
    if (inst.statusEl) inst.statusEl.textContent = '未注册';
    return;
  }
  // 2026-08-22：退出控制后统一显示「加载中…」占位（叠加在最后画面上方，无画面则纯占位），
  // 缩略图链路重建完成（fetchThumb 拉到）后移除——复用 .offline-ph 动画，不新增
  if (inst._lastFrame) {
    // 退出直控截图：先显示最后画面（img），fetchThumb 拉到缩略图后替换
    let img = tv.querySelector('img.thumb');
    if (!img) {
      img = document.createElement('img');
      img.className = 'thumb';
      img.alt = '';
      tv.appendChild(img);
    }
    img.classList.add('loaded'); // 立即显示截图（不淡入，退出直控要立刻看到画面）
    img.src = inst._lastFrame;
  }
  // 统一叠加「加载中…」占位（有画面时叠加在上方，无画面时纯占位；覆盖已有「已连接」占位）
  let ph = tv.querySelector('.offline-ph');
  if (!ph) {
    ph = document.createElement('div');
    ph.className = 'offline-ph overlay';
    ph.innerHTML = '<i class="spin"></i><span>加载中…</span>';
    tv.appendChild(ph);
  } else {
    ph.className = 'offline-ph overlay';
    ph.innerHTML = '<i class="spin"></i><span>加载中…</span>';
  }
  // rfb 字段仅为兼容既有 stopWallRfb/updateWallTile 引用，实为缩略图获取状态标记
  inst.rfb = { kind: 'thumb', closed: false, fetching: false };
  fetchThumb(inst);
}

/**
 * 读网关缩略图缓存并渲染到卡片（2026-08-21，替代 screen.hash/screenshot 轮询）
 * GET /api/devices/:id/thumb：200 { thumb: base64, ts } → 更新卡片 <img class="thumb"> 并记录 data-ts；
 * 204 无缓存 → 静默跳过。仅在线真实隧道设备；聚焦/直控/同步占用画面的卡片不拉取（互斥）。
 * 幂等：fetching 标记防并发重入；在途请求期间被 stopWallRfb 清理（rfb 置 null/closed）则放弃更新 DOM。
 * @param {object} inst 卡片墙实例
 * @returns {Promise<void>}
 */
async function fetchThumb(inst) {
  if (!inst || !inst.rfb || inst.rfb.closed || inst.rfb.kind !== 'thumb') return;
  const dev = inst.device;
  // 画面互斥与前置条件：聚焦中暂停、离线/虚拟/未注册设备无缓存可读
  if (inst.paused || dev.mock || dev.source !== 'register' || dev.online === false) return;
  if (inst.rfb.fetching) return;
  inst.rfb.fetching = true;
  try {
    const headers = TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {};
    const res = await fetch(`/api/devices/${encodeURIComponent(dev.id)}/thumb`, { headers });
    if (res.status !== 200) return; // 204 无缓存：静默跳过
    const data = await res.json();
    const tv = inst.tile && inst.tile.querySelector('.tv');
    if (!data.thumb || !tv) return;
    // 在途请求期间可能已被 stopWallRfb 清理（竞态：拉取中进入聚焦/设备离线）——空值保护
    if (!inst.rfb || inst.rfb.closed) return;
    // 2026-08-22：复用 img 元素只更新 src，避免 innerHTML 重建 DOM 触发 forced reflow
    let img = tv.querySelector('img.thumb');
    if (!img) {
      img = document.createElement('img');
      img.className = 'thumb';
      img.alt = '';
      tv.appendChild(img);
      // 淡入：下一帧加 .loaded 触发 opacity transition（同帧加类会合并样式不触发动画）
      requestAnimationFrame(() => img.classList.add('loaded'));
    }
    // 2026-08-22：移除直控残留 canvas（退出直控后 .tv 里 canvas 与 img 共存，canvas 会盖住缩略图）
    const oldCanvas = tv.querySelector('canvas');
    if (oldCanvas) oldCanvas.remove();
    img.src = `data:image/jpeg;base64,${data.thumb}`;
    // 2026-08-22：缩略图就绪，移除「加载中…」占位（最后画面快照 → 实时缩略图）
    const ph = tv.querySelector('.offline-ph');
    if (ph) ph.remove();
    if (data.ts) inst.tile.dataset.ts = data.ts;
    if (inst.statusEl) inst.statusEl.textContent = '';
  } catch (e) {
    // 读缓存失败保持现状（「加载中…」占位），下个事件/刷新再试
  } finally {
    if (inst.rfb) inst.rfb.fetching = false;
  }
}

function stopWallRfb(inst) {
  if (!inst) return;
  if (inst.rfb) {
    if (inst.rfb.kind === 'thumb') {
      inst.rfb.closed = true; // 缩略图获取无定时器/WS 可清；在途请求由 fetchThumb 检查 closed 后放弃
    } else {
      closeRfb(inst.rfb);
    }
    inst.rfb = null;
  }
  const tv = inst.tile && inst.tile.querySelector('.tv');
  if (tv) tv.innerHTML = '';
}

// ---------- 批量操作（Phase 10.2） ----------
/**
 * 切换设备选中状态：更新 selectedDevices Set 与卡片 checkbox UI，并刷新批量操作栏显隐
 * @param {string} deviceId 设备 ID
 * @returns {void}
 */
function toggleSelect(deviceId) {
  const dev = devices.find((d) => d.id === deviceId);
  if (dev && dev.mock) return; // 虚拟设备仅预览布局，不可加入批量操作
  if (dev && !dev.online) return; // 离线设备不可选中（2026-08-19：全选/单选均只允许在线设备）
  if (selectedDevices.has(deviceId)) {
    selectedDevices.delete(deviceId);
  } else {
    selectedDevices.add(deviceId);
  }
  const inst = wallInstances.get(deviceId);
  if (inst && inst.checkbox) {
    inst.checkbox.checked = selectedDevices.has(deviceId);
    inst.tile.classList.toggle('tile-selected', inst.checkbox.checked);
  }
  updateBatchBar();
}

/**
 * 全选当前可见的在线设备：跳过离线与虚拟设备（2026-08-19：只允许选中在线真实设备）
 * @returns {void}
 */
function selectAll() {
  for (const d of devices) {
    if (!d.online || d.mock) continue;
    selectedDevices.add(d.id);
  }
  for (const [id, inst] of wallInstances) {
    if (!inst.checkbox) continue;
    const on = devices.some((d) => d.id === id && d.online && !d.mock);
    inst.checkbox.checked = on;
    inst.tile.classList.toggle('tile-selected', on);
  }
  updateBatchBar();
}

/**
 * 取消全选：清空 selectedDevices 并清除所有 checkbox 勾选状态
 * @returns {void}
 */
function deselectAll() {
  selectedDevices.clear();
  for (const [, inst] of wallInstances) {
    if (inst.checkbox) {
      inst.checkbox.checked = false;
      inst.tile.classList.remove('tile-selected');
    }
  }
  updateBatchBar();
}

let batchMode = false; // 批量选择模式：点击"批量操作"进入，卡片出现复选框

/**
 * 更新批量操作组件（2026-08-19 顶部入口形态）：
 *   平时 = 顶部「批量」按钮 #batchBtn（直控右侧，移动端保留）；点击进入多选模式后，按钮变「取消」
 *   激活态（承担退出入口），墙区顶部出现全宽圆角胶囊行 #batchBar（[✓ 全选][已选 N 台] ...... [执行][设置]）。
 *   两者互斥显隐，并由 updateBatchBarExt 同步全选复选框状态与已选计数。
 * @returns {void}
 */
function updateBatchBar() {
  const entry = $('batchBtn');
  const bar = $('batchBar');
  if (entry) {
    const active = batchMode;
    entry.classList.toggle('batch-bar-active', active);
    entry.textContent = active ? '取消' : '批量';
    entry.title = active ? '取消：退出批量选择模式' : '批量：点击进入多选模式（墙区顶部出现全选操作条）';
  }
  if (bar) bar.classList.toggle('active', batchMode);
  updateBatchBarExt();
}

/**
 * 更新批量悬浮条（#batchBar）：全选按钮两态文案（全部在线设备已选中 → "取消全选"）+
 * 已选计数。由 updateBatchBar 每次选中变化时调用。
 * @returns {void}
 */
function updateBatchBarExt() {
  const cb = $('batchBarSelectAll');
  const cnt = $('batchBarCount');
  if (cb) {
    const online = devices.filter((d) => d.online && !d.mock);
    cb.checked = batchMode && online.length > 0 && online.every((d) => selectedDevices.has(d.id));
  }
  if (cnt) cnt.textContent = `已选 ${selectedDevices.size} 台`;
}

/**
 * 进入批量选择模式：所有卡片显示左上角复选框（CSS .batch-mode 驱动）
 * @returns {void}
 */
let _fabHiddenForBatch = false; // 批量模式隐藏 FAB 前的可见状态（退出时恢复）

function enterBatchMode() {
  batchMode = true;
  const wall = $('wall');
  if (wall) wall.classList.add('batch-mode');
  // 展开全宽条会遮挡右下角 FAB，批量模式临时隐藏，退出恢复
  const fab = $('fab');
  if (fab && !fab.classList.contains('hidden')) { _fabHiddenForBatch = true; fab.classList.add('hidden'); }
  updateBatchBar();
}

/**
 * 退出批量选择模式：隐藏复选框并清空选中状态，按钮复位
 * @returns {void}
 */
function exitBatchMode() {
  batchMode = false;
  const wall = $('wall');
  if (wall) wall.classList.remove('batch-mode');
  const fab = $('fab');
  if (fab && _fabHiddenForBatch) { fab.classList.remove('hidden'); _fabHiddenForBatch = false; }
  selectedDevices.clear();
  for (const inst of wallInstances.values()) {
    if (inst.checkbox) inst.checkbox.checked = false;
    if (inst.tile) inst.tile.classList.remove('tile-selected');
  }
  updateBatchBar();
}

/**
 * 关闭批量菜单：仅移除菜单与其挂载的按压识别/外部点击处理器（防定时器泄漏），
 * 不退批量模式——胶囊行保持展开（2026-08-19：胶囊行仅在点击顶部「取消」时收起）
 * @param {HTMLElement} menu 批量菜单元素
 * @returns {void}
 */
function closeBatchMenu(menu) {
  if (menu && typeof menu.__outsideHandler === 'function') document.removeEventListener('click', menu.__outsideHandler);
  if (menu && typeof menu.__detach === 'function') { try { menu.__detach(); } catch { /* noop */ } }
  if (menu && menu.parentNode) menu.remove();
}

/**
 * 关闭批量菜单并退出批量模式（仅顶部「取消」按钮路径调用）
 * @param {HTMLElement} menu 批量菜单元素
 * @returns {void}
 */
function finishBatch(menu) {
  closeBatchMenu(menu);
  exitBatchMode();
}

/**
 * 弹出批量执行菜单：勾选设备后点顶部胶囊行「执行」触发（再点「执行」收起，开合二态）。
 * 布局对齐触控端悬浮菜单（2026-08-19）：纯「图标+名称」按钮垂直列表，无大标题/无分组标签；
 * 按键按钮复用控制台右侧按键的实现通道（attachPress 按压识别：单击/双击/三击/长按 → capId →
 * 批量 invoke）——批量态对 BATCH_CAPS 具多击能力的键补声明多击窗口（Home 双击 → home.double）；
 * 长按通道对齐控制台右侧：显式 .long 能力触发（Home 长按 → home.long）、按压式按键（音量/亮度/静音）
 * 长按 = 按住连发基础能力（抬起停止）、键盘/搜索维持单击；电源/截图键不入批量菜单（批量误触电源有锁屏
 * 风险）；批量配置入口已移至「设置」按钮（菜单不再重复）；菜单无取消按钮（点外部关闭，或点顶部「批量」
 * 变「取消」态退出）。
 * @returns {void}
 */
function showBatchMenu() {
  // 执行候选仅保留在线真实设备（2026-08-19：离线/虚拟设备不可参与批量操作）
  const ids = Array.from(selectedDevices).filter((id) => {
    const d = devices.find((x) => x.id === id);
    return d && d.online && !d.mock;
  });
  if (ids.length === 0) { toast('没有可操作的在线设备', 'error'); return; }

  // 关闭已存在菜单
  const old = document.getElementById('batchMenu');
  if (old) old.remove();

  const menu = document.createElement('div');
  menu.id = 'batchMenu';
  menu.className = 'batch-menu';

  // 按键按钮：与控制台右侧按键同一实现通道（attachPress 按压识别），剔除截图键（snapshot：批量
  // 下发无收集画面意义）与电源键（power：批量误触电源有锁屏/关机风险，2026-08-19）。
  // 长按连发状态（2026-08-19）：按压式按键（音量/亮度/静音）长按 = 按住持续下发基础能力，
  // 对齐控制台右侧 HID down 按住 OS 自动重复的语义；抬起（up）即停止。
  // 手感优化（2026-08-19）：长按判定 800→500ms（attachPress longMs）、连发间隔 400→200ms，
  // 接近控制台 OS 重复速率（仍受 API 网络往返影响，属批量通道固有差异）。
  // 修复前：这些键 events 无 long 声明 → attachPress 不挂长按定时器 → 长按无反应/回落单击。
  let holdTimer = null;
  const stopHold = () => { if (holdTimer) { clearInterval(holdTimer); holdTimer = null; } };
  const startHold = (fn) => { stopHold(); holdTimer = setInterval(fn, 200); };

  const cleanups = [];
  const detachAll = () => {
    stopHold(); // 菜单销毁时兜底停止长按连发（防定时器泄漏）
    for (const f of cleanups) { try { f(); } catch { /* noop */ } }
  };
  for (const k of KEY_DEFS) {
    if (k.key === 'snapshot' || k.key === 'power') continue;
    const b = document.createElement('button');
    b.className = 'batch-cap-btn';
    b.innerHTML = '<span class="cap-icon">' + (k.svg || escapeHtml(k.icon || '?')) + '</span><span class="cap-name">' + escapeHtml(k.title) + '</span>';
    // 批量态按压事件：在 KEY_DEFS 事件基础上补声明 BATCH_CAPS 中的多击显式能力（如 home.double）。
    // 长按通道对齐控制台：有显式 .long 能力（home.long）→ 触发显式能力；按压式按键（down/up，
    // 音量/亮度/静音）→ '.hold' 按住连发；无 down/up 的键（键盘/搜索）维持单击（与控制台一致）
    const batchEvents = { ...k.events };
    if (BATCH_CAPS.some((c) => c.id === k.key + '.double')) batchEvents.double = k.key + '.double';
    if (BATCH_CAPS.some((c) => c.id === k.key + '.triple')) batchEvents.triple = k.key + '.triple';
    const hasLongCap = BATCH_CAPS.some((c) => c.id === k.key + '.long');
    if (hasLongCap) batchEvents.long = k.key + '.long';
    else if (k.events && k.events.down) batchEvents.long = k.key + '.hold';
    const baseMeta = BATCH_CAPS.find((c) => c.id === k.key);
    const bk = { ...k, events: batchEvents };
    cleanups.push(attachPress(b, bk, { invoke: (capId) => {
      if (k.events && k.events.up && capId === k.events.up) { stopHold(); return; } // 抬起结束按住连发
      if (batchEvents.long === k.key + '.hold' && capId === k.key + '.hold') {   // 长按 → 按住连发基础能力
        if (baseMeta) startHold(() => doBatchInvoke(ids, baseMeta));
        return;
      }
      const meta = BATCH_CAPS.find((c) => c.id === capId) || baseMeta;
      if (meta) doBatchInvoke(ids, meta);
    }, longMs: 500 })); // 长按判定 500ms（默认 800ms 太钝，批量连发需更快响应）
    menu.appendChild(b);
  }
  // 重启服务（2026-08-19：释放所有按键/硬件键盘锁/解锁已去除——type.paste 内部自带按键清理、
  // 键盘锁为单台硬件键盘维护操作，不适合批量下发）
  const restartMeta = BATCH_CAPS.find((c) => c.id === 'service.restart');
  if (restartMeta) {
    const b = document.createElement('button');
    b.className = 'batch-cap-btn';
    b.innerHTML = '<span class="cap-icon">' + (restartMeta.svg || escapeHtml(restartMeta.icon || '?')) + '</span><span class="cap-name">' + escapeHtml(restartMeta.title || restartMeta.id) + '</span>';
    b.addEventListener('click', () => doBatchInvoke(ids, restartMeta));
    menu.appendChild(b);
  }

  // 卸载钩子：菜单销毁时 detach 按压识别（防定时器泄漏）
  menu.__detach = detachAll;

  // 锚定「执行」按钮向下展开（2026-08-19）：左边缘对齐执行按钮左边缘、顶部贴按钮下方；
  // 下方空间不足时自动改向上展开（执行按钮贴底时），钳制防溢出屏幕
  const execBtn = $('batchBarExec');
  if (execBtn) {
    const r = execBtn.getBoundingClientRect();
    const menuH = 320; // 估算菜单高度（用于下方空间判断）
    const below = r.bottom + 8;
    const top = (below + menuH <= window.innerHeight) ? below : Math.max(8, r.top - 8 - menuH);
    menu.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 240 - 8)) + 'px';
    menu.style.top = top + 'px';
  }

  document.body.appendChild(menu);
  // 点击外部仅关闭菜单、不退批量模式（胶囊行保持展开，仅顶部「取消」可收起——2026-08-19）；
  // 处理器引用存 menu.__outsideHandler，供 closeBatchMenu 移除（防残留误关）
  setTimeout(() => {
    const handler = (e) => {
      if (!e.target.closest('#batchMenu') && !e.target.closest('#batchBtn') && !e.target.closest('#batchBar')) {
        closeBatchMenu(menu);
        document.removeEventListener('click', handler);
      }
    };
    menu.__outsideHandler = handler;
    document.addEventListener('click', handler);
  }, 0);
}

/**
 * 批量调用能力：对选中设备逐台调用 invoke（若有参数先弹表单）
 * @param {string[]} ids 设备 ID 数组
 * @param {object} meta 能力元数据 { id, title, params }
 * @returns {Promise<void>}
 */
async function doBatchInvoke(ids, meta) {
  let params = {};
  if (Array.isArray(meta.params) && meta.params.length > 0) {
    params = await promptParams(meta.params, meta.title);
    if (params === null) return;
  }
  try {
    const r = await batchInvoke('', ids, meta.id, params);
    const fails = (r.results || []).filter((x) => !x.ok);
    // 2026-08-19：批量结果用页内 toast（非阻塞，不再弹系统 alert 挡住其他区域操作）
    if (fails.length === 0) toast(`✓ 已对 ${ids.length} 台设备下发「${meta.title || meta.id}」`, 'success');
    else toast(`✗ 部分设备执行失败：${fails.map((x) => `${x.deviceId}: ${x.error || ''}`).join('，')}`, 'error');
  } catch (e) {
    toast(`✗ 批量调用「${meta.title || meta.id}」失败：${e.message}`, 'error');
  }
}

/**
 * 弹出批量配置面板：按 CONFIG_DEFS 静态定义渲染表单，保存后调用 batchSetConfigs
 * @param {string[]} ids 设备 ID 数组
 * @returns {Promise<void>}
 */
async function showBatchConfigPanel(ids) {
  // 2026-08-13：配置表单定义静态化（CONFIG_DEFS），不再从设备 configSchema 并集
  const schemaMap = new Map();
  for (const s of CONFIG_DEFS) {
    if (s && s.key && !schemaMap.has(s.key)) schemaMap.set(s.key, s);
  }
  const modal = document.createElement('div');
  modal.className = 'modal';
  const card = document.createElement('div');
  card.className = 'modal-card';
  card.innerHTML = `<h3>批量配置（${ids.length} 台设备）</h3>`;

  if (schemaMap.size === 0) {
    const empty = document.createElement('div');
    empty.style.color = 'var(--muted)';
    empty.textContent = '选中设备未上报可配置项';
    card.appendChild(empty);
  } else {
    // 按能力板块分组渲染（2026-08-21 设计文档 7 章：与 App 设置页一致 连接/直连/画面/交互/保活/关于；
    // group 为 null 或缺失的项 UI 隐藏——FabAutoCollapse 等固定行为项）
    const GROUP_ORDER = [
      { key: 'connection',  title: '连接' },
      { key: 'direct',      title: '直连' },
      { key: 'display',     title: '画面' },
      { key: 'interaction', title: '交互' },
      { key: 'keepalive',   title: '保活' },
      { key: 'about',       title: '关于' },
    ];
    const inputs = {};
    for (const g of GROUP_ORDER) {
      const groupSchemas = Array.from(schemaMap.values()).filter((s) => s.group === g.key);
      if (groupSchemas.length === 0) continue;
      const sec = document.createElement('div');
      sec.className = 'cfg-section';
      const title = document.createElement('div');
      title.className = 'cfg-sec-title';
      title.textContent = g.title;
      sec.appendChild(title);
      for (const schema of groupSchemas) {
        const row = document.createElement('label');
        row.className = 'cfg-row';
        row.textContent = schema.title || schema.key;
        const inp = buildConfigInput(schema, undefined);
        inputs[schema.key] = inp;
        row.appendChild(inp);
        sec.appendChild(row);
      }
      card.appendChild(sec);
    }

    const btns = document.createElement('div');
    btns.className = 'modal-btns';
    const cancel = document.createElement('button');
    cancel.textContent = '取消';
    const save = document.createElement('button');
    save.className = 'primary';
    save.textContent = '保存';
    btns.appendChild(cancel);
    btns.appendChild(save);
    card.appendChild(btns);

    cancel.onclick = () => modal.remove();
    save.onclick = async () => {
      const cfg = {};
      for (const [key, inp] of Object.entries(inputs)) {
        cfg[key] = readConfigValue(inp);
      }
      try {
        const r = await batchSetConfigs('', ids, cfg);
        const fails = (r.results || []).filter((x) => x.results && Object.values(x.results).some((v) => !v.ok));
        // 2026-08-19：批量配置结果同样走页内 toast，非阻塞
        if (fails.length === 0) {
          modal.remove();
          toast(`✓ 已对 ${ids.length} 台设备下发配置`, 'success');
        } else {
          toast(`✗ 部分设备配置失败：${fails.map((x) => x.deviceId).join('，')}`, 'error');
        }
      } catch (e) {
        toast(`✗ 批量保存失败：${e.message}`, 'error');
      }
    };
  }

  // 若无配置项，仅提供关闭按钮
  if (schemaMap.size === 0) {
    const btns = document.createElement('div');
    btns.className = 'modal-btns';
    const close = document.createElement('button');
    close.textContent = '关闭';
    btns.appendChild(close);
    card.appendChild(btns);
    close.onclick = () => modal.remove();
  }

  modal.appendChild(card);
  document.body.appendChild(modal);
}

// ---------- 控制台操作菜单（07 §4.1：按键区 KEY_DEFS + 动作区本地按钮） ----------
// 适配/全屏/断开为控制台本地操作，不在能力清单内，由静态按钮提供
/**
 * 按键区 RFB 直发：与画布同通道（noVNC sendKey/_sendMouse），低延迟、时序保证、纳入广播。
 * 按 capId 推断按压事件（click/double/triple/long/down/up），用 keyDef 的 keysym/ptr 发对应时序。
 * @param {object} rfb    - noVNC RFB 实例（focus.rfb）
 * @param {object} keyDef - KEY_DEFS 按键对象（含 ks/code/ptr）
 * @param {string} capId  - 触发的能力 id（含事件类型信息，如 home.double/volup.down）
 * @returns {void}
 */
function rfbPressKey(rfb, keyDef, capId) {
  const ev = capId.includes('.') ? capId.split('.').pop() : 'click';
  // noVNC 1.7.0 无公开 sendPointer(x, y, mask)，等价内部实现为 _sendMouse(x, y, mask)
  // （参数语义一致：x/y 显示坐标、mask 为 RFB 按钮掩码 bit1=中键=2）；
  // 未来版本若公开 sendPointer 则自动优先；sendKey/_sendMouse 异常静默忽略，防中断按压状态机
  const send = (f) => { try { f(); } catch (e) { /* noVNC API 异常静默忽略 */ } };
  const tap = () => {
    if (keyDef.ptr) {
      send(() => rfb.sendPointer ? rfb.sendPointer(0, 0, keyDef.ptr) : rfb._sendMouse(0, 0, keyDef.ptr));
      setTimeout(() => send(() => rfb.sendPointer ? rfb.sendPointer(0, 0, 0) : rfb._sendMouse(0, 0, 0)), 60);
    } else {
      send(() => rfb.sendKey(keyDef.ks, keyDef.code, true));
      setTimeout(() => send(() => rfb.sendKey(keyDef.ks, keyDef.code, false)), 60);
    }
  };
  const down = () => { if (keyDef.ptr) send(() => rfb.sendPointer ? rfb.sendPointer(0, 0, keyDef.ptr) : rfb._sendMouse(0, 0, keyDef.ptr)); else send(() => rfb.sendKey(keyDef.ks, keyDef.code, true)); };
  const up = () => { if (keyDef.ptr) send(() => rfb.sendPointer ? rfb.sendPointer(0, 0, 0) : rfb._sendMouse(0, 0, 0)); else send(() => rfb.sendKey(keyDef.ks, keyDef.code, false)); };
  switch (ev) {
    case 'down': down(); break;
    case 'up': up(); break;
    case 'double': tap(); setTimeout(tap, 120); break;
    case 'triple': tap(); setTimeout(tap, 100); setTimeout(tap, 200); break;
    case 'long': down(); setTimeout(up, 800); break;
    default: tap(); break; // click
  }
}

// ---------- 键盘按钮（2026-08-16 双通道输入：iOS 软键盘 input/composition 事件） ----------
// 「键盘」键 = 单向固定：发 XF86Keyboard 收起被控端软键盘，触控端再 focusKbdInput 调起控制端
// 软键盘（电脑端有实体键盘，不调软键盘）。iOS 系统软键盘不产生 keydown/keyup（WebKit 只派发
// input/composition 事件），noVNC Keyboard(keydown) 方案在 iOS 上失效（§2.3w 研究结论）。
// 输入按字符分流（2026-08-16 方案）：
//   - 英文/数字（单可打印 ASCII）：kbdSendAscii 键值直发（前端补/不补 Shift 信号，
//     设备端 keyDown/keyUp 直接映射不补 Shift）
//   - 中文/emoji/多字符：type.paste 能力注入（写被控端剪贴板 + 模拟 Cmd+V），
//     被控端弹一次系统隐私确认后落入聚焦输入框
//   - 中文/智能输入：compositionend 整段提交
//   - 删除键 = 向被控端发一次 Backspace（keysym 直发，删除操作被控设备）；
//     长按删除为重复 input 事件 → 连续 Backspace
// 被控端键盘完全由被控端系统管理（点被控画面输入框才弹），控制端不注入 attach/detach。
// 演进记录：2026-08-14 noVNC Keyboard(keydown) → 2026-08-15 上午 input 逐键 keysym(ASCII)+
// 粘贴(中文) A+B 混合 → 2026-08-15 下午统一粘贴通道 → 2026-08-16 英文/数字改回键值直发
// （方案 C：设备端不补 Shift，前端补/不补 Shift 信号）。
let kbdComposing = false;     // 中文拼音组合中：暂停转发，compositionend 一次性注入
let kbdJustComposed = false;  // Safari 在 compositionend 后补发 input（isComposing 乱序），短窗口忽略
let kbdJustComposedTimer = null;
let kbdLastLen = 0;           // 上次 input 处理后 kbi.value 长度（删除键识别快照：变短=删除）
// Shift 状态跟踪（2026-08-16 方案 C 修正）：连续大写/符号期间 Shift 保持按下，仅切回小写/数字才抬起，
// 避免快速连打大写时「前一个字符的 Shift↑ 提前抬起、后一个字符失去 Shift 修饰」的交错。
let kbdShiftHeld = false;   // 当前 Shift 是否按下（仅当前会话内状态，非全局）
let kbdShiftTimer = null;   // 空闲自动释放 Shift 的定时器（停止输入 400ms 后自动抬 Shift 防残留）
/** 触屏能力判定：仅用于"自动弹控制端软键盘"（PC 无系统软键盘）；按钮开关行为本身无判定 */
const isTouchable = () => 'ontouchstart' in window || (navigator.maxTouchPoints || 0) > 0;

/** 聚焦隐藏 input 唤起控制端软键盘（iOS 对文本输入元素 focus 才弹键盘）。
 *  仅负责 focus 弹起控制端软键盘；收起被控端键盘由键盘按钮单独发 XF86Keyboard（避免重复）。 */
function focusKbdInput() {
  const kbi = document.getElementById('kbdInput');
  if (!kbi) return;
  try {
    kbi.focus();
    if (kbi.setSelectionRange) kbi.setSelectionRange(kbi.value.length, kbi.value.length);
  } catch (e) { /* 忽略 */ }
}

/**
 * 收起控制端软键盘（blur 触发系统收起）。
 * iOS Safari 对隐藏 input 直接 blur() 常不收起系统软键盘（焦点行为差异、收起异步），
 * 是"控制端软键盘残留 + 被控键盘弹出 = 两个键盘同时显示"的根因之一。
 * 组合手段确保收起：activeElement.blur + readonly 切换（iOS 经典 trick，延时恢复 readonly）。
 * @returns {void}
 */
function blurKbdInput() {
  const kbi = document.getElementById('kbdInput');
  if (!kbi) return;
  releaseKbdShift(); // 收起键盘时兜底释放 Shift，防残留
  try { if (document.activeElement && document.activeElement.blur) document.activeElement.blur(); } catch (e) { /* 忽略 */ }
  try {
    kbi.setAttribute('readonly', 'readonly');
    kbi.blur();
  } catch (e) { /* 忽略 */ }
  setTimeout(() => { try { kbi.removeAttribute('readonly'); } catch (e) {} }, 120);
}

/**
 * 释放 Shift（若当前持有）：发 Shift_L↑ 并清状态与空闲定时器。
 * 供删除/回车/中文粘贴等「不应带 Shift 修饰」的操作前置调用，及 blur/退出时兜底防残留。
 * @returns {void}
 */
function releaseKbdShift() {
  if (!kbdShiftHeld) return;
  if (kbdShiftTimer) { clearTimeout(kbdShiftTimer); kbdShiftTimer = null; }
  const rfb = focus && focus.rfb;
  if (rfb && rfb._farmConnected) {
    try { rfb.sendKey(0xffe1, 'ShiftLeft', false); } catch (e) { /* 静默 */ }
  }
  kbdShiftHeld = false;
}

/**
 * 重置「空闲自动释放 Shift」定时器：发大写/符号字符后调用，停止输入 400ms 后自动抬 Shift，
 * 避免用户停止打字后 Shift 一直残留按下（导致后续被控端输入被 Shift 修饰）。
 * @returns {void}
 */
function resetKbdShiftTimer() {
  if (kbdShiftTimer) clearTimeout(kbdShiftTimer);
  kbdShiftTimer = setTimeout(releaseKbdShift, 400);
}

/**
 * 发送特殊键（退格/回车等）到当前聚焦设备（down + 60ms 按住 + up，与两端单击按键统一时长）。
 * 删除键 = 向被控端发一次 Backspace 按键事件（删除操作被控设备，非控制端本地）。
 * @param {number} keysym X11 keysym
 * @param {string} code   DOM code（用于 noVNC qemu 扩展 scancode 路径，可为 null）
 * @returns {void}
 */
function kbdSendSpecial(keysym, code, releaseMs = 60) {
  const rfb = focus && focus.rfb;
  if (!rfb || !rfb._farmConnected) return;
  releaseKbdShift(); // 删除/回车不应带 Shift 修饰，先释放（防连续大写后 Shift 残留）
  try {
    rfb.sendKey(keysym, code || null, true);
    setTimeout(() => {
      try { rfb.sendKey(keysym, code || null, false); } catch (e) { /* 静默 */ }
    }, releaseMs);
  } catch (e) { /* noVNC API 异常静默忽略 */ }
}

/**
 * 提交软键盘文本到当前聚焦设备：走 type.paste 能力注入（写被控端剪贴板 +
 * releaseEveryKeys + 异步模拟 Cmd+V，被控端弹一次系统隐私确认后落入聚焦输入框）。
 * 仅用于中文/emoji/多字符（2026-08-16 起英文/数字 ASCII 改走 kbdSendAscii 键值直发）。
 * @param {string} text 要注入的文本
 * @returns {void}
 */
function kbdCommitText(text) {
  if (!text) return;
  releaseKbdShift(); // 中文/emoji 粘贴走 type.paste 能力通道，不应带 Shift 修饰
  if (focus && focus.device) {
    submitPasteText(focus.device.id, text);
  }
}

/**
 * 发送单个字符到当前聚焦设备（键值直发，非粘贴）。
 * 前端根据字符判断「补/不补 Shift」信号（方案 C：设备端 keyDown/keyUp 直接映射不补 Shift）。
 * Shift 采用「状态跟踪」而非「每字符独立补 Shift」（2026-08-16 修正交错）：
 *   - 需要 Shift 且未持有 → 发 Shift_L(0xffe1)↓、置持有；连续大写/符号期间 Shift 保持按下。
 *   - 不需要 Shift 且持有 → 发 Shift_L↑、清持有（切回小写/数字时抬起）。
 *   - 字符键：基础字符↓，50ms 后基础字符↑（不再在 up 里顺带抬 Shift）。
 * 50ms 为字符按住时长（模拟真实按键，避免 down/up 太近被 iOS 判无效）。
 * 多字符/非 ASCII → 回退粘贴（kbdCommitText，中文/emoji/粘贴场景）。
 * @param {string} ch 本次 input 事件的增量文本（通常单字符）
 * @returns {void}
 */
function kbdSendAscii(ch) {
  if (!ch) return;
  if (ch.length !== 1) { kbdCommitText(ch); return; }
  const code = ch.charCodeAt(0);
  if (code < 0x20 || code > 0x7e) { kbdCommitText(ch); return; }
  const rfb = focus && focus.rfb;
  if (!rfb || !rfb._farmConnected) return;

  // 判断是否需要 Shift，得到基础字符（无 shift 字符）
  let shift = false, base = ch;
  if (code >= 0x41 && code <= 0x5a) { // A-Z → Shift + 小写
    shift = true; base = String.fromCharCode(code + 0x20);
  } else {
    const shifted = { '!':'1','@':'2','#':'3','$':'4','%':'5','^':'6','&':'7','*':'8','(':'9',
                      ')':'0','_':'-','+':'=','{':'[','}':']','|':'\\',':':';','"':"'",'<':',','>':'.','?':'/','~':'`' };
    if (shifted[ch]) { shift = true; base = shifted[ch]; }
  }
  const baseSym = base.charCodeAt(0); // 可打印 ASCII keysym == 码点

  try {
    // 按需切换 Shift：需要且未持有 → 按下；不需要且持有 → 抬起（连续大写期间保持按下不抬）
    if (shift && !kbdShiftHeld) {
      rfb.sendKey(0xffe1, 'ShiftLeft', true); // XK_Shift_L ↓
      kbdShiftHeld = true;
    } else if (!shift && kbdShiftHeld) {
      releaseKbdShift();                       // 切回小写/数字 → Shift_L ↑
    }
    rfb.sendKey(baseSym, null, true);          // 基础字符 ↓
    setTimeout(() => {
      try { rfb.sendKey(baseSym, null, false); } catch (e) { /* 静默 */ } // 基础字符 ↑
    }, 50);
    if (shift) resetKbdShiftTimer();           // 发大写/符号后重置空闲自动释放
  } catch (e) { /* noVNC API 异常静默忽略 */ }
}

/**
 * 初始化控制端软键盘输入（2026-08-16 起英文/数字改走键值直发，中文/emoji 保留粘贴）：
 * 绑定 #kbdInput 的 input/composition/keydown 事件（iOS 软键盘唯一可靠的事件源）：
 *   - compositionend：中文/emoji/智能输入整段提交（type.paste）
 *   - 非组合 input：删除键 → Backspace 直发被控端；
 *     英文/数字（单可打印 ASCII）→ kbdSendAscii 键值直发（前端自行发/释放 Shift）；
 *     多字符/非 ASCII → 回退粘贴
 *   - keydown：回车/换行/发送 → Enter keysym 直发被控端（单行 input 无 insertLineBreak）
 * 软键盘在「键盘」键点击后弹出（仅触控端；见 renderCapOps 键盘键绑定）。
 * @returns {void}
 */
function initTouchKeyboard() {
  const kbi = document.getElementById('kbdInput');
  if (!kbi) return;

  // 占位空格保持 value 非空：iOS 空 input 上点删除键不触发 input 事件（没内容可删），
  // 删除键因此失效。靠占位让删除键始终触发 inputType=deleteContentBackward（删占位空格）。
  kbi.value = ' ';
  kbdLastLen = 1;

  // 中文拼音组合开始：暂停转发（拼音过程不注入，compositionend 一次性提交）
  kbi.addEventListener('compositionstart', () => { kbdComposing = true; });
  // 组合结束：拿最终文本（中文/emoji/智能输入英文）整段提交
  kbi.addEventListener('compositionend', (e) => {
    kbdComposing = false;
    const text = e.data || '';
    kbi.value = ' ';
    kbdLastLen = 1;
    // Safari 在 compositionend 后可能补发一个 input（isComposing 乱序 bug）：短窗口忽略
    kbdJustComposed = true;
    if (kbdJustComposedTimer) clearTimeout(kbdJustComposedTimer);
    kbdJustComposedTimer = setTimeout(() => { kbdJustComposed = false; }, 60);
    kbdCommitText(text);
  });
  // 输入事件：删除键 / 回车 / 英文逐键键值直发（中文/emoji 走 compositionend 粘贴通道）
  kbi.addEventListener('input', (e) => {
    // compositionend 后短窗口（60ms）iOS 会补发乱序 input：只清空不转发
    if (kbdJustComposed) { kbi.value = ' '; return; }
    // composition 会话中：不干预 kbi.value（iOS IME 拥有所有权）。
    // 【2026-08-15 修复】此前在此执行 kbi.value='' 会破坏 iOS IME 状态机：
    // compositionend 不再触发 → kbdComposing 卡 true → 中英文 input 全被吞 → 不上屏。
    // 拼音/智能输入的过程字符（insertCompositionText）由 compositionend 一次性提交。
    if (kbdComposing) return;

    const v = kbi.value;
    const dt = e.inputType || '';
    // 删除键识别（2026-08-15 修复"删除不生效"）：优先用 iOS 删除键标准事件
    // inputType=deleteContentBackward（与本地 value 无关——删除操作的是被控端，
    // 控制端 input 可能为空/已清空，value 变短检测会漏掉）。长按删除 = 重复该事件。
    // value 变短仅作兜底（iOS 事件异常时）。删除键语义 = 操作被控设备：
    // 向被控端发一次 Backspace 按键事件（长按=连续删除）。
    if (dt === 'deleteContentBackward' || v.length < kbdLastLen) {
      kbdSendSpecial(0xff08, 'Backspace'); // XK_BackSpace → 被控端删字
      // 删除后立即重置占位：浮层只做"删除触发器"，value 始终保持非空，删除键持续触发 input
      kbi.value = ' ';
      kbdLastLen = 1;
      return;
    }
    // 英文/数字：单可打印 ASCII 走键值直发（kbdSendAscii），多字符/非 ASCII 回退粘贴
    const inc = e.data || '';
    if (inc) kbdSendAscii(inc);
    kbi.value = ' ';
    kbdLastLen = 1;
  });

  // 回车/换行/发送：iOS 单行 input 按 return 不触发 input（不插换行），只派发 keydown(13)，
  // 故不能用 input 的 insertLineBreak（单行 input 永不触发）。捕获 Enter → 发 XK_Return，
  // 由被控端按聚焦场景识别为发送/换行/搜索。
  // 2026-08-19 回退记录：曾为 PC 键盘浮层接管扩展方向键/Tab/Esc/Delete 直转 keysym，
  // 实测点画面后焦点会转移给 canvas（浏览器 mousedown 默认行为），浮层与 noVNC 原生
  // 键盘两路径混走行为不定——PC 键盘回归 noVNC 原生映射（点画布即聚焦，原生支持全键），
  // 本通道维持触控软键盘专用的 Enter 转发。
  kbi.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.keyCode === 13) {
      e.preventDefault();
      kbdSendSpecial(0xff0d, 'Enter'); // XK_Return
    }
  });

  // 2026-08-14 审查结论（用户实测确认）：iOS 键盘上方「粘贴」按钮不出现（QuickType 栏无此按钮），
  // 长按也无法触达 kbdInput（隐藏元素不可交互，长按画面会转发被控设备弹出被控端菜单）——
  // iOS 软键盘不挂 paste 监听；正向粘贴由 FAB 菜单「粘贴」按钮/降级浮层显式提供（pasteToFocusedDevice）。
}
initTouchKeyboard();

// ---------- PC 硬键盘删除键长按（2026-08-23，对齐触控端软键盘删除通道） ----------
// 触控端软键盘删除：iOS 长按删除产生重复 input 事件（inputType=deleteContentBackward）→
// 每次 kbdSendSpecial 完整 tap（down+up）→ 连发 Backspace。PC 实体键盘长按 = 浏览器 repeat
// keydown，此前走 noVNC 原生被转成「重复 down 无 up」→ 设备端行为不定（不连续删）。
// 此处 capture 阶段拦截 Backspace/Delete 走 kbdSendSpecial（软键盘同款通道），repeat 自动连发，
// 语义两端完全一致。释放延迟用 0ms（软键盘默认 60ms）——PC 浏览器 repeat 间隔约 30ms，
// 60ms 的 up 会与下次 repeat 的 down 重叠（连发乱序）；短延迟保证每次 tap 完整收尾。
// 放行场景：修饰组合（Ctrl+Backspace 删整词等，走 noVNC 原生需要 down 保持）、
// 焦点在输入框（正常编辑）。
document.addEventListener('keydown', (e) => {
  const k = e.key;
  if (k !== 'Backspace' && k !== 'Delete') return;
  if (e.ctrlKey || e.metaKey || e.altKey) return; // 组合键（删整词/删行）放行 noVNC 原生
  const t = e.target;
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return; // 输入框正常编辑
  const rfb = focus && focus.rfb;
  if (!rfb || !rfb._farmConnected) return; // 仅聚焦控制且已连接时接管
  e.preventDefault();
  e.stopPropagation(); // 阻止 noVNC Keyboard（canvas bubble 监听）收到，避免其重复 down 转发
  const isBack = k === 'Backspace';
  kbdSendSpecial(isBack ? 0xff08 : 0xffff, isBack ? 'Backspace' : 'Delete', 0); // 完整 tap，repeat 连发
}, true); // capture 阶段：先于 canvas 的 bubble 监听

/**
 * 渲染控制台操作菜单（07 §4.1）：按键区（KEY_DEFS 按键对象+按压识别）+ 动作区（本地按钮）
 * 按键区按钮挂 attachPress 按压识别（click/double/triple/long/down/up），动作区按钮单击直执行
 * @param {HTMLElement} container 容器（focusOpsCap / opsMenuCap）
 * @param {object} device 当前聚焦设备
 * @returns {void}
 */
function renderCapOps(container, device) {
  if (!container) return;
  // 清理上次挂载的按压识别（防挂起定时器在切换设备后误触发）
  if (Array.isArray(container.__pressCleanups)) {
    for (const detach of container.__pressCleanups) detach();
  }
  container.__pressCleanups = [];
  container.innerHTML = '';
  const frag = document.createDocumentFragment();
  // 悬浮菜单（opsMenuCap）：不显示分组标题，按钮保留图标+文字（窄菜单参考 5801 面板宽度）
  const isOpsMenu = container.id === 'opsMenuCap';
  // 按键区：分组标题 + 按键对象按钮（按压识别，07 §3.2；KEY_DEFS 自包含契约，直发 RFB）
  const keyTitle = document.createElement('div');
  keyTitle.className = 'cap-group-title';
  keyTitle.textContent = '按键';
  // 按键按钮构建（按压识别；键盘键 = 收起被控端软键盘 + 触控端调起控制端软键盘）
  const buildKeyBtn = (k) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'op key-op';
    b.title = k.title;
    b.innerHTML = '<span class="cap-icon">' + (k.svg || escapeHtml(k.icon || '?')) + '</span><span class="cap-name">' + escapeHtml(k.title) + '</span>';
    container.__pressCleanups.push(attachPress(b, k, { invoke: (capId) => {
      // 键盘键 = 单向固定（2026-08-16 回退）：发 XF86Keyboard 收起被控端软键盘；
      // 触控端再 focusKbdInput 调起控制端软键盘（电脑端有实体键盘，不调软键盘）。
      if (k.key === 'keyboard') {
        kbdSendSpecial(0x1008ff2e, null); // XF86Keyboard → 设备端 toggleOnScreenKeyboard 收起被控端键盘
        if (isTouchable()) focusKbdInput();
        return;
      }
      const rfb = focus && focus.rfb;
      if (rfb && rfb._farmConnected) rfbPressKey(rfb, k, capId);
      // 控制台直连模式：按键仅在有活跃 RFB 连接时可用，无连接不发送
    } }));
    return b;
  };
  // FAB 悬浮菜单专属顺序（2026-08-17 用户拍板）：Home → 复制 → 粘贴 → 键盘 → 截屏 →
  // 其余按键（音量/亮度/搜索）→ 全屏 → 电源（长按保留）→ 断开。
  // 全屏/断开原为 index.html 静态按钮，改动态渲染以便电源插入其间（静态写死会丢电源按压识别）。
  if (isOpsMenu) {
    const byKey = new Map(KEY_DEFS.map((k) => [k.key, k]));
    const order = ['home', 'volup', 'mute', 'voldn', 'briup', 'bridn', 'spotlight'];
    frag.appendChild(buildKeyBtn(byKey.get('home')));
    frag.appendChild(buildClipboardBtn('copy'));
    frag.appendChild(buildClipboardBtn('paste'));
    frag.appendChild(buildKeyBtn(byKey.get('keyboard')));
    frag.appendChild(buildKeyBtn(byKey.get('snapshot')));
    order.slice(1).forEach((key) => { const k = byKey.get(key); if (k) frag.appendChild(buildKeyBtn(k)); });
    frag.appendChild(buildActionBtn('full', '全屏', '全屏切换',
      '<path d="M4 9V4h5"/><path d="M20 9V4h-5"/><path d="M4 15v5h5"/><path d="M20 15v5h-5"/>'));
    frag.appendChild(buildKeyBtn(byKey.get('power')));
    frag.appendChild(buildActionBtn('disc', '断开', '断开（退出控制并返回设备墙）',
      '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/><path d="M9.5 14.5l5-5"/>', 'danger'));
    container.appendChild(frag);
    return;
  }
  // 桌面操作列（focusOpsCap）：KEY_DEFS 顺序 + 复制（电脑端已有 Ctrl+V，不挂粘贴）
  const keyBtns = [];
  for (const k of KEY_DEFS) keyBtns.push(buildKeyBtn(k));
  if (keyBtns.length > 0) {
    frag.appendChild(keyTitle);
    keyBtns.forEach((b) => frag.appendChild(b));
  }
  frag.appendChild(buildClipboardBtn('copy'));
  container.appendChild(frag);
}

/**
 * 剪贴板按钮构建（复制=拉取设备剪贴板 / 粘贴=注入设备；显式双向搬运 2026-08-17）
 * @param {'copy'|'paste'} kind 按钮类型
 * @returns {HTMLButtonElement} 按钮元素（已绑定 click）
 */
function buildClipboardBtn(kind) {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'op';
  if (kind === 'copy') {
    b.title = '复制：拉取被控设备剪贴板到控制端';
    b.innerHTML = '<span class="cap-icon">' +
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' +
      '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>' +
      '</svg></span><span class="cap-name">复制</span>';
    b.addEventListener('click', copyFromFocusedDevice);
  } else {
    b.title = '粘贴：读取控制端剪贴板并粘贴到被控设备聚焦输入框';
    b.innerHTML = '<span class="cap-icon">' +
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' +
      '<path d="M15 2H9a1 1 0 0 0-1 1v2a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V3a1 1 0 0 0-1-1Z"/>' +
      '<path d="M8 4H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2h-2"/>' +
      '<rect x="9" y="11" width="6" height="4" rx="1"/>' +
      '</svg></span><span class="cap-name">粘贴</span>';
    b.addEventListener('click', pasteToFocusedDevice);
  }
  return b;
}

/**
 * 菜单动作按钮构建（全屏/断开；data-op 交由 doOp 统一处理，与原静态按钮行为一致）
 * @param {string} op 动作标识（full/disc）
 * @param {string} name 按钮名称
 * @param {string} title 悬浮提示
 * @param {string} svgPaths 内联 SVG path 内容
 * @param {string} [cls] 附加类名（danger）
 * @returns {HTMLButtonElement} 按钮元素
 */
function buildActionBtn(op, name, title, svgPaths, cls) {
  const b = document.createElement('button');
  b.type = 'button';
  b.dataset.op = op;
  if (cls) b.className = cls;
  b.title = title;
  b.innerHTML = '<span class="cap-icon">' +
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' + svgPaths + '</svg>' +
    '</span><span class="cap-name">' + name + '</span>';
  b.addEventListener('click', () => doOp(op));
  return b;
}

/**
 * 显示顶部居中 toast（动作级日志，与控制台/5801 同构）：fixed 顶部水平居中 + 安全区，三态上色，
 * 500ms 同文案去重。2026-08-19 由右上角改顶部居中——右上角会挡住顶栏按钮（直控/批量/布局）；
 * 顶部居中区域在 PC/移动端均为空白区，天然避开顶栏按钮与批量胶囊行。
 * @param {string} msg  文案（两段式「动作 + 结果/原因」，前缀 ✓/✗ 由调用方带上）
 * @param {string} type success|error|info（默认 info）
 * @returns {void}
 */
const TOAST_CFG = {
  success: { color: '#34c759', ms: 2000 },  // ✓ 成功 绿
  error:   { color: '#ff453a', ms: 3500 },  // ✗ 失败 红
  info:    { color: '#d0d0d0', ms: 2000 },  // 中性 灰
};
let farmToastTimer = null;
let farmToastLast = { msg: '', at: 0 };
function toast(msg, type = 'info') {
  const cfg = TOAST_CFG[type] || TOAST_CFG.info;
  const now = Date.now();
  if (farmToastLast.msg === msg && now - farmToastLast.at < 500) return; // 同文案 500ms 去重防刷屏
  farmToastLast = { msg, at: now };
  let el = document.getElementById('farmToast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'farmToast';
    document.body.appendChild(el);
  }
  el.textContent = msg;
  el.style.cssText =
    'position:fixed;' +
    'top:calc(env(safe-area-inset-top, 0px) + 12px);' +
    'left:50%;transform:translateX(-50%);' +   // 顶部水平居中（避开顶栏左右按钮/批量胶囊行）
    'z-index:999;max-width:min(80vw, 420px);' +
    'background:rgba(20,26,40,.92);color:' + cfg.color + ';' +
    'padding:10px 14px;border-radius:10px;border-left:3px solid ' + cfg.color + ';' +
    'font:13px/1.4 system-ui,sans-serif;box-shadow:0 6px 20px rgba(0,0,0,.4);' +
    'pointer-events:none;transition:opacity .25s;text-align:center;';
  el.style.opacity = '1';
  if (farmToastTimer) clearTimeout(farmToastTimer);
  farmToastTimer = setTimeout(() => { el.style.opacity = '0'; }, cfg.ms);
}

/**
 * 弹出参数输入表单（简化版，支持 number/string）
 * string 输入框自动聚焦 + 监听 paste 事件捕获控制端剪贴板（桌面 Ctrl+V / 移动端长按粘贴），
 * 便于"粘贴输入"类能力跨设备传文本（控制端手机/电脑剪贴板 → 被控设备）。
 * @param paramDefs 参数定义数组
 * @param {string} [title] 能力标题（显示在表单顶部）
 * @returns 参数对象，取消返回 null
 */
function promptParams(paramDefs, title) {
  return new Promise((resolve) => {
    const modal = document.createElement('div');
    modal.className = 'modal';
    const card = document.createElement('div');
    card.className = 'modal-card';
    if (title) {
      const h = document.createElement('h3');
      h.textContent = title;
      card.appendChild(h);
    }
    const inputs = {};
    let focused = false;
    for (const p of paramDefs) {
      const lbl = document.createElement('label');
      lbl.textContent = `${p.name}${p.required ? ' *' : ''} (${p.type})`;
      const inp = document.createElement('input');
      if (p.default !== undefined) inp.value = p.default;
      // string 输入框：捕获控制端剪贴板 paste 事件（用户 Ctrl+V / 移动端长按粘贴时自动填入）
      if (p.type === 'string') {
        inp.addEventListener('paste', (e) => {
          const txt = (e.clipboardData && e.clipboardData.getData('text')) || '';
          if (txt) { inp.value = txt; e.preventDefault(); }
        });
      }
      inputs[p.name] = inp;
      lbl.appendChild(inp);
      card.appendChild(lbl);
      if (!focused) { inp.focus(); focused = true; } // 自动聚焦首个输入框
    }
    const btns = document.createElement('div');
    btns.className = 'modal-btns';
    const ok = document.createElement('button');
    ok.className = 'primary'; ok.textContent = '执行';
    const cancel = document.createElement('button');
    cancel.textContent = '取消';
    btns.appendChild(cancel); btns.appendChild(ok);
    card.appendChild(btns);
    modal.appendChild(card);
    document.body.appendChild(modal);
    cancel.onclick = () => { modal.remove(); resolve(null); };
    ok.onclick = () => {
      const params = {};
      for (const p of paramDefs) {
        const v = inputs[p.name].value.trim();
        if (p.required && !v) { alert(`${p.name} 为必填`); return; }
        if (p.type === 'number') params[p.name] = Number(v) || 0;
        else params[p.name] = v;
      }
      modal.remove();
      resolve(params);
    };
  });
}

/**
 * 读取控制端剪贴板文本（2026-08-14 移除静默降级：剪贴板 API 不可用/读取失败直接抛错，调用方显式处理）。
 * 需 https 安全上下文 + 用户手势激活内调用（iOS WebKit 限制，visibilitychange/pageshow 非手势会被拒）。
 * @returns {Promise<string>} 剪贴板文本（可为空字符串）
 * @throws {Error} 剪贴板 API 不可用（非 https）或系统拒绝读取
 */
async function readClipboardText() {
  if (!window.isSecureContext || !navigator.clipboard || !navigator.clipboard.readText) {
    throw new Error('剪贴板 API 不可用（需 https 安全上下文）');
  }
  return await navigator.clipboard.readText();
}

// 2026-08-17 显式双向搬运：剪贴板无自动同步（设备端不推送、控制端复制不自动写设备），
// 复制/粘贴均为显式按钮或 Ctrl+V 操作（见 copyFromFocusedDevice / pasteToFocusedDevice）。

/**
 * 提交粘贴文本：调用 type.paste 能力注入被控设备（携带控制端文本 → 写设备剪贴板 + 模拟 Cmd+V，原子）。
 * @param {string|null} devId 目标设备 ID（可能为空：keydown 直达路径用 focus.device.id）
 * @param {string} text 要注入的文本
 * @returns {Promise<void>}
 */
async function submitPasteText(devId, text) {
  if (!devId || !text) return;
  try {
    const r = await invokeCap('', devId, 'type.paste', { text });
    if (r && r.ok) {
      toast(`✓ 已粘贴 ${text.length} 字符到设备`, 'success');
    }
    else toast(`✗ 粘贴失败：${(r && r.ack && r.ack.error) || '未知错误'}`, 'error');
  } catch (e) {
    toast(`✗ 粘贴调用失败：${e.message}`, 'error');
  }
}

// 移动端 FAB 菜单「粘贴」：读取控制端剪贴板 → type.paste 原子注入被控设备聚焦输入框。
// 与电脑端 Ctrl+V 完全同链路（readClipboardText → submitPasteText）：
//   - readClipboardText 必须在用户手势内同步调用（本函数由按钮 click 触发，激活窗口有效）；
//   - iOS 控制端 readText 会弹一次系统「允许粘贴」横幅（iOS 隐私，无法绕过）；
//   - 设备端 type.paste 写剪贴板 + releaseEveryKeys + 异步模拟 Cmd+V，被控端再弹一次
//     「想从 superphone 粘贴」隐私确认（iOS 14+ UIPasteboard 读取确认）→ 用户确认后落入聚焦输入框。
// 2026-08-14 用户拍板恢复此显式按钮（此前弹窗/隐式同步因"多步/易塞旧文本"被删，
// 一键直读直贴为显式用户手势，一次点击即可走完整时序）。
async function pasteToFocusedDevice() {
  if (!focus || !focus.device) {
    toast('✗ 粘贴失败：请先进入设备控制', 'error');
    return;
  }
  // 2026-08-17 语义修正（与 5801 对齐）：粘贴 = 控制端剪贴板 → 设备。
  // https 安全上下文 → 读控制端剪贴板直贴（无窗口，一次完成）；
  // http（控制端剪贴板不可读）→ 不读设备剪贴板充数，直接弹输入浮层（粘贴/回车自动注入）。
  if (window.isSecureContext && navigator.clipboard && navigator.clipboard.readText) {
    try {
      const txt = await navigator.clipboard.readText();
      if (txt) { await submitPasteText(focus.device.id, txt); return; }
    } catch (e) { /* 读失败落下一层 */ }
  }
  showPasteFallbackModal();
}

// 电脑端 Ctrl+V 拦截：focus 画布聚焦时按 Ctrl+V，禁止 noVNC 把 Ctrl+V 发到被控设备。
// 2026-08-14 决策：type.paste 带 text（原子"写剪贴板+模拟 Cmd+V"）——协议通道（clipboardPasteFrom）
// 是异步无确认的，先同步再粘贴会有"粘旧内容"竞态，故粘贴输入走能力通道原子完成；
// 剪贴板纯同步（copy 事件）才走协议通道。设备端已加 releaseEveryKeys 清残留修饰键。
document.addEventListener('keydown', async (e) => {
  if (!(e.ctrlKey || e.metaKey) || e.key.toLowerCase() !== 'v') return;
  if (e.target.closest && e.target.closest('input, textarea')) return; // 已在输入框：原生粘贴
  if (!focus || !focus.device) return;
  e.preventDefault();
  e.stopPropagation();
  let txt = null;
  try {
    txt = await readClipboardText();
  } catch (err) {
    // 2026-08-18 与 5801 对齐：http 下读不到控制端剪贴板 → 统一弹输入浮层
    //（PC/触屏一致），不再用隐藏 textarea「第二次 Ctrl+V」方案
    showPasteFallbackModal();
    return;
  }
  if (!txt) { toast('✗ 粘贴失败：控制端剪贴板为空', 'error'); return; }
  await submitPasteText(focus.device.id, txt);
}, true);

// 触控长按 = 传达被控设备长按（2026-08-14）：长按被控画面不再作为粘贴手势，改为左键按下保持
// 传达设备长按（rfb.js patch 0x1/0x0），与电脑端鼠标按住一致。原 __farmPasteLongPress 已删除。

// ---------- 聚焦视图 ----------
/**
 * 被控制中卡片浮层：显示「断开 / 接管」两个按钮（2026-08-22，替代浏览器 confirm）
 * 断开 = 只断开被控状态留在卡片墙；接管 = 先断开再进入控制
 * @param {object} dev 设备对象
 * @param {HTMLElement} tile 卡片元素
 * @returns {void}
 */
function showCtrlActions(dev, tile) {
  hideCtrlActions();
  const ov = document.createElement('div');
  ov.className = 'ctrl-actions';
  ov.innerHTML = `
    <div class="ctrl-actions-title">设备「${dev.name}」正在被控制</div>
    <div class="ctrl-actions-btns">
      <button class="ctrl-actions-btn disc">断开</button>
      <button class="ctrl-actions-btn take">接管</button>
    </div>`;
  tile.appendChild(ov);
  ov.querySelector('.disc').addEventListener('click', (e) => {
    e.stopPropagation();
    disconnectControlled(dev).then((ok) => {
      if (ok) {
        hideCtrlActions();
        const inst = wallInstances.get(dev.id);
        if (inst) updateWallTile(inst, dev); // 立即移除遮罩 + 恢复缩略图
      }
    });
  });
  ov.querySelector('.take').addEventListener('click', (e) => {
    e.stopPropagation();
    disconnectControlled(dev).then((ok) => {
      if (ok) { hideCtrlActions(); enterFocus(dev); }
    });
  });
  // 点击浮层外关闭（延迟注册，避免本次卡片点击冒泡误关）
  setTimeout(() => {
    document.addEventListener('click', function onDoc(e) {
      document.removeEventListener('click', onDoc);
      if (!ov.contains(e.target)) hideCtrlActions();
    });
  }, 0);
}

/** 关闭被控制中卡片浮层 */
function hideCtrlActions() {
  const ov = document.querySelector('.ctrl-actions');
  if (ov) ov.remove();
}

/**
 * 断开设备被控状态（5801 直连等外部控制端）
 * 网关 POST /api/devices/:id/disconnect → 设备端 clients.disconnect id=REMOTE（断开所有非 loopback 客户端）
 * @param {object} dev 设备对象
 * @returns {Promise<boolean>} 是否成功
 */
async function disconnectControlled(dev) {
  try {
    const headers = TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {};
    const res = await fetch(`/api/devices/${encodeURIComponent(dev.id)}/disconnect`, { method: 'POST', headers });
    const data = await res.json().catch(() => ({}));
    if (res.ok && data.ok) {
      dev.controlled = false;
      dev.controlledSource = null;
      toast(`已断开「${dev.name}」的被控状态`, 'info');
      return true;
    }
    toast('断开被控失败' + (data.error ? `：${data.error}` : ''), 'error');
    return false;
  } catch (e) {
    toast('断开被控失败', 'error');
    return false;
  }
}

// 2026-08-23 规避：上次退出的控制 RFB 引用——进入前等待其完全关闭（disconnected），
// 防止 Chrome 每域名 6 连接限制下旧 WS 未关导致新 WS 排队（连接超时根因）。
let lastClosedRfb = null;
function waitPrevRfbClosed() {
  const prev = lastClosedRfb;
  if (!prev) return Promise.resolve();
  const st = prev._rfbConnectionState;
  if (st === 'disconnected' || st === 'disconnecting') return Promise.resolve();
  return new Promise((resolve) => {
    const t = setTimeout(resolve, 500);
    prev.addEventListener('disconnect', () => { clearTimeout(t); resolve(); });
  });
}

async function enterFocus(d) {
  if (focus && focus.device.id === d.id) return;
  if (focus) exitFocus();
  // 只走隧道：未注册设备不可控制（离线已注册设备收编进连接态浮层，见建立连接前判断）
  if (d.source !== 'register') { alert('设备未注册（无隧道），请先在手机 App 配置网关完成注册'); return; }
  // 2026-08-14 审查删除：点卡片不再作为控制端→设备写剪贴板事件（隐式同步易造成控制端旧文本
  // 被塞入设备，用户拍板去除；控制端→设备方向仅保留 copy 事件用户主动复制同步）
  // 聚焦状态写入 URL（2026-08-14）：刷新页面后仍停留当前设备画面，不再回退主页（见 restoreFocusFromUrl）
  try {
    const u = new URL(location.href);
    u.searchParams.set('focus', d.id);
    history.replaceState(null, '', u.toString());
  } catch (e) { /* 忽略：URL 更新失败不影响控制 */ }

  // 预置面板宽度（用墙卡片已知的设备比例），避免“先宽后窄”闪烁
  const wallInst = wallInstances.get(d.id);
  let knownRatio = null;
  if (wallInst && wallInst.tile.dataset.wh) {
    const parts = wallInst.tile.dataset.wh.split('x').map(Number);
    if (parts[0] && parts[1]) knownRatio = parts[0] / parts[1];
  }
  prefitFocusPanel(knownRatio || (9 / 16));

  // 隐藏该设备的墙卡片（它已放大到左侧）：断开卡片墙 RFB，focus 视图重建可操控 RFB
  if (wallInst) {
    stopWallRfb(wallInst);
    wallInst.paused = true;
    wallInst.tile.classList.add('focused-tile');
  }
  $('focusTitle').textContent = `${d.name} (${d.host}:${d.port})`;
  const stage = document.createElement('div');
  stage.id = 'focusStage';
  stage.className = 'focus-stage';
  $('focusScreen').innerHTML = '';
  $('focusScreen').appendChild(stage);
  // 2026-08-15 移动端：创建 stage 即用 JS 像素值撑满视口（不等 connect 后的 fitFocusPanel）。
  // WKWebView 首帧布局未稳定时 CSS height:100% 高度链测量错误 → noVNC autoscale 用错
  // 容器尺寸 → canvas 尺寸/锚点错 → 画布贴顶；重排后跳底。像素值不依赖高度链，恒正确。
  if (window.matchMedia('(max-width: 900px)').matches) {
    stage.style.width = window.innerWidth + 'px';
    stage.style.height = window.innerHeight + 'px';
  }
  // 中央连接浮层：与 5801 直连页一致的连接中加载动画（必须在此处重建——
  // 上方 innerHTML='' 已清空 focusScreen，浮层由 setFocusOverlay 内部 ensure 重新挂载）
  setFocusOverlay(true, '连接中…');
  $('focusPanel').classList.remove('hidden');
  $('focusOps').classList.remove('hidden');
  $('workspace').classList.add('focus-open');
  // 2026-08-15：IPA 容器隐藏底部 TabBar——点开卡片后画面占满整个屏幕（"整个画面即显示容器"）。
  // 仅 WKWebView 容器存在 farmBridge 时发送（Safari/PC 无桥自动跳过）；退出控制时恢复（见 exitFocus）。
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.farmBridge) {
    window.webkit.messageHandlers.farmBridge.postMessage({ type: 'setTabBarHidden', hidden: true });
  }
  renderCapOps($('focusOpsCap'), d);
  renderCapOps($('opsMenuCap'), d);
  if (window.matchMedia('(max-width: 900px)').matches) $('fab').classList.remove('hidden');
  // 主控连接始终携带 grp+broadcast（广播到同 session 的同步/群控订阅设备）。
  // 保证勾选同步设备时无需重建主控连接 → 主控画面不跳动、不改变。
  const grp = wallSession;
  const broadcast = '1';
  // 先初始化 focus 再建立连接，避免在 null 上赋值抛错（修复点击卡片黑屏）
  focus = { device: d, rfb: null };
  // 离线设备收编进连接态浮层（2026-08-16）：进入聚焦画面显示离线态，不建立 RFB（点离线卡片不再弹 alert）
  if (d.online === false) {
    setFocusOverlay(false, '设备离线，请唤醒手机后重试');
    return;
  }
  // 2026-08-23 重构（根因修复）：focus 已在上面**同步**锁定——快速重复进入会被
  // enterFocus 顶部的 if(focus) 拦截，无并发窗口。等上次 WS 完全关闭（disconnected，
  // 释放 Chrome 每域名 6 连接配额，防新 WS 排队）后**异步**建新连接；等待期间若退出/
  // 替换，then 内的 focus 校验会放弃建连，WS 绝不泄漏。
  waitPrevRfbClosed().then(() => {
    // 三重校验：已被退出/替换、或 stage 已被后续 enterFocus 的 innerHTML='' 清空/替换
    // （isConnected=false）→ 放弃建连，WS 绝不泄漏（2026-08-23 真实浏览器复现根因）
    if (!focus || focus.device.id !== d.id || focus.rfb !== null) return;
    if (!stage.isConnected) return;
    const fRfb = createRfb(stage, d, { grp, broadcast, ctrl: true }, $('focusStatusDot'));
    focus.rfb = fRfb;
    // 2026-08-23 确定性优先：连接任何情况失败立即明确报错，不做静默自动重连（黑盒）。
    // 连接超时兜底：10s 未 connect → 断开 + 报错（正常 connect 时清除；exitFocus 清理 focus.connTimer）。
    const connTimer = setTimeout(() => {
      if (focus && focus.rfb === fRfb && fRfb._rfbConnectionState !== 'connected') {
        // 2026-08-23 诊断：超时时刻 noVNC/WS 状态（定位「连接中卡死」根因——WS 排队 or 握手停滞）
        try {
          const sock = fRfb._sock;
          const unread = sock ? (sock._rQlen - sock._rQi) : -1;
          console.error('[focus] CONN TIMEOUT st=', fRfb._rfbConnectionState,
            'init=', fRfb._rfbInitState,
            'wsReady=', sock && sock.readyState, // 0=CONNECTING(排队) 1=OPEN 2=CLOSING 3=CLOSED
            'rQunread=', unread,
            'rQhex=', (unread > 0 && sock) ? Array.from(sock._rQ.subarray(sock._rQi, Math.min(sock._rQlen, sock._rQi + 32))).map((b) => b.toString(16).padStart(2, '0')).join('') : '',
            'wsUrl=', fRfb._url);
        } catch (e) { /* ignore */ }
        fRfb._farmConnTimeout = true; // 标记：超时已报错，disconnect 不覆盖文案
        closeRfb(fRfb);
        setFocusOverlay(false, '连接超时，请退出后重试');
      }
    }, 10000);
    focus.connTimer = connTimer;
    fRfb.addEventListener('connect', () => {
      clearTimeout(connTimer);
      if (focus) focus.connTimer = null;
      // 2026-08-22：连接极快时动画一闪而过——最小显示 300ms 再隐藏，保证「连接中…」可见
      setTimeout(() => setFocusOverlay(false, null), 300);
      setTimeout(fitFocusPanel, 300);
    });
    // 聚焦画面断开：立即明确报错（映射具体原因），不自动重连——由用户手动退出/重进。
    fRfb.addEventListener('disconnect', (e) => {
      clearTimeout(connTimer);
      if (!focus || focus.rfb !== fRfb) return;
      const code = e && e.detail ? e.detail.code : null;
      if (code === 1000 || code === 1001) return; // 主动断开（exitFocus closeRfb）：正常退出不报错
      if (fRfb._farmConnTimeout) return; // 已报「连接超时」，closeRfb 触发的断开不覆盖文案
      if (code === 4001) {
        // 2026-08-23：被其它控制端（5801 直连接管 / 同设备新控制）接管 → 画面已断，
        // 自动执行断开并返回卡片墙（不再停留聚焦画面）；卡片墙随后经被控状态上报
        // （state 事件 → refreshDevices）显示「被 5801 控制中」遮罩。
        toast('设备已被其它端接管，已中断控制', 'error');
        exitFocus();
        return;
      }
      const msg = code === 4003 ? '设备隧道未建立（设备可能离线），请退出后重试'
        : code === 4005 ? '设备画面服务不可用（设备端 VNC 未运行）'
        : code === 4006 ? '设备端连接已断开，请退出后重试'
        : `连接已断开${code ? ' (' + code + ')' : ''}`;
      setFocusOverlay(false, msg);
    });
    setTimeout(fitFocusPanel, 400);
    startFabSignalPoll(); // 移动端悬浮按钮延迟信号轮询（仅在 focus 建立后）
    // 2026-08-15 用户拍板：进入控制不再强制系统全屏（自动 requestFullscreen 在 iOS 上会与
    // 画面/菜单交互冲突，且非用户直接意图）。移动端聚焦画面由 CSS 撑满视口（区域全屏），
    // 需要隐藏浏览器 UI 时用户通过悬浮菜单「全屏」按钮手动切换（doOp 'full'）。
  });
}

// ---------- 聚焦画面中央状态浮层（与 5801 直连页一致） ----------
/**
 * 显示/隐藏聚焦画面中央状态浮层：loading=true 显示旋转加载动画（连接中）；
 * text 非空显示状态文字（断开/重连提示）。
 * 浮层挂在 #focusScreen 内（enterFocus 的 innerHTML='' 会清空它，此处 ensure 自动重建/重新挂载）。
 * @param {boolean} loading 是否显示加载动画
 * @param {string|null} text 状态文字（null=保持当前文字）
 * @returns {void}
 */
function setFocusOverlay(loading, text) {
  const fs = $('focusScreen');
  if (!fs) return;
  let ov = $('focusStatusOv');
  if (!ov) {
    ov = document.createElement('div');
    ov.id = 'focusStatusOv';
    ov.className = 'focus-status-ov hidden';
    ov.innerHTML = '<div class="spin"></div><div id="focusStatusText">连接中…</div>';
  }
  if (ov.parentElement !== fs) fs.appendChild(ov); // innerHTML='' 清空后重新挂载
  // 2026-08-22 修复：创建时带 hidden 类（display:none !important），toggle show 时必须移除，
  // 否则 hidden 的 !important 覆盖 .show 的 display:flex → 浮层永远不可见
  ov.classList.toggle('hidden', !(loading || text != null));
  ov.classList.toggle('loading', !!loading);
  ov.classList.toggle('show', !!loading || text != null);
  if (text != null) {
    const t = $('focusStatusText');
    if (t) t.textContent = text;
  }
}

// ---------- 聚焦画面自动重连（2026-08-14） ----------
// 2026-08-23：移除自动重连（黑盒回退）——连接/断开失败一律立即明确报错，由用户手动重进。
// 确定性优先：不静默重试、不无限「连接中」。

function exitFocus() {
  if (!focus) return;
  const devId = focus.device.id;
  setFocusOverlay(false, null); // 退出隐藏连接浮层
  // 2026-08-22 时序原则：断开时「先清理被控中状态，再断开」——本地置 controlled=false +
  // 移除遮罩，然后才 closeRfb。断开后本地 controlled=false 保持（不 refreshDevices 覆盖），
  // 网关 rfb.stop 上报 controlled=false 后经 state 事件/后续刷新保持，无需延迟 hack。
  const dev = devices.find((d) => d.id === devId);
  if (dev) dev.controlled = false;
  const inst = wallInstances.get(devId);
  if (inst && inst.tile) {
    // 2026-08-22：退出大屏控制前截图最后画面（与退出直控 exitDirectMode 一致）——
    // noVNC disconnect 会移除 canvas，截图保留最后画面，restoreWallTile → startWallRfb
    // 先显示它，缩略图就绪后替换，避免退出时卡片闪「加载中…」
    const c = $('focusStage') && $('focusStage').querySelector('canvas');
    console.log('[exitFocus] stage=', !!$('focusStage'), 'canvas=', !!c);
    if (c) {
      try {
        inst._lastFrame = c.toDataURL('image/jpeg', 0.7);
        console.log('[exitFocus] lastFrame len=', inst._lastFrame ? inst._lastFrame.length : 0);
      } catch (e) { inst._lastFrame = null; console.log('[exitFocus] toDataURL err=', e); }
    }
    const mask = inst.tile.querySelector('.ctrl-mask');
    if (mask) mask.remove();
  }
  // 清除 URL 聚焦参数（2026-08-14）：退出控制后刷新不再自动进入该设备
  try {
    const u = new URL(location.href);
    if (u.searchParams.has('focus')) {
      u.searchParams.delete('focus');
      history.replaceState(null, '', u.toString());
    }
  } catch (e) { /* 忽略 */ }
  const rfbToClose = focus.rfb;
  if (focus.connTimer) { clearTimeout(focus.connTimer); focus.connTimer = null; }
  closeRfb(rfbToClose);
  lastClosedRfb = rfbToClose; // 记录供下次进入等待其完全关闭（规避 Chrome 连接配额排队）
  // 2026-08-23 确定性优先：断开未完成立即报错——closeRfb 后 2s 内未进入
  // disconnecting/disconnected（WS 关闭卡住）即视为异常，明确提示而非静默。
  setTimeout(() => {
    const st = rfbToClose && rfbToClose._rfbConnectionState;
    if (st && st !== 'disconnected' && st !== 'disconnecting') {
      toast('✗ 断开未完成（连接未关闭），请重试', 'error');
    }
  }, 2000);
  stopFabSignalPoll();
  focus = null;
  // 2026-08-15：退出控制恢复 IPA 底部 TabBar（与 enterFocus 隐藏配对；无桥环境自动跳过）
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.farmBridge) {
    window.webkit.messageHandlers.farmBridge.postMessage({ type: 'setTabBarHidden', hidden: false });
  }
  // 退出：收起控制端软键盘
  blurKbdInput();
  exitSyncMode(); // 关闭同步订阅与选择模式
  $('focusPanel').classList.add('hidden');
  $('focusOps').classList.add('hidden');
  $('workspace').classList.remove('focus-open');
  $('opsMenu').classList.add('hidden');
  cancelFabAutoCollapse();
  $('fab').classList.add('hidden');
  restoreWallTile(devId);
  // 退出大屏同步退出系统全屏（若处于全屏态）
  if (document.fullscreenElement) {
    try { document.exitFullscreen().catch(() => {}); } catch (e) { /* 忽略 */ }
  }
}

/**
 * 刷新后恢复聚焦设备（2026-08-14）：URL ?focus=<id> 记录的设备画面，
 * 页面加载且设备列表就绪后自动重新进入控制——刷新落地页 = 当前操作的设备屏幕，不回退主页。
 * 设备离线/不存在/虚拟预览设备（mock）则清除参数回主页。
 * @returns {void}
 */
function restoreFocusFromUrl() {
  try {
    const u = new URL(location.href);
    const fid = u.searchParams.get('focus');
    if (!fid) return;
    if (focus) return; // 已有聚焦
    const dev = devices.find((d) => d.id === fid);
    if (!dev || dev.mock || dev.online !== true || dev.source !== 'register') {
      u.searchParams.delete('focus');
      history.replaceState(null, '', u.toString());
      return;
    }
    enterFocus(dev);
  } catch (e) { /* 忽略：URL 解析失败不影响页面 */ }
}

function restoreWallTile(id) {
  const inst = wallInstances.get(id);
  if (!inst || !inst.paused) return;
  inst.paused = false;
  inst.tile.classList.remove('focused-tile');
  // 退出 focus：恢复卡片墙缩略图获取
  startWallRfb(inst);
}

// ---------- 同步控制（勾选设备与主控同步操作） ----------
let syncMode = false;            // 同步选择模式：点击"同步"进入，墙卡片出现复选框
const syncRfbs = new Map();      // deviceId -> RFB（grp viewOnly 订阅：接收主控广播输入 + 卡片推流显示执行情况）

/**
 * 切换同步选择模式：进入后点卡片即切换同步（无复选框），再次点击按钮退出。
 * 仅聚焦状态下可用。
 * @returns {void}
 */
function toggleSyncMode() {
  if (!focus) return;
  if (syncMode) { exitSyncMode(); return; }
  syncMode = true;
  updateSyncBtn();
}

/**
 * 退出同步选择模式：关闭全部同步 RFB（恢复卡片墙缩略图获取）、清空选中态与"同步中"徽标。
 * @returns {void}
 */
function exitSyncMode() {
  if (!syncMode && syncRfbs.size === 0) return;
  syncMode = false;
  for (const inst of wallInstances.values()) {
    const badge = inst.tile && inst.tile.querySelector('.sync-badge');
    if (badge) badge.remove();
    if (inst.checkbox) inst.checkbox.checked = false;
    if (inst.tile) inst.tile.classList.remove('tile-selected');
  }
  // 关闭全部同步 RFB 订阅并置空，随后恢复卡片墙缩略图获取
  // 必须显式 closeRfb：syncRfb 的 RFB 实例存在 syncRfbs Map 中（未赋给 inst.rfb），
  // stopWallRfb 只清 inst.rfb 不会关闭它 → noVNC 不监听 container DOM 变更 → WS 残留为孤儿会话
  for (const id of syncRfbs.keys()) {
    const rfb = syncRfbs.get(id);
    if (rfb) closeRfb(rfb);
    const inst = wallInstances.get(id);
    if (inst) stopWallRfb(inst);
  }
  syncRfbs.clear();
  updateSyncBtn();
  // 恢复缩略图获取：仅在线且未暂停（主控自身）的卡片
  for (const inst of wallInstances.values()) {
    if (inst.device.online === true && !inst.paused) startWallRfb(inst);
  }
  // 主控连接始终携带广播标记，退出同步无需重建 → 主控画面不跳动
}

/**
 * 设置卡片"同步中"徽标（卡片中央覆盖层，不遮挡推流画面）
 * @param {object} inst 墙卡片实例
 * @param {boolean} on 是否显示
 * @returns {void}
 */
function setSyncBadge(inst, on) {
  if (!inst || !inst.tile) return;
  let badge = inst.tile.querySelector('.sync-badge');
  if (on && !badge) {
    badge = document.createElement('div');
    badge.className = 'sync-badge';
    badge.textContent = '同步中';
    inst.tile.appendChild(badge);
  } else if (!on && badge) {
    badge.remove();
  }
}

/**
 * 勾选/取消同步某设备：建立或关闭该设备的 grp viewOnly RFB 订阅。
 * RFB 渲染到墙卡片（实时推流显示同步执行情况），同时作为广播接收成员——
 * 主控输入经网关 broadcastInput 转发到该设备隧道执行。
 * 选中态 = 卡片边框高亮（tile-selected）+ 中央"同步中"徽标。
 * @param {string} deviceId 设备 ID
 * @returns {void}
 */
function toggleSync(deviceId) {
  const dev = devices.find((d) => d.id === deviceId);
  if (!dev || dev.mock) { alert('虚拟设备仅用于布局预览，不支持同步'); return; }
  if (dev.online === false) { alert(`设备「${dev.name}」离线，无法同步`); return; }
  if (focus && deviceId === focus.device.id) { alert('主控设备本身无需同步'); return; }
  const inst = wallInstances.get(deviceId);
  if (!inst) { alert('设备卡片未就绪，请稍后重试'); return; }
  if (syncRfbs.has(deviceId)) {
    // 取消同步：显式 closeRfb 关闭 WS 订阅，移除选中态，恢复卡片墙缩略图获取
    const rfb = syncRfbs.get(deviceId);
    if (rfb) closeRfb(rfb);
    stopWallRfb(inst);
    syncRfbs.delete(deviceId);
    setSyncBadge(inst, false);
    if (inst.checkbox) inst.checkbox.checked = false;
    inst.tile.classList.remove('tile-selected');
    startWallRfb(inst);
  } else {
    // 勾选同步：停缩略图获取，建立 grp viewOnly RFB 渲染卡片（实时画面 + 接收广播输入）
    stopWallRfb(inst);
    const tv = inst.tile.querySelector('.tv');
    const rfb = createRfb(tv, dev, { grp: wallSession, viewOnly: true });
    rfb.addEventListener('disconnect', () => {
      // 连接异常断开（设备离线等）：清理同步标记，移除选中态，恢复缩略图获取
      if (syncRfbs.get(deviceId) === rfb) {
        syncRfbs.delete(deviceId);
        setSyncBadge(inst, false);
        if (inst.checkbox) inst.checkbox.checked = false;
        inst.tile.classList.remove('tile-selected');
        updateSyncBtn();
        startWallRfb(inst);
      }
    });
    syncRfbs.set(deviceId, rfb);
    setSyncBadge(inst, true);
    if (inst.checkbox) inst.checkbox.checked = true;
    inst.tile.classList.add('tile-selected');
    // 主控连接始终携带广播标记，勾选同步设备无需重建 → 主控画面不跳动
  }
  updateSyncBtn();
}

/**
 * 更新同步按钮状态（竞态二态）：图标恒为链路 SVG；进入同步选择模式后按钮变红，
 * 再次点击断开并恢复原色。
 * @returns {void}
 */
function updateSyncBtn() {
  const btn = $('btnSync');
  if (!btn) return;
  const n = syncRfbs.size;
  const active = syncMode;
  btn.classList.toggle('sync-active', active);
  btn.title = active
    ? (n > 0 ? `同步中（${n} 台设备），点击断开并恢复` : '同步选择中，点击断开')
    : '同步控制：点击选择设备与主控同步';
}

function fmtTime(ts) {
  if (!ts) return '未知';
  const d = new Date(ts);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

// ---------- 直控模式（所有设备开启推流，卡片上直接点击控制） ----------
let directMode = false;          // 直控模式：卡片直达控制，悬停效果与引导提示失效
const directRfbs = new Map();    // deviceId -> RFB（非 ctrl 可输入连接，互不抢占）

/**
 * 为单个真实设备建立直控 RFB（非 ctrl 可输入连接：互不抢占、输入直达设备）。
 * 重复调用安全：设备已在直控中则直接返回其 RFB。
 * @param {object} d 设备对象（须为在线真实隧道设备）
 * @returns {object|null} 直控 RFB 或 null（卡片实例未就绪）
 */
function startDirectRfb(d) {
  const inst = wallInstances.get(d.id);
  if (!inst) return null;
  inst.tile.classList.add('direct-active'); // 直控描边：与普通卡片区分
  const exist = directRfbs.get(d.id);
  if (exist) return exist;
  stopWallRfb(inst); // 停缩略图获取
  const tv = inst.tile.querySelector('.tv');
  // 2026-08-22：直控模式加载动画——卡片中央显示「连接中…」旋转浮层（与聚焦大屏一致），
  // connect 后隐藏；复用 .focus-status-ov 样式（挂到卡片 .tv 内，position:absolute 覆盖卡片）
  let ov = tv.querySelector('.focus-status-ov');
  if (!ov) {
    ov = document.createElement('div');
    ov.className = 'focus-status-ov show loading';
    ov.innerHTML = '<div class="spin"></div><div id="focusStatusText">连接中…</div>';
    tv.appendChild(ov);
  } else {
    ov.classList.add('show', 'loading');
  }
  const rfb = createRfb(tv, d, { ctrl: false }); // 非 ctrl 可输入连接：互不抢占、输入直达设备
  rfb.addEventListener('connect', () => {
    const o = tv.querySelector('.focus-status-ov');
    if (o) o.classList.remove('show', 'loading');
  });
  rfb.addEventListener('disconnect', (e) => {
    // 设备离线/隧道断/服务端断开：清理直控标记，恢复缩略图获取
    if (directRfbs.get(d.id) === rfb) {
      directRfbs.delete(d.id);
      inst.tile.classList.remove('direct-active'); // 直控结束移除描边
      const o = tv.querySelector('.focus-status-ov');
      if (o) o.remove();
      // 2026-08-22：主动退出直控（directMode=false）立即恢复缩略图——_lastFrame 截图
      // （exitDirectMode 退出前已截）由 startWallRfb 先显示，不闪「加载中…」、不黑屏；
      // 无截图则显示加载中动画。异常断开（directMode=true）同样立即恢复。
      if (directMode) {
        startWallRfb(inst);
        updateDirectBtn();
        const code = e && e.detail && e.detail.code;
        toast(`设备「${d.name}」直控已断开` + (code ? `（${code}）` : ''), 'error');
      } else {
        startWallRfb(inst);
        updateDirectBtn();
      }
    }
  });
  directRfbs.set(d.id, rfb);
  return rfb;
}

/**
 * 切换直控模式（竞态二态）：进入 = 所有在线真实设备建立可输入 RFB 推流到卡片；
 * 退出 = 关闭全部直控 RFB，恢复缩略图获取。
 * @returns {void}
 */
function toggleDirectMode() {
  if (directMode) { exitDirectMode(); return; }
  // 2026-08-19：进入直控前先退出聚焦大屏、布局重置为卡片墙——避免"正大屏操作一台设备时点直控，
  // 布局仍是大屏"的问题（直控语义 = 卡片墙直达控制，需完整墙视图）
  if (focus) exitFocus();
  if (layoutMode !== 'grid') applyLayout('grid');
  directMode = true;
  const wall = $('wall');
  if (wall) wall.classList.add('direct-mode');
  let n = 0;
  for (const d of devices) {
    if (!d.online || d.mock || d.source !== 'register') continue; // 仅在线真实隧道设备
    if (startDirectRfb(d)) n++;
  }
  updateDirectBtn();
  if (n > 0) toast(`直控模式：${n} 台设备已开启推流，点击卡片直接控制`, 'info');
  else toast('直控模式：当前无在线真实设备', 'info');
}

/**
 * 退出直控模式：关闭全部直控 RFB，恢复缩略图获取，按钮恢复原色。
 * @returns {void}
 */
function exitDirectMode() {
  if (!directMode && directRfbs.size === 0) return;
  directMode = false;
  const wall = $('wall');
  if (wall) wall.classList.remove('direct-mode');
  // 先 close 全部直控 RFB（必须真正断开 WS，否则残留会话持续占用设备推流，
  // 再次进入直控时会话堆积 → 服务端 sessions=2/3…，还会与后续 rfb.stop 互扰）。
  // 注意 stopWallRfb 只处理 inst.rfb（截图轮询），直控 RFB 在 directRfbs 中，须显式 close。
  for (const [id, rfb] of directRfbs.entries()) {
    const inst = wallInstances.get(id);
    if (inst) {
      // 2026-08-22 时序原则：断开时「先清理被控中状态，再断开」——
      // ① 截图直控 canvas 最后画面（noVNC disconnect 会移除 canvas，截图保留最后画面，
      //    startWallRfb 先显示它，缩略图就绪后替换）
      // ② 本地置 controlled=false + 移除「被控制中」遮罩 + 清理加载浮层
      // ③ 然后才 closeRfb
      if (inst.tile) {
        inst.tile.classList.remove('direct-active'); // 先去除描边（点击退出瞬间视觉立即反馈）
        const c = inst.tile.querySelector('.tv canvas');
        if (c) {
          try { inst._lastFrame = c.toDataURL('image/jpeg', 0.7); } catch (e) { inst._lastFrame = null; }
        }
        const ov = inst.tile.querySelector('.focus-status-ov');
        if (ov) ov.remove();
        const dev = devices.find((d) => d.id === id);
        if (dev) dev.controlled = false;
        const mask = inst.tile.querySelector('.ctrl-mask');
        if (mask) mask.remove();
      }
    }
    closeRfb(rfb);
  }
  directRfbs.clear();
  updateDirectBtn();
  // 2026-08-22：断开后本地 controlled=false 保持（不 refreshDevices 覆盖），
  // 网关 rfb.stop 上报 controlled=false 后经 state 事件/后续刷新保持，无需延迟 hack。
  // 立即恢复缩略图：_lastFrame 截图（退出前已截）由 startWallRfb 先显示，不闪「加载中…」、
  // 不黑屏；无截图（连接失败/黑屏）则显示加载中动画。网关缩略图链路重建后经
  // refreshDevices/事件再拉新缩略图替换，无需 1200ms 延迟。
  for (const inst of wallInstances.values()) {
    if (inst.device.online !== true || inst.paused) continue;
    startWallRfb(inst);
  }
}

/**
 * 更新直控按钮状态：激活态变色并显示直控设备数
 * @returns {void}
 */
function updateDirectBtn() {
  const btn = $('directBtn');
  if (!btn) return;
  const n = directRfbs.size;
  btn.textContent = n > 0 ? `直控 (${n})` : '直控';
  btn.classList.toggle('direct-active', directMode);
  btn.title = directMode
    ? (n > 0 ? `直控中（${n} 台），点击退出` : '直控模式')
    : '直控模式：所有设备开启推流，卡片上直接点击控制';
}

// 设备状态变化时更新墙卡片（在线<->离线切换、名称、状态、上次在线）
function updateWallTile(inst, d) {
  inst.device = d;
  const tile = inst.tile;
  tile.classList.toggle('direct-active', directRfbs.has(d.id)); // 直控描边随卡片重建同步
  tile.classList.toggle('tile-controlled', !!d.controlled); // 被控制中：隐藏 hover 引导提示
  tile.querySelector('.tname').textContent = d.name;
  tile.querySelector('.dot').className = 'dot ' + (d.online ? 'on' : 'off');
  const tv = tile.querySelector('.tv');
  // 2026-08-22：被控制中（5801 直连 / 隧道）→ 不显示画面（停止缩略图获取，避免泄露被控画面）；
  // 被控解除后恢复缩略图获取
  const isControlled = d.controlled && d.online;
  if (isControlled) {
    if (inst.rfb) stopWallRfb(inst);
  } else if (!d.controlled && !inst.paused && !inst.rfb) {
    startWallRfb(inst);
  }
  // 被控状态遮罩（2026-08-22）：设备被控制（隧道 rfb.start / 5801 直连）时叠加「被控制中」遮罩，
  // 网关经 /api/devices 附带 controlled 字段（隧道 FT_STATE 上报），此处按需增删遮罩元素。
  // 直控模式（directMode）下设备由本端自己控制，不显示「被控制中」遮罩。
  let mask = tile.querySelector('.ctrl-mask');
  if (d.controlled && d.online && !(directMode && directRfbs.has(d.id))) {
    if (!mask) {
      mask = document.createElement('div');
      mask.className = 'ctrl-mask';
      mask.textContent = d.controlledSource === '5801' ? '被 5801 控制中' : '被控制中';
      tile.appendChild(mask);
    } else if (d.controlledSource === '5801') {
      mask.textContent = '被 5801 控制中';
    }
  } else if (mask) {
    mask.remove();
  }
  if (d.online) {
    if (inst.paused) return; // 聚焦中，保持隐藏
    tile.classList.remove('tile-offline');
    // 直控模式：该设备已有直控 RFB（实时推流 canvas）。设备信息轮询刷新
    // 绝不能覆盖直控画面或恢复缩略图获取，否则“操作两下后直控失效”（canvas 被替换）。
    if (directMode && directRfbs.has(d.id)) return;
    if (!inst.rfb) { // 未在获取缩略图，启动它
      tv.innerHTML = '<div class="offline-ph">已连接</div>';
      startWallRfb(inst);
    }
  } else {
    tile.classList.add('tile-offline');
    // 直控模式：设备离线应立即退出直控（WS 断开可能滞后，且 stopWallRfb 不处理 directRfbs）
    if (directRfbs.has(d.id)) {
      closeRfb(directRfbs.get(d.id));
      directRfbs.delete(d.id);
      updateDirectBtn();
    }
    stopWallRfb(inst);
    tv.innerHTML = '<div class="offline-ph">离线</div>';
    inst.statusEl.textContent = d.lastSeen ? '离线 · ' + fmtTime(d.lastSeen) : '离线';
  }
}

// 进入聚焦前用已知设备比例预置面板宽度，避免“先宽后窄”闪烁
function prefitFocusPanel(ratio) {
  if (window.matchMedia('(max-width: 900px)').matches) return; // 移动端全屏
  const panel = $('focusPanel');
  const workspace = $('workspace');
  if (!panel || !workspace) return;
  const wsW = workspace.clientWidth;
  const wsH = workspace.clientHeight;
  const headH = 26; // 紧凑头部高度（padding 3px*2 + 13px 行高 + 边框）
  const opsW = ($('focusOps').offsetWidth) || 64;
  const availH = Math.max(200, wsH - headH);
  const availW = Math.max(200, wsW - opsW - 130);
  let pw = availH * ratio;
  if (pw > availW) pw = availW;
  if (pw < 160) pw = 160;
  panel.style.flex = '0 0 ' + Math.floor(pw) + 'px';
  panel.style.width = Math.floor(pw) + 'px';
}

// 聚焦画面：面板宽度跟随设备屏幕比例（竖屏手机=窄高面板），消除两侧空白；
// 操作列紧贴面板右侧，剩余空间给右侧设备墙
function fitFocusPanel() {
  if (!focus || !focus.rfb) return;
  const panel = $('focusPanel');
  const screenEl = $('focusScreen');
  const stage = $('focusStage');
  if (!panel || !screenEl || !stage) return;
  if (window.matchMedia('(max-width: 900px)').matches) {
    // 移动端全屏：stage 用 JS 像素值撑满视口（noVNC scaleViewport 以此为适配基准）。
    // 2026-08-15 根因修复（画布"先贴顶后贴底"漂移，IPA WKWebView）：此前 height:100%
    // 依赖 CSS 高度链（focusPanel fixed inset:0 → focusScreen flex:1 → stage 100%），
    // WKWebView 首帧布局时 safe-area-inset-top 从 0 注入真实值 → header 高度跳变 →
    // 该链测量未稳定 → noVNC autoscale 用错容器尺寸 → 画布贴顶；重排后跳底。
    // 改用 window.innerHeight 像素值：不依赖 CSS 高度链，尺寸恒定，画布不再漂移。
    stage.style.width = window.innerWidth + 'px';
    stage.style.height = window.innerHeight + 'px';
    return;
  }
  const disp = focus.rfb._display;
  const fw = focus.rfb._fb_width || (disp && disp._fbWidth) || 0;
  const fh = focus.rfb._fb_height || (disp && disp._fbHeight) || 0;
  const ratio = (fw && fh) ? (fw / fh) : (9 / 16);  // 设备连接后用设备宽高比，未知时 9:16 兜底
  const wsW = $('workspace').clientWidth;
  const headH = (panel.querySelector('.focus-head') ? panel.querySelector('.focus-head').offsetHeight : 0) || 48;
  const availH = panel.clientHeight - headH;
  const opsW = ($('focusOps').offsetWidth) || 64;
  const availW = Math.max(0, wsW - opsW - 130); // 130: 右侧墙最小宽度+间距
  let pw = availH * ratio;           // 以面板高度为准的理想宽度
  if (pw > availW) pw = availW;      // 太宽则受限
  if (pw < 160) pw = 160;
  panel.style.flex = '0 0 ' + Math.floor(pw) + 'px';
  panel.style.width = Math.floor(pw) + 'px';
  // 2026-08-15 修复画布位置漂移（先贴顶后贴底）：stage 高度统一由 CSS height:100% 恒定撑满
  // focusScreen（.screen flex:1）——此前 connect 前 stage 无高度塌缩 → noVNC autoscale 用错容器
  // 尺寸 → 画布贴顶；fitFocusPanel 在 connect 后 300/400ms 才设置 stage 高度 → 画布位置跳变。
  // 删除 stage.style.height 动态赋值，只保留宽度 100%（高度由 .focus-stage {height:100%} 承担）。
  stage.style.width = '100%';
}

// ---------- 本地操作（全屏/断开，控制台本地能力，不通过设备 API） ----------
// 适配画面为自动行为：createRfb 统一 rfb.scaleViewport = true（等比缩放 contain），无独立按钮
function currentRfb() { return focus ? focus.rfb : null; }

/**
 * 本地操作：全屏/断开
 * 控制型按键（Home/电源/音量/系统动作等）走 RFB 直发（rfbPressKey，见 renderCapOps）
 */
function doOp(op) {
  const rfb = currentRfb();
  if (!rfb && op !== 'disc') return;
  switch (op) {
    case 'full':
      if (document.fullscreenElement) document.exitFullscreen();
      else document.documentElement.requestFullscreen().catch(() => {});
      break;
    case 'disc': exitFocus(); break; // 2026-08-22：不再先 rfb.disconnect()——exitFocus 内先截图再 closeRfb，先 disconnect 会移除 canvas 导致截图失败（canvas= false）
  }
}

/**
 * 根据 schema 构建配置输入控件
 * @param schema 配置 schema（含 type/min/max/enum）
 * @param val   当前值
 * @returns HTMLInputElement 或 HTMLSelectElement
 */
function buildConfigInput(schema, val) {
  if (schema.type === 'bool') {
    const inp = document.createElement('input');
    inp.type = 'checkbox';
    inp.checked = !!val;
    return inp;
  }
  if (schema.type === 'enum') {
    const sel = document.createElement('select');
    const vals = schema.enumValues || [];
    const titles = schema.enumTitles || vals;
    vals.forEach((v, i) => {
      const opt = document.createElement('option');
      opt.value = v;
      opt.textContent = titles[i] || String(v);
      if (String(v) === String(val)) opt.selected = true;
      sel.appendChild(opt);
    });
    return sel;
  }
  if (schema.type === 'number') {
    const inp = document.createElement('input');
    inp.type = 'number';
    if (schema.min !== undefined) inp.min = schema.min;
    if (schema.max !== undefined) inp.max = schema.max;
    if (schema.step !== undefined) inp.step = schema.step;
    inp.value = val ?? '';
    return inp;
  }
  // string / password
  const inp = document.createElement('input');
  inp.type = schema.type === 'password' ? 'password' : 'text';
  inp.value = val ?? '';
  return inp;
}

/**
 * 从输入控件读取配置值
 * @param inp 输入控件
 * @returns 配置值（bool/number/string）
 */
function readConfigValue(inp) {
  if (inp.type === 'checkbox') return inp.checked;
  if (inp.type === 'number') {
    const v = Number(inp.value);
    return isNaN(v) ? 0 : v;
  }
  if (inp.tagName === 'SELECT') {
    const v = inp.value;
    // 数字字符串转数字
    if (/^-?\d+$/.test(v)) return Number(v);
    return v;
  }
  return inp.value;
}

// ---------- RFB 帮助 ----------
function createRfb(container, device, opts = {}, statusEl = null) {
  const params = {};
  if (opts.grp) params.grp = opts.grp;
  if (opts.broadcast) params.broadcast = '1';
  if (opts.ctrl) params.ctrl = '1';
  const uri = wsUrl(`/ws/vnc/${encodeURIComponent(device.id)}`, params);
  const rfb = new RFB(container, uri, {});
  rfb.scaleViewport = true;
  rfb.resizeSession = false;
  rfb.showDotCursor = false; // 2026-08-18 前端光标全权接管，不用 noVNC 默认 dot
  // 2026-08-15：画面余白透明跟随系统主题——noVNC 内部 _screen 默认硬编码 rgb(40,40,40) 深灰，
  // 覆盖外层 .screen 的 transparent 无效；此处显式置透明，露出 body 背景（--bg 随 prefers-color-scheme）。
  rfb.background = 'transparent';
  if (opts.viewOnly) rfb.viewOnly = true;   // 墙缩略图只读：点击卡片=切入大屏控制，不直接操控
  // 光标策略（2026-08-18 定稿）：
  // - 墙缩略图（viewOnly）与触屏端（isMobile）：不显示任何光标（触屏手指即指针，
  //   不再有自动消失触点；墙缩略图消除多 RFB 覆盖层串扰）——服务器光标（移除
  //   ServerCursor 后 libvncserver 默认 X 形）与前端圆一律屏蔽
  // - PC 端聚焦/直控画面：常驻深灰圆+浅灰外圈（自绘 fixed 覆盖层 pcRgba）
  // PC 端常驻光标样式（2026-08-18）：内芯深灰 + 外圈一圈浅灰描边，尺寸略大（28px）。
  const PC_CURSOR_SIZE = 28;
  const PC_CURSOR_R = 11;          // 外圈半径
  const PC_CURSOR_CORE_R = 8;      // 内芯半径（深灰）
  const pcRgba = (() => {
    const S = PC_CURSOR_SIZE, cx = (S - 1) / 2, cy = (S - 1) / 2, R = PC_CURSOR_R, CR = PC_CURSOR_CORE_R;
    const rgba = new Uint8Array(S * S * 4);
    for (let y = 0; y < S; y++) {
      for (let x = 0; x < S; x++) {
        const d = Math.hypot(x - cx, y - cy);
        const i = (y * S + x) * 4;
        if (d <= CR) {
          // 内芯：均匀深灰（恒定透明度，避免中心渐变加深成一个点）
          rgba[i] = 60; rgba[i + 1] = 60; rgba[i + 2] = 60;
          // 边缘 1px 羽化：CR-1 内从 232 平滑降到 0，消除硬边
          rgba[i + 3] = d > CR - 1
            ? Math.round(232 * (CR - d))
            : 232;
        } else if (d <= R) {
          // 外圈：浅灰描边环，由内向外渐隐
          rgba[i] = 160; rgba[i + 1] = 160; rgba[i + 2] = 160;
          rgba[i + 3] = Math.round(210 * (1.0 - ((d - CR) / (R - CR))));
        }
      }
    }
    return rgba;
  })();
  const pcHot = Math.round((PC_CURSOR_SIZE - 1) / 2);
  if (opts.viewOnly || isMobile()) {
    // 墙缩略图 / 触屏端：不显示任何光标。服务器光标（移除 ServerCursor 后
    // libvncserver 默认 X 形）与前端圆一律屏蔽（clear → cursor:none + 覆盖层清空）。
    rfb._refreshCursor = () => { if (rfb._cursor) rfb._cursor.clear(); };
  } else {
    // PC 聚焦/直控：覆盖层常驻光标（自绘 fixed canvas，pcRgba）。
    // 系统光标已被 rfb._cursor 初始 clear() 置为 none，圆由本层常驻绘制。
    const layer = document.createElement('canvas');
    layer.style.cssText = 'position:fixed;z-index:65535;pointer-events:none;visibility:hidden;';
    document.body.appendChild(layer);
    const paint = (x, y) => {
      layer.width = PC_CURSOR_SIZE;
      layer.height = PC_CURSOR_SIZE;
      layer.getContext('2d').putImageData(
        new ImageData(new Uint8ClampedArray(pcRgba), PC_CURSOR_SIZE, PC_CURSOR_SIZE), 0, 0);
      layer.style.left = (x - pcHot) + 'px';
      layer.style.top = (y - pcHot) + 'px';
      layer.style.visibility = '';
    };
    const show = (e) => paint(e.clientX, e.clientY);
    const hide = () => { layer.style.visibility = 'hidden'; };
    const cv = rfb._canvas;
    const opt = { capture: true, passive: true };
    cv.addEventListener('mouseover', show, opt);
    cv.addEventListener('mousemove', show, opt);
    cv.addEventListener('mousedown', show, opt);
    cv.addEventListener('mouseleave', hide, opt);
    rfb.addEventListener('disconnect', hide);
    // 覆盖 _refreshCursor 为空操作：系统光标保持 none，常驻灰圆由覆盖层接管
    rfb._refreshCursor = () => {};
  }
  // 聚焦画布多点手势（2026-08-16）：noVNC pinch/twotap/threetap → touch.* 能力调用
  // （真实 IOHID 多点注入；仅聚焦可操控会话响应，直控/同步实例与断开后不响应）
  if (!opts.viewOnly && rfb._canvas) {
    attachFarmGesture(rfb._canvas, {
      shouldRun: () => !!(focus && focus.rfb === rfb && focus.device && rfb._farmConnected && !rfb.viewOnly),
      invoke: (cap, params) => {
        const dev = focus && focus.device;
        if (!dev) return;
        invokeCap('', dev.id, cap, params).catch((err) => console.warn(`[gesture] ${cap} 失败: ${err.message}`));
      },
    });
  }
  // 鼠标右键 = Home 键（2026-08-19，对齐按键区 Home 键语义）：拦截 noVNC 原生右键
  // （0x4→设备端 menuDown），统一走 RFB 直发 0xff50；单击立即发、双击/三击=自然连点
  // 由被控端系统层识别。触控端（移动端布局/直控/同步）与 PC 端聚焦画布共用此语义。
  if (!opts.viewOnly && rfb._canvas) {
    attachRightHome(rfb, {
      send: () => {
        if (!rfb._farmConnected) return; // 与按键区一致：仅 RFB 直发通道就绪时发送
        try { rfb.sendKey(0xff50, 'Home', true); } catch (e) { /* noVNC API 异常静默忽略 */ }
        setTimeout(() => { try { rfb.sendKey(0xff50, 'Home', false); } catch (e) { /* 静默 */ } }, 60);
      },
    });
  }
  // 聚焦画布帧尺寸变化跟随（2026-08-19）：设备横/竖屏切换 → noVNC _resize（桌面尺寸变化
  // 统一入口，含 ExtendedDesktopSize/DesktopSize 伪编码）→ 画布内容自动切换，但聚焦面板宽度
  // 由 fitFocusPanel 按 _fb_width/_fb_height 计算，仅在 connect 后算过一次——实例级 patch
  // _resize，帧尺寸变化后重算面板宽度，画布容器跟随设备方向。仅 ctrl 聚焦会话需要
  // （直控/同步画布在固定比例卡片内 contain，与卡片墙显示方向解耦，不跟随）。
  if (!opts.viewOnly && opts.ctrl && rfb._resize) {
    const origResize = rfb._resize.bind(rfb);
    rfb._resize = (w, h) => {
      origResize(w, h);
      if (focus && focus.rfb === rfb) {
        requestAnimationFrame(() => {
          if (focus && focus.rfb === rfb) fitFocusPanel();
        });
      }
    };
  }
  // PC 端聚焦/直控画面：常驻深灰圆+浅灰外圈覆盖层（2026-08-18，见上方光标策略分支）。
  // 状态用红/蓝圆点表示（蓝=已连接，红=已断开/失败），不再显示文字
  const setStatus = (s) => {
    if (!statusEl) return;
    statusEl.classList.toggle('on', s === '已连接');
    statusEl.classList.toggle('off', s !== '已连接');
  };
  rfb.addEventListener('connect', () => {
    rfb._farmConnected = true;   // RFB 直发通道就绪标志（按键区判断用）
    setStatus('已连接');
  });
  rfb.addEventListener('disconnect', (e) => {
    rfb._farmConnected = false;  // 通道断开：按键区回退能力链路
    setStatus('已断开');
    // 2026-08-23：聚焦控制会话的断开已由 enterFocus 的 disconnect 监听在浮层明确报错，
    // 此处仅对非聚焦场景（墙缩略图/直控）弹提示，避免重复弹窗。
    const isFocusRfb = !!(focus && focus.rfb === rfb);
    if (isFocusRfb) return;
    const d = e && e.detail ? e.detail : {};
    const code = d.code;
    if (code === 4001) alert('设备已被其它端接管，已中断控制');
    else if (code === 4003) alert('设备隧道未建立（可能刚注册或正在重连），请稍候重试');
    else if (code === 4005) {
      // 设备隧道在线但 5901 画面服务不可用（设备端 VNC 服务未运行）：
      // 与"设备离线"区分开，明确提示画面服务问题而非误导为设备掉线
      toast('✗ 设备在线但画面服务不可用（设备端 VNC 服务未运行），请检查设备', 'error');
    } else if (code && code !== 1000) {
      // 非正常关闭（1006 等）：显示断开码便于定位（1000=正常断开不提示）
      toast(`画面断开 (${code})${d.reason ? '：' + d.reason : ''}`, 'error');
    }
  });
  rfb.addEventListener('credentialsrequired', () => {
    const p = prompt(`请输入 ${device.name} 的 VNC 密码：`);
    if (p) rfb.sendCredentials({ password: p });
  });
  // 2026-08-17 修复：剪贴板 listener 删除时误删了 createRfb 闭合（return rfb; }），
  // 导致后续函数落入 createRfb 块内不可见（copyFromFocusedDevice undefined → 聚焦加载失败）
  return rfb;
}
// 设备→控制端剪贴板写入（2026-08-14 基建）：IPA 容器走原生桥 writeClipboard（无手势/安全上下文限制）；
// 无桥环境（浏览器）：writeText 尽力而为（https 瞬态激活窗口内），失败降级 execCommand（http 亦可）。
// @param {string} text 设备剪贴板文本
// @param {string} devName 来源设备名（toast 标注用）
function farmWriteClipboardToControl(text, devName) {
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.farmBridge;
  if (bridge) {
    try {
      bridge.postMessage({ type: 'writeClipboard', text });
      toast(`✓ 已复制设备「${devName}」剪贴板（${text.length} 字符）`, 'success');
      return;
    } catch (e) {
      console.error('[clip] native writeClipboard 桥调用失败，降级 writeText：', e);
    }
  }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(() => {
      console.debug(`[clip] 已写入控制端剪贴板（${text.length} 字符）`);
      toast(`✓ 已复制设备「${devName}」剪贴板（${text.length} 字符）`, 'success');
    }).catch((err) => {
      console.error('[clip] writeText 失败，降级 execCommand：', err);
      execCopyFallback(text, devName);
    });
    return;
  }
  execCopyFallback(text, devName);
}

// execCommand('copy') 兜底（http 或 writeText 被拒）：隐藏 textarea + select + execCommand。
// 不要求安全上下文，仅在用户手势/瞬态激活窗口内可靠（局域网 clipboard.get 往返毫秒级满足）；
// 失败给出明确提示（极低概率路径）。
function execCopyFallback(text, devName) {
  try {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand('copy');
    document.body.removeChild(ta);
    if (ok) {
      toast(`✓ 已复制设备「${devName}」剪贴板（${text.length} 字符）`, 'success');
      return;
    }
  } catch (e) {
    console.error('[clip] execCommand 失败：', e);
  }
  // 2026-08-17：http/iOS Safari execCommand('copy') 不可用 → 浮层展示文本供长按复制（对齐 5801）
  showCopyTextModal(text, devName);
}

// 复制结果浮层（2026-08-17，与 5801 对齐）：设备剪贴板文本无法写入控制端剪贴板时，
// 展示文本供长按复制；关闭按钮或点遮罩关闭。
let _copyTextModal = null;
function showCopyTextModal(text, devName) {
  if (_copyTextModal) { _copyTextModal.remove(); _copyTextModal = null; }
  const overlay = document.createElement('div');
  overlay.className = 'modal';
  const card = document.createElement('div');
  card.className = 'modal-card';
  const title = document.createElement('h3');
  title.textContent = `设备「${devName}」剪贴板内容`;
  const ta = document.createElement('textarea');
  ta.readOnly = true;
  ta.value = text;
  ta.style.cssText = 'width:100%;min-height:120px;box-sizing:border-box;padding:8px;margin:10px 0;';
  const p = document.createElement('p');
  p.textContent = '长按上方文本复制到本机';
  const closeBtn = document.createElement('button');
  closeBtn.textContent = '关闭';
  const close = () => {
    overlay.remove();
    _copyTextModal = null;
  };
  closeBtn.addEventListener('click', close);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
  card.appendChild(title); card.appendChild(ta); card.appendChild(p); card.appendChild(closeBtn);
  overlay.appendChild(card);
  document.body.appendChild(overlay);
  _copyTextModal = overlay;
  setTimeout(() => { try { ta.focus(); ta.select(); } catch (e) {} }, 100);
}

// 复制按钮（2026-08-17 显式双向搬运）：拉取被控设备剪贴板 → 写控制端剪贴板（降级链见 farmWriteClipboardToControl）。
async function copyFromFocusedDevice() {
  if (!focus || !focus.device) {
    toast('✗ 复制失败：请先进入设备控制', 'error');
    return;
  }
  try {
    const r = await invokeCap('', focus.device.id, 'clipboard.get');
    const text = r && r.ack && r.ack.text != null ? r.ack.text : '';
    if (!(r && r.ok) || typeof text !== 'string') {
      toast(`✗ 复制失败：${(r && r.ack && r.ack.error) || '设备未返回剪贴板'}`, 'error');
      return;
    }
    if (!text) {
      toast('✗ 复制失败：被控设备剪贴板为空', 'error');
      return;
    }
    farmWriteClipboardToControl(text, focus.device.name);
  } catch (e) {
    toast(`✗ 复制失败：${e.message}`, 'error');
  }
}

// 粘贴降级浮层（2026-08-17）：控制端（https 不可用）与设备剪贴板均为空时弹输入框；
// 无确定按钮——粘贴进文本（paste 事件，不要求安全上下文）或回车即自动注入被控设备。
let _pasteFallbackModal = null;
function showPasteFallbackModal() {
  if (_pasteFallbackModal) { _pasteFallbackModal.focus(); return; }
  const overlay = document.createElement('div');
  overlay.className = 'modal';
  const card = document.createElement('div');
  card.className = 'modal-card';
  const title = document.createElement('h3');
  title.textContent = '粘贴输入（粘贴或回车自动注入）';
  const inp = document.createElement('input');
  inp.type = 'text';
  inp.placeholder = '长按粘贴或输入文本';
  const cancelBtn = document.createElement('button');
  cancelBtn.textContent = '取消';
  const close = () => {
    document.removeEventListener('keydown', kbHandler, true);
    overlay.remove();
    _pasteFallbackModal = null;
  };
  const doPaste = () => {
    const txt = inp.value;
    close();
    if (txt && focus && focus.device) submitPasteText(focus.device.id, txt);
  };
  inp.addEventListener('paste', (e) => {
    const txt = (e.clipboardData && e.clipboardData.getData('text')) || '';
    if (txt) { e.preventDefault(); inp.value = txt; doPaste(); } // 粘贴进文本：自动注入
  });
  inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); doPaste(); } });
  cancelBtn.addEventListener('click', close);
  const kbHandler = (e) => { if (e.key === 'Escape') close(); };
  document.addEventListener('keydown', kbHandler, true);
  card.appendChild(title); card.appendChild(inp); card.appendChild(cancelBtn);
  overlay.appendChild(card);
  document.body.appendChild(overlay);
  _pasteFallbackModal = overlay;
  inp.focus();
}
function closeRfb(rfb) {
  if (!rfb) return;
  try {
    // noVNC 的 disconnected/disconnecting 是终态/过渡态，再次 disconnect 会抛
    // "Tried changing state of a disconnected RFB object"，先检查状态再断开
    const st = rfb._rfbConnectionState;
    if (st && st !== 'disconnected' && st !== 'disconnecting') {
      rfb.disconnect();
    }
    // 2026-08-23 根因修复：noVNC disconnect() 只 detach 监听、不主动关闭 WS socket
    // （关闭依赖服务器主动 close 触发 _socketClose）。网关不会主动关控制 WS → 每次退出
    // 控制 WS 挂着、网关 controller 会话残留 → 连续进出累积（WS 并发 + 会话残留）→ 卡住。
    // 主动关闭底层 socket，确保退出即断、网关立即 cleanup。
    if (rfb._sock && typeof rfb._sock.close === 'function') {
      try { rfb._sock.close(); } catch (e) { /* ignore */ }
    }
  } catch (e) { /* ignore */ }
}

// ---------- 设备管理 ----------
// 2026-08-19：手动「添加设备」已完全去除——控制端设备列表仅保留 source=register 隧道设备
// （直连 host 设备模式已废弃，统一走网关隧道），添加 host:port 手动设备无控制意义。
// 后端 POST /api/devices 保留（隧道测试依赖其验证"无隧道拒绝 4003"），仅前端入口移除。
/**
 * 显示卡片右下角⋯菜单（2026-08-15：仅保留「编辑」「删除」——用户拍板去除全部参数/能力/更多参数设置）
 * 编辑：改名（设备名）+ 改 ID（排序号）；删除：清除设备记录并移除卡片（直接删除无确认）。
 * @param {HTMLElement} tile 卡片元素（用于定位菜单）
 * @param {object} d 设备对象
 * @param {number} x 点击位置 clientX
 * @param {number} y 点击位置 clientY
 * @returns {void}
 */
function showTileMenu(tile, d, x, y) {
  const m = $('tileMenu');
  m.innerHTML = '';

  // 编辑：改名（设备名）+ 改 ID（排序号）——ID 不显示，仅决定卡片排列位置
  const editBtn = document.createElement('button');
  editBtn.innerHTML = '<span class="cap-icon">✏️</span><span class="cap-name">编辑</span>';
  editBtn.addEventListener('click', () => { m.classList.add('hidden'); openEditModal(d); });
  m.appendChild(editBtn);

  // 旋转（横/竖屏显示切换，2026-08-19）：仅卡片视图有意义（列表视图固定行高，比例不生效）。
  // 切换该卡片在墙上的显示比例：横屏=设备 screen 比例倒置 + 缩略图旋转铺满；恢复=跟随全局统一比例。
  // 聚焦画面始终实时跟随设备方向（fitFocusPanel 用实时帧尺寸），不受此偏好影响。
  // 图标=旋转箭头（逆时针循环，贴合「旋转」语义），文字固定「旋转」。
  if (layoutMode === 'grid') {
    const orientBtn = document.createElement('button');
    // 图标=旋转箭头（逆时针循环，贴合「旋转」语义），文字固定「旋转」
    const orientIcon = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg>';
    orientBtn.innerHTML = `<span class="cap-icon">${orientIcon}</span><span class="cap-name">旋转</span>`;
    orientBtn.addEventListener('click', () => {
      m.classList.add('hidden');
      // 每次点击读取最新方向状态（菜单可被多次打开，勿用缓存值）
      setTileOrient(d.id, getTileOrient(d.id) === 'landscape' ? 'portrait' : 'landscape');
      applyTileOrient(tile, d);
    });
    m.appendChild(orientBtn);
  }

  // 删除：清除该设备记录并移除卡片（2026-08-15：直接删除，无二次确认——用户拍板）
  const delBtn = document.createElement('button');
  delBtn.style.color = 'var(--bad)';
  delBtn.innerHTML = '<span class="cap-icon">🗑️</span><span class="cap-name">删除</span>';
  delBtn.addEventListener('click', () => { m.classList.add('hidden'); deleteDeviceCard(d); });
  m.appendChild(delBtn);

  m.classList.remove('hidden');
  const rect = tile.getBoundingClientRect();
  m.style.left = Math.min(x, window.innerWidth - 140) + 'px';
  m.style.top = Math.min(y, window.innerHeight - 160) + 'px';
}

// ---------- 编辑设备（改名 + 改 ID 排序号，2026-08-15） ----------
let editModalDevice = null; // 当前打开编辑弹窗对应的设备

/**
 * 打开「编辑设备」弹窗：第一行 ID（排序号，决定卡片排列位置，不显示）、第二行名称（设备名/卡片标签）。
 * 不用 window.prompt——IPA 容器 WKWebView 不支持。
 * @param {object} d 设备对象
 */
function openEditModal(d) {
  editModalDevice = d;
  $('editTitle').textContent = `编辑设备 · ${d.name}`;
  $('fEditOrder').value = typeof d.order === 'number' ? String(d.order) : '';
  $('fEditName').value = d.name || '';
  $('editModal').classList.remove('hidden');
  setTimeout(() => $('fEditName').focus(), 50);
}

/**
 * 保存编辑：ID（0-99999 整数或空=清除）+ 名称（非空）。
 * 真实改名（2026-08-19）：设备在线时先 invoke device.rename（写 MobileGestalt + 重启 SpringBoard
 * 生效），成功后再 PATCH 网关记录，保证记录与设备实际名一致（注册不会覆盖回旧名）；
 * 离线设备仅更新网关记录并提示（上线后以设备实际名为准）。
 * @returns {Promise<void>}
 */
async function saveEditModal() {
  if (!editModalDevice) return;
  const rawOrder = $('fEditOrder').value.trim();
  const order = rawOrder === '' ? null : Number(rawOrder);
  if (order !== null && (!Number.isInteger(order) || order < 0 || order > 99999)) {
    toast('✗ ID 须为 0-99999 的整数，或留空清除', 'error');
    return;
  }
  const name = $('fEditName').value.trim();
  if (!name) { toast('✗ 名称不能为空', 'error'); return; }
  const devId = editModalDevice.id;
  const devOnline = !!editModalDevice.online;
  try {
    if (devOnline) {
      const r = await invokeCap('', devId, 'device.rename', { name });
      if (!r || r.ok !== true) {
        throw new Error((r && ((r.ack && r.ack.error) || r.error)) || '设备改名失败');
      }
    }
    await api(`/api/devices/${encodeURIComponent(devId)}`, { method: 'PATCH', body: JSON.stringify({ name, order }) });
    $('editModal').classList.add('hidden');
    toast(devOnline ? `✓ 已改设备名为「${name}」` : `✓ 已更新记录「${name}」（设备离线，未改底层名）`, 'success');
    editModalDevice = null;
    await refreshDevices();
  } catch (e) {
    toast(`✗ 保存失败：${e.message}`, 'error');
  }
}

/**
 * 删除设备卡片：DELETE 网关记录 → 刷新设备墙（离线卡片/直控连接/批量选中由 refreshDevices 清理）。
 * @param {object} d 设备对象
 * @returns {Promise<void>}
 */
async function deleteDeviceCard(d) {
  try {
    await api(`/api/devices/${encodeURIComponent(d.id)}`, { method: 'DELETE' });
    toast(`✓ 已删除「${d.name}」`, 'success');
    await refreshDevices();
  } catch (e) {
    toast(`✗ 删除失败：${e.message}`, 'error');
  }
}
$('btnSaveEdit').onclick = () => saveEditModal();
$('btnCancelEdit').onclick = () => { $('editModal').classList.add('hidden'); editModalDevice = null; };
$('fEditName').addEventListener('keydown', (e) => { if (e.key === 'Enter') saveEditModal(); });


// ---------- 移动端悬浮信号按钮（圆形可拖动 + 点击展开操作菜单 + 延迟信号状态） ----------

/**
 * 将悬浮操作菜单定位到 FAB 附近且避开按钮区域（2026-08-14：改为水平展开）。
 * 按 FAB 所在半屏决定水平方向——左半屏向右展开、右半屏向左展开（该侧空间不足自动换侧）。
 * 垂直方向（2026-08-15 用户拍板）：菜单从 FAB 底部下方开始向下展开（与 FAB 保持关联，
 * 不固定贴屏幕底部）；若向下展开会触碰屏幕下边界 → 整体上移，使菜单底部贴下边界，
 * 任何情况下菜单都完整可见、永不越界。
 * 菜单必须已可见（调用前 remove hidden）以便测量真实尺寸。
 * @returns {void}
 */
function positionOpsMenu() {
  const menu = $('opsMenu'), fab = $('fab');
  if (!menu || !fab) return;
  const fr = fab.getBoundingClientRect();
  const vw = window.innerWidth, vh = window.innerHeight;
  // 2026-08-15：钳制纳入安全区（iOS 刘海/Home 条）——此前只用固定 pad=8，菜单触底时
  // 底部落入 --safe-bottom 区域，Home 条遮挡最后一行按钮（视觉上"超出屏幕"）。
  // 与 getSafeBounds 同源取值（CSS 变量），保证 FAB 可拖动区域与菜单展开区域一致。
  const cs = getComputedStyle(document.documentElement);
  const safeT = parseInt(cs.getPropertyValue('--safe-top')) || 0;
  const safeB = parseInt(cs.getPropertyValue('--safe-bottom')) || 0;
  const safeL = parseInt(cs.getPropertyValue('--safe-left')) || 0;
  const safeR = parseInt(cs.getPropertyValue('--safe-right')) || 0;
  const pad = 8, gap = 10;
  // 可用区域（视口扣除安全区），同时限制菜单宽度不超出可用区
  const availW = Math.max(120, vw - safeL - safeR - pad * 2);
  const availH = Math.max(120, vh - safeT - safeB - pad * 2);
  // 先重置 maxHeight 再测量真实尺寸（上次调用设置的 maxHeight 会压缩 offsetHeight）
  menu.style.maxHeight = '';
  const mw = Math.min(menu.offsetWidth || 160, availW);
  const rawH = menu.offsetHeight || 300;
  // maxHeight 按可用高度裁剪（触底上移时保证菜单不超出安全区上边界）
  const maxH = Math.max(80, Math.min(rawH, availH));
  menu.style.maxHeight = maxH + 'px';
  const mh = Math.min(rawH, maxH);
  // 水平：FAB 在左半屏 → 右侧展开；右半屏 → 左侧展开；空间不足自动换侧，钳制在安全区内
  const fabCenter = fr.left + fr.width / 2;
  const spaceRight = vw - safeR - (fr.right + gap) - pad;
  const spaceLeft = fr.left - safeL - gap - pad;
  let left;
  if (fabCenter < vw / 2) left = spaceRight >= mw ? fr.right + gap : fr.left - gap - mw;
  else left = spaceLeft >= mw ? fr.left - gap - mw : fr.right + gap;
  if (left < safeL + pad) left = safeL + pad;
  if (left + mw > vw - safeR - pad) left = vw - safeR - mw - pad;
  // 垂直：菜单从 FAB 底部下方开始向下展开（与 FAB 保持关联）；
  // 若菜单底部触碰安全区下边界 → 整体上移，底部贴安全区上沿，永不越界/被遮挡
  let top = fr.bottom + gap;
  if (top + mh > vh - safeB - pad) top = vh - safeB - mh - pad;
  if (top < safeT + pad) top = safeT + pad;
  menu.style.left = left + 'px';
  menu.style.top = top + 'px';
  menu.style.right = 'auto';
  menu.style.bottom = 'auto';
}

function initFab() {
  const fab = $('fab');
  let startX = 0, startY = 0, baseLeft = 0, baseTop = 0, dragging = false, moved = false;
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(v, hi));

  /**
   * 计算 FAB 拖动安全边界（考虑 env(safe-area-inset-*) 避开刘海/Home 条）
   * @returns {{minX:number, minY:number, maxX:number, maxY:number}} FAB 左上角可移动范围（px）
   */
  function getSafeBounds() {
    const cs = getComputedStyle(document.documentElement);
    const st = parseInt(cs.getPropertyValue('--safe-top')) || 0;
    const sr = parseInt(cs.getPropertyValue('--safe-right')) || 0;
    const sb = parseInt(cs.getPropertyValue('--safe-bottom')) || 0;
    const sl = parseInt(cs.getPropertyValue('--safe-left')) || 0;
    const pad = 4;
    const vw = window.innerWidth, vh = window.innerHeight;
    const fw = fab.offsetWidth || 56, fh = fab.offsetHeight || 56;
    return { minX: sl + pad, minY: st + pad, maxX: vw - fw - sr - pad, maxY: vh - fh - sb - pad };
  }

  // 整个圆形按钮可拖动；位移超过阈值才算拖动，否则 pointerup 视为"点击"展开菜单
  fab.addEventListener('pointerdown', (e) => {
    dragging = true; moved = false;
    startX = e.clientX; startY = e.clientY;
    const r = fab.getBoundingClientRect();
    baseLeft = r.left; baseTop = r.top;
    e.preventDefault(); e.stopPropagation();   // 阻止点击穿透到下方画面/被覆盖的菜单项
    fab.setPointerCapture(e.pointerId);
  });
  fab.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    const dx = e.clientX - startX, dy = e.clientY - startY;
    if (!moved && Math.abs(dx) + Math.abs(dy) > 6) moved = true;
    if (!moved) return;
    const b = getSafeBounds();
    fab.style.left = clamp(baseLeft + dx, b.minX, b.maxX) + 'px';
    fab.style.top = clamp(baseTop + dy, b.minY, b.maxY) + 'px';
    fab.style.right = 'auto'; fab.style.bottom = 'auto';
    // 菜单已展开时实时跟随 FAB 重新定位，避免拖动后遮挡
    const menu = $('opsMenu');
    if (menu && !menu.classList.contains('hidden')) positionOpsMenu();
  });
  const endDrag = () => {
    if (!dragging) return;
    dragging = false;
    if (moved) return;
    const menu = $('opsMenu');
    const willOpen = menu.classList.contains('hidden');
    menu.classList.toggle('hidden');           // 未拖动 = 点击 → 展开/收起菜单
    if (willOpen) {
      positionOpsMenu();                       // 展开后立即定位（避开 FAB 区域）
      // 2026-08-17：展开不再定时收起——点开必为按键，收起改由「点击菜单按键后」触发（scheduleFabAutoCollapse）
    } else {
      cancelFabAutoCollapse();
    }
  };
  fab.addEventListener('pointerup', endDrag);
  fab.addEventListener('pointercancel', () => { dragging = false; });
  // 窗口尺寸/方向变化时，若菜单已展开则重新定位，避免旋转后覆盖按钮或越界
  window.addEventListener('resize', () => {
    const menu = $('opsMenu');
    if (menu && !menu.classList.contains('hidden')) positionOpsMenu();
  });
}

// ---------- FAB 菜单自动收起（2026-08-17 语义改造：点击菜单按键后收起，不再从展开时计时）----------
// 配置跟随设备（App 设置页 → 网关 configs 同步）：聚焦设备优先，无聚焦时取设备墙任一注册设备。
// FabAutoCollapse=点击按键后是否收起（默认开启）；收起延时固定 1000ms（FabCollapseMs 已移除，2026-08-20）。
// instant reload 即时生效。
let fabCollapseTimer = null;
function fabCollapseConfigs() {
  const dev = (focus && focus.device) || devices.find((d) => d.source === 'register') || devices[0];
  const c = (dev && dev.configs) || {};
  return {
    auto: c.FabAutoCollapse !== false,                       // 默认开启
    ms: 1000,                                                // 固定收起延时（原 FabCollapseMs 配置已移除）
  };
}
function cancelFabAutoCollapse() {
  if (fabCollapseTimer) { clearTimeout(fabCollapseTimer); fabCollapseTimer = null; }
}
function scheduleFabAutoCollapse() {
  cancelFabAutoCollapse();
  const cfg = fabCollapseConfigs();
  if (!cfg.auto) return;
  fabCollapseTimer = setTimeout(() => {
    fabCollapseTimer = null;
    const menu = $('opsMenu');
    if (menu && !menu.classList.contains('hidden')) menu.classList.add('hidden');
  }, cfg.ms);
}

/**
 * 按延迟更新 FAB 信号格状态（data-sig 由 CSS 驱动颜色/格数）
 * @param {number} ms 延迟毫秒；<0 表示无响应/失败
 * @returns {void}
 */
function updateFabSignal(ms) {
  const fab = $('fab');
  if (!fab) return;
  if (ms >= 0 && ms < 150) fab.dataset.sig = 'sig-high';
  else if (ms >= 0 && ms < 400) fab.dataset.sig = 'sig-mid';
  else fab.dataset.sig = 'sig-low';
  fab.title = (ms >= 0 ? `延迟 ${ms}ms` : '设备无响应') + '（拖动调整位置，点击展开操作）';
}

/**
 * 控制会话期间轮询设备延迟（command ping 等 ack，测往返耗时），驱动信号格
 * @returns {void}
 */
function startFabSignalPoll() {
  stopFabSignalPoll();
  if (!focus) return;
  const d = focus.device;
  const tick = async () => {
    if (!focus || focus.device.id !== d.id) { stopFabSignalPoll(); return; }
    try {
      const t0 = performance.now();
      await api(`/api/devices/${encodeURIComponent(d.id)}/ping`, { method: 'POST' });
      updateFabSignal(Math.round(performance.now() - t0));
    } catch { updateFabSignal(-1); }
  };
  tick();
  fabSigTimer = setInterval(tick, 3000);
}

/**
 * 停止延迟轮询（退出控制/切换设备时调用）
 * @returns {void}
 */
function stopFabSignalPoll() {
  if (fabSigTimer) { clearInterval(fabSigTimer); fabSigTimer = null; }
}

// ---------- 墙屏卡片宽度（px，替代原百分比缩放：直接控制单卡像素宽，自适应平铺填满） ----------

/**
 * 应用卡片宽度到设备墙：设置 --card-w（px），grid auto-fill 按该宽度自适应列数，
 * 卡片从左到右逐行平铺、填满整行；窗口变化时列数自动增减，卡片始终紧挨排列。
 * @param {number} px 卡片宽度（像素）
 * @returns {void}
 */
function applyCardW(px) {
  const wall = $('wall');
  if (wall) wall.style.setProperty('--card-w', px + 'px');
  $('cardwVal').textContent = px + 'px';
  $('cardwRange').value = px;
}

/**
 * 计算卡片宽度滑杆的范围：基于墙容器可用宽度（未聚焦全宽）。
 * 最小固定 110px、默认固定 175px；最大保持动态（每行 5 列，随容器宽度自适应）。
 * 由 grid auto-fill 列数公式反推：列数 n = floor((W + gap) / (cardW + gap))，
 * 故 cardW = (W + gap) / n - gap，其中 W 为容器宽、gap 为卡片间距（12px）。
 * 动态值取整用 floor 并向下对齐 step（5px），保证滑杆可达值均在目标列数内。
 * @returns {{minPx:number, defaultPx:number, maxPx:number}} 最小宽度 / 默认宽度 / 每行5列的最大宽度（px）
 */
function computeCardWBounds() {
  const main = document.querySelector('main');
  const wallW = Math.max(200, (main ? main.clientWidth : 1280) - 28); // 减去 main 左右 padding 14*2
  const gap = 12;   // #wall grid gap
  const step = 5;   // 与滑杆 step 一致，min/max 必须为滑杆可达值
  const cardFor = (n) => Math.floor(((wallW + gap) / n - gap) / step) * step; // 指定列数的卡片宽度
  const maxPx = Math.max(cardFor(5), 110 + step);       // 每行 =5 列（动态，兜底保证大于最小）
  const minPx = Math.min(110, maxPx - step);            // 固定最小 110px
  const defaultPx = Math.min(Math.max(175, minPx), maxPx); // 固定默认 175px，钳制在有效区间
  return { minPx, defaultPx, maxPx };
}

/**
 * 应用滑杆范围并钳制当前值：窗口 resize 后重新计算，保证当前值始终落在有效区间内
 * @returns {void}
 */
function applyCardWBounds() {
  const { minPx, maxPx } = computeCardWBounds();
  const r = $('cardwRange');
  r.min = minPx;
  r.max = maxPx;
  let px = parseInt(r.value, 10);
  if (!Number.isFinite(px) || px < minPx) px = minPx;
  if (px > maxPx) px = maxPx;
  applyCardW(px);
}
// 默认值 = 固定 175px；仅当用户手动调整过（localStorage 有值）才沿用
const b = computeCardWBounds();
const savedCardW = parseInt(localStorage.getItem('farm_cardw') || String(b.defaultPx), 10);
applyCardW(savedCardW);
applyCardWBounds();
$('cardwRange').addEventListener('input', () => {
  const px = parseInt($('cardwRange').value, 10) || b.defaultPx;
  localStorage.setItem('farm_cardw', String(px));
  applyCardW(px);
});
// 窗口尺寸变化时重算范围并钳制当前值
window.addEventListener('resize', applyCardWBounds);

// ---------- init ----------
// 2026-08-19：手动「刷新」按钮已移除——设备列表实时性由 /ws/events 事件驱动（onmessage 重拉 +
// WS 断线重连 onopen 补拉全量），无手动刷新入口
// 展开态全宽操作条（进入批量模式后显示，2026-08-19）：
// 全选复选框：勾选=全选在线设备，取消勾选=取消全选
$('batchBarSelectAll').addEventListener('change', (e) => {
  if (e.target.checked) selectAll(); else deselectAll();
});
// 执行：点一次展开批量菜单，再点一次收起（2026-08-19 开合二态；收起仅移除菜单、不退批量模式）
$('batchBarExec').addEventListener('click', () => {
  const menu = document.getElementById('batchMenu');
  if (menu) closeBatchMenu(menu); else showBatchMenu();
});
// 设置：直接打开批量配置面板（候选仅限在线设备）
$('batchBarSettings').addEventListener('click', () => {
  const ids = Array.from(selectedDevices).filter((id) => {
    const d = devices.find((x) => x.id === id);
    return d && d.online && !d.mock;
  });
  if (ids.length === 0) { toast('没有可操作的在线设备', 'error'); return; }
  showBatchConfigPanel(ids);
});
// 取消：退出批量选择模式（由顶部「批量」按钮变「取消」态承担，见 #batchBtn 绑定；胶囊行已无取消按钮）
// 直控按钮：进入/退出直控模式（竞态二态，激活变色）
$('directBtn').addEventListener('click', (e) => {
  e.stopPropagation();
  toggleDirectMode();
});
// 顶部「批量」按钮（直控右侧）：平时点击进入多选模式（墙区顶部出现全宽胶囊条）；批量模式下变「取消」
// 激活态，点击退出多选模式（若执行菜单开着一并关闭）
$('batchBtn').addEventListener('click', (e) => {
  e.stopPropagation();
  if (batchMode) {
    const menu = document.getElementById('batchMenu');
    if (menu) finishBatch(menu); else exitBatchMode();
  } else {
    enterBatchMode();
  }
});
document.addEventListener('click', (e) => {
  if (!e.target.closest('#tileMenu')) $('tileMenu').classList.add('hidden');
});
// 操作按钮（桌面列 + 移动端悬浮簇共用）
document.querySelectorAll('#focusOps [data-op], #opsMenu [data-op]').forEach((b) => {
  b.addEventListener('click', () => doOp(b.dataset.op));
});
// 同步按钮：进入/退出同步选择模式（竞态二态）
$('btnSync').addEventListener('click', (e) => {
  e.stopPropagation();
  toggleSyncMode();
});

// 2026-08-14：控制台 UI 屏蔽浏览器原生右键菜单——PC 右键 / 长按卡片、按钮、操作菜单
// 不再弹出系统菜单；输入类元素（input/textarea/contenteditable）保留原生菜单（编辑/粘贴）。
// 触控端 iOS 长按系统菜单已由 style.css 的 -webkit-touch-callout:none 禁用。
document.addEventListener('contextmenu', (e) => {
  const t = e.target;
  if (t && (t.closest('input, textarea') || t.isContentEditable)) return;
  e.preventDefault();
});

initFab();
// 移动端悬浮菜单：展开/收起由 FAB 的 pointerup（未拖动=点击）处理；
// 退出控制统一走「断开」（disc → doOp → disconnect + exitFocus），无独立退出按钮
// 点击空白处收起悬浮菜单：用 pointerdown 而非 click —— noVNC canvas 的 gesturehandler
// 在 touchstart 里 preventDefault/stopPropagation，会阻止合成 click 冒泡，导致点画面关不掉菜单；
// pointerdown 先于 touch 事件派发且不受其 preventDefault 影响
document.addEventListener('pointerdown', (e) => {
  if (!e.target.closest('#opsMenu') && !e.target.closest('#fab')) {
    $('opsMenu').classList.add('hidden');
    cancelFabAutoCollapse();
  }
});
// 2026-08-17 点击菜单按键后延迟收起（展开时不再定时收起——点开必为按键；延时固定 1000ms）。
// pointerdown 先于按键自身的 press/click 处理派发，延迟到收起延时后不打断操作。
$('opsMenu').addEventListener('pointerdown', (e) => {
  if (e.target.closest && e.target.closest('button')) scheduleFabAutoCollapse();
});

// ===== 布局切换：宫格 / 列表 两档（PC 与移动端共用同一布局按钮，2026-08-19） =====
const layoutBtn = $('layoutBtn');
const layoutMenu = $('layoutMenu');
const layoutIcon = $('layoutIcon');
const wallEl = $('wall');
const zoomLabel = document.querySelector('.zoom'); // 卡片宽度调节阀（位于布局下拉菜单内宫格选项下方，宫格态显示）
// 布局状态持久化：'grid'（宫格：PC 多列自适应 + 调节阀 / 移动端双列）/ 'list'（单列列表行）
let layoutMode = localStorage.getItem('farm_layout') || 'grid';
// 布局切换图标：grid=四宫格 / list=三横线
const LAYOUT_ICONS = {
  grid: '<rect x="3" y="3" width="8" height="8" rx="1.5"/><rect x="13" y="3" width="8" height="8" rx="1.5"/><rect x="3" y="13" width="8" height="8" rx="1.5"/><rect x="13" y="13" width="8" height="8" rx="1.5"/>',
  list: '<line x1="4" y1="6" x2="20" y2="6"/><line x1="4" y1="12" x2="20" y2="12"/><line x1="4" y1="18" x2="20" y2="18"/>',
};

/**
 * 统计所有在线设备中数量最多的屏幕比例（宽高比，0.01 精度分组），
 * 返回该组平均比例对应的 padding-bottom 百分比（(h/w)*100）。
 * @returns {number|null} padding-bottom 百分比；无在线设备或均无屏幕信息时返回 null
 */
function majorityTilePb() {
  const groups = new Map(); // key=round(w/h*100)/100 -> { sum, n }
  for (const d of devices) {
    if (d.online !== true) continue; // 仅统计当前连接的设备
    const w = d.screen && d.screen.width;
    const h = d.screen && d.screen.height;
    if (!w || !h) continue;
    const r = w / h;
    const key = Math.round(r * 100) / 100;
    const g = groups.get(key) || { sum: 0, n: 0 };
    g.sum += r; g.n += 1;
    groups.set(key, g);
  }
  if (groups.size === 0) return null;
  let bestKey = null; let bestN = -1;
  for (const [key, g] of groups) {
    if (g.n > bestN) { bestN = g.n; bestKey = key; }
  }
  const g = groups.get(bestKey);
  return 100 / (g.sum / g.n); // padding-bottom % = (h/w)*100
}

/**
 * 应用卡片比例自适应：以多数设备的屏幕比例设置 --tile-pb。
 * 用户手动切换过横/竖屏（layoutManual）或墙不存在时跳过。
 * @returns {void}
 */
function applyAutoTileRatio() {
  if (layoutMode !== 'grid' || !wallEl) return; // 列表视图为固定行高，不参与卡片比例自适应
  const pb = majorityTilePb();
  if (pb != null) wallEl.style.setProperty('--tile-pb', pb.toFixed(4) + '%');
}

/**
 * 应用布局到设备墙：'grid'（宫格）/ 'list'（单列列表行）。
 * 宫格走 grid 平铺（PC auto-fill 多列 / 移动端 2 列）+ --tile-pb 比例自适应，并显示 PC 顶栏调节阀；
 * 列表为单列行式（固定行高，不参与比例自适应），隐藏调节阀。
 * @param {string} mode - 'grid' | 'list'
 * @returns {void}
 */
function applyLayout(mode) {
  layoutMode = mode;
  localStorage.setItem('farm_layout', mode);
  wallEl.classList.toggle('wall-grid', mode === 'grid');
  wallEl.classList.toggle('wall-list', mode === 'list');
  layoutIcon.innerHTML = LAYOUT_ICONS[mode] || LAYOUT_ICONS.grid;
  // 卡片宽度调节阀：仅宫格态显示（PC 顶栏；移动端本就由媒体查询隐藏，无影响）
  if (zoomLabel) zoomLabel.classList.toggle('hidden', mode !== 'grid');
  layoutMenu.querySelectorAll('.lopt').forEach((o) => {
    o.classList.toggle('sel', o.dataset.l === mode);
  });
}

// 初始化：读取上次布局（宫格/列表）；grid 下由多数设备比例自适应覆盖 --tile-pb
applyLayout(layoutMode);

layoutBtn.addEventListener('click', (e) => {
  e.stopPropagation();
  layoutMenu.classList.toggle('hidden');
});

layoutMenu.addEventListener('click', (e) => {
  const o = e.target.closest('.lopt');
  if (!o) return;
  applyLayout(o.dataset.l);
  layoutMenu.classList.add('hidden');
});

document.addEventListener('click', (e) => {
  if (!e.target.closest('#layoutMenu') && !e.target.closest('#layoutBtn')) {
    layoutMenu.classList.add('hidden');
  }
});

window.addEventListener('resize', fitFocusPanel);

(async () => {
  try {
    await refreshDevices();
    restoreFocusFromUrl(); // 2026-08-14：刷新后自动恢复当前操作的设备画面（URL ?focus=）
    connectEventsWS(); // 2026-08-18：设备变更推送订阅（2026-08-19 移除 6s 轮询，WS 心跳保活由后端负责）
  } catch (e) {
    if (e.message === 'unauthorized') showLogin();
  }
})();
