// 根因验证：body/main 高度链失效时 canvas 漂移模拟（WKWebView 布局视口差异）
import { chromium } from 'playwright-core';
const EDGE = process.env.MSEDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = 'https://127.0.0.1:8080/?container=ipa&selfId=mock-self';
const browser = await chromium.launch({ executablePath: EDGE, headless: true });
const page = await browser.newPage({ viewport: { width: 390, height: 795 }, isMobile: true, hasTouch: true, ignoreHTTPSErrors: true });

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 25000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2500);

  // 进入聚焦
  await page.click('.tile');
  await page.waitForTimeout(1500);

  const snap = () => page.evaluate(() => {
    const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { y: Math.round(b.y), h: Math.round(b.height) }; };
    const stage = document.querySelector('#focusStage');
    const canvas = stage ? stage.querySelector('canvas') : null;
    const rfbScreen = stage ? stage.querySelector(':scope > div') : null;
    return {
      body: r(document.body), main: r(document.querySelector('main')), workspace: r(document.querySelector('#workspace')),
      panel: r(document.querySelector('#focusPanel')), screen: r(document.querySelector('#focusScreen')),
      stage: r(stage), rfbScreen: r(rfbScreen), canvas: r(canvas),
      vh: window.innerHeight,
    };
  });

  console.log('正常布局:', JSON.stringify(await snap(), null, 1));

  // 模拟布局视口差异：缩小 html/body 高度链（如 WKWebView 中 body 高度 < 视口）
  await page.addStyleTag({ content: 'html, body { height: auto !important; min-height: 0 !important; } main { flex: none !important; } #workspace { height: auto !important; }' });
  await page.waitForTimeout(600);
  console.log('高度链失效后:', JSON.stringify(await snap(), null, 1));

  // 再恢复正常（模拟切换系统颜色触发重排）
  await page.addStyleTag({ content: 'html, body { height: 100% !important; } main { flex: 1 !important; } #workspace { height: 100% !important; }' });
  await page.evaluate(() => window.dispatchEvent(new Event('resize')));
  await page.waitForTimeout(800);
  console.log('恢复后:', JSON.stringify(await snap(), null, 1));
} catch (e) {
  console.error(e.message);
} finally {
  await browser.close();
}
