// 聚焦布局几何验证：模拟 IPA 容器模式（?container=ipa）移动端视口，检查聚焦面板/canvas 位置
import { chromium } from 'playwright-core';
const EDGE = process.env.MSEDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = 'https://127.0.0.1:8080/?container=ipa&selfId=mock-self';
const results = [];
const ok = (name, pass, extra = '') => results.push(`${pass ? 'PASS' : 'FAIL'}  ${name}  ${extra}`);

const browser = await chromium.launch({ executablePath: EDGE, headless: true });
const page = await browser.newPage({ viewport: { width: 390, height: 795 }, isMobile: true, hasTouch: true, ignoreHTTPSErrors: true });

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 25000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2500);

  // 聚焦前布局几何
  const before = await page.evaluate(() => {
    const r = (sel) => { const el = document.querySelector(sel); if (!el) return null; const b = el.getBoundingClientRect(); return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) }; };
    return {
      body: r('body'), main: r('main'), workspace: r('#workspace'), wall: r('#wall'),
      focusPanel: r('#focusPanel'),
      vw: window.innerWidth, vh: window.innerHeight,
      bodyScrollH: document.body.scrollHeight,
    };
  });
  ok('body 宽度 = 视口宽度', before.body && before.body.w === before.vw, JSON.stringify(before.body));
  ok('main 撑满视口宽', before.main && before.main.w >= before.vw - 30, `main=${JSON.stringify(before.main)}`);
  // workspace 在 main 内（padding 14），高度应接近 main 高 - 28
  ok('workspace 高度接近 main 内容区', before.workspace && before.workspace.h >= before.main.h - 30, `ws=${JSON.stringify(before.workspace)} main=${JSON.stringify(before.main)}`);

  // 点击第一张卡片进入聚焦（跳过离线/虚拟 tile：离线点击被 alert 拦截，不进入聚焦）
  await page.evaluate(() => {
    const t = [...document.querySelectorAll('.tile')].find(t => !t.classList.contains('tile-offline') && !t.classList.contains('tile-mock'));
    if (t) t.click();
  });
  await page.waitForTimeout(1200); // 等待 connect + fitFocusPanel

  // 聚焦后布局几何
  const after = await page.evaluate(() => {
    const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) }; };
    const fp = document.querySelector('#focusPanel');
    const stage = document.querySelector('#focusStage');
    const rfbScreen = stage ? stage.querySelector('div') : null;
    const canvas = stage ? stage.querySelector('canvas') : null;
    return {
      focusPanel: r(fp),
      focusScreen: r(document.querySelector('#focusScreen')),
      focusStage: r(stage),
      rfbScreen: r(rfbScreen),
      canvas: r(canvas),
      vw: window.innerWidth, vh: window.innerHeight,
      panelPos: fp ? getComputedStyle(fp).position : null,
    };
  });
  ok('聚焦面板 position=fixed', after.panelPos === 'fixed', after.panelPos);
  ok('聚焦面板覆盖整个视口', after.focusPanel && after.focusPanel.x === 0 && after.focusPanel.y === 0 &&
     after.focusPanel.w === after.vw && after.focusPanel.h === after.vh,
     JSON.stringify(after.focusPanel) + ' vh=' + after.vh);
  ok('聚焦 stage 撑满视口', after.focusStage && after.focusStage.h >= after.vh - 10, JSON.stringify(after.focusStage));
  // canvas 尺寸由 noVNC autoscale 按设备宽高比 contain 决定（不固定等于视口高）；
  // 关键断言：canvas 在 stage 内垂直居中（上下留白相等）——即不受尺寸信号影响
  ok('canvas 垂直居中（上下留白相等）', after.canvas && after.focusStage &&
     Math.abs((after.canvas.y - after.focusStage.y) - (after.focusStage.h - after.canvas.h) / 2) <= 5,
     `canvas.y=${after.canvas.y} canvas.h=${after.canvas.h} stage.h=${after.focusStage.h}`);

  console.log('\n==== 聚焦布局几何（IPA 容器模式） ====');
  console.log('before:', JSON.stringify(before, null, 1));
  console.log('after:', JSON.stringify(after, null, 1));
} catch (e) {
  ok('脚本执行', false, e.message);
} finally {
  await browser.close();
  console.log('\n==== 聚焦布局验证 ====');
  results.forEach((r) => console.log(r));
  const failed = results.filter((r) => r.startsWith('FAIL')).length;
  console.log(failed === 0 ? '全部通过' : `${failed} 项失败`);
  process.exit(failed === 0 ? 0 : 1);
}
