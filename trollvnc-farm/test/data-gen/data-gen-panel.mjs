// 模拟调参面板（用户定案 2026-08-25）：模拟 App 三 Tab 参数面板的离散档位组合
// 矩阵化批量生成 + 自动审查（反查/格式/去重/占比偏差/未接时长/发件格式/收发比），输出调参报告
// 比 data-gen-test 更刁钻：覆盖 UI 实际会产生的档位组合（边界 + 典型 + 极端），纳入 npm test
import { matchRole } from './role-lexicon.js';
import { generateContacts, AREA } from './contacts-gen.js';
import { generateCalls, CARRIER_SVC } from './calls-gen.js';
import { generateSms } from './sms-gen.js';

const PHONE_RE = /^1[3-9]\d{9}$/;
const LANDLINE_RE = /^0\d{2,3}\d{7,8}$/;
const SVC_PHONE_RE = /^(10086|10010|10000|106\d{0,8}|95\d{3,5}|111\d{2,4})$/;

let pass = 0, fail = 0;
const failures = [];
function check(caseName, name, cond, detail = '') {
  if (cond) { pass++; }
  else { fail++; failures.push(`[${caseName}] ${name} ${detail}`); }
}

// ---------- 联系人面板档位 ----------
const contactCases = [
  { name: '北京/默认/本地65/100', params: { count: 100, city: '北京', regionLocal: 0.65 } },
  { name: '杭州/家庭重/本地80/100', params: { count: 100, city: '杭州', regionLocal: 0.8, ratios: { friend: 0.30, work: 0.10, service: 0.05, family: 0.5, business: 0.05 } } },
  { name: '广州/工作重/本地50/100', params: { count: 100, city: '广州', regionLocal: 0.5, ratios: { friend: 0.30, work: 0.50, service: 0.10, family: 0.05, business: 0.05 } } },
  { name: '成都/服务重/本地90/100', params: { count: 100, city: '成都', regionLocal: 0.9, ratios: { friend: 0.20, work: 0.10, service: 0.55, family: 0.05, business: 0.10 } } },
  { name: '武汉/机构重/本地30/100', params: { count: 100, city: '武汉', regionLocal: 0.3, ratios: { friend: 0.20, work: 0.10, service: 0.10, family: 0.10, business: 0.50 } } },
  { name: '深圳/默认/本地0/100(全固话)', params: { count: 100, city: '深圳', regionLocal: 0 } },
  { name: '重庆/默认/本地1/100(全手机)', params: { count: 100, city: '重庆', regionLocal: 1 } },
  { name: '上海/默认/500(上限)', params: { count: 500, city: '上海' } },
  { name: '西安/默认/1(最小)', params: { count: 1, city: '西安' } },
  { name: '乌鲁木齐/默认/100', params: { count: 100, city: '乌鲁木齐' } },
  { name: '拉萨/默认/100', params: { count: 100, city: '拉萨' } },
  { name: '任意数据源城市×10', params: () => { const keys = Object.keys(AREA); const cs = []; for (let i = 0; i < 10; i++) cs.push({ count: 20, city: keys[(i * 37) % keys.length], seed: i }); return cs; } },
];
// ---------- 通话面板档位 ----------
const callCases = [
  { name: 'cmcc/3天/默认/100', params: { count: 100, days: 3, carrier: 'cmcc' } },
  { name: 'cucc/7天/陌生号重/100', params: { count: 100, days: 7, carrier: 'cucc', ratios: { contact: 0.5, stranger: 0.5 } } },
  { name: 'ctcc/1天/默认/200', params: { count: 200, days: 1, carrier: 'ctcc' } },
  { name: 'cmcc/30天/默认/1(最小)', params: { count: 1, days: 30, carrier: 'cmcc' } },
  { name: 'cucc/3天/呼出重/100', params: { count: 100, days: 3, carrier: 'cucc', ratios: { incoming: 0.2, outgoing: 0.6, missed: 0.2 } } },
  { name: 'ctcc/7天/未接重/100', params: { count: 100, days: 7, carrier: 'ctcc', ratios: { incoming: 0.3, outgoing: 0.3, missed: 0.4 } } },
  { name: 'cmcc/3天/联系人重/100', params: { count: 100, days: 3, carrier: 'cmcc', ratios: { contact: 0.9, stranger: 0.1 } } },
  { name: 'cmcc/3天/陌生号极重/100', params: { count: 100, days: 3, carrier: 'cmcc', ratios: { contact: 0.1, stranger: 0.9 } } },
  { name: 'cucc/30天/默认/200', params: { count: 200, days: 30, carrier: 'cucc' } },
  { name: 'ctcc/1天/默认/50', params: { count: 50, days: 1, carrier: 'ctcc' } },
  { name: 'cmcc/3天/默认/1(通讯录空)', params: { count: 1, days: 3, carrier: 'cmcc', contacts: [] } },
  { name: 'cmcc/3天/默认/100(通讯录20人)', params: { count: 100, days: 3, carrier: 'cmcc' } },
];
// ---------- 短信面板档位 ----------
const smsCases = [
  { name: 'cmcc/3天/收发2:8/默认/100', params: { count: 100, days: 3, carrier: 'cmcc', inRatio: 0.2 } },
  { name: 'cucc/7天/收发5:5/服务重/100', params: { count: 100, days: 7, carrier: 'cucc', inRatio: 0.5, ratios: { code: 0.5, express: 0.1, bank: 0.1, carrierSms: 0.1, marketing: 0.1, family: 0.1 } } },
  { name: 'ctcc/1天/收发8:2/100', params: { count: 100, days: 1, carrier: 'ctcc', inRatio: 0.8 } },
  { name: 'cmcc/30天/收发0:10/200', params: { count: 200, days: 30, carrier: 'cmcc', inRatio: 0 } },
  { name: 'cucc/3天/收发10:0/家庭重/100', params: { count: 100, days: 3, carrier: 'cucc', inRatio: 1, ratios: { code: 0.1, express: 0.1, bank: 0.05, carrierSms: 0.05, marketing: 0.1, family: 0.6 } } },
  { name: 'ctcc/7天/银行重/100', params: { count: 100, days: 7, carrier: 'ctcc', inRatio: 0.5, ratios: { code: 0.1, express: 0.1, bank: 0.5, carrierSms: 0.1, marketing: 0.1, family: 0.1 } } },
  { name: 'cmcc/3天/快递重/100', params: { count: 100, days: 3, carrier: 'cmcc', inRatio: 0.2, ratios: { code: 0.1, express: 0.5, bank: 0.1, carrierSms: 0.1, marketing: 0.1, family: 0.1 } } },
  { name: 'cucc/1天/收发9:1/100', params: { count: 100, days: 1, carrier: 'cucc', inRatio: 0.9 } },
  { name: 'ctcc/30天/运营商重/100', params: { count: 100, days: 30, carrier: 'ctcc', inRatio: 0.1, ratios: { code: 0.1, express: 0.1, bank: 0.05, carrierSms: 0.6, marketing: 0.05, family: 0.1 } } },
  { name: 'cmcc/7天/营销重/100', params: { count: 100, days: 7, carrier: 'cmcc', inRatio: 0.5, ratios: { code: 0.1, express: 0.1, bank: 0.1, carrierSms: 0.05, marketing: 0.6, family: 0.05 } } },
  { name: 'cucc/3天/默认/1(最小)', params: { count: 1, days: 3, carrier: 'cucc', inRatio: 0.2 } },
  { name: 'cmcc/3天/默认/300(上限)', params: { count: 300, days: 3, carrier: 'cmcc', inRatio: 0.2 } },
  { name: 'cmcc/3天/未接联动/100', params: { count: 100, days: 3, carrier: 'cmcc', inRatio: 0.5, recentMissed: [{ phone: '13811112222' }, { phone: '13933334444' }] } },
  { name: 'ctcc/3天/默认/100(无未接)', params: { count: 100, days: 3, carrier: 'ctcc', inRatio: 0.2 } },
];

// ---------- 执行与审查 ----------
const genContacts = (cs) => generateContacts(cs);
const contactsPool = generateContacts({ count: 20, city: '北京', seed: 7 }).map((c) => ({ name: c.name, phone: c.phone }));

console.log('== 联系人面板（12 档位 + 10 城扫描） ==');
for (const c of contactCases) {
  const cases = typeof c.params === 'function' ? c.params() : [{ ...c.params, contacts: undefined, seed: undefined, ratios: c.params.ratios, regionLocal: c.params.regionLocal }];
  const list = Array.isArray(cases) ? cases : [c.params];
  for (const p of list) {
    const cs = genContacts(p);
    const name = `${p.city}/${p.count}条`;
    check(c.name, `${name} 反查互斥`, cs.every((x) => matchRole(x.name) === x.role));
    check(c.name, `${name} 号码格式`, cs.every((x) => PHONE_RE.test(x.phone) || LANDLINE_RE.test(x.phone)));
    check(c.name, `${name} 号码去重`, new Set(cs.map((x) => x.phone)).size === cs.length);
    if (p.count >= 100) {
      // 占比断言：多 seed 聚合至 2000 条再断 ±3%（σ≈1.1 点，2.7σ，单档失败率<1%；
      // 曾用 500 条 σ≈2.2 点仅 1.4σ——随机流一变就出现边缘误报）
      const seeds = Array.from({ length: 20 }, (_, i) => 101 * (i + 1));
      const rel = { friend: 0, work: 0, service: 0, family: 0, business: 0 };
      let total = 0;
      for (const sd of seeds) {
        const batch = genContacts({ ...p, count: 100, seed: sd });
        for (const x of batch) rel[x.role]++;
        total += batch.length;
      }
      const ratios = { friend: 0.55, work: 0.20, service: 0.12, family: 0.08, business: 0.05, ...(p.ratios || {}) };
      const okRel = Object.keys(ratios).every((r) => Math.abs(rel[r] / total - ratios[r]) <= 0.03);
      check(c.name, `${name} 占比±3%(聚合${total})`, okRel, JSON.stringify(rel));
    }
  }
}

console.log('== 通话面板（12 档位 × 3 seed） ==');
for (const c of callCases) {
  const contacts = c.params.contacts === undefined ? contactsPool : c.params.contacts;
  const SEEDS = [13, 29, 57];
  for (const sd of SEEDS) {
    const calls = generateCalls({ ...c.params, contacts, seed: sd });
    check(c.name, `[seed${sd}] 未接=时长0 恒成立`, calls.every((x) => (x.answered === 0) === (x.duration === 0)));
    check(c.name, `[seed${sd}] 号码格式合法（手机/固话/客服）`, calls.every((x) => PHONE_RE.test(x.phone) || LANDLINE_RE.test(x.phone) || Object.values(CARRIER_SVC).includes(x.phone)));
    const now = Date.now() / 1000;
    check(c.name, `[seed${sd}] 时间戳窗口内`, calls.every((x) => x.ts <= now + 10 && x.ts >= now - (c.params.days || 3) * 86400 - 86400));
    if (c.params.count >= 100 && !(Array.isArray(c.params.contacts) && c.params.contacts.length === 0)) {
      const cRatio = calls.filter((x) => x.name).length / calls.length;
      const expectC = (c.params.ratios && c.params.ratios.contact) || 0.7;
      check(c.name, `[seed${sd}] 联系人占比±10%`, Math.abs(cRatio - expectC) <= 0.1, `actual=${cRatio.toFixed(2)}`);
    }
  }
}

console.log('== 短信面板（14 档位 × 3 seed） ==');
for (const c of smsCases) {
  const SEEDS = [17, 31, 43];
  for (const sd of SEEDS) {
    const sms = generateSms({ ...c.params, seed: sd });
    check(c.name, `[seed${sd}] 内容非空`, sms.every((x) => x.text && x.text.length > 0));
    check(c.name, `[seed${sd}] 生成文本无 { 残留`, sms.every((x) => !x.text.includes('{')));
    check(c.name, `[seed${sd}] 发件格式合法`, sms.filter((x) => x.phone).every((x) => SVC_PHONE_RE.test(x.phone)));
    check(c.name, `[seed${sd}] 服务类均 fromMe=false`, sms.filter((x) => x.phone).every((x) => x.fromMe === false));
    if (c.params.count >= 100) {
      const fam = sms.filter((x) => !x.phone && !/^(验证码|快递|银行|运营商|营销)/.test(x.text));
      const famFromMe = fam.filter((x) => x.fromMe).length;
      const inRatio = c.params.inRatio ?? 0.2;
      // 动态容差：family 样本量决定（≥30 条 ±15%、≥10 条 ±25%、<10 条跳过——小样本波动大）
      if (fam.length >= 30) check(c.name, `[seed${sd}] 家人朋友收发比±15%`, Math.abs(famFromMe / fam.length - inRatio) <= 0.15, `actual=${(famFromMe / fam.length).toFixed(2)}`);
      else if (fam.length >= 10) check(c.name, `[seed${sd}] 家人朋友收发比±25%`, Math.abs(famFromMe / fam.length - inRatio) <= 0.25, `actual=${(famFromMe / fam.length).toFixed(2)}`);
    }
  }
}

console.log(`\n[面板调参] ${pass} passed, ${fail} failed`);
if (failures.length) {
  console.error(failures.join('\n'));
  process.exit(1);
}
