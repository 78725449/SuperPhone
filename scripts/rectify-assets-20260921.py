r"""阶段性整改 2026-09-21：data/ 资产逐项分级（用户已裁决方案）。

★ 分级铁律：
  · 原始证据层 ✗ 永不清（可被未来管线重新解析的本钱）
  · 派生中间态 可随时重算 → 清出活跃目录
  · 错标/错协议的"资产"（误导性最危险）→ 必须移出活跃位置 ✗
★ 此处用【移动到 data/archive-20260921/】而非物理删除（审计先于删除 + 可救回）；生成清单 manifest.json。

判定依据（本 session 实测）：
  ① data/pages/设置-根页 与 设置-子页-允许"微博" —— v1 采集时 open 失败走到【微博App设置页】，
     目录名错标（自证"含设置"被通用词骗 → 8帧采集错页）→ 归档
  ② data/pages/抖音-首页（连拍版）与 page-assets 抖音-首页.json —— 采样协议错误
     （同一条视频连拍 → 31/32 假稳定，视频标题/字幕被当成结构）✗ 跨视频采样已纠正 → 归档
  ③ omniparser-elements-filtered / omniparser-regions —— 派生中间态（原料=截图在，管线可重算）→ 归档
  ④ ma35_task/ · engine-baselines/ · engine-trial/ · interaction-samples.jsonl ·
     omniparser-elements/ · omniparser-crops/ · pages-dynamic/ · page-assets-dynamic/ —— 原始证据/有效资产 → 保留
"""
import json
import os
import shutil
import time

ROOT = r"D:\编程项目\SuperPhone"
ARC = os.path.join(ROOT, "data", "archive-20260921")

MOVES = [
    # (源, 原因)
    ("data/pages/设置-根页", "错标：实际为微博App设置页（v1 open 失败、自证被通用词骗）——目录名不可信"),
    ("data/pages/设置-子页-允许“微博”", "与「设置-根页」同为该页的重复 8 帧（Jaccard=1.00 已证同页）"),
    ("data/pages/抖音-首页", "连拍采样协议错误（同一条视频的 8 个瞬间 → 31/32 假稳定 ✗）"),
    ("data/page-assets/设置-根页.json", "由错标帧生成 ✗"),
    ("data/page-assets/设置-子页-允许“微博”.json", "由错标帧生成 ✗"),
    ("data/page-assets/抖音-首页.json", "假稳定资产（视频标题/字幕 8/8 误判为结构）✗"),
    ("data/omniparser-elements-filtered", "派生中间态（可由 omniparser-elements+原料截图重算）"),
    ("data/omniparser-regions", "派生中间态（build-regions.py 可重算）"),
]

print("=" * 88)
print("  data/ 资产分级整改（移动到 data/archive-20260921/，非物理删除）")
print("=" * 88)
os.makedirs(ARC, exist_ok=True)
manifest = {"date": time.strftime("%Y-%m-%d %H:%M"), "reason": "阶段性整改：错标/过期/中间态清出活跃目录",
            "moves": []}
for src, why in MOVES:
    s = os.path.join(ROOT, src)
    if not os.path.exists(s):
        print("  （不存在，跳过）%s" % src)
        continue
    dst = os.path.join(ARC, src.replace("/", "_"))
    if os.path.exists(dst):
        dst += "-dup"
    shutil.move(s, dst)
    n = len(os.listdir(dst)) if os.path.isdir(dst) else 1
    manifest["moves"].append({"src": src, "to": os.path.relpath(dst, ARC), "files": n})
    print("  ✓ %-42s → %s（%d 项）" % (src, os.path.basename(dst), n))

# 清单（原因单列，落盘 snapshot：谁在什么判据下被移走）
with open(os.path.join(ARC, "manifest.json"), "w", encoding="utf-8") as fh:
    json.dump({"archivedAt": time.strftime("%Y-%m-%d %H:%M"), "moves": [{"src": s, "reason": w} for s, w in MOVES]},
              fh, ensure_ascii=False, indent=2)
print()
print("  清单：%s\\manifest.json" % ARC)
print()
print("=== 活跃目录整改后现状 ===")
for d in ("data/pages", "data/page-assets", "data/pages-dynamic", "data/page-assets-dynamic",
          "data/omniparser-elements", "data/engine-trial", "data/engine-baselines"):
    p = os.path.join(ROOT, d)
    if os.path.isdir(p):
        sub = sum(len(os.listdir(os.path.join(p, x))) if os.path.isdir(os.path.join(p, x)) else 1
                  for x in os.listdir(p))
        print("  ✓ %-28s %d 项（留）" % (d, sub))
    else:
        print("  — %-28s（已清空/不存在）" % d)
