// TrollVNC 群控台前端：设备墙(实时画面) -> 聚焦视图(左画面+右操作列) -> 移动端悬浮操作簇
import RFB from '/novnc/core/rfb.js';
import { CAP_META, deviceCaps } from './caps.js';

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

// ---------- login ----------
function showLogin() {
  if (document.getElementById('loginBox')) return;
  const wrap = document.createElement('div');
  wrap.id = 'loginBox';
  wrap.className = 'login';
  wrap.innerHTML = `
    <h3>TrollVNC 群控台</h3>
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
async function refreshDevices() {
  const data = await api('/api/devices');
  devices = data.devices || [];
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
      closeRfb(inst.rfb);
      inst.tile.remove();
      wallInstances.delete(id);
    }
  }
  // 渲染全部设备（在线=实时画面；离线=置灰占位+上次在线）
  for (const d of devices) {
    let inst = wallInstances.get(d.id);
    if (!inst) inst = createWallTile(d);
    updateWallTile(inst, d);
  }
}

function createWallTile(d) {
  const tile = document.createElement('div');
  tile.className = 'tile' + (d.online ? '' : ' tile-offline');
  tile.innerHTML = `
    <div class="tv"></div>
    <div class="tile-bar">
      <span class="dot ${d.online ? 'on' : 'off'}"></span>
      <span class="tname">${escapeHtml(d.name)}</span>
      <span class="tstate">${d.online ? '连接中…' : '离线'}</span>
      <button class="tmore" title="更多操作">⋯</button>
    </div>`;
  const tv = tile.querySelector('.tv');
  const statusEl = tile.querySelector('.tstate');
  const inst = { device: d, rfb: null, tile, statusEl, paused: false };
  // 连接前先用上报屏幕比例预置卡片（消除“先宽后窄”闪烁）
  if (d.screen && d.screen.width && d.screen.height) {
    tile.style.setProperty('--tile-ratio', d.screen.width + ' / ' + d.screen.height);
    tile.dataset.wh = d.screen.width + 'x' + d.screen.height;
  }
  if (d.online) {
    inst.rfb = createRfb(tv, d, { grp: wallSession, tile, viewOnly: true }, statusEl);
  } else {
    tv.innerHTML = '<div class="offline-ph">离线</div>';
    statusEl.textContent = d.lastSeen ? '离线 · ' + fmtTime(d.lastSeen) : '离线';
  }
  wallInstances.set(d.id, inst);

  tile.addEventListener('click', (e) => {
    if (e.target.closest('.tmore')) return;
    const dev = inst.device;
    if (dev.online === false) {
      alert(`设备「${dev.name}」离线，请唤醒手机后重试`);
      return;
    }
    enterFocus(dev);
  });
  tile.querySelector('.tmore').addEventListener('click', (e) => {
    e.stopPropagation();
    showTileMenu(tile, d, e.clientX, e.clientY);
  });
  $('wall').appendChild(tile);
  return inst;
}

// ---------- 按能力清单渲染操作按钮（宪法 4.2/5.2/7.3） ----------
// 适配/全屏/断开为控制台本地操作，不在 capabilities 内，由静态按钮提供
function renderCapOps(container, caps) {
  if (!container) return;
  container.innerHTML = '';
  for (const c of caps) {
    const meta = CAP_META[c];
    if (!meta) continue;
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'op';
    b.dataset.op = meta.op;
    b.title = meta.title;
    b.textContent = meta.icon;
    b.addEventListener('click', () => doOp(meta.op));
    container.appendChild(b);
  }
}

// ---------- 聚焦视图 ----------
function enterFocus(d) {
  if (focus && focus.device.id === d.id) return;
  if (focus) exitFocus();
  if (d.online === false) { alert(`设备「${d.name}」离线，请唤醒手机后重试`); return; }

  // 预置面板宽度（用墙卡片已知的设备比例），避免“先宽后窄”闪烁
  const wallInst = wallInstances.get(d.id);
  let knownRatio = null;
  if (wallInst && wallInst.tile.dataset.wh) {
    const parts = wallInst.tile.dataset.wh.split('x').map(Number);
    if (parts[0] && parts[1]) knownRatio = parts[0] / parts[1];
  }
  prefitFocusPanel(knownRatio || (9 / 16));

  // 隐藏该设备的墙卡片（它已放大到左侧）
  if (wallInst) {
    closeRfb(wallInst.rfb);
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
  renderCapOps($('focusOpsCap'), deviceCaps(d));
  renderCapOps($('opsMenuCap'), deviceCaps(d));
  if (window.matchMedia('(max-width: 900px)').matches) $('fab').classList.remove('hidden');
  const grp = $('chkFocusBroadcast').checked ? wallSession : '';
  const broadcast = $('chkFocusBroadcast').checked ? '1' : '';
  focus = { device: d, rfb: createRfb(stage, d, { grp, broadcast }, $('focusStatus')) };
  focus.rfb.addEventListener('connect', () => setTimeout(fitFocusPanel, 300));
  setTimeout(fitFocusPanel, 400);
}

function exitFocus() {
  if (!focus) return;
  const devId = focus.device.id;
  closeRfb(focus.rfb);
  focus = null;
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
  inst.rfb = createRfb(inst.tile.querySelector('.tv'), inst.device, { grp: wallSession, tile: inst.tile, viewOnly: true }, inst.statusEl);
}

function fmtTime(ts) {
  if (!ts) return '未知';
  const d = new Date(ts);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
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
    if (!inst.rfb) {
      tv.innerHTML = '';
      inst.rfb = createRfb(tv, d, { grp: wallSession, tile, viewOnly: true }, inst.statusEl);
    }
  } else {
    tile.classList.add('tile-offline');
    if (inst.rfb) { closeRfb(inst.rfb); inst.rfb = null; }
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
  const headH = 48;
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
  if (window.matchMedia('(max-width: 900px)').matches) return; // 移动端保持全宽
  const panel = $('focusPanel');
  const screenEl = $('focusScreen');
  const stage = $('focusStage');
  if (!panel || !screenEl || !stage) return;
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

// ---------- 操作（与手机 web 同能力层） ----------
function currentRfb() { return focus ? focus.rfb : null; }

function tapKey(rfb, ks, code) {
  try { rfb.sendKey(ks, code, true); } catch (e) { return; }
  setTimeout(() => { try { rfb.sendKey(ks, code, false); } catch (e) {} }, 60);
}
function pointer(rfb, mask) {
  try {
    const b = new Uint8Array(6);
    b[0] = 5; b[1] = mask; b[2] = 0; b[3] = 1; b[4] = 0; b[5] = 1;
    rfb._sock.send(b.buffer);
    if (mask !== 0) setTimeout(() => pointer(rfb, 0), 80);
  } catch (e) {}
}

function doOp(op) {
  const rfb = currentRfb();
  if (!rfb) return;
  switch (op) {
    case 'home': tapKey(rfb, 0xff50, 'Home'); break;
    case 'power': pointer(rfb, 2); break;                 // 中键=电源（TrollVNC 映射）
    case 'volup': tapKey(rfb, 0x1008ff13, 'AudioVolumeUp'); break;
    case 'voldn': tapKey(rfb, 0x1008ff11, 'AudioVolumeDown'); break;
    case 'mute': tapKey(rfb, 0x1008ff12, 'AudioVolumeMute'); break;
    case 'briup': tapKey(rfb, 0x1008ff03, 'BrightnessUp'); break;
    case 'bridn': tapKey(rfb, 0x1008ff02, 'BrightnessDown'); break;
    case 'kb': try { rfb.focus(); } catch (e) {} break;
    case 'clip':
      navigator.clipboard.readText().then((t) => {
        if (t) try { rfb.clipboardPasteFrom(t); } catch (e) {}
      }).catch(() => {});
      break;
    case 'fit': rfb.scaleViewport = true; break;
    case 'full':
      if (document.fullscreenElement) document.exitFullscreen();
      else document.documentElement.requestFullscreen().catch(() => {});
      break;
    case 'disc': try { rfb.disconnect(); } catch (e) {} exitFocus(); break;
  }
}

// ---------- RFB 帮助 ----------
function createRfb(container, device, opts = {}, statusEl = null) {
  const params = {};
  if (opts.grp) params.grp = opts.grp;
  if (opts.broadcast) params.broadcast = '1';
  const uri = wsUrl(`/ws/vnc/${encodeURIComponent(device.id)}`, params);
  const rfb = new RFB(container, uri, {});
  rfb.scaleViewport = true;
  rfb.resizeSession = false;
  rfb.showDotCursor = true;
  if (opts.viewOnly) rfb.viewOnly = true;   // 墙缩略图只读：点击卡片=切入大屏控制，不直接操控
  const setStatus = (s) => { if (statusEl) statusEl.textContent = s; };
  const applyRatio = () => {
    if (!opts.tile) return;
    try {
      const disp = rfb._display;
      const w = rfb._fb_width || (disp && (disp._fbWidth || (disp.get_width && disp.get_width()))) || 0;
      const h = rfb._fb_height || (disp && (disp._fbHeight || (disp.get_height && disp.get_height()))) || 0;
      if (w && h) { opts.tile.style.setProperty('--tile-ratio', w + ' / ' + h); opts.tile.dataset.wh = w + 'x' + h; }
    } catch (e) { /* ignore */ }
  };
  rfb.addEventListener('connect', () => {
    setStatus('已连接');
    applyRatio();
    setTimeout(applyRatio, 300);
  });
  rfb.addEventListener('disconnect', () => setStatus('已断开'));
  rfb.addEventListener('credentialsrequired', () => {
    const p = prompt(`请输入 ${device.name} 的 VNC 密码：`);
    if (p) rfb.sendCredentials({ password: p });
  });
  return rfb;
}
function closeRfb(rfb) {
  try { rfb.disconnect(); } catch (e) {}
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
  const caps = deviceCaps(d).map((c) => (CAP_META[c] && CAP_META[c].label) || c).join('、') || '—';
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

function showTileMenu(tile, d, x, y) {
  const m = $('tileMenu');
  m.innerHTML = `
    <button data-a="view">查看/控制</button>
    <button data-a="detail">详情</button>
    <button data-a="edit">编辑</button>
    <button data-a="ping">测试在线</button>
    <button data-a="del">删除</button>`;
  m.classList.remove('hidden');
  const rect = tile.getBoundingClientRect();
  m.style.left = Math.min(x, window.innerWidth - 140) + 'px';
  m.style.top = Math.min(y, window.innerHeight - 160) + 'px';
  m.onclick = async (e) => {
    const a = e.target.dataset.a;
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
    } else if (a === 'del') {
      if (confirm(`删除设备 ${d.name}？`)) {
        await api(`/api/devices/${encodeURIComponent(d.id)}`, { method: 'DELETE' });
        const inst = wallInstances.get(d.id);
        if (inst) { closeRfb(inst.rfb); inst.tile.remove(); wallInstances.delete(d.id); }
        await refreshDevices();
      }
    }
  };
}

// ---------- 移动端悬浮操作簇（可拖动 + 双指缩放） ----------
function initFab() {
  const fab = $('fab');
  const head = $('fabHead');
  let startX = 0, startY = 0, baseLeft = 0, baseTop = 0, dragging = false;
  let pinchDist = 0, baseScale = 1;

  head.addEventListener('pointerdown', (e) => {
    dragging = true;
    startX = e.clientX; startY = e.clientY;
    const r = fab.getBoundingClientRect();
    baseLeft = r.left; baseTop = r.top;
    head.setPointerCapture(e.pointerId);
  });
  head.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    const nx = baseLeft + (e.clientX - startX);
    const ny = baseTop + (e.clientY - startY);
    fab.style.left = Math.max(4, Math.min(nx, window.innerWidth - 60)) + 'px';
    fab.style.top = Math.max(4, Math.min(ny, window.innerHeight - 60)) + 'px';
    fab.style.right = 'auto'; fab.style.bottom = 'auto';
  });
  head.addEventListener('pointerup', () => { dragging = false; });

  // 双指捏合缩放
  fab.addEventListener('touchstart', (e) => {
    if (e.touches.length === 2) {
      pinchDist = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY);
      baseScale = parseFloat(fab.dataset.scale || '1');
    }
  }, { passive: true });
  fab.addEventListener('touchmove', (e) => {
    if (e.touches.length === 2) {
      const d = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY);
      const s = Math.min(2.2, Math.max(0.6, baseScale * (d / pinchDist)));
      fab.dataset.scale = String(s);
      fab.style.transform = `scale(${s})`;
    }
  }, { passive: true });
}

// ---------- 墙屏缩放（统一缩放所有卡片） ----------
function applyZoom(z) {
  const wall = $('wall');
  if (wall) wall.style.setProperty('--zoom', z);
  $('zoomVal').textContent = Math.round(z * 100) + '%';
  $('zoomRange').value = Math.round(z * 100);
}
const savedZoom = parseFloat(localStorage.getItem('farm_zoom') || '1');
applyZoom(savedZoom);
$('zoomRange').addEventListener('input', () => {
  const z = parseFloat($('zoomRange').value) / 100;
  localStorage.setItem('farm_zoom', String(z));
  applyZoom(z);
});

// ---------- init ----------
$('btnRefresh').onclick = () => refreshDevices().catch(() => showLogin());
$('btnAdd').onclick = openAdd;
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
$('chkFocusBroadcast').onchange = () => {
  if (!focus) return;
  // 重建聚焦连接以切换广播标记
  const d = focus.device;
  closeRfb(focus.rfb);
  const grp = $('chkFocusBroadcast').checked ? wallSession : '';
  const broadcast = $('chkFocusBroadcast').checked ? '1' : '';
  const stage = document.createElement('div');
  stage.id = 'focusStage';
  stage.className = 'focus-stage';
  $('focusScreen').innerHTML = '';
  $('focusScreen').appendChild(stage);
  focus.rfb = createRfb(stage, d, { grp, broadcast }, $('focusStatus'));
  focus.rfb.addEventListener('connect', () => setTimeout(fitFocusPanel, 300));
  setTimeout(fitFocusPanel, 400);
};

initFab();
// 移动端悬浮菜单
$('fabMenuBtn').addEventListener('click', (e) => {
  e.stopPropagation();
  $('opsMenu').classList.toggle('hidden');
});
$('opsExit').addEventListener('click', () => {
  $('opsMenu').classList.add('hidden');
  exitFocus();
});
document.addEventListener('click', (e) => {
  if (!e.target.closest('#opsMenu') && !e.target.closest('#fab')) {
    $('opsMenu').classList.add('hidden');
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
