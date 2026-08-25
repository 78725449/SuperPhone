// 通话生成器（D2 §2.2）
// 角色反查分层加权（family 4.0/work 3.0/friend 2.0/service 1.0/business 0.5）+ Zipf 陌生号
// + 昼夜权重 + 时长对数 + 运营商客服来电（D2 §2.4）
import * as rng from './rng.js';
import { matchRole } from './role-lexicon.js';
import { readFileSync } from 'node:fs';

const PHONE_SEGMENTS = JSON.parse(readFileSync(new URL('./number-segments.json', import.meta.url), 'utf8')); // 完整号段池（任务 3 构建，与 contacts 同源）

// 昼夜权重表（D3 §2.2 —— 0-6 深夜 0.05 起，18-21 峰值 1.00）
export const CIRCADIAN_WEIGHTS = [
  [0, 6, 0.05], [6, 8, 0.30], [8, 9, 0.70], [9, 12, 0.90], [12, 14, 0.80],
  [14, 18, 0.95], [18, 21, 1.00], [21, 23, 0.70], [23, 24, 0.30],
];

// 反查分层选人权重（D2 §2.2）
export const ROLE_WEIGHTS = { family: 4.0, work: 3.0, friend: 2.0, service: 1.0, business: 0.5 };

export const CARRIER_SVC = { cmcc: '10086', cucc: '10010', ctcc: '10000' };

// 昼夜加权时间点（拒绝采样，最多 50 次；D3 §2.2）
function weightedHour() {
  for (let i = 0; i < 50; i++) {
    const h = rng.randInt(0, 23);
    const w = CIRCADIAN_WEIGHTS.find(([a, b]) => h >= a && h < b)[2];
    if (rng.rand01() < w) return h;
  }
  return 19; // 峰值兜底
}

// 活跃日：随机选 1-2 天为活跃日，其余稀疏（D2 §2.2）
function activeDaySet(days) {
  const set = new Set([rng.randInt(0, days - 1)]);
  if (days > 1 && rng.rand01() < 0.4) set.add(rng.randInt(0, days - 1));
  return set;
}

// 时长：对数分布 -ln(U)×120 秒；family 30% 概率长通话 10-30min（D2 §2.2）
function durationFor(role, answered) {
  if (!answered) return 0;
  if (role === 'family' && rng.rand01() < 0.3) return 600 + rng.rand01() * 1200;
  const d = -Math.log(1 - rng.rand01()) * 120;
  return Math.min(1800, Math.max(20, Math.round(d)));
}

/**
 * 通话生成（D2 §2.2）
 * @param {object} p
 * @param {number} p.count 1-200
 * @param {number} [p.days] 1-30（默认 3）
 * @param {string} [p.carrier] cmcc|cucc|ctcc
 * @param {object} [p.ratios] {contact,stranger,incoming,outgoing,missed}
 * @param {{name:string, phone:string}[]} [p.contacts] 通讯录（读系统通讯录的结果）
 * @param {number} [p.seed]
 * @returns {{phone:string, name:string|null, originated:0|1, answered:0|1, duration:number, ts:number}[]}
 */
export function generateCalls(p) {
  const count = Math.max(1, Math.min(200, p.count | 0));
  const days = Math.max(1, Math.min(30, p.days || 3));
  const carrier = p.carrier || 'cmcc';
  const r = { contact: 0.7, stranger: 0.3, incoming: 0.4, outgoing: 0.4, missed: 0.2, ...(p.ratios || {}) };
  rng.seed(p.seed);
  const now = Date.now() / 1000;
  const contacts = (p.contacts || []).filter((c) => c && c.phone);
  const activeDays = activeDaySet(days);
  const byRole = {};
  for (const c of contacts) {
    const role = matchRole(c.name);
    (byRole[role] = byRole[role] || []).push(c);
  }
  const roleKeys = Object.keys(byRole).filter((k) => byRole[k].length);
  const calls = [];
  let svcCallDone = false;
  // Zipf 陌生号池（generateCalls 局部变量——模块级会跨 seed 污染，破坏同 seed 可复现）
  const strangerPool = [];
  const randomStranger = () => {
    if (strangerPool.length && rng.rand01() < 0.5) return rng.pick(strangerPool);
    const n = randomStrangerPhone();
    strangerPool.push(n);
    return n;
  };
  for (let i = 0; i < count; i++) {
    const day = rng.randInt(0, days - 1);
    const active = activeDays.has(day);
    const hour = weightedHour();
    // 活跃日通话密度高：活跃日才进入 9-21 时段，沉寂日整体低频（D2 §2.2）
    if (!active && rng.rand01() < 0.6) { i--; continue; }
    const ts = Math.floor(now) - day * 86400 - (rng.rand01() * 86400);
    // 运营商客服来电 1-2 条（首次，D2 §2.4；已接时长短通话 30-120s，未接 0）
    if (!svcCallDone && roleKeys.length >= 0 && rng.rand01() < 0.08) {
      svcCallDone = true;
      const svcAnswered = rng.rand01() < 0.5 ? 1 : 0;
      calls.push({ phone: CARRIER_SVC[carrier], name: null, originated: 0, answered: svcAnswered, duration: svcAnswered ? 30 + Math.round(rng.rand01() * 90) : 0, ts });
      continue;
    }
    // 选人池：contact / stranger
    const isContact = rng.rand01() < r.contact && contacts.length > 0;
    let phone, name = null, role = 'friend';
    if (isContact) {
      const keys = roleKeys.length ? roleKeys : ['friend'];
      const chosenRole = keys[rng.weightedIndex(keys.map((k) => ROLE_WEIGHTS[k] || 1))];
      const pool = byRole[chosenRole] || contacts;
      const c = rng.pick(pool);
      phone = c.phone; name = c.name; role = chosenRole;
    } else {
      phone = randomStranger();
    }
    // 状态：missed 集中在陌生号（D2 §2.2）
    const st = rng.weightedIndex([r.incoming, r.outgoing, r.missed]);
    const missed = st === 2;
    const originated = st === 1 ? 1 : 0;
    const answered = missed ? 0 : 1;
    calls.push({ phone, name, originated, answered, duration: durationFor(role, answered), ts });
  }
  return calls.slice(0, count);
}

// 陌生号纯函数（无状态）：完整号段池（与 contacts 同源）
function randomStrangerPhone() {
  const p = rng.pick(PHONE_SEGMENTS);
  return p + String(rng.randInt(10000000, 99999999));
}
