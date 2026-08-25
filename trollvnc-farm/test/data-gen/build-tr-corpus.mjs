// 构建脚本：corpus.js → TRCorpus.h/.mm（ObjC 常量，App 无 Node 运行时；与 TRAreaCodes 同模式）
// 运行：node test/data-gen/build-tr-corpus.mjs（cwd=trollvnc-farm），输出到 ../../TrollVNC/src/
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const { FAMILY_NAMES, GIVEN_NAMES, NICKNAMES, ROLE_WORDS, SMS_TEMPLATES, BRAND_POOLS } =
  await import('./corpus.js');
const numberSegments = JSON.parse(readFileSync(join(here, 'number-segments.json'), 'utf8'));
const outDir = join(here, '..', '..', '..', 'TrollVNC', 'src');
const date = new Date().toISOString().slice(0, 10);

const arrFn = (name, arr) =>
  `NSArray *${name}(void) {\n    return @[\n${arr.map((x) => `        @"${x}",`).join('\n')}\n    ];\n}`;
const header = `// TRCorpus.h —— 构建产物（勿手改，改 corpus.js 后重跑 build-tr-corpus.mjs；构建于 ${date}）
// 语料单一数据源：trollvnc-farm/test/data-gen/corpus.js（规格 §1.2，营销行业分组）
#import <Foundation/Foundation.h>

NSArray<NSString *> *kFamilyNames(void);
NSArray<NSString *> *kGivenNames(void);
NSArray<NSString *> *kNicknames(void);
NSArray<NSString *> *kFamilyWords(void);
NSArray<NSString *> *kServiceWords(void);
NSArray<NSString *> *kBusinessWords(void);
NSArray<NSString *> *kWorkWords(void);
NSArray<NSString *> *kSmsCodeTexts(void);
NSArray<NSString *> *kSmsExpressTexts(void);
NSArray<NSString *> *kSmsBankTexts(void);
NSArray<NSString *> *kSmsCarrierTexts(void);
NSArray<NSString *> *kSmsMarketingIndustries(void);
NSArray<NSString *> *kSmsFamilyTexts(void);
NSArray<NSString *> *kBanks(void);
NSArray<NSString *> *kCouriers(void);
NSArray<NSString *> *kPlatforms(void);
NSArray<NSString *> *kStations(void);
NSArray<NSString *> *kEstates(void);
NSArray<NSString *> *kOrgs(void);
NSArray<NSString *> *kProducts(void);
NSArray<NSString *> *kEcoms(void);
NSArray<NSString *> *kBrands(void);
NSArray<NSString *> *kPhoneSegments(void);
`;

const mktIndustries = Object.entries(SMS_TEMPLATES.marketing).map(([g, v]) =>
  `    @{@"brands": @[${v.brands.map((b) => `@"${b}"`).join(', ')}], @"templates": @[\n${v.templates.map((t) => `        @"${t}",`).join('\n')}\n    ]}`).join(',\n');

const mm = `// TRCorpus.mm —— 构建产物（勿手改，改 corpus.js 后重跑 build-tr-corpus.mjs；构建于 ${date}）
#import "TRCorpus.h"

${arrFn('kFamilyNames', FAMILY_NAMES)}

${arrFn('kGivenNames', GIVEN_NAMES)}

${arrFn('kNicknames', NICKNAMES)}

${arrFn('kFamilyWords', ROLE_WORDS.family)}

${arrFn('kServiceWords', ROLE_WORDS.service)}

${arrFn('kBusinessWords', ROLE_WORDS.business)}

${arrFn('kWorkWords', ROLE_WORDS.work)}

${arrFn('kSmsCodeTexts', SMS_TEMPLATES.code)}

${arrFn('kSmsExpressTexts', SMS_TEMPLATES.express)}

${arrFn('kSmsBankTexts', SMS_TEMPLATES.bank)}

${arrFn('kSmsCarrierTexts', SMS_TEMPLATES.carrierSms)}

NSArray *kSmsMarketingIndustries(void) {
    return @[
${mktIndustries}
    ];
}

${arrFn('kSmsFamilyTexts', SMS_TEMPLATES.family)}

${arrFn('kBanks', BRAND_POOLS.banks)}

${arrFn('kCouriers', BRAND_POOLS.couriers)}

${arrFn('kPlatforms', BRAND_POOLS.platforms)}

${arrFn('kStations', BRAND_POOLS.stations)}

${arrFn('kEstates', BRAND_POOLS.estates)}

${arrFn('kOrgs', BRAND_POOLS.orgs)}

${arrFn('kProducts', BRAND_POOLS.products)}

${arrFn('kEcoms', BRAND_POOLS.ecoms)}

${arrFn('kBrands', BRAND_POOLS.brands)}

${arrFn('kPhoneSegments', numberSegments)}
`;

writeFileSync(join(outDir, 'TRCorpus.h'), header);
writeFileSync(join(outDir, 'TRCorpus.mm'), mm);
console.log('TRCorpus.h/.mm 已生成 →', outDir);
