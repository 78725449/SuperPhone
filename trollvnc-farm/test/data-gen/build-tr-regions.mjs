// 构建脚本：regions.json → TRRegions.mm/.h（省市两级树，喂 BRTextPickerView dataSourceArr）
// 运行：node test/data-gen/build-tr-regions.mjs（cwd=trollvnc-farm），输出到 ../../TrollVNC/src/
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const regions = JSON.parse(readFileSync(join(here, 'regions.json'), 'utf8'));
const outDir = join(here, '..', '..', '..', 'TrollVNC', 'src');
const date = new Date().toISOString().slice(0, 10);

// regions.json: [{province, cities:[...]}] → BRTextModel 树 [{text, children:[{text}]}]
const tree = regions.map((r) => ({
  text: r.province,
  children: r.cities.map((c) => ({ text: c })),
}));
const entry = (o) => `@{@"text": @"${o.text}", @"children": @[${(o.children || []).map((c) => `@{@"text": @"${c.text}"}`).join(', ')}]}`;
const body = tree.map((t) => `    ${entry(t)},`).join('\n');

const header = `// TRRegions.h —— 构建产物（勿手改，改 regions.json 后重跑 build-tr-regions.mjs；构建于 ${date}）
#import <Foundation/Foundation.h>

/// 省市两级树（民政部数据源 → regions.json），喂 BRTextPickerView dataSourceArr
/// 格式：NSArray<NSDictionary*>{text:省, children:[{text:市}]}
NSArray *kRegions(void);
`;

const mm = `// TRRegions.mm —— 构建产物（勿手改，改 regions.json 后重跑 build-tr-regions.mjs；构建于 ${date}）
#import "TRRegions.h"

NSArray *kRegions(void) {
    return @[
${body}
    ];
}
`;

writeFileSync(join(outDir, 'TRRegions.h'), header);
writeFileSync(join(outDir, 'TRRegions.mm'), mm);
console.log('TRRegions.h/.mm 已生成 →', outDir, `（${tree.length} 省）`);
