// 验证：立即重连 + 5801 式连接浮层 + 去掉点卡片读剪贴板（2026-08-14）
const https = await import('node:https');
const g = (u) => new Promise((r, j) => https.get(u, { rejectUnauthorized: false }, (res) => {
  let d = ''; res.on('data', (c) => (d += c)); res.on('end', () => r(d));
}).on('error', j));

const h = await g('https://localhost:8080/');
const a = await g('https://localhost:8080/app.js?v=76');
const c = await g('https://localhost:8080/style.css');

console.log(h.includes('app.js?v=76') ? 'PASS  index.html ?v=76' : 'FAIL  index.html');
console.log(h.includes('focusStatusOv') ? 'PASS  index.html 浮层元素' : 'FAIL  浮层元素');
console.log(c.includes('.focus-status-ov') && c.includes('@keyframes spin') ? 'PASS  style.css 浮层样式+动画' : 'FAIL  style.css');
const checks = {
  '立即重连（首次直接 reconnectFocusRfb）': a.includes('reconnectFocusRfb(); // 首次：立即重连'),
  '无退避数组': !a.includes('FOCUS_RECONNECT_DELAYS'),
  '2s 防抖重试': a.includes('FOCUS_RECONNECT_DELAY = 2000'),
  'setFocusOverlay 函数': a.includes('function setFocusOverlay'),
  'enterFocus 显示连接浮层': a.includes("setFocusOverlay(true, '连接中…')"),
  'connect 隐藏浮层': a.includes('setFocusOverlay(false, null);'),
  'disconnect 显示重连提示': a.includes("setFocusOverlay(false, '画面已断开，正在重连…')"),
  '点卡片不再读剪贴板': !a.includes('let clipTxt = null'),
  'trySyncClipboardOnResume 保留': a.includes('async function trySyncClipboardOnResume'),
};
for (const [k, v] of Object.entries(checks)) console.log(`${v ? 'PASS' : 'FAIL'}  ${k}`);
