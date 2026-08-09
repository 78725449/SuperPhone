// 能力清单纯模块单测（web/caps.js）：清单驱动渲染的边界（宪法 4.2/5.2/7.3）
import { DEFAULT_CAPS, CAP_FALLBACK, deviceCaps, groupByCategory } from '../web/caps.js';

let failures = 0;
function check(name, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

const ids = (arr) => (arr || []).map((c) => c && c.id).filter(Boolean);

check('默认全集 9 项且不含本地操作(适配/全屏/断开)',
  DEFAULT_CAPS.length === 9 && !DEFAULT_CAPS.some((c) => ['fit', 'full', 'disc'].includes(c)));
check('CAP_FALLBACK 覆盖全部默认项且字段齐全',
  DEFAULT_CAPS.every((c) => CAP_FALLBACK[c] && CAP_FALLBACK[c].id === c && CAP_FALLBACK[c].title &&
    CAP_FALLBACK[c].icon && CAP_FALLBACK[c].category && CAP_FALLBACK[c].route && CAP_FALLBACK[c].route.type &&
    Array.isArray(CAP_FALLBACK[c].params)));
check('keyboard→hid / clipboard.paste→native 路由映射',
  CAP_FALLBACK.keyboard.route.type === 'hid' && CAP_FALLBACK['clipboard.paste'].route.type === 'native');
check('无清单设备 → 默认全集', ids(deviceCaps(undefined)).join() === DEFAULT_CAPS.join());
check('空清单 → 默认全集', ids(deviceCaps({ capabilities: [] })).join() === DEFAULT_CAPS.join());
check('部分清单按上报渲染', ids(deviceCaps({ capabilities: ['home', 'power'] })).join() === 'home,power');
check('未知项被过滤', ids(deviceCaps({ capabilities: ['home', 'weird', 'clipboard'] })).join() === 'home');
check('capMetadata 优先于 capabilities',
  ids(deviceCaps({ capabilities: ['home'], capMetadata: [{ id: 'screenshot', title: '截屏', icon: '📸', category: 'system', route: { type: 'native' }, params: [] }] })).join() === 'screenshot');
check('groupByCategory 按 category 分组',
  (() => {
    const m = groupByCategory([
      { id: 'a', category: 'hid' },
      { id: 'b', category: 'hid' },
      { id: 'c', category: 'native' },
    ]);
    return m.get('hid').length === 2 && m.get('native').length === 1 && m.get('control') === undefined;
  })());
check('groupByCategory 无 category 兜底 control',
  (() => { const m = groupByCategory([{ id: 'x' }]); return m.get('control').length === 1; })());
check('groupByCategory 非数组 → 空 Map',
  (() => { const m = groupByCategory(null); return m instanceof Map && m.size === 0; })());

console.log(failures === 0 ? '\nALL CAPS TESTS PASSED' : `\n${failures} TEST(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
