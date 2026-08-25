// 构建脚本：area-data/phone.dat（phone2region，MIT）→ TRHlr.mm/.h（城市→号段区间表）+ hlr-prefixes.json（Node 同构用）
// 运行：node test/data-gen/build-tr-hlr.mjs（cwd=trollvnc-farm）
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const buf = readFileSync(join(here, 'area-data', 'phone.dat'));
const indexOffset = buf.readInt32LE(4);
const size = (buf.length - indexOffset) / 9;

// 2026-08-26 过滤：剔除不可作普通手机号的前缀（与 build-area-table.mjs SEGMENTS 同清单）——
// 虚拟运营商 162/165/167/170/171、物联网 145/146/147/148/149、卫星移动 174（1740-1745 天通）；
// 另 134 内的 1349（卫星移动）为 4 位段，3 位粒度无法分离，此处按 7 位前缀单独过滤（1349000-1349999）。
const BAD_HEAD3 = new Set(['145','146','147','148','149','162','165','167','170','171','174']);
const isBadPrefix = (p) => {
  const head = String(Math.floor(p / 10000)); // 7 位前缀前 3 位
  if (BAD_HEAD3.has(head)) return true;
  return p >= 1349000 && p < 1350000;
};

// 解析索引 → 城市 → 前缀列表
const cityPrefix = new Map();
for (let i = 0; i < size; i++) {
  const prefix = buf.readInt32LE(indexOffset + i * 9);
  const infoOffset = buf.readInt32LE(indexOffset + i * 9 + 4);
  let end = infoOffset;
  while (end < buf.length && buf[end] !== 0x0a && buf[end] !== 0) end++;
  const content = buf.toString('utf8', infoOffset, end).replace(/\0/g, '');
  const city = (content.split('|')[1] || '').trim();
  if (!city) continue;
  if (isBadPrefix(prefix)) continue;
  if (!cityPrefix.has(city)) cityPrefix.set(city, []);
  cityPrefix.get(city).push(prefix);
}

// 相邻前缀合并为 [start, end] 区间
const cityRanges = new Map();
for (const [city, arr] of cityPrefix) {
  arr.sort((a, b) => a - b);
  const rs = [];
  let start = arr[0], prev = arr[0];
  for (let i = 1; i < arr.length; i++) {
    if (arr[i] === prev + 1) { prev = arr[i]; continue; }
    rs.push([start, prev]); start = prev = arr[i];
  }
  rs.push([start, prev]);
  cityRanges.set(city, rs);
}

// 城市按字典序排序（.mm 二分查找）
const cities = [...cityRanges.keys()].sort();

// 生成 .mm：单一 uint32 大数组 + 城市 {name, offset, count} 索引
let flat = [];
const meta = cities.map((city) => {
  const rs = cityRanges.get(city);
  const offset = flat.length / 2;
  for (const [s, e] of rs) { flat.push(s, e); }
  return { city, offset, count: rs.length };
});

const date = new Date().toISOString().slice(0, 10);
const rangesText = [];
for (let i = 0; i < flat.length; i += 10) {
  rangesText.push('    ' + flat.slice(i, i + 10).map((v) => `${v},`).join(' '));
}
const metaText = meta.map((m) => `    {"${m.city}", ${m.offset}, ${m.count}},`).join('\n');

const header = `// TRHlr.h —— 构建产物（勿手改，改 phone.dat 后重跑 build-tr-hlr.mjs；构建于 ${date}）
#import <Foundation/Foundation.h>
#import <stdint.h>

/// 手机号段归属地表（phone2region 数据源 → 静态区间表；城市名不带"市"后缀，与区号表一致）
/// kHlrRandomPrefix：随机取该城市归属的一个 7 位号段前缀；无数据返回 0
#ifdef __cplusplus
extern "C" {
#endif
uint32_t trHlrRandomPrefix(NSString *city);
NSInteger trHlrCityCount(void); // 表内城市数（测试/校验用）
#ifdef __cplusplus
}
#endif
`;

const mm = `// TRHlr.mm —— 构建产物（勿手改，改 phone.dat 后重跑 build-tr-hlr.mjs；构建于 ${date}）
// 数据源：phone2region（MIT，${size} 条号段索引 → ${cities.length} 城 / ${flat.length / 2} 区间）
#import "TRHlr.h"

static const uint32_t kHlrRanges[] = {
${rangesText.join('\n')}
};

static const struct { const char *city; int offset; int count; } kHlrCities[] = {
${metaText}
};
#define KHLCITY_COUNT (sizeof(kHlrCities) / sizeof(kHlrCities[0]))

NSInteger trHlrCityCount(void) { return (NSInteger)KHLCITY_COUNT; }

// 二分查城市（kHlrCities 已按字典序排列）；命中返回下标，未命中 -1
static NSInteger trHlrFindCity(NSString *city) {
    if (city.length == 0) return -1;
    NSInteger lo = 0, hi = (NSInteger)KHLCITY_COUNT - 1;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) / 2;
        NSComparisonResult r = [city compare:@(kHlrCities[mid].city)];
        if (r == NSOrderedSame) return mid;
        if (r == NSOrderedAscending) hi = mid - 1;
        else lo = mid + 1;
    }
    return -1;
}

uint32_t trHlrRandomPrefix(NSString *city) {
    NSInteger idx = trHlrFindCity(city);
    if (idx < 0) return 0;
    int off = kHlrCities[idx].offset;
    int count = kHlrCities[idx].count;
    // xorshift64（与 TRDataFiller trRand 同构常量），避免依赖调用方 PRNG 状态
    static uint64_t s = 0;
    if (!s) s = (uint64_t)[[NSDate date] timeIntervalSinceReferenceDate] * 1000.0 | 1;
    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    int ri = (int)(s % (uint64_t)count);
    uint32_t start = kHlrRanges[(off + ri) * 2];
    uint32_t end = kHlrRanges[(off + ri) * 2 + 1];
    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    return start + (uint32_t)(s % (end - start + 1));
}
`;

writeFileSync(join(here, '..', '..', '..', 'TrollVNC', 'src', 'TRHlr.h'), header);
writeFileSync(join(here, '..', '..', '..', 'TrollVNC', 'src', 'TRHlr.mm'), mm);

// Node 同构用 JSON：{city: [[s,e],...]}
const json = {};
for (const [city, rs] of cityRanges) json[city] = rs;
writeFileSync(join(here, 'hlr-prefixes.json'), JSON.stringify(json));

console.log(`TRHlr.h/.mm 已生成（${cities.length} 城 / ${flat.length / 2} 区间 / ${(mm.length / 1024).toFixed(0)} KB）+ hlr-prefixes.json`);
