// 验证切回前台剪贴板同步 + 重连（2026-08-14）
const https = await import('node:https');
const g = (u) => new Promise((r, j) => https.get(u, { rejectUnauthorized: false }, (res) => {
  let d = ''; res.on('data', (c) => (d += c)); res.on('end', () => r(d));
}).on('error', j));

const h = await g('https://localhost:8080/');
const a = await g('https://localhost:8080/app.js?v=75');

console.log(h.includes('app.js?v=75') ? 'PASS  index.html ?v=75' : 'FAIL  index.html');
const checks = {
  'consumePendingClip 函数': a.includes('function consumePendingClip'),
  'trySyncClipboardOnResume 函数': a.includes('async function trySyncClipboardOnResume'),
  'iOS 排除（避免横幅）': a.includes('isIOS) return;') || a.includes('if (isIOS) return;'),
  'connect 事件消费 pending': a.includes('consumePendingClip(rfb);'),
  'visibilitychange 调用切回同步': a.includes('trySyncClipboardOnResume();'),
  '重连成功也尝试同步': a.includes('setTimeout(fitFocusPanel, 300);\n    trySyncClipboardOnResume'),
};
for (const [k, v] of Object.entries(checks)) console.log(`${v ? 'PASS' : 'FAIL'}  ${k}`);
