// 聚焦画布多点手势 → touch.* 能力调用（2026-08-16）
// 消费 server patch 的 rfb.js 在 pinch/twotap/threetap 手势上派发的 farmgesture CustomEvent：
//   detail = { type, clientX, clientY, rect?, scale?, angle?, duration? }
// 坐标统一画布内 0-1 归一化（(0.5,0.5)=画布中央），与设备端 touch.* 契约一致；
// 设备端再按自身屏幕物理像素去归一化（见说明文档 §4.4）。
// 增改手势 = caps.js GESTURE_DEFS + 设备端 executor + 本文件 resolveGesture 各加一条。

/**
 * 画布视口坐标 → 0-1 归一化（钳制到画布内兜底）
 * @param {number} x clientX
 * @param {number} y clientY
 * @param {DOMRect} rect 画布 getBoundingClientRect()
 * @returns {{x: number, y: number}}
 */
export function normalizePoint(x, y, rect) {
  if (!rect || rect.width <= 0 || rect.height <= 0) return { x: 0.5, y: 0.5 };
  return {
    x: Math.min(1, Math.max(0, (x - rect.left) / rect.width)),
    y: Math.min(1, Math.max(0, (y - rect.top) / rect.height)),
  };
}

/**
 * 手势事件 → 能力调用（纯函数，供单测）
 * @param {{type: string, clientX: number, clientY: number, rect?: DOMRect,
 *          scale?: number, angle?: number, duration?: number}} detail farmgesture 事件 detail
 * @returns {{cap: string, params: object}|null} 无可调用手势（如 scale≈1）返回 null
 */
export function resolveGesture(detail) {
  const { type, clientX, clientY, rect } = detail || {};
  const pt = normalizePoint(clientX, clientY, rect);
  switch (type) {
    case 'pinch': {
      // scale 由 server patch 按位移增量映射并已钳制；此处防御性再钳制（设备端校验 0.5~2.0）
      const scale = Math.max(0.5, Math.min(2.0, Number(detail.scale) || 1));
      // scale==1 表示间距未变化：设备端 pinchLinearInBounds 也直接忽略，这里提前跳过
      if (scale <= 0.99 || scale >= 1.01) {
        return {
          cap: 'touch.pinch',
          params: {
            x: pt.x, y: pt.y,
            scale,
            angle: Number(detail.angle) || 0,
            duration: Number(detail.duration) || 0.6,
          },
        };
      }
      return null;
    }
    case 'twotap':
      return { cap: 'touch.twoFingerTap', params: { x: pt.x, y: pt.y } };
    case 'threetap':
      return { cap: 'touch.threeFingerTap', params: { x: pt.x, y: pt.y } };
    default:
      return null;
  }
}

/**
 * 在画布上挂多点手势监听（farmgesture → 能力调用）
 * @param {HTMLElement} canvas 画布元素（rfb._canvas）
 * @param {{invoke?: Function, shouldRun?: Function}} opts
 *   invoke(cap, params) 能力调用；shouldRun() 返回是否当前可操控会话（默认恒真）
 * @returns {Function} 卸载函数
 */
export function attachFarmGesture(canvas, opts = {}) {
  if (!canvas || typeof canvas.addEventListener !== 'function') return () => {};
  const invoke = opts.invoke || (() => {});
  const shouldRun = opts.shouldRun || (() => true);
  const handler = (ev) => {
    if (!shouldRun()) return;
    const rect = canvas.getBoundingClientRect();
    const target = resolveGesture(Object.assign({}, ev.detail || {}, { rect }));
    if (target) invoke(target.cap, target.params);
  };
  canvas.addEventListener('farmgesture', handler);
  return () => canvas.removeEventListener('farmgesture', handler);
}