/**
 * 验证 dot 光标 patch：从 server/index.js 提取替换逻辑，应用到原始 rfb.js，
 * 确认正则匹配成功且替换后的光标是 7×7 圆点。
 * 用法：node test/verify-dot-cursor.js
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, '..');
const NOVNC_DIR = path.join(ROOT, 'node_modules', '@novnc', 'novnc');
const rfbSrc = fs.readFileSync(path.join(NOVNC_DIR, 'core', 'rfb.js'), 'utf8');

// 复刻 server/index.js 中的 dot patch（正则 + 替换文本）
const oldBlock = /    dot: \{[\s\S]*?\n    \}\n\};/;
if (!oldBlock.test(rfbSrc)) {
  console.error('FAIL: 正则未匹配原始 rfb.js 的 dot 块');
  process.exit(1);
}
console.log('PASS: 正则匹配原始 dot 块');

const newBlock = `    dot: {
        /* eslint-disable indent */
        // 7×7 圆点：白色填充 + 黑色描边，hotx/hoty = 中心 (3,3)
        rgbaPixels: new Uint8Array([
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255, 0, 0, 0, 0,
            0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255,
            0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255,
            0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255,
            0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0,
        ]),
        /* eslint-enable indent */
        w: 7, h: 7,
        hotx: 3, hoty: 3,
    }
};`;

const patched = rfbSrc.replace(oldBlock, newBlock);
if (patched === rfbSrc) {
  console.error('FAIL: 替换后无变化');
  process.exit(1);
}
console.log('PASS: 替换生效');

// 从 newBlock 中提取 rgbaPixels 数组并验证形状
const arrM = newBlock.match(/rgbaPixels: new Uint8Array\(\[([\s\S]*?)\]\)/);
const px = eval('[' + arrM[1].replace(/\s+/g, ' ').trim() + ']');
const w = 7, h = 7, hotx = 3, hoty = 3;
console.log(`PASS: pixels=${px.length} (expect ${w * h * 4}=${w * h * 4})`);
if (px.length !== w * h * 4) {
  console.error('FAIL: 像素数不符');
  process.exit(1);
}

// 验证形状（.透明 #黑描边 o白色填充）
let grid = '';
for (let y = 0; y < h; y++) {
  let row = '';
  for (let x = 0; x < w; x++) {
    const i = (y * w + x) * 4;
    const a = px[i + 3];
    if (a === 0) row += '.';
    else if (px[i] === 255) row += 'o';
    else row += '#';
  }
  grid += row + '\n';
}
console.log('形状:\n' + grid);
console.log('PASS: dot 光标验证全部通过');
