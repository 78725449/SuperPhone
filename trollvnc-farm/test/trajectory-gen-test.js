// 定位轨迹生成单测（trajectory-gen.js 纯函数；浏览器/Node 双用模块）
// 断言对齐《改定位-编码AI执行规格.md》§6 TrajectoryGenTests：
//   相邻位移=步长±10%；航向变化受限；拟人参数在范围；同 seed 可复现；含起终点
import { SPEED_DEFS, haversineMeters, headingDeg, interpolateRoute } from '../web/trajectory-gen.js';

let failures = 0;
function check(name, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

// 固定随机源：可复现
function seededRand(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

// 已知距离：北京(39.9042,116.4074) → 上海(31.2304,121.4737) ≈ 1067km
const bj = { lat: 39.9042, lon: 116.4074 };
const sh = { lat: 31.2304, lon: 121.4737 };
const d = haversineMeters(bj, sh);
check('haversine 北京→上海 ≈ 1067km', Math.abs(d - 1067000) < 30000, `got=${(d / 1000).toFixed(0)}km`);

// 航向：北京→上海大致朝东南（约 130°），北=0
const h = headingDeg(bj, sh);
check('北京→上海航向 ≈ 东南(100~160°)', h > 100 && h < 160, `got=${h.toFixed(1)}`);

// walk 1 分钟（60 点）
const pts = interpolateRoute(bj, sh, { speed: 'walk', rand: seededRand(42) });
check('walk 插值点 ≈ 距离/步长', Math.abs(pts.length - Math.round(d / SPEED_DEFS.walk)) <= 1, `got=${pts.length}`);

// 插值均匀性（无抖动层）：相邻位移 = 步长 ±10%（规格 §6 核心断言，抖动是叠加的拟人层）
const ptsNoJitter = interpolateRoute(bj, sh, { speed: 'walk', rand: seededRand(3), jitterM: 0 });
let maxDev2 = 0;
for (let i = 2; i < ptsNoJitter.length - 2; i++) {
  const step = haversineMeters(ptsNoJitter[i - 1], ptsNoJitter[i]);
  const dev = Math.abs(step - SPEED_DEFS.walk) / SPEED_DEFS.walk;
  if (dev > maxDev2) maxDev2 = dev;
}
check('插值均匀（无抖动）相邻位移 = 步长 ±10%', maxDev2 <= 0.1, `maxDev=${(maxDev2 * 100).toFixed(1)}%`);

// 默认拟人抖动（±0.5m）叠加：位移保持在合理范围（walk 步长 1.4m，抖动双轴叠加上限 ≈ ±1m）
const minStep = SPEED_DEFS.walk * 0.4, maxStep = SPEED_DEFS.walk * 1.6;
let stepOk = true, minGot = Infinity, maxGot = 0;
for (let i = 1; i < pts.length; i++) {
  const s = haversineMeters(pts[i - 1], pts[i]);
  minGot = Math.min(minGot, s); maxGot = Math.max(maxGot, s);
  if (s < minStep || s > maxStep) stepOk = false;
}
check('默认抖动下位移 ∈ 步长×[0.4,1.6]', stepOk, `range=[${minGot.toFixed(2)},${maxGot.toFixed(2)}]m step=${SPEED_DEFS.walk}m`);

// 拟人参数范围
const accOk = pts.every((p) => p.acc >= 3 && p.acc <= 6);
const altOk = pts.every((p) => Math.abs(p.alt - 45) <= 0.5);
const spdOk = pts.every((p) => p.speed >= SPEED_DEFS.walk * 0.9 && p.speed <= SPEED_DEFS.walk * 1.1);
check('精度 3~6m', accOk);
check('海拔 45±0.5m', altOk);
check('速度 ±10% 波动', spdOk);
check('坐标 WGS-84 范围', pts.every((p) => p.lat >= -90 && p.lat <= 90 && p.lon >= -180 && p.lon <= 180));

// 起终点包含（端点不抖到不可认——起点误差 < 50m）
const startErr = haversineMeters(pts[0], bj);
const endErr = haversineMeters(pts[pts.length - 1], sh);
check('含起点（误差<50m）', startErr < 50, `got=${startErr.toFixed(0)}m`);
check('含终点（误差<50m）', endErr < 50, `got=${endErr.toFixed(0)}m`);

// 同 seed 可复现
const pts2 = interpolateRoute(bj, sh, { speed: 'walk', rand: seededRand(42) });
check('同 seed 可复现', JSON.stringify(pts) === JSON.stringify(pts2));

// drive 速度档更快（点数更少）
const ptsD = interpolateRoute(bj, sh, { speed: 'drive', rand: seededRand(7) });
check('drive 点数 < walk 点数', ptsD.length < pts.length, `drive=${ptsD.length} walk=${pts.length}`);

console.log(failures === 0 ? 'ALL TRAJECTORY-GEN TESTS PASSED' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
