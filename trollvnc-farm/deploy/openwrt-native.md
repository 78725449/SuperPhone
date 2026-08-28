# 软路由（OpenWrt）部署指南 —— 无 Docker 方式（Entware + Node）

适合不支持 Docker 的软路由（如老 ARM 机型），用 Entware 跑 Node 服务。

## 1. 安装 Entware 与 Node

```sh
# 安装 Entware（若未安装）
opkg update
opkg install entware
# Entware 环境初始化后：
/opt/bin/opkg update
/opt/bin/opkg install node
```

## 2. 拷贝项目并安装依赖

```sh
scp -r trollvnc-farm root@192.168.1.1:/opt/trollvnc-farm
ssh root@192.168.1.1
cd /opt/trollvnc-farm
/opt/bin/npm ci --omit=dev
```

## 3. 配置环境变量

```sh
export FARM_PORT=8080
export FARM_TOKEN=改成你的令牌
export FARM_MDNS=0   # 生产建议：关闭网关 mDNS 广播/发现（见下方「局域网暴露收敛」）
```

## 4. 注册为开机服务（procd）

新建 `/etc/init.d/trollvnc-farm`：

```sh
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /opt/bin/node /opt/trollvnc-farm/server/index.js
    procd_set_param env FARM_PORT=8080 FARM_TOKEN=改成你的令牌 FARM_MDNS=0
    procd_set_param respawn
    procd_close_instance
}
```

```sh
chmod +x /etc/init.d/trollvnc-farm
/etc/init.d/trollvnc-farm enable
/etc/init.d/trollvnc-farm start
```

## 5. frpc（内网穿透）

```sh
opkg install frpc
# 配置文件 /etc/frp/frpc.toml，见 frp/frpc.toml
/etc/init.d/frpc enable && /etc/init.d/frpc start
```

## 6. 局域网暴露收敛（风控纪律，2026-08-28）

抖音类 App 会 browse Bonjour/Multipeer 枚举局域网服务（逆向报告 §4 实证）。mDNS 的 publish 即广播——不主动发布才不可见。农场生产环境执行：

1. **网关**：启动加环境变量 `FARM_MDNS=0`（上文 procd env 已含）——同时关闭网关自身的 `_superphone-farm._tcp` 广播与 `_rfb._tcp` 遗留发现。设备经 18081 主动注册，不依赖 mDNS。
2. **设备端**：`BonjourEnabled` 默认已关闭（2026-08-28 起 mDNS 不发布 `_rfb._tcp`/`_http._tcp`），保持关闭；仅确需 VNC 客户端局域网自动发现时用 CLI `-B on` 或配置显式开启，用完即关。
3. **初始化纪律**：网关/设备都不广播后，App 首次初始化**手动填网关地址**（搜索网关功能依赖网关广播，收敛后不可用）。
4. **存量设备**：若曾显式开启过 Bonjour（配置已持久化 YES），经网关批量配置 `BonjourEnabled=false` 并重启服务收敛。

收口状态：局域网内 `_rfb._tcp`/`_http._tcp`/`_superphone-farm._tcp` 三个服务类型均不可见，设备仅经 18081/18181 出向连接网关。
