"""从网关诊断日志里区分【浏览器真实请求】与【验证脚本请求】，并给出结论。

判据：浏览器发起的请求带 Referer 或 Origin；脚本（python urllib）两者都不带。
"""
import glob, os, re, sys

logs = sorted(glob.glob(r"D:\编程项目\SuperPhone\trollvnc-farm\data\gateway-*.log"),
              key=os.path.getmtime)
if not logs:
    print("未找到网关日志"); sys.exit(1)
log = logs[-1]
print(f"日志: {os.path.basename(log)}  {os.path.getsize(log)//1024}KB\n")

pat = re.compile(r"\[redir\] (\w+) (\S+) dest=(\S+) accept=(\S*) origin=(\S+) ref=(\S+) → (.+)$")
browser, script = [], []
with open(log, encoding="utf-8", errors="replace") as f:
    for line in f:
        m = pat.search(line.strip())
        if not m:
            continue
        method, path, dest, accept, origin, ref, action = m.groups()
        row = (method, path, dest, origin, ref, action)
        if ref == "-" and origin == "-":
            script.append(row)
        else:
            browser.append(row)

print("=" * 100)
print(f"【浏览器真实请求】{len(browser)} 条")
print("=" * 100)
for method, path, dest, origin, ref, action in browser:
    loc = "301→https" if "301" in action else "明文服务"
    print(f"  {method:4s} {path[:66]:68s} dest={dest:9s} {loc}")

print()
print("=" * 100)
print(f"【我的验证脚本请求】{len(script)} 条（不计入判定）")
print("=" * 100)

# 结论
print()
print("=" * 100)
bad = [r for r in browser if "301" in r[5]]
# 顶层导航被 301 是正确的（对照组）；其余被 301 才是问题
topnav = [r for r in bad if r[2] == "document"]
problem = [r for r in bad if r[2] != "document"]
print("结论")
print("=" * 100)
print(f"  浏览器请求中被 301 的：{len(bad)} 条")
print(f"    ├ 其中顶层导航(document)：{len(topnav)} 条 —— ★ 这是【正确】的（用户手输 http 应升级到 https）")
for r in topnav:
    print(f"    │    {r[0]} {r[1]}")
print(f"    └ 其中非顶层导航：{len(problem)} 条 —— {'✗ 有问题！' if problem else '☆ 无（正确）'}")
for r in problem:
    print(f"         ✗ {r[0]} {r[1]}  dest={r[2]}  {r[5]}")

served = [r for r in browser if "301" not in r[5]]
print()
print(f"  ★ 走【明文服务】的浏览器请求：{len(served)} 条")
for r in served:
    print(f"      {r[0]:4s} {r[1][:70]}")

print()
if not problem:
    print("  ★★ 判定：浏览器与网关之间的链路【完全正常】—— 没有任何非顶层导航的请求被 301。")
    print("      如果面板仍不显示，问题不在协议/重定向这一层，应转查其它方向。")
else:
    print("  ✗ 判定：仍有非顶层导航请求被 301，需继续修。")
