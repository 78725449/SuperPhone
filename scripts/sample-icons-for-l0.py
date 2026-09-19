r"""L0 图标质检 —— 用【视觉】从 859 张裁片中筛出【真图标】+ 挑出代表抽样做 catalog。

★ 为什么要我（引擎）做：裁片是 OmniParser 检测框裁出来的——其中含文字块、按钮、空白、背景。
  我（当前模型）有视觉能力，直接看图可判"这是不是一个完整的 UI 控件（按钮/图标/开关）"。
★ 做法（批量，不逐个毁库 ✗）：
  1. 分类目录 data/omniparser-crops/（859 张）按 frame 分组
  2. 抽样每 5 张一张作为【代表】—— 直接 read_image 看内容 + 定义快照 typeTag
  3. 产出 skills/superphone-device/assets/_shared/elements/elements-catalog.json（v1 草案）
     字段：{cropFile, sourceShot, tag(主分类), verified:seed|auto, proposed_name}

★ 注意（来自实测）：859 张【不是全部是图标】✗ —— 有文字（与 OCR 冲突）、有空白、有部分裁剪 ✗。
  → 用「我看了之后判了 type」的方式（内容锚就是描述）最好 —— 不靠模型自动生成名称 ✗（会乱）✓
"""
import glob
import json
import os
import re

ROOT = r"D:\编程项目\SuperPhone"
CROPS = os.path.join(ROOT, "data", "omniparser-crops")
CATALOG = os.path.join(ROOT, "skills", "superphone-device", "assets", "_shared", "elements", "elements-catalog.json")

if not os.path.isdir(CROPS):
    print("✗ 裁片目录不存在")
    sys.exit(1)

files = sorted(glob.glob(os.path.join(CROPS, "*.png")) + glob.glob(os.path.join(CROPS, "*.jpg")))
print("  裁片总数：%d" % len(files))

# ★ 按 (页面来源, 尺寸, phash 相似) 分组合并 —— 我有 100 类聚类（data/omniparser-icon-clusters.json）
clusters = []
cj = os.path.join(ROOT, "data", "omniparser-icon-clusters.json")
if os.path.exists(cj):
    cj_data = json.load(open(cj, encoding="utf-8"))
    cls = cj_data.get("clusters", [])
    print("  已有聚类：%d 类" % len(cls))
else:
    cls = []
    print("  （无聚类数据，靠视觉采样归类）")

# ＊ 代表抽样：每类最多 1-2 张，其余跳过（后续人工确认）
# 优先：cluster.size > 1（≥2 张说明它【在多帧中出现】，可靠性高）
reps = []
if cls:
    for c in cls:
        members = c.get("members", [])
        if not members:
            continue
        # members 是 "设置 App|shot|bbox" key 形式，从中找 crop 文件名
        for mkey in members[:2]:
            # key 形如 "抖音|screenshot_7.png|316,1092"
            parts = mkey.split("|")
            shot = parts[1] if len(parts) > 1 else ""
            ms = re.search(r"screenshot_(\d+)", shot)
            if not ms:
                continue
            sid = ms.group(1)
            # 从 data/omniparser-crops/ 源头找对应文件
            # (crop 文件名格式：s{sid}_{i}_{w}x{h}_c{conf}.png)
            pattern = os.path.join(CROPS, "s%s_*" % sid)
            cand = sorted(glob.glob(pattern))
            if cand:
                reps.append(cand[0])
else:
    reps = files[:50]   # 没有聚类数据就直接抽前 50

reps = [f for f in reps if os.path.exists(f)][:40]
print("  代表抽样：%d 张" % len(reps))

out = [{"catalogVersion": "v1-2026-09-21", "cropsDir": "data/omniparser-crops/",
        "total": len(files), "representatives": len(reps), "note": "AI 视觉抽查 + 100 类聚类分类辅助"}]
for r in reps[:40]:
    rel = os.path.relpath(r, ROOT)
    sz = os.path.getsize(r)
    out.append({"crop": rel, "sizeKB": round(sz / 1024, 1)})

with open(os.path.join(ROOT, "data", "omniparser-icons-sampled.json"), "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print("  草案已落盘：data/omniparser-icons-sampled.json")
print()
print("  ★★ 下一步：引擎（当前模型）用 read_image 逐张【看内容】，再起中文名入册")
