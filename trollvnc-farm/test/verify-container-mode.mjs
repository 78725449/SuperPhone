// Web 容器化 Phase 1 验证：?selfId= 自身设备过滤 + ?container=ipa 容器模式标记
// 前提：网关运行在 127.0.0.1:8080，且 /api/devices 至少返回一台真实设备（id 取自运行期）
import { chromium } from 'playwright-core';
const EDGE = process.env.MSEDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = 'http://127.0.0.1:8080/';
const results = [];
const ok = (name, pass, extra = '') => results.push(`${pass ? 'PASS' : 'FAIL'}  ${name}  ${extra}`);

const browser = await chromium.launch({ executablePath: EDGE, headless: true });
const page = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });

try {
  // 0) 取真实设备 id（网关运行期返回的第一个 source=register 设备）
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 25000 });
  const devRes = await page.evaluate(async (base) => {
    const r = await fetch(base + 'api/devices');
    const j = await r.json();
    return (j.devices || []).filter((d) => d.source === 'register').map((d) => ({ id: d.id, name: d.name }))[0] || null;
  }, BASE);
  ok('网关返回 register 设备', !!devRes, devRes ? `${devRes.name} (${devRes.id})` : '无真实设备');
  if (!devRes) throw new Error('no real device');

  // 1) 普通浏览器访问（无容器参数）：body 标记 web，真实设备卡片存在
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 25000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2000);
  const norm = await page.evaluate((dev) => {
    const names = [...document.querySelectorAll('.tname')].map((e) => e.textContent.trim());
    return {
      dataContainer: document.body.dataset.container,
      farmContainer: window.__FARM_CONTAINER,
      hasSelf: names.includes(dev.name),
      meta: document.querySelector('#meta').textContent,
    };
  }, devRes);
  ok('普通访问 body[data-container]=web', norm.dataContainer === 'web', `got=${norm.dataContainer}`);
  ok('普通访问 __FARM_CONTAINER=false', norm.farmContainer === false);
  ok('普通访问设备墙含自身设备', norm.hasSelf, `meta=${norm.meta}`);

  // 2) 容器访问（?selfId=<真实id>&container=ipa）：body 标记 ipa，自身设备被过滤
  await page.goto(`${BASE}?selfId=${encodeURIComponent(devRes.id)}&container=ipa`, { waitUntil: 'networkidle', timeout: 25000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2000);
  const ipa = await page.evaluate((dev) => {
    const names = [...document.querySelectorAll('.tname')].map((e) => e.textContent.trim());
    return {
      dataContainer: document.body.dataset.container,
      farmContainer: window.__FARM_CONTAINER,
      hasSelf: names.includes(dev.name),
      meta: document.querySelector('#meta').textContent,
    };
  }, devRes);
  ok('容器访问 body[data-container]=ipa', ipa.dataContainer === 'ipa', `got=${ipa.dataContainer}`);
  ok('容器访问 __FARM_CONTAINER=true', ipa.farmContainer === true);
  ok('容器访问设备墙已过滤自身', !ipa.hasSelf, `meta=${ipa.meta}`);
  ok('容器访问自身不误伤其它卡片', ipa.meta.includes('台'), `meta=${ipa.meta}`);

  // 3) 仅 ?container=ipa（无 selfId）：标记生效但不过滤设备（不误伤）
  await page.goto(`${BASE}?container=ipa`, { waitUntil: 'networkidle', timeout: 25000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2000);
  const ipaNoSelf = await page.evaluate((dev) => ({
    dataContainer: document.body.dataset.container,
    hasSelf: [...document.querySelectorAll('.tname')].some((e) => e.textContent.trim() === dev.name),
  }), devRes);
  ok('仅容器标记不触发过滤', ipaNoSelf.dataContainer === 'ipa' && ipaNoSelf.hasSelf,
    `data=${ipaNoSelf.dataContainer} hasSelf=${ipaNoSelf.hasSelf}`);
} catch (e) {
  ok('执行异常', false, e.message);
} finally {
  await browser.close();
}

console.log(results.join('\n'));
const failed = results.filter((l) => l.startsWith('FAIL')).length;
console.log(`\n${results.length - failed}/${results.length} PASS`);
process.exit(failed ? 1 : 0);
