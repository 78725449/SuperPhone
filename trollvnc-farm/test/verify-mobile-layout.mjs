// 移动端 H5 改造验证：header 精简（仅布局+批量）、#wall 宽度撑满、卡片/列表两档布局、批量 checkbox
import { chromium } from 'playwright-core';
const EDGE = process.env.MSEDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = 'http://127.0.0.1:8080/';
const results = [];
const ok = (name, pass, extra = '') => results.push(`${pass ? 'PASS' : 'FAIL'}  ${name}  ${extra}`);

const browser = await chromium.launch({ executablePath: EDGE, headless: true });
const page = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
const visible = (loc) => loc.evaluate((el) => el && el.offsetParent !== null);

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 25000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2500);

  // 1) header 精简：仅布局 + 批量可见，其余隐藏
  const header = await page.evaluate(() => {
    const vis = (sel) => { const el = document.querySelector(sel); return el && el.offsetParent !== null; };
    return {
      zoom: vis('.zoom'), refresh: vis('#btnRefresh'), direct: vis('#directBtn'),
      add: vis('#btnAdd'), meta: vis('.meta'),
      layout: vis('#layoutBtn'), batch: vis('#batchBtn'),
      overflow: (() => { const h = document.querySelector('header'); return h.scrollWidth - h.clientWidth; })(),
      headerH: document.querySelector('header').getBoundingClientRect().height,
    };
  });
  ok('移动端隐藏卡片滑杆', !header.zoom);
  ok('移动端隐藏刷新/直控/添加/统计', !header.refresh && !header.direct && !header.add && !header.meta);
  ok('移动端保留布局+批量按钮', header.layout && header.batch);
  ok('header 无横向溢出', header.overflow <= 0, `overflow=${header.overflow}px h=${header.headerH}px`);

  // 2) #wall 宽度撑满（此前收缩为 242px → 卡片被压小）
  const wallW = await page.evaluate(() => document.querySelector('#wall').clientWidth);
  ok('卡片墙宽度撑满容器', wallW >= 340, `wallW=${wallW}px`);

  // 3) 卡片视图：2 列大卡片
  const gridInfo = await page.evaluate(() => {
    const tiles = [...document.querySelectorAll('.tile')].slice(0, 4);
    return { first: { w: tiles[0].offsetWidth, h: tiles[0].offsetHeight }, cls: document.querySelector('#wall').className };
  });
  ok('卡片视图宫格 2 列（宽>140）', gridInfo.first.w > 140, `${gridInfo.first.w}x${gridInfo.first.h}px cls=${gridInfo.cls}`);

  // 4) 切列表视图：单列行式（tile 高 < 卡片模式高，行式布局）
  await page.click('#layoutBtn');
  await page.waitForTimeout(300);
  await page.click('.lopt[data-l="list"]');
  await page.waitForTimeout(600);
  const listInfo = await page.evaluate(() => {
    const wall = document.querySelector('#wall');
    const t = wall.querySelector('.tile');
    const tv = t.querySelector('.tv');
    const tbar = t.querySelector('.tile-bar');
    return {
      cls: wall.className,
      tile: { w: t.offsetWidth, h: t.offsetHeight },
      tv: { w: tv.offsetWidth, h: tv.offsetHeight },
      tbarStatic: getComputedStyle(tbar).position === 'static',
      icon: document.querySelector('#layoutIcon').innerHTML.includes('line x1'),
      sel: document.querySelector('.lopt[data-l="list"]').classList.contains('sel'),
    };
  });
  ok('列表视图切换成功', listInfo.cls.includes('wall-list'), listInfo.cls);
  ok('列表行式布局（tv 48px 缩略图）', listInfo.tv.w <= 50 && listInfo.tv.h <= 50, `${listInfo.tv.w}x${listInfo.tv.h}`);
  ok('列表单列（tile 宽>300）', listInfo.tile.w > 300, `${listInfo.tile.w}x${listInfo.tile.h}`);
  ok('列表信息区静态定位', listInfo.tbarStatic);
  ok('布局图标切换为列表', listInfo.icon);
  ok('菜单选中列表', listInfo.sel);

  // 5) 列表模式批量 checkbox 显示
  await page.click('#batchBtn');
  await page.waitForTimeout(300);
  const cbOn = await page.locator('.tile-checkbox:visible').count();
  ok('列表模式批量复选框显示', cbOn > 0, `checkbox=${cbOn}`);
  await page.click('#batchBtn');
  await page.waitForTimeout(300);

  // 6) 切回卡片
  await page.click('#layoutBtn');
  await page.waitForTimeout(300);
  await page.click('.lopt[data-l="grid"]');
  await page.waitForTimeout(600);
  const backGrid = await page.evaluate(() => document.querySelector('#wall').className);
  ok('切回卡片视图', backGrid.includes('wall-grid'), backGrid);
} catch (e) {
  ok('脚本执行', false, e.message);
} finally {
  await browser.close();
  console.log('\n==== 移动端 H5 布局改造验证 ====');
  results.forEach((r) => console.log(r));
  const failed = results.filter((r) => r.startsWith('FAIL')).length;
  console.log(failed === 0 ? '全部通过' : `${failed} 项失败`);
  process.exit(failed === 0 ? 0 : 1);
}
