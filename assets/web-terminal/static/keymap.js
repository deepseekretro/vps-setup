/* Clipboard key decisions for the web terminal.
 *
 * Pure, side-effect free and unit-testable (see keymap.test.js).
 * Kept separate from app.js because app.js is DOM-bound.
 *
 * xterm.js sends ^C on Ctrl+C and has no copy binding, and its selection is not
 * a DOM selection, so the browser's own "Copy" menu item cannot see it.
 * These rules give us a real copy path while leaving paste to xterm's native
 * paste-event handling (intercepting paste keys risks double pastes).
 */
(function (root, factory) {
  var api = factory();
  if (typeof module !== 'undefined' && module.exports) { module.exports = api; }
  if (root) { root.WTKeymap = api; }
})(typeof window !== 'undefined' ? window : null, function () {
  'use strict';

  /**
   * @param {{key:string, ctrlKey?:boolean, shiftKey?:boolean, metaKey?:boolean, altKey?:boolean}} ev
   * @param {boolean} hasSelection
   * @returns {'copy'|null} null => let xterm/browser handle it
   */
  function decide(ev, hasSelection) {
    if (!ev) return null;
    var k = ev.key;
    var ctrl = !!ev.ctrlKey, shift = !!ev.shiftKey, meta = !!ev.metaKey, alt = !!ev.altKey;

    if (alt) return null;                       // never steal Alt combos

    // macOS: Cmd+C copies (native copy cannot see xterm's selection)
    if (meta && !ctrl && (k === 'c' || k === 'C')) return 'copy';

    // explicit copy: Ctrl+Shift+C  or  Ctrl+Insert
    if (ctrl && shift && (k === 'C' || k === 'c')) return 'copy';
    if (ctrl && !shift && k === 'Insert') return 'copy';

    // NOTE: Ctrl+Shift+A is deliberately NOT bound here: opencode uses
    // ctrl+shift+a for input.select.line.home, so it must reach the app.
    // Use the right-click menu for "select all".

    // Ctrl+C: copy when text is selected, otherwise fall through to ^C (SIGINT)
    if (ctrl && !shift && (k === 'c' || k === 'C')) return hasSelection ? 'copy' : null;

    // Ctrl+V / Ctrl+Shift+V / Shift+Insert / Cmd+V: xterm handles the native
    // paste event; intercepting here and also reading the clipboard would paste twice.
    return null;
  }

  /**
   * Extract the whole buffer as text (for "copy all output").
   * Duck-typed on purpose so it can be unit tested without a real terminal:
   * `buffer` needs `length` and `getLine(i) -> { translateToString(trimRight) }`.
   * @param {{length:number, getLine:(i:number)=>{translateToString:(t?:boolean)=>string}|undefined}} buffer
   * @returns {string}
   */
  function bufferText(buffer) {
    if (!buffer || typeof buffer.getLine !== 'function') return '';
    var lines = [];
    for (var i = 0; i < buffer.length; i++) {
      var line = buffer.getLine(i);
      lines.push(line && typeof line.translateToString === 'function'
        ? line.translateToString(true)
        : '');
    }
    while (lines.length && lines[lines.length - 1] === '') { lines.pop(); }   // drop trailing blanks
    return lines.join('\n');
  }

  /**
   * Base64 -> UTF-8 text. Works in the browser (atob) and in Node (Buffer),
   * and never throws: bad input yields ''.
   */
  function b64ToText(b64) {
    if (typeof b64 !== 'string' || b64 === '') return '';
    try {
      var bin;
      if (typeof atob === 'function') { bin = atob(b64); }
      else if (typeof Buffer !== 'undefined') { return Buffer.from(b64, 'base64').toString('utf8'); }
      else { return ''; }
      var bytes = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i); }
      if (typeof TextDecoder === 'function') { return new TextDecoder('utf-8').decode(bytes); }
      return bin;
    } catch (e) {
      return '';
    }
  }

  // OSC 52:  ESC ] 52 ; <selector> ; <base64> ( BEL | ESC \ )
  // The payload is restricted to the base64 charset on purpose: a truncated
  // fragment left over from an earlier chunk then cannot swallow the next real
  // sequence (ESC/']' are not base64 characters, so the match simply fails and
  // the scanner moves on to the following start marker).
  var OSC52_RE = /\x1b\]52;([^;]*);([A-Za-z0-9+/=]*)(?:\x07|\x1b\\)/g;
  var OSC52_MAX_PENDING = 64 * 1024;

  /**
   * Pull every complete OSC 52 clipboard write out of a chunk of terminal
   * output, and return the trailing fragment that may still be incomplete so
   * the caller can prepend it to the next chunk.
   *
   * @param {string} buf
   * @returns {{events: Array<{selector:string, text:string}>, rest: string}}
   */
  function osc52Extract(buf) {
    var events = [];
    if (typeof buf !== 'string' || buf === '') return { events: events, rest: '' };
    var last = 0, m;
    OSC52_RE.lastIndex = 0;
    while ((m = OSC52_RE.exec(buf)) !== null) {
      last = OSC52_RE.lastIndex;
      events.push({ selector: m[1], text: b64ToText(m[2]) });
    }
    var tail = buf.slice(last);
    var rest = '';
    var i = tail.indexOf('\x1b]52;');
    if (i !== -1) {
      var frag = tail.slice(i);
      // Carry it over only if it is genuinely unfinished. A fragment that already
      // has a terminator but did not match (e.g. the "?" query form, or malformed
      // base64) can never become valid later, so drop it instead of hoarding it.
      var terminated = frag.indexOf('\x07') !== -1 || frag.indexOf('\x1b\\') !== -1;
      if (!terminated && frag.length <= OSC52_MAX_PENDING) { rest = frag; }
    }
    return { events: events, rest: rest };
  }

  /**
   * Synchronized output (DECSET/DECRST 2026).
   *
   * TUI apps bracket a repaint with ESC[?2026h ... ESC[?2026l, meaning "do not
   * render until I am done". xterm.js does not know mode 2026, and the backend
   * forwards PTY output in short time buckets, so a repaint can reach the
   * renderer in halves - visible tearing/judder while scrolling (opencode animates
   * its scroll at ~60fps). This accumulates the bracketed region and hands it to
   * term.write() as one piece.
   *
   * feed(data) -> string of output that is ready to be written right now.
   * flush()    -> whatever is still held (stuck/aborted frame) as one string.
   */
  function syncWriter() {
    var ON = '\x1b[?2026h';
    var OFF = '\x1b[?2026l';
    var MAX_HELD = 1024 * 1024;      // safety: never buffer without bound
    var tail = '';                   // possibly-partial marker from last feed
    var held = '';                   // repaint in progress
    var syncing = false;

    function partialSuffix(text, from) {
      var max = Math.min(ON.length - 1, text.length - from);
      for (var n = max; n >= 1; n--) {
        var s = text.slice(text.length - n);
        if (ON.indexOf(s) === 0 || OFF.indexOf(s) === 0) { return n; }
      }
      return 0;
    }

    function feed(data) {
      var out = '';
      var text = tail + (typeof data === 'string' ? data : '');
      tail = '';
      var pos = 0;

      function push(s) {
        if (!s) { return; }
        if (syncing) { held += s; } else { out += s; }
      }

      while (pos < text.length) {
        var ih = text.indexOf(ON, pos);
        var il = text.indexOf(OFF, pos);
        var idx = -1, marker = '';
        if (ih !== -1 && (il === -1 || ih < il)) { idx = ih; marker = ON; }
        else if (il !== -1) { idx = il; marker = OFF; }

        if (idx === -1) {
          var keep = partialSuffix(text, pos);          // hold a split marker
          push(text.slice(pos, text.length - keep));
          tail = keep ? text.slice(text.length - keep) : '';
          break;
        }
        push(text.slice(pos, idx));
        if (marker === ON) {
          syncing = true;
          held += ON;
        } else {
          held += OFF;                                  // complete the frame
          syncing = false;
          out += held;
          held = '';
        }
        pos = idx + marker.length;
      }

      if (held.length > MAX_HELD) {                     // give up on a stuck frame
        out += held;
        held = '';
        syncing = false;
      }
      return out;
    }

    function flush() {
      var out = held;
      held = '';
      syncing = false;
      return out;
    }

    return {
      feed: feed,
      flush: flush,
      isSyncing: function () { return syncing; }
    };
  }

  /* ---------------- session list helpers ---------------- */

  function pad2(n) { return (n < 10 ? '0' : '') + n; }

  // Human readable "time since" for the session navigation. `now` is injectable
  // so the behaviour is unit-testable without freezing the clock.
  function relTime(ms, now) {
    if (!ms || ms <= 0) return '';
    var t = (typeof now === 'number') ? now : Date.now();
    var diff = t - ms;
    if (diff < 0) diff = 0;
    if (diff < 45 * 1000) return '刚刚';
    if (diff < 60 * 60 * 1000) return Math.round(diff / 60000) + ' 分钟前';
    if (diff < 24 * 60 * 60 * 1000) return Math.floor(diff / 3600000) + ' 小时前';

    var d = new Date(ms);
    var hm = pad2(d.getHours()) + ':' + pad2(d.getMinutes());
    var today = new Date(t);
    var yesterday = new Date(t - 24 * 60 * 60 * 1000);
    if (d.getFullYear() === yesterday.getFullYear()
        && d.getMonth() === yesterday.getMonth()
        && d.getDate() === yesterday.getDate()) {
      return '昨天 ' + hm;
    }
    var md = (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + hm;
    if (d.getFullYear() !== today.getFullYear()) {
      return d.getFullYear() + '年' + md;
    }
    return md;
  }

  return { decide: decide, bufferText: bufferText, osc52Extract: osc52Extract,
           b64ToText: b64ToText, syncWriter: syncWriter, relTime: relTime };
});
