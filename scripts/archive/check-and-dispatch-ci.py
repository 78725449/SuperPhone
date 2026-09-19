r"""检查 CI 状态 + 需要时手动触发 workflow_dispatch。

★ 项目坑（AGENTS.md 已记）：Git Data API 推送【不触发】Actions → 必须手动 dispatch。
★ 另一坑：build-ipa.mjs 的两个 Windows bug 之一就是 `--data "@file"` 的写法（`^` 要写 `~1`）。
  这里用 python 发请求，避开 shell 引号问题。
"""
import json
import os
import ssl
import sys
import time
import urllib.request

REPO = "78725449/SuperPhone"
TOKEN = os.environ.get("GHTOK") or ""
PROXY = "http://127.0.0.1:7890"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}))


def api(path, method="GET", body=None):
    url = "https://api.github.com%s" % path
    data = json.dumps(body).encode() if body is not None else None
    rq = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer %s" % TOKEN,
        "Accept": "application/vnd.github+json",
        "User-Agent": "dsh",
        "Content-Type": "application/json"})
    try:
        with opener.open(rq, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:300]


head = os.popen("git rev-parse HEAD").read().strip()
print("  本地 HEAD  = %s" % head[:12])
st, ref = api("/repos/%s/git/ref/heads/main" % REPO)
remote = ref["object"]["sha"] if ref else "?"
print("  远程 main  = %s" % remote[:12])

st, runs = api("/repos/%s/actions/runs?per_page=5" % REPO)
print("\n  最近 CI runs：")
found = False
if runs and runs.get("workflow_runs"):
    for r in runs["workflow_runs"][:5]:
        mark = "★" if r["head_sha"] == remote else " "
        if r["head_sha"] == remote:
            found = True
        print("   %s #%-4s %-10s %-10s %s  %s"
              % (mark, r["run_number"], r["status"], r["conclusion"] or "-",
                 r["head_sha"][:8], r["created_at"]))
else:
    print("    （无 run 或查询失败：%s）" % str(runs)[:120])

if not found:
    print("\n  ★ 远程 HEAD 没有对应的 CI run → Git Data API 推送不触发 Actions，需手动 dispatch")
    st, wf = api("/repos/%s/actions/workflows/build.yml" % REPO)
    print("     workflow 查询：HTTP %s" % st)
    st, res = api("/repos/%s/actions/workflows/build.yml/dispatches" % REPO,
                  method="POST", body={"ref": "main"})
    print("     dispatch：HTTP %s %s" % (st, "✓ 已触发" if st == 204 else str(res)[:200]))
    if st == 204:
        print("     等 15 秒后查 run…")
        time.sleep(15)
        st, runs = api("/repos/%s/actions/runs?per_page=3" % REPO)
        for r in (runs or {}).get("workflow_runs", [])[:3]:
            print("     #%-4s %-10s %-10s %s  %s"
                  % (r["run_number"], r["status"], r["conclusion"] or "-",
                     r["head_sha"][:8], r["created_at"]))
