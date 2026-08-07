# 内网穿透配置

## 方案一：frp（推荐，需要一台公网 VPS）

1. **VPS 上**运行 frps：`frps -c frps.toml`
2. **软路由上**运行 frpc：`frpc -c frpc.toml`
3. 外部访问：`http://你的VPS公网IP:8080/?token=你的FARM_TOKEN`

> frp 各版本下载：https://github.com/fatedier/frp/releases
> OpenWrt 可直接 `opkg install frpc`（配置文件放 /etc/frp/frpc.toml，`/etc/init.d/frpc enable && start`）

## 方案二：Tailscale / ZeroTier（无需公网 VPS）

给软路由装 Tailscale（`opkg install tailscale` 或容器），手机/电脑也装同一个 Tailscale 网络，
直接用软路由的 Tailscale IP + 8080 访问。走 WireGuard，链路加密，无需端口转发。

## 方案三：Cloudflare Tunnel（需要域名）

在软路由上跑 cloudflared，把本地 8080 映射到公网域名，自带 TLS 与访问策略。

## 注意

- **注册/心跳端口（18081）不需要也不建议穿透到公网**：本方案面向内网自用，手机在局域网内注册；
  外部访问只暴露网页管理端（8080），设备控制在隧道内由网关转发。

## 安全建议（对外网暴露时）

- 一定设置 `FARM_TOKEN`，并且用 HTTPS（frp + Caddy/Nginx 反代，或 Cloudflare Tunnel 自带 TLS）
- 公网不要裸奔 5901 等 VNC 端口；手机只允许通过群控台访问
- 建议在网关前再加一层访问控制（如 Authelia / Cloudflare Access）
