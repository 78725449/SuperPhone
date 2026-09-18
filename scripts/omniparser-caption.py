r"""icon_caption：给"纯图标元素"起名字 —— L0 图标库的关键一步。

★ 为什么需要：icon_detect 只说"这里有个可交互图标"（bbox ✓），不给名字 ✗。
  而 L0 图标库要的正是"这个图标是什么"（"返回"/"搜索"/"点赞"…）✓。
  icon_caption 就是干这个的：输入图标裁剪 → 输出语义（照 OmniParser 的用法）。

★ 照抄它的用法（util/utils.py::get_caption_model_processor / get_parsed_content_icon）：
    processor = AutoProcessor.from_pretrained("microsoft/Florence-2-base", trust_remote_code=True)
    model     = AutoModelForCausalLM.from_pretrained(<微调权重>, torch_dtype=float16).to(device)
    prompt    = "<CAPTION>"      # florence 系
    裁剪 → ★ resize(64,64) → batch 推理（max_new_tokens=20, do_sample=False ✓ 确定性）

★★ 本脚本额外回答一个【关键问题】：
   同一个图标（如返回箭头）在【不同页面/不同截图】上，会不会得到【一致的名字】？
   —— 这是 L0 图标库能否成立的前提 ✗：若同一个图标每次叫法都不同，就聚不成库 ✗
"""
import glob
import json
import os
import re
import sys
import time
from collections import Counter

import cv2
import numpy as np
import torch
from PIL import Image

ROOT = r"D:\编程项目\SuperPhone"
WEIGHTS_DIR = os.path.join(ROOT, "_research", "OmniParser", "weights")
CAPTION_DIR = os.path.join(WEIGHTS_DIR, "icon_caption")
ELEM_DIR = os.path.join(ROOT, "data", "omniparser-elements")
OUT_JSON = os.path.join(ROOT, "data", "omniparser-captions.json")

MA = os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use",
                  "打开设置，进入蓝牙页面，然后返回，再进入通用页面")
SHOT_DIRS = {"设置 App": MA, "抖音": os.path.join(ROOT, "ma35_task")}


def imread_u(p):
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


if not os.path.isdir(CAPTION_DIR):
    print("✗ 缺 icon_caption 权重: %s" % CAPTION_DIR)
    print("  先跑: python scripts/fetch-omniparser-caption.py")
    sys.exit(1)

print("=" * 96)
print("  icon_caption：给纯图标元素命名")
print("=" * 96)

from transformers import AutoProcessor, AutoModelForCausalLM   # noqa: E402

t0 = time.time()
processor = AutoProcessor.from_pretrained("microsoft/Florence-2-base", trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained(CAPTION_DIR, torch_dtype=torch.float16,
                                             trust_remote_code=True).to("cuda")
model.eval()
print("  ✓ 模型就绪（%.1fs）· 显存 %.1f GB"
      % (time.time() - t0, torch.cuda.memory_allocated() / 1e9))

# 收集"纯图标元素"（content 为空）—— 它们才是 OCR 给不了的
crops, meta = [], []
for f in sorted(glob.glob(os.path.join(ELEM_DIR, "*.json"))):
    d = json.load(open(f, encoding="utf-8"))
    label = d["label"]
    sd = SHOT_DIRS.get(label)
    if not sd:
        continue
    img_path = os.path.join(sd, d["screenshot"])
    if not os.path.exists(img_path):
        continue
    im = imread_u(img_path)
    if im is None:
        continue
    H, W = im.shape[:2]
    for e in d["elements"]:
        if e.get("type") != "icon" or e.get("content"):
            continue                      # 只要【没有文字】的纯图标 ✓
        x1, y1, x2, y2 = [int(v) for v in e["bbox"]]
        x1, y1 = max(0, x1), max(0, y1)
        x2, y2 = min(W, x2), min(H, y2)
        if x2 - x1 < 12 or y2 - y1 < 12:
            continue
        crop = im[y1:y2, x1:x2]
        crop = cv2.resize(crop, (64, 64))
        crops.append(Image.fromarray(cv2.cvtColor(crop, cv2.COLOR_BGR2RGB)))
        meta.append({"label": label, "shot": d["screenshot"],
                     "bbox": [x1, y1, x2 - x1, y2 - y1]})

print("  待命名纯图标：%d 个" % len(crops))
if not crops:
    print("  ✗ 没有纯图标元素，先跑 scripts/omniparser-full.py")
    sys.exit(1)

PROMPT = "<CAPTION>"
caps = []
B = 16
t0 = time.time()
with torch.inference_mode():
    for i in range(0, len(crops), B):
        batch = crops[i:i + B]
        inputs = processor(images=batch, text=[PROMPT] * len(batch),
                           return_tensors="pt", do_resize=False).to("cuda", torch.float16)
        ids = model.generate(input_ids=inputs["input_ids"],
                             pixel_values=inputs["pixel_values"],
                             max_new_tokens=20, num_beams=1, do_sample=False)
        texts = processor.batch_decode(ids, skip_special_tokens=True)
        caps.extend([t.strip() for t in texts])
        print("    %3d/%d …" % (min(i + B, len(crops)), len(crops)), end="\r")
print()
print("  ✓ 命名完成（%.1fs，%.0f ms/个）" % (time.time() - t0, 1000 * (time.time() - t0) / len(crops)))

for m, c in zip(meta, caps):
    m["caption"] = c

with open(OUT_JSON, "w", encoding="utf-8") as fh:
    json.dump(meta, fh, ensure_ascii=False, indent=2)

print()
print("=" * 96)
print("  结果")
print("=" * 96)
cnt = Counter(c.strip().lower().rstrip(".") for c in caps)
print("  命名分布（Top 20）：")
for k, v in cnt.most_common(20):
    print("    %-30s %d" % (k[:30], v))
nonempty = [c for c in caps if c.strip()]
print()
print("  ★ 非空命名 %d / %d（%.0f%%）" % (len(nonempty), len(caps), 100.0 * len(nonempty) / len(caps)))
print("  ★ 不同名字 %d 种 → ★ 平均每个名字被用 %.1f 次"
      % (len(cnt), len(caps) / max(1, len(cnt))))
print()
print("=" * 96)
print("  判读（★ 关键：同图标是否一致命名）")
print("=" * 96)
if len(cnt) and len(caps) / len(cnt) >= 3:
    print("  → ★★ 名字复用率较高（平均一个名字用 %.1f 次）→ 存在稳定词汇 → L0 库可聚 ✓"
          % (len(caps) / len(cnt)))
else:
    print("  → ⚠️ 名字高度分散（%d 个图标出 %d 种名字）→ 同图标命名不稳定 → 直接入库会碎 ✗"
          % (len(caps), len(cnt)))
print()
print("  ★ 名字（英文）与我们的中文 UI 有落差 → 是否需要中文化/映射，看后续使用")
print("  逐图标明细已落盘：%s" % OUT_JSON)
