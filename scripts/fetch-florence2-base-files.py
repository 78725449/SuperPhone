r"""补下 Florence-2-base 的 processor/tokenizer 文件（icon_caption 权重里没有这些）。

★ 现象（2026-09-19 实测）：icon_caption 的权重只有 model.safetensors + config.json +
  generation_config.json；而 util/utils.py 的用法是
      AutoProcessor.from_pretrained("microsoft/Florence-2-base", trust_remote_code=True)
  → 它会去 HF 取 base 的 tokenizer/preprocessor；本机代理对 HF 不稳定，
    取到一半断掉 → merges.txt 缺失 → `open(merges_file)` 拿到 None → TypeError ✗

★ 对策：显式把 base 的这几个【小文件】下全（都只有几十 KB~几 MB），并带重试。
  已经下好的 1GB icon_caption 权重不受影响，不重下。
"""
import os
import sys
import time

os.environ.setdefault("HTTPS_PROXY", "http://127.0.0.1:7890")
os.environ.setdefault("HTTP_PROXY", "http://127.0.0.1:7890")

DEST = r"D:\编程项目\SuperPhone\_research\OmniParser\weights"
os.makedirs(DEST, exist_ok=True)

from huggingface_hub import hf_hub_download   # noqa: E402

# Florence-2-base 里 processor/tokenizer/远程代码所需的文件
FILES = [
    "preprocessor_config.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
    "special_tokens_map.json",
    "processing_florence2.py",
    "configuration_florence2.py",
    "config.json",
]

print("=" * 88)
print("  补下 Florence-2-base 的 processor/tokenizer（%d 个文件）" % len(FILES))
print("=" * 88)
ok, fail = 0, []
for f in FILES:
    for attempt in range(4):
        try:
            p = hf_hub_download(repo_id="microsoft/Florence-2-base", filename=f,
                                local_dir=DEST)
            print("  ✓ %-34s %8.2f KB" % (f, os.path.getsize(p) / 1024))
            ok += 1
            break
        except Exception as e:
            if attempt == 3:
                print("  ✗ %-34s %s" % (f, str(e)[:80]))
                fail.append(f)
            else:
                time.sleep(3 * (attempt + 1))

print()
print("  %d/%d 成功" % (ok, len(FILES)))
if fail:
    print("  失败：%s" % " · ".join(fail))
    print("  → 可重跑本脚本；HF 代理不稳时多试几次即可")
else:
    print("  ★ 齐了 → 重跑 scripts/omniparser-caption.py")
print("  下载目录：%s（HF 会按 repo 名建子目录）" % DEST)
