// 联系人生成器（D1 §2，数据源驱动）
// 数据源：area-codes.json / number-segments.json（build-area-table.mjs 构建产物，民政部+工信部）
// 语料：corpus.js（姓名池，规格 §1.2）；角色备注名生成/反查：role-lexicon.js
import * as rng from './rng.js';
import { generateRemark, matchRole } from './role-lexicon.js';
import { FAMILY_NAMES, GIVEN_NAMES } from './corpus.js';
import { readFileSync } from 'node:fs';

// 数据源产物（构建期生成，禁止手工精简表）
export const AREA = JSON.parse(readFileSync(new URL('./area-codes.json', import.meta.url), 'utf8'));
const PHONE_SEGMENTS = JSON.parse(readFileSync(new URL('./number-segments.json', import.meta.url), 'utf8'));
// 号段归属地（build-tr-hlr.mjs 构建产物，phone2region 数据源）：{city: [[start,end],...]} 7 位前缀区间
const HLR = JSON.parse(readFileSync(new URL('./hlr-prefixes.json', import.meta.url), 'utf8'));

const DEFAULT_REL = { friend: 0.55, work: 0.20, service: 0.12, family: 0.08, business: 0.05 };

function randomMobile() {
  const seg = rng.pick(PHONE_SEGMENTS);
  const tail = rng.randInt(10000000, 99999999);
  return seg + tail; // 3 位号段 + 8 位尾号 = 11 位
}

function randomLocalMobile(city) {
  const rs = HLR[city];
  if (!rs || !rs.length) return null; // 城市无归属地数据（调用方回退全国随机）
  const [s, e] = rs[rng.randInt(0, rs.length - 1)];
  const prefix = rng.randInt(s, e); // 7 位前缀（3 号段 + 4 HLR）
  return String(prefix) + String(rng.randInt(0, 9999)).padStart(4, '0'); // + 4 位尾号
}

function randomLandline(areaCode) {
  const n1 = rng.randInt(2, 9), n2 = rng.randInt(0, 9), n3 = rng.randInt(0, 9);
  const n4 = rng.randInt(0, 9), n5 = rng.randInt(0, 9), n6 = rng.randInt(0, 9), n7 = rng.randInt(0, 9);
  return `0${areaCode}${n1}${n2}${n3}${n4}${n5}${n6}${n7}`;
}

/**
 * 联系人生成（D1 §2）：Profile → Persona[]
 * @param {object} p
 * @param {number} p.count 1-500
 * @param {string} p.city 常住城市中文名（须在 AREA 数据源表内）
 * @param {number} [p.regionLocal] 本地占比 0-1（默认 0.65）
 * @param {object} [p.ratios] {friend,work,service,family,business}（默认 DEFAULT_REL）
 * @param {number} [p.seed]
 * @returns {{name:string, phone:string, role:string, city:string}[]}
 */
export function generateContacts(p) {
  const count = Math.max(1, Math.min(500, p.count | 0));
  const ratios = { ...DEFAULT_REL, ...(p.ratios || {}) };
  const regionLocal = p.regionLocal === undefined ? 0.65 : p.regionLocal;
  const cityInfo = AREA[p.city] || AREA['北京'];
  rng.seed(p.seed);
  const roles = ['friend', 'work', 'service', 'family', 'business'];
  const w = roles.map((r) => Math.max(0, Math.min(1, ratios[r] || 0)));
  const persons = [];
  const used = new Set();
  for (let i = 0; i < count; i++) {
    const role = roles[rng.weightedIndex(w)];
    const fam = rng.pick(FAMILY_NAMES);
    const given = rng.pick(GIVEN_NAMES);
    const name = generateRemark(role, fam, given, rng);
    let phone;
    // 号码分配（D1 §2.5 HLR 语义）：机构/生活服务类小比例本地固话（区号体现地区）；
    // regionLocal 分支 = 常住城市归属手机号（HLR 前缀），其余 = 全国随机手机号
    if ((role === 'service' || role === 'business') && rng.rand01() < 0.3) {
      phone = randomLandline(cityInfo.areaCode);
    } else if (rng.rand01() < regionLocal) {
      phone = randomLocalMobile(p.city) || randomMobile();
    } else {
      phone = randomMobile();
    }
    if (used.has(phone)) { i--; continue; } // 生成集内去重
    used.add(phone);
    persons.push({ name, phone, role, city: cityInfo.province });
  }
  return persons;
}

export { matchRole };
