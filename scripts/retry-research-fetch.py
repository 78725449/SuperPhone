"""重试 4 个 fetch 失败的上游（代理断流）。

失败原因：curl 56 schannel: server closed abruptly —— Windows 的 TLS 后端 schannel 经代理
传输大仓库时被中断。对策（按优先级）：
  1) 换 openssl 后端（仅本次命令级 -c，不动全局配置）
  2) 浅取 --depth 1（只取最新快照，传输量最小）
  3) 只取需要的分支
"""
import os, subprocess

DST = r"D:\编程项目\SuperPhone\_research"
PROXY = "http://127.0.0.1:7890"

TARGETS = [
    ("TrollVNC-upstream", "https://github.com/OwnGoalStudio/TrollVNC", "main", True),
    ("mobile-use",        "https://github.com/minitap-ai/mobile-use",  "main", False),
    ("mobilerun",         "https://github.com/droidrun/mobilerun",     "main", False),
    ("surya",             "https://github.com/datalab-to/surya",       "master", False),
]

env = dict(os.environ, HTTPS_PROXY=PROXY, HTTP_PROXY=PROXY, GIT_TERMINAL_PROMPT="0")


def run(args, cwd, timeout=1200):
    p = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()


for name, url, branch, is_git in TARGETS:
    d = os.path.join(DST, name)
    print(f"\n{'='*76}\n{name}   (分支 {branch}  已是git={is_git})\n{'='*76}", flush=True)
    if not os.path.isdir(d):
        print("  目录不存在"); continue

    if not is_git:
        run(["git", "init", "-q"], d)
        rc, out, _ = run(["git", "remote", "-v"], d)
        if "origin" not in out:
            run(["git", "remote", "add", "origin", url], d)

    # 先确定上游分支名（浅取也要正确分支）
    got = False
    for attempt, extra in enumerate([
        ["-c", "http.sslBackend=openssl", "-c", "http.postBuffer=524288000"],
        ["-c", "http.sslBackend=openssl"],
        [],
    ], 1):
        depth = ["--depth", "1"] if (not is_git or attempt >= 2) else []
        args = ["git"] + extra + ["fetch"] + depth + ["origin", branch]
        print(f"  尝试 {attempt}: {' '.join(args)}", flush=True)
        rc, out, err = run(args, d)
        if rc == 0:
            print("      ✓ fetch 成功")
            got = True
            break
        print(f"      ✗ {err.splitlines()[0][:110] if err else '(无 stderr)'}")
    if not got:
        print("      ✗✗ 三次尝试均失败")
        continue

    rc, up_sha, _ = run(["git", "rev-parse", "--short", f"origin/{branch}"], d)
    print(f"      上游 {branch}@{up_sha}")

    if is_git:
        rc, head, _ = run(["git", "rev-parse", "--short", "HEAD"], d)
        rc, st, _ = run(["git", "status", "--porcelain"], d)
        dirty = len([l for l in st.splitlines() if l.strip()])
        print(f"      本地 HEAD={head}  改动 {dirty} 条")
        if head == up_sha:
            print("      ✓ 已是最新"); continue
        if dirty:
            print("      ⚠ 有本地改动，只 fetch 不覆盖"); continue
        rc, out, err = run(["git", "merge", "--ff-only", f"origin/{branch}"], d)
        print("      ✓ 快进成功" if rc == 0 else f"      ✗ 快进失败: {err[:150]}")
    else:
        # 非 git 副本：把工作区对齐到上游最新
        run(["git", "reset", "-q", "--mixed"], d)
        rc, _, err = run(["git", "read-tree", "-m", "-u", f"origin/{branch}"], d)
        run(["git", "reset", "-q", "--mixed", f"origin/{branch}"], d)
        if rc == 0:
            print(f"      ✓ 工作区已对齐到 {branch}@{up_sha}")
            rc, head, _ = run(["git", "rev-parse", "--short", "HEAD"], d)
            print(f"        当前 HEAD={head}")
        else:
            print(f"      ✗ 对齐失败: {err[:150]}")

print("\n\n完成")
