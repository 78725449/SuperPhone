r"""拉取 OmniParser V2 的 icon_detect 权重（YOLOv8-Nano 微调版）。

仓库：microsoft/OmniParser-v2.0
  icon_detect/train_args.yaml  ·  icon_detect/model.pt  ·  icon_detect/model.yaml

★ 走代理（api.github.com / huggingface.co 在本机常被阻断；AGENTS.md 记了这条）。
★ 许可提醒：OmniParser 代码 MIT，但 icon_detect 的【权重是 AGPL-3.0】——
  内网自用不分发没问题，将来若产品化需注意。
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

FILES = ["icon_detect/train_args.yaml", "icon_detect/model.pt", "icon_detect/model.yaml"]
ok = 0
for f in FILES:
    try:
        p = hf_hub_download(repo_id="microsoft/OmniParser-v2.0", filename=f,
                            local_dir=DEST)
        sz = os.path.getsize(p)
        print("  ✓ %-34s %8.2f MB" % (f, sz / 1048576))
        ok += 1
    except Exception as e:
        print("  ✗ %-34s %s" % (f, str(e)[:110]))

print()
print("  %d/%d 下载成功 → %s" % (ok, len(FILES), DEST))
if ok == len(FILES):
    mp = os.path.join(DEST, "icon_detect", "model.pt")
    print("  ★ 权重就位：%s" % mp)
    print("    （下一步：scripts/validate-omniparser-ios.py）")
