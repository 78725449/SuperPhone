// PressRecognizer：按键对象按压模式识别（07 §3.2）
// 用法：attachPress(element, keyDef, { invoke: async (capId) => {} })
// 事件：pointerdown/pointerup，双击/三击窗口 300ms，长按阈值 800ms

const DOUBLE_MS = 300;
const LONG_MS = 800;

/**
 * 挂载按压识别器：将 keyDef.events 声明的按压模式（click/double/triple/long/down/up）翻译为能力 id 调用
 * @param element 目标元素（需支持 addEventListener/removeEventListener，浏览器 DOM 或 Node EventTarget 均可）
 * @param keyDef 按键对象，格式 { key, title, icon, events: { click: capId, double: capId, triple: capId, long: capId, down: capId, up: capId } }
 * @param opts 选项对象 { invoke: async (capId) => {} }，capId 为 keyDef.events 中对应模式声明的能力 id
 * @returns {Function} 卸载函数；调用后移除事件监听，停止识别
 */
export function attachPress(element, keyDef, opts = {}) {
  const events = keyDef.events || {};
  let isLong = false, longTimer = null, pressCount = 0, clickTimer = null;

  const fire = (name) => {
    const capId = events[name];
    if (capId && opts.invoke) opts.invoke(capId);
  };

  const onUp = () => {
    clearTimeout(longTimer);
    fire('up');                                      // 有 up 字段的按键：松开触发 up
    if (isLong) { isLong = false; return; }          // 长按已触发，抬起不再算点击
    pressCount += 1;
    // 有 double/triple 才启用多击窗口
    if (events.double || events.triple) {
      clearTimeout(clickTimer);
      clickTimer = setTimeout(() => {
        // 分级判定：达到三击阈值触发 triple，否则达双击阈值触发 double，否则按单击
        if (events.triple && pressCount >= 3) fire('triple');
        else if (events.double && pressCount >= 2) fire('double');
        else fire('click');
        pressCount = 0;
      }, DOUBLE_MS);
    } else {
      fire('click');                                 // 无多击：立即执行，零延迟
    }
  };

  const onDown = (e) => {
    if (e && e.preventDefault) e.preventDefault();
    isLong = false;
    clearTimeout(clickTimer);                        // 新一轮按压开始，作废 pending 多击窗口
    fire('down');                                    // down 类按键按下立即触发
    if (events.long) {
      longTimer = setTimeout(() => { isLong = true; pressCount = 0; fire('long'); }, LONG_MS);
    }
  };

  element.addEventListener('pointerdown', onDown);
  element.addEventListener('pointerup', onUp);
  return () => { element.removeEventListener('pointerdown', onDown); element.removeEventListener('pointerup', onUp); };
}
