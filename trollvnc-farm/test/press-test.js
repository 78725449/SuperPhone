// PressRecognizer 时序单测（07 §3.2，Node EventTarget 模拟 pointer 事件）
import { attachPress } from '../web/press.js';

let failures = 0;
function check(name, cond) { console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}`); if (!cond) failures++; }

function makeEl() {
  return new EventTarget(); // Node 原生 EventTarget 已支持 addEventListener/dispatchEvent
}
function press(el, t) {
  return new Promise((res) => {
    setTimeout(() => { el.dispatchEvent(new Event('pointerdown')); }, t);
    setTimeout(() => { el.dispatchEvent(new Event('pointerup')); res(); }, t + 60);
  });
}
function pressHold(el, t, holdMs) {
  return new Promise((res) => {
    setTimeout(() => { el.dispatchEvent(new Event('pointerdown')); }, t);
    setTimeout(() => { el.dispatchEvent(new Event('pointerup')); res(); }, t + holdMs);
  });
}

(async () => {
  const volup = { events: { click: 'volup', down: 'volup.down', up: 'volup.up' } };
  const calls = [];
  const el = makeEl();
  attachPress(el, volup, { invoke: (id) => calls.push(id) });

  await press(el, 0);                                // 单击 → down/click/up
  check('volup 按下触发 down', calls.includes('volup.down'));
  check('volup 抬起触发 up', calls.includes('volup.up'));
  check('volup 单击立即执行（无多击延迟）', calls.includes('volup') && calls[0] === 'volup.down');

  calls.length = 0;
  const el2 = makeEl();
  attachPress(el2, { events: { click: 'home', double: 'home.double', long: 'home.long' } }, { invoke: (id) => calls.push(id) });
  await press(el2, 0); await press(el2, 120);        // 两次快速点击 → double
  await new Promise((r) => setTimeout(r, 400));
  check('home 双击识别为 home.double', calls.includes('home.double') && !calls.includes('home'));

  calls.length = 0;
  const el3 = makeEl();
  attachPress(el3, { events: { click: 'home', double: 'home.double', long: 'home.long' } }, { invoke: (id) => calls.push(id) });
  await press(el3, 0);                               // 单次点击 → 窗口超时后 click
  await new Promise((r) => setTimeout(r, 400));
  check('home 单击窗口超时执行 click', calls.includes('home'));

  calls.length = 0;
  const el4 = makeEl();
  attachPress(el4, { events: { click: 'home', double: 'home.double', long: 'home.long' } }, { invoke: (id) => calls.push(id) });
  await pressHold(el4, 0, 900);                      // 按住 900ms → long
  await new Promise((r) => setTimeout(r, 200));
  check('home 长按识别为 home.long', calls.includes('home.long') && !calls.includes('home'));

  calls.length = 0;
  const el5 = makeEl();
  attachPress(el5, { events: { click: 'power', double: 'power.double', triple: 'power.triple', long: 'power.long' } }, { invoke: (id) => calls.push(id) });
  await press(el5, 0); await press(el5, 120); await press(el5, 240);  // 三次快速点击 → triple
  await new Promise((r) => setTimeout(r, 400));
  check('power 三击识别为 power.triple', calls.includes('power.triple') && !calls.includes('power'));

  console.log(failures === 0 ? '\nALL PRESS TESTS PASSED' : `\n${failures} TEST(S) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
})();
