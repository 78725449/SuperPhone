r"""首次验收 script.exec 的三个新键（screenBand / require / wantBand）。

★ 项目纪律（AGENTS.md）："暴露「从未被调用过」的能力 = 给它做首次验收"。
★ 本脚本就是这三个键的首次真机验收。
步骤设计（无论设备在哪一页，结果都有信息量）：
  步A expect{screenBand:{bot:">=0"}} —— 无条件成立的断言，为的是【看 detail 里结构计数的实况】
     （若返回"未知 expect 键"→ 新镜像没部署上 ✗）
  步B tap 首页 tab + require{screenBand:{bot:">=3"}} ——
     · 若在带 tab 的页面 → 通过（且 tap 到"首页"）
     · 若在帮助/子页 → requireFailed（★ 前置条件正确拦截 ✓ —— 这正是我们要的语义）
wantBand=true → trace 每步带 bandBefore/bandAfter（监督数据回流引擎）。
"""
import json
import subprocess
import sys

args = ["python", r"D:\编程项目\SuperPhone\scripts\engine-prims.py", "exec",
        "--steps",
        json.dumps([
            {"op": "expect", "assert": {"screenBand": {"bot": ">=0"}}},
            {"op": "tap", "x": 0.102, "y": 0.963,
             "require": {"screenBand": {"bot": ">=3"}}},
        ]),
        "--wantband"]
p = subprocess.run(args, capture_output=True, text=True,
                   encoding="utf-8", errors="replace")
print(p.stdout or p.stderr)
