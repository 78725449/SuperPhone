// 回归验证：屏幕上长按 → noVNC farmlongpress（bubbles）→ 跨设备粘贴条（2026-08-13）
// 覆盖：进入 focus 大屏 → 长按触发 farmlongpress → 粘贴条弹出
import { chromium } from 'playwright-core';
const EDGE = process.env.MSEDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = 'http://127.0.0.1:8080/';
const results = [];
const ok = (name, pass, extra = '') => results.push(`${pass ? 'PASS' : 'FAIL'}  ${name}  ${extra}`);

const browser = await chromium.launch({ executablePath: EDGE, headless: true });
const page = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 25000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(3000);

  // 1) 点击在线设备卡片进入 focus 大屏
  const entered = await page.evaluate(() => {
    const tile = [...document.querySelectorAll('.tile')].find(t => {
      const dot = t.querySelector('.dot');
      return dot && dot.classList.contains('on');
    });
    if (!tile) return false;
    tile.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    return true;
  });
  ok('找到在线设备并点击进入大屏', entered);
  await page.waitForTimeout(1500);
  // 网关刚重启/设备重连时 noVNC 连接中，canvas 延迟创建：轮询等待
  try {
    await page.waitForFunction(() => !!document.querySelector('#focusStage canvas'), null, { timeout: 20000 });
  } catch (e) { ok('等待 canvas 出现', false, '20s 超时'); }
  const focusState = await page.evaluate(() => {
    const stage = document.querySelector('#focusStage');
    return {
      panel: !!document.querySelector('#focusPanel') && !document.querySelector('#focusPanel').classList.contains('hidden'),
      stageBound: stage ? stage.dataset.pasteBound : null,
      canvas: !!(stage && stage.querySelector('canvas')),
    };
  });
  ok('focus 大屏已打开', focusState.panel, JSON.stringify(focusState));
  ok('focusStage 已绑定长按粘贴', focusState.stageBound === '1');
  ok('focusStage 内存在 noVNC canvas', focusState.canvas);

  // 2) 注入 farmlongpress 计数（独立验证手势层派发，含冒泡到 stage）
  await page.evaluate(() => {
    window.__lpCount = 0;
    document.querySelector('#focusStage').addEventListener('farmlongpress', () => { window.__lpCount++; });
  });

  // 3) CDP 浏览器级触摸长按：touchStart → 1300ms（> noVNC 1000ms 阈值）→ touchEnd
  const rect = await page.evaluate(() => {
    const r = document.querySelector('#focusStage canvas').getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  });
  const client = await page.context().newCDPSession(page);
  await client.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: rect.x, y: rect.y }] });
  await page.waitForTimeout(1300);
  await client.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await page.waitForTimeout(500);
  const afterLong = await page.evaluate(() => {
    const b = document.querySelector('#pasteBar');
    return { lpCount: window.__lpCount || 0, shown: b && !b.classList.contains('hidden') };
  });
  ok('长按 → farmlongpress 事件触发（冒泡到 stage）', afterLong.lpCount >= 1, `lpCount=${afterLong.lpCount}`);
  ok('长按 → 跨设备粘贴条出现', afterLong.shown, JSON.stringify(afterLong));
} catch (e) {
  ok('脚本异常', false, e.message);
} finally {
  await browser.close();
}
console.log(results.join('\n'));
const failed = results.filter(r => r.startsWith('FAIL'));
console.log(failed.length ? `\n${failed.length} FAILED` : '\nALL PASS');
