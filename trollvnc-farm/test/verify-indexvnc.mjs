// 验证 5801 直连页 index.vnc 方案 A 改造（能力对齐 + down/up 连发 + fit 移除 + caps.js 元数据同步）
// 2026-08-14 追加：图标 SVG 对齐网关 + 移除「收起菜单」按钮 + kb 键「隐藏键盘」开关（默认红色隐藏被控设备键盘）
import fs from 'fs';
import { spawnSync } from 'child_process';

const WC = 'C:/Users/Administrator/Documents/ChatGPT/New project/TrollVNC/layout/usr/share/trollvnc/webclients';
const s = fs.readFileSync(WC + '/index.vnc', 'utf8');
const m = s.match(/<script type="module">([\s\S]*?)<\/script>/);
if (!m) { console.log('FAIL: module script not found'); process.exit(1); }

// 语法检查（提取脚本写临时 .mjs 用 node --check）
const tmp = WC + '/_tmpcheck.mjs';
fs.writeFileSync(tmp, m[1]);
const r = spawnSync(process.execPath, ['--check', tmp], { encoding: 'utf8' });
fs.unlinkSync(tmp);
console.log('syntax check:', r.status === 0 ? 'PASS' : 'FAIL\n' + r.stderr);

// 顺序断言（与网关 KEY_DEFS 对齐）
console.log('power above home:', s.indexOf("op: 'power'") < s.indexOf("op: 'home'"));
console.log('mute above voldn:', s.indexOf("op: 'mute'") < s.indexOf("op: 'voldn'"));
console.log('snapshot above spotlight:', s.indexOf("op: 'snapshot'") < s.indexOf("op: 'spotlight'"));
console.log('kb after spotlight:', s.indexOf("op: 'spotlight'") < s.indexOf("op: 'kb'"));

// 增删断言
console.log('snapshot present:', s.includes("op: 'snapshot'"));
console.log('spotlight present:', s.includes("op: 'spotlight'"));
console.log('fit removed:', !s.includes("op: 'fit'") && !s.includes("case 'fit'"));
console.log('snapshot keysym:', s.includes("tapKey(0x1008ff80, 'CustomSnapshot')"));
console.log('spotlight keysym:', s.includes("tapKey(0x1008ff1d, 'XF86Search')"));
// 图标/文案对齐（2026-08-14：SF Symbols SVG + 网关 title 一致）
console.log('BAR_KEYS svg icons present:', s.includes("op: 'power'") && s.includes("svg: '<svg viewBox=\"0 0 24 24\""));
console.log('home label aligned:', s.includes("label: 'Home'"));
console.log('snapshot label aligned:', s.includes("label: '截屏'"));
// 收起菜单按钮移除（2026-08-14）
console.log('panel-close removed:', !s.includes('panel-close'));
// 软键盘（2026-08-15 实时打字方案：input/composition 事件驱动，无 Keyboard 实例/无 touchKb）
console.log('kbInput element present:', s.includes('id="kbInput"'));
console.log('Keyboard import removed:', !s.includes("import Keyboard"));
console.log('no touchKb / new Keyboard:', !s.includes('touchKb') && !s.includes('new Keyboard'));
console.log('input-event kbd present:', s.includes('function kbdSendChar') && s.includes('function kbdForwardText') && s.includes('kbdComposing'));
console.log('no legacy keyInput diff:', !s.includes('kbOnInput') && !s.includes('kbReset') && !s.includes('keysyms.lookup'));
// 「键盘」键 = 显示/隐藏控制端软键盘（2026-08-14 对齐原生 noVNC「Show Keyboard」，无输入源切换/无 attach hack）
console.log('kbdSoft default false:', s.includes('var kbdSoft = false'));
console.log('kbdBtns var:', s.includes('var kbdBtns = []'));
console.log('no kbdControl two-state:', !s.includes('var kbdControl') && !s.includes('kbdControl ='));
console.log('no attach protocol keysym:', !s.includes('tapKey(0x1008ff83') && !s.includes('tapKey(0x1008ff84'));
console.log('no auto-popup on connect:', !s.includes('if (isTouch) { focusKbInput(); kbdSoft = true; }'));
console.log('toggleKbd/updateKbdBtns/focusKbInput present:', s.includes('function toggleKbd') && s.includes('function updateKbdBtns') && s.includes('function focusKbInput'));
console.log('kb case routes to toggleKbd:', s.includes("case 'kb'") && s.includes('toggleKbd()'));
console.log('toggle = kbdSoft blur/focus (native):', s.includes('if (kbdSoft) {') && s.includes('blurKbInput();') && s.includes('focusKbInput();'));
console.log('iOS reliable dismiss (readonly trick):', s.includes("kbi.setAttribute('readonly', 'readonly')") && s.includes("kbi.removeAttribute('readonly')"));
console.log('connect resets kbdSoft:', s.includes('kbdSoft = false;'));
console.log('kbd-on highlight (no kbd-control/device):', s.includes('.kbd-on') && !s.includes('.kbd-control') && !s.includes('.kbd-device'));
console.log('no pagehide attach restore:', !s.includes('XF86KeyboardShow'));
console.log('paste overlay kept:', s.includes('id="clipOverlay"') && s.includes('function pasteToDevice') && s.includes("pasteToDevice(t)"));

// down/up 连发断言
console.log('DOWNUP_KEYS present:', s.includes('var DOWNUP_KEYS'));
console.log('attachKeyPressDownUp present:', s.includes('function attachKeyPressDownUp'));
console.log('DOWNUP_KEYS 5 键:', (s.match(/volup:|voldn:|mute:|briup:|bridn:/g) || []).length >= 5);

// caps.js 元数据同步
const c = fs.readFileSync(WC + '/caps.js', 'utf8');
console.log('caps.js snapshot meta:', c.includes("snapshot:  { op: 'snapshot'"));
console.log('caps.js spotlight meta:', c.includes("spotlight: { op: 'spotlight'"));
console.log('caps.js home label aligned:', c.includes("label: 'Home'"));
console.log('caps.js snapshot label aligned:', c.includes("label: '截屏'"));
