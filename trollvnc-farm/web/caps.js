// 能力即服务前端驱动（2026-08-13 重构：无上报、无元数据表，前端自包含定义 + 直接发送）
// 原则：IPA 注册表仅存 executor；前端按需直接编写每个能力的调用实现（类似 KEY_DEFS 右侧按键模式）。
// 新增能力/参数 = 设备端注册 executor + 前端定义数组加一条（两端约定对齐，不做运行时发现）。
// 传输通道：按键走 RFB 直发（KEY_DEFS ks/code/ptr）；其余走 invoke API（网关隧道直达设备 executor）。

/** 右侧按键直发映射（RFB 通道，07 §4.1）：ks/code 为 X11 keysym 直发，ptr 为指针掩码（仅 power 用中键）
 *  图标：内联 SVG（苹果 SF Symbols 风格，stroke=currentColor 跟随主题色），无 SVG 时回退 emoji */
export const KEY_DEFS = [
  { key: 'home', title: 'Home 键', icon: '🏠',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 10.5L12 3l9 7.5"/><path d="M5 9.5V20h14V9.5"/><path d="M9.5 20v-5.5h5V20"/></svg>',
    ks: 0xff50, code: 'Home', events: { click: 'home', double: 'home.double', long: 'home.long' } },
  { key: 'power', title: '电源', icon: '⏻',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v8"/><path d="M18.4 6.6a9 9 0 1 1-12.8 0"/></svg>',
    ptr: 2, events: { click: 'power', double: 'power.double', triple: 'power.triple', long: 'power.long' } },
  { key: 'volup', title: '音量 +', icon: '🔊',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9v6h3l5 4V5L7 9H4z"/><path d="M15.5 8.5a4.5 4.5 0 0 1 0 7"/><path d="M19 4v6M16 7h6"/></svg>',
    ks: 0x1008ff13, code: 'AudioVolumeUp', events: { click: 'volup', down: 'volup.down', up: 'volup.up' } },
  { key: 'voldn', title: '音量 −', icon: '🔉',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9v6h3l5 4V5L7 9H4z"/><path d="M15.5 8.5a4.5 4.5 0 0 1 0 7"/><path d="M16 7h6"/></svg>',
    ks: 0x1008ff11, code: 'AudioVolumeDown', events: { click: 'voldn', down: 'voldn.down', up: 'voldn.up' } },
  { key: 'mute', title: '静音', icon: '🔇',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9v6h3l5 4V5L7 9H4z"/><path d="M22 4L4 20"/></svg>',
    ks: 0x1008ff12, code: 'AudioVolumeMute', events: { click: 'mute', down: 'mute.down', up: 'mute.up' } },
  { key: 'briup', title: '亮度 +', icon: '☀️',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4.5"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>',
    ks: 0x1008ff03, code: 'BrightnessUp', events: { click: 'briup', down: 'briup.down', up: 'briup.up' } },
  { key: 'bridn', title: '亮度 −', icon: '🌙',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3 7 7 0 0 0 21 12.8z"/></svg>',
    ks: 0x1008ff02, code: 'BrightnessDown', events: { click: 'bridn', down: 'bridn.down', up: 'bridn.up' } },
  { key: 'keyboard', title: '键盘', icon: '⌨️',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="6.5" width="19" height="11" rx="2"/><path d="M6 11h1M10 11h1M14 11h1M18 11h1M6 14.5h1M10 14.5h1M14 14.5h1M18 14.5h1"/></svg>',
    ks: 0x1008ff2e, code: 'XF86Keyboard', events: { click: 'keyboard' } },
  { key: 'spotlight', title: '搜索', icon: '🔍',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.5-4.5"/></svg>',
    ks: 0x1008ff1d, code: 'XF86Search', events: { click: 'spotlight' } },
  { key: 'snapshot', title: 'Home+Power截屏', icon: '📸',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h2.5L8 5.5h8L17.5 8H20a1.5 1.5 0 0 1 1.5 1.5V18A1.5 1.5 0 0 1 20 19.5H4A1.5 1.5 0 0 1 2.5 18V9.5A1.5 1.5 0 0 1 4 8z"/><circle cx="12" cy="13.5" r="3.5"/></svg>',
    ks: 0x1008ff80, code: 'CustomSnapshot', events: { click: 'snapshot' } },
  { key: 'hwlock', title: '键盘锁/解锁', icon: '🔒',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="4.5" y="10.5" width="15" height="10" rx="2"/><path d="M8 10.5v-3a4 4 0 0 1 8 0v3"/><circle cx="12" cy="15" r="1.5" fill="currentColor" stroke="none"/></svg>',
    ks: 0x1008ff81, code: 'CustomHwLock', events: { click: 'hwlock' } },
  { key: 'releasekeys', title: '释放按键', icon: '🙊',
    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="9" width="18" height="9" rx="2"/><path d="M6.5 13h1M10 13h1M13.5 13h1M17 13h1M7 16h10"/><path d="M12 2v5M9.5 4.5L12 2l2.5 2.5"/></svg>',
    ks: 0x1008ff82, code: 'CustomReleaseKeys', events: { click: 'releasekeys' } },
];

/** 动作区能力（控制台，点击 invoke 直达设备 executor）——自包含定义
 *  2026-08-13 精简：删 type.text（屏幕直接打字，仅 ASCII 无场景）、clipboard.set（并入 type.paste 内部流程）、
 *  screenshot 按钮（能力保留供卡片墙内部拉图，动作区无需手动截图）；保留 type.paste（跨设备粘贴，弹窗自动捕获
 *  控制端剪贴板 Ctrl+V/长按粘贴）+ clipboard.get（远程读设备剪贴板窄场景） */
export const ACT_DEFS = [
  { id: 'type.paste',  title: '粘贴输入',   icon: '📋', params: [{ name: 'text', type: 'string', required: true }] },
  { id: 'clipboard.get', title: '获取剪贴板', icon: '📋', params: [] },
];

/** 卡片 ⋯ 菜单「常用能力」（点击 invoke 直达设备）——自包含定义 */
export const QUICK_ACTIONS = [
  { id: 'service.restart', title: '重启服务', icon: '🔄', params: [] },
];

/** 批量「调用能力」清单（含 category 供分组渲染；点击 batchInvoke）——自包含定义，固化现状批量菜单能力 */
export const BATCH_CAPS = [
  { id: 'home',          title: 'Home 键',   icon: '🏠', category: 'hid', params: [] },
  { id: 'power',         title: '电源',      icon: '⏻',  category: 'hid', params: [] },
  { id: 'volup',         title: '音量 +',    icon: '🔊', category: 'hid', params: [] },
  { id: 'voldn',         title: '音量 −',    icon: '🔉', category: 'hid', params: [] },
  { id: 'mute',          title: '静音',      icon: '🔇', category: 'hid', params: [] },
  { id: 'briup',         title: '亮度 +',    icon: '☀️', category: 'hid', params: [] },
  { id: 'bridn',         title: '亮度 −',    icon: '🌙', category: 'hid', params: [] },
  { id: 'keyboard',      title: '键盘',      icon: '⌨️', category: 'hid', params: [] },
  { id: 'spotlight',     title: '搜索',      icon: '🔍', category: 'hid', params: [] },
  { id: 'home.double',   title: '双击Home',  icon: '🏠', category: 'hid', params: [] },
  { id: 'home.long',     title: '长按Home',  icon: '🏠', category: 'hid', params: [] },
  { id: 'power.double',  title: '双击电源',  icon: '⏻',  category: 'hid', params: [] },
  { id: 'power.triple',  title: '三击电源',  icon: '⏻',  category: 'hid', params: [] },
  { id: 'power.long',    title: '长按电源',  icon: '⏻',  category: 'hid', params: [] },
  { id: 'hwlock',        title: '硬件键盘锁', icon: '🔒', category: 'hid', params: [] },
  { id: 'hwunlock',      title: '硬件键盘解锁', icon: '🔓', category: 'hid', params: [] },
  { id: 'releasekeys',   title: '释放所有按键', icon: '🙊', category: 'hid', params: [] },
  { id: 'service.restart', title: '重启服务', icon: '🔄', category: 'service', params: [] },
  { id: 'settings.generateKeys', title: '生成证书', icon: '🔐', category: 'native', params: [] },
  { id: 'settings.searchGateway', title: '搜索网关', icon: '🔍', category: 'native', params: [] },
  { id: 'clients.count',  title: '客户端数量', icon: '🔢', category: 'system', params: [] },
  { id: 'clients.list',   title: '客户端列表', icon: '📋', category: 'system', params: [] },
  { id: 'clients.disconnect', title: '断开客户端', icon: '🔌', category: 'system', params: [{ name: 'clientId', type: 'string', required: true }] },
  { id: 'clients.block',  title: '阻止客户端', icon: '🚫', category: 'system', params: [{ name: 'clientId', type: 'string', required: true }] },
  { id: 'clients.unblock',title: '解除阻止', icon: '✅', category: 'system', params: [{ name: 'host', type: 'string', required: true }] },
  { id: 'clients.blocked.list', title: '黑名单列表', icon: '📜', category: 'system', params: [] },
  { id: 'sys.version',    title: '版本信息', icon: '🏷️', category: 'native', params: [] },
  { id: 'sys.resolution', title: '屏幕分辨率', icon: '📐', category: 'native', params: [] },
  { id: 'sys.rotation',   title: '当前旋转', icon: '🔄', category: 'native', params: [] },
  { id: 'sys.bonjour.txt',title: 'Bonjour TXT', icon: '📡', category: 'native', params: [] },
  { id: 'gateway.isConnected', title: '网关状态', icon: '🟢', category: 'gateway', params: [] },
  { id: 'gateway.reconnect',   title: '手动重连', icon: '🔌', category: 'gateway', params: [] },
];

/** 配置表单定义（契约）：与设备端 _registerConfigSchemas 对齐（37 项全量保留——均有真实实现） */
export const CONFIG_DEFS = [
  { key: 'Scale', title: '输出缩放', type: 'number', min: 0.1, max: 1.0, step: 0.1, reload: 'hot' },
  { key: 'FrameRateSpec', title: '帧率', type: 'string', reload: 'hot' },
  { key: 'OrientationSync', title: '方向同步', type: 'bool', reload: 'hot' },
  { key: 'OrientationPadFix', title: '方向偏移', type: 'enum', enumValues: [0, 1, 2, 3], enumTitles: ['禁用', '90°', '180°', '270°'], reload: 'hot' },
  { key: 'ServerCursor', title: '服务端光标', type: 'bool', reload: 'hot' },
  { key: 'DeferWindowSec', title: '延迟窗口', type: 'number', min: 0, max: 0.5, step: 0.005, reload: 'hot' },
  { key: 'MaxInflight', title: '最大并行帧', type: 'number', min: 0, max: 8, step: 1, reload: 'hot' },
  { key: 'PerformanceMode', title: '性能模式', type: 'enum', enumValues: ['balanced', 'quality', 'performance', 'custom'], enumTitles: ['均衡', '画质', '性能', '自定义'], reload: 'hot' },
  { key: 'TileSize', title: '分块大小', type: 'number', min: 8, max: 128, step: 1, reload: 'restart' },
  { key: 'FullscreenThresholdPercent', title: '脏区阈值', type: 'number', min: 0, max: 100, step: 1, reload: 'hot' },
  { key: 'MaxRects', title: '最大矩形数', type: 'number', min: 1, max: 4096, step: 1, reload: 'restart' },
  { key: 'AsyncSwap', title: '非阻塞交换', type: 'bool', reload: 'restart' },
  { key: 'ThumbInterval', title: '卡片墙帧获取间隔(秒)', type: 'number', min: 1, max: 60, step: 1, reload: 'instant' },
  { key: 'NaturalScroll', title: '自然滚动', type: 'bool', reload: 'instant' },
  { key: 'ModifierMap', title: '修饰键映射', type: 'enum', enumValues: ['std', 'altcmd'], enumTitles: ['标准', 'Alt→Cmd'], reload: 'hot' },
  { key: 'AutoAssistEnabled', title: '辅助触控', type: 'bool', reload: 'instant' },
  { key: 'WheelStepPx', title: '滚轮步进', type: 'number', min: 0, max: 1000, step: 1, reload: 'hot' },
  { key: 'WheelTuning', title: '滚轮调优', type: 'string', reload: 'hot' },
  { key: 'ViewOnly', title: '全局只读', type: 'bool', reload: 'instant' },
  { key: 'ClipboardEnabled', title: '剪贴板同步', type: 'bool', reload: 'instant' },
  { key: 'FullPassword', title: '完全访问密码', type: 'password', reload: 'restart' },
  { key: 'ViewOnlyPassword', title: '只读密码', type: 'password', reload: 'restart' },
  { key: 'BindHost', title: '绑定地址', type: 'string', reload: 'restart' },
  { key: 'BonjourEnabled', title: '自动发现', type: 'bool', reload: 'gateway' },
  { key: 'HttpDir', title: 'HTTP 根目录', type: 'string', reload: 'restart' },
  { key: 'Enabled', title: '服务启用', type: 'bool', reload: 'restart' },
  { key: 'GatewayHost', title: '网关地址', type: 'string', reload: 'gateway' },
  { key: 'GatewayToken', title: '网关令牌', type: 'password', reload: 'gateway' },
  { key: 'SslCertFile', title: 'SSL证书文件', type: 'string', reload: 'restart' },
  { key: 'SslKeyFile', title: 'SSL私钥文件', type: 'string', reload: 'restart' },
  { key: 'KeepAliveSec', title: '保活间隔', type: 'number', min: 0, max: 300, step: 1, reload: 'hot' },
  { key: 'Notifications', title: '通知模式', type: 'enum', enumValues: ['all', 'connectOnly', 'silent'], enumTitles: ['全部通知', '仅连接通知', '静默'], reload: 'instant' },
  { key: 'KeyLogging', title: '键盘日志', type: 'bool', reload: 'instant' },
  { key: 'WatchdogThrottleInterval', title: '重启节流间隔', type: 'number', min: 1, max: 300, step: 1, reload: 'hot' },
  { key: 'WatchdogKeepAlive', title: '崩溃自动重启', type: 'bool', reload: 'hot' },
  { key: 'WatchdogExitTimeout', title: '退出超时', type: 'number', min: 1, max: 60, step: 1, reload: 'hot' },
  { key: 'HIDKeepAliveInterval', title: 'HID防休眠间隔', type: 'number', min: 0, max: 300, step: 1, reload: 'hot' },
];
export const CONFIG_BY_KEY = new Map(CONFIG_DEFS.map((s) => [s.key, s]));

/** reload 分区标签（配置面板按此分区显示） */
export const RELOAD_LABELS = {
  instant: '立即生效', hot: '热重载', gateway: '网关刷新', restart: '需重启服务',
};

/** 能力 category 中文分组标题（批量菜单按 category 分组显示） */
export const CATEGORY_LABELS = {
  hid: '硬件按键', touch: '触控操作', stylus: '触控笔', system: '系统管理',
  native: '原生功能', service: '服务管理', gateway: '网关信息', control: '控制操作',
};

/**
 * 按能力元数据的 category 字段分组（批量菜单分组渲染）
 * @param {Array<object>} caps 自包含能力定义数组，每项含 { id, category, ... }
 * @returns {Map<string, Array<object>>} key=category, value=该 category 下的定义数组（保持插入顺序）
 */
export function groupByCategory(caps) {
  const map = new Map();
  if (!Array.isArray(caps)) return map;
  for (const meta of caps) {
    if (!meta || !meta.id) continue;
    const cat = meta.category || 'control';
    if (!map.has(cat)) map.set(cat, []);
    map.get(cat).push(meta);
  }
  return map;
}

/**
 * 按 reload 分区静态配置表单定义
 * @returns { instant: [], hot: [], gateway: [], restart: [] }
 */
export function configSchemaByReload() {
  const groups = { instant: [], hot: [], gateway: [], restart: [] };
  for (const item of CONFIG_DEFS) {
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

/** 卡片 ⋯ 菜单「常用参数」编排清单（QUICK_CONFIG_GROUPS：分组 + 键名，schema 从 CONFIG_DEFS 取） */
export const QUICK_CONFIG_GROUPS = [
  { title: '画面与性能', keys: ['Scale', 'FrameRateSpec', 'PerformanceMode'] },
  { title: '输入与交互', keys: ['ClipboardEnabled', 'ViewOnly', 'Notifications'] },
];
