// 验证 noVNC 与设备端的 Extended Clipboard 握手：进入聚焦后检查
// rfb._clipboardServerCapabilitiesFormats / _clipboardServerCapabilitiesActions
// （设备端是否发过 ServerCaps → 影响剪贴板能力协商）
// 2026-08-15：clipboardPasteFrom 已改为直发 Provide（不经 Notify/Request 拉取），
// 本验证仅确认协议协商状态，不再作为同步是否生效的门控。
import { chromium } from 'playwright-core';
const EDGE = process.env.MSEDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = 'https://127.0.0.1:8080/?container=ipa&selfId=mock-self';
const browser = await chromium.launch({ executablePath: EDGE, headless: true });
const page = await browser.newPage({ viewport: { width: 390, height: 795 }, isMobile: true, hasTouch: true, ignoreHTTPSErrors: true });

try {
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 25000 });
  await page.waitForSelector('.tile', { timeout: 20000 });
  await page.waitForTimeout(2500);
  // 点击在线设备进入聚焦（离线/虚拟 tile 会被 alert 拦截）
  await page.evaluate(() => {
    const t = [...document.querySelectorAll('.tile')].find(t => !t.classList.contains('tile-offline') && !t.classList.contains('tile-mock'));
    if (t) t.click();
  });
  await page.waitForTimeout(4000); // 等待 RFB 连接完成
  const caps = await page.evaluate(() => {
    const rfb = window.__farmFocusRfb || (window.focus && window.focus.rfb);
    if (!rfb) return { error: 'no rfb' };
    return {
      connected: rfb._rfbConnectionState,
      formats: rfb._clipboardServerCapabilitiesFormats,
      actions: rfb._clipboardServerCapabilitiesActions,
      text: rfb._clipboardText,
    };
  });
  console.log('==== noVNC Extended Clipboard 握手状态 ====');
  console.log(JSON.stringify(caps, null, 1));
  const hasText = caps.formats && caps.formats[1];
  const hasNotify = caps.actions && caps.actions[1 << 27];
  console.log(`服务器声明 Text 格式: ${!!hasText}`);
  console.log(`服务器声明 Notify 动作: ${!!hasNotify}`);
  if (!hasText || !hasNotify) {
    console.log('⇒ ServerCaps 未收到/不完整（能力协商缺失，仅提示）；clipboardPasteFrom 现已直发 Provide，不依赖该协商');
  } else {
    console.log('⇒ Extended Clipboard 握手完整（提供方直发 Provide 时能力协商仍正常）');
  }
} catch (e) {
  console.log('脚本异常:', e.message);
} finally {
  await browser.close();
}
