// 改定位 API 链路验证（verify-locsim）：setConfigs(anchor) → 读回校验 → status → track/itinerary → off 收尾
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

// 2. anchor 目标（北京）
const setR = await api(`/api/devices/${encodeURIComponent(devId)}/configs`, {
  method: 'POST', body: JSON.stringify({ configs: {
    SimLocationMode: 'anchor', SimLocationLat: TARGET.lat, SimLocationLon: TARGET.lon, SimLocationAccuracy: TARGET.acc,
  } }),
});
const r = setR.j.results || {};
check('anchor 三参下发全部 ok',
  setR.status === 200
  && r.SimLocationMode && r.SimLocationMode.ok
  && r.SimLocationLat && r.SimLocationLat.ok
  && r.SimLocationLon && r.SimLocationLon.ok
  && r.SimLocationAccuracy && r.SimLocationAccuracy.ok, JSON.stringify(setR.j));

// 3. 读回校验（等 1s 让设备上报 configs 刷新）
await new Promise((r) => setTimeout(r, 1000));
const getR = await api(`/api/devices/${encodeURIComponent(devId)}/configs`);
const c = getR.j.configs || {};
check('读回 SimLocationMode=anchor', c.SimLocationMode === 'anchor', `got=${c.SimLocationMode}`);
check('读回 SimLocationLat≈目标', Math.abs(Number(c.SimLocationLat) - TARGET.lat) < 0.001, `got=${c.SimLocationLat}`);
check('读回 SimLocationLon≈目标', Math.abs(Number(c.SimLocationLon) - TARGET.lon) < 0.001, `got=${c.SimLocationLon}`);

// 3.2 status：invoke sim.location.status 应返回 mode=anchor + 当前位置≈北京
const stR = await api(`/api/devices/${encodeURIComponent(devId)}/invoke`, {
  method: 'POST', body: JSON.stringify({ cap: 'sim.location.status', params: {} }),
});
const st = stR.j;
check('invoke sim.location.status ok', stR.status === 200 && st && st.ok !== false && st.mode === 'anchor', JSON.stringify(st));
check('status 当前位置≈北京', Math.abs(Number(st.lat) - TARGET.lat) < 0.01 && Math.abs(Number(st.lon) - TARGET.lon) < 0.01, `got=${st.lat},${st.lon}`);

// 3.5 track：invoke sim.location.track 上传 60 点短轨迹（链路验证用；真实轨迹由面板按完整路线生成，时长=距离÷速度）
const pts = interpolateRoute(TARGET, { lat: 31.2304, lon: 121.4737 }, { speed: 'walk', maxPoints: 60 });
const trkR = await api(`/api/devices/${encodeURIComponent(devId)}/invoke`, {
  method: 'POST', body: JSON.stringify({ cap: 'sim.location.track', params: { points: pts } }),
});
check('invoke sim.location.track ok（60 点）', trkR.status === 200 && trkR.j.ok, JSON.stringify(trkR.j));
await new Promise((r) => setTimeout(r, 1500));
const getT = await api(`/api/devices/${encodeURIComponent(devId)}/configs`);
const ct = getT.j.configs || {};
check('读回 SimLocationMode=itinerary', ct.SimLocationMode === 'itinerary', `got=${ct.SimLocationMode}`);

// 3.6 route：invoke sim.route.calculate（Apple 原生算路，异步）——只验证请求链路与立即 ack
const rtR = await api(`/api/devices/${encodeURIComponent(devId)}/invoke`, {
  method: 'POST', body: JSON.stringify({ cap: 'sim.route.calculate', params: {
    from: { lat: 39.9042, lon: 116.4074 }, to: { lat: 31.2304, lon: 121.4737 }, mode: 'walk',
  } }),
});
check('invoke sim.route.calculate ok（异步 calculating）', rtR.status === 200 && rtR.j.ok && rtR.j.status === 'calculating', JSON.stringify(rtR.j));

// 3.7 itinerary：invoke sim.itinerary（region 段：单段=区域漫游，同步生成不依赖设备端联网）——段起点静态绑定自当前 _current
await new Promise((r) => setTimeout(r, 500));
const itR = await api(`/api/devices/${encodeURIComponent(devId)}/invoke`, {
  method: 'POST', body: JSON.stringify({ cap: 'sim.itinerary', params: {
    segments: [{ type: 'region', center: { lat: 39.9042, lon: 116.4074 }, radius: 500, mode: 'walk', durationMin: 5 }],
  } }),
});
check('invoke sim.itinerary ok（异步 calculating）', itR.status === 200 && itR.j.ok && itR.j.status === 'calculating', JSON.stringify(itR.j));
await new Promise((r) => setTimeout(r, 3000));
const getI = await api(`/api/devices/${encodeURIComponent(devId)}/configs`);
const ci = getI.j.configs || {};
check('itinerary 落盘切 SimLocationMode=itinerary', ci.SimLocationMode === 'itinerary', `got=${ci.SimLocationMode}`);

// 4. off 收尾
const off1 = await api(`/api/devices/${encodeURIComponent(devId)}/configs`, {
  method: 'POST', body: JSON.stringify({ configs: { SimLocationMode: 'off' } }),
});
check('收尾 off 下发 ok', off1.status === 200 && off1.j.results && off1.j.results.SimLocationMode && off1.j.results.SimLocationMode.ok);

log(fails === 0
  ? '\nALL LOCSIM VERIFY PASSED — 请人工开系统地图确认蓝点位于 (39.9042, 116.4074) 北京'
  : `\n${fails} FAILURES`);
process.exit(fails === 0 ? 0 : 1);
