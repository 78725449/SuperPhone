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
// 软键盘（2026-08-16：英文/数字走 kbdSendAscii 键值直发 + 中文/emoji 走 kbdCommitText 粘贴）
console.log('kbInput element present:', s.includes('id="kbInput"'));
console.log('Keyboard import removed:', !s.includes("import Keyboard"));
console.log('no touchKb / new Keyboard:', !s.includes('touchKb') && !s.includes('new Keyboard'));
console.log('kbdCommitText paste present:', s.includes('function kbdCommitText') && s.includes('kbdComposing'));
console.log('kbdSendAscii key-event present:', s.includes('function kbdSendAscii') && s.includes('rfb.sendKey(baseSym, null, true)'));
console.log('kbdSendAscii shift signal:', s.includes("rfb.sendKey(0xffe1, 'ShiftLeft', true)"));
// P1/P2（2026-08-16）：Shift 状态跟踪消除交错 + kbdSendSpecial 对齐 60ms 按住
console.log('P1 kbdShiftHeld state:', s.includes('kbdShiftHeld') && s.includes('kbdShiftTimer'));
console.log('P1 release/reset shift fn:', s.includes('function releaseKbdShift') && s.includes('function resetKbdShiftTimer'));
console.log('P1 shift-up out of char-up:', !s.includes("if (shift) rfb.sendKey(0xffe1, 'ShiftLeft', false)"));
console.log('P2 kbdSendSpecial 60ms:', /rfb\.sendKey\(keysym, code \|\| null, true\);\s*\} catch \(e\) \{ return; \}\s*setTimeout/.test(s));
console.log('no old per-key kbdSendChar:', !s.includes('function kbdSendChar') && !s.includes('function kbdForwardText') && !s.includes('function kbdCommitBuffer'));
console.log('delete via Backspace keysym:', s.includes('kbdSendSpecial(0xff08') && s.includes('Backspace'));
console.log('enter via keydown + XK_Return:', s.includes("kbInput.addEventListener('keydown'") && s.includes('kbdSendSpecial(0xff0d'));
console.log('no insertLineBreak dead branch:', !s.includes("dt === 'insertLineBreak'"));
console.log('no legacy keyInput diff:', !s.includes('kbOnInput') && !s.includes('kbReset') && !s.includes('keysyms.lookup'));
// 「键盘」键 = 两态开关（2026-08-16）：'control' 收起原生+拉起控制端 / 'device' 用被控端原生键盘
console.log('no kbdSoft:', !s.includes('kbdSoft'));
console.log('no kbdBtns:', !s.includes('kbdBtns'));
console.log('no kbdControl two-state:', !s.includes('var kbdControl') && !s.includes('kbdControl ='));
console.log('no attach protocol keysym:', !s.includes('tapKey(0x1008ff83') && !s.includes('tapKey(0x1008ff84'));
console.log('no kbdMode/toggleKbdMode:', !s.includes('kbdMode') && !s.includes('function toggleKbdMode'));
console.log('no old toggleKbd:', !s.includes('function toggleKbd(') && !s.includes('function updateKbdBtns'));
console.log('kb case one-shot XF86Keyboard:', s.includes("case 'kb'") && s.includes("tapKey(0x1008ff2e, 'XF86Keyboard')"));
console.log('kb case touch focusKbInput:', s.includes("case 'kb'") && s.includes('isTouch') && s.includes('focusKbInput()'));
console.log('focusKbInput present:', s.includes('function focusKbInput'));
console.log('iOS reliable dismiss (readonly trick):', s.includes("kbi.setAttribute('readonly', 'readonly')") && s.includes("kbi.removeAttribute('readonly')"));
console.log('no kbd-device-mode css:', !s.includes('.kbd-device-mode'));
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
