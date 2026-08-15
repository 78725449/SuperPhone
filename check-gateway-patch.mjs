// 验证网关 serve 的 noVNC patch 生效
import https from 'node:https';
const agent = new https.Agent({ rejectUnauthorized: false });

function get(url) {
  return new Promise((resolve, reject) => {
    https.get(url, { agent }, (res) => {
      let d = '';
      res.on('data', (c) => d += c);
      res.on('end', () => resolve(d));
    }).on('error', reject);
  });
}

const rfb = await get('https://localhost:8080/novnc/core/rfb.js');
console.log('rfb.js 长按 0x1 (按下):', rfb.includes('this._handleMouseButton(pos.x, pos.y, 0x1);'));
const m04 = rfb.match(/pos\.y, 0x4\);/g);
console.log('rfb.js 残留 0x4:', m04 ? m04.length : 0);

const gh = await get('https://localhost:8080/novnc/core/input/gesturehandler.js?v=3');
console.log('gesturehandler 移除 __farmPasteLongPress:', !gh.includes('__farmPasteLongPress'));
console.log('gesturehandler passive:false:', gh.includes('passive: false'));

const app = await get('https://localhost:8080/web/app.js?v=71');
console.log('app.js v71 半透明灰圆:', app.includes('APPLE_CURSOR_SIZE') && app.includes('169'));
