/* Multi-tab web terminal frontend.
 *
 * One WebSocket multiplexes N PTY sessions (one per tab). Tab ids are persisted
 * in localStorage, and every (re)connect sends an "attach" for the whole tab
 * list: the server re-attaches to the same live shells and replays missed
 * output, so a page refresh does NOT kill your terminals.
 */
(function () {
  'use strict';

  var panes = document.getElementById('panes');
  var tabbar = document.getElementById('tabbar');
  var newTabBtn = document.getElementById('newtab');
  var statusEl = document.getElementById('status');
  var emptyHint = document.getElementById('empty-hint');
  var tabMoreBtn = document.getElementById('tabmore');
  var layoutSwEl = document.getElementById('layoutsw');
  var gridColsEl = document.getElementById('gridcols');
  var gridActsEl = document.getElementById('gridacts');
  var wallAllBtn = document.getElementById('wallall');
  var wallOneBtn = document.getElementById('wallone');
  var groupsEl = document.getElementById('groups');
  var gListEl = document.getElementById('g-list');
  var gCountEl = document.getElementById('g-count');

  var LS_KEY = 'webterm.tabs.v1';
  var ws = null;
  var tabSeq = 0;
  var tabs = new Map();        // id -> tab object
  var activeId = null;
  var outbox = [];             // messages queued while socket is not OPEN

  /* ---------------- persistence ---------------- */

  function loadStored() {
    try { return JSON.parse(localStorage.getItem(LS_KEY) || '[]') || []; }
    catch (e) { return []; }
  }

  function saveTabs() {
    var arr = [];
    tabs.forEach(function (t, id) {
      arr.push({ id: id, n: t.n, title: t.title, userTitled: t.userTitled, ocId: t.ocId || null });
    });
    try { localStorage.setItem(LS_KEY, JSON.stringify(arr)); } catch (e) { /* ignore */ }
  }

  /* ---------------- websocket ---------------- */

  function setStatus(text, ok) {
    statusEl.textContent = text;
    statusEl.className = ok ? 'ok' : '';
  }

  function sendMsg(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(obj));
    } else {
      outbox.push(obj);
    }
  }

  function flushOutbox() {
    while (outbox.length && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(outbox.shift()));
    }
  }

  function dimsOf(t) {
    var d = t.fit ? t.fit.proposeDimensions() : null;
    return d && d.cols > 1 && d.rows > 1 ? d : { cols: 80, rows: 24 };
  }

  /* ---------------- clipboard ---------------- */

  var toastEl = null, toastTimer = null;

  function toast(msg, sticky) {
    if (!toastEl) {
      toastEl = document.createElement('div');
      toastEl.id = 'toast';
      document.body.appendChild(toastEl);
    }
    toastEl.textContent = msg;
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    if (!sticky) {
      toastTimer = setTimeout(function () { toastEl.classList.remove('show'); }, 2000);
    }
  }

  // --- frame-atomic rendering ------------------------------------------------
  // opencode (and other TUIs) wrap each repaint in DECSET/DECRST 2026 so the
  // terminal cannot show a half-drawn frame. xterm.js ignores 2026 and our
  // transport delivers output in small time buckets, which downsamples
  // opencode's ~60fps scroll animation and can cut a frame in half. Hold the
  // bracketed region and write it as one piece.
  var SYNC_STUCK_MS = 500;

  function writeOutput(t, data) {
    if (!window.WTKeymap || !window.WTKeymap.syncWriter) { t.term.write(data); return; }
    if (!t.sync) { t.sync = window.WTKeymap.syncWriter(); }
    var ready = t.sync.feed(data);
    if (ready) { t.term.write(ready); }
    if (t.sync.isSyncing()) {
      if (!t._syncTimer) {
        t._syncTimer = setTimeout(function () {
          t._syncTimer = null;
          flushSync(t);                              // app died mid-frame: show it
        }, SYNC_STUCK_MS);
      }
    } else if (t._syncTimer) {
      clearTimeout(t._syncTimer);
      t._syncTimer = null;
    }
  }

  function flushSync(t) {
    if (t._syncTimer) { clearTimeout(t._syncTimer); t._syncTimer = null; }
    if (!t.sync) { return; }
    var out = t.sync.flush();
    if (out) { t.term.write(out); }
  }

  function resetSync(t) {
    if (t._syncTimer) { clearTimeout(t._syncTimer); t._syncTimer = null; }
    if (t.sync) { t.sync.flush(); }                  // screen is about to be cleared
    t.sync = window.WTKeymap && window.WTKeymap.syncWriter
      ? window.WTKeymap.syncWriter() : null;
  }

  // xterm.js does not implement OSC 52, but TUI apps (opencode's "copy message",
  // copy-on-select, /btw "press C") use it to put text in the system clipboard.
  function handleOsc52(t, data) {
    if (!window.WTKeymap || !window.WTKeymap.osc52Extract) return;
    if (data.indexOf('\x1b]52;') === -1 && !t._oscPending) return;
    var res = window.WTKeymap.osc52Extract((t._oscPending || '') + data);
    t._oscPending = res.rest;
    res.events.forEach(function (e) {
      if (e.selector === '?') return;                 // query form: never answered
      if (!e.text) return;
      copyText(e.text, 'OSC 52');
    });
  }

  // navigator.clipboard needs a secure context (https or localhost). This app is
  // commonly served over plain http on an IP, so keep an execCommand fallback.
  function copyText(text, source) {
    if (!text) { toast('没有选中内容'); return; }
    var label = '已复制 ' + text.length + ' 字符' + (source ? '（' + source + '）' : '');
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () {
        toast(label);
      }).catch(function () { legacyCopy(text, label); });
    } else {
      legacyCopy(text, label);
    }
  }

  function legacyCopy(text, label) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.cssText = 'position:fixed;top:-1000px;left:-1000px;opacity:0';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    if (ok) { toast(label); }
    else { toast('复制被浏览器拦截：启用 HTTPS 后即可直接复制'); }
  }

  // xterm clears its selection on real input and dismisses it while the app
  // repaints (TUI alt-screen), so re-assert it right after selecting.
  function selectAllSticky(t) {
    function apply() {
      t.term.selectAll();
      t.term.focus();
    }
    apply();
    setTimeout(function () { if (!t.term.hasSelection()) apply(); }, 60);
    setTimeout(function () { if (!t.term.hasSelection()) apply(); }, 250);
  }

  /* ---------------- image upload -> opencode attachment ---------------- */
  // The browser streams the file to the backend (base64 chunks) which stores it
  // inside the opencode project directory; we then "type" "@<relative path>"
  // into the PTY, and opencode's own "@" completion turns it into an attachment.
  // Verified: typing the mention key-by-key + Enter attaches the image (a bulk
  // write is treated as a paste and stays literal text instead).
  var UP_CHUNK = 96 * 1024;      // bytes per frame (base64 stays well under 8MB)
  var UP_TYPE_DELAY = 22;        // ms between injected keystrokes
  var UP_SELECT_DELAY = 1400;    // let opencode's "@" file search settle
  var UP_MAX = 20 * 1024 * 1024;

  var upInput = null;
  var upTarget = null;

  function openImagePicker(id) {
    if (!upInput) {
      upInput = document.createElement('input');
      upInput.type = 'file';
      upInput.accept = 'image/*';
      upInput.style.display = 'none';
      document.body.appendChild(upInput);
      upInput.addEventListener('change', function () {
        var f = upInput.files && upInput.files[0];
        var id = upTarget;
        upInput.value = '';
        if (f && id) uploadImage(id, f);
      });
    }
    upTarget = id;
    upInput.value = '';
    upInput.click();
  }

  function b64encode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 0x8000) {
      out += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(out);
  }

  function uploadImage(id, file) {
    var t = tabs.get(id);
    if (!t || !t.alive) { toast('这个标签已经结束了'); return; }
    if (!file || !/^image\//.test(file.type || '')) { toast('只能上传图片文件'); return; }
    if (file.size > UP_MAX) { toast('图片太大：上限 ' + (UP_MAX / 1024 / 1024) + 'MB'); return; }
    if (t.attaching) { toast('正在附加上一张图片，请稍候…'); return; }
    if (!file.size) { toast('这个文件是空的'); return; }

    var upid = 'u' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
    var seq = 0, offset = 0;
    toast('正在上传 ' + (file.name || '图片') + ' …', true);

    function step() {
      var end = Math.min(offset + UP_CHUNK, file.size);
      var reader = new FileReader();
      reader.onerror = function () { toast('读取文件失败'); };
      reader.onload = function () {
        var last = end >= file.size;
        sendMsg({
          type: 'upload', id: id, upid: upid, name: file.name || 'image.png',
          mime: file.type, seq: seq++, last: last,
          data: b64encode(new Uint8Array(reader.result))
        });
        offset = end;
        if (last) { toast('正在附加到 opencode…', true); } else { step(); }
      };
      reader.readAsArrayBuffer(file.slice(offset, end));
    }
    step();
  }

  // Any full-screen TUI (opencode included) switches to the alternate buffer;
  // typing "@path" into a plain shell would run it as a command instead.
  function inFullScreenApp(t) {
    var b = t.term.buffer && t.term.buffer.active;
    return !!(b && b.type === 'alternate');
  }

  function setBusy(t, on) {
    t.attaching = on;
    if (t.upBtn) t.upBtn.classList.toggle('busy', !!on);
  }

  // Type "@<path>" one character at a time so opencode treats it as keystrokes
  // (a bulk write looks like a paste and is never offered as a file mention).
  function attachImage(t, id, rel, name) {
    var text = ' @' + rel;
    var i = 0;
    if (t.attaching) { toast('上一张图片还在附加中，这张已保存：' + rel, true); return; }
    setBusy(t, true);
    (function type() {
      if (!tabs.has(id)) { setBusy(t, false); return; }
      if (i < text.length) {
        sendMsg({ type: 'input', id: id, data: text.charAt(i++) });
        setTimeout(type, UP_TYPE_DELAY);
        return;
      }
      setTimeout(function () {
        if (!tabs.has(id)) { setBusy(t, false); return; }
        sendMsg({ type: 'input', id: id, data: '\r' });   // accept the match
        setBusy(t, false);
        t.term.focus();
        toast('图片已附加到 opencode 输入框：' + name + ' — 直接输入问题再回车发送');
      }, UP_SELECT_DELAY);
    })();
  }

  function finishUpload(m) {
    var t = tabs.get(m.id);
    var name = m.name || '图片';
    if (!t || !t.alive) { toast('图片已保存：' + (m.rel || m.path)); return; }
    t.term.focus();
    if (!inFullScreenApp(t)) {
      toast('图片已保存到 ' + m.rel + '（当前标签没有运行 opencode，未自动附加）', true);
      return;
    }
    attachImage(t, m.id, m.rel, name);
  }

  function pasteInto(t, id) {    t.term.focus();
    if (navigator.clipboard && window.isSecureContext && navigator.clipboard.readText) {
      navigator.clipboard.readText().then(function (text) {
        if (text && t.alive) sendMsg({ type: 'input', id: id, data: text });
      }).catch(function () { toast('读取剪贴板被拒绝，请按 Ctrl+V 粘贴'); });
    } else {
      toast('请按 Ctrl+V 粘贴（启用 HTTPS 后可直接点此粘贴）');
    }
  }

  /* ---------------- right-click menu ---------------- */

  var menuEl = null;

  function hideMenu() { if (menuEl) menuEl.style.display = 'none'; }

  function ensureMenu() {
    if (menuEl) return;
    menuEl = document.createElement('div');
    menuEl.className = 'ctxmenu';
    document.body.appendChild(menuEl);
    document.addEventListener('click', hideMenu);
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') hideMenu(); });
    window.addEventListener('blur', hideMenu);
  }

  // items: [label, handler, extraClass] — a label of '-' draws a separator.
  function openMenu(x, y, items) {
    ensureMenu();
    menuEl.innerHTML = '';
    items.forEach(function (it) {
      if (it[0] === '-') {
        var sep = document.createElement('div');
        sep.className = 'sep';
        menuEl.appendChild(sep);
        return;
      }
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = it[0];
      if (it[2]) b.classList.add(it[2]);
      // Keep focus in the terminal: a focused button would make xterm render the
      // selection in its "inactive" style and steal keyboard input.
      b.addEventListener('mousedown', function (e) { e.preventDefault(); });
      b.addEventListener('click', function (e) { e.stopPropagation(); hideMenu(); it[1](); });
      menuEl.appendChild(b);
    });
    menuEl.style.display = 'block';
    menuEl.style.left = Math.max(4, Math.min(x, window.innerWidth - menuEl.offsetWidth - 8)) + 'px';
    menuEl.style.top = Math.max(4, Math.min(y, window.innerHeight - menuEl.offsetHeight - 8)) + 'px';
  }

  function showMenu(x, y, id) {
    var t = tabs.get(id);
    if (!t) return;
    openMenu(x, y, [
      ['复制', function () {
        var sel = t.term.getSelection();
        if (!sel) { toast('没有选中内容：拖选文本（TUI 里按住 Shift 再拖选）'); return; }
        copyText(sel);
      }],
      ['复制全部输出', function () {
        // Deterministic: reads the scrollback buffer directly, so it does not
        // depend on a selection highlight surviving mouse/TUI redraws.
        var text = (window.WTKeymap && window.WTKeymap.bufferText)
          ? window.WTKeymap.bufferText(t.term.buffer && t.term.buffer.active)
          : '';
        if (!text) { toast('终端还没有内容'); return; }
        copyText(text);
      }],
      ['粘贴', function () { pasteInto(t, id); }],
      ['上传图片并附加…', function () { activate(id); openImagePicker(id); }],
      ['全选', function () { selectAllSticky(t); }],
      ['清屏', function () { t.term.clear(); }],
      '-'
    ].concat(gridMenuItems(id)).concat(splitMenuItems(id)));
  }

  function attachAll() {
    if (!tabs.size) return;
    var sessions = [];
    tabs.forEach(function (t, id) {
      var d = dimsOf(t);
      sessions.push({ id: id, cols: d.cols, rows: d.rows });
    });
    sendMsg({ type: 'attach', sessions: sessions });
  }

  var connectFails = 0;

  function connect() {
    var proto = location.protocol === 'https:' ? 'wss' : 'ws';
    var everOpened = false;
    // ws 基址跟随页面所在目录: 子目录部署(如 /terminal/)时连 /terminal/ws,
    // 根路径部署时 base 恰为 '/',保持原有行为。
    var base = location.pathname.replace(/[^/]*$/, '');
    ws = new WebSocket(proto + '://' + location.host + base + 'ws');

    ws.onopen = function () {
      everOpened = true;
      connectFails = 0;
      setStatus('已连接', true);
      flushOutbox();
      attachAll();                                   // re-attach every tab
      requestCwds();                                 // keep 分组's directory map warm
    };

    ws.onclose = function () {
      // never opened => almost always auth failure (401 from basic auth)
      connectFails = everOpened ? 0 : connectFails + 1;
      if (!everOpened && connectFails >= 2) {
        setStatus('认证失败或被拒绝 — 请刷新页面重新登录', false);
      } else {
        setStatus('已断开，3 秒后重连…', false);
      }
      setTimeout(connect, 3000);                     // shells survive; we re-attach
    };

    ws.onerror = function () { setStatus('连接异常', false); };

    ws.onmessage = function (ev) {
      var m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.type === 'pong' || m.type === 'sessions') return;
      if (m.type === 'opencode_sessions') {           // left navigation payload
        navState.bin = m.bin || navState.bin;
        renderSessions(m.items || [], m.error || '');
        return;
      }
      if (m.type === 'opencode_session_deleted') {    // result of a nav delete
        if (m.ok) {
          toast('已删除会话 ' + m.session);
          var live = tabForSession(m.session);
          if (live) closeTab(live.id);                // as promised in the dialog
          requestSessions(true);
        } else {
          navStatusEl.textContent = '删除失败：' + (m.error || '未知错误');
          toast('删除失败：' + (m.error || '未知错误'));
        }
        return;
      }
      if (m.type === 'cwds') {                        // 分组: where each shell is
        applyCwds(m.items || {}, m.home || '');
        return;
      }
      if (m.type === 'upload_done') {                 // image stored on the server
        finishUpload(m);
        return;
      }
      if (m.type === 'upload_error') {
        var bad = tabs.get(m.id);
        if (bad) setBusy(bad, false);
        toast('上传失败：' + (m.error || '未知错误'));
        return;
      }
      var t = tabs.get(m.id);
      if (!t) return;

      switch (m.type) {
        case 'reset':                                  // replay starts: clear screen
          resetSync(t);                                // drop any half-received frame
          t.term.reset();
          break;
        case 'output':
          if (t.pendingCmd) {                          // resumed session: shell is up
            var pc = t.pendingCmd; t.pendingCmd = null;
            sendMsg({ type: 'input', id: m.id, data: pc + '\n' });
          }
          handleOsc52(t, m.data);   // OSC 52 -> real clipboard (xterm ignores it)
          writeOutput(t, m.data);   // 2026-aware: render each repaint atomically
          matchTitle(m.id, m.data);
          break;
        case 'attached':
          t.alive = true;
          t.tabEl.classList.remove('dead');
          break;
        case 'exit':
          flushSync(t);                                // show anything still held
          t.term.write('\r\n\x1b[38;5;203m[会话已结束]\x1b[0m\r\n');
          t.alive = false;
          t.tabEl.classList.add('dead');
          break;
      }
    };
  }

  // OSC 0 (window title): ESC ] 0 ; title BEL|ST  -> use as tab label
  var OSC_RE = /\x1b\]0;([^\x07\x1b]*)(\x07|\x1b\\)/;
  function matchTitle(id, data) {
    var t = tabs.get(id);
    if (!t || t.userTitled) return;
    var i = data.lastIndexOf('\x1b]0;');
    if (i === -1) return;
    var m = OSC_RE.exec(data.slice(i));
    if (m && m[1].trim()) {
      t.title = m[1].trim();
      t.labelEl.textContent = t.title;
      saveTabs();
      scheduleTabbar();                     // the label width changed
    }
  }

  function scheduleResize(id) {
    var t = tabs.get(id);
    if (!t || !t.alive) return;
    clearTimeout(t._rt);
    t._rt = setTimeout(function () {
      var d = dimsOf(t);
      sendMsg({ type: 'resize', id: id, cols: d.cols, rows: d.rows });
    }, 60);
  }

  /* ---------------- tabs ---------------- */

  var lastId = null;

  function createTab(opts) {
    opts = opts || {};
    if (emptyHint) emptyHint.style.display = 'none';

    var id = opts.id || ('t' + Date.now().toString(36) + '_' + Math.random().toString(36).slice(2, 7));
    var n = opts.n || (++tabSeq);
    if (n > tabSeq) tabSeq = n;

    // show the new pane first: xterm needs a visible element to measure itself
    tabs.forEach(function (t) { t.pane.classList.remove('active'); });
    var pane = document.createElement('div');
    pane.className = 'pane on';                      // ".on" = visible; activate() fixes visibility after
    pane.dataset.tid = id;                           // lets tab drag map a pane element back to its tab

    var tools = document.createElement('div');
    tools.className = 'pane-tools';
    // This pane's own tab, sitting right above the terminal: in 宫格 / 分屏 you can
    // see at a glance which terminal is which.  It is clickable (focus) and
    // draggable (same gesture as the strip tab: re-order / go on the wall).
    var paneTab = document.createElement('span');
    paneTab.className = 'pane-tab';
    var paneDot = document.createElement('span'); paneDot.className = 'dot';
    var paneLabel = document.createElement('span'); paneLabel.className = 'plabel';
    paneTab.append(paneDot, paneLabel);
    paneTab.addEventListener('click', function (e) { e.stopPropagation(); activate(id); });
    tools.appendChild(paneTab);
    var splitBtn = document.createElement('button');
    splitBtn.type = 'button';
    splitBtn.className = 'pane-tool split-tool';    // hidden in 宫格 / 分组 layouts
    splitBtn.textContent = '◫ 分屏';
    splitBtn.title = '把这块区域一分为二（也可右键终端选方向，或把标签拖到某个面板的边缘）';
    splitBtn.addEventListener('mousedown', function (e) { e.preventDefault(); });
    splitBtn.addEventListener('click', function (e) {
      e.preventDefault();
      activate(id);
      var r = splitBtn.getBoundingClientRect();
      openMenu(r.left, r.bottom + 6, splitMenuItems(id));
    });
    tools.appendChild(splitBtn);
    var upBtn = document.createElement('button');
    upBtn.type = 'button';
    upBtn.className = 'pane-tool';
    upBtn.textContent = '🖼 上传图片';
    upBtn.title = '上传一张图片并附加到 opencode 输入框（也可把图片拖到终端，或 Ctrl+V 粘贴图片）';
    upBtn.addEventListener('mousedown', function (e) { e.preventDefault(); });
    upBtn.addEventListener('click', function (e) {
      e.preventDefault();
      activate(id);
      openImagePicker(id);
    });
    tools.appendChild(upBtn);
    var wallBtn = document.createElement('button');
    wallBtn.type = 'button';
    wallBtn.className = 'pane-tool wall-tool';      // only shown in 宫格
    wallBtn.textContent = '✕ 移出';
    wallBtn.title = '把这个终端从宫格里移出（终端本身不关闭，仍在标签栏里，拖回来即可重新上墙）';
    wallBtn.addEventListener('mousedown', function (e) { e.preventDefault(); });
    wallBtn.addEventListener('click', function (e) {
      e.preventDefault();
      wallRemove(id);
    });
    tools.appendChild(wallBtn);

    var host = document.createElement('div');
    host.className = 'pane-term';
    pane.append(tools, host);
    panes.appendChild(pane);

    var tabEl = document.createElement('div');
    tabEl.className = 'tab';
    tabEl.dataset.tid = id;                        // tab drag maps a strip element back to its tab
    var dot = document.createElement('span'); dot.className = 'dot';
    var label = document.createElement('span'); label.className = 'label';
    label.textContent = (opts.title && !opts.userTitled) ? opts.title : ('Tab ' + n);
    paneLabel.textContent = label.textContent;           // same text above the pane
    var close = document.createElement('span'); close.className = 'close'; close.textContent = '×';
    close.title = '关闭终端';
    tabEl.append(dot, label, close);

    var t = {
      term: null, fit: null, pane: pane, tabEl: tabEl, labelEl: label,
      paneTabEl: paneTab, paneLabelEl: paneLabel,
      n: n, alive: true, title: opts.title || '', userTitled: !!opts.userTitled,
      ocId: opts.ocId || null, _rt: null, upBtn: upBtn, attaching: false,
      cwd: '',                                        // filled in by the server
      gkey: (layoutMode === 'grouped') ? curGroup : '' // 分组: until cwd is known
    };
    tabEl.addEventListener('click', function (e) { if (e.target !== close) activate(id); });
    close.addEventListener('click', function (e) { e.stopPropagation(); closeTab(id); });
    tabbar.insertBefore(tabEl, tabMoreBtn);
    wireTabDrag(t.tabEl, t, id, close);                    // drag from the strip tab
    wireTabDrag(paneTab, t, id, null);                     // …or from the tab above the pane

    // clicking anywhere inside a pane focuses it (matters in split view)
    pane.addEventListener('mousedown', function () {
      if (activeId !== id && tabs.has(id)) activate(id);
    }, true);

    var term = new Terminal({
      fontFamily: 'Menlo, Consolas, "DejaVu Sans Mono", monospace',
      fontSize: 14,
      cursorBlink: true,
      scrollback: 5000,
      theme: {
        background: '#12141a',
        foreground: '#e6e6e6',
        cursor: '#19a97b',
        selectionBackground: '#3b4a6b',
        // must be set explicitly: the inactive colour is what you see whenever the
        // terminal is not focused (e.g. right after clicking a menu item)
        selectionInactiveBackground: '#2c3852',
        selectionForeground: '#ffffff'
      }
    });
    var fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open(host);
    try { fit.fit(); } catch (e) { /* ignore */ }

    t.term = term;
    t.fit = fit;

    term.onData(function (d) {
      if (t.alive) sendMsg({ type: 'input', id: id, data: d });
    });
    term.onResize(function (s) {
      if (t.alive) sendMsg({ type: 'resize', id: id, cols: s.cols, rows: s.rows });
    });
    term.attachCustomKeyEventHandler(function (ev) {
      if (ev.type !== 'keydown') return true;
      if (ev.altKey && (ev.key === 'w' || ev.key === 'W')) { closeTab(id); return false; }
      if (handleLayoutKey(ev)) return false;         // Alt+L / Alt+1..9 stay here
      var action = (window.WTKeymap && window.WTKeymap.decide)
        ? window.WTKeymap.decide(ev, term.hasSelection())
        : null;
      if (action === 'copy') {
        copyText(term.getSelection());
        // plain Ctrl+C only: drop the selection so a second press reaches the app
        // (opencode uses ctrl+c for prompt.clear / app.exit)
        if (ev.ctrlKey && !ev.shiftKey) { term.clearSelection(); }
        return false;
      }
      if (action === 'select-all') { selectAllSticky(t); return false; }
      return true;   // paste & everything else: handled by xterm / browser
    });

    // xterm renders its selection without a DOM selection, so the browser's own
    // context menu cannot copy it: provide our own.
    pane.addEventListener('contextmenu', function (e) {
      e.preventDefault();
      e.stopPropagation();
      showMenu(e.clientX, e.clientY, id);
    });

    // Drag an image from the desktop onto the terminal (or paste one).
    pane.addEventListener('dragover', function (e) {
      if (!e.dataTransfer) return;
      e.preventDefault();                              // required to accept a drop
      e.dataTransfer.dropEffect = 'copy';
      pane.classList.add('dragover');
    });
    pane.addEventListener('dragleave', function (e) {
      if (!pane.contains(e.relatedTarget)) pane.classList.remove('dragover');
    });
    pane.addEventListener('drop', function (e) {
      e.preventDefault();
      pane.classList.remove('dragover');
      var f = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
      if (f) { activate(id); uploadImage(id, f); }
    });

    // Capture phase: run before xterm's own paste handler, and only when the
    // clipboard actually holds an image (plain text keeps working as before).
    pane.addEventListener('paste', function (e) {
      var items = (e.clipboardData && e.clipboardData.items) || [];
      for (var i = 0; i < items.length; i++) {
        if (items[i].type && items[i].type.indexOf('image/') === 0) {
          var f = items[i].getAsFile();
          if (f) {
            e.preventDefault();
            e.stopPropagation();
            uploadImage(id, f);
          }
          return;
        }
      }
    }, true);

    tabs.set(id, t);

    if (opts.restore) {
      // restored from localStorage: pending until the server answers "attach"
      t.term.write('\x1b[38;5;244m正在恢复会话…\x1b[0m\r\n');
    } else {
      var d = dimsOf(t);
      sendMsg({ type: 'create', id: id, cmd: 'bash', cols: d.cols, rows: d.rows });
    }
    saveTabs();
    if (opts.quiet) {
      // caller (split layout) places & activates this pane itself
    } else {
      activate(id);
      term.focus();
    }
    if (layoutMode === 'grouped') { renderGroups(); requestCwds(); }
    scheduleTabbar();
    return id;
  }

  window.newTab = function () { return createTabSmart(); };

  function activate(id) {
    var t = tabs.get(id);
    if (!t) return;
    wallEnsure(id);                            // 宫格: whatever you focus must be visible
    if (layoutMode === 'tabs' && layoutTree && !treeHas(layoutTree, id)) {
      // split view: the tab is not on stage — show it in place of the focused
      // (or first) pane; the pane it replaces stays alive as a normal tab
      var anchor = (activeId && tabs.has(activeId) && treeHas(layoutTree, activeId))
        ? activeId : treeLeaves(layoutTree)[0];
      if (anchor && anchor !== id) {
        layoutTree = treeSwap(layoutTree, anchor, id);
        saveLayout();
      }
    }
    activeId = id;
    if (layoutMode === 'grouped') {            // following a tab follows its group
      curGroup = groupKeyOf(id);
      groupFocus[curGroup] = id;
      syncGroupsActive();
    }
    tabs.forEach(function (tt, tid) {
      tt.pane.classList.toggle('active', tid === id);
      tt.tabEl.classList.toggle('active', tid === id);
      if (tt.paneTabEl) tt.paneTabEl.classList.toggle('active', tid === id);
    });
    if (layoutMode !== 'tabs' || !layoutTree) {
      syncPaneVisibility();                    // single / grid / grouped: focus decides
    } else {
      refitVisibleSoon();                      // a swapped-in pane may need re-measuring
    }
    scheduleTabbar();                          // the focused tab must stay in the strip
    saveLayout();                              // remember focus across refreshes too
    requestAnimationFrame(function () {
      var ct = tabs.get(id);
      if (ct && activeId === id && ct.term) ct.term.focus();
    });
  }

  function closeTab(id) {
    var t = tabs.get(id);
    if (!t) return;
    var wasActive = (activeId === id);
    if (layoutTree) {
      layoutTree = normTree(treeRemove(layoutTree, id));
      saveLayout();
    }
    sendMsg({ type: 'close', id: id });
    try { t.term.dispose(); } catch (e) { /* ignore */ }
    t.pane.remove();
    t.tabEl.remove();
    tabs.delete(id);
    if (layoutMode === 'grid') {               // 宫格: a closed terminal leaves the wall
      var wi = gridWall.indexOf(id);
      if (wi >= 0) { gridWall.splice(wi, 1); saveWall(); }
    }
    if (wasActive) activeId = null;
    saveTabs();
    renderLayout();                            // rebuild split boxes / pane visibility
    syncNavActive();

    if (tabs.size === 0) {
      layoutTree = null;                       // nothing left to tile
      if (emptyHint) emptyHint.style.display = 'flex';
      return;
    }
    if (wasActive) {
      var next = null;
      if (layoutMode === 'grouped') {          // stay inside the group we were in
        var ids = tabbarIds();
        var back = groupFocus[curGroup];
        next = (back && tabs.has(back)) ? back : (ids[0] || null);
      }
      if (!next) tabs.forEach(function (_, tid) { next = tid; });
      if (next) activate(next);
    }
  }

  /* ---------------- split layout: draggable tiling of panes ----------------
   *
   * A binary tree of panes:  leaf = tab id (string)
   *                          node = { d: 'row'|'col', r: share of "a", a: node, b: node }
   * layoutTree === null  ->  single-pane mode (exactly the old tab behaviour).
   * Every operation keeps the invariant "root is never a bare leaf"; a tree that
   * shrinks to one leaf collapses back into single-pane mode.
   */

  var LAYOUT_KEY = 'webterm.layout.v1';
  var SPLIT_MIN = 0.15;                        // each side keeps at least 15% of the box
  var MAX_SPLIT = 6;                           // hard cap on visible panes
  var SIDE_LABEL = { left: '左侧', right: '右侧', top: '上方', bottom: '下方' };

  var layoutTree = null;

  function normTree(n) { return (n && typeof n === 'string') ? null : n; }

  function treeLeaves(n, out) {
    out = out || [];
    if (typeof n === 'string') out.push(n);
    else if (n) { treeLeaves(n.a, out); treeLeaves(n.b, out); }
    return out;
  }

  function treeHas(n, id) {
    if (typeof n === 'string') return n === id;
    if (!n) return false;
    return treeHas(n.a, id) || treeHas(n.b, id);
  }

  function treeInsert(n, targetId, newId, side) {
    if (typeof n === 'string') {
      if (n !== targetId) return n;
      if (side === 'left')   return { d: 'row', r: 0.5, a: newId,    b: targetId };
      if (side === 'top')    return { d: 'col', r: 0.5, a: newId,    b: targetId };
      if (side === 'bottom') return { d: 'col', r: 0.5, a: targetId, b: newId };
      return                        { d: 'row', r: 0.5, a: targetId, b: newId };
    }
    return { d: n.d, r: n.r,
             a: treeInsert(n.a, targetId, newId, side),
             b: treeInsert(n.b, targetId, newId, side) };
  }

  function treeRemove(n, id) {
    if (typeof n === 'string') return n === id ? null : n;
    var a = treeRemove(n.a, id);
    var b = treeRemove(n.b, id);
    if (a && b) return { d: n.d, r: n.r, a: a, b: b };
    return a || b;                             // one child vanished: collapse
  }

  function treeSwap(n, oldId, newId) {
    if (typeof n === 'string') return n === oldId ? newId : n;
    return { d: n.d, r: n.r, a: treeSwap(n.a, oldId, newId), b: treeSwap(n.b, oldId, newId) };
  }

  function treeValid(n) {
    if (typeof n === 'string') return n.length > 0;
    if (!n || typeof n !== 'object') return false;
    if ((n.d !== 'row' && n.d !== 'col') || typeof n.r !== 'number') return false;
    if (!(n.r >= 0.05 && n.r <= 0.95)) return false;
    return treeValid(n.a) && treeValid(n.b);
  }

  function setGrow(el, r) {
    r = Math.min(0.98, Math.max(0.02, r));
    el.style.flexGrow = String(Math.round(r * 1000));
    el.style.flexBasis = '0';
    el.style.flexShrink = '1';
  }

  function buildSplitDOM(n) {
    if (typeof n === 'string') {
      var t = tabs.get(n);
      return t ? t.pane : document.createElement('div');
    }
    var box = document.createElement('div');
    box.className = 'split ' + (n.d === 'col' ? 's-col' : 's-row');
    var aEl = buildSplitDOM(n.a);
    var div = document.createElement('div');
    div.className = 'divider ' + (n.d === 'col' ? 'd-col' : 'd-row');
    div.title = '拖动调整两侧大小（仅本机显示，不改终端列数比例）';
    wireDivider(div, n);
    var bEl = buildSplitDOM(n.b);
    setGrow(aEl, n.r);
    setGrow(bEl, 1 - n.r);
    box.appendChild(aEl);
    box.appendChild(div);
    box.appendChild(bEl);
    return box;
  }

  function renderLayout() {
    // pull panes out of stale split boxes first, then drop the boxes
    tabs.forEach(function (t) {
      if (t.pane.parentNode !== panes) panes.appendChild(t.pane);
    });
    Array.prototype.slice.call(panes.children).forEach(function (el) {
      if (el.classList && el.classList.contains('split')) el.remove();
    });
    tabs.forEach(function (t) {
      t.pane.classList.remove('in-split');
      t.pane.classList.remove('droptgt', 'dz-left', 'dz-right', 'dz-top', 'dz-bottom', 'dz-center');
      t.pane.style.flexGrow = '';
      t.pane.style.flexBasis = '';
      t.pane.style.flexShrink = '';
    });
    panes.classList.toggle('grid-mode', layoutMode === 'grid');
    panes.classList.toggle('group-mode', layoutMode === 'grouped');
    if (layoutMode === 'grid') applyGrid();
    else if (layoutMode === 'tabs' && layoutTree) panes.appendChild(buildSplitDOM(layoutTree));
    orderPanes();
    // Entering 分组 (or closing the last tab of the selected group) must never
    // leave the stage showing a terminal from another group.
    if (layoutMode === 'grouped') { renderGroups(); syncGroupSelection(); }
    syncPaneVisibility();
    scheduleTabbar();
  }

  // DOM order = tab order (unless a split tree already owns the panes).
  function orderPanes() {
    if (layoutMode === 'tabs' && layoutTree) return;
    if (layoutMode === 'grid') {                       // wall order, not tab order
      sanitizeWall().forEach(function (id) {
        var t = tabs.get(id);
        if (t) panes.appendChild(t.pane);
      });
      return;
    }
    tabs.forEach(function (t) { panes.appendChild(t.pane); });
  }

  // Which panes should be on screen right now.
  function visibleIds() {
    var on = Object.create(null);
    if (!tabs.size) return on;
    if (layoutMode === 'grid') {                       // only what is on the wall
      sanitizeWall().forEach(function (id) { if (tabs.has(id)) on[id] = true; });
      return on;
    }
    if (layoutMode === 'grouped') {                    // one terminal per group
      if (activeId && tabs.has(activeId)) on[activeId] = true;
      return on;
    }
    if (layoutTree) treeLeaves(layoutTree).forEach(function (lid) { on[lid] = true; });
    else if (activeId) on[activeId] = true;
    return on;
  }

  function syncPaneVisibility() {
    var on = visibleIds();
    var tiled = (layoutMode === 'tabs' && !!layoutTree);
    tabs.forEach(function (t, id) {
      var shown = !!on[id];
      t.pane.classList.toggle('on', shown);
      t.pane.classList.toggle('in-split', !!(tiled && shown));
      t.tabEl.classList.toggle('offstage', !!(tiled && !shown));
      if (!shown) {
        t.pane.style.flexGrow = '';
        t.pane.style.flexBasis = '';
        t.pane.style.flexShrink = '';
      }
    });
    if (tiled && (!activeId || !on[activeId])) {
      // focus fell off stage (e.g. its pane was removed): promote the first one
      var first = treeLeaves(layoutTree)[0];
      if (first && tabs.has(first)) { activeId = null; activate(first); return; }
    }
    refitVisible();                                    // skips panes without ".on"
  }

  var fitRaf = 0;

  function refitVisible() {
    fitRaf = 0;
    tabs.forEach(function (t, id) {
      if (!t.pane.classList.contains('on')) return;  // hidden panes cannot be measured
      try { t.fit.fit(); } catch (e) { /* ignore */ }
      scheduleResize(id);
    });
  }

  function refitVisibleSoon() {
    if (fitRaf) return;
    fitRaf = requestAnimationFrame(refitVisible);
  }

  function saveLayout() {
    try {
      localStorage.setItem(LAYOUT_KEY, JSON.stringify({ v: 1, tree: layoutTree, focus: activeId }));
    } catch (e) { /* ignore */ }
  }

  function loadLayoutRaw() {
    try { return JSON.parse(localStorage.getItem(LAYOUT_KEY) || 'null'); }
    catch (e) { return null; }
  }

  function applyStoredLayout(data) {
    if (!data || !data.tree || typeof data.tree === 'string' || !treeValid(data.tree)) return false;
    var leaves = treeLeaves(data.tree);
    if (leaves.length < 2 || leaves.length > MAX_SPLIT) return false;
    var seen = Object.create(null);
    for (var i = 0; i < leaves.length; i++) {
      if (!tabs.has(leaves[i]) || seen[leaves[i]]) return false;
      seen[leaves[i]] = 1;
    }
    layoutTree = data.tree;
    renderLayout();
    var fid = (data.focus && tabs.has(data.focus) && treeHas(layoutTree, data.focus))
      ? data.focus : leaves[0];
    activate(fid);
    return true;
  }

  function splitPane(id, side) {
    var t = tabs.get(id);
    if (!t) return;
    if (!t.alive) { toast('这个标签已经结束了'); return; }
    if (treeLeaves(layoutTree || id).length >= MAX_SPLIT) { toast('最多同屏 ' + MAX_SPLIT + ' 个终端'); return; }
    var nid = createTab({ quiet: true });
    layoutTree = treeInsert(layoutTree || id, id, nid, side);
    saveLayout();
    renderLayout();
    activate(nid);
    toast('已分屏（' + SIDE_LABEL[side] + '）：新终端已就位');
  }

  function movePane(id, targetId, side) {
    if (!tabs.has(id) || !tabs.has(targetId) || id === targetId) return;
    if (treeLeaves(layoutTree || targetId).length >= MAX_SPLIT) { toast('最多同屏 ' + MAX_SPLIT + ' 个终端'); return; }
    var tree = layoutTree || targetId;
    if (treeHas(tree, id)) tree = treeRemove(tree, id) || targetId;
    layoutTree = treeInsert(tree, targetId, id, side);
    saveLayout();
    renderLayout();
    activate(id);
    var label = tabs.get(id) ? tabs.get(id).labelEl.textContent : '';
    toast('已把「' + (label || '终端') + '」放到' + SIDE_LABEL[side]);
  }

  function unsplitPane(id) {
    if (!layoutTree || !tabs.has(id)) return;
    if (treeLeaves(layoutTree).length <= 1) {
      layoutTree = null;
    } else {
      layoutTree = normTree(treeRemove(layoutTree, id));
    }
    saveLayout();
    renderLayout();
    toast('已移出分屏：该终端回到标签栏');
    if (activeId === id) {
      var alt = null;
      if (layoutTree) alt = treeLeaves(layoutTree)[0];
      if (!alt) tabs.forEach(function (_, tid) { if (!alt && tid !== id) alt = tid; });
      if (alt) activate(alt);
    }
  }

  function collapseSplits() {
    if (!layoutTree) return;
    layoutTree = null;
    if (activeId && !tabs.has(activeId)) activeId = null;
    saveLayout();
    renderLayout();
    toast('已还原为单屏，其余终端仍在标签栏里');
    if (activeId) { activate(activeId); return; }
    var first = null;
    tabs.forEach(function (_, tid) { if (!first) first = tid; });
    if (first) activate(first);
  }

  // "+"/Alt+N: in split view a new terminal splits the focused area (wide ->
  // right, tall -> bottom); in single mode it is just the old plain new tab
  function createTabSmart() {
    if (layoutMode !== 'tabs' || !layoutTree) { createTab(); return; }
    if (activeId && tabs.has(activeId) && treeHas(layoutTree, activeId)) {
      var r = tabs.get(activeId).pane.getBoundingClientRect();
      splitPane(activeId, r.width > r.height * 1.15 ? 'right' : 'bottom');
      return;
    }
    createTab();
  }

  // 宫格: what the terminal's right-click menu offers for the wall.
  function gridMenuItems(id) {
    if (layoutMode !== 'grid') return [];
    return [
      wallHas(id) ? ['移出宫格（终端不关）', function () { wallRemove(id); }]
                  : ['放进宫格', function () { wallEnsure(id); }],
      ['全部上墙', function () { wallAll(); }],
      ['只留当前一格', function () { wallOne(); }]
    ];
  }

  function splitMenuItems(id) {
    if (layoutMode !== 'tabs') {
      return [['分屏要用「横排」布局（点顶部横排）', function () {
        toast('切到「横排」布局后即可分屏');
      }]];
    }
    var items = [
      ['分屏到右侧', function () { splitPane(id, 'right'); }],
      ['分屏到下方', function () { splitPane(id, 'bottom'); }],
      ['分屏到左侧', function () { splitPane(id, 'left'); }],
      ['分屏到上方', function () { splitPane(id, 'top'); }]
    ];
    if (layoutTree && tabs.get(id)) {
      items.push('-');
      if (treeHas(layoutTree, id)) items.push(['移出分屏', function () { unsplitPane(id); }]);
      items.push(['全部还原为单屏', function () { collapseSplits(); }]);
    }
    return items;
  }

  /* ---- divider drag: change the ratio of the two neighbouring children ---- */

  function wireDivider(div, node) {
    div.addEventListener('pointerdown', function (e) {
      if (e.button !== undefined && e.button !== 0) return;
      e.preventDefault();
      var aEl = div.previousElementSibling;
      var bEl = div.nextElementSibling;
      if (!aEl || !bEl) return;
      var horiz = (node.d !== 'col');          // row container: divider moves on x
      var startPos = horiz ? e.clientX : e.clientY;
      var ra = aEl.getBoundingClientRect();
      var rb = bEl.getBoundingClientRect();
      var aStart = horiz ? ra.width : ra.height;
      var total = aStart + (horiz ? rb.width : rb.height);
      if (total < 40) return;
      try { div.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
      div.classList.add('busy');
      var raf = 0;
      var cur = startPos;
      function apply() {
        raf = 0;
        node.r = Math.min(1 - SPLIT_MIN, Math.max(SPLIT_MIN, (aStart + (cur - startPos)) / total));
        setGrow(aEl, node.r);
        setGrow(bEl, 1 - node.r);
        refitVisibleSoon();
      }
      function move(ev) {
        cur = horiz ? ev.clientX : ev.clientY;
        if (!raf) raf = requestAnimationFrame(apply);
      }
      function up() {
        div.removeEventListener('pointermove', move);
        div.removeEventListener('pointerup', up);
        div.removeEventListener('pointercancel', up);
        div.classList.remove('busy');
        if (raf) { cancelAnimationFrame(raf); raf = 0; }
        saveLayout();
        refitVisible();
      }
      div.addEventListener('pointermove', move);
      div.addEventListener('pointerup', up);
      div.addEventListener('pointercancel', up);
    });
  }

  /* ---- tab drag: drop a tab on a pane edge to put it into the split ---- */

  function paneIdOf(el) {
    var p = el && el.closest ? el.closest('.pane') : null;
    return (p && p.dataset && p.dataset.tid) ? p.dataset.tid : null;
  }

  var dropState = null;

  function clearDropZone() {
    if (!dropState) return;
    if (dropState.paneEl) dropState.paneEl.classList.remove('droptgt', 'dz-left', 'dz-right', 'dz-top', 'dz-bottom', 'dz-center');
    if (dropState.tabEl) dropState.tabEl.classList.remove('droptab', 'drop-before', 'drop-after');
    dropState = null;
  }

  // What the floating label says about the place you are hovering.
  function dropHint(drop) {
    if (!drop) return '';
    if (drop.kind === 'strip') return '放到这里';
    if (layoutMode === 'grid') {
      return (drop.zone === 'center') ? '换到这一格' : ('上墙：' + (SIDE_LABEL[drop.zone] || '这里'));
    }
    return '分屏：' + (SIDE_LABEL[drop.zone] || '这里');
  }

  function updateDropZone(x, y) {
    var hit = document.elementFromPoint(x, y);
    // 1) over the tab strip -> re-order the tabs themselves
    var overTab = (hit && hit.closest) ? hit.closest('.tab') : null;
    if (overTab && tabbar.contains(overTab) && overTab.dataset.tid) {
      var r0 = overTab.getBoundingClientRect();
      var after = x > r0.left + r0.width / 2;
      if (!dropState || dropState.kind !== 'strip' || dropState.tabEl !== overTab || dropState.after !== after) {
        clearDropZone();
        overTab.classList.add('droptab', after ? 'drop-after' : 'drop-before');
        dropState = { kind: 'strip', tabEl: overTab, tabId: overTab.dataset.tid, after: after };
      }
      return dropState;
    }
    // 2) over a pane -> 横排: split there / 宫格: put it on the wall there
    if (!hit || !paneIdOf(hit)) { clearDropZone(); return null; }
    var paneEl = hit.closest('.pane');
    var r = paneEl.getBoundingClientRect();
    var edge = 0.30;
    var zone = null;
    if ((x - r.left) / r.width < edge) zone = 'left';
    else if ((r.right - x) / r.width < edge) zone = 'right';
    else if ((y - r.top) / r.height < edge) zone = 'top';
    else if ((r.bottom - y) / r.height < edge) zone = 'bottom';
    else if (layoutMode === 'grid') zone = 'center';   // 宫格: the whole cell = 换掉这格
    if (!zone) { clearDropZone(); return null; }
    if (!dropState || dropState.kind !== 'pane' || dropState.paneEl !== paneEl || dropState.zone !== zone) {
      clearDropZone();
      paneEl.classList.add('droptgt', 'dz-' + zone);
      dropState = { kind: 'pane', paneEl: paneEl, zone: zone };
    }
    return dropState;
  }

  /* ---- the tab you are dragging follows the pointer (a small floating label) ---- */

  var dragGhost = null;

  function showGhost(t, ev) {
    if (dragGhost) return;
    var g = document.createElement('div');
    g.className = 'tabghost';
    var dot = document.createElement('span'); dot.className = 'ghostdot';
    var label = document.createElement('span');
    label.textContent = t.labelEl.textContent || '终端';
    var act = document.createElement('span'); act.className = 'ghostact';
    g.append(dot, label, act);
    document.body.appendChild(g);
    dragGhost = { el: g, act: act, x: ev.clientX, y: ev.clientY, raf: 0 };
    document.body.classList.add('wt-dragging');
    moveGhost(ev);
  }

  function moveGhost(ev) {
    if (!dragGhost) return;
    dragGhost.x = ev.clientX;
    dragGhost.y = ev.clientY;
    if (dragGhost.raf) return;
    dragGhost.raf = requestAnimationFrame(function () {
      if (!dragGhost) return;
      dragGhost.raf = 0;
      // keep the label under the cursor, nudged so it never covers the drop target
      dragGhost.el.style.transform = 'translate(' + (dragGhost.x + 14) + 'px,' +
                                     (dragGhost.y + 10) + 'px)';
    });
  }

  function hideGhost() {
    if (!dragGhost) return;
    if (dragGhost.raf) cancelAnimationFrame(dragGhost.raf);
    dragGhost.el.remove();
    dragGhost = null;
    document.body.classList.remove('wt-dragging');
  }

  /* ---- re-ordering the tabs by dragging inside the strip ---- */

  function stripIndex(id) {
    var all = Array.prototype.slice.call(tabbar.querySelectorAll('.tab'));
    for (var i = 0; i < all.length; i++) if (all[i].dataset.tid === id) return i + 1;
    return 0;
  }

  // Keep the Map order (persisted, and used by Alt+1..9 / 全部上墙 / pane order)
  // in sync with the visible strip order.
  function rebuildTabOrder() {
    var order = [];
    Array.prototype.forEach.call(tabbar.querySelectorAll('.tab'), function (el) {
      if (el.dataset.tid && tabs.has(el.dataset.tid)) order.push(el.dataset.tid);
    });
    if (order.length !== tabs.size) return;               // never lose a tab
    var pairs = order.map(function (tid) { return [tid, tabs.get(tid)]; });
    tabs.clear();
    pairs.forEach(function (p) { tabs.set(p[0], p[1]); });
  }

  function moveTabInStrip(id, targetId, after) {
    var src = tabs.get(id), tgt = tabs.get(targetId);
    if (!src || !tgt || id === targetId) return;
    var ref = after ? tgt.tabEl.nextSibling : tgt.tabEl;
    if (ref === src.tabEl) return;                        // already in that place
    tabbar.insertBefore(src.tabEl, ref || tabMoreBtn);
    rebuildTabOrder();
    saveTabs();                                           // remember the new order
    renderLayout();                                       // panes follow the strip order
    scheduleTabbar();
    // NOTE: no activate() here on purpose — re-ordering must not change which
    // terminal is focused (in 宫格 that would also drag it onto the wall).
    toast('已把「' + (src.labelEl.textContent || '终端') + '」移到第 ' + stripIndex(id) + ' 位');
  }

  function wireTabDrag(handle, t, id, ignoreEl) {
    handle.addEventListener('pointerdown', function (e) {
      if (e.button !== undefined && e.button !== 0) return;
      if (ignoreEl && (e.target === ignoreEl || ignoreEl.contains(e.target))) return;
      if (e.target && e.target.closest && e.target.closest('.pane-tool')) return;
      var st = { x: e.clientX, y: e.clientY, active: false, drop: null };
      function mark(on) {
        t.tabEl.classList.toggle('dragging', on);
        t.paneTabEl.classList.toggle('dragging', on);
      }
      function move(ev) {
        if (!tabs.has(id)) { cleanup(); return; }
        if (!st.active) {
          if (Math.abs(ev.clientX - st.x) < 6 && Math.abs(ev.clientY - st.y) < 6) return;
          st.active = true;
          mark(true);
          showGhost(t, ev);
        }
        moveGhost(ev);
        st.drop = updateDropZone(ev.clientX, ev.clientY);
        if (dragGhost) dragGhost.act.textContent = dropHint(st.drop);
      }
      function cleanup() {
        handle.removeEventListener('pointermove', move);
        handle.removeEventListener('pointerup', up);
        handle.removeEventListener('pointercancel', cancel);
        mark(false);
        clearDropZone();
        hideGhost();
      }
      function up() {
        var drop = st.active ? st.drop : null;
        cleanup();
        if (!drop || !tabs.has(id)) return;
        if (drop.kind === 'strip') {                       // dropped back on the strip
          if (drop.tabId && drop.tabId !== id) moveTabInStrip(id, drop.tabId, drop.after);
          return;
        }
        var pid = paneIdOf(drop.paneEl);
        if (pid && pid !== id && tabs.has(pid)) {
          if (layoutMode === 'grid') gridDrop(id, pid, drop.zone);  // 宫格: 上墙/换位
          else movePane(id, pid, drop.zone);                        // 横排: 分屏
        }
      }
      function cancel() { cleanup(); }
      try { t.tabEl.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
      t.tabEl.addEventListener('pointermove', move);
      t.tabEl.addEventListener('pointerup', up);
      t.tabEl.addEventListener('pointercancel', cancel);
    });
  }

  window.addEventListener('blur', function () { clearDropZone(); hideGhost(); });

  /* ---------------- layout modes: 横排 / 宫格 / 分组 ----------------
   *
   * tabs    : classic strip + one terminal on stage (draggable splits).
   * grid    : a manual "wall" of cells — a terminal only gets a cell once you
   *           drag its tab in (or click it); drag between cells to re-order,
   *           drop on a cell centre to replace it, drop on an edge to insert.
   * grouped : terminals are grouped by the directory their shell sits in (or by
   *           the directory of the opencode session they run), the rail picks a
   *           group and the strip only shows that group's tabs.
   *
   * The split tree is only rendered in "tabs"; switching away keeps it in
   * localStorage so coming back restores the same arrangement.
   */

  var MODE_KEY = 'webterm.layoutmode.v1';
  var GRIDCOL_KEY = 'webterm.gridcol.v1';
  var GRID_KEY = 'webterm.gridwall.v1';   // 宫格: which terminals are on the wall
  var GROUP_KEY = 'webterm.navgroup.v1';
  var LAYOUT_MODES = ['tabs', 'grid', 'grouped'];
  var MODE_LABEL = { tabs: '横排标签', grid: '宫格平铺', grouped: '按目录分组' };
  var TAB_MORE_W = 76;                    // width reserved for the "⋯ n" button
  var CWDS_MS = 5000;                     // how often grouped mode re-asks for cwds
  var GRID_MAX = 9;                       // most cells on the 宫格 wall

  var layoutMode = 'tabs';
  var gridCols = 0;                       // 0 = pick columns automatically
  var gridWall = [];                      // 宫格: tab ids on the wall, in order
  var wallLock = false;                   // true while tabs are being restored
  var curGroup = null;                    // selected group key (grouped mode)
  var groupFocus = Object.create(null);   // group key -> last focused tab id
  var tabMoreList = [];                   // ids the strip could not show
  var HOME_DIR = '';
  var tabbarRaf = 0;
  var cwdsTimer = 0;

  function lsGet(key) { try { return localStorage.getItem(key); } catch (e) { return null; } }
  function lsSet(key, val) { try { localStorage.setItem(key, val); } catch (e) { /* ignore */ } }

  // "#layout=grid&cols=2" picks a layout for this visit only (bookmarks, tests):
  // it never touches the saved preference.
  function hashVal(re) {
    var m = re.exec(location.hash || '');
    return m ? m[1] : null;
  }

  function navItemById(sid) {
    for (var i = 0; i < navState.items.length; i++) {
      if (navState.items[i].id === sid) return navState.items[i];
    }
    return null;
  }

  /* ---- 分组: which group does a tab belong to ---- */

  function groupKeyOf(id) {
    var t = tabs.get(id);
    if (!t) return '';
    if (t.ocId) {                                     // tied to an opencode session
      var it = navItemById(t.ocId);
      if (it && it.directory) return it.directory;
    }
    if (t.cwd) return t.cwd;                          // where its shell really is
    return (t.gkey === undefined || t.gkey === null) ? '' : t.gkey;
  }

  function groupLabelOf(key) {
    if (!key) return '未分组';
    if (HOME_DIR && key === HOME_DIR) return '~ (home)';
    var parts = String(key).split('/').filter(Boolean);
    return parts.length ? parts[parts.length - 1] : key;
  }

  function builtGroups() {
    var map = Object.create(null), order = [];
    tabs.forEach(function (t, id) {
      var k = groupKeyOf(id);
      if (!map[k]) { map[k] = { key: k, label: groupLabelOf(k), ids: [] }; order.push(k); }
      map[k].ids.push(id);
    });
    var gs = order.map(function (k) { return map[k]; });
    gs.sort(function (a, b) {
      if (!a.key !== !b.key) return a.key ? -1 : 1;   // 未分组 always last
      return a.label.localeCompare(b.label);
    });
    return gs;
  }

  function ensureGroup() {
    var gs = builtGroups();
    if (!gs.length) { curGroup = null; return gs; }
    var has = function (k) {
      for (var i = 0; i < gs.length; i++) if (gs[i].key === k) return true;
      return false;
    };
    if (!has(curGroup)) {
      // nothing remembered (or that group is gone): stay with the terminal the
      // user was just looking at, which is far less surprising than "第一组"
      var mine = (activeId && tabs.has(activeId)) ? groupKeyOf(activeId) : null;
      curGroup = has(mine) ? mine : gs[0].key;
    }
    return gs;
  }

  function renderGroups() {
    var gs = ensureGroup();
    gListEl.innerHTML = '';
    gCountEl.textContent = gs.length ? gs.length + ' 组' : '';
    if (!gs.length) {
      var info = document.createElement('div');
      info.className = 'g-info';
      info.textContent = '还没有终端';
      gListEl.appendChild(info);
      return;
    }
    gs.forEach(function (g) {
      var row = document.createElement('div');
      row.className = 'g-item' + (g.key === curGroup ? ' active' : '');
      row.dataset.key = g.key;
      row.title = (g.key || '未分组') + '\n' + g.ids.length + ' 个终端';
      var nameEl = document.createElement('div');
      nameEl.className = 'g-name';
      nameEl.textContent = g.label;
      var metaEl = document.createElement('div');
      metaEl.className = 'g-meta';
      metaEl.textContent = g.ids.length + ' 个终端' + (g.key ? ' · ' + g.key : '');
      row.append(nameEl, metaEl);
      row.addEventListener('click', function () { selectGroup(g.key); });
      gListEl.appendChild(row);
    });
  }

  function syncGroupsActive() {
    Array.prototype.forEach.call(gListEl.children, function (row) {
      if (!row.dataset || row.dataset.key === undefined) return;
      row.classList.toggle('active', row.dataset.key === curGroup);
    });
  }

  // Ids the strip is allowed to show (in tab order).
  function tabbarIds() {
    var ids = [];
    tabs.forEach(function (t, id) { ids.push(id); });
    if (layoutMode !== 'grouped') return ids;
    ensureGroup();
    return ids.filter(function (id) { return groupKeyOf(id) === curGroup; });
  }

  function selectGroup(key) {
    curGroup = key;
    lsSet(GROUP_KEY, key);
    syncGroupsActive();
    var ids = tabbarIds();
    var next = (activeId && ids.indexOf(activeId) >= 0) ? activeId : null;
    if (!next && groupFocus[key] && ids.indexOf(groupFocus[key]) >= 0) next = groupFocus[key];
    if (!next) next = ids[0] || null;
    if (next) activate(next); else syncPaneVisibility();
    scheduleTabbar();
  }

  // Membership changed underneath us (cwd / opencode list): keep a live focus.
  function syncGroupSelection() {
    ensureGroup();
    var ids = tabbarIds();
    if (activeId && ids.indexOf(activeId) >= 0) return;
    var next = (groupFocus[curGroup] && ids.indexOf(groupFocus[curGroup]) >= 0)
      ? groupFocus[curGroup] : (ids[0] || null);
    if (next) activate(next);
  }

  /* ---- 宫格: a wall you build by dragging tabs in ----
   *
   * A terminal only gets a cell once it is "on the wall": drag its tab into the
   * stage (drop near an edge to insert beside a cell, on the middle to replace
   * it), or just click the tab.  Nothing is added behind your back, and the wall
   * is remembered per browser.
   */

  function saveWall() { lsSet(GRID_KEY, JSON.stringify(gridWall)); }

  function wallHas(id) { return gridWall.indexOf(id) >= 0; }

  // The focused terminal must be visible: put it on the wall if it is missing.
  function wallEnsure(id) {
    if (layoutMode !== 'grid' || wallLock) return false;
    if (!id || !tabs.has(id) || wallHas(id)) return false;
    if (gridWall.length >= GRID_MAX) {
      toast('宫格最多 ' + GRID_MAX + ' 格：先「✕ 移出」几格再放');
      return false;
    }
    gridWall.push(id);
    saveWall();
    renderLayout();
    scheduleTabbar();
    return true;
  }

  function wallRemove(id) {
    var i = gridWall.indexOf(id);
    if (i < 0 || layoutMode !== 'grid') return;
    gridWall.splice(i, 1);
    if (!gridWall.length) {
      // never leave the stage blank: keep some other terminal (it stays open)
      var spare = null;
      tabs.forEach(function (t, tid) { if (!spare && tid !== id) spare = tid; });
      if (spare) gridWall.push(spare);
      else {
        gridWall.push(id);
        toast('宫格至少要留一格');
        return;
      }
    }
    saveWall();
    renderLayout();                       // sanitizeWall() keeps the wall sane
    scheduleTabbar();
    toast('已移出宫格：终端还在标签栏里，点标签或拖回来即可重新上墙');
  }

  function wallAll() {
    var ids = [];
    tabs.forEach(function (t, id) { ids.push(id); });
    gridWall = ids.slice(0, GRID_MAX);
    saveWall();
    renderLayout();
    scheduleTabbar();
    toast(ids.length > GRID_MAX
      ? '已把前 ' + GRID_MAX + ' 个终端全部上墙（宫格最多 ' + GRID_MAX + ' 格）'
      : '已把 ' + gridWall.length + ' 个终端全部上墙');
  }

  function wallOne() {
    var keep = (activeId && tabs.has(activeId)) ? activeId : null;
    if (!keep) tabs.forEach(function (t, id) { if (!keep) keep = id; });
    gridWall = keep ? [keep] : [];
    saveWall();
    renderLayout();
    scheduleTabbar();
    toast('只留当前终端：把其它标签拖进画面即可拼墙');
  }

  // Forget closed tabs, never leave the wall empty, cap the number of cells.
  function sanitizeWall() {
    if (wallLock) return gridWall;         // tabs are still being restored at boot
    var seen = Object.create(null), out = [];
    gridWall.forEach(function (id) {
      if (typeof id === 'string' && !seen[id] && tabs.has(id)) { seen[id] = 1; out.push(id); }
    });
    if (!out.length && tabs.size && !wallLock) {
      var first = (activeId && tabs.has(activeId)) ? activeId : null;
      if (!first) tabs.forEach(function (t, id) { if (!first) first = id; });
      if (first) out.push(first);
    }
    out = out.slice(0, GRID_MAX);
    var same = out.length === gridWall.length;
    for (var i = 0; same && i < out.length; i++) if (out[i] !== gridWall[i]) same = false;
    gridWall = out;
    if (!same) saveWall();
    return gridWall;
  }

  // A tab was dropped on a cell: insert next to it, or take its place.
  function gridDrop(id, targetId, zone) {
    if (!tabs.has(id) || !tabs.has(targetId) || id === targetId) return;
    var before = gridWall.slice();
    var from = gridWall.indexOf(id);
    if (from >= 0) gridWall.splice(from, 1);
    var ti = gridWall.indexOf(targetId);
    if (zone === 'center') {
      if (ti < 0) gridWall.push(id); else gridWall.splice(ti, 1, id);
    } else if (ti < 0) {
      gridWall.push(id);
    } else {
      gridWall.splice((zone === 'left' || zone === 'top') ? ti : ti + 1, 0, id);
    }
    if (gridWall.length > GRID_MAX) {
      gridWall = before;
      toast('宫格最多 ' + GRID_MAX + ' 格');
      return;
    }
    saveWall();
    renderLayout();
    scheduleTabbar();
    activate(id);
    var label = tabs.get(id).labelEl.textContent || '终端';
    toast(zone === 'center'
      ? '「' + label + '」换到了这一格'
      : '「' + label + '」已放到' + (SIDE_LABEL[zone] || '宫格里'));
  }

  function gridColumnCount(n) {
    if (gridCols > 0) return Math.max(1, Math.min(gridCols, n));
    if (n <= 1) return 1;
    if (n === 2) return 2;
    return Math.min(4, Math.ceil(Math.sqrt(n)));
  }

  function applyGrid() {
    var ids = sanitizeWall();
    if (!ids.length) { panes.style.gridTemplateColumns = ''; return; }
    var c = gridColumnCount(ids.length);
    panes.style.gridTemplateColumns = 'repeat(' + c + ', minmax(0, 1fr))';
    panes.dataset.cols = String(c);                  // handy when debugging
  }

  /* ---- tab strip: what fits stays, the rest goes behind "⋯ n" ---- */

  function scheduleTabbar() {
    if (tabbarRaf) return;
    tabbarRaf = requestAnimationFrame(function () { tabbarRaf = 0; applyTabbar(); });
  }

  function tabLabelOf(id) {
    var t = tabs.get(id);
    if (!t) return '';
    return (t.n ? t.n + '. ' : '') + (t.labelEl.textContent || '终端')
         + (t.alive ? '' : '（已结束）');
  }

  function applyTabbar() {
    var allowed = Object.create(null);
    tabbarIds().forEach(function (id) { allowed[id] = 1; });

    var cands = [];
    tabs.forEach(function (t, id) {
      var inBar = !!allowed[id];
      var onWall = (layoutMode === 'grid') && wallHas(id);
      t.tabEl.style.display = inBar ? '' : 'none';
      t.tabEl.classList.toggle('on-wall', onWall);
      if (t.paneTabEl) {                              // the tab shown above the pane
        t.paneTabEl.classList.toggle('on-wall', onWall);
        t.paneTabEl.classList.toggle('active', id === activeId);
        t.paneLabelEl.textContent = (onWall ? '▦ ' : '') + tabLabelOf(id);
        t.paneTabEl.title = '这个终端的标签：点一下聚焦，拖动 = 换位置 / 上墙' +
          (onWall ? '（已在宫格墙上）' : '');
      }
      if (inBar) cands.push(id);
    });

    var widths = cands.map(function (id) { return tabs.get(id).tabEl.offsetWidth + 3; });
    var total = widths.reduce(function (a, b) { return a + b; }, 0);
    var avail = tabbar.clientWidth - 30 - newTabBtn.offsetWidth - 8;
    var hidden = Object.create(null);
    if (total > avail) {
      avail -= TAB_MORE_W;                           // the button we are about to show
      for (var i = cands.length - 1; i >= 0 && total > avail; i--) {
        if (cands[i] === activeId) continue;         // never hide the focused tab
        hidden[cands[i]] = 1;
        total -= widths[i];
      }
    }
    var dropped = [];
    cands.forEach(function (id) {
      if (hidden[id]) { tabs.get(id).tabEl.style.display = 'none'; dropped.push(id); }
    });
    var outside = [];
    tabs.forEach(function (t, id) { if (!allowed[id]) outside.push(id); });

    tabMoreList = dropped.concat(outside);
    var n = tabMoreList.length;
    tabMoreBtn.classList.toggle('show', !!n);
    tabMoreBtn.textContent = '⋯' + (n ? ' ' + n : '');
    tabMoreBtn.title = n ? n + ' 个终端未显示（点击查看 / 切换）' : '';
  }

  function showTabMoreMenu() {
    var r = tabMoreBtn.getBoundingClientRect();
    var byGroup = Object.create(null), order = [];
    tabMoreList.forEach(function (id) {
      var g = (layoutMode === 'grouped') ? groupKeyOf(id) : '';
      if (!byGroup[g]) { byGroup[g] = []; order.push(g); }
      byGroup[g].push(id);
    });
    var items = [];
    order.forEach(function (g) {
      var ids = byGroup[g];
      if (layoutMode === 'grouped' && g !== curGroup) {
        items.push([groupLabelOf(g) + '（' + ids.length + '）',
          (function (k) { return function () { selectGroup(k); }; })(g), 'head']);
      }
      ids.forEach(function (id) {
        var mark = (id === activeId) ? '✓ '
                 : ((layoutMode === 'grid' && wallHas(id)) ? '▦ ' : '');
        items.push([mark + tabLabelOf(id),
          (function (i) { return function () { activate(i); }; })(id)]);
      });
    });
    if (!items.length) return;
    openMenu(r.left, r.bottom + 6, items);
  }

  /* ---- mode plumbing ---- */

  function setLayoutMode(mode, quiet) {
    if (LAYOUT_MODES.indexOf(mode) < 0) mode = 'tabs';
    layoutMode = mode;
    Array.prototype.forEach.call(layoutSwEl.children, function (b) {
      b.classList.toggle('on', b.dataset.mode === mode);
    });
    groupsEl.classList.toggle('hidden', mode !== 'grouped');
    gridColsEl.classList.toggle('show', mode === 'grid');
    gridActsEl.classList.toggle('show', mode === 'grid');
    if (mode === 'grouped') { ensureGroup(); requestCwds(); }
    renderLayout();
    if (!quiet) {
      toast(mode === 'grid'
        ? '宫格：把标签拖进画面占一格（拖到格子中间=替换那格，✕ 移出=下墙）'
        : '布局：' + MODE_LABEL[mode]);
    }
  }

  function chooseLayoutMode(mode) {
    lsSet(MODE_KEY, mode);
    setLayoutMode(mode);
  }

  function cycleLayout() {
    var i = LAYOUT_MODES.indexOf(layoutMode);
    chooseLayoutMode(LAYOUT_MODES[(i + 1) % LAYOUT_MODES.length]);
  }

  function focusNthTab(n) {
    var ids = tabbarIds();
    if (ids[n - 1]) activate(ids[n - 1]);
  }

  // Alt+L / Alt+1..9 are claimed BEFORE xterm sees them, otherwise the shell
  // would also receive M-l / M-1 (readline: downcase-word / digit-argument).
  // The document listener below picks up the same event only when a terminal
  // did not already handle it (e.g. focus is on a button).
  function handleLayoutKey(ev) {
    if (!ev.altKey || ev.ctrlKey || ev.metaKey) return false;
    var k = ev.key || '';
    if (k === 'l' || k === 'L') { ev.__wtHandled = true; cycleLayout(); return true; }
    if (k >= '1' && k <= '9') {
      ev.__wtHandled = true;
      focusNthTab(parseInt(k, 10));
      return true;
    }
    return false;
  }

  function requestCwds() { sendMsg({ type: 'cwds' }); }

  function applyCwds(items, home) {
    if (home) HOME_DIR = home;
    var changed = false;
    tabs.forEach(function (t, id) {
      var c = items[id] || '';
      if (c !== (t.cwd || '')) { t.cwd = c; changed = true; }
    });
    if (!changed) return;
    if (layoutMode === 'grouped') { renderGroups(); syncGroupSelection(); }
    scheduleTabbar();
  }

  function initLayout() {
    var hMode = hashVal(/(?:^|[#&])layout=(tabs|grid|grouped)\b/);
    var hCols = hashVal(/(?:^|[#&])cols=([0-4])\b/);
    var sCols = parseInt(lsGet(GRIDCOL_KEY) || '0', 10);
    gridCols = (hCols !== null) ? parseInt(hCols, 10) : (isNaN(sCols) ? 0 : sCols);
    gridColsEl.value = String(gridCols);
    var savedGroup = lsGet(GROUP_KEY);
    curGroup = (savedGroup === null) ? null : savedGroup;

    var sWall = [];
    try { sWall = JSON.parse(lsGet(GRID_KEY) || '[]'); } catch (e) { sWall = []; }
    gridWall = (Object.prototype.toString.call(sWall) === '[object Array]') ? sWall : [];

    Array.prototype.forEach.call(layoutSwEl.children, function (b) {
      b.addEventListener('click', function () { chooseLayoutMode(b.dataset.mode); });
    });
    gridColsEl.addEventListener('change', function () {
      gridCols = parseInt(gridColsEl.value, 10) || 0;
      lsSet(GRIDCOL_KEY, String(gridCols));
      if (layoutMode === 'grid') renderLayout();
    });
    wallAllBtn.addEventListener('click', function () { if (layoutMode === 'grid') wallAll(); });
    wallOneBtn.addEventListener('click', function () { if (layoutMode === 'grid') wallOne(); });
    tabMoreBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      showTabMoreMenu();
    });

    document.addEventListener('keydown', function (e) {
      if (e.__wtHandled) return;                   // a terminal already did it
      if (handleLayoutKey(e)) e.preventDefault();
    });

    cwdsTimer = setInterval(function () {
      if (layoutMode === 'grouped' && !document.hidden) requestCwds();
    }, CWDS_MS);
    window.addEventListener('focus', function () {
      if (layoutMode === 'grouped') requestCwds();
    });

    setLayoutMode(hMode || lsGet(MODE_KEY) || 'tabs', true);
  }

  /* ---------------- left navigation: opencode sessions ---------------- */


  var NAV_KEY = 'webterm.nav.v1';

  var navEl = document.getElementById('nav');
  var navListEl = document.getElementById('nav-list');
  var navStatusEl = document.getElementById('nav-status');
  var navToggleBtn = document.getElementById('navtoggle');
  var navRefreshBtn = document.getElementById('nav-refresh');

  var navState = {
    items: [], bin: 'opencode', visible: true, loading: false, error: '', timer: null
  };

  var modalEl = document.getElementById('modal');
  var modalTitle = document.getElementById('modal-title');
  var modalName = document.getElementById('modal-name');
  var modalMeta = document.getElementById('modal-meta');
  var modalNote = document.getElementById('modal-note');
  var modalCmd = document.getElementById('modal-cmd');
  var modalOk = document.getElementById('modal-ok');
  var pendingAction = null;                          // function run on "确定"

  function relTime(ms) {
    return (window.WTKeymap && window.WTKeymap.relTime) ? window.WTKeymap.relTime(ms) : '';
  }

  function requestSessions(force) {
    if (force) {
      navRefreshBtn.classList.add('spin');
      setTimeout(function () { navRefreshBtn.classList.remove('spin'); }, 700);
    }
    navState.loading = true;
    if (!navState.items.length) {
      navListEl.innerHTML = '<div class="nav-info">加载中…</div>';
    }
    sendMsg({ type: 'opencode_sessions', force: !!force });
  }

  function renderSessions(items, err) {
    navState.loading = false;
    navState.error = err || '';
    navListEl.innerHTML = '';

    if (err) {
      var e = document.createElement('div');
      e.className = 'nav-info error';
      e.textContent = '读取会话失败：' + err;
      navListEl.appendChild(e);
      navStatusEl.textContent = '读取失败 · 点 ⟳ 重试';
      return;
    }
    if (!items.length) {
      var n = document.createElement('div');
      n.className = 'nav-info';
      n.textContent = '还没有 opencode 会话。在终端里跑一次 opencode 就会出现在这里。';
      navListEl.appendChild(n);
      navStatusEl.textContent = '0 个会话';
      return;
    }

    navState.items = items;
    items.forEach(function (it) {
      var row = document.createElement('div');
      row.className = 'nav-item';
      row.dataset.id = it.id;
      row.title = (it.title || '') + '\n' + it.id + (it.directory ? '\n' + it.directory : '');

      var nameEl = document.createElement('div');
      nameEl.className = 'nav-item-title';
      nameEl.textContent = it.title || '(无标题)';

      var metaEl = document.createElement('div');
      metaEl.className = 'nav-item-meta';
      var timeEl = document.createElement('span');
      timeEl.textContent = relTime(it.updated);
      metaEl.appendChild(timeEl);
      if (it.directory) {
        var dirEl = document.createElement('span');
        dirEl.className = 'dir';
        dirEl.textContent = '· ' + it.directory;
        metaEl.appendChild(dirEl);
      }

      row.append(nameEl, metaEl);
      row.addEventListener('click', function () { openSession(it); });
      row.addEventListener('contextmenu', function (e) {
        e.preventDefault();
        showNavMenu(e.clientX, e.clientY, it);
      });
      navListEl.appendChild(row);
    });

    var now = new Date();
    navStatusEl.textContent = items.length + ' 个会话 · 更新于 '
      + pad2(now.getHours()) + ':' + pad2(now.getMinutes());
    syncNavActive();
    // A tab running an opencode session is grouped by that session's directory,
    // which only this list knows: refresh the rail (and the strip) after it changes.
    if (layoutMode === 'grouped') { renderGroups(); syncGroupSelection(); }
    scheduleTabbar();
  }

  function pad2(n) { return (n < 10 ? '0' : '') + n; }

  // Mark nav rows that are currently open in a live tab.
  function syncNavActive() {
    var open = Object.create(null);
    tabs.forEach(function (t) { if (t.ocId && t.alive) open[t.ocId] = true; });
    Array.prototype.forEach.call(navListEl.children, function (row) {
      if (!row.dataset || !row.dataset.id) return;
      row.classList.toggle('active', !!open[row.dataset.id]);
    });
  }

  function resumeCommand(id) {
    var bin = navState.bin || 'opencode';
    if (/\s/.test(bin)) bin = "'" + bin + "'";
    return bin + ' -s ' + id;
  }

  // Is this opencode session already open in one of our tabs?
  function tabForSession(sid) {
    var hit = null;
    tabs.forEach(function (t, id) {
      if (!hit && t.ocId === sid) hit = { id: id, t: t };
    });
    return hit;
  }

  // Row click: an already-open session just gets focused; otherwise ask first.
  function openSession(item) {
    var hit = tabForSession(item.id);
    if (hit && hit.t.alive) {
      activate(hit.id);
      toast('已切换到 Tab ' + hit.t.n + '：' + (item.title || item.id));
      syncNavActive();
      return;
    }
    showResumeModal(item);
  }

  function metaLine(item) {
    var bits = [];
    if (item.directory) bits.push('目录 ' + item.directory);
    bits.push('最后活动 ' + (relTime(item.updated) || '未知'));
    bits.push('id ' + item.id);
    return bits.join(' · ');
  }

  // Shared confirm dialog. cfg: {title, name, meta, note, warn, cmd, ok, danger};
  // onOk is executed only when the user confirms.
  function showConfirm(cfg, onOk) {
    pendingAction = onOk || null;
    modalTitle.textContent = cfg.title || '';
    modalName.textContent = cfg.name || '';
    modalName.style.display = cfg.name ? '' : 'none';
    modalMeta.textContent = cfg.meta || '';
    modalMeta.style.display = cfg.meta ? '' : 'none';
    modalNote.textContent = cfg.note || '';
    modalNote.className = 'm-note' + (cfg.warn ? ' warn' : '');
    modalCmd.textContent = cfg.cmd || '';
    modalOk.textContent = cfg.ok || '确定';
    modalOk.className = cfg.danger ? 'danger' : 'primary';
    modalEl.classList.add('show');
    try { modalOk.focus(); } catch (e) { /* ignore */ }
  }

  function hideModal() {
    pendingAction = null;
    modalEl.classList.remove('show');
    if (activeId) {
      var t = tabs.get(activeId);
      if (t) t.term.focus();
    }
  }

  function showResumeModal(item) {
    showConfirm({
      title: '恢复这个 opencode 会话？',
      name: item.title || '(无标题)',
      meta: metaLine(item),
      note: '将在新标签里运行下面的命令，当前终端不受影响：',
      cmd: resumeCommand(item.id),
      ok: '恢复并打开新标签'
    }, function () { resumeSession(item); });
  }

  function showDeleteModal(item) {
    var hit = tabForSession(item.id);
    var note = '会连同它的子会话一起从 opencode 里删除，此操作无法撤销。';
    if (hit && hit.t.alive) {
      note = '该会话正在 Tab ' + hit.t.n + ' 里运行，删除时会一并关闭这个标签。'
           + '删除后无法撤销。';
    }
    showConfirm({
      title: '删除这个 opencode 会话？',
      name: item.title || '(无标题)',
      meta: metaLine(item),
      note: note,
      warn: true,
      cmd: (navState.bin || 'opencode').replace(/^'|'$/g, '') + ' session delete ' + item.id,
      ok: '确认删除',
      danger: true
    }, function () { deleteSession(item); });
  }

  function deleteSession(item) {
    sendMsg({ type: 'opencode_session_delete', session: item.id });
    toast('正在删除：' + (item.title || item.id));
    navStatusEl.textContent = '正在删除 ' + item.id + ' …';
  }

  // right-click on a session row
  function showNavMenu(x, y, item) {
    var hit = tabForSession(item.id);
    openMenu(x, y, [
      [hit && hit.t.alive ? '切换到该标签' : '恢复（新标签）',
        function () { openSession(item); }],
      ['-'],
      ['删除这个会话…', function () { showDeleteModal(item); }, 'danger']
    ]);
  }

  // Type a command into a freshly created tab once its shell has produced output
  // (i.e. printed its prompt); the timer is a fallback in case it never does.
  function queueCommand(id, cmd) {
    var t = tabs.get(id);
    if (!t) return;
    t.pendingCmd = cmd;
    setTimeout(function () {
      if (t.pendingCmd) {
        var c = t.pendingCmd;
        t.pendingCmd = null;
        sendMsg({ type: 'input', id: id, data: c + '\n' });
      }
    }, 1500);
  }

  function resumeSession(item) {
    var title = item.title || ('opencode ' + item.id.slice(0, 12));
    var id;
    if (layoutTree && activeId && tabs.has(activeId) && treeHas(layoutTree, activeId)) {
      // split view: keep the current pane untouched, add the resumed one beside it
      var r = tabs.get(activeId).pane.getBoundingClientRect();
      id = createTab({ title: title, quiet: true });
      layoutTree = treeInsert(layoutTree, activeId, id, r.width > r.height * 1.15 ? 'right' : 'bottom');
      saveLayout();
      renderLayout();
    } else {
      id = createTab({ title: title });
    }
    var t = tabs.get(id);
    if (t) t.ocId = item.id;
    queueCommand(id, resumeCommand(item.id));
    activate(id);
    toast('新标签里恢复：' + title);
    syncNavActive();
    requestSessions(true);                           // this session jumps to the top
  }

  function setNavVisible(v) {
    navState.visible = !!v;
    navEl.classList.toggle('hidden', !navState.visible);
    navToggleBtn.classList.toggle('on', navState.visible);
    try { localStorage.setItem(NAV_KEY, navState.visible ? '1' : '0'); } catch (e) { /* ignore */ }
    if (navState.visible) requestSessions(false);
    // the terminal area changed width: every VISIBLE pane must re-measure
    requestAnimationFrame(function () {
      refitVisible();
      setTimeout(refitVisible, 90);
    });
    scheduleTabbar();
  }

  function initNav() {
    navToggleBtn.addEventListener('click', function () { setNavVisible(!navState.visible); });
    navRefreshBtn.addEventListener('click', function () { requestSessions(true); });

    modalEl.addEventListener('click', function (e) { if (e.target === modalEl) hideModal(); });
    document.getElementById('modal-cancel').addEventListener('click', function (e) {
      e.preventDefault(); hideModal();
    });
    modalOk.addEventListener('click', function (e) {
      e.preventDefault();
      var act = pendingAction;
      hideModal();
      if (act) act();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && modalEl.classList.contains('show')) hideModal();
    });

    var pref = null;
    try { pref = localStorage.getItem(NAV_KEY); } catch (e) { /* ignore */ }
    setNavVisible(pref === null ? true : pref === '1');

    // keep the list fresh while it is on screen, and when the window regains focus
    navState.timer = setInterval(function () {
      if (navState.visible && !document.hidden) requestSessions(false);
    }, 60000);
    window.addEventListener('focus', function () {
      if (navState.visible) requestSessions(false);
    });
  }

  /* ---------------- boot ---------------- */

  newTabBtn.addEventListener('click', function () { createTabSmart(); });
  document.addEventListener('keydown', function (e) {
    if (e.altKey && (e.key === 'n' || e.key === 'N')) { e.preventDefault(); createTabSmart(); }
  });
  window.addEventListener('resize', function () {
    // hidden panes cannot be measured by xterm: fit every visible pane only
    refitVisibleSoon();
    scheduleTabbar();                          // fewer/more tabs fit after a resize
  });
  window.addEventListener('beforeunload', function () {
    try { if (ws && ws.readyState === WebSocket.OPEN) ws.close(); } catch (e) { /* ignore */ }
  });

  // Dropping an image outside a pane must not navigate the page to the file.
  document.addEventListener('dragover', function (e) { e.preventDefault(); });
  document.addEventListener('drop', function (e) { e.preventDefault(); });

  wallLock = true;                             // do not grow the 宫格 wall while restoring
  initLayout();                                // before the restore loop: tabs land
  initNav();                                   // in the right layout right away
  connect();

  var stored = loadStored();
  // IMPORTANT: read the saved layout before any createTab() runs — each of them
  // calls activate() -> saveLayout(), which would overwrite it with tree:null.
  var storedLayout = loadLayoutRaw();
  if (stored.length) {
    stored.forEach(function (s) { createTab({ id: s.id, n: s.n, title: s.title, userTitled: s.userTitled, ocId: s.ocId, restore: true }); });
    if (!applyStoredLayout(storedLayout)) {
      // no usable split layout: fall back to the old single-pane restore
      var ids = [];
      tabs.forEach(function (_, tid) { ids.push(tid); });
      if (ids.length) activate(ids[ids.length - 1]);
    }
  } else {
    createTab();
  }
  wallLock = false;
  if (layoutMode === 'grid') {                 // drop dead ids, keep the wall sane
    sanitizeWall();
    renderLayout();
  }
})();
