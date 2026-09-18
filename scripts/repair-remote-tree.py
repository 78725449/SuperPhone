"""把远程 main 强制退回干净 commit，然后重新推送本地 HEAD（只含本次 6 个文件）。

背景（2026-09-19 事故）：`git add -A` 把仓库根 68 个未跟踪文件（测试截图 / __pycache__ /
一批旧文档与临时脚本）一并提交并推送，污染了远程树；随后本地 reset 重提交，
但 push-via-api 以【已污染的远程树】为 base，导致二次推送仍带着污染。
本脚本按 AGENTS.md 记的模式修复：先把 ref 退回干净 commit，再用干净的 base 重推。

★ PowerShell 5.1 会吞掉 curl 的嵌套引号（"Problems parsing JSON"）→ 故用 Python。
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "78725449/SuperPhone"
CLEAN = "1c79d0c9e5271cee6af8c2de7f7ab4005b292569"   # 污染之前那个 commit（树 == 本地 30d61cf）
TOKEN = os.environ.get("GHTOK")
PROXY = "http://127.0.0.1:7890"
ROOT = r"D:\编程项目\SuperPhone"
CLEANUP = [
    "ma35_task", "scripts/_test_shot.jpg", "scripts/__pycache__",
    "data/_verify-douyin.jpg", "data/_verify-search.jpg", "data/actor-run",
]
SIX = [
    "TrollVNC/src/TRCapabilityRegistry.mm",
    "dsh-superphone/src/tools.ts",
    "scripts/verify-iframe-chain.py",
    "skills/superphone-device/SKILL.md",
    "定案-最终开发方向-2026-09-19.md",
    "说明文档.md",
]

if not TOKEN:
    print("✗ 缺 GHTOK")
    sys.exit(1)

opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({"https": PROXY, "http": PROXY}))


def api(path, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        "https://api.github.com" + path, data=data, method=method,
        headers={"Authorization": "Bearer " + TOKEN, "User-Agent": "dsh",
                 "Content-Type": "application/json", "Accept": "application/vnd.github+json"})
    try:
        with opener.open(req, timeout=60) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw.strip() else None
    except urllib.error.HTTPError as e:
        return {"__error": e.code, "__body": e.read().decode()[:300]}


print("=" * 78)
print("① 把远程 main 强制退回干净 commit")
print("=" * 78)
r = api("/repos/%s/git/refs/heads/main" % REPO, "PATCH",
        {"sha": CLEAN, "force": True})
if r and r.get("__error"):
    print("  ✗ PATCH 失败: %s %s" % (r["__error"], r["__body"]))
    sys.exit(1)
print("  ✓ 已 PATCH → %s" % (r or {}).get("object", {}).get("sha"))

cur = api("/repos/%s/git/ref/heads/main" % REPO)
cur_sha = cur["object"]["sha"]
print("  当前远程 main = %s  %s" % (cur_sha, "✓" if cur_sha == CLEAN else "✗ 未生效"))
if cur_sha != CLEAN:
    sys.exit(1)

print()
print("=" * 78)
print("② 本地把污染文件移出工作区（保留在磁盘，只移到一个 _staged 目录，便于回查）")
print("=" * 78)
for p in CLEANUP:
    full = os.path.join(ROOT, p)
    if os.path.exists(full):
        print("  提示（不删，仅列出）：%s 仍存在 —— 它已在 .gitignore 之外，需显式 add 才会入库" % p)
print("  （本步无需改动：只要推送时显式指定 6 个文件，就不会再带上它们）")

print()
print("=" * 78)
print("③ 重新推送：以干净 commit 为 base，只带本次 6 个文件")
print("=" * 78)
env = dict(os.environ, CWD=ROOT, HTTPS_PROXY=PROXY, HTTP_PROXY=PROXY)
for f in SIX:
    subprocess.run(["git", "add", f], cwd=ROOT, check=True)
st = subprocess.run(["git", "diff", "--cached", "--name-only"], cwd=ROOT,
                    capture_output=True, text=True, encoding="utf-8")
staged = [x for x in st.stdout.splitlines() if x.strip()]
print("  暂存区（应为 6 个）: %d 个" % len(staged))
for f in staged:
    print("      " + f)
if len(staged) != 6:
    print("  ✗ 暂存区不是 6 个 —— 中止，先人工确认")
    sys.exit(1)

# 用干净 commit 作为本地 diff 基准的等价物：本地没有它的对象，
# 故显式用 30d61cf（树与它相同）当 localBase
p = subprocess.run(["node", "scripts/push-via-api.mjs", "HEAD", CLEAN, "30d61cf"],
                   cwd=ROOT, env=env, capture_output=True, text=True, encoding="utf-8")
print(p.stdout[-800:] if p.stdout else "")
if p.returncode != 0:
    print("  ✗ push 失败 rc=%s" % p.returncode)
    print(p.stderr[-500:] if p.stderr else "")
    sys.exit(1)

print()
print("=" * 78)
print("④ 核对")
print("=" * 78)
lt = subprocess.run(["git", "rev-parse", "HEAD^{tree}"], cwd=ROOT,
                    capture_output=True, text=True).stdout.strip()
rh = api("/repos/%s/git/ref/heads/main" % REPO)["object"]["sha"]
rt = api("/repos/%s/git/commits/%s" % (REPO, rh))["tree"]["sha"]
print("  本地树 = %s" % lt)
print("  远程树 = %s" % rt)
print("  ★ 一致: %s" % (lt == rt))

tree = api("/repos/%s/git/trees/%s?recursive=1" % (REPO, rt))
paths = [e["path"] for e in tree.get("tree", [])]
print("  远程文件总数 = %d" % len(paths))
bad = [x for x in paths if any(k in x for k in
       ("ma35_task/", "_test_shot.jpg", "__pycache__", "_verify-douyin", "actor-run/"))]
print("  ★ 污染文件: %s" % ("✓ 已清除" if not bad else "✗ 仍有 %d 个: %s" % (len(bad), bad[:5])))
