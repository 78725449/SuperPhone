// 角色互斥匹配 + 备注名生成（词池单一数据源在 corpus.js，规格 §1.2 / D1 §2.4）
import { ROLE_WORDS, NICKNAMES } from './corpus.js';

export const ROLE_ORDER = ['family', 'service', 'business', 'work', 'friend'];

// 反查：备注名 → 角色（顺序 family→service→business→work→friend，互斥保证不重叠）
export function matchRole(displayName) {
  if (!displayName) return 'friend';
  if (ROLE_WORDS.family.includes(displayName)) return 'family';
  if (ROLE_WORDS.service.some((w) => displayName.includes(w))) return 'service';
  if (ROLE_WORDS.business.some((w) => displayName.includes(w))) return 'business';
  if (displayName.includes('-') || ROLE_WORDS.work.some((w) => displayName.includes(w))) return 'work';
  return 'friend';
}

// 生成备注名（互斥约束：work 必带 -、family 纯称谓、service 职业+姓、business 机构名）
export function generateRemark(role, familyName, givenName, rng) {
  switch (role) {
    case 'family': return rng.pick(ROLE_WORDS.family);
    case 'service': return rng.pick(ROLE_WORDS.service) + familyName;
    case 'business': return rng.pick(ROLE_WORDS.business) + '客服';
    case 'work': return familyName + givenName + '-' + rng.pick(ROLE_WORDS.work);
    default: return familyName + givenName;
  }
}

export { NICKNAMES };
