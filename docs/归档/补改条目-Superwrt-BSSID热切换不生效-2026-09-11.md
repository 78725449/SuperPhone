# Superwrt 软路由整改条目：BSSID 热切换不生效（2026-09-11 真机实证）

> 状态：**待用户审阅**。属于 Superwrt 项目（D:\编程项目\Superwrt\），非 SuperPhone 仓库改动。
> 证据来源：2026-09-11 真机故障——SuperPhone daemon 下发 BSSID 切换后设备 wifi 断开、无法加入。

---

## 一、故障现象（2026-09-11 实证）

1. SuperPhone 设锚点 → daemon 反查获取目标 AP BSSID → POST wifi-switch.cgi（`current_ssid=时来运转, target.bssid=DC:08:56:17:AD:61`）
2. `wifi-switch.log` 显示 `DONE: mac=DC:08:56:17:AD:61 (ssid unchanged)`——uci 写入成功
3. **但运行时接口 MAC 未变**（`iw dev phy1-ap0 info` → addr 仍为旧值 `20:58:69:6a:00:9c`）
4. hostapd 持续报 `handle_probe_req: send failed` → 设备能看到 SSID 却永远关联失败 → iOS「无法加入网络」，忘记重输密码也失败
5. 手动 `wifi down radio1 && wifi up radio1` 后恢复正常（接口重建、新 MAC 生效、probe 恢复）

## 二、根因

**hostapd 单进程全局模式（`hostapd -s -g /var/run/hostapd/global`）下，BSSID 是启动参数，不支持热改：**

- `wifi reload` 只向 hostapd 发送 UPDATE（配置更新）命令，**不接受 bssid 变更**——配置层（`/var/run/hostapd-phy1.conf` 已含新 bssid）与运行时接口状态不一致
- hostapd 以「配置 bssid ≠ 接口实际 MAC」的病态运行 → probe response 发送失败 → 客户端无法关联
- OpenWrt `wifi reload` 对 macaddr 变更的既有限制（reload 不重建已存在接口；重建需要 down/up）

## 三、整改方向（待审批，方案先行）

### 方案 A（推荐，最小改动）：wifi-switch.cgi 改强制重建

```bash
# 原（不生效）
uci set wireless.default_radio1.macaddr='XX:XX:XX:XX:XX:XX'
uci commit wireless
wifi reload          # 仅 UPDATE，bssid 不生效

# 改（强制重建）
uci set wireless.default_radio1.macaddr='XX:XX:XX:XX:XX:XX'
uci commit wireless
wifi down radio1 && wifi up radio1   # 重建接口，bssid 生效
```

代价：radio1 下所有虚拟 AP（CL1xx 共 30 个）短暂中断（~2s），期间该 radio 客户端全断→重连。可接受（当前切换本就伴随短暂断网）。

### 方案 B（长远）：研究 hostapd 多 BSS 热切 bssid

- hostapd 对启用中 BSS 修改 bssid 不支持（启动参数）；社区做法 = `hostapd_cli` 无热切接口，需接口级重建
- 或评估 `wifi reload` 前先 `ip link set phy1-ap0 down`（可能触发 netifd 重建）
- 结论：方案 A 已满足需求，B 留作调查项，不做预判式设计

### 附加观察（本次故障同步发现）

- `handle_probe_req: send failed` 是「bssid 配置与接口不一致」的特征日志——今后 wps-switch 后设备无法加入，先查 `iw dev phy1-ap0 info` 的 addr 是否等于预期 target
- 切换期间设备 DHCP 会重新分配 IP（本次 .242 依赖不变，若需固定可加 DHCP 静态绑定）

## 四、验收

1. wps-switch 下发后 `iw dev phy1-ap0 info` → addr = target bssid（非旧值）
2. `logread | grep handle_probe_req` 无新增失败
3. 设备 5s 内无感漫游回「时来运转」（同 SSID 无需重输密码）