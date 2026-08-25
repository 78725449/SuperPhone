// 定位轨迹生成（纯函数，浏览器与 Node 双用；无 DOM 依赖）
// 对齐《改定位-编码AI执行规格.md》§3.4：输出统一为 §3.3.2 文件格式（WGS-84 + 拟人参数）
// M3 先落地 Interpolator（A→B 按速度插值，Andromeda interpolateRoute 思路）；区域漫游/GPX 后续扩展

/** 速度档（m/s，与 SimLocationSpeed 枚举对齐） */
export const SPEED_DEFS = { walk: 1.4, cycle: 5.5, drive: 13.9 };

/** 两点球面距离（米，haversine，公开数学） */
export function haversineMeters(a, b) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const la = toRad(a.lat), lb = toRad(b.lat);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(la) * Math.cos(lb) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

/** A→B 航向（度，0=北/顺时针） */
export function headingDeg(from, to) {
  const toRad = (d) => (d * Math.PI) / 180;
  const y = Math.sin(toRad(to.lon - from.lon)) * Math.cos(toRad(to.lat));
  const x = Math.cos(toRad(from.lat)) * Math.sin(toRad(to.lat))
    - Math.sin(toRad(from.lat)) * Math.cos(toRad(to.lat)) * Math.cos(toRad(to.lon - from.lon));
  return (Math.atan2(y, x) * 180) / Math.PI;
}

/**
 * A→B 按速度插值生成轨迹点（1 点/秒，含拟人抖动/精度/海拔/航向）
 * @param {{lat:number,lon:number}} from 起点（WGS-84）
 * @param {{lat:number,lon:number}} to   终点（WGS-84）
 * @param {object} opt { speed:'walk'|'cycle'|'drive', jitterM:米(默认0.5), altBase:米(默认45), rand:()=>number 可选注入随机源 }
 * @returns {Array<{lat,lon,speed,course,alt,acc}>} 点序列（已含拟人参数；2026-08-26 起 sim.location.track 外部能力已收敛，本模块供 App 算法原型/测试使用）
 */
export function interpolateRoute(from, to, opt = {}) {
  const mps = SPEED_DEFS[opt.speed] || SPEED_DEFS.walk;
  const jitterDeg = (opt.jitterM ?? 0.3) / 111320; // 米 → 度（约）；默认 0.3m：双轴合成 ≤±0.85m，贴近 C6"抖动远小于步长"
  const altBase = opt.altBase ?? 45;
  const rand = opt.rand || Math.random;
  const dist = haversineMeters(from, to);
  // 每秒 1 步；maxPoints 截断（超长轨迹面板用：点数 = 时长×60，避免海量点打爆 16MB 帧）
  const steps = Math.max(1, Math.min(Math.round(dist / mps), opt.maxPoints ?? Infinity));
  const heading = headingDeg(from, to);
  const points = [];
  for (let i = 0; i <= steps; i++) {
    const t = steps === 0 ? 1 : i / steps;
    points.push({
      lat: +(from.lat + (to.lat - from.lat) * t + (rand() - 0.5) * 2 * jitterDeg).toFixed(6),
      lon: +(from.lon + (to.lon - from.lon) * t + (rand() - 0.5) * 2 * jitterDeg).toFixed(6),
      speed: +(mps * (0.9 + rand() * 0.2)).toFixed(2),        // ±10% 波动
      course: +((heading + (rand() - 0.5) * 8 + 360) % 360).toFixed(1), // 航向 ±4° 抖动
      alt: +(altBase + (rand() - 0.5)).toFixed(1),             // 海拔 ±0.5m
      acc: +(3 + rand() * 3).toFixed(1),                       // 精度 3~6m 随机
    });
  }
  return points;
}
