// 悬浮菜单越界验证：移动视口 + iOS safe-area，FAB 在各边界位置点开菜单，检查是否越界/被 Home 条遮挡
import { chromium } from 'playwright-core';
const EDGE = process.env.MSEDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = 'https://127.0.0.1:8080/?container=ipa&selfId=mock-self';
const results = [];
const ok = (name, pass, extra = '') => results.push(`${pass ? 'PASS' : 'FAIL'}  ${name}  ${extra}`);

const browser = await chromium.launch({ executablePath: EDGE, headless: true });
const context = await browser.newContext({
  viewport: { width: 390, height: 844 },
  isMobile: true, hasTouch: true, deviceScaleFactor: 3,
  ignoreHTTPSErrors: true,
  userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
});
const page = await context.newPage();

// 模拟 iOS safe-area：顶部 47 / 底部 34（页面加载完成后设置，:root 内联覆盖 env()）
async function setSafeArea() {
  await page.evaluate(() => {
    const set = (k, v) => document.documentElement.style.setProperty(k, v);
    set('--safe-top', '47px'); set('--safe-bottom', '34px');
    set('--safe-left', '0px'); set('--safe-right', '0px');
  });
}

async function openMenuAt(left, top) {
  // 放置 FAB 到指定位置（跳过拖动，直接 set 位置后点击）
  await page.evaluate(([l, t]) => {
    const fab = document.getElementById('fab');
    fab.style.left = l + 'px'; fab.style.top = t + 'px';
    fab.style.right = 'auto'; fab.style.bottom = 'auto';
  }, [left, top]);
  // 点击（pointerdown 位移 0 → pointerup 判定为点击展开）
  const fb = await page.locator('#fab').boundingBox();
  await page.mouse.move(fb.x + fb.width / 2, fb.y + fb.height / 2);
  await page.mouse.down();
  await page.mouse.up();
  await page.waitForTimeout(150);
  const menu = await page.evaluate(() => {
    const el = document.getElementById('opsMenu');
    const b = el.getBoundingClientRect();
    return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height), shown: !el.classList.contains('hidden') };
  });
  // 收起，供下次使用
  await page.evaluate(() => document.getElementById('opsMenu').classList.add('hidden'));
  return menu;
}

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2500);
  await setSafeArea(); // 注入 iOS safe-area（在打开菜单前生效）
  // 点击在线设备卡片进入聚焦（离线/虚拟 tile 点击被 alert 拦截，不进入聚焦）
  await page.evaluate(() => {
    const t = [...document.querySelectorAll('.tile')].find(t => !t.classList.contains('tile-offline') && !t.classList.contains('tile-mock'));
    if (t) t.click();
  });
  await page.waitForTimeout(1800);
  const vh = await page.evaluate(() => window.innerHeight);
  const vw = await page.evaluate(() => window.innerWidth);
  ok('进入聚焦后 FAB 可见', await page.locator('#fab').isVisible());

  const spots = [
    ['右下角', vw - 70, vh - 90],
    ['左下角', 8, vh - 90],
    ['底部中央', vw / 2 - 28, vh - 90],
    ['顶部中央', vw / 2 - 28, 60],
    ['中右', vw - 70, vh / 2],
    ['中部', vw / 2 - 28, vh / 2],
  ];
  for (const [name, l, t] of spots) {
    const m = await openMenuAt(l, t);
    const inX = m.x >= 0 && m.x + m.w <= vw;
    const inY = m.y >= 0 && m.y + m.h <= vh;
    // Home 条遮挡检查：菜单底部不应进入底部安全区（vh-34）
    const homeOverlap = m.y + m.h > vh - 34 + 1;
    ok(`${name}: 菜单完整在视口内 (x=${m.x},y=${m.y},w=${m.w},h=${m.h} vw=${vw} vh=${vh})`, m.shown && inX && inY, JSON.stringify(m));
    ok(`${name}: 底部未被 Home 条遮挡 (bottom<=${vh - 34})`, !homeOverlap, `bottom=${m.y + m.h}`);
  }
} catch (e) {
  ok('脚本执行', false, e.message);
} finally {
  await context.close();
  await browser.close();
  console.log('\n==== 悬浮菜单越界验证 ====');
  results.forEach((r) => console.log(r));
  const failed = results.filter((r) => r.startsWith('FAIL')).length;
  console.log(failed === 0 ? '全部通过' : `${failed} 项失败`);
  process.exit(failed === 0 ? 0 : 1);
}
