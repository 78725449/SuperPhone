# 能力缺口补齐实现计划（5802 sim.itinerary + 注册表 data.read）

日期：2026-08-25
设计：docs/superpowers/specs/2026-08-25-capability-gap-fill-design.md
执行：子代理驱动 + 两阶段审查（规格 + 代码质量）

## 任务

### T1：TRDataFiller 提取共享 data.read（TRDataFiller.mm）
- 加 `+ (NSDictionary *)readDatabase:(NSString *)dbName table:(NSString *)table limit:(NSInteger)limit`
- 移植自 trollvncserver `tvExtHandleDataRead`：kDBPaths（calls/sms/contacts）+ 白名单表 + `SELECT * FROM %@ ORDER BY ROWID DESC LIMIT %ld` 行查询
- 行查询辅助（sqlite 行转 NSDictionary）移植 tvDbQueryRows 逻辑（新静态函数或复用现有）
- limit 钳制 1~50；返回 `{db,count,rows,error?}`
- 验证项：编译通过；返回结构与现有一致

### T2：trollvncserver data.read 改薄封装（trollvncserver.mm L4108-4163）
- `tvExtHandleDataRead` 改为调 `[TRDataFiller readDatabase:...]`（cl 传 NULL 语义不变）
- 移除本地重复实现（路径表/白名单/行查询）
- 验证项：5802/0x50 data.read 返回结构不变

### T3：注册表补 data.read executor（TRCapabilityRegistry.mm）
- 注册 `data.read`（params: db 必填 / table / limit 可选）
- executor 调 `[TRDataFiller readDatabase:...]`，失败转 NSError（对齐 data.fill 模式 L807-827）
- 验证项：网关 invoke `data.read` 返回 `{db,count,rows}`

### T4：trollvncserver 补 sim.itinerary（5802 + 0x50，trollvncserver.mm）
- `tvHttpApiDispatch` 与 `tvExtHandleMessage` 各加 `sim.itinerary` 分支
- 复用 `SimItineraryPlanner submitItinerary:completion:`（异步），返回 `{ok,status:"calculating"}`
- 校验 `segments` 为数组且非空
- `#import "SimItineraryPlanner.h"`（bootstrap SDK 需显式导入，同 MKGeometry 教训）
- 验证项：5802 调 sim.itinerary 返回 calculating；0x50 同

### T5：代码质量审查 + 规格审查
- 审查点：① tvDbQueryRows 移植完整性（NULL 列处理/类型转换）；② sim.itinerary 三处逻辑一致（注册表/5802/0x50）；③ import 缺失（bootstrap 编译）；④ 注释与实现一致
- 修复审查发现

### T6：commit + 文档同步
- commit：`feat: 注册表补 data.read、5802/0x50 补 sim.itinerary（能力缺口对齐）`
- 同步：说明文档.md 能力矩阵（5802 增 sim.itinerary、注册表增 data.read）、AGENTS.md 补条目（三处补齐清单更新）
- 提交与文档同步同一 commit

### T7：CI 验证 + .tipa 落位
- push-via-api + workflow_dispatch + 轮询 run + 下载校验 .tipa（174 条目/3.9MB）
- 验证项：CI 4 scheme success；.tipa 关键文件齐全

### T8：真机验证指引（交付用户）
- 网关 invoke `data.read`（跨网读库）
- 5802 `sim.itinerary`（5801 直连页/脚本可调定位编排）
- 回归：5802/0x50 data.read 行为不变

## 纪律
- 三处补齐（注册表/0x50/5802）本次涉及 data.read（注册表新增）+ sim.itinerary（0x50/5802 新增）
- caps.js/BATCH_CAPS 本次不动（UI 后续阶段）
- 未验证不声称完成
