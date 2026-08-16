// 能力前端自包含定义单测（web/caps.js）：无上报、无元数据表，全部为可直接调用的定义数组
// 2026-08-15 精简：ACT_DEFS/QUICK_ACTIONS/QUICK_CONFIG_GROUPS/configSchemaByReload 已删除（卡片菜单仅留编辑/删除），
// BATCH_CAPS 去掉 clients.*/sys.*/gateway.*（App 原生客户端列表另有入口）。
import { BATCH_CAPS, CONFIG_DEFS, CONFIG_BY_KEY, KEY_DEFS, GESTURE_DEFS, groupByCategory } from '../web/caps.js';

let failures = 0;
function check(name, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

// ---- BATCH_CAPS：批量能力自包含（精简后 20 项：17 硬件键 + 重启 + 生成证书 + 搜索网关） ----
check('BATCH_CAPS 非空且自包含（含 category）',
  BATCH_CAPS.length === 20 && BATCH_CAPS.every((d) => d.id && d.title && d.icon && d.category && Array.isArray(d.params)));
check('BATCH_CAPS 含重启、不含客户端/系统/网关批量项',
  BATCH_CAPS.some((d) => d.id === 'service.restart')
  && !BATCH_CAPS.some((d) => /clients\.|sys\.|gateway\.|touch|stylus|screenshot|clipboard|type\./i.test(d.id)));

// ---- CONFIG_DEFS：配置表单定义契约 ----
check('CONFIG_DEFS 含 36 项', CONFIG_DEFS.length === 36);
check('CONFIG_DEFS 不含端口项（端口固定不可调）', !CONFIG_DEFS.some((s) => /Port$/i.test(s.key)));
check('CONFIG_DEFS 每项含 reload 与字段', CONFIG_DEFS.every((s) => s.key && s.title && s.type && s.reload));

// ---- KEY_DEFS 保留（右侧按键直发；2026-08-14 移除 hwlock/releasekeys 两键 → 10 键） ----
check('KEY_DEFS 10 键且含直发映射', KEY_DEFS.length === 10 && KEY_DEFS.every((k) => k.title && k.icon && k.events));
check('KEY_DEFS 按键含 ks/code/ptr 直发映射', KEY_DEFS.some((k) => typeof k.ks === 'number') && KEY_DEFS.some((k) => k.ptr));

// ---- groupByCategory 保留（批量分组渲染：hid/service/native） ----
check('groupByCategory 按 category 分组', groupByCategory(BATCH_CAPS).size === 3);

// ---- GESTURE_DEFS（2026-08-16 画布多点手势契约：pinch/twotap/threetap → touch.* invoke） ----
check('GESTURE_DEFS 3 项且字段齐全',
  GESTURE_DEFS.length === 3 && GESTURE_DEFS.every((g) => g.gesture && g.id && g.title && g.icon && g.category === 'touch'));
check('GESTURE_DEFS id 为 touch.* 且不与 BATCH_CAPS/KEY_DEFS 冲突',
  GESTURE_DEFS.every((g) => /^touch\./.test(g.id))
  && !GESTURE_DEFS.some((g) => [...BATCH_CAPS, ...KEY_DEFS].some((d) => d.id === g.id)));

console.log(failures === 0 ? 'ALL CAPS TESTS PASSED' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
