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
    procd_set_param env FARM_PORT=8080 FARM_TOKEN=改成你的令牌
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
