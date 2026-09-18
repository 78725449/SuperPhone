"""插件面板 iframe 完整链路验证（一次性走完，不再逐段"通过"就报）

覆盖 iframe 在真实浏览器里会发出的【每一类】请求：
  顶层导航（iframe） / 静态资源（script×5, style） / API（fetch×7） / WebSocket×2
外加对照组：用户手输 http://IP:8080（顶层导航 document）应仍 301 到 https。

用 Sec-Fetch-Dest 模拟真实浏览器的请求目的标注 —— 这是本次修复的核心判据。
"""
import urllib.request, urllib.error, socket, base64, os, ssl, json, sys

DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
BASE = "http://127.0.0.1:8080"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(NoRedirect)


def http_probe(path, dest, method="GET", accept=None, body=None):
    """按 Sec-Fetch-Dest 模拟一类请求。

    判定标准是【未被 301 跳转】—— 而不是"必须 200"：
    API 收到不合法的 body 会返回 400/422，那同样证明请求【到达了真正的 handler】，
    属于本次修复要达成的效果（此前它们会被 301 到 https 并被浏览器按跨源拦掉）。
    """
    headers = {"Sec-Fetch-Dest": dest}
    if accept:
        headers["Accept"] = accept
    req = urllib.request.Request(BASE + path, headers=headers, method=method)
    if method == "POST":
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(body if body is not None else {}).encode()
    try:
        with opener.open(req, timeout=10) as r:
            return True, f"HTTP {r.status}"
    except urllib.error.HTTPError as e:
        loc = e.headers.get("Location", "")
        if e.code in (301, 302, 307, 308) and loc:
            return False, f"★ 被跳转 HTTP {e.code} → {loc[:40]}"
        # 其他错误码（400/404/422…）说明请求已到达 handler，正是我们要的
        return True, f"HTTP {e.code}（已到达 handler，未跳转）"
    except Exception as e:
        return False, f"{type(e).__name__}: {str(e)[:44]}"


def ws_probe(path, tls=False):
    try:
        s = socket.create_connection(("127.0.0.1", 8080), timeout=10)
        if tls:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            s = ctx.wrap_socket(s, server_hostname="127.0.0.1")
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall((
            f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode())
        line = s.recv(512).decode("utf-8", "replace").split("\r\n")[0].strip()
        s.close()
        return "101" in line, line
    except Exception as e:
        return False, f"{type(e).__name__}: {str(e)[:44]}"


# ── 完整链路清单 ──────────────────────────────────────────────
# ★ 维护纪律：本清单必须覆盖 iframe 最终会请求的【每一个 URL】。
#   历史教训（2026-09-18）：修了 caps.js/press.js/gesture.js 三个被浏览器永久缓存 301 的文件，
#   却漏了 app.js 第 3 行的 /novnc/core/rfb.js?v=4 —— 用户重启后错误只是"换了文件名"继续报。
#   故 app.js 的全部 import 都在此列出；改 app.js 的 import 或版本号后，同步改这里。
CHAIN = [
    ("① iframe 顶层导航",      f"/?syscursor=1&pv=3&only={DEV}", "iframe", "GET"),
    ("② 样式表",                "/style.css?v=53",                "style",  "GET"),
    ("③ 主脚本",                "/app.js?v=229",                  "script", "GET"),
    ("④ noVNC 核心(server patch)", "/novnc/core/rfb.js?v=5",       "script", "GET"),
    ("⑤ 能力脚本",              "/caps.js?v=16",                  "script", "GET"),
    ("⑥ 按键脚本",              "/press.js?v=1",                  "script", "GET"),
    ("⑦ 手势脚本",              "/gesture.js?v=1",                "script", "GET"),
    ("⑧ 设备列表 API",          "/api/devices",                   "empty",  "GET"),
    ("⑨ 缩略图 API",            f"/api/devices/{DEV}/thumb",      "empty",  "GET"),
    ("⑩ 能力配置 API",          f"/api/devices/{DEV}/configs",    "empty",  "GET"),
    ("⑪ 能力调用 API",          f"/api/devices/{DEV}/invoke",     "empty",  "POST"),
    ("⑫ 批量调用 API",          "/api/devices/batch/invoke",      "empty",  "POST"),
    ("⑬ ping API",              f"/api/devices/{DEV}/ping",       "empty",  "POST"),
    ("⑭ 断开 API",              f"/api/devices/{DEV}/disconnect", "empty",  "POST"),
    # 旧 URL（浏览器缓存过 301 的那些）—— 服务端也必须已修好，否则将来换回旧地址仍会炸
    ("⑮ 旧URL caps.js?v=15",    "/caps.js?v=15",                  "script", "GET"),
    ("⑯ 旧URL press.js",        "/press.js",                      "script", "GET"),
    ("⑰ 旧URL gesture.js",      "/gesture.js",                    "script", "GET"),
    ("⑱ 旧URL rfb.js?v=4",      "/novnc/core/rfb.js?v=4",         "script", "GET"),
]
CONTROL = [
    ("★ 对照：用户手输 http://IP:8080（顶层导航）", "/", "document", "GET"),
    ("★ 对照：用户手输 /index.html",                "/index.html", "document", "GET"),
]

print("=" * 78)
print("iframe 完整链路（全部必须「未跳转」）")
print("=" * 78)
fails = []
for label, path, dest, method in CHAIN:
    ok, detail = http_probe(path, dest, method)
    mark = "OK  " if ok else "FAIL"
    if not ok:
        fails.append(label)
    print(f"  [{mark}] {label:22s} {dest:8s} {method:5s} → {detail}")

print()
print("=" * 78)
print("WebSocket（画面 / 事件通道）")
print("=" * 78)
for label, path, tls in [
    ("ws  事件通道", "/ws/events", False),
    ("ws  画面通道", f"/ws/vnc/{DEV}", False),
    ("wss 对照（原有路径不应被破坏）", "/ws/events", True),
]:
    ok, detail = ws_probe(path, tls)
    mark = "OK  " if ok else "FAIL"
    if not ok:
        fails.append(label)
    print(f"  [{mark}] {label:30s} → {detail}")

print()
print("=" * 78)
print("对照组：顶层导航必须仍然是 301 到 https（原设计保留）")
print("=" * 78)
for label, path, dest, method in CONTROL:
    ok, detail = http_probe(path, dest, method)
    # 对照组期望的是"被跳转"——即 http_probe 返回 ok=False 且描述里是 301
    is_301 = (not ok) and "301" in detail and "https://" in detail
    mark = "OK  " if is_301 else "FAIL"
    if not is_301:
        fails.append(label)
    print(f"  [{mark}] {label:44s} → {detail}")

print()
print("=" * 78)
print(f"结果：{'★ 全部通过' if not fails else '✗ 失败项: ' + ', '.join(fails)}")
print("=" * 78)
sys.exit(1 if fails else 0)
