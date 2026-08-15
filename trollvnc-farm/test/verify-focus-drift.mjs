// 聚焦画布漂移复现：点卡片后 canvas/stage 位置，模拟"切换系统颜色触发重排"（viewport resize）
import { chromium } from 'playwright-core';
const EDGE = process.env.MSEDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = 'https://127.0.0.1:8080/?container=ipa&selfId=mock-self';
const results = [];
const ok = (name, pass, extra = '') => results.push(`${pass ? 'PASS' : 'FAIL'}  ${name}  ${extra}`);

const browser = await chromium.launch({ executablePath: EDGE, headless: true });
const page = await browser.newPage({ viewport: { width: 390, height: 795 }, isMobile: true, hasTouch: true, ignoreHTTPSErrors: true });

const snapshot = () => page.evaluate(() => {
  const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { y: Math.round(b.y), h: Math.round(b.height) }; };
  const stage = document.querySelector('#focusStage');
  const canvas = stage ? stage.querySelector('canvas') : null;
  const screen = document.querySelector('#focusScreen');
  return {
    t0: Date.now(),
    stage: r(stage), canvas: r(canvas), screen: r(screen),
    vh: window.innerHeight,
    stageCSS: stage ? { h: getComputedStyle(stage).height, pos: getComputedStyle(stage).position } : null,
    screenCSS: screen ? { h: getComputedStyle(screen).height } : null,
  };
});

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 25000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2500);

  await page.evaluate(() => {
    const t = [...document.querySelectorAll('.tile')].find(t => !t.classList.contains('tile-offline') && !t.classList.contains('tile-mock'));
    if (t) t.click();
  });
  await page.waitForTimeout(300);   // 刚点完，connect 前（RFB 创建瞬间）
  const s1 = await snapshot();
  await page.waitForTimeout(1500);  // connect + fitFocusPanel 后
  const s2 = await snapshot();

  // 模拟"切换系统颜色"：触发一次 resize（系统颜色切换会引发 WKWebView 重排/resize 事件）
  await page.evaluate(() => { window.dispatchEvent(new Event('resize')); document.dispatchEvent(new Event('visibilitychange')); });
  await page.waitForTimeout(800);
  const s3 = await snapshot();

  console.log('t=300ms  (创建瞬间):', JSON.stringify(s1));
  console.log('t=1800ms (稳定后):', JSON.stringify(s2));
  console.log('t=+resize (模拟切换):', JSON.stringify(s3));

  const moved = Math.abs((s2.canvas?.y || 0) - (s3.canvas?.y || 0)) > 3;
  const stageH = s2.stage?.h || 0;
  const canvasH = s2.canvas?.h || 0;
  ok('stage 高度 = 视口高度', stageH >= (s2.vh - 10), `stage.h=${stageH} vh=${s2.vh}`);
  // canvas 尺寸由 autoscale 按设备比例 contain 决定；核心断言是居中与 resize 无漂移
  ok('canvas 垂直居中（上下留白相等）', (s2.canvas?.y || 0) >= 0 &&
     Math.abs((s2.canvas?.y || 0) - (stageH - canvasH) / 2) <= 5,
     `canvas.y=${s2.canvas?.y} canvas.h=${canvasH} stage.h=${stageH}`);
  // 漂移复现判定：resize 前后 canvas.y 变化（贴顶→贴底）
  ok('resize 后 canvas 位置不变（无漂移）', !moved, `beforeY=${s2.canvas?.y} afterY=${s3.canvas?.y}`);
  ok('canvas 顶部 y >= 0 且居中', (s2.canvas?.y || 0) >= 0 && (s2.canvas?.y || 0) < (s2.vh / 2), `canvas.y=${s2.canvas?.y}`);
} catch (e) {
  ok('脚本执行', false, e.message);
} finally {
  await browser.close();
  console.log('\n==== 聚焦画布漂移复现 ====');
  results.forEach((r) => console.log(r));
  const failed = results.filter((r) => r.startsWith('FAIL')).length;
  console.log(failed === 0 ? '全部通过' : `${failed} 项失败`);
  process.exit(failed === 0 ? 0 : 1);
}
