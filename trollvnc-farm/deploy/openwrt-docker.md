# 软路由（OpenWrt）部署指南 —— Docker 方式

适合 x86_64 / ARM64 软路由，前提是路由器能跑 Docker。

## 1. 安装 Docker（OpenWrt）

```sh
opkg update
opkg install docker dockerd luci-app-docker
service dockerd start
service dockerd enable
```

> 某些固件（如 ImmortalWrt / 带 Entware 的固件）路径不同：
> ```sh
# Entware 方式
opkg update && opkg install docker dockerd luci-app-docker
# 或先装 entware：opkg install entware
```

## 2. 拷贝项目到软路由

```sh
scp -r trollvnc-farm root@192.168.1.1:/root/
ssh root@192.168.1.1
cd /root/trollvnc-farm
```

## 3. 修改配置

编辑 `docker-compose.yml`，把 `FARM_TOKEN` 改成你自己的访问令牌（必须改）。

生产环境建议同时加环境变量 `FARM_MDNS=0`（见下方「局域网暴露收敛」；设备经 18081 主动注册，不依赖网关 mDNS）。

## 4. 构建并启动

```sh
docker compose up -d --build
```

> 软路由 CPU 较弱时构建较慢，也可以在电脑上构建好再导入：
> ```sh
docker build -t trollvnc-farm:latest .
docker save trollvnc-farm:latest | gzip > farm.tar.gz   # 传到路由后：
docker load < farm.tar.gz
docker compose up -d
```

## 5. 防火墙

OpenWrt 防火墙默认放行 LAN→路由器，8080 在 LAN 内可直接访问：
`http://192.168.1.1:8080`（或 `http://软路由IP:8080`）。

如果需要放行，在 LuCI → 网络 → 防火墙 → 通信规则 增加：
- 允许从 lan 到 本机(router) 的 TCP 8080

## 6. 验证

- 手机 App 连接页填入网关地址（首次初始化；生产 `FARM_MDNS=0` 时网关不广播，无法自动搜索）并连接，稍等几秒，网页端应自动出现设备（注册通道 18081）
- 点「查看」→ 输入手机 VNC 密码 → 看到并控制手机屏幕
- 点「墙屏」→ 同时看多台；点「群控」→ 操作主屏广播到其它墙屏

## 7. 内网穿透

见 `frp/` 目录：frps 放公网 VPS，frpc 装软路由（`opkg install frpc` 或 Docker 跑 frpc）。

## 注意事项

- 必须用 **host 网络模式**（compose 里已设置），否则容器内 mDNS 发现和访问局域网手机都会失效。
- data/ 目录保存设备列表，升级容器不丢数据。
- 首次启动会做 TCP 探测，设备状态（在线/离线）每 15 秒刷新一次。

## 局域网暴露收敛（风控纪律，2026-08-28）

抖音类 App 会 browse Bonjour/Multipeer 枚举局域网服务（逆向报告 §4 实证）。mDNS 的 publish 即广播——不主动发布才不可见。农场生产环境执行：

1. **网关**：启动加环境变量 `FARM_MDNS=0`（docker-compose.yml environment 或 procd env）——同时关闭网关自身的 `_superphone-farm._tcp` 广播与 `_rfb._tcp` 遗留发现。设备经 18081 主动注册，不依赖 mDNS。
2. **设备端**：`BonjourEnabled` 默认已关闭（2026-08-28 起 mDNS 不发布 `_rfb._tcp`/`_http._tcp`），保持关闭；仅确需 VNC 客户端局域网自动发现时用 CLI `-B on` 或配置显式开启，用完即关。
3. **初始化纪律**：网关/设备都不广播后，App 首次初始化**手动填网关地址**（搜索网关功能依赖网关广播，收敛后不可用）。
4. **存量设备**：若曾显式开启过 Bonjour（配置已持久化 YES），经网关批量配置 `BonjourEnabled=false` 并重启服务收敛。

收口状态：局域网内 `_rfb._tcp`/`_http._tcp`/`_superphone-farm._tcp` 三个服务类型均不可见，设备仅经 18081/18181 出向连接网关。
