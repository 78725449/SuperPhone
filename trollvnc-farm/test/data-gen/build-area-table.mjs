// 构建期脚本：权威数据源 → 静态表（数据源严谨原则，用户定案 2026-08-25）
// 数据源：province-city-china@8.5.8（npm，民政部行政区划 + district-code 国内长途区号），vendor 于 area-data/
// 产出1 area-codes.json    { "城市名": { "province": "省", "areaCode": "755" } }（全国地级行政区，区号去前导0）
// 产出2 regions.json       [{ "province": "河北省", "cities": ["石家庄市", ...] }]（省→市两级，喂 BRPickerView）
// 产出3 TRAreaCodes.mm/.h  ObjC 静态表（App 无 Node 运行时，构建期生成提交）
// 产出4 number-segments.json 完整手机号段（工信部《电信网编号计划》已分配号段，非抽样）
// 校验（硬性门禁）：区号条目≥300 / 区号格式 0\d{2,3} / 直辖市 010·021·022·023 / 省关联失败≈0
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const areaData = join(here, 'area-data');
const read = (p) => JSON.parse(readFileSync(join(here, p), 'utf8'));

const district = read('area-data/district-code.json'); // [{name:'石家庄市', code:'0311'}]
const region = read('area-data/region-data.json');     // [{code,name,province,city,area,town}]

// ---- 省级/地级关联（region-data：province 字段 = 省级 code 前两位） ----
const provNameByPrefix = {};
for (const r of region) if (r.city === 0 && r.area === 0 && r.province) provNameByPrefix[r.province] = r.name;

// 主表 = region-data 地级市（2021 民政部行政区划，province 关联天然正确）；
// district-code 仅提供区号（旧表含已撤销城市如巢湖/莱芜，不以它为主表）
const dcByName = {};
for (const d of district) dcByName[d.name] = d.code;

const MUNICIPALITIES = ['北京市', '上海市', '天津市', '重庆市'];
const stripSuffix = (n) => n.replace(/市$/, '').replace(/省$/, '').replace(/特别行政区$/, '').replace(/壮族自治区$/, '').replace(/回族自治区$/, '').replace(/维吾尔自治区$/, '').replace(/自治区$/, '');

// ---- 组装 area-codes（地级市 + 直辖市） ----
const areaCodes = {};   // { "石家庄": { province: "河北", areaCode: "311" } }
const failAssoc = [];
const failNoArea = [];  // region 有但 district-code 无区号（改名/新设）
for (const r of region) if (r.city && r.area === 0) {
  const pn = provNameByPrefix[r.province];
  const rawCode = dcByName[r.name];
  if (!pn) { failAssoc.push(`省关联失败: ${r.name}`); continue; }
  if (!rawCode) { failNoArea.push(r.name); continue; }
  if (!/^0\d{2,3}$/.test(rawCode)) { failAssoc.push(`区号格式非法: ${r.name} ${rawCode}`); continue; }
  areaCodes[stripSuffix(r.name)] = { province: stripSuffix(pn), areaCode: rawCode.replace(/^0/, '') };
}
for (const m of MUNICIPALITIES) {
  const rawCode = dcByName[m];
  if (rawCode && /^0\d{2,3}$/.test(rawCode)) {
    areaCodes[stripSuffix(m)] = { province: stripSuffix(m), areaCode: rawCode.replace(/^0/, '') };
  }
}

// ---- 省市两级（regions.json，喂选择器；直辖市单列） ----
const provCityMap = {};
for (const r of region) if (r.city && r.area === 0) {
  const pn = provNameByPrefix[r.province];
  if (pn) (provCityMap[pn] = provCityMap[pn] || []).push(r.name);
}
for (const m of MUNICIPALITIES) provCityMap[m] = [m];
const regions = [];
for (const [pn, cities] of Object.entries(provCityMap)) {
  regions.push({ province: pn, cities: cities.sort((a, b) => a.localeCompare(b, 'zh')) });
}
regions.sort((a, b) => a.province.localeCompare(b.province, 'zh'));

// ---- ObjC 静态表（TRAreaCodes.mm / .h） ----
const sortedKeys = Object.keys(areaCodes).sort((a, b) => a.localeCompare(b, 'zh'));
const entries = sortedKeys.map((k) => `            @"${k}": @"${areaCodes[k].areaCode}"`).join(',\n');
const mm = `// TRAreaCodes.mm —— 构建产物（勿手改，改源数据后重跑 build-area-table.mjs）
// 数据源：province-city-china@8.5.8（民政部，npm）district-code；构建于 ${new Date().toISOString().slice(0, 10)}
#import "TRAreaCodes.h"

static NSDictionary *trAreaCodeTable(void) {
    static NSDictionary *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{
${entries}
        };
    });
    return t;
}

NSString *trAreaCodeForCity(NSString *city) {
    NSString *v = trAreaCodeTable()[city];
    return v ?: @"10"; // 缺省北京
}
`;
const h = `// TRAreaCodes.h —— 构建产物（勿手改）
#import <Foundation/Foundation.h>

/// 城市(中文名) → 国内长途区号（去前导 0）；缺省 @"10"（北京）
NSString *trAreaCodeForCity(NSString *city);
`;
writeFileSync(join(here, 'TRAreaCodes.mm'), mm);
writeFileSync(join(here, 'TRAreaCodes.h'), h);

// ---- 完整手机号段（工信部《电信网编号计划》已分配号段，非抽样） ----
const SEGMENTS = [
  '130','131','132','133','134','135','136','137','138','139',
  '145','146','147','148','149','150','151','152','153','155','156','157','158','159',
  '162','165','166','167','170','171','172','173','174','175','176','177','178',
  '180','181','182','183','184','185','186','187','188','189',
  '190','191','193','194','195','196','198','199',
];
const segUnique = new Set(SEGMENTS);
const segBad = SEGMENTS.filter((s) => !/^1[3-9]\d$/.test(s) || segUnique.size !== SEGMENTS.length);
writeFileSync(join(here, 'number-segments.json'), JSON.stringify(SEGMENTS, null, 0));

// ---- 产出 ----
writeFileSync(join(here, 'area-codes.json'), JSON.stringify(areaCodes, null, 2));
writeFileSync(join(here, 'regions.json'), JSON.stringify(regions, null, 1));

// ---- 校验（硬性门禁） ----
const errs = [];
if (Object.keys(areaCodes).length < 300) errs.push(`区号条目不足: ${Object.keys(areaCodes).length}/300`);
if (areaCodes['北京']?.areaCode !== '10') errs.push('北京区号错误');
if (areaCodes['上海']?.areaCode !== '21') errs.push('上海区号错误');
if (areaCodes['天津']?.areaCode !== '22') errs.push('天津区号错误');
if (areaCodes['重庆']?.areaCode !== '23') errs.push('重庆区号错误');
if (failAssoc.length > 0) errs.push(`省关联失败 ${failAssoc.length} 条: ${failAssoc.slice(0, 5).join('; ')}`);
if (segBad.length) errs.push(`号段非法: ${segBad.join(',')}`);
if (regions.length < 31) errs.push(`省级不足: ${regions.length}/31`);

if (errs.length) {
  console.error('✗ build-area-table 校验失败:\n' + errs.join('\n'));
  process.exit(1);
}
console.log(`✓ area-codes: ${Object.keys(areaCodes).length} 城市 / regions: ${regions.length} 省 / 号段: ${SEGMENTS.length} 个`);
console.log('✓ TRAreaCodes.mm/h、area-codes.json、regions.json、number-segments.json 已生成');
