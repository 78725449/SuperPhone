"""把 _research/ 下的参考项目全部更新到上游最新。

分两类处理：
  A) 已是 git 仓库 → 直接 fetch + 检查能否快进 + pull（有本地改动则报告，不强推）
  B) 非 git 的源码副本 → 先 git init + remote add + fetch（只下载对象，不动工作区），
     再用 git status 看差异；若工作区与上游一致或只是旧版 → 安全对齐到最新；
     若有上游没有的本地文件 → 只报告，不覆盖。
"""
import os, subprocess, sys

DST = r"D:\编程项目\SuperPhone\_research"
PROXY = "http://127.0.0.1:7890"

REPOS = {
    "MobileAgent":       "https://github.com/X-PLUG/MobileAgent",
    "AppAgentX":         "https://github.com/Westlake-AGI-Lab/AppAgentX",
    "mobile-harness":    "https://github.com/droidrun/mobile-harness",
    "PhoneHarness":      "https://github.com/PhoneHarness/PhoneHarness",
    "AgentProg":         "https://github.com/MobileLLM/AgentProg",
    "TrollVNC-upstream": "https://github.com/OwnGoalStudio/TrollVNC",
    "dsh-ios-app":       "https://github.com/kriskwok/dsh-ios-app",
    "imessage-data-foundry": None,          # 已有 git，用自身 remote
    "mobile-use":        "https://github.com/minitap-ai/mobile-use",
    "mobilerun":         "https://github.com/droidrun/mobilerun",
    "OmniParser":        "https://github.com/microsoft/OmniParser",
    "surya":             "https://github.com/datalab-to/surya",
}

env = dict(os.environ, HTTPS_PROXY=PROXY, HTTP_PROXY=PROXY,
           GIT_TERMINAL_PROMPT="0", GIT_SSH_COMMAND="ssh -o BatchMode=yes")


def run(args, cwd, timeout=600):
    p = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()


def branch_of(cwd):
    rc, out, _ = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd)
    return out if rc == 0 else "main"


results = []
for name, url in REPOS.items():
    d = os.path.join(DST, name)
    if not os.path.isdir(d):
        results.append((name, "SKIP", "目录不存在"))
        continue
    print(f"\n{'='*76}\n{name}\n{'='*76}", flush=True)
    is_git = os.path.isdir(os.path.join(d, ".git"))

    if not is_git:
        if not url:
            results.append((name, "SKIP", "非 git 且无已知上游"))
            continue
        print(f"  [B] 非 git → 接入上游 {url}")
        run(["git", "init", "-q"], d)
        run(["git", "remote", "add", "origin", url], d)
        had_local = True          # 未知，保守处理
    else:
        print("  [A] 已是 git 仓库")
        rc, out, _ = run(["git", "remote", "-v"], d)
        if "origin" not in out:
            if url:
                run(["git", "remote", "add", "origin", url], d)
                print(f"      补上 origin = {url}")
        had_local = False

    print("  fetch 中…", flush=True)
    rc, out, err = run(["git", "fetch", "--all", "--tags", "--prune"], d, timeout=900)
    if rc != 0:
        print(f"      ✗ fetch 失败: {err[:200]}")
        results.append((name, "FAIL", f"fetch: {err[:80]}"))
        continue
    print("      ✓ fetch 完成")

    # 找默认分支
    rc, out, _ = run(["git", "symbolic-ref", "-q", "refs/remotes/origin/HEAD"], d)
    if rc == 0 and out:
        up = out.replace("refs/remotes/origin/", "")
    else:
        rc, out, _ = run(["git", "ls-remote", "--symref", "origin", "HEAD"], d)
        up = "main"
        for line in out.splitlines():
            if line.startswith("ref:") and "refs/heads/" in line:
                up = line.split("refs/heads/")[1].split()[0]
                break
    print(f"      上游默认分支: {up}")

    rc, hi, _ = run(["git", "rev-parse", "--short", f"origin/{up}"], d)
    up_sha = hi if rc == 0 else "?"

    if not is_git:
        # 非 git 副本：先看工作区与上游的差异规模
        run(["git", "add", "-A"], d)
        rc, st, _ = run(["git", "status", "--porcelain"], d)
        n_change = len([l for l in st.splitlines() if l.strip()])
        print(f"      工作区相对上游未跟踪/改动条目: {n_change}")
        if n_change > 0:
            # 用一次 diff 统计与上游的差异（--no-index 不适用，改用 add 后 diff --cached HEAD）
            rc2, dstat, _ = run(["git", "diff", "--cached", "--stat", f"origin/{up}"], d)
            tail = dstat.splitlines()[-1] if dstat else "(无)"
            print(f"      与 origin/{up} 的差异: {tail[:120]}")
        # 安全对齐：把工作区内容设为上游版本（git 无历史，只能以文件为准）
        run(["git", "reset", "-q", "--mixed"], d)          # 先取消暂存，避免污染索引
        rc3, _, err3 = run(["git", "checkout", "-q", "-f", f"origin/{up}", "--", "."], d)
        # checkout -- . 只能取已跟踪文件；改用 read-tree + checkout-index 全量覆盖
        rc4, _, err4 = run(["git", "read-tree", "-m", "-u", f"origin/{up}"], d)
        run(["git", "reset", "-q", "--mixed", f"origin/{up}"], d)
        if rc4 == 0:
            print(f"      ✓ 工作区已对齐到上游 {up}@{up_sha}")
            results.append((name, "OK", f"接入 git 并对齐到 {up}@{up_sha}"))
        else:
            print(f"      ✗ 对齐失败: {err4[:160]}")
            results.append((name, "FAIL", f"对齐: {err4[:80]}"))
        continue

    # 已是 git：检查本地状态
    rc, st, _ = run(["git", "status", "--porcelain"], d)
    dirty = len([l for l in st.splitlines() if l.strip()])
    cur = branch_of(d)
    rc, head, _ = run(["git", "rev-parse", "--short", "HEAD"], d)
    rc, base, _ = run(["git", "merge-base", "HEAD", f"origin/{up}"], d)
    rc, upfull, _ = run(["git", "rev-parse", f"origin/{up}"], d)
    can_ff = (base == upfull)

    print(f"      当前 {cur}@{head}  上游 {up}@{up_sha}  本地改动 {dirty} 条  可快进={can_ff}")
    if dirty:
        print("      ⚠ 有本地改动，只 fetch 不覆盖（避免丢失你的改动）")
        results.append((name, "PARTIAL", f"已 fetch 到 {up}@{up_sha}，本地有 {dirty} 条改动未覆盖"))
        continue
    if head == up_sha:
        print("      ✓ 已是最新")
        results.append((name, "OK", f"已是最新 {up}@{up_sha}"))
        continue
    if can_ff:
        rc, out, err = run(["git", "merge", "--ff-only", f"origin/{up}"], d)
        if rc == 0:
            print(f"      ✓ 快进到 {up}@{up_sha}")
            results.append((name, "OK", f"快进到 {up}@{up_sha}"))
        else:
            print(f"      ✗ 快进失败: {err[:160]}")
            results.append((name, "FAIL", f"merge: {err[:80]}"))
    else:
        rc, out, err = run(["git", "rebase", f"origin/{up}"], d)
        if rc == 0:
            print(f"      ✓ rebase 到 {up}@{up_sha}")
            results.append((name, "OK", f"rebase 到 {up}@{up_sha}"))
        else:
            run(["git", "rebase", "--abort"], d)
            print(f"      ✗ 分叉且 rebase 失败，已回滚: {err[:160]}")
            results.append((name, "PARTIAL", f"分叉，已 fetch 到 {up}@{up_sha}，未合并"))

print(f"\n\n{'='*76}\n汇总\n{'='*76}")
for name, status, note in results:
    print(f"  [{status:8s}] {name:24s} {note}")
