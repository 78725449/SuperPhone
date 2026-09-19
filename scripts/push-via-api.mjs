// 通过 GitHub Git Data API 推送本地提交（github.com 不可达时的备用通道）
// 用法：GHTOK=<token> node push-via-api.mjs <本地commit> <远程base commit> [本地base commit]
import { execSync } from 'node:child_process';

const REPO = process.env.REPO || '78725449/SuperPhone';
const TOKEN = process.env.GHTOK;
const API = 'https://api.github.com';
const CWD = process.env.CWD || 'C:\\Users\\Administrator\\Documents\\ChatGPT\\New project';
const BRANCH = process.env.BRANCH || 'main';
const LOCAL = process.argv[2];
const REMOTE_BASE = process.argv[3];
const LOCAL_BASE = process.argv[4] || process.argv[3]; // 本地 diff 基准（可与远程 base 不同 sha，内容等价即可）

if (!TOKEN || !LOCAL || !LOCAL_BASE || !REMOTE_BASE) {
  console.error('usage: GHTOK=<token> node push-via-api.mjs <localCommit> <remoteBaseCommit> [localBaseCommit]');
  process.exit(1);
}

const h = { Authorization: `Bearer ${TOKEN}`, Accept: 'application/vnd.github+json', 'User-Agent': 'push-via-api' };

async function api(method, url, body) {
  const res = await fetch(url, { method, headers: h, body: body ? JSON.stringify(body) : undefined });
  if (!res.ok) throw new Error(`${method} ${url} -> ${res.status} ${await res.text()}`);
  return res.json();
}

// 1. 远程 HEAD 与 base tree
const ref = await api('GET', `${API}/repos/${REPO}/git/ref/heads/${BRANCH}`);
if (ref.object.sha !== REMOTE_BASE) {
  console.error(`远程 main 已变化: 期望 ${REMOTE_BASE}, 实际 ${ref.object.sha}`);
  process.exit(1);
}
const baseCommitObj = await api('GET', `${API}/repos/${REPO}/git/commits/${REMOTE_BASE}`);
const baseTree = baseCommitObj.tree.sha;
console.log('remote HEAD:', ref.object.sha, '| base tree:', baseTree);

// 2. 变更文件 → blob
const names = execSync(`git -c core.quotepath=false diff --name-status ${LOCAL_BASE} ${LOCAL}`, { encoding: 'utf8', cwd: CWD });
const treeEntries = [];
let uploaded = 0;
for (const rawLine of names.trim().split('\n')) {
  const line = rawLine.trim();
  if (!line) continue;
  const sp = line.indexOf('\t');
  const st = sp >= 0 ? line.slice(0, sp) : line;
  let rest = sp >= 0 ? line.slice(sp + 1) : '';
  // ★ rename（git mv 产生 R<score>）拆成【D旧 + A新】——此前会把 "旧\t新" 当单路径，导致
  //   git ls-tree 拿到 undefined（"Not a valid object name undefined"）并整包崩 ✗
  if (/^R/.test(st)) {
    const t2 = rest.indexOf('\t');
    const oldPath = t2 >= 0 ? rest.slice(0, t2) : rest;
    const newPath = t2 >= 0 ? rest.slice(t2 + 1) : '';
    console.log('DEL(rename)', oldPath);
    if (!newPath) continue;
    rest = newPath;
    treeEntries.push({ path: oldPath, mode: '100644', type: 'blob', sha: null });
  }
  const filePath = rest;
  if (!filePath) continue;
  if (st === 'D') {
    treeEntries.push({ path: filePath, mode: '100644', type: 'blob', sha: null });
    console.log('DEL', filePath);
    continue;
  }
  const ls = execSync(`git -c core.quotepath=false ls-tree ${LOCAL} -- "${filePath}"`, { encoding: 'utf8', cwd: CWD }).trim();
  const parts = ls.split(/\s+/); // [mode, type, sha, path]
  const [mode, type, sha] = parts;
  const content = execSync(`git cat-file blob ${sha}`, { encoding: null, cwd: CWD, maxBuffer: 256 * 1024 * 1024 });
  const b64 = content.toString('base64');
  const blob = await api('POST', `${API}/repos/${REPO}/git/blobs`, { content: b64, encoding: 'base64' });
  treeEntries.push({ path: filePath, mode, type: 'blob', sha: blob.sha });
  uploaded++;
  console.log(`${st === 'A' ? 'ADD' : (/^R/.test(st) ? 'ADD(rename)' : 'MOD')} ${filePath} (${mode}, ${content.length}B)`);
}
console.log('entries:', treeEntries.length, '| blobs uploaded:', uploaded);

// 2.5 获取远程 base tree 递归清单，过滤与 base 相同的条目（GitHub tree API 对 base_tree 合并
//     提交相同路径/相同内容条目会报 422 GitRPC::BadObjectState）
const baseTreeInfo = await api('GET', `${API}/repos/${REPO}/git/trees/${baseTree}?recursive=1`);
const basePaths = new Map();
for (const t of baseTreeInfo.tree || []) {
  if (t.type === 'blob' && t.path) basePaths.set(t.path, t.sha);
}
const filtered = treeEntries.filter((e) => {
  if (e.sha === null) return basePaths.has(e.path); // 删除：仅当 base 中存在该路径
  return basePaths.get(e.path) !== e.sha;           // blob：仅当与 base 内容不同
});
console.log('entries after base-dedup:', treeEntries.length, '->', filtered.length);

// 3. 构建 tree（增量 base_tree；全量相同时直接复用 baseTree）
const tree = filtered.length === 0
  ? { sha: baseTree }
  : await api('POST', `${API}/repos/${REPO}/git/trees`, { base_tree: baseTree, tree: filtered });
console.log('new tree:', tree.sha);

// 4. 创建 commit
const msg = execSync(`git log -1 --format=%B ${LOCAL}`, { encoding: 'utf8', cwd: CWD }).trim();
const commit = await api('POST', `${API}/repos/${REPO}/git/commits`, { message: msg, tree: tree.sha, parents: [REMOTE_BASE] });
console.log('new commit:', commit.sha);

// 5. 更新分支引用
await api('PATCH', `${API}/repos/${REPO}/git/refs/heads/${BRANCH}`, { sha: commit.sha, force: false });
console.log(`${BRANCH} updated ->`, commit.sha);
console.log('DONE');
