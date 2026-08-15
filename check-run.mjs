// 查询 release 最新 run 状态
import { execSync } from 'node:child_process';

const REPO = '78725449/TrollVNC';
let TOKEN = '';
try {
  const out = execSync('git credential-manager get', { encoding: 'utf8', input: 'protocol=https\nhost=github.com\n' });
  for (const line of out.split('\n')) if (line.startsWith('password=')) TOKEN = line.slice(9).trim();
} catch (e) { console.error('token 失败:', e.message); }
if (!TOKEN) process.exit(1);

const res = await fetch(`https://api.github.com/repos/${REPO}/actions/runs?branch=release&per_page=3`, {
  headers: { Authorization: `Bearer ${TOKEN}`, 'User-Agent': 'check-ci' },
});
const data = await res.json();
for (const r of data.workflow_runs) {
  console.log(`${r.id} | ${r.head_sha.slice(0, 7)} | ${r.status} | ${r.conclusion ?? '-'}`);
}
