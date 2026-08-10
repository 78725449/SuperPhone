// TrollVNC 群控台前端：设备墙(实时画面) -> 聚焦视图(左画面+右操作列) -> 移动端悬浮操作簇
import RFB from '/novnc/core/rfb.js';
import { deviceCaps, configSchemaByReload, invokeCap, setConfigs, RELOAD_LABELS, batchInvoke, batchSetConfigs, batchRestart, groupByCategory, CATEGORY_LABELS } from './caps.js';

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
let selectedDevices = new Set(); // 批量操作选中的设备 ID 集合（Phase 10.2）

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
      stopWallRfb(inst);
      inst.tile.remove();
      wallInstances.delete(id);
      // 同步清理批量选中集合（Phase 10.2）
      selectedDevices.delete(id);
    }
  }
  updateBatchBar();
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
  // Phase 12.1（v2.3 恢复）：卡片墙建立完整 RFB 连接（viewOnly 只读），实时渲染画面。
  // v1.8.3 的 invoke screenshot API 轮询设计已弃用。
  // rfb：noVNC RFB 实例（viewOnly），ThumbInterval 可选作为帧渲染频率节流（默认不限制）。
  const inst = { device: d, tile, statusEl, paused: false, rfb: null, checkbox: cb };
  // 恢复已选中状态（设备刷新后保持勾选）
  if (selectedDevices.has(d.id)) {
    cb.checked = true;
    tile.classList.add('tile-selected');
  }
  // 连接前先用上报屏幕比例预置卡片（消除“先宽后窄”闪烁）
  if (d.screen && d.screen.width && d.screen.height) {
    tile.style.setProperty('--tile-ratio', d.screen.width + ' / ' + d.screen.height);
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

  // checkbox 勾选切换：阻止冒泡避免触发卡片点击进入聚焦（Phase 10.2）
  cb.addEventListener('click', (e) => {
    e.stopPropagation();
    toggleSelect(d.id);
  });
  tile.addEventListener('click', (e) => {
    if (e.target.closest('.tmore')) return;
    if (e.target.closest('.tile-checkbox')) return;
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

/**
 * 启动卡片墙 RFB 连接（Phase 12.1，v2.3 恢复）
 * 功能：为卡片墙建立完整 RFB 连接（viewOnly 只读），实时渲染设备画面。
 *       v1.8.3 的 invoke screenshot API 轮询设计已弃用，改回 noVNC 持久连接。
 *       ThumbInterval 可选作为帧渲染频率节流（默认不限制=实时渲染）。
 * 错误处理：RFB 断开时标记卡片"不可达"；focus 视图复用同一连接或重建。
 * @param {object} inst 卡片墙实例 { device, tile, statusEl, rfb, paused }
 * @returns {void}
 */
function startWallRfb(inst) {
  if (!inst || inst.paused || inst.rfb) return;
  const tv = inst.tile.querySelector('.tv');
  if (!tv) return;
  // ???????????????????????
  if (inst.device.source !== 'register') {
    tv.innerHTML = '<div class="offline-ph">未注册 · 请先配置网关</div>';
    if (inst.statusEl) inst.statusEl.textContent = '未注册';
    return;
  }
  // ?????? = ??????? RFB ???????? RFB ????
  // ?? noVNC ???????????/???????????????? RFB ??
  tv.innerHTML = '<div class="offline-ph">加载中…</div>';
  inst.rfb = { kind: 'screenshot', timer: null, closed: false };
  const tick = async () => {
    if (inst.paused || inst.rfb.closed) return;
    try {
      const r = await invokeCap('', inst.device.id, 'screenshot', {});
      const result = r && r.ack && r.ack.result;
      const b64 = result && (result.image || result.base64);
      if (b64) {
        tv.innerHTML = `<img class="thumb" src="data:image/jpeg;base64,${b64}" alt="" />`;
        if (inst.statusEl) inst.statusEl.textContent = '';
        if (inst.tile && result.width && result.height) {
          inst.tile.style.setProperty('--tile-ratio', result.width + ' / ' + result.height);
          inst.tile.dataset.wh = result.width + 'x' + result.height;
        }
      }
    } catch (e) {
      if (inst.statusEl) inst.statusEl.textContent = '截图失败';
    } finally {
      if (!inst.paused && !inst.rfb.closed) {
        const iv = (inst.device.configs && inst.device.configs.ThumbInterval) || 5;
        inst.rfb.timer = setTimeout(tick, Math.max(1, Number(iv) || 5) * 1000);
      }
    }
  };
  tick();
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

/**
 * 更新批量操作栏显隐与计数：勾选≥1 台时显示，否则隐藏
 * @returns {void}
 */
function updateBatchBar() {
  const btn = $('batchBtn');
  const cnt = $('batchCount');
  if (!btn) return;
  const n = selectedDevices.size;
  if (cnt) cnt.textContent = String(n);
  btn.classList.toggle('hidden', n === 0);
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
  cfgBtn.addEventListener('click', () => { menu.remove(); showBatchConfigPanel(ids); });
  menu.appendChild(cfgBtn);

  // 4) 批量重启（危险操作，需二次确认）
  const restartBtn = document.createElement('button');
  restartBtn.className = 'batch-menu-row-item danger';
  restartBtn.innerHTML = '<span class="cap-icon">🔄</span><span class="cap-name">批量重启</span>';
  restartBtn.addEventListener('click', async () => {
    if (!confirm(`确认批量重启选中的 ${ids.length} 台设备？`)) return;
    menu.remove();
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
  closeBtn.addEventListener('click', () => menu.remove());
  menu.appendChild(closeBtn);

  document.body.appendChild(menu);
  // 点击外部关闭
  setTimeout(() => {
    const handler = (e) => {
      if (!e.target.closest('#batchMenu') && !e.target.closest('#batchBtn')) {
        menu.remove();
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

// ---------- 按能力元数据渲染操作按钮（Phase 4.7：数据驱动，不再硬编码 keysym；Phase 10.3：按 category 分组） ----------
// 适配/全屏/断开为控制台本地操作，不在能力清单内，由静态按钮提供
/**
 * 按能力元数据渲染操作按钮，按 category 分组（Phase 10.3）
 * 每个分组前插入分组标题，分组内仍为纵向列表按钮（图标+名称），分组间用 hr 分隔
 * @param {HTMLElement} container 容器元素
 * @param {Array<object>} capMetadata 能力元数据数组
 * @returns {void}
 */
function renderCapOps(container, capMetadata) {
  if (!container) return;
  container.innerHTML = '';
  // 按 category 分组渲染（Phase 10.3）
  const grouped = groupByCategory(capMetadata);
  let groupIdx = 0;
  for (const [cat, metas] of grouped) {
    // 分组之间插入分隔线（首个分组前不插）
    if (groupIdx > 0) {
      const divider = document.createElement('hr');
      divider.className = 'cap-group-divider';
      container.appendChild(divider);
    }
    groupIdx++;
    // 分组标题（中文映射，兜底显示原 category）
    const title = document.createElement('div');
    title.className = 'cap-group-title';
    title.textContent = CATEGORY_LABELS[cat] || cat || '其它';
    container.appendChild(title);
    // 分组内纵向列表按钮
    for (const meta of metas) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'op';
      b.dataset.cap = meta.id;
      b.title = meta.title || meta.id;
      // 按钮内“图标+名称”横向布局：移动端 ops-menu-grid 显示两者，PC 端 focus-ops-cap 通过 CSS 隐藏 cap-name
      b.innerHTML = '<span class="cap-icon">' + escapeHtml(meta.icon || '?') + '</span><span class="cap-name">' + escapeHtml(meta.title || meta.id) + '</span>';
      b.addEventListener('click', () => doInvoke(meta));
      container.appendChild(b);
    }
  }
  // 追加配置入口按钮（二级菜单）
  const cfgBtn = document.createElement('button');
  cfgBtn.type = 'button';
  cfgBtn.className = 'op';
  cfgBtn.dataset.op = 'config';
  cfgBtn.title = '设备配置';
  cfgBtn.innerHTML = '<span class="cap-icon">⚙</span><span class="cap-name">设备配置</span>';
  cfgBtn.addEventListener('click', () => showConfigPanel());
  container.appendChild(cfgBtn);
}

/**
 * 调用设备能力（通过网关 invoke API，Phase 4.7）
 * 无参能力直接调用；有参能力弹出参数输入
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
    if (!r.ok) alert(`能力「${meta.title}」执行失败：${r.ack?.error || '未知错误'}`);
  } catch (e) {
    alert(`能力「${meta.title}」调用失败：${e.message}`);
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
  renderCapOps($('focusOpsCap'), deviceCaps(d));
  renderCapOps($('opsMenuCap'), deviceCaps(d));
  // 缓存设备元数据供配置面板使用
  focus.capMetadata = deviceCaps(d);
  focus.configSchema = d.configSchema || [];
  if (window.matchMedia('(max-width: 900px)').matches) $('fab').classList.remove('hidden');
  const grp = $('chkFocusBroadcast').checked ? wallSession : '';
  const broadcast = $('chkFocusBroadcast').checked ? '1' : '';
  focus = { device: d, rfb: createRfb(stage, d, { grp, broadcast, ctrl: true }, $('focusStatus')) };
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
  // 退出 focus：恢复卡片墙 RFB 连接（Phase 12.1，v2.3 恢复）
  startWallRfb(inst);
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
    if (!inst.rfb) { // RFB 未连接，启动它（Phase 12.1，v2.3 恢复）
      tv.innerHTML = '<div class="offline-ph">连接中…</div>';
      startWallRfb(inst);
    }
  } else {
    tile.classList.add('tile-offline');
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
 */
async function showConfigPanel() {
  if (!focus || !focus.device) return;
  const dev = focus.device;
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
  const groups = configSchemaByReload({ configSchema: focus.configSchema });
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
  rfb.addEventListener('disconnect', (e) => {
    setStatus('已断开');
    const code = e && e.detail && e.detail.code;
    if (code === 4001) alert('设备已被其它端接管，已中断控制');
    else if (code === 4003) alert('设备未注册（无隧道），无法控制。请在手机 App 中配置网关并完成注册');
  });
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

/**
 * 显示卡片右下角⋯菜单（Phase 10.3：按 category 分组，能力+管理操作合并）
 * 菜单分两段：上半段为设备能力（按 category 分组渲染，点击调用 doInvoke）；
 * 下半段为管理操作（查看/控制、详情、编辑、测试在线、删除）。
 * @param {HTMLElement} tile 卡片元素（用于定位菜单）
 * @param {object} d 设备对象
 * @param {number} x 点击位置 clientX
 * @param {number} y 点击位置 clientY
 * @returns {void}
 */
function showTileMenu(tile, d, x, y) {
  const m = $('tileMenu');
  m.innerHTML = '';

  // 1) 能力分组（按 category 分组渲染，Phase 10.3）
  const grouped = groupByCategory(deviceCaps(d));
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
    } else if (a === 'del') {
      if (confirm(`删除设备 ${d.name}？`)) {
        await api(`/api/devices/${encodeURIComponent(d.id)}`, { method: 'DELETE' });
        const inst = wallInstances.get(d.id);
        if (inst) { stopWallRfb(inst); inst.tile.remove(); wallInstances.delete(d.id); }
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
    const b = getSafeBounds();
    fab.style.left = Math.max(b.minX, Math.min(nx, b.maxX)) + 'px';
    fab.style.top = Math.max(b.minY, Math.min(ny, b.maxY)) + 'px';
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
// 批量操作按钮（Phase 10.2）：勾选≥1 台设备后点击弹出批量菜单
$('batchBtn').addEventListener('click', (e) => {
  e.stopPropagation();
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
  focus.rfb = createRfb(stage, d, { grp, broadcast, ctrl: true }, $('focusStatus'));
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

// ===== 布局切换：横屏1-6列 / 竖屏1-6列（手机端布局按钮，与 PC 端尺寸调节阀为同一组件两态） =====
const layoutBtn = $('layoutBtn');
const layoutMenu = $('layoutMenu');
const wallEl = $('wall');

/**
 * 应用布局到设备墙：切换横竖屏方向 + 设置列数
 * @param {string} v - 布局标识，格式 'h1'..'h6'（横屏1-6列）/ 'v1'..'v6'（竖屏1-6列）
 * @returns {void}
 */
function applyLayout(v) {
  const n = parseInt(v.slice(1), 10);
  const isH = v.charAt(0) === 'h';
  wallEl.classList.toggle('layout-h', isH);
  wallEl.classList.toggle('layout-v', !isH);
  wallEl.style.gridTemplateColumns = 'repeat(' + n + ', 1fr)';
  layoutMenu.querySelectorAll('.lopt').forEach((o) => {
    o.classList.toggle('sel', o.dataset.l === v);
  });
}

// 初始化默认布局为竖屏 2 列
applyLayout('v2');

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
