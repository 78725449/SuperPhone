// 通过 GitHub Git Data API 推送本地提交（github.com 不可达时的备用通道）
// 用法：GHTOK=<token> node push-via-api.mjs <本地commit> <本地base commit> <远程base commit>
import { execSync } from 'node:child_process';

const REPO = process.env.REPO || '78725449/TrollVNC';
const TOKEN = process.env.GHTOK;
const API = 'https://api.github.com';
const CWD = process.env.CWD || 'C:\\Users\\Administrator\\Documents\\ChatGPT\\New project\\TrollVNC';
const BRANCH = process.env.BRANCH || 'main';
const LOCAL = process.argv[2];
const REMOTE_BASE = process.argv[3];
const LOCAL_BASE = process.argv[4] || process.argv[3]; // 本地 diff 基准（可与远程 base 不同 sha，内容等价即可）

if (!TOKEN || !LOCAL || !LOCAL_BASE || !REMOTE_BASE) {
  console.error('usage: GHTOK=<token> node push-via-api.mjs <localCommit> <localBaseCommit> <remoteBaseCommit>');
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
const names = execSync(`git diff --name-status ${LOCAL_BASE} ${LOCAL}`, { encoding: 'utf8', cwd: CWD });
const treeEntries = [];
let uploaded = 0;
for (const rawLine of names.trim().split('\n')) {
  const line = rawLine.trim();
  if (!line) continue;
  const sp = line.indexOf('\t');
  const st = sp >= 0 ? line.slice(0, sp) : line;
  const filePath = sp >= 0 ? line.slice(sp + 1) : '';
  if (!filePath) continue;
  if (st === 'D') {
    treeEntries.push({ path: filePath, mode: '100644', type: 'blob', sha: null });
    console.log('DEL', filePath);
    continue;
  }
  const ls = execSync(`git ls-tree ${LOCAL} -- "${filePath}"`, { encoding: 'utf8', cwd: CWD }).trim();
  const parts = ls.split(/\s+/); // [mode, type, sha, path]
  const [mode, type, sha] = parts;
  const content = execSync(`git cat-file blob ${sha}`, { encoding: null, cwd: CWD });
  const b64 = content.toString('base64');
  const blob = await api('POST', `${API}/repos/${REPO}/git/blobs`, { content: b64, encoding: 'base64' });
  treeEntries.push({ path: filePath, mode, type: 'blob', sha: blob.sha });
  uploaded++;
  console.log(`${st === 'A' ? 'ADD' : 'MOD'} ${filePath} (${mode}, ${content.length}B)`);
}
console.log('entries:', treeEntries.length, '| blobs uploaded:', uploaded);

// 3. 构建 tree（增量 base_tree）
const tree = await api('POST', `${API}/repos/${REPO}/git/trees`, { base_tree: baseTree, tree: treeEntries });
console.log('new tree:', tree.sha);

// 4. 创建 commit
const msg = execSync(`git log -1 --format=%B ${LOCAL}`, { encoding: 'utf8', cwd: CWD }).trim();
const commit = await api('POST', `${API}/repos/${REPO}/git/commits`, { message: msg, tree: tree.sha, parents: [REMOTE_BASE] });
console.log('new commit:', commit.sha);

// 5. 更新分支引用
await api('PATCH', `${API}/repos/${REPO}/git/refs/heads/${BRANCH}`, { sha: commit.sha, force: false });
console.log(`${BRANCH} updated ->`, commit.sha);
console.log('DONE');
