r"""取 CI #922 产物 → 核验含 app.list 版本字段 → 落盘待部署。

★ 判据（不只看"编译通过"）：
  ① 产物内核 grep shortVersionString（ASCII 字面量，__cstring 可搜）
  ② 落盘到 data/ci-artifact/ 供 deploy-tipa.py 显式部署（★ 不能用默认陈旧包 ✗）
"""
import io
import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile

REPO = "78725449/SuperPhone"
TOKEN = os.environ.get("GHTOK") or ""
PROXY = "http://127.0.0.1:7890"
OUT = r"D:\编程项目\SuperPhone\data\ci-artifact"
RUN_NUMBER = int(sys.argv[1]) if len(sys.argv) > 1 else 922
op = urllib.request.build_opener(
    urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}))


def api(p):
    rq = urllib.request.Request("https://api.github.com" + p, headers={
        "Authorization": "Bearer %s" % TOKEN,
        "Accept": "application/vnd.github+json", "User-Agent": "dsh"})
    try:
        with op.open(rq, timeout=60) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return {"_err": e.code, "_body": e.read()[:200]}


os.makedirs(OUT, exist_ok=True)
runs = api("/repos/%s/actions/runs?per_page=20" % REPO)
run = next((r for r in runs.get("workflow_runs", []) if r["run_number"] == RUN_NUMBER), None)
if not run:
    print("  ✗ 找不到 run #%d" % RUN_NUMBER)
    sys.exit(1)
print("  run #%s · %s · %s · head=%s" % (run["run_number"], run["status"], run["conclusion"], run["head_sha"][:8]))

arts = api("/repos/%s/actions/runs/%s/artifacts" % (REPO, run["id"]))
pick = next((a for a in arts.get("artifacts", []) if a["name"].startswith("packages-bootstrap")), None)
if not pick:
    print("  ✗ 无 packages-bootstrap 产物")
    sys.exit(1)
print("  产物：%s（%.2f MB）" % (pick["name"], pick["size_in_bytes"] / 1048576))

zip_path = os.path.join(OUT, "run%d-packages-bootstrap.zip" % RUN_NUMBER)
subprocess.run(["curl.exe", "-sL", "-x", PROXY,
                "-H", "Authorization: Bearer %s" % TOKEN, "-H", "User-Agent: dsh",
                "-o", zip_path,
                "https://api.github.com/repos/%s/actions/artifacts/%s/zip" % (REPO, pick["id"])],
               capture_output=True)
data = io.open(zip_path, "rb").read()
print("  下载 %.2f MB" % (len(data) / 1048576))

tipa_name = None
inner = None
with zipfile.ZipFile(io.BytesIO(data)) as z:
    for n in z.namelist():
        if n.lower().endswith(".tipa"):
            inner = z.read(n)
            tipa_name = n
            break
if inner is None:
    print("  ✗ 外层无 .tipa：%s" % z.namelist()[:5])
    sys.exit(1)
print("  内层 %s（%.2f MB）" % (tipa_name, len(inner) / 1048576))

mgr = None
with zipfile.ZipFile(io.BytesIO(inner)) as z:
    cand = [n for n in z.namelist() if n.endswith("trollvncmanager")]
    if cand:
        mgr = z.read(cand[0])
        n_entries = len(z.namelist())
if not mgr:
    print("  ✗ 无 trollvncmanager")
    sys.exit(1)
print("  .tipa 条目 %d · trollvncmanager %.2f MB" % (n_entries, len(mgr) / 1048576))

print()
print("  ── 核验 app.list 版本字段（ASCII 字面量，__cstring）──")
allok = True
for k in ["shortVersionString", "bundleVersion", "screenBand", "wantBand"]:
    n = mgr.count(k.encode())
    print("     %-20s %d 处  %s" % (k, n, "✓" if n else "✗ 缺失"))
    allok = allok and n > 0

dest = os.path.join(OUT, "TrollVNC_0.0.1-run%d.tipa" % RUN_NUMBER)
io.open(dest, "wb").write(inner)
print()
print("  ★ %s" % ("产物含新代码 ✓ → %s" % os.path.relpath(dest) if allok else "✗ 产物不含新代码"))
