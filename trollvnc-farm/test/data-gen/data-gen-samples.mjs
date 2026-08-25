// 样例审查：3 组组合输出 JSON 到 outputs/，供用户审核内容质量与调参（阶段 1 门禁）
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { generateContacts } from './contacts-gen.js';
import { generateCalls } from './calls-gen.js';
import { generateSms } from './sms-gen.js';

const here = dirname(fileURLToPath(import.meta.url));

const groups = [
  { name: 'group-a', seed: 1001, city: '北京', carrier: 'cmcc', inRatio: 0.2, regionLocal: 0.65,
    rel: { friend: 0.55, work: 0.20, service: 0.12, family: 0.08, business: 0.05 },
    call: { contact: 0.7, stranger: 0.3, incoming: 0.4, outgoing: 0.4, missed: 0.2 },
    sms: { code: 0.35, express: 0.20, bank: 0.15, carrierSms: 0.10, marketing: 0.10, family: 0.10 } },
  { name: 'group-b', seed: 2002, city: '杭州', carrier: 'cucc', inRatio: 0.5, regionLocal: 0.5,
    rel: { friend: 0.40, work: 0.30, service: 0.10, family: 0.15, business: 0.05 },
    call: { contact: 0.5, stranger: 0.5, incoming: 0.3, outgoing: 0.5, missed: 0.2 },
    sms: { code: 0.40, express: 0.15, bank: 0.10, carrierSms: 0.15, marketing: 0.15, family: 0.05 } },
  { name: 'group-c', seed: 3003, city: '广州', carrier: 'ctcc', inRatio: 0.1, regionLocal: 0.8,
    rel: { friend: 0.30, work: 0.15, service: 0.20, family: 0.25, business: 0.10 },
    call: { contact: 0.9, stranger: 0.1, incoming: 0.5, outgoing: 0.3, missed: 0.2 },
    sms: { code: 0.30, express: 0.25, bank: 0.10, carrierSms: 0.10, marketing: 0.20, family: 0.05 } },
];

const out = {};
for (const g of groups) {
  const contacts = generateContacts({ count: 50, city: g.city, regionLocal: g.regionLocal, ratios: g.rel, seed: g.seed });
  const calls = generateCalls({ count: 30, days: 3, carrier: g.carrier, ratios: g.call, contacts, seed: g.seed });
  const missed = calls.filter((c) => c.answered === 0 && !c.name).map((c) => ({ phone: c.phone }));
  const sms = generateSms({ count: 30, days: 3, carrier: g.carrier, inRatio: g.inRatio, ratios: g.sms, recentMissed: missed, seed: g.seed });
  out[g.name] = { config: g, contacts: contacts.slice(0, 20), calls: calls.slice(0, 20), sms: sms.slice(0, 20) };
}
const path = join(here, '..', '..', '..', 'outputs', 'data-gen-samples.json');
writeFileSync(path, JSON.stringify(out, null, 2));
console.log('样例已输出到', path);
