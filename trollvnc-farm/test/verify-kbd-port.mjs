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

// 软键盘基座（2026-08-16：英文/数字走 kbdSendAscii 键值直发 + 中文/emoji 走 kbdCommitText 粘贴，
// input/composition/keydown 事件驱动，无 Keyboard 实例/无旧逐键函数）
console.log('no Keyboard import:', !a.includes("import Keyboard"));
console.log('kbdInput element in html:', h.includes('id="kbdInput"'));
console.log('initTouchKeyboard present:', a.includes('function initTouchKeyboard') && a.includes('initTouchKeyboard()'));
console.log('kbdCommitText paste present:', a.includes('function kbdCommitText') && a.includes('kbdComposing'));
console.log('kbdSendAscii key-event present:', a.includes('function kbdSendAscii') && a.includes('rfb.sendKey(baseSym, null, true)'));
console.log('kbdSendAscii shift signal:', a.includes("rfb.sendKey(0xffe1, 'ShiftLeft', true)"));
// P1/P2（2026-08-16）：Shift 状态跟踪消除交错 + kbdSendSpecial 对齐 60ms 按住
console.log('P1 kbdShiftHeld state:', a.includes('kbdShiftHeld') && a.includes('kbdShiftTimer'));
console.log('P1 release/reset shift fn:', a.includes('function releaseKbdShift') && a.includes('function resetKbdShiftTimer'));
console.log('P1 shift-up out of char-up:', !a.includes("if (shift) rfb.sendKey(0xffe1, 'ShiftLeft', false)"));
console.log('P2 kbdSendSpecial 60ms:', /rfb\.sendKey\(keysym, code \|\| null, true\);\s*setTimeout/.test(a));
console.log('no old per-key kbdSendChar:', !a.includes('function kbdSendChar') && !a.includes('function kbdForwardText') && !a.includes('function kbdCommitBuffer'));
console.log('delete via Backspace keysym:', a.includes('kbdSendSpecial(0xff08') && a.includes('Backspace'));
console.log('enter via keydown + XK_Return:', a.includes("kbi.addEventListener('keydown'") && a.includes('kbdSendSpecial(0xff0d'));
console.log('no insertLineBreak dead branch:', !a.includes("dt === 'insertLineBreak'"));
console.log('no touchKb / new Keyboard:', !a.includes('touchKb') && !a.includes('new Keyboard'));

// 「键盘」键 = 两态开关（2026-08-16）：'control' 收起原生+拉起控制端 / 'device' 用被控端原生键盘
console.log('no kbdSoft:', !a.includes('kbdSoft'));
console.log('no kbdBtns:', !a.includes('kbdBtns'));
console.log('no kbdControl two-state:', !a.includes('let kbdControl') && !a.includes('kbdControl ='));
console.log('no attach protocol fns:', !a.includes('sendXf86KeyboardHide') && !a.includes('sendXf86KeyboardShow') && !a.includes('sendXf86Keyboard('));
console.log('isTouchable present:', a.includes("const isTouchable = () => 'ontouchstart' in window"));
console.log('no kbdMode/toggleKbdMode:', !a.includes('kbdMode') && !a.includes('function toggleKbdMode'));
console.log('no old toggleKbd:', !a.includes('function toggleKbd(') && !a.includes('function updateKbdBtns'));
console.log('keyboard key one-shot XF86Keyboard:', a.includes("k.key === 'keyboard'") && a.includes('kbdSendSpecial(0x1008ff2e'));
console.log('keyboard key touch focusKbdInput:', a.includes("k.key === 'keyboard'") && a.includes('isTouchable()') && a.includes('focusKbdInput()'));
console.log('focusKbdInput present:', a.includes('function focusKbdInput'));
console.log('iOS reliable dismiss (readonly trick):', a.includes("kbi.setAttribute('readonly', 'readonly')") && a.includes("kbi.removeAttribute('readonly')"));
console.log('no kbd-device-mode css:', !css.includes('.kbd-device-mode'));
console.log('exitFocus still blurKbdInput:', a.includes('blurKbdInput();'));
console.log('no pagehide attach restore:', !a.includes('sendXf86KeyboardShow'));
console.log('non-key keys keep rfbPressKey:', a.includes("rfbPressKey(rfb, k, capId)"));
console.log('caps.js version bumped:', a.includes("./caps.js?v=4"));
