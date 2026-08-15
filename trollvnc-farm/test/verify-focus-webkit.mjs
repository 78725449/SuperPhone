// WebKit 引擎验证：模拟 iOS WKWebView 渲染，检查聚焦面板布局（对比 Chromium headless）
import { webkit } from 'playwright-core';
const BASE = 'https://127.0.0.1:8080/?container=ipa&selfId=mock-self';
const results = [];
const ok = (name, pass, extra = '') => results.push(`${pass ? 'PASS' : 'FAIL'}  ${name}  ${extra}`);

const browser = await webkit.launch({ headless: true });
// 模拟 iPhone 12/13 视口 + iOS UA
const context = await browser.newContext({
  viewport: { width: 390, height: 844 },
  isMobile: true,
  hasTouch: true,
  deviceScaleFactor: 3,
  ignoreHTTPSErrors: true,
  userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
});
const page = await context.newPage();

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2500);

  const before = await page.evaluate(() => {
    const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) }; };
    return {
      body: r(document.body), html: r(document.documentElement),
      main: r(document.querySelector('main')), workspace: r(document.querySelector('#workspace')),
      wall: r(document.querySelector('#wall')),
      vw: window.innerWidth, vh: window.innerHeight,
      bodyScrollH: document.body.scrollHeight, htmlScrollH: document.documentElement.scrollHeight,
    };
  });
  ok('body 撑满视口宽', before.body && before.body.w === before.vw, JSON.stringify(before.body));
  ok('html/body 无垂直滚动（height:100% 生效）', before.bodyScrollH <= before.vh + 1, `bodyScrollH=${before.bodyScrollH} vh=${before.vh}`);
  ok('workspace 高度 > 0', before.workspace && before.workspace.h > 700, JSON.stringify(before.workspace));

  await page.click('.tile');
  await page.waitForTimeout(1500);

  const after = await page.evaluate(() => {
    const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) }; };
    const fp = document.querySelector('#focusPanel');
    const stage = document.querySelector('#focusStage');
    return {
      focusPanel: r(fp), focusScreen: r(document.querySelector('#focusScreen')),
      focusStage: r(stage), canvas: r(stage ? stage.querySelector('canvas') : null),
      vw: window.innerWidth, vh: window.innerHeight,
      panelPos: fp ? getComputedStyle(fp).position : null,
      bodyScrollY: window.scrollY, docScrollY: document.documentElement.scrollTop,
      bodyScrollH: document.body.scrollHeight, htmlScrollH: document.documentElement.scrollHeight,
      htmlScrollY: document.scrollingElement ? document.scrollingElement.scrollTop : -1,
    };
  });
  ok('聚焦面板 position=fixed', after.panelPos === 'fixed', after.panelPos);
  ok('聚焦面板覆盖视口（x=0,y=0,wh=vw,vh）', after.focusPanel && after.focusPanel.x === 0 && after.focusPanel.y === 0 &&
     after.focusPanel.w === after.vw && after.focusPanel.h === after.vh,
     JSON.stringify(after.focusPanel) + ' vh=' + after.vh);
  ok('focusStage 撑满视口高', after.focusStage && after.focusStage.h >= after.vh - 10, JSON.stringify(after.focusStage));
  ok('页面无滚动偏移（window.scrollY=0）', after.bodyScrollY === 0 && after.htmlScrollY === 0, `scrollY=${after.bodyScrollY} htmlScrollY=${after.htmlScrollY}`);
  ok('canvas 垂直居中（上下留白相等，与容器测量时序解耦）', after.canvas && after.focusStage &&
     Math.abs((after.canvas.y - after.focusStage.y) - (after.focusStage.h - after.canvas.h) / 2) <= 5,
     `canvas.y=${after.canvas && after.canvas.y} h=${after.canvas && after.canvas.h} stageH=${after.focusStage && after.focusStage.h}`);

  console.log('\n==== WebKit(WKWebView 模拟) 聚焦布局 ====');
  console.log('before:', JSON.stringify(before, null, 1));
  console.log('after:', JSON.stringify(after, null, 1));
} catch (e) {
  ok('脚本执行', false, e.message);
} finally {
  await context.close();
  await browser.close();
  console.log('\n==== WebKit 聚焦布局验证 ====');
  results.forEach((r) => console.log(r));
  const failed = results.filter((r) => r.startsWith('FAIL')).length;
  console.log(failed === 0 ? '全部通过' : `${failed} 项失败`);
  process.exit(failed === 0 ? 0 : 1);
}
