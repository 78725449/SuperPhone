// 临时校验：morton tile key 换算数学对拍 apple-corelocation-experiments（buckhx/tiles）
const MIN_LAT = -85.05112878, MAX_LAT = 85.05112878;
const MIN_LON = -180, MAX_LON = 180;

function clip(v, min, max) { return Math.min(Math.max(v, min), max); }

// buckhx Coordinate.ToPixel → ToTile（含 +0.5 像素舍入）
function toTileXY(lat, lon, z) {
  const size = 256 << z;
  const la = clip(lat, MIN_LAT, MAX_LAT);
  const lo = clip(lon, MIN_LON, MAX_LON);
  const x = (lo + 180) / 360.0;
  const sinLat = Math.sin((la * Math.PI) / 180);
  const y = 0.5 - Math.log((1 + sinLat) / (1 - sinLat)) / (4 * Math.PI);
  const px = Math.floor(clip(x * size + 0.5, 0, size - 1));
  const py = Math.floor(clip(y * size + 0.5, 0, size - 1));
  return { tx: Math.floor(px / 256), ty: Math.floor(py / 256) };
}

// morton.Pack(mLat=row, mLong=column, level)
function pack(row, column, level) {
  let result = 1n << BigInt(level << 1);
  for (let i = 0; i < level; i++) {
    if (column & 1) result += 1n << BigInt(2 * i);
    if (row & 1) result += 1n << BigInt(2 * i + 1);
    column >>= 1;
    row >>= 1;
  }
  return result;
}

// morton.Unpack
function unpack(key) {
  let row = 0, column = 0, level = 0;
  let q = BigInt(key);
  while (q > 1n) {
    const mask = 1 << level;
    if (q & 1n) column |= mask;
    if (q & 2n) row |= mask;
    level++;
    q = (q - (q & 3n)) / 4n;
  }
  return { row, column, level };
}

// FromTile: Tile{Y: row, X: column, Z: level}.ToPixel().ToCoords() → NW corner
function tileToCoords(row, column, level) {
  const size = 256 << level;
  const x = clip(column * 256, 0, size - 1) / size - 0.5;
  const y = 0.5 - clip(row * 256, 0, size - 1) / size;
  const lat = 90 - (360 * Math.atan(Math.exp(-y * 2 * Math.PI))) / Math.PI;
  const lon = 360 * x;
  return { lat, lon };
}

// ---- 自检 1：Cardiff 编码应落在 README 示例键区间 81644851..81644861 ----
const { tx, ty } = toTileXY(51.4816, -3.1791, 13);
const key = pack(ty, tx, 13);
console.log('Cardiff (51.4816,-3.1791) z13 -> tile (x,y)=', tx, ty, ' key=', key.toString(), key >= 81644851n && key <= 81644861n ? '✅ 在示例区间' : '❌ 不在区间');

// ---- 自检 2：decode(2562456?) 反推 Hillcrest 之类已知 key 是否落回 Cardiff 附近 ----
// 用区间内一个 key 反解码
for (const k of [81644851n, 81644856n, 81644861n]) {
  const { row, column, level } = unpack(k);
  const c = tileToCoords(row, column, level);
  console.log(`decode(${k}) level=${level} row=${row} col=${column} -> NW (${c.lat.toFixed(5)}, ${c.lon.toFixed(5)})`);
}

// ---- 自检 3：roundtrip encode->decode 回到原点所在瓦片 ----
const rtt = toTileXY(51.4816, -3.1791, 13);
const rtKey = pack(rtt.ty, rtt.tx, 13);
const { row: r2, column: c2, level: l2 } = unpack(rtKey);
const rt = tileToCoords(r2, c2, l2);
console.log('roundtrip NW =', rt.lat.toFixed(5), rt.lon.toFixed(5), '原点在瓦片内:', rt.lat <= 51.4816 && rt.lon >= -3.1791 && rt.lat > 51.4816 - 0.044 && rt.lon < -3.1791 + 0.044);

// ---- 自检 4：杭州（30.25, 120.17）level 13 的 key（下一步真实取数用） ----
const hz = toTileXY(30.25, 120.17, 13);
const hzKey = pack(hz.ty, hz.tx, 13);
console.log('Hangzhou (30.25,120.17) z13 -> tile (x,y)=', hz.tx, hz.ty, ' key=', hzKey.toString());
const hzDec = tileToCoords(hz.ty, hz.tx, 13);
console.log('Hangzhou tile NW =', hzDec.lat.toFixed(5), hzDec.lon.toFixed(5));