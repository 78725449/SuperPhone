#!/usr/bin/env node
/**
 * ai-direct-loop.mjs —— 无网关 AI 直连闭环验证脚本（2026-09-15 快照服务三期）
 *
 * 直连设备 5802（不经网关、不经 5901 RFB），跑通 AI 感知闭环：
 *   snapshot → wait(变化) → waitStable(稳定) → vision.find_text(识别) → touch.tap(驱动)
 * 协议层零超时（wait 挂起到变化/连接断开）；等待上限由本脚本的 deadline 参数定义（应用层）。
 *
 * 用法：
 *   node scripts/ai-direct-loop.mjs <设备IP> demo --find="设置" [--steps 5]
 *   node scripts/ai-direct-loop.mjs <设备IP> once
 *   node scripts/ai-direct-loop.mjs <设备IP> watch --since 0 --timeout 10000
 * 环境变量：SP_DEBUG=1 打印每步耗时
 */
import http from 'node:http';

const [ip] = process.argv.slice(2);
if (!ip) {
  console.error('用法: node scripts/ai-direct-loop.mjs <设备IP> [demo|once|watch] [参数]');
  process.exit(1);
}
const BASE = `http://${ip}:5802`;
const DEBUG = process.env.SP_DEBUG === '1';

function rpc(op, params = {}, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ op, params });
    const req = http.request(`${BASE}/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: timeoutMs,
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
        catch (e) { reject(new Error(`响应解析失败: ${e.message}`)); }
      });
    });
    req.on('timeout', () => { req.destroy(new Error(`rpc ${op} 超时(${timeoutMs}ms)`)); });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

/** 挂起等变化：协议零超时；应用层 deadline 用 AbortController 断开连接取消（设备端自动清理） */
function waitChange(since, deadlineMs = 30000) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ op: 'screen.wait', params: { since } });
    const req = http.request(`${BASE}/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
        catch (e) { reject(new Error(`wait 响应解析失败: ${e.message}`)); }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
    // 应用层 deadline：到点 abort → 连接断开 → 设备端挂起自动清理（无协议层超时）
    const timer = setTimeout(() => req.destroy(new Error(`wait 无变化超时(${deadlineMs}ms)——注入可能未生效`)), deadlineMs);
    req.on('close', () => clearTimeout(timer));
  });
}

function waitStable(minStableMs = 500, deadlineMs = 30000) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ op: 'screen.waitStable', params: { minStableMs } });
    const req = http.request(`${BASE}/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
        catch (e) { reject(new Error(`waitStable 响应解析失败: ${e.message}`)); }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
    const timer = setTimeout(() => req.destroy(new Error(`waitStable 超时(${deadlineMs}ms)`)), deadlineMs);
    req.on('close', () => clearTimeout(timer));
  });
}

async function timed(label, fn) {
  const t0 = Date.now();
  const v = await fn();
  if (DEBUG) console.log(`  [${label}] ${Date.now() - t0}ms`);
  return v;
}

function parseOpts(argv) {
  const opts = {};
  for (const a of argv) {
    const m = a.match(/^--([^=]+)=(.*)$/);
    if (m) opts[m[1]] = m[2];
  }
  return opts;
}

/** 演示闭环：find_text 找目标 → 点中心 → 等变化 → 等稳定 → 再找（验证注入生效） */
async function demo(find) {
  console.log(`[demo] 目标文本: "${find}"（直连 ${BASE}）`);
  for (let step = 1; step <= 5; step++) {
    const ocr = await timed(`step${step} find_text`, () =>
      rpc('vision.find_text', { text: find }, 15000));
    if (!ocr.ok || !ocr.found) {
      console.log(`[demo] step${step}: 未找到目标 → 结束（${ocr.error || 'found=false'}）`);
      return;
    }
    const line = ocr.lines && ocr.lines[0];
    if (!line) { console.log(`[demo] step${step}: 无命中行`); return; }
    console.log(`[demo] step${step}: 命中 "${line.text}" @ (${line.cx}, ${line.cy})`);
    const tap = await timed(`step${step} tap`, () => rpc('touch.tap', { x: line.cx, y: line.cy }));
    if (!tap.ok) { console.log(`[demo] step${step}: tap 失败 ${tap.error}`); return; }
    const snapBefore = await timed(`step${step} snapshot`, () => rpc('screen.snapshot', {}));
    const chg = await timed(`step${step} wait`, () => waitChange(snapBefore.seq, 10000));
    if (!chg.ok) { console.log(`[demo] step${step}: 无变化（${chg.error}）— 可能点击无响应，继续下一轮`); continue; }
    await timed(`step${step} waitStable`, () => waitStable(600, 10000));
    console.log(`[demo] step${step}: 变化已稳定 (seq=${chg.seq})`);
    if (DEBUG) console.log(`[demo] step${step}: 关键帧 seq=${snapBefore.seq} -> ${chg.seq}`);
  }
}

const mode = process.argv[3] || 'demo';
const opts = parseOpts(process.argv.slice(4));

if (mode === 'demo') {
  const find = opts.find || '设置';
  await demo(find);
} else if (mode === 'once') {
  const s = await timed('snapshot', () => rpc('screen.snapshot', {}));
  console.log(`snapshot ok=${s.ok} seq=${s.seq} ${s.w}x${s.h} jpegB64=${s.jpeg ? s.jpeg.length : 0}B`);
  const o = await timed('ocr', () => rpc('vision.ocr', {}, 15000));
  console.log(`ocr ok=${o.ok} lines=${o.count || 0}`);
  if (o.texts && o.texts.length) console.log(` 首行: ${o.texts[0].text}`);
} else if (mode === 'watch') {
  const since = Number(opts.since) || 0;
  const loops = Number(opts.loops) || 3;
  let seq = since;
  for (let i = 0; i < loops; i++) {
    const t0 = Date.now();
    const chg = await waitChange(seq, 15000);
    if (!chg.ok) { console.log(`[watch] #${i + 1}: 无变化（${chg.error}）`); continue; }
    console.log(`[watch] #${i + 1}: 变化发生 seq=${seq}->${chg.seq} (耗时 ${Date.now() - t0}ms)`);
    seq = chg.seq;
  }
} else {
  console.error(`未知模式: ${mode}（demo|once|watch）`);
  process.exit(1);
}