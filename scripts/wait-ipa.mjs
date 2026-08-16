// 等待 GitHub Actions 编译完成并下载 bootstrap .tipa
// 用法：node wait-ipa.mjs <runId> [outDir]
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const REPO = process.env.REPO || '78725449/SuperPhone';
const RUN_ID = process.argv[2];
const OUT_DIR = process.argv[3] || 'C:\\Users\\Administrator\\Documents\\ChatGPT\\New project';
if (!RUN_ID) { console.error('usage: node wait-ipa.mjs <runId> [outDir]'); process.exit(1); }

// 提取 GCM 缓存的 GitHub token
let TOKEN = '';
try {
  const out = execSync('git credential-manager get', { encoding: 'utf8', input: 'protocol=https\nhost=github.com\n' });
  for (const line of out.split('\n')) {
    if (line.startsWith('password=')) TOKEN = line.slice(9).trim();
  }
} catch (e) { console.error('GCM token 提取失败:', e.message); }
if (!TOKEN) { console.error('未获取到 token'); process.exit(1); }

const h = { Authorization: `Bearer ${TOKEN}`, 'User-Agent': 'wait-ipa', Accept: 'application/vnd.github+json' };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.error(...a); // stderr 立即刷新，避免管道缓冲

async function api(url) {
  const res = await fetch(url, { headers: h });
  if (!res.ok) throw new Error(`${url} -> ${res.status} ${await res.text()}`);
  return res.json();
}

const POLL_MS = 30000;
const MAX_WAIT_MS = 45 * 60 * 1000;
const start = Date.now();
let concluded = null;

log(`[wait] 轮询 run ${RUN_ID} ...`);
while (Date.now() - start < MAX_WAIT_MS) {
  const run = await api(`https://api.github.com/repos/${REPO}/actions/runs/${RUN_ID}`);
  const elapsed = Math.round((Date.now() - start) / 1000);
  log(`[wait] ${elapsed}s | status=${run.status} conclusion=${run.conclusion ?? '-'}`);
  if (run.status === 'completed') { concluded = run.conclusion; break; }
  await sleep(POLL_MS);
}
if (!concluded) { log('[wait] 超时未完成'); process.exit(1); }
log(`[wait] 编译结束: ${concluded}`);
if (concluded !== 'success') { log('[wait] 编译失败，不下载'); process.exit(1); }

// 列出 artifacts，找 bootstrap packages
const arts = await api(`https://api.github.com/repos/${REPO}/actions/runs/${RUN_ID}/artifacts`);
const targets = arts.artifacts.filter((a) => a.name.startsWith('packages-'));
log('[wait] artifacts:', targets.map((a) => a.name).join(', '));
const target = targets.find((a) => a.name === 'packages-bootstrap') || targets[0];
if (!target) { log('[wait] 没有 packages artifact'); process.exit(1); }

// 下载 zip（带认证）
const zipUrl = `https://api.github.com/repos/${REPO}/actions/artifacts/${target.id}/zip`;
log(`[wait] 下载 ${target.name} (${target.size_in_bytes} bytes) ...`);
const res = await fetch(zipUrl, { headers: h, redirect: 'follow' });
if (!res.ok) throw new Error(`artifact zip -> ${res.status} ${await res.text()}`);
const buf = Buffer.from(await res.arrayBuffer());
const zipPath = path.join(OUT_DIR, `${target.name}.zip`);
fs.writeFileSync(zipPath, buf);
log(`[wait] zip 已保存: ${zipPath} (${buf.length} bytes)`);
