// 能力清单纯模块单测（web/caps.js）：清单驱动渲染的边界（宪法 4.2/5.2/7.3）
import { DEFAULT_CAPS, CAP_META, deviceCaps } from '../web/caps.js';

let failures = 0;
function check(name, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

check('默认全集 9 项且不含本地操作(适配/全屏/断开)',
  DEFAULT_CAPS.length === 9 && !DEFAULT_CAPS.some((c) => ['fit', 'full', 'disc'].includes(c)));
check('CAP_META 覆盖全部默认项且字段齐全',
  DEFAULT_CAPS.every((c) => CAP_META[c] && CAP_META[c].op && CAP_META[c].label && CAP_META[c].icon && CAP_META[c].title));
check('keyboard→kb / clipboard→clip 映射', CAP_META.keyboard.op === 'kb' && CAP_META.clipboard.op === 'clip');
check('无清单设备 → 默认全集', deviceCaps(undefined).join() === DEFAULT_CAPS.join());
check('空清单 → 默认全集', deviceCaps({ capabilities: [] }).join() === DEFAULT_CAPS.join());
check('部分清单按上报渲染', deviceCaps({ capabilities: ['home', 'power'] }).join() === 'home,power');
check('未知项被过滤', deviceCaps({ capabilities: ['home', 'weird', 'clipboard'] }).join() === 'home,clipboard');

console.log(failures === 0 ? '\nALL CAPS TESTS PASSED' : `\n${failures} TEST(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
