"""把 3 个非 git 副本对齐到上游最新。

上一轮 read-tree 失败原因：工作区文件是【未跟踪】状态，git 拒绝用上游版本覆盖它们
（"Untracked working tree file ... would be overwritten by merge"）。
标准解法：先把现状 git add + commit 成基线（内容进历史，可回溯），
再 git reset --hard origin/<branch> —— 此时文件已是【已跟踪】，可以安全覆盖。
"""
import os, subprocess

DST = r"D:\编程项目\SuperPhone\_research"
PROXY = "http://127.0.0.1:7890"
TARGETS = [
    ("mobile-use", "main"),
    ("mobilerun",  "main"),
    ("surya",      "master"),
]
env = dict(os.environ, HTTPS_PROXY=PROXY, HTTP_PROXY=PROXY,
           GIT_TERMINAL_PROMPT="0",
           GIT_AUTHOR_NAME="research-sync", GIT_AUTHOR_EMAIL="research-sync@local",
           GIT_COMMITTER_NAME="research-sync", GIT_COMMITTER_EMAIL="research-sync@local")


def run(args, cwd, timeout=900):
    p = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()


for name, branch in TARGETS:
    d = os.path.join(DST, name)
    print(f"\n{'='*76}\n{name}  →  对齐到 origin/{branch}\n{'='*76}", flush=True)

    rc, up_sha, _ = run(["git", "rev-parse", "--short", f"origin/{branch}"], d)
    if rc != 0:
        print("  ✗ 找不到上游分支（fetch 未成功）"); continue
    print(f"  上游 {branch}@{up_sha}")

    # 1) 把现有内容提交成基线（保留在 git 历史里，可回溯）
    run(["git", "add", "-A"], d)
    rc, st, _ = run(["git", "status", "--porcelain"], d)
    n = len([l for l in st.splitlines() if l.strip()])
    if n:
        rc, out, err = run(["git", "commit", "-q", "-m",
                            "baseline: 接入上游前的本地副本快照"], d)
        print(f"  ✓ 已提交基线（{n} 个文件进历史，可回溯）")
    else:
        print("  （工作区为空，无需基线）")

    # 2) 硬对齐到上游
    rc, out, err = run(["git", "reset", "--hard", f"origin/{branch}"], d)
    if rc == 0:
        rc2, head, _ = run(["git", "rev-parse", "--short", "HEAD"], d)
        rc3, st2, _ = run(["git", "status", "--porcelain"], d)
        dirty = len([l for l in st2.splitlines() if l.strip()])
        print(f"  ✓ 工作区已对齐到 {branch}@{head}  残留未跟踪 {dirty} 条")
    else:
        print(f"  ✗ {err[:200]}")

print("\n完成")
