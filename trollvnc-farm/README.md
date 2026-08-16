# superphone-farm

SuperPhone 群控网关（Node.js）：软路由部署，集中管理内网运行 SuperPhone 的 iOS 设备，提供 REST API + WebSocket\u2192VNC 桥接 + mDNS 发现 + 群控广播 + 网页管理。

## 快速开始

```sh
npm install
FARM_TOKEN=test123 npm start
```

默认端口：控制台 8080、TCP 注册 18081、VNC 桥 18181。

详见项目根目录《项目知识库.md》（架构/时序/实现/规则）。
