// 数据生成算法断言 + 魔鬼测试（阶段 1 门禁：语料自检/占比/互斥/格式/分布/Zipf/可复现/极端稳定）
import { validateCorpus } from './corpus.js';
import { matchRole, generateRemark, ROLE_ORDER } from './role-lexicon.js';
import { generateContacts, AREA } from './contacts-gen.js';
import { generateCalls, CARRIER_SVC } from './calls-gen.js';
import { generateSms } from './sms-gen.js';

let pass = 0, fail = 0;
function check(name, cond, detail = '') {
  if (cond) { pass++; console.log(`  ✓ ${name}`); }
  else { fail++; console.error(`  ✗ ${name} ${detail}`); }
}
const PHONE_RE = /^1[3-9]\d{9}$/;
const LANDLINE_RE = /^0\d{2,3}\d{7,8}$/;

// ---- 0. 语料自检（corpus.js 规模/质量，规格 §1.2）----
{
  console.log('== corpus ==');
  const errs = validateCorpus();
  check('语料规模与质量全过（姓名/词池/模板/品牌池达标、无未知变量、长度<70、词池互斥）', errs.length === 0, errs.join('; '));
}

// ---- 1. 联系人 ----
{
  console.log('== contacts ==');
  const cs = generateContacts({ count: 500, city: '杭州', seed: 42 });
  check('数量=500', cs.length === 500, `got ${cs.length}`);
  check('备注互斥反查 100% 命中', cs.every((c) => matchRole(c.name) === c.role));
  check('号码格式全部合法', cs.every((c) => PHONE_RE.test(c.phone) || LANDLINE_RE.test(c.phone)));
  check('号码无重复', new Set(cs.map((c) => c.phone)).size === cs.length);
  const rel = { friend: 0, work: 0, service: 0, family: 0, business: 0 };
  for (const c of cs) rel[c.role]++;
  const ratios = { friend: 0.55, work: 0.20, service: 0.12, family: 0.08, business: 0.05 };
  const okRel = ROLE_ORDER.every((r) => Math.abs(rel[r] / 500 - ratios[r]) <= 0.03);
  check('关系构成占比 ±3%（500 条）', okRel, JSON.stringify(rel));
  check('同 seed 可复现', JSON.stringify(generateContacts({ count: 500, city: '杭州', seed: 42 })) === JSON.stringify(cs));
  check('count=1 边界', generateContacts({ count: 1, city: '北京', seed: 1 }).length === 1);
  check('count=500 上限', generateContacts({ count: 500, city: '北京', seed: 1 }).length === 500);
  check('占比单极值(family=1) 不崩', generateContacts({ count: 50, city: '北京', seed: 1, ratios: { friend: 0, work: 0, service: 0, family: 1, business: 0 } }).every((c) => c.role === 'family'));
  check('regionLocal=0 全固话', generateContacts({ count: 20, city: '广州', seed: 2, regionLocal: 0 }).every((c) => LANDLINE_RE.test(c.phone)));
  check('regionLocal=1 全手机', generateContacts({ count: 20, city: '广州', seed: 2, regionLocal: 1 }).every((c) => PHONE_RE.test(c.phone)));
  check('数据源表完整性（条目≥300、直辖市区号正确）', Object.keys(AREA).length >= 300 && AREA['北京'].areaCode === '10' && AREA['深圳'].areaCode === '755');
}

// ---- 2. 通话 ----
{
  console.log('== calls ==');
  const contacts = [
    { name: '爸爸', phone: '13800000001' }, { name: '李强-科技', phone: '13800000002' },
    { name: '张伟', phone: '13800000003' }, { name: '王师傅', phone: '13800000004' },
    { name: '银行客服', phone: '13800000005' },
  ];
  const calls = generateCalls({ count: 100, days: 7, seed: 7, contacts });
  check('数量=100', calls.length === 100, `got ${calls.length}`);
  check('号码格式合法', calls.every((c) => PHONE_RE.test(c.phone) || Object.values(CARRIER_SVC).includes(c.phone)));
  check('未接 duration=0', calls.every((c) => (c.answered === 0) === (c.duration === 0)));
  check('运营商客服短号出现', calls.some((c) => Object.values(CARRIER_SVC).includes(c.phone)));
  const now = Date.now() / 1000;
  check('时间戳在窗口内', calls.every((c) => c.ts <= now + 10 && c.ts >= now - 7 * 86400 - 86400));
  check('同 seed 可复现', JSON.stringify(generateCalls({ count: 100, days: 7, seed: 7, contacts })) === JSON.stringify(calls));
  const stranger = calls.filter((c) => !c.name).map((c) => c.phone);
  const freq = {};
  for (const n of stranger) freq[n] = (freq[n] || 0) + 1;
  const maxFreq = Math.max(0, ...Object.values(freq));
  check('陌生号存在高频复用(Zipf)', maxFreq >= 3, `maxFreq=${maxFreq}`);
  check('count=1 边界', generateCalls({ count: 1, days: 1, seed: 1, contacts }).length === 1);
  check('通讯录空退化为陌生号', generateCalls({ count: 20, days: 3, seed: 3, contacts: [] }).every((c) => !c.name));
}

// ---- 3. 短信 ----
{
  console.log('== sms ==');
  const sms = generateSms({ count: 100, days: 7, seed: 11, carrier: 'cmcc', recentMissed: [{ phone: '13811112222' }] });
  check('数量=100', sms.length === 100, `got ${sms.length}`);
  check('服务类均 fromMe=false', sms.filter((s) => s.phone).every((s) => s.fromMe === false));
  check('inRatio=1 家人朋友全我发', generateSms({ count: 50, days: 3, seed: 5, inRatio: 1, ratios: { code: 0, express: 0, bank: 0, carrierSms: 0, marketing: 0, family: 1 } }).every((s) => s.fromMe === true));
  check('inRatio=0 家人朋友全我收', generateSms({ count: 50, days: 3, seed: 5, inRatio: 0, ratios: { code: 0, express: 0, bank: 0, carrierSms: 0, marketing: 0, family: 1 } }).every((s) => s.fromMe === false));
  check('非家人短信发件均为服务/特服号格式', sms.filter((s) => s.phone).every((s) => /^(10086|10010|10000|106\d{0,7}|101\d{0,7}|100\d{0,7}|95\d{3,5})$/.test(s.phone)));
  check('运营商短信发件=特服号', sms.some((s) => s.phone === '10086') && sms.filter((s) => s.phone === '10086').every((s) => !s.text.includes('尾号') && !s.text.includes('快件') && !s.text.includes('验证码')));
  check('内容非空', sms.every((s) => s.text && s.text.length > 0));
  check('同 seed 可复现', JSON.stringify(generateSms({ count: 100, days: 7, seed: 11, carrier: 'cmcc' })) === JSON.stringify(sms));
  check('count=1 边界', generateSms({ count: 1, days: 1, seed: 1 }).length === 1);
}

// ---- 4. 魔鬼测试：连续 100 轮随机 seed 不崩 + 不变量恒成立 ----
{
  console.log('== 魔鬼测试：100 轮 ==');
  let ok = true;
  for (let s = 0; s < 100; s++) {
    const countC = rngP(s, 1, 500), city = rngCity(s), rl = rngP(s, 0, 1);
    const cs = generateContacts({ count: countC, city, seed: s, regionLocal: rl });
    const contacts = cs.map((c) => ({ name: c.name, phone: c.phone }));
    const calls = generateCalls({ count: rngP(s, 1, 200), days: rngP(s, 1, 30), seed: s, contacts });
    const sms = generateSms({ count: rngP(s, 1, 300), days: rngP(s, 1, 30), seed: s, inRatio: rngP(s, 0, 1) });
    const fails = [];
    if (!cs.every((c) => matchRole(c.name) === c.role)) fails.push('联系人反查');
    if (!cs.every((c) => PHONE_RE.test(c.phone) || LANDLINE_RE.test(c.phone))) fails.push('联系人号码格式');
    if (new Set(cs.map((c) => c.phone)).size !== cs.length) fails.push('联系人号码重复');
    if (!calls.every((c) => (c.answered === 0) === (c.duration === 0))) fails.push('通话未接-时长');
    if (!sms.every((s2) => s2.text && s2.text.length > 0)) fails.push('短信空文本');
    if (fails.length) {
      console.error(`  seed=${s} params={count:${countC},city:${city},rl:${rl}} 失败: ${fails.join(',')}`);
      ok = false;
      break;
    }
  }
  check('100 轮随机 seed 全过（不变量恒成立）', ok);
}

function rngP(s, lo, hi) { const x = Math.sin(s * 999) * 10000; return lo + Math.floor((x - Math.floor(x)) * (hi - lo + 1)); }
function rngCity(s) { const keys = Object.keys(AREA); return keys[Math.abs(s) % keys.length]; }

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
