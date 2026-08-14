// 卡片墙排序号（order）测试：PATCH 设置/清除/校验 + GET /api/devices 排序返回（2026-08-15）
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..');
const PORT = 18700 + Math.floor(Math.random() * 200);
const REG_PORT = PORT + 1;
const TUN_PORT = PORT + 1 + 1000;
const TOKEN = 'testtoken';
const tmpData = fs.mkdtempSync(path.join(os.tmpdir(), 'farm-order-test-'));

let failures = 0;
function check(name, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}
async function waitFor(fn, timeoutMs = 6000, interval = 80) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try { const v = await fn(); if (v) return v; } catch { /* retry */ }
    await new Promise((r) => setTimeout(r, interval));
  }
  throw new Error('waitFor timeout');
}

const child = spawn(process.execPath, [path.join(ROOT, 'server', 'index.js')], {
  env: { ...process.env, FARM_PORT: String(PORT), FARM_REG_PORT: String(REG_PORT), FARM_TUNNEL_PORT: String(TUN_PORT), FARM_TOKEN: TOKEN, FARM_DATA_DIR: tmpData, FARM_TLS: '0', FARM_HOST: '127.0.0.1', FARM_MDNS: '0' },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let childOut = '';
child.stdout.on('data', (d) => (childOut += d));
child.stderr.on('data', (d) => (childOut += d));

const auth = { Authorization: `Bearer ${TOKEN}` };
const base = `http://127.0.0.1:${PORT}`;
async function api(p, opts = {}) {
  const res = await fetch(base + p, { headers: { ...auth, 'Content-Type': 'application/json' }, ...opts });
  const text = await res.text();
  let body = null;
  try { body = JSON.parse(text); } catch { body = null; }
  return { status: res.status, body };
}
async function addDevice(name, host, port) {
  const r = await api('/api/devices', { method: 'POST', body: JSON.stringify({ name, host, port }) });
  return r.body.device;
}
async function getOrdered() {
  const r = await api('/api/devices');
  return (r.body.devices || []).map((d) => d.id);
}

let a, b, c;
try {
  // 等服务器就绪
  await waitFor(async () => (await api('/api/state')).status === 200);

  // 注册 3 台 manual 设备（按注册时间顺序 a,b,c）
  a = await addDevice('devA', '10.0.0.1', 5901);
  b = await addDevice('devB', '10.0.0.2', 5901);
  c = await addDevice('devC', '10.0.0.3', 5901);

  // 初始：无 order → 按注册时间排序 [a, b, c]
  let ordered = await getOrdered();
  check('初始按注册时间排序', ordered.join() === [a.id, b.id, c.id].join(), ordered.join());

  // 设置 order：b=1, a=3, c 保持 null → [b, a, c]
  await api(`/api/devices/${b.id}`, { method: 'PATCH', body: JSON.stringify({ order: 1 }) });
  await api(`/api/devices/${a.id}`, { method: 'PATCH', body: JSON.stringify({ order: 3 }) });
  ordered = await getOrdered();
  check('有 order 升序在前、无 order 在后', ordered.join() === [b.id, a.id, c.id].join(), ordered.join());

  // order 重复兜底：a 改 1 与 b 相同 → 按 id 字典序（a<b）
  await api(`/api/devices/${a.id}`, { method: 'PATCH', body: JSON.stringify({ order: 1 }) });
  ordered = await getOrdered();
  const ab = [a.id, b.id].sort();
  check('order 相同按 id 兜底', ordered.slice(0, 2).join() === ab.join(), ordered.join());

  // 清除 order（null）→ a 回到无 order 段（b 在前，a/c 按注册时间：a 先注册在前）
  await api(`/api/devices/${a.id}`, { method: 'PATCH', body: JSON.stringify({ order: null }) });
  ordered = await getOrdered();
  check('清除 order 回退注册时间段', ordered[0] === b.id && ordered.indexOf(a.id) < ordered.indexOf(c.id), ordered.join());

  // 无效 order 拒绝：-1 / 100000
  const r1 = await api(`/api/devices/${a.id}`, { method: 'PATCH', body: JSON.stringify({ order: -1 }) });
  const r2 = await api(`/api/devices/${a.id}`, { method: 'PATCH', body: JSON.stringify({ order: 100000 }) });
  check('order=-1 拒绝(400)', r1.status === 400 && !r1.body.device);
  check('order=100000 拒绝(400)', r2.status === 400 && !r2.body.device);

  // 设备不存在 404
  const r3 = await api('/api/devices/nonexistent-id', { method: 'PATCH', body: JSON.stringify({ order: 1 }) });
  check('不存在设备 404', r3.status === 404);

  // 持久化：order 写入 devices.json
  await new Promise((r) => setTimeout(r, 600)); // 等 saveDb 防抖 300ms 落盘
  const db = JSON.parse(fs.readFileSync(path.join(tmpData, 'devices.json'), 'utf8'));
  const bInDb = db.find((d) => d.id === b.id);
  check('order 已持久化到 devices.json', bInDb && bInDb.order === 1);
} catch (e) {
  console.error('FATAL', e);
  failures++;
} finally {
  child.kill();
  console.log(childOut.split('\n').filter((l) => /error|ERR/i.test(l)).slice(0, 5).join('\n'));
}

console.log(failures === 0 ? '\nALL ORDER TESTS PASSED' : `\n${failures} ORDER TEST(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
