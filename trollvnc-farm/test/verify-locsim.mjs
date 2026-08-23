// 改定位 API 链路验证（verify-locsim）：setConfigs(static) → 读回校验 → invoke track → off 收尾
// 用法：node verify-locsim.mjs <deviceId> [base]   （base 默认 https://127.0.0.1:8080，可 FARM_BASE 覆盖）
// 通过标准：setConfigs/invoke 均 ok 且读回参数一致；人工再开系统地图看蓝点=目标坐标/轨迹移动
import { env } from 'node:process';
import { interpolateRoute } from '../web/trajectory-gen.js';
const devId = process.argv[2];
const BASE = env.FARM_BASE || process.argv[3] || 'https://127.0.0.1:8080';
if (!devId) { console.error('usage: node verify-locsim.mjs <deviceId> [base]'); process.exit(1); }

const TARGET = { lat: 39.9042, lon: 116.4074, acc: 5 }; // 北京 WGS-84
const log = (...a) => console.log(...a);
let fails = 0;
function check(name, cond, extra = '') {
  log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) fails++;
}

async function api(path, opts = {}) {
  const res = await fetch(`${BASE}${path}`, {
    ...opts,
    headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) },
  });
  const j = await res.json().catch(() => ({}));
  return { status: res.status, j };
}

// 1. 先 off（清态）
const off0 = await api(`/api/devices/${encodeURIComponent(devId)}/configs`, {
  method: 'POST', body: JSON.stringify({ configs: { SimLocationMode: 'off' } }),
});
check('初始 off 下发 ok', off0.status === 200 && off0.j.results && off0.j.results.SimLocationMode && off0.j.results.SimLocationMode.ok, JSON.stringify(off0.j));

// 2. static 目标（北京）
const setR = await api(`/api/devices/${encodeURIComponent(devId)}/configs`, {
  method: 'POST', body: JSON.stringify({ configs: {
    SimLocationMode: 'static', SimLocationLat: TARGET.lat, SimLocationLon: TARGET.lon, SimLocationAccuracy: TARGET.acc,
  } }),
});
const r = setR.j.results || {};
check('static 三参下发全部 ok',
  setR.status === 200
  && r.SimLocationMode && r.SimLocationMode.ok
  && r.SimLocationLat && r.SimLocationLat.ok
  && r.SimLocationLon && r.SimLocationLon.ok
  && r.SimLocationAccuracy && r.SimLocationAccuracy.ok, JSON.stringify(setR.j));

// 3. 读回校验（等 1s 让设备上报 configs 刷新）
await new Promise((r) => setTimeout(r, 1000));
const getR = await api(`/api/devices/${encodeURIComponent(devId)}/configs`);
const c = getR.j.configs || {};
check('读回 SimLocationMode=static', c.SimLocationMode === 'static', `got=${c.SimLocationMode}`);
check('读回 SimLocationLat≈目标', Math.abs(Number(c.SimLocationLat) - TARGET.lat) < 0.001, `got=${c.SimLocationLat}`);
check('读回 SimLocationLon≈目标', Math.abs(Number(c.SimLocationLon) - TARGET.lon) < 0.001, `got=${c.SimLocationLon}`);

// 3.5 track：invoke sim.location.track 上传 1 分钟 walk 轨迹（北京→上海 截取 60 点）
const pts = interpolateRoute(TARGET, { lat: 31.2304, lon: 121.4737 }, { speed: 'walk', maxPoints: 60 });
const trkR = await api(`/api/devices/${encodeURIComponent(devId)}/invoke`, {
  method: 'POST', body: JSON.stringify({ cap: 'sim.location.track', params: { points: pts } }),
});
check('invoke sim.location.track ok（60 点）', trkR.status === 200 && trkR.j.ok, JSON.stringify(trkR.j));
await new Promise((r) => setTimeout(r, 1500));
const getT = await api(`/api/devices/${encodeURIComponent(devId)}/configs`);
const ct = getT.j.configs || {};
check('读回 SimLocationMode=track', ct.SimLocationMode === 'track', `got=${ct.SimLocationMode}`);

// 4. off 收尾
const off1 = await api(`/api/devices/${encodeURIComponent(devId)}/configs`, {
  method: 'POST', body: JSON.stringify({ configs: { SimLocationMode: 'off' } }),
});
check('收尾 off 下发 ok', off1.status === 200 && off1.j.results && off1.j.results.SimLocationMode && off1.j.results.SimLocationMode.ok);

log(fails === 0
  ? '\nALL LOCSIM VERIFY PASSED — 请人工开系统地图确认蓝点位于 (39.9042, 116.4074) 北京'
  : `\n${fails} FAILURES`);
process.exit(fails === 0 ? 0 : 1);
