// 验证用户实际访问地址 https://10.0.0.111:8080 的响应内容（临时诊断）
import https from 'https';
const get = (host, p) => new Promise((r) => {
  https.get({ host, port: 8080, path: p, rejectUnauthorized: false }, (res) => {
    let d = '';
    res.on('data', (c) => (d += c));
    res.on('end', () => r({ status: res.statusCode, d }));
  }).on('error', (e) => r({ err: e.message }));
});
const host = '10.0.0.111';
const idx = await get(host, '/');
const m = idx.d.match(/app\.js\?v=(\d+)/);
console.log('index.html status:', idx.status, '| app.js?v=', m ? m[1] : 'NOT FOUND');
const rfb = await get(host, '/novnc/core/rfb.js?v=2');
console.log('rfb.js?v=2 status:', rfb.status, '| has 7×7:', rfb.d.includes('7×7 圆点'), '| bytes:', rfb.d.length);
const app = await get(host, '/app.js?v=56');
console.log('app.js?v=56 has rfb.js?v=2 import:', app.d.includes('/novnc/core/rfb.js?v=2'));
