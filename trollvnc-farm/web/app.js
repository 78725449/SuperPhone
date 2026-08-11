// SuperPhone 群控台前端：设备墙(实时画面) -> 聚焦视图(左画面+右操作列) -> 移动端悬浮操作簇
import RFB from '/novnc/core/rfb.js';
import { deviceCaps, configSchemaByReload, invokeCap, setConfigs, RELOAD_LABELS, batchInvoke, batchSetConfigs, batchRestart, groupByCategory, CATEGORY_LABELS, KEY_DEFS, ACTION_CAPS, menuCaps } from './caps.js';
import { attachPress } from './press.js';

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
    <h3>SuperPhone 群控台</h3>
    <input id="loginToken" type="password" placeholder="访问令牌 (FARM_TOKEN)" />
    <button id="btnLogin" class="primary">进入</button>`;
  document.body.prepend(wrap);
  $('btnLogin').onclick = async () => {
    setToken($('loginToken').value.trim());
    wrap.remove();
    try { await refreshDevices(); } catch { showLogin(); }
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
      caps: [], configSchema: [], lastSeen: Date.now(),
    });
  }
  return arr;
}
const MOCK_COUNT = 30;  // 虚拟预览设备数量，置 0 即关闭预览
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
  // 注入虚拟预览设备（MOCK_COUNT=30 便于查看卡片墙布局与比例自适应；置 0 即关闭）
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
      toast(`直控模式：新增 ${added} 台设备推流`);
    }
  }
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
      <span class="tstate">${d.online ? '连接中…' : '离线'}</span>
      <button class="tmore" title="更多操作">⋯</button>
    </div>`;
  const tv = tile.querySelector('.tv');
  const statusEl = tile.querySelector('.tstate');
  const cb = tile.querySelector('.tile-checkbox');
  // 卡片墙画面获取：hash 门控 + 变化拉图（每 ThumbInterval 秒先取轻量 pHash，
  // 画面未变化不拉图；变化才 invoke screenshot 渲染新帧）。不建 RFB 持久连接。
  // rfb：截图轮询实例（字段名沿用历史），ThumbInterval 为 hash 检测间隔（默认 5 秒）。
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
  if (d.online) {
    tv.innerHTML = '<div class="offline-ph">连接中…</div>';
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
    if (directMode) return; // 直控模式：点击卡片直达 RFB 控制（canvas 输入事件由 noVNC 处理），不聚焦、无悬停提示
    if (syncMode) { toggleSync(d.id); return; } // 同步选择模式：点卡片切换同步（选中态=边框高亮+同步中）
    if (dev.online === false) {
      alert(`设备「${dev.name}」离线，请唤醒手机后重试`);
      return;
    }
    if (batchMode) exitBatchMode(); // 批量模式下点卡片聚焦：退出批量选择
    enterFocus(dev);
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
 * 启动卡片墙画面获取（hash 门控 + 变化拉图）
 * 功能：每 ThumbInterval 秒先调 screen.hash（0.3ms 级轻量 pHash，CPU<1%），
 *       与上次 hash 相同则画面未变化，不拉图（卡片保持缓存帧，静止时零图片流量）；
 *       仅当 hash 变化才调 screenshot 拉取新帧渲染。
 * 说明：v1.8.3 的定时全量截图轮询已升级为 hash 门控；卡片墙不建 RFB 持久连接。
 * 前提：所有安装本 IPA 的设备均注册 screen.hash/screenshot 能力（无旧版回退）。
 * 错误处理：hash/拉图失败均显式标记"获取失败"，不影响下一轮检测。
 * @param {object} inst 卡片墙实例 { device, tile, statusEl, rfb, paused }
 * @returns {void}
 */
function startWallRfb(inst) {
  if (!inst || inst.paused || inst.rfb) return;
  const tv = inst.tile.querySelector('.tv');
  if (!tv) return;
  // 虚拟预览设备：不建立真实拉流，直接渲染等比 SVG 占位画面
  if (inst.device.mock) {
    renderMockScreen(tv, inst.device);
    if (inst.statusEl) inst.statusEl.textContent = '预览';
    inst.rfb = { kind: 'mock', closed: false }; // 占位标记：避免 updateWallTile 每轮重复渲染
    return;
  }
  // 仅隧道设备（source=register）支持画面获取
  if (inst.device.source !== 'register') {
    tv.innerHTML = '<div class="offline-ph">未注册 · 请先配置网关</div>';
    if (inst.statusEl) inst.statusEl.textContent = '未注册';
    return;
  }
  tv.innerHTML = '<div class="offline-ph">加载中…</div>';
  // rfb 字段仅为兼容既有 stopWallRfb/updateWallTile 引用，实为截图轮询实例
  inst.rfb = { kind: 'screenshot', timer: null, closed: false, lastHash: null, silent: 0 };
  const tick = async () => {
    if (inst.paused || inst.rfb.closed) return;
    let changed = false;
    try {
      // 1) 轻量屏幕 hash：安装本 IPA 的设备均具备 screen.hash 能力，失败即显式报错，无回退
      const h = await invokeCap('', inst.device.id, 'screen.hash', {});
      const hash = ((h && h.ack) || {}).hash;
      if (!hash) throw new Error('screen.hash 未返回 hash');
      changed = (hash !== inst.rfb.lastHash);
      if (!changed) { inst.rfb.silent = (inst.rfb.silent || 0) + 1; return; } // 画面未变化，保持缓存帧
      inst.rfb.lastHash = hash;
      inst.rfb.silent = 0;
      // 2) 画面变化 → 拉取新帧
      const r = await invokeCap('', inst.device.id, 'screenshot', {});
      const ack = (r && r.ack) || {};
      const b64 = ack.image || ack.base64;
      if (b64) {
        tv.innerHTML = `<img class="thumb" src="data:image/jpeg;base64,${b64}" alt="" />`;
        if (inst.statusEl) inst.statusEl.textContent = '';
        if (inst.tile && ack.width && ack.height) {
          // 仅记录设备屏幕比例供聚焦面板使用；卡片墙统一 9:16（见 createWallTile）
          inst.tile.dataset.wh = ack.width + 'x' + ack.height;
        }
      }
    } catch (e) {
      if (inst.statusEl) inst.statusEl.textContent = '获取失败';
    } finally {
      if (!inst.paused && !inst.rfb.closed) {
        // 双速检测（与 IPA 控制端一致）：变化后快检 1s；静止按 1.5 倍退避至 15s 封顶
        const base = Number((inst.device.configs && inst.device.configs.ThumbInterval) || 5) || 5;
        let next;
        if (changed) next = 1;
        else next = Math.min(Math.max(base * Math.pow(1.5, (inst.rfb.silent || 0) - 1), base), 15);
        inst.rfb.timer = setTimeout(tick, Math.max(1, next) * 1000);
      }
    }
  };
  tick(); // hash 门控变化拉图：画面静止零图片流量（ThumbInterval 间隔 + 变化 1s 快检 / 静止 1.5 倍退避至 15s 封顶）
}

function stopWallRfb(inst) {
  if (!inst) return;
  if (inst.rfb) {
    if (inst.rfb.kind === 'screenshot') {
      inst.rfb.closed = true;
      if (inst.rfb.timer) clearTimeout(inst.rfb.timer);
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
 * 全选当前可见设备：将所有在线（含离线）的墙卡片对应的设备加入 selectedDevices
 * @returns {void}
 */
function selectAll() {
  for (const d of devices) selectedDevices.add(d.id);
  for (const [id, inst] of wallInstances) {
    if (inst.checkbox) {
      inst.checkbox.checked = true;
      inst.tile.classList.add('tile-selected');
    }
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
 * 更新批量操作按钮文案（竞态二态）：
 *   未进入批量模式 → "批量操作"；已进入且未勾选 → "取消"；已勾选 N 台 → "批量操作 (N)"
 * @returns {void}
 */
function updateBatchBar() {
  const btn = $('batchBtn');
  if (!btn) return;
  const n = selectedDevices.size;
  if (!batchMode) btn.textContent = '批量操作';
  else if (n > 0) btn.textContent = `批量操作 (${n})`;
  else btn.textContent = '取消';
  btn.classList.toggle('batch-mode-active', batchMode);
}

/**
 * 进入批量选择模式：所有卡片显示左上角复选框（CSS .batch-mode 驱动）
 * @returns {void}
 */
function enterBatchMode() {
  batchMode = true;
  const wall = $('wall');
  if (wall) wall.classList.add('batch-mode');
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
  selectedDevices.clear();
  for (const inst of wallInstances.values()) {
    if (inst.checkbox) inst.checkbox.checked = false;
    if (inst.tile) inst.tile.classList.remove('tile-selected');
  }
  updateBatchBar();
}

/**
 * 关闭批量菜单并退出批量模式（批量操作完成/取消时调用）
 * @param {HTMLElement} menu 批量菜单元素
 * @returns {void}
 */
function finishBatch(menu) {
  if (menu && menu.parentNode) menu.remove();
  exitBatchMode();
}

/**
 * 弹出批量操作菜单：勾选设备后点击"批量操作"按钮触发
 * 菜单包含三个分组：批量调用能力 / 批量调整配置 / 批量重启（需二次确认）
 * @returns {void}
 */
function showBatchMenu() {
  const ids = Array.from(selectedDevices);
  if (ids.length === 0) { alert('请先勾选至少一台设备'); return; }

  // 关闭已存在菜单
  const old = document.getElementById('batchMenu');
  if (old) old.remove();

  const menu = document.createElement('div');
  menu.id = 'batchMenu';
  menu.className = 'batch-menu';
  menu.innerHTML = `<div class="batch-menu-title">批量操作（${ids.length} 台）</div>`;

  // 1) 全选/取消全选
  const selectRow = document.createElement('div');
  selectRow.className = 'batch-menu-row';
  const selAll = document.createElement('button');
  selAll.textContent = '全选';
  const deselAll = document.createElement('button');
  deselAll.textContent = '取消全选';
  selAll.addEventListener('click', () => { selectAll(); menu.remove(); });
  deselAll.addEventListener('click', () => { deselectAll(); menu.remove(); });
  selectRow.appendChild(selAll);
  selectRow.appendChild(deselAll);
  menu.appendChild(selectRow);

  // 2) 批量调用能力（取所有选中设备能力元数据的并集，按 category 分组渲染）
  const capList = document.createElement('div');
  capList.className = 'batch-menu-section';
  capList.innerHTML = '<div class="batch-menu-sec-title">批量调用能力</div>';
  // 合并选中设备的能力清单（用 id 去重）
  const capMap = new Map();
  for (const id of ids) {
    const inst = wallInstances.get(id);
    const dev = inst ? inst.device : devices.find((d) => d.id === id);
    if (!dev) continue;
    for (const meta of deviceCaps(dev)) {
      if (meta && meta.id && !capMap.has(meta.id)) capMap.set(meta.id, meta);
    }
  }
  // 按 category 分组
  const grouped = groupByCategory(Array.from(capMap.values()));
  for (const [cat, metas] of grouped) {
    const grpTitle = document.createElement('div');
    grpTitle.className = 'cap-group-title';
    grpTitle.textContent = CATEGORY_LABELS[cat] || cat || '其它';
    capList.appendChild(grpTitle);
    for (const meta of metas) {
      const b = document.createElement('button');
      b.className = 'batch-cap-btn';
      b.innerHTML = '<span class="cap-icon">' + escapeHtml(meta.icon || '?') + '</span><span class="cap-name">' + escapeHtml(meta.title || meta.id) + '</span>';
      b.addEventListener('click', () => doBatchInvoke(ids, meta));
      capList.appendChild(b);
    }
  }
  menu.appendChild(capList);

  // 3) 批量调整配置（从选中设备 configSchema 并集渲染表单）
  const cfgBtn = document.createElement('button');
  cfgBtn.className = 'batch-menu-row-item';
  cfgBtn.innerHTML = '<span class="cap-icon">⚙</span><span class="cap-name">批量调整配置</span>';
  cfgBtn.addEventListener('click', () => { finishBatch(menu); showBatchConfigPanel(ids); });
  menu.appendChild(cfgBtn);

  // 4) 批量重启（危险操作，需二次确认）
  const restartBtn = document.createElement('button');
  restartBtn.className = 'batch-menu-row-item danger';
  restartBtn.innerHTML = '<span class="cap-icon">🔄</span><span class="cap-name">批量重启</span>';
  restartBtn.addEventListener('click', async () => {
    if (!confirm(`确认批量重启选中的 ${ids.length} 台设备？`)) return;
    finishBatch(menu);
    try {
      const r = await batchRestart('', ids);
      const fails = (r.results || []).filter((x) => !x.ok);
      if (fails.length === 0) alert(`已对 ${ids.length} 台设备下发重启`);
      else alert(`部分设备重启失败：\n${fails.map((x) => `${x.deviceId}: ${x.error || ''}`).join('\n')}`);
    } catch (e) {
      alert(`批量重启失败：${e.message}`);
    }
  });
  menu.appendChild(restartBtn);

  // 关闭按钮
  const closeBtn = document.createElement('button');
  closeBtn.className = 'batch-menu-close';
  closeBtn.textContent = '取消';
  closeBtn.addEventListener('click', () => finishBatch(menu));
  menu.appendChild(closeBtn);

  document.body.appendChild(menu);
  // 点击外部关闭并退出批量模式
  setTimeout(() => {
    const handler = (e) => {
      if (!e.target.closest('#batchMenu') && !e.target.closest('#batchBtn')) {
        finishBatch(menu);
        document.removeEventListener('click', handler);
      }
    };
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
    params = await promptParams(meta.params);
    if (params === null) return;
  }
  try {
    const r = await batchInvoke('', ids, meta.id, params);
    const fails = (r.results || []).filter((x) => !x.ok);
    if (fails.length === 0) alert(`已对 ${ids.length} 台设备下发「${meta.title || meta.id}」`);
    else alert(`部分设备执行失败：\n${fails.map((x) => `${x.deviceId}: ${x.error || ''}`).join('\n')}`);
  } catch (e) {
    alert(`批量调用「${meta.title || meta.id}」失败：${e.message}`);
  }
}

/**
 * 弹出批量配置面板：从选中设备 configSchema 取并集，渲染表单，保存后调用 batchSetConfigs
 * @param {string[]} ids 设备 ID 数组
 * @returns {Promise<void>}
 */
async function showBatchConfigPanel(ids) {
  // 合并选中设备的 configSchema（按 key 去重，取首个 schema 定义）
  const schemaMap = new Map();
  for (const id of ids) {
    const inst = wallInstances.get(id);
    const dev = inst ? inst.device : devices.find((d) => d.id === id);
    if (!dev || !Array.isArray(dev.configSchema)) continue;
    for (const s of dev.configSchema) {
      if (s && s.key && !schemaMap.has(s.key)) schemaMap.set(s.key, s);
    }
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
    const sec = document.createElement('div');
    sec.className = 'cfg-section';
    const inputs = {};
    for (const schema of schemaMap.values()) {
      const row = document.createElement('label');
      row.className = 'cfg-row';
      row.textContent = schema.title || schema.key;
      const inp = buildConfigInput(schema, undefined);
      inputs[schema.key] = inp;
      row.appendChild(inp);
      sec.appendChild(row);
    }
    card.appendChild(sec);

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
        if (fails.length === 0) {
          modal.remove();
          alert(`已对 ${ids.length} 台设备下发配置`);
        } else {
          alert(`部分设备配置失败：\n${fails.map((x) => x.deviceId).join('\n')}`);
        }
      } catch (e) {
        alert(`批量保存失败：${e.message}`);
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

// ---------- 控制台操作菜单（07 §4.1：按键区 KEY_DEFS + 动作区 ACTION_CAPS） ----------
// 适配/全屏/断开为控制台本地操作，不在能力清单内，由静态按钮提供
/**
 * 渲染控制台操作菜单（07 §4.1）：按键区（KEY_DEFS 按键对象+按压识别）+ 动作区（ACTION_CAPS）
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
  const caps = menuCaps(device, 'console');
  const byId = new Map(caps.map((c) => [c.id, c]));

  // 按键区：分组标题 + 按键对象按钮（按压识别，07 §3.2）
  // 按键按钮先构建进临时数组，存在按键才追加分组标题，避免渲染孤立空标题
  const keyTitle = document.createElement('div');
  keyTitle.className = 'cap-group-title';
  keyTitle.textContent = '按键';
  const keyBtns = [];
  for (const k of KEY_DEFS) {
    const meta = byId.get(k.events.click) || byId.get(k.events.down);
    if (!meta) continue; // 设备不支持该按键能力则跳过
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'op key-op';
    b.title = k.title;
    b.innerHTML = '<span class="cap-icon">' + escapeHtml(k.icon || meta.icon || '?') + '</span><span class="cap-name">' + escapeHtml(k.title) + '</span>';
    container.__pressCleanups.push(attachPress(b, k, { invoke: (capId) => {
      const m = byId.get(capId) || { id: capId, title: capId, params: [] };
      doInvoke(m);
    } }));
    keyBtns.push(b);
  }
  if (keyBtns.length > 0) {
    frag.appendChild(keyTitle);
    keyBtns.forEach((b) => frag.appendChild(b));
  }

  // 动作区：ACTION_CAPS 单击直执行
  const actMeta = ACTION_CAPS.map((id) => byId.get(id)).filter(Boolean);
  if (actMeta.length > 0) {
    const actTitle = document.createElement('div');
    actTitle.className = 'cap-group-title';
    actTitle.textContent = '动作';
    frag.appendChild(actTitle);
    for (const meta of actMeta) {
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'op';
      b.dataset.cap = meta.id; b.title = meta.title;
      b.innerHTML = '<span class="cap-icon">' + escapeHtml(meta.icon || '?') + '</span><span class="cap-name">' + escapeHtml(meta.title || meta.id) + '</span>';
      b.addEventListener('click', () => doInvoke(meta));
      frag.appendChild(b);
    }
  }
  container.appendChild(frag);
}

/**
 * 显示轻量 toast 提示（右上角短暂浮现，自动消失）
 * @param {string} msg 提示文案
 * @returns {void}
 */
let farmToastTimer = null;
function toast(msg) {
  let el = document.getElementById('farmToast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'farmToast';
    el.style.cssText = 'position:fixed;top:14px;right:14px;z-index:999;background:rgba(20,26,40,.92);color:#fff;padding:10px 14px;border-radius:10px;font:13px/1.4 system-ui,sans-serif;box-shadow:0 6px 20px rgba(0,0,0,.4);max-width:70vw;pointer-events:none;transition:opacity .25s;';
    document.body.appendChild(el);
  }
  el.textContent = msg;
  el.style.opacity = '1';
  if (farmToastTimer) clearTimeout(farmToastTimer);
  farmToastTimer = setTimeout(() => { el.style.opacity = '0'; }, 2000);
}

/**
 * 调用设备能力（通过网关 invoke API，Phase 4.7）
 * 无参能力直接调用；有参能力弹出参数输入；成功/失败均有 toast 反馈
 */
async function doInvoke(meta) {
  if (!focus || !focus.device) return;
  const devId = focus.device.id;
  // 有参数的能力：弹出简易表单
  let params = {};
  if (Array.isArray(meta.params) && meta.params.length > 0) {
    params = await promptParams(meta.params);
    if (params === null) return; // 用户取消
  }
  try {
    const r = await invokeCap('', devId, meta.id, params);
    if (r && r.ok) toast(`✓ 已执行：${meta.title}`);
    else toast(`✗ 能力「${meta.title}」执行失败：${r?.ack?.error || '未知错误'}`);
  } catch (e) {
    toast(`✗ 能力「${meta.title}」调用失败：${e.message}`);
  }
}

/**
 * 弹出参数输入表单（简化版，支持 number/string）
 * @param paramDefs 参数定义数组
 * @returns 参数对象，取消返回 null
 */
function promptParams(paramDefs) {
  return new Promise((resolve) => {
    const modal = document.createElement('div');
    modal.className = 'modal';
    const card = document.createElement('div');
    card.className = 'modal-card';
    const inputs = {};
    for (const p of paramDefs) {
      const lbl = document.createElement('label');
      lbl.textContent = `${p.name}${p.required ? ' *' : ''} (${p.type})`;
      const inp = document.createElement('input');
      if (p.default !== undefined) inp.value = p.default;
      inputs[p.name] = inp;
      lbl.appendChild(inp);
      card.appendChild(lbl);
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

// ---------- 聚焦视图 ----------
function enterFocus(d) {
  if (focus && focus.device.id === d.id) return;
  if (focus) exitFocus();
  if (d.online === false) { alert(`设备「${d.name}」离线，请唤醒手机后重试`); return; }
  // 只走隧道：未注册设备不可控制
  if (d.source !== 'register') { alert('设备未注册（无隧道），请先在手机 App 配置网关完成注册'); return; }

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
  $('focusPanel').classList.remove('hidden');
  $('focusOps').classList.remove('hidden');
  $('workspace').classList.add('focus-open');
  renderCapOps($('focusOpsCap'), d);
  renderCapOps($('opsMenuCap'), d);
  if (window.matchMedia('(max-width: 900px)').matches) $('fab').classList.remove('hidden');
  // 主控连接始终携带 grp+broadcast（广播到同 session 的同步/群控订阅设备）。
  // 保证勾选同步设备时无需重建主控连接 → 主控画面不跳动、不改变。
  const grp = wallSession;
  const broadcast = '1';
  // 先初始化 focus 再挂载元数据，避免在 null 上赋值抛错（修复点击卡片黑屏）
  focus = { device: d, rfb: null };
  focus.capMetadata = deviceCaps(d);
  focus.configSchema = d.configSchema || [];
  focus.rfb = createRfb(stage, d, { grp, broadcast, ctrl: true }, $('focusStatusDot'));
  focus.rfb.addEventListener('connect', () => setTimeout(fitFocusPanel, 300));
  setTimeout(fitFocusPanel, 400);
  startFabSignalPoll(); // 移动端悬浮按钮延迟信号轮询（仅在 focus 建立后）
}

function exitFocus() {
  if (!focus) return;
  const devId = focus.device.id;
  closeRfb(focus.rfb);
  stopFabSignalPoll();
  focus = null;
  exitSyncMode(); // 关闭同步订阅与选择模式
  $('focusPanel').classList.add('hidden');
  $('focusOps').classList.add('hidden');
  $('workspace').classList.remove('focus-open');
  $('opsMenu').classList.add('hidden');
  $('fab').classList.add('hidden');
  restoreWallTile(devId);
}

function restoreWallTile(id) {
  const inst = wallInstances.get(id);
  if (!inst || !inst.paused) return;
  inst.paused = false;
  inst.tile.classList.remove('focused-tile');
  // 退出 focus：恢复卡片墙 RFB 连接（Phase 12.1，v2.3 恢复）
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
 * 退出同步选择模式：关闭全部同步 RFB（恢复卡片墙截图轮询）、清空选中态与"同步中"徽标。
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
  // 关闭全部同步 RFB 订阅并置空，随后恢复卡片墙截图轮询
  for (const id of syncRfbs.keys()) {
    const inst = wallInstances.get(id);
    if (inst) stopWallRfb(inst);
  }
  syncRfbs.clear();
  updateSyncBtn();
  // 恢复截图轮询：仅在线且未暂停（主控自身）的卡片
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
    // 取消同步：关闭 RFB 订阅并置空，移除选中态，恢复卡片墙截图轮询
    stopWallRfb(inst);
    syncRfbs.delete(deviceId);
    setSyncBadge(inst, false);
    if (inst.checkbox) inst.checkbox.checked = false;
    inst.tile.classList.remove('tile-selected');
    startWallRfb(inst);
  } else {
    // 勾选同步：停截图轮询，建立 grp viewOnly RFB 渲染卡片（实时画面 + 接收广播输入）
    stopWallRfb(inst);
    const tv = inst.tile.querySelector('.tv');
    const rfb = createRfb(tv, dev, { grp: wallSession, viewOnly: true });
    rfb.addEventListener('disconnect', () => {
      // 连接异常断开（设备离线等）：清理同步标记，移除选中态，恢复截图轮询
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
 * 更新同步按钮状态（竞态二态）：图标恒为 🔗；进入同步选择模式后按钮变红，
 * 再次点击断开并恢复原色。
 * @returns {void}
 */
function updateSyncBtn() {
  const btn = $('btnSync');
  if (!btn) return;
  const n = syncRfbs.size;
  const active = syncMode;
  btn.textContent = '🔗';
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
  const exist = directRfbs.get(d.id);
  if (exist) return exist;
  stopWallRfb(inst); // 停截图轮询
  const tv = inst.tile.querySelector('.tv');
  const rfb = createRfb(tv, d, { ctrl: false }); // 非 ctrl 可输入连接：互不抢占、输入直达设备
  rfb.addEventListener('disconnect', (e) => {
    // 设备离线/隧道断/服务端断开：清理直控标记，恢复截图轮询
    if (directRfbs.get(d.id) === rfb) {
      directRfbs.delete(d.id);
      startWallRfb(inst);
      updateDirectBtn();
      if (directMode) {
        const code = e && e.detail && e.detail.code;
        toast(`设备「${d.name}」直控已断开` + (code ? `（${code}）` : ''));
      }
    }
  });
  directRfbs.set(d.id, rfb);
  return rfb;
}

/**
 * 切换直控模式（竞态二态）：进入 = 所有在线真实设备建立可输入 RFB 推流到卡片；
 * 退出 = 关闭全部直控 RFB，恢复截图轮询（变化帧采样）。
 * @returns {void}
 */
function toggleDirectMode() {
  if (directMode) { exitDirectMode(); return; }
  directMode = true;
  const wall = $('wall');
  if (wall) wall.classList.add('direct-mode');
  let n = 0;
  for (const d of devices) {
    if (!d.online || d.mock || d.source !== 'register') continue; // 仅在线真实隧道设备
    if (startDirectRfb(d)) n++;
  }
  updateDirectBtn();
  if (n > 0) toast(`直控模式：${n} 台设备已开启推流，点击卡片直接控制`);
  else toast('直控模式：当前无在线真实设备');
}

/**
 * 退出直控模式：关闭全部直控 RFB，恢复截图轮询（变化帧采样），按钮恢复原色。
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
    closeRfb(rfb);
    const inst = wallInstances.get(id);
    if (inst) stopWallRfb(inst);
  }
  directRfbs.clear();
  updateDirectBtn();
  for (const inst of wallInstances.values()) {
    if (inst.device.online === true && !inst.paused) startWallRfb(inst); // 恢复变化帧采样
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
  tile.querySelector('.tname').textContent = d.name;
  tile.querySelector('.dot').className = 'dot ' + (d.online ? 'on' : 'off');
  const tv = tile.querySelector('.tv');
  if (d.online) {
    if (inst.paused) return; // 聚焦中，保持隐藏
    tile.classList.remove('tile-offline');
    // 直控模式：该设备已有直控 RFB（实时推流 canvas）。设备信息轮询刷新
    // 绝不能覆盖直控画面或恢复截图轮询，否则“操作两下后直控失效”（canvas 被替换）。
    if (directMode && directRfbs.has(d.id)) return;
    if (!inst.rfb) { // RFB 未连接，启动它（Phase 12.1，v2.3 恢复）
      tv.innerHTML = '<div class="offline-ph">连接中…</div>';
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
    // 移动端全屏：stage 必须撑满 focusScreen（noVNC scaleViewport 以此为适配基准，
    // 否则容器高度 0 → 画面被缩放到 0 → 黑屏）。CSS 兜底 100%，此处显式再设一次。
    stage.style.width = '100%';
    stage.style.height = '100%';
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
  stage.style.width = '100%';
  stage.style.height = availH + 'px';
}

// ---------- 本地操作（适配/全屏/断开，控制台本地能力，不通过设备 API） ----------
function currentRfb() { return focus ? focus.rfb : null; }

/**
 * 本地操作：适配画面/全屏/断开
 * 控制型能力（Home/电源/音量等）已改走 doInvoke → 网关 invoke API
 */
function doOp(op) {
  const rfb = currentRfb();
  if (!rfb && op !== 'disc') return;
  switch (op) {
    case 'fit': rfb.scaleViewport = true; break;
    case 'full':
      if (document.fullscreenElement) document.exitFullscreen();
      else document.documentElement.requestFullscreen().catch(() => {});
      break;
    case 'disc': try { rfb.disconnect(); } catch (e) {} exitFocus(); break;
  }
}

// ---------- 配置面板（二级菜单，按 reload 分区显示，Phase 4.7） ----------

/**
 * 显示设备配置面板：拉取当前配置值 + 按 schema 渲染表单 + 按 reload 分区
 * @param {object} [device] 目标设备对象；缺省时回退到全局 focus 设备（控制台场景）
 */
async function showConfigPanel(device) {
  const dev = device || (focus && focus.device);
  if (!dev) return;
  const modal = document.createElement('div');
  modal.className = 'modal';
  const card = document.createElement('div');
  card.className = 'modal-card';
  card.innerHTML = `<h3>${escapeHtml(dev.name)} - 设备配置</h3>`;

  // 拉取当前配置值
  let configs = {};
  try {
    const resp = await fetch(`/api/devices/${encodeURIComponent(dev.id)}/configs`, {
      headers: window._farmAuthHeader || {},
    });
    if (resp.ok) configs = (await resp.json()).configs || {};
  } catch (e) { /* ignore */ }

  // 按 reload 分区渲染表单
  const groups = configSchemaByReload({ configSchema: dev.configSchema || [] });
  const inputs = {};
  for (const [reload, items] of Object.entries(groups)) {
    if (items.length === 0) continue;
    const sec = document.createElement('div');
    sec.className = 'cfg-section';
    sec.innerHTML = `<div class="cfg-sec-title">${RELOAD_LABELS[reload] || reload}</div>`;
    for (const schema of items) {
      const val = configs[schema.key];
      const row = document.createElement('label');
      row.className = 'cfg-row';
      row.textContent = schema.title || schema.key;
      const inp = buildConfigInput(schema, val);
      inputs[schema.key] = inp;
      row.appendChild(inp);
      sec.appendChild(row);
    }
    card.appendChild(sec);
  }

  // 保存按钮
  const btns = document.createElement('div');
  btns.className = 'modal-btns';
  const cancel = document.createElement('button');
  cancel.textContent = '取消';
  const save = document.createElement('button');
  save.className = 'primary'; save.textContent = '保存';
  btns.appendChild(cancel); btns.appendChild(save);
  card.appendChild(btns);
  modal.appendChild(card);
  document.body.appendChild(modal);

  cancel.onclick = () => modal.remove();
  save.onclick = async () => {
    const cfg = {};
    for (const [key, inp] of Object.entries(inputs)) {
      cfg[key] = readConfigValue(inp);
    }
    try {
      const r = await setConfigs('', dev.id, cfg);
      const fails = Object.entries(r.results || {}).filter(([, v]) => !v.ok);
      if (fails.length === 0) {
        modal.remove();
        alert('配置已保存');
      } else {
        const msg = fails.map(([k, v]) => `${k}: ${v.error || v.reload}`).join('\n');
        alert(`部分配置失败：\n${msg}`);
      }
    } catch (e) {
      alert(`保存失败：${e.message}`);
    }
  };
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
  rfb.showDotCursor = true;
  if (opts.viewOnly) rfb.viewOnly = true;   // 墙缩略图只读：点击卡片=切入大屏控制，不直接操控
  // 状态用红/蓝圆点表示（蓝=已连接，红=已断开/失败），不再显示文字
  const setStatus = (s) => {
    if (!statusEl) return;
    statusEl.classList.toggle('on', s === '已连接');
    statusEl.classList.toggle('off', s !== '已连接');
  };
  rfb.addEventListener('connect', () => {
    setStatus('已连接');
  });
  rfb.addEventListener('disconnect', (e) => {
    setStatus('已断开');
    const code = e && e.detail && e.detail.code;
    if (code === 4001) alert('设备已被其它端接管，已中断控制');
    else if (code === 4003) alert('设备隧道未建立（可能刚注册或正在重连），请稍候重试');
  });
  rfb.addEventListener('credentialsrequired', () => {
    const p = prompt(`请输入 ${device.name} 的 VNC 密码：`);
    if (p) rfb.sendCredentials({ password: p });
  });
  return rfb;
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
  } catch (e) { /* ignore */ }
}

// ---------- 设备管理 ----------
function openAdd() {
  $('addTitle').textContent = '添加设备';
  ['fName', 'fHost', 'fGroup', 'fNote'].forEach((i) => ($(i).value = ''));
  $('fPort').value = 5901;
  $('addModal').classList.remove('hidden');
  $('btnSaveDevice').onclick = async () => {
    await api('/api/devices', {
      method: 'POST',
      body: JSON.stringify({
        name: $('fName').value, host: $('fHost').value,
        port: Number($('fPort').value), group: $('fGroup').value, note: $('fNote').value,
      }),
    });
    $('addModal').classList.add('hidden');
    await refreshDevices();
  };
}
function openEdit(d) {
  $('addTitle').textContent = '编辑设备';
  $('fName').value = d.name || '';
  $('fHost').value = d.host || '';
  $('fPort').value = d.port || 5901;
  $('fGroup').value = d.group || '';
  $('fNote').value = d.note || '';
  $('addModal').classList.remove('hidden');
  $('btnSaveDevice').onclick = async () => {
    await api(`/api/devices/${encodeURIComponent(d.id)}`, {
      method: 'PATCH',
      body: JSON.stringify({
        name: $('fName').value, host: $('fHost').value, port: Number($('fPort').value),
        group: $('fGroup').value, note: $('fNote').value,
      }),
    });
    $('addModal').classList.add('hidden');
    await refreshDevices();
  };
}
// 设备详情（能力清单只读：能力/配置/屏幕/httpPort/上次在线）
function openDetail(d) {
  // deviceCaps 返回元数据对象数组，取 title（无则 id）作为展示名
  const caps = deviceCaps(d).map((c) => (c && (c.title || c.id)) || '?').join('、') || '—';
  const cfg = (d.configs && typeof d.configs === 'object') ? d.configs : {};
  const cfgRows = Object.entries(cfg).map(([k, v]) => '<tr><td>' + escapeHtml(k) + '</td><td>' + escapeHtml(String(v)) + '</td></tr>').join('') || '<tr><td colspan="2">未上报</td></tr>';
  $('detailTitle').textContent = d.name || d.id;
  $('detailBody').innerHTML = [
    '<div class="drow"><span>设备 ID</span><code>' + escapeHtml(d.id) + '</code></div>',
    '<div class="drow"><span>地址</span><span>' + escapeHtml(d.host) + ':' + escapeHtml(String(d.port)) + '</span></div>',
    '<div class="drow"><span>来源</span><span>' + escapeHtml(d.source || '—') + '</span></div>',
    '<div class="drow"><span>状态</span><span class="' + (d.online ? 'ok' : 'bad') + '">' + (d.online ? '在线' : '离线') + '</span></div>',
    '<div class="drow"><span>上次在线</span><span>' + (d.lastSeen ? fmtTime(d.lastSeen) : '—') + '</span></div>',
    (d.screen && d.screen.width && d.screen.height) ? '<div class="drow"><span>屏幕</span><span>' + d.screen.width + '×' + d.screen.height + '</span></div>' : '',
    d.httpPort ? '<div class="drow"><span>HTTP 端口</span><span>' + d.httpPort + '（http://' + escapeHtml(d.host) + ':' + d.httpPort + '）</span></div>' : '',
    '<div class="drow"><span>操作能力</span><span>' + escapeHtml(caps) + '</span></div>',
    '<div class="dsec">配置上报（只读）</div>',
    '<table class="dcfg"><tbody>' + cfgRows + '</tbody></table>',
  ].join('');
  $('detailModal').classList.remove('hidden');
}

/**
 * 显示卡片右下角⋯菜单（Phase 10.3：按 category 分组，能力+管理操作合并）
 * 菜单分两段：上半段为设备能力（menuCaps('tile') 按 category 分组渲染，点击调用 doInvoke）；
 * 下半段为管理操作（查看/控制、详情、编辑、测试在线、⚙ 设备配置、删除）。
 * @param {HTMLElement} tile 卡片元素（用于定位菜单）
 * @param {object} d 设备对象
 * @param {number} x 点击位置 clientX
 * @param {number} y 点击位置 clientY
 * @returns {void}
 */
function showTileMenu(tile, d, x, y) {
  const m = $('tileMenu');
  m.innerHTML = '';

  // 1) 能力分组（menuCaps('tile') 排除 internal 原语，Phase 1 任务 6）
  const grouped = groupByCategory(menuCaps(d, 'tile'));
  let groupIdx = 0;
  for (const [cat, metas] of grouped) {
    if (groupIdx > 0) {
      const divider = document.createElement('hr');
      divider.className = 'cap-group-divider';
      m.appendChild(divider);
    }
    groupIdx++;
    const title = document.createElement('div');
    title.className = 'cap-group-title';
    title.textContent = CATEGORY_LABELS[cat] || cat || '其它';
    m.appendChild(title);
    for (const meta of metas) {
      const b = document.createElement('button');
      b.dataset.cap = meta.id;
      b.innerHTML = '<span class="cap-icon">' + escapeHtml(meta.icon || '?') + '</span><span class="cap-name">' + escapeHtml(meta.title || meta.id) + '</span>';
      b.addEventListener('click', () => {
        m.classList.add('hidden');
        doInvoke(meta);
      });
      m.appendChild(b);
    }
  }

  // 2) 管理操作（分段分隔线 + 纵向列表）
  const mgmtDivider = document.createElement('hr');
  mgmtDivider.className = 'cap-group-divider';
  m.appendChild(mgmtDivider);
  const mgmtTitle = document.createElement('div');
  mgmtTitle.className = 'cap-group-title';
  mgmtTitle.textContent = '设备管理';
  m.appendChild(mgmtTitle);
  for (const [a, label] of [
    ['view', '查看/控制'],
    ['detail', '详情'],
    ['edit', '编辑'],
    ['ping', '测试在线'],
    ['config', '⚙ 设备配置'],
    ['del', '删除'],
  ]) {
    const b = document.createElement('button');
    b.dataset.a = a;
    b.textContent = label;
    m.appendChild(b);
  }

  m.classList.remove('hidden');
  const rect = tile.getBoundingClientRect();
  m.style.left = Math.min(x, window.innerWidth - 140) + 'px';
  m.style.top = Math.min(y, window.innerHeight - 160) + 'px';
  m.onclick = async (e) => {
    const a = e.target.dataset.a;
    if (!a) return;
    m.classList.add('hidden');
    if (a === 'view') enterFocus(d);
    else if (a === 'detail') openDetail(d);
    else if (a === 'edit') openEdit(d);
    else if (a === 'ping') {
      try {
        const r = await api(`/api/devices/${encodeURIComponent(d.id)}/ping`, { method: 'POST' });
        alert(`${d.name}: ${r.online ? '在线' : '离线'}`);
        await refreshDevices();
      } catch (err) { alert('测试失败: ' + err.message); }
    } else if (a === 'config') showConfigPanel(d);
    else if (a === 'del') {
      if (confirm(`删除设备 ${d.name}？`)) {
        await api(`/api/devices/${encodeURIComponent(d.id)}`, { method: 'DELETE' });
        const inst = wallInstances.get(d.id);
        if (inst) { stopWallRfb(inst); inst.tile.remove(); wallInstances.delete(d.id); }
        await refreshDevices();
      }
    }
  };
}

// ---------- 移动端悬浮信号按钮（圆形可拖动 + 点击展开操作菜单 + 延迟信号状态） ----------

/**
 * 将悬浮操作菜单定位到 FAB 附近且避开按钮区域。
 * 优先放在 FAB 下方，空间不足则上方；按可用空间裁剪 max-height，
 * 保证菜单任何情况下都不覆盖悬浮按钮（修复"点穿"到菜单项的问题）。
 * 菜单必须已可见（调用前 remove hidden）以便测量真实尺寸。
 * @returns {void}
 */
function positionOpsMenu() {
  const menu = $('opsMenu'), fab = $('fab');
  if (!menu || !fab) return;
  const fr = fab.getBoundingClientRect();
  const vw = window.innerWidth, vh = window.innerHeight;
  const pad = 8, gap = 10;
  const mw = menu.offsetWidth || 200;
  const rawH = menu.offsetHeight || 300;
  const below = vh - fr.bottom - gap - pad;   // FAB 下方可用空间
  const above = fr.top - gap - pad;           // FAB 上方可用空间
  const placeBelow = below >= 120 && below >= above;
  const maxH = Math.max(80, Math.min(rawH, placeBelow ? below : above));
  menu.style.maxHeight = maxH + 'px';
  const mh = Math.min(rawH, maxH);
  let top = placeBelow ? fr.bottom + gap : fr.top - gap - mh;
  if (top < pad) top = pad;
  if (top + mh > vh - pad) top = Math.max(pad, vh - mh - pad);
  let left = fr.right - mw;                   // 与 FAB 右对齐，越界左移
  if (left < pad) left = pad;
  if (left + mw > vw - pad) left = vw - mw - pad;
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
    if (willOpen) positionOpsMenu();           // 展开后立即定位（避开 FAB 区域）
  };
  fab.addEventListener('pointerup', endDrag);
  fab.addEventListener('pointercancel', () => { dragging = false; });
  // 窗口尺寸/方向变化时，若菜单已展开则重新定位，避免旋转后覆盖按钮或越界
  window.addEventListener('resize', () => {
    const menu = $('opsMenu');
    if (menu && !menu.classList.contains('hidden')) positionOpsMenu();
  });
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
// 默认值 = 每行 10 列对应的 px；仅当用户手动调整过（localStorage 有值）才沿用
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
$('btnRefresh').onclick = () => refreshDevices().catch(() => showLogin());
$('btnAdd').onclick = openAdd;
// 直控按钮：进入/退出直控模式（竞态二态，激活变色）
$('directBtn').addEventListener('click', (e) => {
  e.stopPropagation();
  toggleDirectMode();
});
// 批量操作按钮：未进入批量模式 → 进入（卡片出现复选框）；已进入且无勾选 → 退出；已勾选 → 弹出批量菜单
$('batchBtn').addEventListener('click', (e) => {
  e.stopPropagation();
  if (!batchMode) { enterBatchMode(); return; }
  if (selectedDevices.size === 0) { exitBatchMode(); return; }
  showBatchMenu();
});
$('btnBack').onclick = exitFocus;
$('btnCancelAdd').onclick = () => $('addModal').classList.add('hidden');
$('btnDetailClose').onclick = () => $('detailModal').classList.add('hidden');
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

initFab();
// 移动端悬浮菜单：展开/收起由 FAB 的 pointerup（未拖动=点击）处理；退出按钮独立绑定
$('opsExit').addEventListener('click', () => {
  $('opsMenu').classList.add('hidden');
  exitFocus();
});
// 点击空白处收起悬浮菜单：用 pointerdown 而非 click —— noVNC canvas 的 gesturehandler
// 在 touchstart 里 preventDefault/stopPropagation，会阻止合成 click 冒泡，导致点画面关不掉菜单；
// pointerdown 先于 touch 事件派发且不受其 preventDefault 影响
document.addEventListener('pointerdown', (e) => {
  if (!e.target.closest('#opsMenu') && !e.target.closest('#fab')) {
    $('opsMenu').classList.add('hidden');
  }
});

// ===== 布局切换：卡片（宫格）/ 列表 两档（借鉴 IPA 控制端布局按钮，PC 端隐藏、移动端主用） =====
const layoutBtn = $('layoutBtn');
const layoutMenu = $('layoutMenu');
const layoutIcon = $('layoutIcon');
const wallEl = $('wall');
// 布局状态持久化：'grid'（卡片宫格，比例自适应）/ 'list'（单列列表行）；PC 端恒为卡片宫格（布局按钮仅移动端可见）
let layoutMode = 'grid';
if (window.matchMedia('(max-width: 900px)').matches) {
  layoutMode = localStorage.getItem('farm_layout') || 'grid';
}
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
 * 应用布局到设备墙：'grid'（卡片宫格）/ 'list'（单列列表行）。
 * 卡片视图走 grid 平铺（PC auto-fill 多列 / 移动端 2 列）+ --tile-pb 比例自适应；
 * 列表视图为单列行式（固定行高，不参与比例自适应）。
 * @param {string} mode - 'grid' | 'list'
 * @returns {void}
 */
function applyLayout(mode) {
  layoutMode = mode;
  localStorage.setItem('farm_layout', mode);
  wallEl.classList.toggle('wall-grid', mode === 'grid');
  wallEl.classList.toggle('wall-list', mode === 'list');
  layoutIcon.innerHTML = LAYOUT_ICONS[mode] || LAYOUT_ICONS.grid;
  layoutMenu.querySelectorAll('.lopt').forEach((o) => {
    o.classList.toggle('sel', o.dataset.l === mode);
  });
}

// 初始化：读取上次布局（卡片/列表）；grid 下由多数设备比例自适应覆盖 --tile-pb
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
    setInterval(() => { if (document.visibilityState === 'visible') refreshDevices().catch(() => {}); }, 6000);
  } catch (e) {
    if (e.message === 'unauthorized') showLogin();
  }
})();
