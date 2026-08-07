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

- 手机开启 TrollVNC（设置里 Bonjour 保持开启），稍等几秒，网页端应自动出现设备
- 也可手动「+ 添加设备」填手机 IP 和 5901
- 点「查看」→ 输入手机 VNC 密码 → 看到并控制手机屏幕
- 点「墙屏」→ 同时看多台；点「群控」→ 操作主屏广播到其它墙屏

## 7. 内网穿透

见 `frp/` 目录：frps 放公网 VPS，frpc 装软路由（`opkg install frpc` 或 Docker 跑 frpc）。

## 注意事项

- 必须用 **host 网络模式**（compose 里已设置），否则容器内 mDNS 发现和访问局域网手机都会失效。
- data/ 目录保存设备列表，升级容器不丢数据。
- 首次启动会做 TCP 探测，设备状态（在线/离线）每 15 秒刷新一次。
