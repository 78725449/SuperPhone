// 验证网关 gesturehandler patch：阈值 12 + coalesced + 无 farm 残留
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
const gh = await get('https://localhost:8080/novnc/core/input/gesturehandler.js?v=4');
console.log('GH_MOVE_THRESHOLD 12:', gh.includes('const GH_MOVE_THRESHOLD = 12;'));
console.log('coalesced touchmove:', gh.includes('getCoalescedEvents'));
console.log('无 __farmPasteLongPress:', !gh.includes('__farmPasteLongPress'));
const app = await get('https://localhost:8080/web/app.js?v=72');
console.log('app.js v72 深灰128:', app.includes('rgba[i] = 128'));
