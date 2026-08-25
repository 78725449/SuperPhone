// xorshift64 PRNG —— 必须与 TRDataFiller.mm 的 trSeed/trRand/trRand01/trRandInt 完全同构
// （同 seed 下两端输出一致，供阶段 2 JSON diff 对照；ObjC uint64_t 溢出截断 = 本文件 BigInt 64 位掩码）
let s = 0x9e3779b97f4a7c15n; // uint64 常量
const MASK = 0xffffffffffffffffn;

export function seed(v) {
  s = (BigInt(v || 0) === 0n ? BigInt(Math.floor(Date.now() * 1000)) : BigInt(v)) & MASK;
}

export function next() {
  s ^= s << 13n; s &= MASK;
  s ^= s >> 7n;
  s ^= s << 17n; s &= MASK;
  return s;
}

export function rand01() { return Number(next() % 1000000n) / 1000000; }

export function randInt(lo, hi) {
  if (hi <= lo) return lo;
  return lo + Math.floor(rand01() * (hi - lo + 1));
}

// 从数组等权取一
export function pick(arr) { return arr[randInt(0, arr.length - 1)]; }

// 按权重表取索引（weights: number[]，自动归一化）
export function weightedIndex(weights) {
  const total = weights.reduce((a, b) => a + b, 0);
  let r = rand01() * total;
  for (let i = 0; i < weights.length; i++) { r -= weights[i]; if (r < 0) return i; }
  return weights.length - 1;
}
