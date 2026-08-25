// 短信生成器（D2 §2.3）
// 类型构成（服务 90%/日常 10%）+ 内容池（corpus.js，规格 §1.2）+ 收发比（inRatio，仅 family 类）
// + 运营商服务短信（特服号，按 carrier）+ 未接来电联动 + 昼夜分布
import * as rng from './rng.js';
import { matchRole } from './role-lexicon.js';
import { CIRCADIAN_WEIGHTS, CARRIER_SVC } from './calls-gen.js';
import { SMS_TEMPLATES, BRAND_POOLS, SMS_SVC_BANK, SMS_SVC_EXPRESS } from './corpus.js'; // 语料库（任务 2，规格 §1.2）+ 服务短信发件号池

export const CARRIER_NAMES = { cmcc: '中国移动', cucc: '中国联通', ctcc: '中国电信' };

// fillTemplate(tpl, carrier, brandPool)：模板 {var} 注入（replace 表与 corpus.js 模板变量一一对应；
// {brand} 取行业品牌池——营销标签品牌与内容强关联，用户定案）
function fillTemplate(tpl, carrier, brandPool) {
  const B = BRAND_POOLS;
  return tpl
    .replace(/\{code4\}/g, String(rng.randInt(1000, 9999)))
    .replace(/\{code6\}/g, String(rng.randInt(100000, 999999)))
    .replace(/\{station\}/g, rng.pick(B.stations))
    .replace(/\{company\}/g, rng.pick(B.couriers))
    .replace(/\{trackno\}/g, String(rng.randInt(1000000000, 9999999999)))
    .replace(/\{box\}/g, String(rng.randInt(1, 99)))
    .replace(/\{bank\}/g, rng.pick(B.banks))
    .replace(/\{last4\}/g, String(rng.randInt(1000, 9999)))
    .replace(/\{time\}/g, `${rng.randInt(0, 23)}:${String(rng.randInt(0, 59)).padStart(2, '0')}`)
    .replace(/\{amount\}/g, (rng.rand01() * 5000).toFixed(2))
    .replace(/\{balance\}/g, (rng.rand01() * 50000).toFixed(2))
    .replace(/\{day\}/g, `${rng.randInt(1, 28)}日`)
    .replace(/\{gb1\}/g, (rng.rand01() * 20).toFixed(1))
    .replace(/\{gb2\}/g, (rng.rand01() * 30).toFixed(1))
    .replace(/\{carrier\}/g, CARRIER_NAMES[carrier])
    .replace(/\{estate\}/g, rng.pick(B.estates))
    .replace(/\{wan\}/g, String(rng.randInt(15, 60)))
    .replace(/\{org\}/g, rng.pick(B.orgs))
    .replace(/\{loan\}/g, String(rng.randInt(5, 50)))
    .replace(/\{platform\}/g, rng.pick(B.platforms))
    .replace(/\{product\}/g, rng.pick(B.products))
    .replace(/\{ecom\}/g, rng.pick(B.ecoms))
    .replace(/\{brand\}/g, rng.pick(brandPool || B.brands))
    .replace(/\{discount\}/g, String(rng.randInt(5, 9)))
    .replace(/\{pct\}/g, (0.5 + rng.rand01() * 7.5).toFixed(1))
    .replace(/\{phone\}/g, '400-' + String(rng.randInt(1000000, 9999999)));
}

/**
 * 短信生成（D2 §2.3）
 * @param {object} p
 * @param {number} p.count 1-300
 * @param {number} [p.days] 1-30
 * @param {string} [p.carrier] cmcc|cucc|ctcc
 * @param {number} [p.inRatio] 我发占比 0-1（默认 0.2，仅 family 类）
 * @param {object} [p.ratios] {code,express,bank,carrierSms,marketing,family}
 * @param {object[]} [p.recentMissed] 最近未接号码 [{phone}]（未接来电联动）
 * @param {number} [p.seed]
 * @returns {{phone:string, text:string, ts:number, fromMe:boolean}[]}
 */
export function generateSms(p) {
  const count = Math.max(1, Math.min(300, p.count | 0));
  const days = Math.max(1, Math.min(30, p.days || 3));
  const carrier = p.carrier || 'cmcc';
  const inRatio = p.inRatio === undefined ? 0.2 : p.inRatio;
  const r = { code: 0.35, express: 0.20, bank: 0.15, carrierSms: 0.10, marketing: 0.10, family: 0.10, ...(p.ratios || {}) };
  rng.seed(p.seed);
  const now = Date.now() / 1000;
  const types = ['code', 'express', 'bank', 'carrierSms', 'marketing', 'family'];
  const w = types.map((t) => r[t]);
  const msgs = [];
  let carrierDone = false;
  let missedLinked = false;
  for (let i = 0; i < count; i++) {
    const type = types[rng.weightedIndex(w)];
    const ts = Math.floor(now) - rng.randInt(0, days - 1) * 86400 - Math.floor(rng.rand01() * 86400);
    if (type === 'carrierSms') {
      // 运营商服务短信：发件=特服号（1-2 条）
      msgs.push({ phone: CARRIER_SVC[carrier], text: fillTemplate(rng.pick(SMS_TEMPLATES.carrierSms), carrier), ts, fromMe: false });
      carrierDone = true;
      continue;
    }
    if (type === 'family') {
      const fromMe = rng.rand01() < inRatio; // 收发比仅作用于家人朋友类
      msgs.push({ phone: null, text: rng.pick(SMS_TEMPLATES.family), ts, fromMe });
      continue;
    }
    if (type === 'marketing') {
      // 营销：随机行业组 → 组品牌池 + 组模板（品牌-内容强关联），发件=106 营销特服号
      const inds = Object.keys(SMS_TEMPLATES.marketing);
      const g = SMS_TEMPLATES.marketing[inds[rng.randInt(0, inds.length - 1)]];
      msgs.push({ phone: svc106(), text: fillTemplate(rng.pick(g.templates), carrier, g.brands), ts, fromMe: false });
      continue;
    }
    // 服务类（code/express/bank）：发件=服务号码——验证码 106 特服号 / 快递 953xx-955xx 客服短号 / 银行 955xx 客服短号（非私人手机号）
    const svc = type === 'bank' ? rng.pick(SMS_SVC_BANK) : type === 'express' ? rng.pick(SMS_SVC_EXPRESS) : svc106();
    msgs.push({ phone: svc, text: fillTemplate(rng.pick(SMS_TEMPLATES[type]), carrier), ts, fromMe: false });
  }
  // 未接来电联动（D2 §2.3）：跟 1 条"您有一个未接来电"
  if (!missedLinked && p.recentMissed && p.recentMissed.length && rng.rand01() < 0.3) {
    missedLinked = true;
    const src = rng.pick(p.recentMissed);
    msgs.push({ phone: CARRIER_SVC[carrier], text: `【运营商】您有一个来自${src.phone}的未接来电`, ts: Math.floor(now), fromMe: false });
  }
  return msgs.slice(0, count);
}

// 106 企业特服号（验证码/营销发件；与 ObjC trRandomSvc106 同构：106 + 8 位 = 11 位）
function svc106() {
  return '106' + String(rng.randInt(0, 99999999)).padStart(8, '0');
}
