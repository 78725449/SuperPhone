// 画布多点手势 → touch.* 能力映射单测（web/gesture.js）：与设备端 touch.* 契约对齐
// 坐标 0-1 归一化；pinch scale≈1 跳过（设备端 pinchLinearInBounds 同样忽略 scale=1）。
import { GESTURE_DEFS } from '../web/caps.js';
import { resolveGesture, normalizePoint } from '../web/gesture.js';

let failures = 0;
function check(name, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
  if (!cond) failures++;
}

// DOMRect 桩（画布 800×400，位于 (100,50)）
const rect = { left: 100, top: 50, width: 800, height: 400, right: 900, bottom: 450 };

// ---- 契约对齐：GESTURE_DEFS 与 resolveGesture 支持的输入端一致 ----
check('GESTURE_DEFS 声明与 resolveGesture 三态覆盖一致',
  GESTURE_DEFS.length === 3
  && GESTURE_DEFS.every((g) => g.gesture && g.id && g.title && g.icon && g.category === 'touch')
  && GESTURE_DEFS.map((g) => g.gesture).sort().join(',') === 'pinch,threetap,twotap');

// ---- normalizePoint：画布坐标 → 0-1 ----
check('normalizePoint 画布坐标转 0-1（中心）',
  normalizePoint(500, 250, rect).x === 0.5 && normalizePoint(500, 250, rect).y === 0.5);
check('normalizePoint 越界钳制到 0-1',
  normalizePoint(-10, 9999, rect).x === 0 && normalizePoint(-10, 9999, rect).y === 1);
check('normalizePoint 无 rect 回退中心（不抛错）',
  normalizePoint(1, 1, null).x === 0.5 && normalizePoint(1, 1, null).y === 0.5);

// ---- 两指/三指轻点 ----
const two = resolveGesture({ type: 'twotap', clientX: 500, clientY: 250, rect });
check('twotap → touch.twoFingerTap（中心 0.5,0.5）',
  two.cap === 'touch.twoFingerTap' && two.params.x === 0.5 && two.params.y === 0.5);
const three = resolveGesture({ type: 'threetap', clientX: 100, clientY: 50, rect });
check('threetap → touch.threeFingerTap（左上角 0,0）',
  three.cap === 'touch.threeFingerTap' && three.params.x === 0 && three.params.y === 0);

// ---- 捏合 ----
const pinch = resolveGesture({ type: 'pinch', clientX: 500, clientY: 250, rect, scale: 1.6, angle: 0.3 });
check('pinch scale>1 → touch.pinch（scale/angle/duration 默认 0.6/中心）',
  pinch.cap === 'touch.pinch'
  && pinch.params.scale === 1.6 && pinch.params.angle === 0.3 && pinch.params.duration === 0.6
  && pinch.params.x === 0.5 && pinch.params.y === 0.5);
check('pinch scale<1 缩小同样放行',
  resolveGesture({ type: 'pinch', clientX: 500, clientY: 250, rect, scale: 0.7 }).params.scale === 0.7);
check('pinch 超界 scale 钳制到 [0.5,2.0]（与设备端校验一致，防超界被拒）',
  resolveGesture({ type: 'pinch', clientX: 500, clientY: 250, rect, scale: 5 }).params.scale === 2
  && resolveGesture({ type: 'pinch', clientX: 500, clientY: 250, rect, scale: 0.1 }).params.scale === 0.5);
check('pinch scale≈1 跳过（返回 null，设备端同样忽略）',
  resolveGesture({ type: 'pinch', clientX: 500, clientY: 250, rect, scale: 1 }) === null);

// ---- 非法输入兜底 ----
check('未知手势类型 → null', resolveGesture({ type: 'rotate', clientX: 1, clientY: 1, rect }) === null);
check('缺 rect 不抛错（中心兜底）',
  resolveGesture({ type: 'threetap', clientX: 1, clientY: 1 }).params.x === 0.5);
check('空 detail → null', resolveGesture(null) === null);

console.log(failures === 0 ? 'ALL GESTURE TESTS PASSED' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);