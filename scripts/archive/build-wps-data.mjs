// scripts/build-wps-data.mjs
// 输入：wps-expand-hz.json（BSSID 列表）
// 输出：TrollVNC/src/WpsBssidData.h（静态常量数组，BSSID 标准化为 XX:XX:XX:XX:XX:XX）
// 用法：node scripts/build-wps-data.mjs [input.json] [output.h]
import fs from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const input = process.argv[2] ?? join(here, '..', 'wps-expand-hz.json');
const output = process.argv[3] ?? join(here, '..', 'TrollVNC/src/WpsBssidData.h');
const data = JSON.parse(fs.readFileSync(input, 'utf8'));

// BSSID 标准化：单数字节补前导零（0:19:70:57:d:3b → 00:19:70:57:0d:3b）
function normalizeBssid(b) {
  const n = b.split(':').map((s) => s.padStart(2, '0')).join(':').toUpperCase();
  if (!/^([0-9A-F]{2}:){5}[0-9A-F]{2}$/.test(n)) {
    throw new Error(`invalid bssid: ${b} → ${n}`);
  }
  return n;
}

const raw = Array.isArray(data) ? data : (data.bssids ?? []);
const bssids = [...new Set(raw.map((b) => normalizeBssid(typeof b === 'string' ? b : b.bssid)))];

const lines = [
  '/*',
  ' * WpsBssidData.h — 目标城市真实 BSSID 常量表（生成产物，勿手改）',
  ' * 源数据：wps-expand-hz.json（apple-wps.mjs tile/expand 实测，801 条源数据 → 去重 401）',
  ' * 生成：node scripts/build-wps-data.mjs',
  ' */',
  '#ifndef WpsBssidData_h',
  '#define WpsBssidData_h',
  '',
  '#define kWpsBssidCount ' + bssids.length,
  'static const char *kWpsBssids[kWpsBssidCount] = {',
  ...bssids.map((b) => `    "${b}",`),
  '};',
  '',
  '#endif',
];
fs.writeFileSync(output, lines.join('\n') + '\n');
console.log(`[build-wps-data] wrote ${bssids.length} BSSIDs to ${output}`);
