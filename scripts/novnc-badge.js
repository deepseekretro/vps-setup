/*! novnc-badge.js —— /new_vnc 状态角标（由 /root/vps-setup/scripts/novnc_new_deploy.sh 安装）
 *
 * 目的：随时自证「画面到底是不是无损、有没有被缩放」，不用猜也不用抓包。
 *
 * 它只读、不改变任何东西：
 *   编码/无损性 —— 统计 RFB 各解码器 decodeRect 的实际调用（16=ZRLE 7=Tight 0=Raw ...）
 *                  无损 = 协议保证无量化（ZRLE/Hextile/Raw/Zlib/RRE/TightPNG）
 *                  有损 = JPEG / H.264；Tight 视子编码而定，所以额外盯住 Tight 解码器的
 *                  _jpegRect()：出现过 JPEG 子编码才写「有损」，一块都没有就是真无损。
 *                  切换编码后由 app/novnc-encoder.js 调 __vpsBadgeReset() 清零重新统计。
 *   分辨率      —— 帧尺寸
 *   缩放        —— 画布 CSS 宽 × devicePixelRatio ÷ 帧宽；拆成「布局×DPR」两个因子显示。
 *                  布局 = noVNC 的 Scaling Mode/窗口造成的 CSS 缩放；DPR = 系统显示缩放×浏览器缩放。
 *                  乘积只有 =1.00 才是「1 帧像素对 1 物理像素」，否则浏览器会重采样（发虚）。
 *   帧率/带宽   —— 每秒 FramebufferUpdate 次数、每秒本页收到的字节数（画面静止时为 0，正常）
 *
 * 它挂的是 app 用的那一份 core/rfb.js（ES module 有缓存，import 到的是同一个模块实例），
 * 在原型上包一层，因此不用碰 app/ui.js，也不用 window.UI 暴露任何东西。
 *
 * 隐藏：在地址后加 ?badge=0
 */
(function () {
    'use strict';

    if (/[?&]badge=0(&|$)/.test(location.search)) { return; }

    // 编码号 → [名称, 是否无损]
    var ENC = {
        0:  ['Raw', true],
        1:  ['CopyRect', true],
        2:  ['RRE', true],
        5:  ['Hextile', true],
        6:  ['Zlib', true],
        16: ['ZRLE', true],
        '-260': ['TightPNG', true],
        7:  ['Tight', null],      // null = 视子编码而定（palette/filter 无损，JPEG 有损）
        21: ['JPEG', false],
        50: ['H.264', false]
    };

    var el = document.createElement('div');
    el.id = 'vpsBadge';
    el.style.cssText =
        'position:fixed;left:8px;bottom:8px;z-index:2147483647;' +
        'background:rgba(0,0,0,.66);color:#9aa;padding:3px 8px;border-radius:6px;' +
        'font:12px/1.6 ui-monospace,Menlo,Consolas,monospace;pointer-events:none;' +
        'white-space:nowrap;user-select:none';
    el.textContent = '状态角标：等待连接…';
    (function mount() {
        if (document.body) { document.body.appendChild(el); }
        else { setTimeout(mount, 50); }
    })();

    var S = { rfb: null, bytes: 0, bytesPrev: 0, frames: 0, framesPrev: 0, counts: {}, jpegTiles: 0,
              lastEnc: null, ts: [] };

    // 切换编码时由 novnc-encoder.js 调用：丢掉旧编码的统计，避免误报
    window.__vpsBadgeReset = function () {
        S.counts = {};
        S.jpegTiles = 0;
        S.lastEnc = null;
        S.ts = [];
    };

    function wrapDec(num, dec) {
        var orig = dec.decodeRect.bind(dec);
        dec.decodeRect = function () {
            S.counts[num] = (S.counts[num] || 0) + 1;
            S.lastEnc = num;
            return orig.apply(null, arguments);
        };
        // Tight 的有损/无损取决于子编码：JPEG 子编码走 _jpegRect()（照片块），
        // 其余（调色板/渐变/基本）都是无损。盯着它就能把 Tight 说清楚。
        if (typeof dec._jpegRect === 'function' && !dec.__vpsBadgeJpeg) {
            var origJpeg = dec._jpegRect.bind(dec);
            dec._jpegRect = function () {
                S.jpegTiles++;
                return origJpeg.apply(null, arguments);
            };
            dec.__vpsBadgeJpeg = true;
        }
        dec.__vpsBadge = true;
    }

    function attach(rfb) {
        if (rfb !== S.rfb) { S.rfb = rfb; S.counts = {}; S.jpegTiles = 0; S.lastEnc = null; }
        var d = rfb._decoders;
        if (d) {
            for (var k in d) {
                if (d[k] && !d[k].__vpsBadge) { wrapDec(k, d[k]); }
            }
        }
        var ws = rfb._sock && rfb._sock._websocket;   // Websock 内部持有的 WebSocket / RTCDataChannel
        if (ws && !ws.__vpsBadge && typeof ws.onmessage === 'function') {
            var origMsg = ws.onmessage;
            ws.onmessage = function (e) {
                var n = (e && e.data && (e.data.byteLength || e.data.length)) || 0;
                S.bytes += n;
                return origMsg.call(this, e);
            };
            ws.__vpsBadge = true;
        }
    }

    // 拿到 app 里那个 RFB 实例：包一层它的每帧入口
    import('../core/rfb.js').then(function (m) {
        var RFB = m && m.default;
        if (!RFB || !RFB.prototype || RFB.prototype.__vpsBadge) { return; }
        var orig = RFB.prototype._framebufferUpdate;
        if (typeof orig !== 'function') { return; }
        RFB.prototype._framebufferUpdate = function () {
            attach(this);
            S.frames++;
            // 记到达时刻：平均帧率看不出「一卡一卡」，间隔分布才能
            S.ts.push(performance.now());
            if (S.ts.length > 3000) { S.ts.shift(); }
            return orig.apply(this, arguments);
        };
        RFB.prototype.__vpsBadge = true;
    }).catch(function () { /* 取不到就保持「等待连接…」，不影响页面 */ });

    function tick() {
        var fps = S.frames - S.framesPrev; S.framesPrev = S.frames;
        var bps = S.bytes - S.bytesPrev; S.bytesPrev = S.bytes;
        var rfb = S.rfb;
        var state = rfb ? rfb._rfbConnectionState : null;
        var parts = [];
        var color = '#9aa';

        if (!rfb || state !== 'connected') {
            parts.push(state ? ('未连接（' + state + '）') : '等待连接…');
        } else {
            var num = S.lastEnc, name = null, lossless = null;
            if (num !== null && num !== undefined) {
                if (ENC[num]) { name = ENC[num][0]; lossless = ENC[num][1]; }
                else { name = '编码' + num; }
                // Tight：只有 JPEG 子编码有损；一块 JPEG 都没有就是真无损（实测才敢这么说）
                // 注意：解码器实例的键是字符串（'7'），不能用 num === 7 严格比较
                if (String(num) === '7') { lossless = (S.jpegTiles === 0); }
            } else {
                name = '等待画面';
            }
            parts.push(name + (lossless === true ? '·无损' : lossless === false ? '·有损' : '')
                       + (String(num) === '7' && S.jpegTiles > 0 ? 'JPEG×' + S.jpegTiles : ''));
            color = lossless === true ? '#8cffa8' : lossless === false ? '#ffc46b' : '#9aa';

            var c = rfb._display && rfb._display._target;
            if (c && c.width) {
                parts.push(c.width + '×' + c.height);
                // 拆成两个因子，避免把「客户端的显示缩放」误读成「noVNC 在缩放」：
                //   布局 = 画布 CSS 宽 ÷ 帧宽   （noVNC 的 Scaling Mode / 窗口布局造成）
                //   DPR  = window.devicePixelRatio（系统显示缩放 × 浏览器缩放，noVNC 管不着）
                //   物理 = 布局 × DPR，即 1 帧像素最终画到几个物理像素上；只有 =1 才不是重采样
                var cssRatio = (c.clientWidth || c.width) / c.width;
                var dpr = window.devicePixelRatio || 1;
                var eff = cssRatio * dpr;
                if (Math.abs(eff - 1) < 0.01) {
                    parts.push('1:1');
                } else {
                    parts.push('×' + eff.toFixed(2) + '(布局' + cssRatio.toFixed(2) +
                               '·DPR' + dpr.toFixed(2) + (eff > 1 ? '·发虚' : '·缩小') + ')');
                }
            }
            // Tight 会把一帧拆成好几条 FBU 消息，直接数消息会读出「195fps / 间隔 0ms」这种
            // 没有意义的数（p50=0 就是征兆）。先把「相邻到达间隔 <10ms」的连续消息合并成
            // 一次画面，再统计画面率和画面间隔 —— 这才是眼睛看到的节奏。
            var now = performance.now(), starts = [], prev = -1e9, i;
            for (i = 0; i < S.ts.length; i++) {
                if (S.ts[i] - prev >= 10) { starts.push(S.ts[i]); }
                prev = S.ts[i];
            }
            var vis = 0;
            for (i = 0; i < starts.length; i++) {
                if (now - starts[i] <= 1000) { vis++; }
            }
            parts.push(vis > 0 ? vis + 'fps' : '静止');
            // 间隔 p50/p95/最大：最近 5 秒内相邻两次画面的到达间隔（毫秒）。
            // 30fps 应该 p50≈33ms 且 p95/最大 贴着 33；>100ms 的空档按次计数。
            var iv = [];
            for (i = 1; i < starts.length; i++) {
                if (now - starts[i] <= 5000) { iv.push(starts[i] - starts[i - 1]); }
            }
            if (iv.length >= 3) {
                var gaps = 0;
                for (i = 0; i < iv.length; i++) { if (iv[i] > 100) { gaps++; } }
                iv.sort(function (a, b) { return a - b; });
                parts.push('间隔' + Math.round(iv[Math.floor(iv.length * 0.5)]) + '/'
                           + Math.round(iv[Math.floor(iv.length * 0.95)]) + '/'
                           + Math.round(iv[iv.length - 1]) + 'ms'
                           + (gaps > 0 ? ' 卡顿' + gaps + '/5s' : ''));
            }
            parts.push(bps >= 1024 ? Math.round(bps / 1024) + 'KB/s'
                                   : (bps > 0 ? bps + 'B/s' : '0KB/s'));
        }

        el.textContent = parts.join('  ');
        el.style.color = color;
    }

    setInterval(tick, 1000);
    tick();
})();
