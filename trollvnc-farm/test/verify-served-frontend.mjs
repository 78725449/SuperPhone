// 验证网关当前提供的前端版本与 rfb.js patch 内容（临时诊断脚本）
import https from 'https';
const get = (p) => new Promise((r) => {
  https.get({ host: '127.0.0.1', port: 8080, path: p, rejectUnauthorized: false }, (res) => {
    let d = '';
    res.on('data', (c) => (d += c));
    res.on('end', () => r({ status: res.statusCode, d }));
  }).on('error', (e) => r({ err: e.message }));
});
(async () => {
  const idx = await get('/');
  const m = idx.d.match(/app\.js\?v=(\d+)/);
  console.log('index.html status:', idx.status, '| app.js?v=', m ? m[1] : 'NOT FOUND');
  const app = await get('/app.js?v=' + (m ? m[1] : ''));
  console.log('app.js status:', app.status, '| has rfb.js?v=2:', app.d.includes('/novnc/core/rfb.js?v=2'));
  const rfb = await get('/novnc/core/rfb.js?v=2');
  console.log('rfb.js?v=2 status:', rfb.status, '| has 7×7:', rfb.d.includes('7×7 圆点'), '| bytes:', rfb.d.length);
  // 2026-08-15：聚焦画布漂移根因——noVNC _screen overflow:auto 滚动条出现触发浏览器自动滚动，
  // canvas margin:auto 与外部绝对定位居中冲突；patch 改为 hidden + margin 0（见 server/index.js）
  console.log('rfb.js overflow=hidden:', rfb.d.includes("this._screen.style.overflow = 'hidden'"),
              '| margin=0:', rfb.d.includes("this._canvas.style.margin = '0'"),
              '| no overflow=auto:', !rfb.d.includes("this._screen.style.overflow = 'auto'"));
})();
