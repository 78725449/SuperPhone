// 验证网关控制台控制端软键盘移植 + 「键盘」输入源三态切换（2026-08-14：无键盘→控制端软键盘→被控设备键盘）
import fs from 'fs';
import { spawnSync } from 'child_process';

const WEB = 'C:/Users/Administrator/Documents/ChatGPT/New project/trollvnc-farm/web';
const a = fs.readFileSync(WEB + '/app.js', 'utf8');
const h = fs.readFileSync(WEB + '/index.html', 'utf8');
const css = fs.readFileSync(WEB + '/style.css', 'utf8');

// app.js 语法检查（复制到临时 .mjs 用 node --check；import 带 ?v= 是合法 specifier，不解析）
const tmp = WEB + '/_check.mjs';
fs.writeFileSync(tmp, a);
const r = spawnSync(process.execPath, ['--check', tmp], { encoding: 'utf8' });
fs.unlinkSync(tmp);
console.log('app.js syntax check:', r.status === 0 ? 'PASS' : 'FAIL\n' + r.stderr);

// 软键盘基座（Keyboard 实例绑定隐藏 input）
console.log('Keyboard import:', a.includes("import Keyboard from '/novnc/core/input/keyboard.js?v=2'"));
console.log('kbdInput element in html:', h.includes('id="kbdInput"'));
console.log('initTouchKeyboard present:', a.includes('function initTouchKeyboard') && a.includes('initTouchKeyboard()'));
console.log('touchKb binding:', a.includes('new Keyboard(kbi)') && a.includes('touchKb.onkeyevent') && a.includes('touchKb.grab()'));
console.log('touchKb forwards to focus.rfb:', a.includes('rfb.sendKey(keysym, code, down)'));

// 「键盘」键 = 显示/隐藏控制端软键盘（2026-08-14 对齐原生 noVNC「Show Keyboard」，无输入源切换/无 attach hack）
console.log('kbdSoft default false:', a.includes('let kbdSoft = false'));
console.log('kbdBtns var:', a.includes('let kbdBtns = []'));
console.log('no kbdControl two-state:', !a.includes('let kbdControl') && !a.includes('kbdControl ='));
console.log('no attach protocol fns:', !a.includes('sendXf86KeyboardHide') && !a.includes('sendXf86KeyboardShow') && !a.includes('sendXf86Keyboard('));
console.log('isTouchable only for auto-popup:', a.includes("const isTouchable = () => 'ontouchstart' in window"));
console.log('toggleKbd/updateKbdBtns present:', a.includes('function toggleKbd') && a.includes('function updateKbdBtns'));
console.log('keyboard key routes to toggleKbd:', a.includes("k.key === 'keyboard'") && a.includes('toggleKbd()'));
console.log('toggle = kbdSoft blur/focus (native):', a.includes('if (kbdSoft) {') && a.includes('blurKbdInput();') && a.includes('focusKbdInput();'));
console.log('iOS reliable dismiss (readonly trick):', a.includes("kbi.setAttribute('readonly', 'readonly')") && a.includes("kbi.removeAttribute('readonly')"));
console.log('blur resets kbdSoft:', a.includes('kbdSoft = false;') && a.includes('updateKbdBtns()'));
console.log('kbd-on highlight css (no kbd-control/device):', css.includes('.kbd-on') && !css.includes('.kbd-control') && !css.includes('.kbd-device'));
console.log('enterFocus resets kbdSoft:', a.includes('kbdSoft = false; kbdBtns = []'));
console.log('exitFocus resets kbdSoft:', a.includes('kbdSoft = false; kbdBtns = [];'));
console.log('no pagehide attach restore:', !a.includes('sendXf86KeyboardShow'));
console.log('non-key keys keep rfbPressKey:', a.includes("rfbPressKey(rfb, k, capId)"));
console.log('caps.js version bumped:', a.includes("./caps.js?v=4"));
