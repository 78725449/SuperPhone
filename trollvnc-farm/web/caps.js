// 能力即服务前端驱动（Phase 4.7）
// 从 /api/devices/:id/caps 拉取元数据，自动渲染控制按钮（一级菜单）+ 配置表单（二级菜单）
// 不再硬编码 keysym；新增能力设备侧注册后前端自动渲染，无需改本文件

/** 兜底默认能力 ID（设备未上报 capMetadata 时用，与设备侧 TRCapabilityRegistry 对齐） */
export const DEFAULT_CAPS = ['home', 'power', 'volup', 'voldn', 'mute', 'briup', 'bridn', 'keyboard', 'clipboard.paste'];

/** 兜底能力元数据（设备未上报时用，保证前端可用） */
export const CAP_FALLBACK = {
  'home':            { id: 'home',            title: 'Home 键',  icon: '🏠', category: 'control', route: { type: 'hid' }, params: [] },
  'power':           { id: 'power',            title: '电源',     icon: '⏻',  category: 'control', route: { type: 'hid' }, params: [] },
  'volup':           { id: 'volup',            title: '音量 +',   icon: '🔊', category: 'control', route: { type: 'hid' }, params: [] },
  'voldn':           { id: 'voldn',            title: '音量 −',  icon: '🔉', category: 'control', route: { type: 'hid' }, params: [] },
  'mute':            { id: 'mute',             title: '静音',     icon: '🔇', category: 'control', route: { type: 'hid' }, params: [] },
  'briup':           { id: 'briup',            title: '亮度 +',  icon: '☀️', category: 'control', route: { type: 'hid' }, params: [] },
  'bridn':           { id: 'bridn',            title: '亮度 −',  icon: '🌙', category: 'control', route: { type: 'hid' }, params: [] },
  'keyboard':        { id: 'keyboard',         title: '键盘',     icon: '⌨️', category: 'control', route: { type: 'hid' }, params: [] },
  'clipboard.paste': { id: 'clipboard.paste',  title: '粘贴剪贴板', icon: '📋', category: 'control', route: { type: 'native' }, params: [] },
};

/** reload 分区标签（二级菜单按此分区显示） */
export const RELOAD_LABELS = {
  instant: '立即生效',
  hot: '热重载',
  gateway: '网关刷新',
  restart: '需重启服务',
};

/**
 * 能力 category 中文分组标题映射（Phase 10.3）
 * 用于能力菜单按 category 分组渲染时的分组标题显示
 */
export const CATEGORY_LABELS = {
  hid: '硬件按键',
  touch: '触控操作',
  stylus: '触控笔',
  system: '系统管理',
  native: '原生功能',
  service: '服务管理',
  gateway: '网关信息',
  control: '控制操作',  // 兜底
};

/**
 * 按能力元数据的 category 字段分组（Phase 10.3）
 * 用于 renderCapOps / showBatchMenu 渲染分组能力列表
 * @param {Array<object>} capMetadata 能力元数据数组，每项含 { id, category, ... }
 * @returns {Map<string, Array<object>>} key=category, value=该 category 下的 meta 数组（保持插入顺序）
 */
export function groupByCategory(capMetadata) {
  const map = new Map();
  if (!Array.isArray(capMetadata)) return map;
  for (const meta of capMetadata) {
    if (!meta || !meta.id) continue;
    const cat = meta.category || 'control';  // 兜底归入 control
    if (!map.has(cat)) map.set(cat, []);
    map.get(cat).push(meta);
  }
  return map;
}

/**
 * 从设备能力元数据中提取控制型能力清单
 * 设备上报 capMetadata 时用上报值，否则回退兜底
 * @param device 设备对象（含 capMetadata/capabilities）
 * @returns 控制型能力元数据数组
 */
export function deviceCaps(device) {
  if (device && Array.isArray(device.capMetadata) && device.capMetadata.length > 0) {
    return device.capMetadata.filter((c) => c && c.id);
  }
  // 回退：用 capabilities ID + 兜底元数据
  const ids = (device && Array.isArray(device.capabilities) && device.capabilities.length) ? device.capabilities : DEFAULT_CAPS;
  return ids.map((id) => CAP_FALLBACK[id]).filter(Boolean);
}

/**
 * 从设备 configSchema 中按 reload 分区
 * @param device 设备对象（含 configSchema）
 * @returns { instant: [], hot: [], gateway: [], restart: [] }
 */
export function configSchemaByReload(device) {
  const schema = (device && Array.isArray(device.configSchema)) ? device.configSchema : [];
  const groups = { instant: [], hot: [], gateway: [], restart: [] };
  for (const item of schema) {
    if (!item || !item.key) continue;
    const r = item.reload || 'instant';
    if (groups[r]) groups[r].push(item);
  }
  return groups;
}

/**
 * 调用设备能力（通过网关 invoke API）
 * @param apiBase 网关 API 基路径（如 ''）
 * @param deviceId 设备 ID
 * @param capId 能力 ID
 * @param params 参数对象
 * @returns { ok, ack } 结果
 */
export async function invokeCap(apiBase, deviceId, capId, params = {}) {
  const res = await fetch(`${apiBase}/api/devices/${encodeURIComponent(deviceId)}/invoke`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(window._farmAuthHeader || {}) },
    body: JSON.stringify({ cap: capId, params }),
  });
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

/**
 * 设置设备配置（通过网关 configs API）
 * @param apiBase 网关 API 基路径
 * @param deviceId 设备 ID
 * @param configs { key: value } 对象
 * @returns { results } 每个配置的设置结果
 */
export async function setConfigs(apiBase, deviceId, configs) {
  const res = await fetch(`${apiBase}/api/devices/${encodeURIComponent(deviceId)}/configs`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(window._farmAuthHeader || {}) },
    body: JSON.stringify(configs),
  });
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

/**
 * 批量调用能力（多台设备统一执行）
 * @param apiBase 网关 API 基路径
 * @param deviceIds 设备 ID 数组
 * @param capId 能力 ID
 * @param params 参数对象
 * @returns { cap, results: [{deviceId, ok, error}] }
 */
export async function batchInvoke(apiBase, deviceIds, capId, params = {}) {
  const res = await fetch(`${apiBase}/api/devices/batch/invoke`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(window._farmAuthHeader || {}) },
    body: JSON.stringify({ deviceIds, cap: capId, params }),
  });
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

/**
 * 批量设置配置（多台设备统一覆盖）
 * @param apiBase 网关 API 基路径
 * @param deviceIds 设备 ID 数组
 * @param configs { key: value } 对象
 * @returns { results: [{deviceId, results: {key: {ok, reload}}}] }
 */
export async function batchSetConfigs(apiBase, deviceIds, configs) {
  const res = await fetch(`${apiBase}/api/devices/batch/configs`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(window._farmAuthHeader || {}) },
    body: JSON.stringify({ deviceIds, configs }),
  });
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

/**
 * 批量重启（多台设备，前端需二次确认）
 * @param apiBase 网关 API 基路径
 * @param deviceIds 设备 ID 数组
 * @returns { results: [{deviceId, ok, error}] }
 */
export async function batchRestart(apiBase, deviceIds) {
  const res = await fetch(`${apiBase}/api/devices/batch/restart`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(window._farmAuthHeader || {}) },
    body: JSON.stringify({ deviceIds }),
  });
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

/**
 * 按键对象清单（07 §3.1/§4.1）：events 引用设备端能力 id，前端按按压模式翻译
 * ks/code/ptr 为 RFB 直发通道映射（与 5801 index.vnc dispatchOp 一致）：
 *   - ks   X11 keysym 数值，noVNC rfb.sendKey(keysym, code, down) 用
 *   - code noVNC 键码名（KeyTable 映射）
 *   - ptr  指针掩码（仅 power 用中键=2，模拟电源键；rfb.pointer 同款）
 * 控制台直连模式：12 键全部经 RFB 直发（无 keysym 回退能力链路）。
 * 系统动作键使用自定义 keysym（keyboard=0x1008ff2e / spotlight=0x1008ff1d /
 * snapshot=0x1008ff8a / hwlock=0x1008ff8b / releasekeys=0x1008ff8c），设备端
 * kbdAddEvent 映射到 STHIDEventGenerator API（toggleOnScreenKeyboard 等），
 * 单击执行（down 触发）、up 忽略。
 */
export const KEY_DEFS = [
  { key: 'home',    title: 'Home 键',  icon: '🏠', ks: 0xff50,       code: 'Home',            events: { click: 'home',           double: 'home.double',   long: 'home.long' } },
  { key: 'power',   title: '电源',     icon: '⏻',  ptr: 2,                                   events: { click: 'power',          double: 'power.double',  triple: 'power.triple', long: 'power.long' } },
  { key: 'volup',   title: '音量 +',   icon: '🔊', ks: 0x1008ff13,   code: 'AudioVolumeUp',   events: { click: 'volup',          down: 'volup.down',      up: 'volup.up' } },
  { key: 'voldn',   title: '音量 −',   icon: '🔉', ks: 0x1008ff11,   code: 'AudioVolumeDown', events: { click: 'voldn',          down: 'voldn.down',      up: 'voldn.up' } },
  { key: 'mute',    title: '静音',     icon: '🔇', ks: 0x1008ff12,   code: 'AudioVolumeMute', events: { click: 'mute',           down: 'mute.down',       up: 'mute.up' } },
  { key: 'briup',   title: '亮度 +',   icon: '☀️', ks: 0x1008ff03,   code: 'BrightnessUp',    events: { click: 'briup',          down: 'briup.down',      up: 'briup.up' } },
  { key: 'bridn',   title: '亮度 −',   icon: '🌙', ks: 0x1008ff02,   code: 'BrightnessDown',  events: { click: 'bridn',          down: 'bridn.down',      up: 'bridn.up' } },
  { key: 'keyboard',title: '键盘',     icon: '⌨️', ks: 0x1008ff2e,   code: 'Keyboard',        events: { click: 'keyboard' } },
  { key: 'spotlight',title: '搜索',    icon: '🔍', ks: 0x1008ff1d,   code: 'Search',          events: { click: 'spotlight' } },
  { key: 'snapshot',title: 'Home+Power截屏', icon: '📸', ks: 0x1008ff8a, code: 'Snapshot',   events: { click: 'snapshot' } },
  { key: 'hwlock',  title: '键盘锁/解锁', icon: '🔒', ks: 0x1008ff8b, code: 'HardwareLock',   events: { click: 'hwlock' } },
  { key: 'releasekeys', title: '释放按键', icon: '🙊', ks: 0x1008ff8c, code: 'ReleaseKeys',   events: { click: 'releasekeys' } },
];

/** 动作区固定能力 id（07 §4.1，从设备 capMetadata 取元数据渲染） */
export const ACTION_CAPS = ['type.text', 'type.paste', 'clipboard.get', 'clipboard.set', 'screenshot'];

/**
 * 按场景过滤设备能力（07 §3.3/§4）
 * @param device 设备对象
 * @param scope 'console' 控制台侧边栏/悬浮 | 'tile' 卡片菜单 | 'batch' 批量
 * @returns 过滤后的能力元数据数组
 */
export function menuCaps(device, scope) {
  const caps = deviceCaps(device);
  const byId = new Map(caps.filter((c) => c && c.id).map((c) => [c.id, c]));
  if (scope === 'console') {
    // 按键区：KEY_DEFS 的 events 引用的能力；动作区：ACTION_CAPS
    const ids = [...KEY_DEFS.flatMap((k) => Object.values(k.events)), ...ACTION_CAPS];
    return ids.map((id) => byId.get(id)).filter(Boolean);
  }
  if (scope === 'tile') {
    return caps.filter((c) => c && c.menu !== 'internal');
  }
  if (scope === 'batch') {
    return caps.filter((c) =>
      c && c.menu !== 'internal' && c.category !== 'touch' && c.category !== 'stylus'
      && !/screenshot|screen\.|clipboard|type\./i.test(c.id));
  }
  return caps;
}
