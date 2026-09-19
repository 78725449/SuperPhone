r"""L0 图标质检 v2 —— 直接取样 + 人工经视觉（当前模型）审核
   做法：不依赖聚类 ✗ — 聚类的 member 格式不合 ✗，直接【顺序读 40 张，看内容后判定是 图标/文字/空白/背景】
   输出：标的 catalog（cuts + descriptions），由引擎【看图】给出
"""
import glob
import io
import json
import os

ROOT = r"D:\编程项目\SuperPhone"
CROPS = os.path.join(ROOT, "data", "omniparser-crops")
OUT = os.path.join(ROOT, "data", "omniparser-icons-sampled.json")

# 抽 [间隔采样]: 859 / 40 ≈ 每 21 张取一张 ✓ 均匀分布在各时间点（等差 — 保证覆盖）
allf = sorted(glob.glob(os.path.join(CROPS, "*.png")))
step = max(1, len(allf) // 40)
reps = allf[:len(allf):step][:40]
print("  裁片总数 %d · 抽 %d 张代表（间隔 %d）" % (len(allf), len(reps), step))

items = []
for r in reps[:40]:
    sz = os.path.getsize(r)
    items.append({
        "crop": os.path.relpath(r, ROOT),
        "sizeKB": round(sz / 1024, 2),
    })

doc = {"catalogVersion": "v2-2026-09-21",
       "samplingMethod": "顺序均分（间隔 %d）· 40 张代表" % step,
       "total": len(allf),
       "sampled": items}
io.open(os.path.join(ROOT, "data", "omniparser-icons-sampled.json"), "w", encoding="utf-8").write(
    json.dumps(doc, ensure_ascii=False, indent=2))
print("  ✓ 落盘 %d 条" % len(items))
print()
print("  下一步：一轮 read_image 逐张看 + 起名")
for it in items[:40]:
    print("   %s  (%.1f KB)" % (it["crop"], it["sizeKB"]))
