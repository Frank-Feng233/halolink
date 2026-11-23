//
//  WebPage.swift
//  HaloLink macOS host
//
//  Self-contained browser fallback client (served at GET /). No CDN, no ES
//  modules, no exotic APIs — it must work in the Chromium-based HarmonyOS
//  browser. The page shows the MJPEG stream and posts normalized pointer events
//  back to POST /input; the Mac injects them as real events.
//

import Foundation

enum WebPage {
    static let html: String = #"""
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,minimum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="theme-color" content="#0b0f14">
<title>HaloLink 扩展屏</title>
<style>
  html,body{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden;
    overscroll-behavior:none;touch-action:none;user-select:none;-webkit-user-select:none;
    -webkit-tap-highlight-color:transparent;
    font-family:-apple-system,"HarmonyOS Sans","Noto Sans SC","PingFang SC",system-ui,sans-serif;}
  #stage{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;background:#000;}
  #screen{display:block;background:#000;touch-action:none;user-select:none;-webkit-user-drag:none;
    max-width:none;max-height:none;transform-origin:center center;}
  #bar{position:fixed;left:0;right:0;top:0;height:40px;display:flex;align-items:center;gap:10px;
    padding:0 12px;box-sizing:border-box;background:linear-gradient(180deg,rgba(0,0,0,.78),rgba(0,0,0,0));
    color:#9fe8d8;font:12px/40px "SF Mono",Menlo,Consolas,monospace;z-index:10;
    transition:opacity .25s ease;}
  #bar.hidden{opacity:0;pointer-events:none;}
  #bar .sep{opacity:.35;}
  #bar .grow{flex:1;}
  #title{font-weight:700;color:#5eead4;letter-spacing:.5px;}
  #state{color:#fbbf24;}
  #state.ok{color:#5eead4;}
  #state.bad{color:#f87171;}
  .btn{-webkit-appearance:none;appearance:none;border:1px solid rgba(94,234,212,.45);
    background:rgba(15,23,42,.72);color:#a7f3d0;font:12px/1 -apple-system,system-ui,sans-serif;
    padding:8px 12px;border-radius:9px;cursor:pointer;touch-action:manipulation;}
  .btn:active{background:rgba(94,234,212,.25);}
  #panel{position:fixed;left:50%;bottom:18px;transform:translateX(-50%);width:min(720px,92vw);
    display:none;gap:8px;align-items:center;padding:10px;box-sizing:border-box;
    background:rgba(15,23,42,.94);border:1px solid rgba(94,234,212,.35);border-radius:14px;
    z-index:20;box-shadow:0 12px 32px rgba(0,0,0,.6);}
  #panel.show{display:flex;}
  #text{flex:1;min-width:0;background:#020617;color:#e2e8f0;border:1px solid rgba(148,163,184,.4);
    border-radius:9px;padding:10px 12px;font:15px/1.2 -apple-system,system-ui,sans-serif;outline:none;}
  #text:focus{border-color:#5eead4;}
  #hint{position:fixed;left:0;right:0;bottom:56px;text-align:center;color:#64748b;
    font:12px/1.5 -apple-system,system-ui,sans-serif;pointer-events:none;z-index:9;transition:opacity .4s;}
  #hint.hidden{opacity:0;}
  #toast{position:fixed;left:50%;top:56px;transform:translateX(-50%);padding:8px 14px;border-radius:10px;
    background:rgba(220,38,38,.92);color:#fff;font:12px/1.4 -apple-system,system-ui,sans-serif;
    display:none;z-index:30;max-width:90vw;}
  #toast.show{display:block;}
  .fs-only{display:none;}
  body.fullscreen #bar{opacity:0;}
</style>
</head>
<body>
<div id="stage"><img id="screen" alt="HaloLink stream" draggable="false"></div>
<div id="bar">
  <span id="title">HaloLink</span>
  <span id="state">连接中…</span>
  <span class="sep">|</span>
  <span id="res">--</span>
  <span id="fps">fps --</span>
  <span id="kbps">-- kbps</span>
  <span id="rtt">rtt --</span>
  <span class="grow"></span>
  <button class="btn" id="fullBtn" type="button">全屏</button>
  <button class="btn" id="kbdBtn" type="button">键盘/文字</button>
</div>
<div id="hint">点击画面开始 · 单指拖动=鼠标 · 双指滑动=滚轮</div>
<div id="panel">
  <input id="text" type="text" autocomplete="off" autocorrect="off" autocapitalize="off"
         spellcheck="false" placeholder="输入文字后回车发送到 Mac">
  <button class="btn" id="sendBtn" type="button">发送</button>
  <button class="btn" id="closeBtn" type="button">关闭</button>
</div>
<div id="toast"></div>
<script>
(function () {
  'use strict';

  var img = document.getElementById('screen');
  var stage = document.getElementById('stage');
  var stateEl = document.getElementById('state');
  var resEl = document.getElementById('res');
  var fpsEl = document.getElementById('fps');
  var kbpsEl = document.getElementById('kbps');
  var rttEl = document.getElementById('rtt');
  var hintEl = document.getElementById('hint');
  var panel = document.getElementById('panel');
  var textEl = document.getElementById('text');
  var toastEl = document.getElementById('toast');

  var statusTimer = null;
  var streamRequested = false;
  var streamWidth = 0, streamHeight = 0;
  var lastStatusOk = 0;

  // ---- keyboard / text panel -------------------------------------------------
  function showPanel(show) {
    panel.classList.toggle('show', !!show);
    if (show) {
      setTimeout(function () { textEl.focus(); }, 40);
    } else {
      textEl.blur();
    }
  }
  function toast(message) {
    toastEl.textContent = message;
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.classList.remove('show'); }, 2200);
  }
  var toastTimer = null;

  document.getElementById('kbdBtn').addEventListener('click', function (ev) {
    ev.preventDefault();
    ev.stopPropagation();
    showPanel(!panel.classList.contains('show'));
  });
  document.getElementById('closeBtn').addEventListener('click', function (ev) {
    ev.preventDefault();
    showPanel(false);
  });
  function sendText() {
    var value = textEl.value;
    if (!value) { return; }
    post({ type: 'text', text: value });
    textEl.value = '';
  }
  document.getElementById('sendBtn').addEventListener('click', function (ev) {
    ev.preventDefault();
    sendText();
  });
  textEl.addEventListener('keydown', function (ev) {
    if (ev.key === 'Enter') {
      ev.preventDefault();
      sendText();
    } else if (ev.key === 'Escape') {
      showPanel(false);
    }
    ev.stopPropagation();
  });

  // ---- fullscreen -----------------------------------------------------------
  var fullBtn = document.getElementById('fullBtn');
  function isFullscreen() {
    return document.fullscreenElement || document.webkitFullscreenElement ||
           document.mozFullScreenElement || document.msFullscreenElement || false;
  }
  function requestFullscreen() {
    var el = document.documentElement;
    var fn = el.requestFullscreen || el.webkitRequestFullscreen ||
             el.mozRequestFullScreen || el.msRequestFullscreen;
    if (!fn) { return false; }
    try {
      var result = fn.call(el);
      if (result && typeof result.then === 'function') { result.catch(function () {}); }
      return true;
    } catch (e) { return false; }
  }
  function toggleFullscreen() {
    if (isFullscreen()) {
      var exit = document.exitFullscreen || document.webkitExitFullscreen ||
                 document.mozCancelFullScreen || document.msExitFullscreen;
      if (exit) { try { exit.call(document); } catch (e) {} }
    } else if (!requestFullscreen()) {
      toast('此浏览器不支持全屏，可添加到主屏幕使用');
    }
  }
  fullBtn.addEventListener('click', function (ev) {
    ev.preventDefault();
    ev.stopPropagation();
    toggleFullscreen();
  });
  document.addEventListener('fullscreenchange', function () {
    document.body.classList.toggle('fullscreen', !!isFullscreen());
  });
  var autoFullscreenTried = false;
  function autoFullscreenOnFirstGesture() {
    if (autoFullscreenTried) { return; }
    autoFullscreenTried = true;
    if (!isFullscreen()) { requestFullscreen(); }
  }

  // ---- HTTP helpers ---------------------------------------------------------
  var moveInFlight = false;
  function post(obj) {
    try {
      var body = JSON.stringify(obj);
      var isMove = (obj.type === 'touch' && obj.action === 'move');
      if (isMove) {
        if (moveInFlight) { return; } // drop rather than build a backlog
        moveInFlight = true;
      }
      var p = fetch('/input', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: body,
        keepalive: true,
        cache: 'no-store'
      });
      if (p && typeof p.then === 'function') {
        p.then(function () { if (isMove) { moveInFlight = false; } },
               function () { if (isMove) { moveInFlight = false; } });
      } else if (isMove) {
        moveInFlight = false;
      }
    } catch (e) {
      moveInFlight = false;
    }
  }

  // ---- image sizing: exact fit, so pointer mapping needs no letterbox maths --
  function stageSize() {
    var rect = stage.getBoundingClientRect();
    var w = rect.width || window.innerWidth;
    var h = rect.height || window.innerHeight;
    return { w: w, h: h };
  }
  function layout() {
    if (!streamWidth || !streamHeight) { return; }
    var size = stageSize();
    var vw = size.w, vh = size.h;
    var scale = Math.min(vw / streamWidth, vh / streamHeight);
    var width = Math.max(1, Math.floor(streamWidth * scale));
    var height = Math.max(1, Math.floor(streamHeight * scale));
    img.style.width = width + 'px';
    img.style.height = height + 'px';
  }
  window.addEventListener('resize', layout);
  window.addEventListener('orientationchange', function () { setTimeout(layout, 120); });
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', layout);
    window.visualViewport.addEventListener('scroll', layout);
  }
  setTimeout(layout, 300);

  // ---- pointer handling ------------------------------------------------------
  var pointers = {};        // pointerId -> {x, y}
  var pointerCount = 0;
  var dragging = false;
  var scrollMode = false;
  var lastCentroid = null;
  var pendingMove = null;
  var moveTimer = null;
  var lastMoveSent = 0;

  function normalized(ev) {
    var rect = img.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) { return null; }
    var x = (ev.clientX - rect.left) / rect.width;
    var y = (ev.clientY - rect.top) / rect.height;
    x = Math.min(1, Math.max(0, x));
    y = Math.min(1, Math.max(0, y));
    return { x: Math.round(x * 10000) / 10000, y: Math.round(y * 10000) / 10000 };
  }
  function centroid() {
    var sx = 0, sy = 0, n = 0;
    for (var id in pointers) {
      if (pointers.hasOwnProperty(id)) { sx += pointers[id].x; sy += pointers[id].y; n++; }
    }
    return n ? { x: sx / n, y: sy / n } : null;
  }
  function countPointers() {
    var n = 0;
    for (var id in pointers) { if (pointers.hasOwnProperty(id)) { n++; } }
    return n;
  }
  function flushMove() {
    moveTimer = null;
    if (!pendingMove) { return; }
    var move = pendingMove;
    pendingMove = null;
    lastMoveSent = (window.performance && performance.now) ? performance.now() : Date.now();
    post({ type: 'touch', action: 'move', x: move.x, y: move.y, pointerId: 0 });
  }
  function queueMove(x, y) {
    pendingMove = { x: x, y: y };
    var now = (window.performance && performance.now) ? performance.now() : Date.now();
    if (now - lastMoveSent >= 16) {
      flushMove();
    } else if (!moveTimer) {
      moveTimer = setTimeout(flushMove, Math.max(4, 16 - (now - lastMoveSent)));
    }
  }

  function onDown(ev) {
    if (ev.button !== undefined && ev.button !== 0 && ev.pointerType !== 'touch') { return; }
    autoFullscreenOnFirstGesture();
    hintEl.classList.add('hidden');
    try { img.setPointerCapture(ev.pointerId); } catch (e) {}
    pointers[ev.pointerId] = { x: ev.clientX, y: ev.clientY };
    pointerCount = countPointers();

    if (pointerCount >= 2) {
      // Second finger: switch from mouse to two-finger scrolling.
      if (dragging) {
        var last = normalized(ev);
        if (last) { post({ type: 'touch', action: 'up', x: last.x, y: last.y, pointerId: 0 }); }
        dragging = false;
      }
      pendingMove = null;
      scrollMode = true;
      lastCentroid = centroid();
      ev.preventDefault();
      return;
    }
    var point = normalized(ev);
    if (!point) { return; }
    dragging = true;
    post({ type: 'touch', action: 'down', x: point.x, y: point.y, pointerId: 0 });
    ev.preventDefault();
  }

  function onMove(ev) {
    if (!pointers.hasOwnProperty(ev.pointerId)) { return; }
    pointers[ev.pointerId] = { x: ev.clientX, y: ev.clientY };
    pointerCount = countPointers();

    if (scrollMode && pointerCount >= 2) {
      var center = centroid();
      if (center && lastCentroid) {
        var dx = Math.round((center.x - lastCentroid.x) * 6);
        var dy = Math.round((center.y - lastCentroid.y) * 6);
        if (dx !== 0 || dy !== 0) {
          post({ type: 'scroll', dx: -dx, dy: -dy });
        }
        lastCentroid = center;
      }
      ev.preventDefault();
      return;
    }
    if (!dragging) { return; } // hover moves do not move the Mac cursor
    var point = normalized(ev);
    if (!point) { return; }
    queueMove(point.x, point.y);
    ev.preventDefault();
  }

  function endPointer(ev, cancelled) {
    if (!pointers.hasOwnProperty(ev.pointerId)) { return; }
    delete pointers[ev.pointerId];
    pointerCount = countPointers();
    try { img.releasePointerCapture(ev.pointerId); } catch (e) {}

    if (scrollMode) {
      if (pointerCount >= 2) { lastCentroid = centroid(); return; }
      scrollMode = false;
      lastCentroid = null;
      return; // do not emit a click after a two-finger gesture
    }
    if (!dragging) { return; }
    flushMove();
    dragging = false;
    var point = normalized(ev);
    if (point && !cancelled) {
      post({ type: 'touch', action: 'up', x: point.x, y: point.y, pointerId: 0 });
    } else if (point) {
      post({ type: 'touch', action: 'cancel', x: point.x, y: point.y, pointerId: 0 });
    }
    ev.preventDefault();
  }

  img.addEventListener('pointerdown', onDown);
  img.addEventListener('pointermove', onMove);
  img.addEventListener('pointerup', function (ev) { endPointer(ev, false); });
  img.addEventListener('pointercancel', function (ev) { endPointer(ev, true); });
  img.addEventListener('lostpointercapture', function (ev) { endPointer(ev, true); });
  img.addEventListener('contextmenu', function (ev) { ev.preventDefault(); });
  img.addEventListener('dragstart', function (ev) { ev.preventDefault(); });

  // Mouse wheel / trackpad scrolling (desktop browsers)
  stage.addEventListener('wheel', function (ev) {
    ev.preventDefault();
    post({ type: 'scroll', dx: Math.round(ev.deltaX), dy: Math.round(ev.deltaY) });
  }, { passive: false });

  // Hardware keyboard: forward a small set of special keys when the text box is
  // not focused (useful with a Bluetooth keyboard attached to the tablet).
  var specialKeyMap = {
    'Enter': 'ENTER', 'Escape': 'ESC', 'Backspace': 'BACKSPACE', 'Tab': 'TAB',
    'Delete': 'FORWARD_DELETE', 'ArrowLeft': 'LEFT', 'ArrowRight': 'RIGHT',
    'ArrowUp': 'UP', 'ArrowDown': 'DOWN', ' ': 'SPACE'
  };
  document.addEventListener('keydown', function (ev) {
    if (document.activeElement === textEl) { return; }
    var mapped = specialKeyMap[ev.key];
    if (mapped) {
      ev.preventDefault();
      post({ type: 'key', action: 'tap', key: mapped });
    }
  });

  // ---- status polling -------------------------------------------------------
  function setState(text, cls) {
    stateEl.textContent = text;
    stateEl.className = cls || '';
  }
  function fetchStatus() {
    var started = (window.performance && performance.now) ? performance.now() : Date.now();
    fetch('/status', { cache: 'no-store' })
      .then(function (response) { return response.json(); })
      .then(function (data) {
        var latency = ((window.performance && performance.now) ? performance.now() : Date.now()) - started;
        lastStatusOk = Date.now();
        setState('已连接', 'ok');
        if (!streamRequested && data.width && data.height) {
          streamRequested = true;
          streamWidth = data.width;
          streamHeight = data.height;
          resEl.textContent = data.width + '×' + data.height;
          // Keep the MJPEG payload light: request at most 1600px wide. The image
          // is stretched to the fit rect so the pointer mapping stays linear.
          var requestWidth = Math.min(1600, data.width);
          var url = '/mjpg?w=' + requestWidth + '&fps=30&q=0.55';
          img.setAttribute('data-src', url);
          img.src = url + '&t=' + Date.now();
          layout();
        }
        var nativeStream = (data.transport === 'ready');
        var fpsValue = nativeStream ? (data.encodedFps || 0) : (data.mjpegFps || 0);
        var kbpsValue = nativeStream ? (data.kbps || 0) : (data.mjpegKbps || 0);
        fpsEl.textContent = 'fps ' + fpsValue.toFixed(1);
        kbpsEl.textContent = Math.round(kbpsValue) + ' kbps';
        rttEl.textContent = 'rtt ' + Math.round(latency) + 'ms' +
          (data.clients !== undefined ? ' · c' + data.clients : '');
      })
      .catch(function () {
        setState('未连接', 'bad');
      });
  }
  function statusLoop() {
    fetchStatus();
    statusTimer = setTimeout(statusLoop, 2000);
  }
  statusLoop();

  // ---- stream watchdog ------------------------------------------------------
  var loadCounter = 0, lastLoadTime = 0;
  img.addEventListener('load', function () {
    loadCounter++;
    lastLoadTime = Date.now();
    if (loadCounter === 1) {
      setState('画面已连接', 'ok');
      hintEl.textContent = '点击画面开始 · 单指拖动=鼠标 · 双指滑动=滚轮';
      setTimeout(function () { hintEl.classList.add('hidden'); }, 6000);
    }
  });
  img.addEventListener('error', function () {
    setState('重连中…', 'bad');
    reloadStream(800);
  });
  var reloadTimer = null;
  function reloadStream(delay) {
    if (reloadTimer) { return; }
    reloadTimer = setTimeout(function () {
      reloadTimer = null;
      var base = img.getAttribute('data-src') || '/mjpg';
      img.src = base + (base.indexOf('?') >= 0 ? '&' : '?') + 't=' + Date.now();
    }, delay || 300);
  }
  setInterval(function () {
    if (lastLoadTime && Date.now() - lastLoadTime > 5000) { reloadStream(100); }
  }, 4000);

  // Start with a default aspect ratio until /status reports the real one.
  streamWidth = 2800;
  streamHeight = 1848;
  resEl.textContent = streamWidth + '×' + streamHeight;
  layout();
  img.src = '/mjpg?w=1600&fps=30';
  img.setAttribute('data-src', '/mjpg?w=1600&fps=30');
})();
</script>
</body>
</html>
"""#
}
