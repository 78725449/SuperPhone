// 一键构建设备端 .tipa 更新包：推送本地 commit → 触发 CI（push 事件）→ 等待编译 → 下载并解压 bootstrap .tipa
// 用法：GHTOK=<token> node build-ipa.mjs [本地commit] [outDir]
//   默认 commit=HEAD（须有未推送的设备端变更），outDir=仓库根
// 依赖：scripts/push-via-api.mjs（Git Data API 推送，github.com 直连被阻断时的备用通道）
// 注意：push 触发 CI 受 .github/workflows/build.yml paths 过滤（仅 TrollVNC/** 或 workflow 变更才编译）；
//       若本次变更不含设备端文件，脚本会警告但照常推送（可改用 workflow_dispatch 手动触发强制编译）。
import { execSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const REPO = process.env.REPO || '78725449/SuperPhone';
const TOKEN = process.env.GHTOK;
const CWD = process.env.CWD || 'C:\\Users\\Administrator\\Documents\\ChatGPT\\New project';
const BRANCH = process.env.BRANCH || 'main';
const LOCAL = process.argv[2] || 'HEAD';
const OUT_DIR = process.argv[3] || CWD;
const API = 'https://api.github.com';

if (!TOKEN) { console.error('usage: GHTOK=<token> node build-ipa.mjs [commit] [outDir]'); process.exit(1); }

const h = { Authorization: `Bearer ${TOKEN}`, Accept: 'application/vnd.github+json', 'User-Agent': 'build-ipa' };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.error(...a); // stderr 立即刷新，避免管道缓冲

async function api(method, url, body) {
  const res = await fetch(url, { method, headers: h, body: body ? JSON.stringify(body) : undefined });
  if (!res.ok) throw new Error(`${method} ${url} -> ${res.status} ${await res.text()}`);
  return res.json();
}

// 1. 解析本地 commit sha 与远程 base
const localSha = execSync(`git rev-parse ${LOCAL}`, { encoding: 'utf8', cwd: CWD }).trim();
const ref = await api('GET', `${API}/repos/${REPO}/git/ref/heads/${BRANCH}`);
const remoteBase = ref.object.sha;
log(`[build] local  ${LOCAL} = ${localSha}`);
log(`[build] remote ${BRANCH} = ${remoteBase}`);
if (localSha === remoteBase) {
  log('[build] 本地 HEAD 与远程一致，无新 commit 可推送');
  process.exit(1);
}

// 2. 检查本次变更是否含设备端文件（决定 push 是否触发 CI 编译）
const changed = execSync(`git -c core.quotepath=false diff --name-only ${remoteBase} ${localSha}`, { encoding: 'utf8', cwd: CWD })
  .split('\n').map((s) => s.trim()).filter(Boolean);
const touchesDevice = changed.some((f) => f.startsWith('TrollVNC/') || f === '.github/workflows/build.yml');
if (!touchesDevice) {
  log(`[build] 警告：本次 ${changed.length} 个变更文件不含 TrollVNC/** 或 workflow，push 不会触发 CI 编译`);
  log('[build] 如需强制编译请用 workflow_dispatch 手动触发（不受 paths 限制）');
}

// 3. 推送本地 commit（Git Data API；远程 base 不符会拒绝）
log(`[build] pushing ${localSha} ...`);
const push = spawnSync(process.execPath, [path.join(CWD, 'scripts', 'push-via-api.mjs'), localSha, remoteBase], {
  env: { ...process.env, GHTOK: TOKEN, REPO, BRANCH, CWD },
  encoding: 'utf8',
  maxBuffer: 64 * 1024 * 1024,
});
process.stdout.write(push.stdout);
process.stderr.write(push.stderr);
if (push.status !== 0) { log('[build] push failed'); process.exit(1); }

// 4. 等 push 触发的 CI run（head_sha == localSha）出现并完成
const POLL_MS = 30000;
const MAX_WAIT_MS = 45 * 60 * 1000;
const start = Date.now();
let runId = null;
log('[build] waiting for CI run ...');
while (Date.now() - start < MAX_WAIT_MS) {
  const runs = await api('GET', `${API}/repos/${REPO}/actions/runs?event=push&branch=${BRANCH}&per_page=10`);
  const run = runs.workflow_runs.find((r) => r.head_sha === localSha);
  if (run) { runId = run.id; log(`[build] run ${runId} found (status=${run.status})`); break; }
  const elapsed = Math.round((Date.now() - start) / 1000);
  log(`[build] ${elapsed}s | run not yet visible, retrying ...`);
  await sleep(POLL_MS);
}
if (!runId) { log('[build] 超时未找到 CI run（可能 paths 过滤未触发编译）'); process.exit(1); }

// 5. 轮询 run 完成
let concluded = null;
while (Date.now() - start < MAX_WAIT_MS) {
  const run = await api('GET', `${API}/repos/${REPO}/actions/runs/${runId}`);
  const elapsed = Math.round((Date.now() - start) / 1000);
  log(`[build] ${elapsed}s | status=${run.status} conclusion=${run.conclusion ?? '-'}`);
  if (run.status === 'completed') { concluded = run.conclusion; break; }
  await sleep(POLL_MS);
}
if (!concluded) { log('[build] 超时未完成'); process.exit(1); }
log(`[build] 编译结束: ${concluded}`);
if (concluded !== 'success') { log('[build] 编译失败，不下载'); process.exit(1); }

// 6. 下载 packages-bootstrap.zip 并解压出 .tipa
const arts = await api('GET', `${API}/repos/${REPO}/actions/runs/${runId}/artifacts`);
const target = arts.artifacts.find((a) => a.name === 'packages-bootstrap');
if (!target) { log('[build] 没有 packages-bootstrap artifact'); process.exit(1); }
log(`[build] 下载 ${target.name} (${target.size_in_bytes} bytes) ...`);
const res = await fetch(`https://api.github.com/repos/${REPO}/actions/artifacts/${target.id}/zip`, { headers: h, redirect: 'follow' });
if (!res.ok) throw new Error(`artifact zip -> ${res.status} ${await res.text()}`);
const buf = Buffer.from(await res.arrayBuffer());
const zipPath = path.join(OUT_DIR, 'packages-bootstrap.zip');
fs.writeFileSync(zipPath, buf);
log(`[build] zip 已保存: ${zipPath} (${buf.length} bytes)`);

// 解压（Windows PowerShell Expand-Archive；zip 内为 .tipa 文件）
const extractDir = path.join(OUT_DIR, '_ipa_out');
fs.mkdirSync(extractDir, { recursive: true });
const ps = spawnSync('powershell', ['-NoProfile', '-Command',
  `Expand-Archive -Path '${zipPath}' -DestinationPath '${extractDir}' -Force`], { encoding: 'utf8' });
if (ps.status !== 0) { log('[build] 解压失败:', ps.stderr); process.exit(1); }
const tipas = fs.readdirSync(extractDir).filter((f) => f.endsWith('.tipa'));
if (tipas.length === 0) { log('[build] 解压目录无 .tipa 文件'); process.exit(1); }
for (const t of tipas) {
  const src = path.join(extractDir, t);
  const dst = path.join(OUT_DIR, t);
  fs.copyFileSync(src, dst);
  log(`[build] .tipa 已就绪: ${dst}`);
}
log('[build] 完成');