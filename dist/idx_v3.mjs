
import RFB from './novnc/core/rfb.js';
(function () {
  var host = location.hostname;
  var port = $PORT;
  var wsProto = location.protocol === 'https:' ? 'wss://' : 'ws://';
  var url = wsProto + host + ':' + port + '/websockify';

  var screen = document.getElementById('screen');
  var hint = document.getElementById('hint');
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
  // 直接注入 RFB PointerEvent（type=5）：中键=电源（TrollVNC 映射）
  function pointer(mask) {
    try {
      var b = new Uint8Array(6);
      b[0] = 5; b[1] = mask; b[2] = 0; b[3] = 1; b[4] = 0; b[5] = 1;
      rfb._sock.send(b.buffer);
      if (mask !== 0) setTimeout(function () { pointer(0); }, 80);
    } catch (e) {}
  }

  document.getElementById('bHome').onclick = function () { tapKey(0xff50, 'Home'); };
  document.getElementById('bPower').onclick = function () { pointer(2); };
  document.getElementById('bVolDn').onclick = function () { tapKey(0x1008ff11, 'AudioVolumeDown'); };
  document.getElementById('bVolUp').onclick = function () { tapKey(0x1008ff13, 'AudioVolumeUp'); };
  document.getElementById('bMute').onclick = function () { tapKey(0x1008ff12, 'AudioVolumeMute'); };
  document.getElementById('bBriUp').onclick = function () { tapKey(0x1008ff03, 'BrightnessUp'); };
  document.getElementById('bBriDn').onclick = function () { tapKey(0x1008ff02, 'BrightnessDown'); };
  document.getElementById('bFit').onclick = function () { rfb.scaleViewport = true; };
  document.getElementById('bFull').onclick = function () {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen().catch(function () {});
  };
  document.getElementById('bDisc').onclick = function () {
    try { rfb.disconnect(); } catch (e) {}
  };

  // 能力清单增强（可选）：caps.js 可加载时覆盖按钮标题（失败不影响连接）
  import('./caps.js').then(function (m) {
    if (!m || !m.CAP_META) return;
    var map = {
      home: 'bHome', power: 'bPower', volup: 'bVolUp', voldn: 'bVolDn',
      mute: 'bMute', briup: 'bBriUp', bridn: 'bBriDn'
    };
    Object.keys(map).forEach(function (op) {
      var meta = m.CAP_META[op];
      var el = document.getElementById(map[op]);
      if (meta && el) el.textContent = meta.label;
    });
  }).catch(function () {});
})();
