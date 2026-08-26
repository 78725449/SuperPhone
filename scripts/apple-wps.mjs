#!/usr/bin/env node
// Apple WPS (WiFi Positioning System) 取数论证脚本 —— WiFi 定位伪装方案链路 B 外部论证
//
// 背景：
//   iOS 的 WiFi 定位 = 设备把附近 BSSID 列表发给 Apple 的 gs-loc 服务，Apple 返回这些
//   BSSID 在数据库里登记的位置（众包：真实设备扫到 BSSID 时带上 GPS 坐标上报 Apple）。
//   本方案：抓取**目标城市真实存在的 BSSID**，未来注入 locationd 的模拟 WiFi 扫描，
//   让 Apple 定位链路反查命中目标区域（见 说明文档 §2.0 与 WiFi 定位伪装方案）。
//
// 协议依据（多开源实现交叉确认，2026-08 调研）：
//   - 端点：https://gs-loc.apple.com/clls/wloc（国际）/ https://gs-loc-cn.apple.com/clls/wloc（中国区）
//   - 请求体 = ARPC 定长头部 + protobuf(AppleWLoc)；响应 = 10B 帧头 + protobuf
//   - 参考实现（逐字节对齐）：
//     * acheong08/apple-corelocation-experiments —— lib/arpc.go（ARPC 头）、lib/wloc.go、
//       lib/constants.go（headers/locale/os 版本）、pb/BSSIDApple.proto（schema）
//     * hubert3/iSniff-GPS、darkosancanin/apple_bssid_locator
//   - 坐标编码 int64 = 度 × 1e8（定点）
//   - field4 num_wifi_results 为 sint32：-1 禁用、0 返回全部邻域（默认）、正数限数量
//
// 用法：
//   node apple-wps.mjs query --bssid AA:BB:CC:DD:EE:FF [--china]
//   node apple-wps.mjs expand --seed AA:BB:CC:DD:EE:FF --lat 30.30 --lon 120.10 --radius-km 25 --max 800 [--china]
//
// 输出：
//   query  -> 打印邻域 AP 列表（BSSID + 坐标，坐标×1e-8 定点转浮点）
//   expand -> 以 seed 为起点做邻域膨胀，收集目标半径内的 BSSID，JSON 落盘

// ---------- 手写 protobuf 编解码 ----------
// 对齐 pb/BSSIDApple.proto（proto3）：
//   message WifiDevice { string bssid = 1; optional Location location = 2; }
//   message AppleWLoc {
//     repeated WifiDevice wifi_devices = 2;
//     optional sint32 num_cell_results = 3;
//     optional sint32 num_wifi_results = 4; // -1 禁用, 0 全部
//     optional string app_bundle_id = 5;
//     optional DeviceType device_type = 33; // 必带（服务端校验相关）
//   }
//   message DeviceType { string operating_system = 1; string model = 2; }
//   message Location { optional int64 latitude = 1; optional int64 longitude = 2; }

function varint(value) {
  const bytes = [];
  let v = BigInt(value) & 0xffffffffffffffffn;
  if (v < 0n) v = v + (1n << 64n);
  while (true) {
    if (v < 0x80n) { bytes.push(Number(v)); break; }
    bytes.push(Number((v & 0x7fn) | 0x80n));
    v >>= 7n;
  }
  return Buffer.from(bytes);
}

function readVarint(buf, off) {
  let shift = 0n;
  let value = 0n;
  while (true) {
    const b = buf[off++];
    value |= BigInt(b & 0x7f) << shift;
    if (!(b & 0x80)) break;
    shift += 7n;
  }
  return { value, off };
}

function zigzag(value) {
  const v = BigInt(value);
  const masked = v & 0xffffffffffffffffn;
  return (masked << 1n) ^ (masked >> 63n);
}

// protobuf tag（fieldNo 可能 ≥32，必须 varint 编码，不能塞单字节）
function fieldTag(fieldNo, wireType) {
  return varint((BigInt(fieldNo) << 3n) | BigInt(wireType));
}

// 编码字符串字段（fieldNumber, wiretype 2）
function encFieldStr(fieldNo, s) {
  const buf = Buffer.from(s, 'utf8');
  return Buffer.concat([fieldTag(fieldNo, 2), varint(buf.length), buf]);
}

// 编码 varint 字段（fieldNumber, wiretype 0）
function encFieldVarint(fieldNo, v) {
  return Buffer.concat([fieldTag(fieldNo, 0), varint(v)]);
}

// 编码 sint32 字段（zigzag）
function encFieldSint32(fieldNo, v) {
  return encFieldVarint(fieldNo, zigzag(v));
}

// 编码 message 字段（fieldNumber, wiretype 2）
function encFieldMsg(fieldNo, body) {
  return Buffer.concat([fieldTag(fieldNo, 2), varint(body.length), body]);
}

function encodeWifiDevice(bssid) {
  return encFieldStr(1, bssid);
}

function encodeDeviceType(os, model) {
  return Buffer.concat([encFieldStr(1, os), encFieldStr(2, model)]);
}

function encodeAppleWLoc(bssid) {
  const parts = [];
  parts.push(encFieldMsg(2, encodeWifiDevice(bssid)));              // wifi_devices
  parts.push(encFieldSint32(3, 0));                                  // num_cell_results = 0
  parts.push(encFieldSint32(4, 0));                                  // num_wifi_results = 0 → 返回全部邻域
  parts.push(encFieldMsg(33, encodeDeviceType('iPhone OS17.5/21F79', 'iPhone12,1'))); // device_type
  return Buffer.concat(parts);
}

// ---------- ARPC 头部（对齐 lib/arpc.go Serialize） ----------
// uint16 version | pascal(locale) | pascal(appIdentifier) | pascal(osVersion)
// | uint32 functionId | uint32 payloadLen | payload
function buildArpcRequest(protobufBody, opts = {}) {
  const version = opts.version ?? 1;
  const locale = opts.locale ?? 'en-001_001';
  const appIdentifier = opts.appIdentifier ?? 'com.apple.locationd';
  const osVersion = opts.osVersion ?? '18.6.2.22G100';
  const functionId = opts.functionId ?? 1;
  const payloadBuf = Buffer.from(protobufBody);
  const head = Buffer.alloc(2 + (2 + locale.length) + (2 + appIdentifier.length) + (2 + osVersion.length) + 4 + 4, 0);
  let o = 0;
  head.writeUInt16BE(version, o); o += 2;
  o += pascalInto(head, o, locale);
  o += pascalInto(head, o, appIdentifier);
  o += pascalInto(head, o, osVersion);
  head.writeUInt32BE(functionId, o); o += 4;
  head.writeUInt32BE(payloadBuf.length, o); o += 4;
  return Buffer.concat([head, payloadBuf]);
}

function pascalInto(buf, off, s) {
  buf.writeUInt16BE(s.length, off);
  buf.write(s, off + 2, 'utf8');
  return 2 + s.length;
}

// ---------- 响应解析 ----------
function parseWifiDevices(buf) {
  const devices = [];
  let i = 0;
  while (i < buf.length) {
    const t = readVarint(buf, i);
    const fieldNum = Number(t.value >> 3n);
    const wireType = Number(t.value & 7n);
    i = t.off;
    if (fieldNum === 2 && wireType === 2) {
      const { value: len, off } = readVarint(buf, i);
      i = off;
      const payload = buf.subarray(i, i + Number(len));
      i += Number(len);
      const d = parseWifiDevice(payload);
      if (d) devices.push(d);
    } else if (wireType === 0) {
      i = readVarint(buf, i).off;
    } else if (wireType === 2) {
      const { value: len, off } = readVarint(buf, i); i = off + Number(len);
    } else if (wireType === 5) {
      i += 4;
    } else if (wireType === 1) {
      i += 8;
    }
  }
  return devices;
}

function parseWifiDevice(payload) {
  const dev = { bssid: '', lat: null, lon: null };
  let j = 0;
  while (j < payload.length) {
    const t = readVarint(payload, j);
    const fieldNum = Number(t.value >> 3n);
    const wireType = Number(t.value & 7n);
    j = t.off;
    if (fieldNum === 1 && wireType === 2) {
      const { value: len, off } = readVarint(payload, j); j = off;
      dev.bssid = payload.subarray(j, j + Number(len)).toString('utf8');
      j += Number(len);
    } else if (fieldNum === 2 && wireType === 2) {
      const { value: len, off } = readVarint(payload, j); j = off;
      const loc = parseLocation(payload.subarray(j, j + Number(len)));
      j += Number(len);
      dev.lat = loc.lat;
      dev.lon = loc.lon;
    } else if (wireType === 0) {
      j = readVarint(payload, j).off;
    } else if (wireType === 2) {
      const { value: len, off } = readVarint(payload, j); j = off + Number(len);
    } else if (wireType === 5) {
      j += 4;
    } else if (wireType === 1) {
      j += 8;
    }
  }
  return dev;
}

function parseLocation(payload) {
  const loc = { lat: null, lon: null };
  let j = 0;
  while (j < payload.length) {
    const t = readVarint(payload, j);
    const fieldNum = Number(t.value >> 3n);
    const wireType = Number(t.value & 7n);
    j = t.off;
    if (wireType === 0) {
      const { value, off } = readVarint(payload, j);
      j = off;
      // int64 负数 = 64 位补码，修正符号后除以 1e8
      let signed = Number(value);
      if ((value & 0x8000000000000000n) !== 0n) signed = Number(value - (1n << 64n));
      if (fieldNum === 1) loc.lat = signed / 1e8;
      if (fieldNum === 2) loc.lon = signed / 1e8;
    } else if (wireType === 2) {
      const { value: len, off } = readVarint(payload, j); j = off + Number(len);
    } else if (wireType === 5) {
      j += 4;
    } else if (wireType === 1) {
      j += 8;
    }
  }
  return loc;
}

// Apple 以 (-180,-180) 哨兵表示库中未知 BSSID（对齐 Go 参考实现）
function isValidCoord(d) {
  return d.lat !== null && d.lon !== null && !(d.lat === -180 && d.lon === -180);
}

// ---------- WLOC 请求封装 ----------
const DEFAULT_HEADERS = {
  'Content-Type': 'application/x-www-form-urlencoded',
  'Accept': '*/*',
  'Accept-Charset': 'utf-8',
  'Accept-Language': 'en-us',
  'User-Agent': 'locationd/2890.16.16 CFNetwork/1496.0.7 Darwin/23.5.0',
};

async function wlocQuery(bssid, { china = false, timeout = 15000, debug = false } = {}) {
  const host = china ? 'gs-loc-cn.apple.com' : 'gs-loc.apple.com';
  const body = buildArpcRequest(encodeAppleWLoc(bssid));
  if (debug) console.log(`[debug] request ${body.length}B: ${body.toString('hex')}`);
  const res = await fetch(`https://${host}/clls/wloc`, {
    method: 'POST',
    headers: DEFAULT_HEADERS,
    body,
    signal: AbortSignal.timeout(timeout),
  });
  if (!res.ok) {
    const raw = Buffer.from(await res.arrayBuffer());
    throw new Error(`HTTP ${res.status} ${res.statusText} body[${raw.length}B]: ${raw.toString('hex').slice(0, 400)}`);
  }
  const raw = Buffer.from(await res.arrayBuffer());
  // 响应 = 10B 帧头 + protobuf
  const proto = raw.subarray(10);
  return parseWifiDevices(proto);
}

// ---------- WiFi Tiles（wifi_request_tile 瓦片取数） ----------
// 协议依据：acheong08/apple-corelocation-experiments
//  - 端点 https://gspe85-ssl.ls.apple.com/wifi_request_tile（中国区 gspe85-cn-ssl.ls.apple.com）
//  - GET + X-tilekey 头；响应 = 纯 protobuf（无 ARPC 前缀），schema 见 pb/wifiTiles.proto
//  - tile key = morton 编码的 OSM(Web Mercator) 瓦片坐标，level 13 与 Go 参考实现一致
const TILE_HOSTS = {
  intl: 'https://gspe85-ssl.ls.apple.com',
  cn: 'https://gspe85-cn-ssl.ls.apple.com',
};
const TILE_HEADERS = {
  'Accept': '*/*',
  'Connection': 'keep-alive',
  'User-Agent': 'geod/1 CFNetwork/1496.0.7 Darwin/23.5.0',
  'Accept-Language': 'en-US,en-GB;q=0.9,en;q=0.8',
  'X-os-version': '17.5.21F79',
};
const MIN_LAT = -85.05112878, MAX_LAT = 85.05112878, MIN_LON = -180, MAX_LON = 180;
function clip(v, min, max) { return Math.min(Math.max(v, min), max); }

// buckhx/tiles coordinate.go ToPixel(带 +0.5 像素舍入)→ToTile：返回 OSM 瓦片 (tx, ty)
function latLonToTile(lat, lon, z) {
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

// morton.Pack/Unpack（lib/morton/morton.go 逐行对拍；level=13 时 key < 2^27，BigInt 保精度）
function packTileKey(row, column, level) {
  let result = 1n << BigInt(level << 1);
  for (let i = 0; i < level; i++) {
    if (column & 1) result += 1n << BigInt(2 * i);
    if (row & 1) result += 1n << BigInt(2 * i + 1);
    column >>= 1;
    row >>= 1;
  }
  return result;
}

function unpackTileKey(key) {
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

// FromTile：瓦片 NW 角经纬度（buckhx pixel.go ToCoords 逆变换）
function tileToNW(row, column, level) {
  const size = 256 << level;
  const x = clip(column * 256, 0, size - 1) / size - 0.5;
  const y = 0.5 - clip(row * 256, 0, size - 1) / size;
  const lat = 90 - (360 * Math.atan(Math.exp(-y * 2 * Math.PI))) / Math.PI;
  const lon = 360 * x;
  return { lat, lon };
}

// 瓦片响应 bssid 为 int64（大端 8 字节取低 6 字节，对齐 lib/mac/mac.go Decode）
function macFromInt64(v) {
  const hex = v.toString(16).padStart(16, '0');
  return hex.slice(-12).match(/.{2}/g).join(':');
}

// 按 target 城市粗略选区（shapefile 的极简替代）：中国大陆 bbox 启发式
// 注意：港澳台/边境城市会误判（真分界需 shapefile 判定），可 --china/--intl 显式指定
function pickTileHost(lat, lon, mode) {
  if (mode === 'cn') return TILE_HOSTS.cn;
  if (mode === 'intl') return TILE_HOSTS.intl;
  if (lat >= 18 && lat <= 54 && lon >= 73 && lon <= 135) return TILE_HOSTS.cn;
  return TILE_HOSTS.intl;
}

// 解析 WifiTile proto：repeated Region(3){ repeated Device(2){ bssid=5 int64, entry=6{ lat=1/long=2 sfixed32 } } }
function parseWifiTile(buf) {
  const aps = [];
  let i = 0;
  while (i < buf.length) {
    const t = readVarint(buf, i);
    const fieldNum = Number(t.value >> 3n);
    const wireType = Number(t.value & 7n);
    i = t.off;
    if (fieldNum === 3 && wireType === 2) {
      const { value: len, off } = readVarint(buf, i); i = off;
      const regionEnd = i + Number(len);
      while (i < regionEnd) {
        const rt = readVarint(buf, i);
        const rf = Number(rt.value >> 3n);
        const rw = Number(rt.value & 7n);
        i = rt.off;
        if (rf === 2 && rw === 2) {
          const { value: dlen, off: doff } = readVarint(buf, i); i = doff;
          const devEnd = i + Number(dlen);
          let bssid = null, lat = null, lon = null;
          while (i < devEnd) {
            const dt = readVarint(buf, i);
            const df = Number(dt.value >> 3n);
            const dw = Number(dt.value & 7n);
            i = dt.off;
            if (df === 5 && dw === 0) {
              const { value, off } = readVarint(buf, i); i = off;
              bssid = macFromInt64(value);
            } else if (df === 6 && dw === 2) {
              const { value: elen, off: eoff } = readVarint(buf, i); i = eoff;
              const entryEnd = i + Number(elen);
              while (i < entryEnd) {
                const et = readVarint(buf, i);
                const ef = Number(et.value >> 3n);
                const ew = Number(et.value & 7n);
                i = et.off;
                if (ew === 5) {
                  const raw = buf.readInt32LE(i); i += 4;
                  if (ef === 1) lat = raw / 1e7;
                  else if (ef === 2) lon = raw / 1e7;
                } else if (ew === 0) { i = readVarint(buf, i).off; }
                else if (ew === 2) { const { value: l2, off: o2 } = readVarint(buf, i); i = o2 + Number(l2); }
                else if (ew === 1) { i += 8; }
              }
            } else if (dw === 0) { i = readVarint(buf, i).off; }
            else if (dw === 2) { const { value: l2, off: o2 } = readVarint(buf, i); i = o2 + Number(l2); }
            else if (dw === 5) { i += 4; }
            else if (dw === 1) { i += 8; }
          }
          if (bssid && lat !== null && lon !== null) aps.push({ bssid, lat, lon });
        } else if (rw === 0) { i = readVarint(buf, i).off; }
        else if (rw === 2) { const { value: l2, off: o2 } = readVarint(buf, i); i = o2 + Number(l2); }
        else if (rw === 5) { i += 4; }
        else if (rw === 1) { i += 8; }
      }
    } else if (wireType === 0) { i = readVarint(buf, i).off; }
    else if (wireType === 2) { const { value: len, off } = readVarint(buf, i); i = off + Number(len); }
    else if (wireType === 5) { i += 4; }
    else if (wireType === 1) { i += 8; }
  }
  return aps;
}

async function tileQuery(lat, lon, { level = 13, mode = null, timeout = 15000, debug = false } = {}) {
  const { tx, ty } = latLonToTile(lat, lon, level);
  const key = packTileKey(ty, tx, level);
  const host = pickTileHost(lat, lon, mode);
  const url = `${host}/wifi_request_tile`;
  if (debug) console.log(`[debug] tile(${tx},${ty}) z${level} key=${key} host=${host}`);
  const res = await fetch(url, {
    headers: { ...TILE_HEADERS, 'X-tilekey': key.toString() },
    signal: AbortSignal.timeout(timeout),
  });
  if (!res.ok) {
    const raw = Buffer.from(await res.arrayBuffer());
    throw new Error(`HTTP ${res.status} ${res.statusText} body[${raw.length}B]: ${raw.toString('hex').slice(0, 400)}`);
  }
  const raw = Buffer.from(await res.arrayBuffer());
  return { key, host, aps: parseWifiTile(raw) };
}

// ---------- CLI ----------
function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith('--')) {
        args[key] = next; i++;
      } else {
        args[key] = true;
      }
    } else {
      args._.push(a);
    }
  }
  return args;
}

function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

const usage = `用法:
  node apple-wps.mjs query  --bssid AA:BB:CC:DD:EE:FF [--china]
  node apple-wps.mjs expand --seed AA:BB:CC:DD:EE:FF --lat 30.30 --lon 120.10 [--radius-km 25] [--max 800] [--china] [--out out.json]`;

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._[0];

  if (cmd === 'tile') {
    const lat = parseFloat(args.lat);
    const lon = parseFloat(args.lon);
    const level = parseInt(args.level ?? '13');
    if (Number.isNaN(lat) || Number.isNaN(lon)) {
      console.log('tile 需要 --lat --lon');
      process.exit(1);
    }
    const mode = args.china ? 'cn' : args.intl ? 'intl' : null;
    const t0 = Date.now();
    const { key, host, aps } = await tileQuery(lat, lon, { level, mode, debug: !!args.debug });
    const tile = tileToNW(unpackTileKey(key).row, unpackTileKey(key).column, unpackTileKey(key).level);
    console.log(`瓦片 key=${key} host=${host} 瓦片NW=(${tile.lat.toFixed(5)}, ${tile.lon.toFixed(5)}) AP=${aps.length} 耗时 ${Date.now() - t0}ms`);
    const withCoord = aps.filter(a => a.lat !== null && a.lon !== null);
    for (const a of withCoord.slice(0, 30)) {
      console.log(`  ${a.bssid}  ${a.lat.toFixed(6)}, ${a.lon.toFixed(6)}`);
    }
    if (withCoord.length > 30) console.log(`  ... 其余 ${withCoord.length - 30} 个省略`);
    if (args.out) {
      const fs = await import('node:fs');
      const json = { generatedAt: new Date().toISOString(), host, tileKey: key.toString(), level, centerLat: lat, centerLon: lon, tileNW: tile, total: withCoord.length, aps: withCoord };
      fs.writeFileSync(args.out, JSON.stringify(json, null, 2));
      console.log(`已写入 ${args.out}`);
    }
    return;
  }

  if (!cmd) { console.log(usage); return; }

  if (cmd === 'query') {
    if (!args.bssid) { console.log('缺少 --bssid'); process.exit(1); }
    const t0 = Date.now();
    console.log(`查询 ${args.bssid}（${args.china ? '中国区' : '国际区'}）...`);
    const devices = await wlocQuery(args.bssid, { china: !!args.china, debug: !!args.debug });
    const found = devices.filter(isValidCoord);
    console.log(`返回 ${devices.length} 个 AP（含坐标 ${found.length} 个），耗时 ${Date.now() - t0}ms`);
    for (const d of found.slice(0, 50)) {
      console.log(`  ${d.bssid}  ${d.lat.toFixed(6)}, ${d.lon.toFixed(6)}`);
    }
    if (found.length > 50) console.log(`  ... 其余 ${found.length - 50} 个省略`);
    return;
  }

  if (cmd === 'expand') {
    const seed = (args.seed || '').toLowerCase();
    const lat = parseFloat(args.lat);
    const lon = parseFloat(args.lon);
    const radiusKm = parseFloat(args.radiusKm ?? args['radius-km'] ?? 25);
    const max = parseInt(args.max ?? '800');
    if (!seed || Number.isNaN(lat) || Number.isNaN(lon)) {
      console.log('expand 需要 --seed --lat --lon');
      process.exit(1);
    }
    const out = args.out ?? `wps-expand-${Date.now()}.json`;
    const seen = new Set([seed]);
    const queue = [seed];
    let total = 0;
    const results = [];
    const startedAt = Date.now();
    console.log(`膨胀开始 seed=${seed} 中心=(${lat},${lon}) 半径=${radiusKm}km`);
    while (queue.length && total < max) {
      const cur = queue.shift();
      let devices;
      try {
        devices = await wlocQuery(cur, { china: !!args.china });
      } catch (e) {
        console.log(`  查询 ${cur} 失败: ${e.message}`);
        continue;
      }
      const found = devices.filter(isValidCoord);
      let nearCount = 0;
      for (const d of found) {
        const dist = haversine(lat, lon, d.lat, d.lon);
        if (dist <= radiusKm) {
          nearCount++;
          total++;
          results.push({ bssid: d.bssid, lat: d.lat, lon: d.lon, distKm: Number(dist.toFixed(2)) });
          if (!seen.has(d.bssid)) { seen.add(d.bssid); queue.push(d.bssid); }
        }
      }
      console.log(`  ${cur} -> ${found.length} AP, 半径内 ${nearCount}, 累计 ${total}, 待展开 ${queue.length}`);
    }
    const fs = await import('node:fs');
    const json = { generatedAt: new Date().toISOString(), china: !!args.china, centerLat: lat, centerLon: lon, radiusKm, total, bssids: results };
    fs.writeFileSync(out, JSON.stringify(json, null, 2));
    console.log(`完成: ${total} 个目标城市 BSSID，写入 ${out}，耗时 ${((Date.now() - startedAt) / 1000).toFixed(1)}s`);
    return;
  }

  console.log(usage);
}

main().catch(e => {
  console.error('错误:', e.message);
  process.exit(1);
});