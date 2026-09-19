r"""资产树的【唯一读写入口】—— 产生资产的地方也在这里统一。

★★ 为什么需要它（用户 2026-09-21 指出"产生资产的地方是不是也要调整"）：
   此前资产是【各写各的】✗：engine 首跑手写 data/engine-trial/meta.json、
   build-page-assets.py 写 data/page-assets/（平铺）、格式互不相同 →
   资产形态一变就要改 N 个脚本 ✗。
   ⇒ 统一为：所有读写都走本脚本 → 格式只在【一处】定义 ✓

★ 读（四级阶梯，对应 assets/README.md §三）：
   which <bundleId> <version> <page>   精确命中
   find  <bundleId> --band bot=4,mid=12 --anchors 首页,我    结构+内容锚查表（供引擎判页）
★ 写（只增不删；pits 只追加）：
   bump     <bundleId> <version> <page> <actionId>      验证成功后 runCount+1
   add-pit  <bundleId> <version> <page> --text "..."    追加负样本
   upsert-action ... --json '{...}'                     新做法入册 / 合并已有
   new-page <bundleId> <version> <page> --json '{...}'  新页面（含首次采集）
★ 枚举：
   list [bundleId]                                       已知 App / 版本 / 页面

★ 纪律：写入前先备份到 data/backups/；pits 只追加；不物理删任何资产（用 status: deprecated）
"""
import argparse
import json
import os
import shutil
import sys
import time

ROOT = r"D:\编程项目\SuperPhone"
ASSETS = os.path.join(ROOT, "skills", "superphone-device", "assets")
BACKUP = os.path.join(ROOT, "data", "backups")


def jload(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def jsave(p, d):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    os.replace(tmp, p)          # 原子替换（防写一半）


def backup(p):
    if not os.path.exists(p):
        return
    d = os.path.join(BACKUP, "asset-%s-%s" % (os.path.basename(p)[:24], time.strftime("%Y%m%d-%H%M%S")))
    os.makedirs(d, exist_ok=True)
    shutil.copy2(p, d)


def app_dir(bid):
    return os.path.join(ASSETS, bid)


def page_path(bid, ver, page):
    return os.path.join(app_dir(bid), ver, "%s.json" % page)


def cmd_list(a):
    if not os.path.isdir(ASSETS):
        print("（资产库不存在）")
        return
    for bid in sorted(os.listdir(ASSETS)):
        ap = os.path.join(ASSETS, bid)
        if not os.path.isdir(ap) or bid.startswith("_"):
            continue
        meta = jload(os.path.join(ap, "_app.json")) if os.path.exists(os.path.join(ap, "_app.json")) else {}
        vers = [v for v in sorted(os.listdir(ap)) if os.path.isdir(os.path.join(ap, v))]
        print("  %-30s %-12s versions=%s" % (bid, meta.get("name", "?"), vers))
        for v in vers:
            pages = [f[:-5] for f in sorted(os.listdir(os.path.join(ap, v)))
                     if f.endswith(".json") and not f.startswith("_")]
            vj = os.path.join(ap, v, "_version.json")
            st = jload(vj).get("status", "?") if os.path.exists(vj) else "?"
            print("       %-10s [%-9s] pages=%s" % (v, st, pages))


def cmd_which(a):
    """★ 读：精确命中（四级阶梯的第①级）"""
    p = page_path(a.bundleId, a.version, a.page)
    if not os.path.exists(p):
        print(json.dumps({"hit": False, "reason": "no-such-page",
                          "tried": os.path.relpath(p, ROOT)}, ensure_ascii=False))
        return
    d = jload(p)
    print(json.dumps({"hit": True, "path": os.path.relpath(p, ROOT),
                      "structureSignature": d.get("structureSignature"),
                      "contentAnchors": d.get("contentAnchors"),
                      "actions": [{"id": x.get("id"), "intent": x.get("intent"),
                                   "targetPage": x.get("targetPage"),
                                   "runCount": x.get("runCount")} for x in d.get("actions", [])],
                      "pits": len(d.get("pits", []))}, ensure_ascii=False, indent=1))


def cmd_find(a):
    """★ 读：按【结构带 + 内容锚】查表（供引擎判页；四级阶梯的②③级在此合并）
    用法：find <bundleId> --bot 4 --mid 12 --anchors 首页,我 [--version 39.9.0]
    """
    bid = a.bundleId
    ap = app_dir(bid)
    cands = []
    for ver in sorted(os.listdir(ap)) if os.path.isdir(ap) else []:
        vd = os.path.join(ap, ver)
        if not os.path.isdir(vd):
            continue
        if a.version and ver != a.version:
            continue
        for f in sorted(os.listdir(vd)):
            if not f.endswith(".json") or f.startswith("_"):
                continue
            d = jload(os.path.join(vd, f))
            ss = d.get("structureSignature", {}).get("assert", {})
            anchors = d.get("contentAnchors", [])
            score = 0.0
            # 结构带判分（宽松：只看能否满足）
            for k, v in ss.items():
                if v is None:
                    continue
                s = str(v)
                have = {"bot": a.bot, "mid": a.mid, "top": a.top}.get(k)
                if have is None:
                    continue
                try:
                    n = int(str(v).lstrip("><="))
                except Exception:
                    continue
                if s.startswith(">=") and have >= n:
                    score += 1
                elif s.startswith("<=") and have <= n:
                    score += 1
                elif s.isdigit() and have == n:
                    score += 1
            # 内容锚判分（权重更高：它是"唯一判页"的依据）
            hit_anchors = [x for x in anchors if x in (a.anchors or "")]
            score += 2.0 * len(hit_anchors)
            cands.append({"page": d.get("page"), "version": ver, "score": score,
                          "anchorsHit": hit_anchors, "anchorsTotal": len(anchors),
                          "path": os.path.relpath(os.path.join(vd, f), ROOT)})
    cands.sort(key=lambda x: -x["score"])
    best = cands[0] if cands else None
    out = {"band": {"bot": a.bot, "mid": a.mid, "top": a.top},
           "anchors": a.anchors,
           "candidates": cands[:5],
           "verdict": ("命中 " + best["page"]) if (best and best["score"] >= 2) else
                      ("★ 不确定（分数 %s）→ 必须看图裁决" % (best["score"] if best else 0))}
    print(json.dumps(out, ensure_ascii=False, indent=1))


def _modify(a, page_key=None):
    p = page_path(a.bundleId, a.version, page_key or a.page)
    if not os.path.exists(p):
        print(json.dumps({"ok": False, "error": "页面资产不存在: " + os.path.relpath(p, ROOT)},
                         ensure_ascii=False))
        sys.exit(2)
    backup(p)
    return p, jload(p)


def cmd_bump(a):
    """★ 写：验证成功后 runCount + 1（飞轮的核心计数）"""
    p, d = _modify(a)
    for x in d.get("actions", []):
        if x.get("id") == a.actionId:
            x["runCount"] = int(x.get("runCount", 0)) + 1
            x["lastVerifiedAt"] = time.strftime("%Y-%m-%d %H:%M")
            jsave(p, d)
            print(json.dumps({"ok": True, "action": a.actionId, "runCount": x["runCount"],
                              "path": os.path.relpath(p, ROOT)}, ensure_ascii=False))
            return
    print(json.dumps({"ok": False, "error": "无此 action id: " + a.actionId}, ensure_ascii=False))
    sys.exit(2)


def cmd_add_pit(a):
    """★ 写：追加负样本（只追加不替换）"""
    p, d = _modify(a)
    pits = d.setdefault("pits", [])
    if a.text in pits:
        print(json.dumps({"ok": True, "note": "已存在，未重复追加", "pits": len(pits)}, ensure_ascii=False))
        return
    pits.append(a.text)
    jsave(p, d)
    print(json.dumps({"ok": True, "added": a.text, "pits": len(pits),
                      "path": os.path.relpath(p, ROOT)}, ensure_ascii=False))


def cmd_upsert_action(a):
    """★ 写：新做法入册；同 id 已存在则【合并】（保留旧 evidence，runCount 累加）"""
    p, d = _modify(a)
    act = json.loads(a.json)
    if "id" not in act:
        print(json.dumps({"ok": False, "error": "action 必须带 id"}, ensure_ascii=False))
        sys.exit(2)
    acts = d.setdefault("actions", [])
    for i, x in enumerate(acts):
        if x.get("id") == act["id"]:
            merged = dict(x)
            merged.update({k: v for k, v in act.items() if k != "runCount"})
            merged["runCount"] = int(x.get("runCount", 0)) + int(act.get("runCount", 0))
            acts[i] = merged
            jsave(p, d)
            print(json.dumps({"ok": True, "merged": act["id"], "runCount": merged["runCount"]},
                             ensure_ascii=False))
            return
    acts.append(act)
    jsave(p, d)
    print(json.dumps({"ok": True, "added": act["id"], "actions": len(acts),
                      "path": os.path.relpath(p, ROOT)}, ensure_ascii=False))


def cmd_new_page(a):
    """★ 写：新页面（含首次采集产物）—— 路径不存在则建（含版本目录）"""
    p = page_path(a.bundleId, a.version, a.page)
    if os.path.exists(p):
        print(json.dumps({"ok": False, "error": "已存在，请用 upsert-action 增量更新: "
                          + os.path.relpath(p, ROOT)}, ensure_ascii=False))
        sys.exit(2)
    d = json.loads(a.json)
    jsave(p, d)
    # 同步 _version.json 的 pages 列表
    vj = os.path.join(app_dir(a.bundleId), a.version, "_version.json")
    if os.path.exists(vj):
        vd = jload(vj)
        pages = vd.setdefault("pages", [])
        if a.page not in pages:
            pages.append(a.page)
            jsave(vj, vd)
    print(json.dumps({"ok": True, "created": os.path.relpath(p, ROOT)}, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser(description="资产树唯一读写入口")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("list"); s.add_argument("bundleId", nargs="?"); s.set_defaults(fn=cmd_list)

    s = sub.add_parser("which")
    s.add_argument("bundleId"); s.add_argument("version"); s.add_argument("page")
    s.set_defaults(fn=cmd_which)

    s = sub.add_parser("find")
    s.add_argument("bundleId")
    s.add_argument("--version"); s.add_argument("--bot", type=int); s.add_argument("--mid", type=int)
    s.add_argument("--top", type=int); s.add_argument("--anchors", default="")
    s.set_defaults(fn=cmd_find)

    s = sub.add_parser("bump")
    s.add_argument("bundleId"); s.add_argument("version"); s.add_argument("page"); s.add_argument("actionId")
    s.set_defaults(fn=cmd_bump)

    s = sub.add_parser("add-pit")
    s.add_argument("bundleId"); s.add_argument("version"); s.add_argument("page")
    s.add_argument("--text", required=True)
    s.set_defaults(fn=cmd_add_pit)

    s = sub.add_parser("upsert-action")
    s.add_argument("bundleId"); s.add_argument("version"); s.add_argument("page")
    s.add_argument("--json", required=True)
    s.set_defaults(fn=cmd_upsert_action)

    s = sub.add_parser("new-page")
    s.add_argument("bundleId"); s.add_argument("version"); s.add_argument("page")
    s.add_argument("--json", required=True)
    s.set_defaults(fn=cmd_new_page)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
