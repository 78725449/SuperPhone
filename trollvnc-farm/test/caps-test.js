// 能力前端自包含定义单测（web/caps.js）：无上报、无元数据表，全部为可直接调用的定义数组
import { ACT_DEFS, QUICK_ACTIONS, BATCH_CAPS, CONFIG_DEFS, CONFIG_BY_KEY, KEY_DEFS, QUICK_CONFIG_GROUPS, configSchemaByReload, groupByCategory } from '../web/caps.js';

let failures = 0;
function check(name, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

// ---- ACT_DEFS：动作区自包含定义 ----
check('ACT_DEFS 5 项且字段齐全', ACT_DEFS.length === 5 && ACT_DEFS.every((d) => d.id && d.title && d.icon && Array.isArray(d.params)));
check('ACT_DEFS 覆盖动作区能力 id',
  ['type.text', 'type.paste', 'clipboard.get', 'clipboard.set', 'screenshot'].every((id) => ACT_DEFS.some((d) => d.id === id)));

// ---- QUICK_ACTIONS：卡片能力自包含 ----
check('QUICK_ACTIONS 自包含 service.restart',
  QUICK_ACTIONS.length === 1 && QUICK_ACTIONS[0].id === 'service.restart' && QUICK_ACTIONS[0].title && QUICK_ACTIONS[0].icon && Array.isArray(QUICK_ACTIONS[0].params));

// ---- BATCH_CAPS：批量能力自包含 ----
check('BATCH_CAPS 非空且自包含（含 category）',
  BATCH_CAPS.length >= 20 && BATCH_CAPS.every((d) => d.id && d.title && d.icon && d.category && Array.isArray(d.params)));
check('BATCH_CAPS 含 restart/查询类', BATCH_CAPS.some((d) => d.id === 'service.restart') && BATCH_CAPS.some((d) => d.id === 'clients.list'));
check('BATCH_CAPS 不含触控/截图/剪贴板/文本类',
  !BATCH_CAPS.some((d) => /touch|stylus|screenshot|clipboard|type\./i.test(d.id)));

// ---- CONFIG_DEFS：配置表单定义契约 ----
check('CONFIG_DEFS 含 37 项', CONFIG_DEFS.length === 37);
check('CONFIG_DEFS 覆盖 QUICK 6 项', QUICK_CONFIG_GROUPS.flatMap((g) => g.keys).every((k) => CONFIG_BY_KEY.has(k)));
check('CONFIG_DEFS 不含端口项（端口固定不可调）', !CONFIG_DEFS.some((s) => /Port$/i.test(s.key)));
check('CONFIG_DEFS 每项含 reload 与字段', CONFIG_DEFS.every((s) => s.key && s.title && s.type && s.reload));
check('configSchemaByReload 四区非空',
  ['instant', 'hot', 'gateway', 'restart'].every((k) => Array.isArray(configSchemaByReload()[k]))
  && Object.values(configSchemaByReload()).some((a) => a.length > 0));

// ---- KEY_DEFS 保留（右侧按键直发） ----
check('KEY_DEFS 12 键且含直发映射', KEY_DEFS.length === 12 && KEY_DEFS.every((k) => k.title && k.icon && k.events));
check('KEY_DEFS 按键含 ks/code/ptr 直发映射', KEY_DEFS.some((k) => typeof k.ks === 'number') && KEY_DEFS.some((k) => k.ptr));

// ---- groupByCategory 保留（批量分组渲染） ----
check('groupByCategory 按 category 分组', groupByCategory(BATCH_CAPS).size >= 4);

console.log(failures === 0 ? 'ALL CAPS TESTS PASSED' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
