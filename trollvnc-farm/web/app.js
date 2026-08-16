// SuperPhone 群控台前端：设备墙(实时画面) -> 聚焦视图(左画面+右操作列) -> 移动端悬浮操作簇
// rfb.js?v=2：noVNC 核心为 server 内存 patch（dot 圆点/TLS 屏蔽等），URL 带版本号强制浏览器
// 重新拉取 patch 后的内容，避免旧版缓存（同 gesturehandler.js?v=3 方案）
import RFB from '/novnc/core/rfb.js?v=2';
import { invokeCap, setConfigs, batchInvoke, batchSetConfigs, batchRestart, groupByCategory, CATEGORY_LABELS, KEY_DEFS, BATCH_CAPS, CONFIG_BY_KEY, CONFIG_DEFS } from './caps.js?v=4';
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
      toast(`直控模式：新增 ${added} 台设备推流`, 'info');
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
    if (batchMode) exitBatchMode(); // 批量模式下点卡片聚焦：退出批量选择
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

  // 2) 批量调用能力（2026-08-13：BATCH_CAPS 静态定义，按 category 分组渲染）
  const capList = document.createElement('div');
  capList.className = 'batch-menu-section';
  capList.innerHTML = '<div class="batch-menu-sec-title">批量调用能力</div>';
  const grouped = groupByCategory(BATCH_CAPS);
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

  // 3) 批量调整配置（CONFIG_DEFS 静态表单定义）
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
    params = await promptParams(meta.params, meta.title);
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

// ---------- 控制台操作菜单（07 §4.1：按键区 KEY_DEFS + 动作区 ACT_DEFS） ----------
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
function kbdSendSpecial(keysym, code) {
  const rfb = focus && focus.rfb;
  if (!rfb || !rfb._farmConnected) return;
  releaseKbdShift(); // 删除/回车不应带 Shift 修饰，先释放（防连续大写后 Shift 残留）
  try {
    rfb.sendKey(keysym, code || null, true);
    setTimeout(() => {
      try { rfb.sendKey(keysym, code || null, false); } catch (e) { /* 静默 */ }
    }, 60);
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
 *     英文/数字（单可打印 ASCII）→ kbdSendAscii 键值直发（被控端补 Shift）；
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
  // 输入事件：删除键 / 回车 / 英文逐键增量（统一粘贴通道）
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
  kbi.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.keyCode === 13) {
      e.preventDefault();
      kbdSendSpecial(0xff0d, 'Enter'); // XK_Return
    }
  });

  // 2026-08-14 审查结论（用户实测确认）：iOS 键盘上方「粘贴」按钮不出现（QuickType 栏无此按钮），
  // 长按也无法触达 kbdInput（隐藏元素不可交互，长按画面会转发被控设备弹出被控端菜单）——
  // iOS 上无横幅自动取剪贴板路径不存在。用户拍板：iOS 不提供正向粘贴，
  // 控制端→设备方向仅保留 copy 事件（用户主动复制即同步）；原 paste 事件监听已删除。
}
initTouchKeyboard();

/**
 * 渲染控制台操作菜单（07 §4.1）：按键区（KEY_DEFS 按键对象+按压识别）+ 动作区（ACT_DEFS）
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
  // 按键按钮先构建进临时数组，存在按键才追加分组标题，避免渲染孤立空标题
  const keyTitle = document.createElement('div');
  keyTitle.className = 'cap-group-title';
  keyTitle.textContent = '按键';
  const keyBtns = [];
  for (const k of KEY_DEFS) {
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
    keyBtns.push(b);
  }
  if (keyBtns.length > 0) {
    if (!isOpsMenu) frag.appendChild(keyTitle);   // 悬浮菜单不显示「按键」分组标题
    keyBtns.forEach((b) => frag.appendChild(b));
  }

  // 移动端悬浮菜单本地动作：粘贴到设备（2026-08-14 用户拍板恢复）
  // 读取控制端剪贴板 → type.paste 原子注入被控设备聚焦输入框（与电脑 Ctrl+V 同链路）。
  // 仅挂 opsMenu（移动端 FAB 菜单）：电脑端已有 Ctrl+V，不重复加按钮。
  if (isOpsMenu) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'op';
    b.title = '粘贴：读取控制端剪贴板并粘贴到被控设备聚焦输入框';
    b.innerHTML = '<span class="cap-icon">' +
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' +
      '<path d="M15 2H9a1 1 0 0 0-1 1v2a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V3a1 1 0 0 0-1-1Z"/>' +
      '<path d="M8 4H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2h-2"/>' +
      '<rect x="9" y="11" width="6" height="4" rx="1"/>' +
      '</svg></span><span class="cap-name">粘贴</span>';
    b.addEventListener('click', pasteToFocusedDevice);
    frag.appendChild(b);
  }

  // 动作区已移除（2026-08-15：ACT_DEFS 清空——type.paste 走 Ctrl+V 原子链路、clipboard.get 走
  // 设备→控制端自动同步；capabilities 架构精简后该区不再渲染任何能力按钮）
  container.appendChild(frag);
}

/**
 * 显示右上角 toast（动作级日志，与控制台/5801 同构）：fixed 右上角 + 安全区，三态上色，500ms 同文案去重。
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
    'right:calc(env(safe-area-inset-right, 0px) + 14px);' +
    'z-index:999;max-width:min(72vw, 340px);' +
    'background:rgba(20,26,40,.92);color:' + cfg.color + ';' +
    'padding:10px 14px;border-radius:10px;border-left:3px solid ' + cfg.color + ';' +
    'font:13px/1.4 system-ui,sans-serif;box-shadow:0 6px 20px rgba(0,0,0,.4);' +
    'pointer-events:none;transition:opacity .25s;';
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

// 2026-08-15 基建：回环防护由原生端 changeCount 锚点抑制承担（writeClipboard 写入触发的一次
// 通知被吞、setStringFromRemote 同理），此处不再做来源排除/文本去重——相同文本每次复制都同步。
// 粘贴输入回显抑制由设备端 setStringForPasteInput（suppressInputEcho）治本承担（需重打 IPA），
// 前端不做兜底（用户 2026-08-15 拍板：前端不加输入回显抑制）。

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
    if (r && r.ok) toast(`✓ 已粘贴 ${text.length} 字符到设备`, 'success');
    else toast(`✗ 粘贴失败：${(r && r.ack && r.ack.error) || '未知错误'}`, 'error');
  } catch (e) {
    toast(`✗ 粘贴调用失败：${e.message}`, 'error');
  }
}

// 控制端→受控设备剪贴板同步核心（2026-08-14 抽出共用）：
// 把控制端剪贴板文本经 RFB clipboardPasteFrom（Extended Clipboard 协议通道，UTF-8）写入
// 当前连接会话（聚焦 focus.rfb + 直控 directRfbs），受设备 ClipboardEnabled 门控；
// 无连接会话静默（不做任何同步、不提示）。
// @param {string} txt 控制端剪贴板文本
// @param {string|null} excludeDeviceId 排除回发的来源设备（"从谁复制的不推送给谁"）
function farmPushClipboardToSessions(txt, excludeDeviceId) {
  if (!txt) return;
  const clipOn = (d) => !(d && d.configs && d.configs.ClipboardEnabled === false);
  const sent = new Set();
  if (focus && focus.device && focus.rfb && focus.rfb._farmConnected && clipOn(focus.device) &&
      focus.device.id !== excludeDeviceId) {
    sent.add(focus.rfb);
  }
  for (const [id, rfb] of directRfbs) {
    if (!rfb._farmConnected) continue;
    if (id === excludeDeviceId) continue;
    const wi = wallInstances.get(id);
    if (wi && !clipOn(wi.device)) continue;
    sent.add(rfb);
  }
  sent.forEach((rfb) => { try { rfb.clipboardPasteFrom(txt); } catch (_) { /* 静默 */ } });
}

// IPA 容器原生桥（2026-08-14）：控制端设备装 IPA 时，App 原生层监听本机剪贴板
// （TVNCConsoleWebViewController → evaluateJavaScript）推文本至此。无桥环境（浏览器/电脑）
// 该函数永不触发。与 copy 事件同一条发送路径；防循环：若文本恰为最近 RFB 收到的
// （控制端剪贴板被 RFB 写入的回显），则排除来源设备回发（"从谁复制的不推送给谁"），
// 配合设备端回显抑制（setStringFromRemote 文本对比）双保险。
window.__farmNativeClipboard = (text) => {
  if (!text) return;
  // 2026-08-15 基建：回环由原生端 changeCount 锚点抑制断环，此处直接同步给全部同步目标
  //（focus 主控 + 直控设备）；相同文本每次复制都同步（不再文本去重/来源排除）。
  farmPushClipboardToSessions(text, null);
};

// 控制端复制（Ctrl+C / 菜单复制）→ 协议通道同步到"当前连接会话"（2026-08-14 统一协议通道）。
// 注：所有设备统一安装新版 IPA（enableExtendedClipboard），不做旧包兼容/降级检测（2026-08-14 用户决策）。
document.addEventListener('copy', async () => {
  let txt = null;
  try {
    txt = await readClipboardText();
  } catch (_) {
    return; // 复制动作本身已成功；同步失败不阻断复制（非降级路径，仅跳过同步）
  }
  if (!txt) return;
  // 2026-08-15 基建：回环由原生端 changeCount 锚点抑制断环，此处直接同步给全部同步目标。
  farmPushClipboardToSessions(txt, null);
});

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
  let txt = null;
  try {
    txt = await readClipboardText(); // 同步发起（手势激活内），勿在调用前 await 其它操作
  } catch (err) {
    toast(`✗ 粘贴失败：${err.message}`, 'error'); // 非 https/API 不可用/被拒：明确报错，不降级弹浮层
    return;
  }
  if (!txt) {
    toast('✗ 粘贴失败：控制端剪贴板为空', 'error');
    return;
  }
  await submitPasteText(focus.device.id, txt);
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
    toast(`✗ 粘贴失败：${err.message}`, 'error'); // 剪贴板不可读：明确报错，不降级弹浮层
    return;
  }
  if (!txt) { toast('✗ 粘贴失败：控制端剪贴板为空', 'error'); return; }
  await submitPasteText(focus.device.id, txt);
}, true);

// 触控长按 = 传达被控设备长按（2026-08-14）：控制端→设备剪贴板仅保留 copy 事件（用户主动复制
// 即经协议通道同步）；长按被控画面不再作为粘贴手势，改为左键按下保持传达设备长按（rfb.js patch
// 0x1/0x0），与电脑端鼠标按住一致。原 __farmPasteLongPress 已删除。

// ---------- 聚焦视图 ----------
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
  const fRfb = createRfb(stage, d, { grp, broadcast, ctrl: true }, $('focusStatusDot'));
  focus.rfb = fRfb;
  fRfb.addEventListener('connect', () => {
    focusReconnectAttempts = 0; // 重连成功：复位重试计数
    setFocusOverlay(false, null); // 隐藏连接浮层
    setTimeout(fitFocusPanel, 300);
  });
  // 聚焦主控画面断线自动重连（2026-08-14）：iOS 后台挂起/切应用导致 WS 断开（1006）后画面黑屏，
  // 断开即调度重建（网关按新连接重建 ctrl 会话、设备端 rfb.start 无条件重连）；见 scheduleFocusReconnect。
  fRfb.addEventListener('disconnect', (e) => {
    if (!focus || focus.rfb !== fRfb) return;
    const code = e && e.detail ? e.detail.code : null;
    if (code === 1000 || code === 1001 || code === 4001) return; // 主动断开/被接管不重连
    setFocusOverlay(false, '画面已断开，正在重连…');
    scheduleFocusReconnect(); // 首次立即重连
  });
  setTimeout(fitFocusPanel, 400);
  startFabSignalPoll(); // 移动端悬浮按钮延迟信号轮询（仅在 focus 建立后）
  // 2026-08-15 用户拍板：进入控制不再强制系统全屏（自动 requestFullscreen 在 iOS 上会与
  // 画面/菜单交互冲突，且非用户直接意图）。移动端聚焦画面由 CSS 撑满视口（区域全屏），
  // 需要隐藏浏览器 UI 时用户通过悬浮菜单「全屏」按钮手动切换（doOp 'full'）。
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
  ov.classList.toggle('loading', !!loading);
  ov.classList.toggle('show', !!loading || text != null);
  if (text != null) {
    const t = $('focusStatusText');
    if (t) t.textContent = text;
  }
}

// ---------- 聚焦画面自动重连（2026-08-14） ----------
// iOS 后台挂起/切应用或网络抖动导致控制端 WebSocket 断开（1006 等）后画面黑屏：
// 断开时或页面回到前台时自动重建 RFB —— 网关按新连接重建 ctrl 会话，
// 设备端 rfb.start 无条件重连（见设备端协议），画面无需退出重进即可恢复。
// 主动断开（1000/1001）与被其他端接管（4001）不自动重连。
let focusReconnectTimer = null;
let focusReconnectAttempts = 0;
const FOCUS_RECONNECT_MAX = 8;
const FOCUS_RECONNECT_DELAY = 2000; // 重连失败后的防抖间隔（2026-08-14 用户要求：首次断开立即重连）

/**
 * 调度聚焦画面重连：断开立即重连（不做退避等待）；仅当立即重连失败（设备未恢复）时
 * 以固定 2s 间隔重试，达到上限后停止，避免设备真离线时无限快速重试刷屏。
 * @returns {void}
 */
function scheduleFocusReconnect() {
  if (!focus) return;
  if (focusReconnectAttempts >= FOCUS_RECONNECT_MAX) return;
  focusReconnectAttempts++;
  if (focusReconnectAttempts === 1) {
    reconnectFocusRfb(); // 首次：立即重连
  } else {
    clearTimeout(focusReconnectTimer);
    focusReconnectTimer = setTimeout(reconnectFocusRfb, FOCUS_RECONNECT_DELAY);
  }
}

/**
 * 重建聚焦 RFB（网关按新连接重建 ctrl 会话，设备端重连 5901）
 * @returns {void}
 */
function reconnectFocusRfb() {
  focusReconnectTimer = null;
  if (!focus || !focus.rfb) return;
  if (focus.rfb._rfbConnectionState === 'connected') return; // 已自行恢复
  setFocusOverlay(true, '连接中…'); // 重连过程显示加载动画（与 5801 一致）
  const d = focus.device;
  const stage = $('focusStage');
  closeRfb(focus.rfb);
  stage.innerHTML = '';
  const rfb = createRfb(stage, d, { grp: wallSession, broadcast: '1', ctrl: true }, $('focusStatusDot'));
  rfb.addEventListener('connect', () => {
    focusReconnectAttempts = 0;
    setFocusOverlay(false, null);
    setTimeout(fitFocusPanel, 300);
  });
  rfb.addEventListener('disconnect', (e) => {
    if (!focus || focus.rfb !== rfb) return;
    const code = e && e.detail ? e.detail.code : null;
    if (code === 1000 || code === 1001 || code === 4001) return;
    setFocusOverlay(false, '画面已断开，正在重连…');
    scheduleFocusReconnect();
  });
  focus.rfb = rfb;
  setTimeout(fitFocusPanel, 400);
}

// 回到前台：若聚焦连接已断开立即触发重连（后台挂起期间 WS 被系统断开，回前台直接恢复）
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && focus && focus.rfb) {
    if (focus.rfb._rfbConnectionState !== 'connected') {
      focusReconnectAttempts = 0;
      scheduleFocusReconnect();
    }
  }
});

function exitFocus() {
  if (!focus) return;
  const devId = focus.device.id;
  clearTimeout(focusReconnectTimer);
  focusReconnectTimer = null;
  focusReconnectAttempts = 0;
  setFocusOverlay(false, null); // 退出隐藏连接浮层
  // 清除 URL 聚焦参数（2026-08-14）：退出控制后刷新不再自动进入该设备
  try {
    const u = new URL(location.href);
    if (u.searchParams.has('focus')) {
      u.searchParams.delete('focus');
      history.replaceState(null, '', u.toString());
    }
  } catch (e) { /* 忽略 */ }
  closeRfb(focus.rfb);
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
    // 取消同步：显式 closeRfb 关闭 WS 订阅，移除选中态，恢复卡片墙截图轮询
    const rfb = syncRfbs.get(deviceId);
    if (rfb) closeRfb(rfb);
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
        toast(`设备「${d.name}」直控已断开` + (code ? `（${code}）` : ''), 'error');
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
  if (n > 0) toast(`直控模式：${n} 台设备已开启推流，点击卡片直接控制`, 'info');
  else toast('直控模式：当前无在线真实设备', 'info');
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
    case 'disc': try { rfb.disconnect(); } catch (e) {} exitFocus(); break;
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
  rfb.showDotCursor = true;
  // 2026-08-15：画面余白透明跟随系统主题——noVNC 内部 _screen 默认硬编码 rgb(40,40,40) 深灰，
  // 覆盖外层 .screen 的 transparent 无效；此处显式置透明，露出 body 背景（--bg 随 prefers-color-scheme）。
  rfb.background = 'transparent';
  if (opts.viewOnly) rfb.viewOnly = true;   // 墙缩略图只读：点击卡片=切入大屏控制，不直接操控
  // 光标策略（2026-08-14 用户需求）：
  // - 墙缩略图（viewOnly）：无光标（消除多 RFB 覆盖层光标串扰——PC"屏幕中原有的 X"即来自
  //   墙缩略图/直控卡片的独立覆盖层）
  // - 手机端控制画面：尊重服务端光标——ServerCursor 开 → 触屏点击/移动显示服务端圆点，
  //   空闲 1.5s 自动隐藏；ServerCursor 关 → 服务端无光标 → 无光标。不使用 dot（showDotCursor=false）
  // - PC 端聚焦/直控画面：保持 dot 圆点（showDotCursor=true），鼠标移入仅一个圆点
  if (opts.viewOnly) {
    rfb.showDotCursor = false;
    // 覆盖 _refreshCursor：无论服务端光标/dot 一律渲染为空（clear → cursor:none + 覆盖层清空）
    rfb._refreshCursor = () => { if (rfb._cursor) rfb._cursor.clear(); };
  } else if (isMobile()) {
    rfb.showDotCursor = false;
    let cursorTimer = null;
    const CURSOR_IDLE_MS = 1500;
    const cursorHide = () => { if (rfb._cursor && rfb._cursor._canvas) rfb._cursor._hideCursor(); };
    // 苹果风格触控光标（2026-08-14）：iOS 系统触摸指示器样式——半透明灰圆，
    // 触屏点击/移动时显示、空闲 1.5s 自动隐藏。不显示服务端光标图像（白点黑边不合苹果风格）。
    const APPLE_CURSOR_SIZE = 24;
    const APPLE_CURSOR_R = 9;
    const appleCursorRgba = (() => {
      const S = APPLE_CURSOR_SIZE, cx = (S - 1) / 2, cy = (S - 1) / 2, R = APPLE_CURSOR_R;
      const rgba = new Uint8Array(S * S * 4);
      for (let y = 0; y < S; y++) {
        for (let x = 0; x < S; x++) {
          const d = Math.hypot(x - cx, y - cy);
          const i = (y * S + x) * 4;
          if (d <= R) {
            rgba[i] = 128; rgba[i + 1] = 128; rgba[i + 2] = 128; // 深灰（2026-08-14 加深）
            rgba[i + 3] = Math.round(217 * (1.0 - 0.6 * (d / R))); // 中心≈0.85 边缘渐隐
          }
        }
      }
      return rgba;
    })();
    const cursorShow = () => {
      rfb._cursor.change(appleCursorRgba, Math.round((APPLE_CURSOR_SIZE - 1) / 2),
                         Math.round((APPLE_CURSOR_SIZE - 1) / 2), APPLE_CURSOR_SIZE, APPLE_CURSOR_SIZE);
    };
    const cursorPoke = () => {
      cursorShow();
      clearTimeout(cursorTimer);
      cursorTimer = setTimeout(cursorHide, CURSOR_IDLE_MS);
    };
    const cv = rfb._canvas;
    const opt = { capture: true, passive: true };
    cv.addEventListener('touchstart', cursorPoke, opt);
    cv.addEventListener('touchmove', cursorPoke, opt);
    cv.addEventListener('mousemove', cursorPoke, opt);
    cv.addEventListener('mousedown', cursorPoke, opt);
    cv.addEventListener('wheel', cursorPoke, { capture: true, passive: false });
    rfb.addEventListener('disconnect', () => clearTimeout(cursorTimer));
  }
  // PC 端聚焦/直控画面：保持 noVNC 默认（showDotCursor=true）——服务端光标优先，
  // PC 上显示的是设备端真实发送的光标（可验证 IPA 圆点图案是否编译生效）；
  // ServerCursor 关闭时回落 dot 圆点。
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
  // 设备 → 控制端剪贴板同步（方案 B 双向，2026-08-14）：
  // 设备端剪贴板变化 → ClipboardManager.onChange → ClientCutText → 网关 FT_DATA 广播 wsSet
  // → noVNC RFB 'clipboard' 事件（noVNC 内部已过滤 viewOnly，仅控制/直控会话触发）。
  // 写入控制端剪贴板（"最后变化者胜"语义）+ toast 标注来源设备；设备端 setStringFromRemote
  // 有抑制回调不回发，writeText 不触发 copy 事件，双向均无回环。
// 设备→控制端剪贴板写入（2026-08-14）：iOS WebKit 在【非用户手势】下 navigator.clipboard.writeText
// 会被拒（NotAllowedError）——手机 Safari 与 IPA 容器 WKWebView 同受限，电脑 Chrome 无此限制。
// 容器模式（IPA）：优先走原生桥 writeClipboard（farmBridge → 原生写 UIPasteboard，无手势/安全上下文限制）；
// 无桥环境（浏览器）：writeText 尽力而为，失败明确提示。
// @param {string} text 设备剪贴板文本
// @param {string} devName 来源设备名（toast 标注用）
function farmWriteClipboardToControl(text, devName) {
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.farmBridge;
  if (bridge) {
    try {
      bridge.postMessage({ type: 'writeClipboard', text });
      toast(`✓ 已同步设备「${devName}」剪贴板（${text.length} 字符）`, 'success');
      return;
    } catch (e) {
      console.error('[clip] native writeClipboard 桥调用失败，降级 writeText：', e);
    }
  }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(() => {
      console.debug(`[clip] 已写入控制端剪贴板（${text.length} 字符）`);
      toast(`✓ 已同步设备「${devName}」剪贴板（${text.length} 字符）`, 'success');
    }).catch((err) => {
      console.error('[clip] 写入控制端剪贴板失败：', err);
      toast(`✗ 设备「${devName}」剪贴板已同步但写入控制端失败（iOS 非手势限制，建议使用 SuperPhone App 内控制台）`, 'error');
    });
    return;
  }
  console.error('[clip] navigator.clipboard 不可用（需 https 安全上下文）');
  toast(`✗ navigator.clipboard 不可用（需 https 安全上下文），设备「${devName}」剪贴板无法写入控制端`, 'error');
}

// 设备→控制端剪贴板同步（RFB ServerCutText 负长度 Extended Clipboard，2.3u 修复）：
// 被控端复制 → 网关透传 → noVNC 'clipboard' 事件 → 写控制端剪贴板（原生桥优先）。
  rfb.addEventListener('clipboard', (e) => {
    const text = e && e.detail && e.detail.text;
    if (!text) return;
    const now = Date.now();
    // 2026-08-15 修复"被控设备复制后不是每次都能同步"：绝对 1s 节流会吞掉连续复制——
    // 用户复制 A 后 1s 内再复制 B，B 的剪贴板事件被直接丢弃。改为"同文本短窗口去重"：
    // 仅当文本与上次相同且 500ms 内重复（协议/系统抖动）才过滤；不同文本立即放行。
    if (rfb._farmClipLastText === text && rfb._farmClipLastAt && now - rfb._farmClipLastAt < 500) return;
    rfb._farmClipLastAt = now;
    rfb._farmClipLastText = text;
    // 2026-08-15 基建：回环由原生端 changeCount 锚点抑制断环（writeClipboard 写入触发的一次
    // 通知被吞），不再记录来源/做文本排除——相同文本每次复制都同步（用户要求）。
    farmWriteClipboardToControl(text, device.name);
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
 * 保存编辑：ID（0-99999 整数或空=清除）+ 名称（非空）→ PATCH 网关 → 刷新设备墙。
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
  try {
    await api(`/api/devices/${encodeURIComponent(devId)}`, { method: 'PATCH', body: JSON.stringify({ name, order }) });
    $('editModal').classList.add('hidden');
    toast(`✓ 已更新「${name}」`, 'success');
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
$('btnCancelAdd').onclick = () => $('addModal').classList.add('hidden');
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
    restoreFocusFromUrl(); // 2026-08-14：刷新后自动恢复当前操作的设备画面（URL ?focus=）
    setInterval(() => { if (document.visibilityState === 'visible') refreshDevices().catch(() => {}); }, 6000);
  } catch (e) {
    if (e.message === 'unauthorized') showLogin();
  }
})();
