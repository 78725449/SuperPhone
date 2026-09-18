"""查最近的 CI run 状态，并给出失败时的权威错误位置（check-run annotations）。"""
import json
import os
import urllib.request

REPO = "78725449/SuperPhone"
T = os.environ["GHTOK"]
PROXY = "http://127.0.0.1:7890"
op = urllib.request.build_opener(
    urllib.request.ProxyHandler({"https": PROXY, "http": PROXY}))


def api(p):
    rq = urllib.request.Request("https://api.github.com" + p,
                                headers={"Authorization": "Bearer " + T,
                                         "User-Agent": "dsh",
                                         "Accept": "application/vnd.github+json"})
    with op.open(rq, timeout=60) as r:
        raw = r.read().decode()
        return json.loads(raw) if raw.strip() else None


runs = api("/repos/%s/actions/runs?per_page=5" % REPO).get("workflow_runs", [])
print("=" * 90)
print("最近 5 次 run")
print("=" * 90)
for r in runs:
    print("  #%s  %-11s  %-14s  head=%s  %s" % (
        r["run_number"], r["status"], r["conclusion"] or "-",
        r["head_sha"][:8], r["created_at"]))
print()

if not runs:
    print("  (没有 run)")
    raise SystemExit(0)

latest = runs[0]
print("=" * 90)
print("最新 run #%s 详情" % latest["run_number"])
print("=" * 90)
print("  状态: %s / %s" % (latest["status"], latest["conclusion"] or "(进行中)"))
print("  head: %s" % latest["head_sha"])
print("  事件: %s   分支: %s" % (latest["event"], latest["head_branch"]))
print("  链接: %s" % latest["html_url"])
print()

jobs = api("/repos/%s/actions/runs/%s/jobs" % (REPO, latest["id"])).get("jobs", [])
print("  作业:")
for j in jobs:
    print("    %-42s %-11s %s" % (j["name"][:42], j["status"],
                                  j["conclusion"] or "-"))

failed = [j for j in jobs if j.get("conclusion") == "failure"]
if failed:
    print()
    print("=" * 90)
    print("★ 失败作业的权威错误（check-run annotations）")
    print("=" * 90)
    for j in failed:
        print("  · %s" % j["name"])
        try:
            ann = api("/repos/%s/check-runs/%s/annotations" % (REPO, j["id"]))
            if not ann:
                print("      (无 annotation —— billing 拦截或 runner 故障常见于此)")
            for a in (ann or [])[:12]:
                print("      [%s] %s:%s  %s" % (
                    a.get("annotation_level"), a.get("path"),
                    a.get("start_line"), (a.get("message") or "")[:150]))
        except Exception as e:
            print("      取 annotation 失败: %s" % e)
elif latest["status"] != "completed":
    print()
    print("  ⏳ 还在跑 —— 用 `node scripts/wait-ipa.mjs <runId>` 或稍后再查")
else:
    print()
    print("  ✓ 全部作业成功")
