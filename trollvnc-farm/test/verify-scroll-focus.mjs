// 验证：滚动设备墙后点卡片，聚焦面板 fixed inset:0 是否错位（WKWebView 布局视口问题）
import { chromium } from 'playwright-core';
const EDGE = process.env.MSEDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = 'https://127.0.0.1:8080/?container=ipa&selfId=mock-self';
const browser = await chromium.launch({ executablePath: EDGE, headless: true });
const page = await browser.newPage({ viewport: { width: 390, height: 795 }, isMobile: true, hasTouch: true, ignoreHTTPSErrors: true });

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 25000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2500);

  // 场景A：不滚动直接点卡片
  const tiles = page.locator('.tile');
  const n = await tiles.count();
  console.log('tiles:', n);
  await tiles.nth(0).click();
  await page.waitForTimeout(1500);
  const sA = await page.evaluate(() => {
    const fp = document.querySelector('#focusPanel').getBoundingClientRect();
    const st = document.querySelector('#focusStage').getBoundingClientRect();
    return { panel: { y: Math.round(fp.y), h: Math.round(fp.height) }, stage: { y: Math.round(st.y), h: Math.round(st.height) }, vh: window.innerHeight };
  });
  console.log('场景A（未滚动点卡片）:', JSON.stringify(sA));

  // 退出聚焦
  await page.evaluate(() => { document.querySelector('#opsMenu').classList.add('hidden'); document.querySelector('#fab').classList.add('hidden'); });
  await page.click('.ops-exit, [data-op="disc"]').catch(() => {});
  await page.waitForTimeout(600);

  // 场景B：滚动设备墙后点卡片
  await page.evaluate(() => { const w = document.querySelector('#wall'); if (w) w.scrollTop = 400; });
  await page.waitForTimeout(300);
  await tiles.nth(1).click();
  await page.waitForTimeout(1500);
  const sB = await page.evaluate(() => {
    const fp = document.querySelector('#focusPanel').getBoundingClientRect();
    const st = document.querySelector('#focusStage').getBoundingClientRect();
    return { panel: { y: Math.round(fp.y), h: Math.round(fp.height) }, stage: { y: Math.round(st.y), h: Math.round(st.height) }, vh: window.innerHeight,
             scrollY: window.scrollY, wallScrollTop: document.querySelector('#wall') ? document.querySelector('#wall').scrollTop : -1 };
  });
  console.log('场景B（滚动后点卡片）:', JSON.stringify(sB));

  console.log(sA.panel.y === sB.panel.y ? '面板位置一致（无错位）' : '面板位置错位！');
} catch (e) {
  console.error(e.message);
} finally {
  await browser.close();
}
