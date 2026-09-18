r"""拉取 OmniParser V2 的 icon_caption 权重（Florence-2 基座微调版）。

仓库：microsoft/OmniParser-v2.0
  icon_caption/config.json · generation_config.json · model.safetensors
  （官方 README 用的是 icon_caption 这份，社区常重命名成 icon_caption_florence）

★ 为什么需要它：icon_detect 只告诉你"这里有个可交互图标"（bbox ✓），
  但【不给它名字】✗ —— 而 L0 图标库要的正是"这个图标是什么"✓。
  icon_caption 就是干这个的：输入图标裁剪图 → 输出语义（"Menu"/"Back"/"Search"…）。

★ 许可：icon_caption 权重是 MIT（icon_detect 的是 AGPL-3.0）—— 两者不同，都用得上。
"""
import os
import sys

os.environ.setdefault("HTTPS_PROXY", "http://127.0.0.1:7890")
os.environ.setdefault("HTTP_PROXY", "http://127.0.0.1:7890")

DEST = r"D:\编程项目\SuperPhone\_research\OmniParser\weights"
os.makedirs(DEST, exist_ok=True)

try:
    from huggingface_hub import hf_hub_download
except Exception as e:
    print("✗ 缺 huggingface_hub: %s" % e)
    sys.exit(1)

FILES = [
    "icon_caption/config.json",
    "icon_caption/generation_config.json",
    "icon_caption/model.safetensors",
]
ok = 0
for f in FILES:
    try:
        p = hf_hub_download(repo_id="microsoft/OmniParser-v2.0", filename=f, local_dir=DEST)
        print("  ✓ %-46s %8.2f MB" % (f, os.path.getsize(p) / 1048576))
        ok += 1
    except Exception as e:
        print("  ✗ %-46s %s" % (f, str(e)[:100]))

print()
print("  %d/%d 下载成功 → %s" % (ok, len(FILES), DEST))
if ok == len(FILES):
    print("  ★ icon_caption 就位：%s" % os.path.join(DEST, "icon_caption"))
    print("    （下一步：scripts/omniparser-caption.py）")
