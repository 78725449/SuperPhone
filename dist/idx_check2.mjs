
import RFB from './novnc/core/rfb.js';
// caps.js 通过动态导入加载（失败不影响连接）；内置默认集作为回退
var DEFAULT_CAPS = ['home', 'power', 'volup', 'voldn', 'mute', 'briup', 'bridn', 'keyboard', 'clipboard'];
var CAP_META = {
  home:      { op: 'home',      label: 'Home',      icon: '🏠', title: 'Home 键' },
  power:     { op: 'power',     label: '电源',      icon: '⏻',    title: '电源' },
  volup:     { op: 'volup',     label: '音量 +',    icon: '🔊', title: '音量 +' },
  voldn:     { op: 'voldn',     label: '音量 −',    icon: '🔉', title: '音量 −' },
  mute:      { op: 'mute',      label: '静音',      icon: '🔇', title: '静音' },
  briup:     { op: 'briup',     label: '亮度 +',    icon: '☀️', title: '亮度 +' },
  bridn:     { op: 'bridn',     label: '亮度 −',    icon: '🌙', title: '亮度 −' },
  keyboard:  { op: 'kb',        label: '键盘',      icon: '⌨️', title: '键盘' },
  clipboard: { op: 'clip',      label: '剪贴板',    icon: '📋', title: '粘贴剪贴板' },
};
(function () {
  var host = location.hostname;
  var port = $PORT;
  var wsProto = location.protocol === 'https:' ? 'wss://' : 'ws://';
  var url = wsProto + host + ':' + port + '/websockify';

  var screen = document.getElementById('screen');
  var hint = document.getElementById('hint');
  var validPort = /^[0-9]+$/.test(String(port)) && port > 0 && port < 65536;
  if (!validPort) {
    hint.textContent = '端口异常：$PORT 未替换（期望 VNC 端口，如 5901）';
  } else {
    hint.textContent = '连接中 ' + url;
  }
  var rfb = new RFB(screen, url, {});
  rfb.scaleViewport = true;
  rfb.resizeSession = false;
  rfb.showDotCursor = true;

  rfb.addEventListener('connect', function () {
    hint.textContent = '已连接 ' + host + ':' + port + '（等待首帧…）';
    // 检测是否真的收到画面帧（区分“连上但黑帧”与“连不上”）
    var gotFrame = false;
    function fbSize() {
      var d = rfb._display;
      if (!d) return 0;
      return d._fbWidth || d._fbHeight || (d.get_width ? d.get_width() : 0) || (d.get_height ? d.get_height() : 0);
    }
    var fc = setInterval(function () {
      if (fbSize() > 0) {
        gotFrame = true;
        hint.textContent = '已连接 · 画面接收中';
        clearInterval(fc);
      }
    }, 800);
    setTimeout(function () {
      clearInterval(fc);
      if (!gotFrame) hint.textContent = '已连接但未收到画面（锁屏黑帧 / 抓屏异常 / 编码不支持）';
    }, 5000);
  });
  rfb.addEventListener('disconnect', function (e) {
    var msg = (e && e.detail && e.detail.message) ? '：' + e.detail.message : '';
    hint.textContent = '已断开' + msg + '（目标 ' + url + '）';
  });
  rfb.addEventListener('error', function () { hint.textContent = '连接失败 ' + url; });
  rfb.addEventListener('credentialsrequired', function () {
    var p = window.prompt('请输入 VNC 密码：');
    if (p) rfb.sendCredentials({ password: p });
  });

  function tapKey(ks, code) {
    try { rfb.sendKey(ks, code, true); } catch (e) { return; }
    setTimeout(function () { try { rfb.sendKey(ks, code, false); } catch (e) {} }, 60);
  }
  function pointer(mask) {
    try {
      var b = new Uint8Array(6);
      b[0] = 5; b[1] = mask; b[2] = 0; b[3] = 1; b[4] = 0; b[5] = 1;
      rfb._sock.send(b.buffer);
      if (mask !== 0) setTimeout(function () { pointer(0); }, 80);
    } catch (e) {}
  }
  function doOp(op) {
    switch (op) {
      case 'home': tapKey(0xff50, 'Home'); break;
      case 'power': pointer(2); break;
      case 'volup': tapKey(0x1008ff13, 'AudioVolumeUp'); break;
      case 'voldn': tapKey(0x1008ff11, 'AudioVolumeDown'); break;
      case 'mute': tapKey(0x1008ff12, 'AudioVolumeMute'); break;
      case 'briup': tapKey(0x1008ff03, 'BrightnessUp'); break;
      case 'bridn': tapKey(0x1008ff02, 'BrightnessDown'); break;
      case 'kb': try { rfb.focus(); } catch (e) {} break;
      case 'clip':
        navigator.clipboard.readText().then(function (t) { if (t) try { rfb.clipboardPasteFrom(t); } catch (e) {} }).catch(function () {});
        break;
      case 'fit': rfb.scaleViewport = true; break;
      case 'full':
        if (document.fullscreenElement) document.exitFullscreen();
        else document.documentElement.requestFullscreen().catch(function () {});
        break;
      case 'disc': try { rfb.disconnect(); } catch (e) {} break;
    }
  }
  // 能力清单驱动渲染（宪法 5.2/6.6）：设备操作来自清单（优先 runtime 注入 window.TVNC_CAPS），
  // 适配/全屏/断开为本地操作，由静态按钮提供
  function renderCapOps(container) {
    if (!container) return;
    var caps = (window.TVNC_CAPS && window.TVNC_CAPS.length) ? window.TVNC_CAPS : DEFAULT_CAPS;
    container.innerHTML = '';
    caps.forEach(function (c) {
      var meta = CAP_META[c];
      if (!meta) return;
      var b = document.createElement('button');
      b.type = 'button';
      b.dataset.op = meta.op;
      b.title = meta.title;
      b.textContent = meta.icon;
      b.addEventListener('click', function () { doOp(meta.op); });
      container.appendChild(b);
    });
  }
  renderCapOps(document.getElementById('barCaps'));
  renderCapOps(document.getElementById('opsCaps'));
  import('./caps.js').then(function (m) {
    if (m && m.DEFAULT_CAPS) DEFAULT_CAPS = m.DEFAULT_CAPS;
    if (m && m.CAP_META) CAP_META = m.CAP_META;
    renderCapOps(document.getElementById('barCaps'));
    renderCapOps(document.getElementById('opsCaps'));
  }).catch(function () { /* caps.js 缺失不影响连接 */ });
  function bind(sel) {
    document.querySelectorAll(sel).forEach(function (b) {
      b.addEventListener('click', function () { doOp(b.dataset.op); });
    });
  }
  bind('#bar [data-op]');
  bind('#opsMenu [data-op]');
  document.getElementById('fabBtn').addEventListener('click', function () {
    document.getElementById('opsMenu').classList.toggle('show');
  });
  document.getElementById('menuClose').addEventListener('click', function () {
    document.getElementById('opsMenu').classList.remove('show');
  });
})();
