// 验证 index.html 图标改动（同步=两台设备双向箭头 + 断开=红色完整锁链断裂线）
import fs from 'fs';
const h = fs.readFileSync('web/index.html', 'utf8');
const opens = (h.match(/<svg/g) || []).length;
const closes = (h.match(/<\/svg>/g) || []).length;
console.log('svg open/close:', opens, closes);
console.log('sync big+small device (master phone pair):',
  h.includes('<rect x="2" y="3.5" width="9.5" height="17" rx="2"/>') &&   // 大手机（主控）
  h.includes('<rect x="14" y="7" width="8" height="13" rx="1.8"/>') &&    // 小手机（被控）
  h.includes('M12.1 10.3l1.8 1.4-1.8 1.4') &&                             // 朝右箭头
  h.includes('M13.9 10.3l-1.8 1.4 1.8 1.4'));                              // 朝左箭头
console.log('broken chain (link break line) count:', (h.match(/M9.5 14.5l5-5/g) || []).length, '(expect 2)');
console.log('disc buttons danger class count:', (h.match(/data-op="disc" class="danger"/g) || []).length + (h.match(/data-op="disc" class="op danger"/g) || []).length, '(expect 2)');
console.log('old icons gone:',
  !h.includes('M20 12a8 8 0 1 1-2.34-5.66') &&       // 旧循环箭头已替换
  !h.includes('M9 15l6-6') &&                         // 旧断链已替换
  !h.includes('M8.25 5.5a7.5 7.5') &&                 // broadcast 已替换
  !h.includes('<rect x="6" y="6" width="12" height="5"') && // powerplug 已替换
  !h.includes('<rect x="6" y="6" width="12" height="12"'));
