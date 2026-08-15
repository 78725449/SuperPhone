// 去重/身份合并测试：
// 1) 同一 deviceId 多次注册 -> 列表仅 1 条；旧连接关闭不误判离线
// 2) 身份合并：manual/mdns 同 host:port 记录在注册时合并为 deviceId；已注册设备不被 manual 覆盖（禁止双卡）
import { spawn } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..');
const PORT = 18400 + Math.floor(Math.random() * 300);
const REG_PORT = PORT + 1;
const TUN_PORT = PORT + 1 + 1000;
const TOKEN = 'testtoken';
const tmpData = fs.mkdtempSync(path.join(os.tmpdir(), 'farm-dedupe-'));

let failures = 0;
function check(name, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}
async function waitFor(fn, timeoutMs = 6000, interval = 80) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try { const v = await fn(); if (v) return v; } catch {}
    await new Promise((r) => setTimeout(r, interval));
  }
  throw new Error('waitFor timeout');
}

const child = spawn(process.execPath, [path.join(ROOT, 'server', 'index.js')], {
  env: { ...process.env, FARM_PORT: String(PORT), FARM_REG_PORT: String(REG_PORT), FARM_TUNNEL_PORT: String(TUN_PORT), FARM_TOKEN: TOKEN, FARM_DATA_DIR: tmpData, FARM_TLS: '0', FARM_HOST: '127.0.0.1' },
  stdio: ['ignore', 'pipe', 'pipe'],
});
const auth = { Authorization: `Bearer ${TOKEN}` };
async function getDevices() {
  return (await (await fetch(`http://127.0.0.1:${PORT}/api/devices`, { headers: auth })).json()).devices;
}
function openReg(deviceId, port = 5901, name = 'DupPhone') {
  return new Promise((resolve, reject) => {
    const s = net.connect(REG_PORT, '127.0.0.1', () => {
      s.write(JSON.stringify({ type: 'register', deviceId, name, vncPort: port }) + '\n');
    });
    let buf = '';
    const t = setTimeout(() => { s.destroy(); reject(new Error('ack timeout')); }, 4000);
    s.on('data', (d) => { buf += d.toString(); if (buf.includes('ack')) { clearTimeout(t); resolve(s); } });
    s.on('error', reject);
  });
}
function connClosed(sock) {
  return new Promise((resolve) => { sock.once('close', () => resolve(true)); sock.once('error', () => resolve(true)); setTimeout(() => resolve(false), 2000); });
}

let a = null, b = null, mergeSock = null, ms2 = null;
try {
  await waitFor(async () => (await fetch(`http://127.0.0.1:${PORT}/api/state`, { headers: auth })).ok);

  // ---- 1. 同一 deviceId 重复注册去重 ----
  a = await openReg('dup-1');
  await waitFor(async () => (await getDevices()).filter((d) => d.id === 'dup-1').length === 1);
  check('首次注册：设备列表仅 1 条 dup-1', (await getDevices()).filter((d) => d.id === 'dup-1').length === 1);

  const aClosedP = connClosed(a);
  b = await openReg('dup-1');
  await waitFor(async () => (await getDevices()).filter((d) => d.id === 'dup-1').length === 1);
  check('重复注册：仍只有 1 条 dup-1', (await getDevices()).filter((d) => d.id === 'dup-1').length === 1);
  const dev1 = (await getDevices()).find((d) => d.id === 'dup-1');
  check('重复注册后设备在线', dev1 && dev1.online === true);

  const aClosed = await aClosedP;
  check('旧连接被服务端关闭（单连接策略）', aClosed, `aClosed=${aClosed}`);
  await new Promise((r) => setTimeout(r, 800));
  const dev2 = (await getDevices()).find((d) => d.id === 'dup-1');
  check('旧连接关闭后设备仍在线（新连接存活）', dev2 && dev2.online === true);

  b.destroy();
  await waitFor(async () => {
    const d = (await getDevices()).find((x) => x.id === 'dup-1');
    return d && d.online === false;
  });
  check('新连接关闭后判离线', true);

  // ---- 2. 身份合并：先 manual 建卡，再 register 同 host:port -> 合并为 deviceId ----
  await fetch(`http://127.0.0.1:${PORT}/api/devices`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({ name: 'ManualPhone', host: '127.0.0.1', port: 15901 }),
  });
  const manual1 = (await getDevices()).find((d) => d.name === 'ManualPhone');
  check('manual 建卡成功', manual1 && manual1.source === 'manual' && manual1.port === 15901);
  mergeSock = await openReg('merge-1', 15901, 'MergePhone');
  await waitFor(async () => {
    const ds = (await getDevices()).filter((d) => d.host === '127.0.0.1' && d.port === 15901);
    return ds.length === 1 && ds[0].id === 'merge-1' && ds[0].source === 'register';
  });
  const afterMerge = (await getDevices()).filter((d) => d.host === '127.0.0.1' && d.port === 15901);
  check('manual+register 合并为一条 deviceId', afterMerge.length === 1 && afterMerge[0].id === 'merge-1' && afterMerge[0].source === 'register');
  check('合并保留 addedAt', afterMerge[0].addedAt === manual1.addedAt);
  check('合并后名称以注册为准', afterMerge[0].name === 'MergePhone');
  mergeSock.destroy();

  // ---- 3. 反向：已注册设备不被 manual 覆盖（deviceId 优先，禁止双卡）----
  ms2 = await openReg('merge-2', 15902, 'MergePhone2');
  await waitFor(async () => (await getDevices()).some((d) => d.id === 'merge-2' && d.online === true));
  const postRes = await fetch(`http://127.0.0.1:${PORT}/api/devices`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({ name: 'ManualOverride', host: '127.0.0.1', port: 15902 }),
  });
  check('manual POST 命中已注册设备 -> 201（幂等返回）', postRes.status === 201);
  const ds2 = (await getDevices()).filter((d) => d.host === '127.0.0.1' && d.port === 15902);
  check('已注册设备不被降级/不新增（仍 1 条 register）', ds2.length === 1 && ds2[0].source === 'register' && ds2[0].id === 'merge-2' && ds2[0].name === 'MergePhone2');
  ms2.destroy();

  // 清理
  try { a.destroy(); } catch {}
} catch (e) {
  console.error('TEST ERROR:', e.message);
  failures++;
} finally {
  try { a && a.destroy(); } catch {}
  try { b && b.destroy(); } catch {}
  try { mergeSock && mergeSock.destroy(); } catch {}
  try { ms2 && ms2.destroy(); } catch {}
  child.kill();
  await new Promise((r) => setTimeout(r, 300));
  try { fs.rmSync(tmpData, { recursive: true, force: true }); } catch {}
}

console.log(failures === 0 ? '\nALL DEDUPE TESTS PASSED' : `\n${failures} TEST(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
