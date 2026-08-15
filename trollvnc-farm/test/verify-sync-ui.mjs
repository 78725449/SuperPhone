// 同步交互 UI 验证脚本：驱动系统 Edge 打开控制台，验证卡片墙渲染与同步交互流程
// 用法：node test/verify-sync-ui.mjs
import { chromium } from 'playwright-core';

const EDGE = process.env.MSEDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = process.env.BASE_URL || 'http://127.0.0.1:8080/';
const results = [];
const ok = (name, pass, extra = '') => results.push(`${pass ? 'PASS' : 'FAIL'}  ${name}  ${extra}`);

const browser = await chromium.launch({ executablePath: EDGE, headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 900 } });
const dialogs = [];
page.on('dialog', async (d) => { dialogs.push(d.message()); await d.dismiss(); });
page.on('pageerror', (e) => results.push(`PAGE_ERROR  ${e.message}`));

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 25000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2500);

  // 1) 卡片墙渲染（真实设备 + 30 台虚拟预览）
  const tileCount = await page.locator('.tile').count();
  ok('卡片墙渲染', tileCount >= 30, `tiles=${tileCount}`);

  // 2) 卡片统一尺寸规格
  const dims = await page.$$eval('.tile', (els) => els.slice(0, 3).map((e) => `${e.offsetWidth}x${e.offsetHeight}`));
  ok('卡片同尺寸规格', new Set(dims).size === 1, dims.join(' '));

  // 3) 批量按钮竞态二态（常驻 → 点击出现复选框 → 再点退出）
  await page.click('#batchBtn');
  await page.waitForTimeout(200);
  const cbOn = await page.locator('.tile-checkbox:visible').count();
  ok('批量模式复选框出现', cbOn > 0, `checkbox=${cbOn}`);
  await page.click('#batchBtn');
  await page.waitForTimeout(300);
  const cbOff = await page.locator('.tile-checkbox:visible').count();
  ok('退出批量复选框消失', cbOff === 0, `checkbox=${cbOff}`);

  // 3.5) 直控模式：激活变色 + 点击卡片不聚焦（directMode 拦截）+ 退出恢复
  const offTile = page.locator('.tile.tile-offline').first();
  await page.click('#directBtn');
  await page.waitForTimeout(1500);
  const dActive = await page.locator('#directBtn').evaluate((e) => e.classList.contains('direct-active'));
  const dText = (await page.locator('#directBtn').textContent()).trim();
  const dWall = await page.locator('#wall.direct-mode').count();
  ok('直控激活变色', dActive && dWall === 1, `text=${dText}`);
  const dbg = dialogs.length;
  if (await offTile.count() > 0) {
    await offTile.click({ timeout: 3000 }).catch(() => {});
    await page.waitForTimeout(500);
    const noFocus = (await page.locator('#workspace.focus-open').count()) === 0;
    ok('直控时点卡片不聚焦', noFocus && dialogs.length === dbg, `dialogs delta=${dialogs.length - dbg}`);
  }
  await page.click('#directBtn');
  await page.waitForTimeout(1200);
  const dActive2 = await page.locator('#directBtn').evaluate((e) => e.classList.contains('direct-active'));
  ok('退出直控恢复原色', !dActive2);

  // 4) 聚焦真实在线设备（iPhone）
  const iphone = page.locator('.tile', { hasText: 'iPhone' }).first();
  const iphoneVisible = await iphone.count() > 0;
  ok('找到真实 iPhone 卡片', iphoneVisible);
  if (iphoneVisible) {
    await iphone.click();
    await page.waitForSelector('#workspace.focus-open', { timeout: 15000 });
    await page.waitForTimeout(3000);
    ok('聚焦主控进入大屏', true);

    // 5) 同步按钮红色激活态（图标恒为 🔗，进入选择模式后变红）
    const btn0 = (await page.locator('#btnSync').textContent()).trim();
    const act0 = await page.locator('#btnSync').evaluate((e) => e.classList.contains('sync-active'));
    await page.click('#btnSync');
    await page.waitForTimeout(400);
    const btn1 = (await page.locator('#btnSync').textContent()).trim();
    const act1 = await page.locator('#btnSync').evaluate((e) => e.classList.contains('sync-active'));
    ok('同步按钮红色激活态', btn0 === '🔗' && btn1 === '🔗' && act0 === false && act1 === true, `🔗 ${act0}→${act1}`);

    // 6) 同步选择模式下点击离线卡片 → 提示无法同步
    if (await offTile.count() > 0) {
      const before = dialogs.length;
      await offTile.click({ timeout: 3000 }).catch(() => {});
      await page.waitForTimeout(500);
      ok('同步模式点离线卡片提示', dialogs.length > before, dialogs.slice(before).join(' | '));
    } else {
      ok('存在离线卡片用于交互验证', false, 'no offline tile found');
    }

    // 7) 再次点击断开，按钮恢复原色
    await page.click('#btnSync');
    await page.waitForTimeout(400);
    const act2 = await page.locator('#btnSync').evaluate((e) => e.classList.contains('sync-active'));
    ok('再次点击断开恢复原色', act2 === false, `→ active=${act2}`);

    // 8) 返回设备墙
    await page.click('#btnBack');
    await page.waitForTimeout(800);
    ok('返回设备墙', !(await page.locator('#workspace.focus-open').count()));
  }
} catch (e) {
  results.push(`FAIL  脚本异常: ${e.message}`);
}

await page.screenshot({ path: 'test/verify-sync-shot.png' });
await browser.close();

console.log('\n==== 同步交互验证结果 ====');
results.forEach((r) => console.log(r));
const failed = results.filter((r) => r.startsWith('FAIL')).length + results.filter((r) => r.startsWith('PAGE_ERROR')).length;
console.log(`\n${results.length - failed}/${results.length} 项通过`);
process.exit(failed ? 1 : 0);
