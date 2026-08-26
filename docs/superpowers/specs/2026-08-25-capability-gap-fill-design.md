# 能力缺口补齐设计（5802 sim.itinerary + 注册表 data.read）

日期：2026-08-25
状态：已确认（用户拍板）
关联愿景：局域网网关管理所有设备（A）/ 外网访问网关操作内网设备（B）/ 5801 不经过网关独立操作单台设备（C）

## 背景

对照愿景 A/B/C 审计能力集，发现两个**对称缺口**：

| 缺口 | 通道 | 缺失能力 | 影响 |
|---|---|---|---|
| 1 | 5802/0x50（局域网直连）| `sim.itinerary` 定位编排 | 5801 直连页做不了定位编排（愿景 C 不完整）|
| 2 | 注册表 invoke（跨网/网关）| `data.read` 读库 | 外网/网关管理无法读设备数据（愿景 B 不完整）|

用户确认：定位编排与数据生成/清空是**网关和 5801 两端都需具备**的能力，补齐两缺口。

## 设计

### 改动 1：data.read 逻辑提取共享（TRDataFiller）

现 `tvExtHandleDataRead`（trollvncserver.mm L4108-4163）含路径表/白名单/行查询（依赖 trollvncserver 的 `tvDbQueryRows`）。提取为 TRDataFiller 类方法（manager 与 trollvncserver 共享）：

```objc
+ (NSDictionary *)readDatabase:(NSString *)dbName table:(NSString *)table limit:(NSInteger)limit;
```

- 移植：kDBPaths（calls/sms/contacts）+ 白名单表（ZCALLRECORD/ZHANDLE/Z_PRIMARYKEY / message/chat/handle/chat_message_join/chat_handle_join / ABPerson/ABMultiValue/ABStore）+ `SELECT * FROM %@ ORDER BY ROWID DESC LIMIT %ld` 行查询（含 sqlite 行转 NSDictionary，移植自 tvDbQueryRows）
- limit 钳制 1~50（不变）
- 返回 `{db,count,rows,error?}`（结构不变）
- **行为不变**：trollvncserver `tvExtHandleDataRead` 改为薄封装调共享方法（5802/0x50 外部无感）

### 改动 2：注册表补 data.read（TRCapabilityRegistry）

```objc
[self _registerControl:@"data.read" title:@"读取数据" icon:@"📖" route:TRCapRouteNative
    params:@[@{@"name":@"db",@"type":@"string",@"required":@YES},
             @{@"name":@"table",@"type":@"string",@"required":@NO},
             @{@"name":@"limit",@"type":@"number",@"required":@NO}]
    executor:^NSDictionary *(NSDictionary *p, NSError **e) {
        NSString *db = p[@"db"];
        if (![db isKindOfClass:[NSString class]]) { 错误; }
        return [TRDataFiller readDatabase:db table:p[@"table"] limit:[p[@"limit"] integerValue]];
    }];
```

### 改动 3：5802 + 0x50 补 sim.itinerary（trollvncserver）

与注册表 executor（L786-804）同逻辑，复用 `SimItineraryPlanner submitItinerary`（异步算路，立即返回 calculating）：

```objc
// tvHttpApiDispatch 与 tvExtHandleMessage 各加：
else if ([op isEqualToString:@"sim.itinerary"]) {
    NSArray *segs = params[@"segments"];
    if (![segs isKindOfClass:[NSArray class]] || segs.count == 0)
        return tvExtErr(@"sim.itinerary 缺少参数 segments");
    [SimItineraryPlanner submitItinerary:segs completion:^(NSDictionary *result, NSError *err) {
        TVLog(@"[locsim] itinerary %@", err ? err.localizedDescription : @"done");
    }];
    return tvExtOk(@{@"status": @"calculating"});
}
```

- 三处补齐纪律：注册表（已有）+ 0x50 + 5802 全补，handler 纯函数化（cl 传 NULL 复用）
- 依赖：trollvncserver 需 `#import "SimItineraryPlanner.h"`（编译期检查 bootstrap SDK 同 MKGeometry 教训）

### 改动 4：caps.js 契约（本次不增）

前端按钮 UI 属后续阶段（用户明确"补好以后再来设计 UI"）——**本次不改 caps.js/BATCH_CAPS 计数**；注册表新增 data.read 不强制前端暴露（能力可用、前端未接）。5801 分叉 caps.js 同样不动。

## 边界与安全

- 白名单表不变（data.read 只读固定表，无任意文件访问）
- limit 上限 50 不变
- sim.itinerary 异步（invoke/5802 立即 ack calculating，与注册表行为一致）
- 不做：caps.js 按钮、网关 web 前端、5801 直连页 UI（均后续阶段）

## 验证

1. CI 编译（4 scheme，bootstrap 验证 App target）
2. 真机：网关 invoke `data.read`（跨网读库）；5802 `sim.itinerary`（5801 直连页可调）
3. 回归：5802/0x50 data.read 行为不变（同返回结构）
