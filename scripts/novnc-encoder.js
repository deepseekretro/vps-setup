/*! novnc-encoder.js —— /new_vnc 的「编码」下拉框（由 /root/vps-setup/scripts/novnc_new_deploy.sh 安装）
 *
 * 位置：设置面板「高级」里、品质(Quality)那一项的上方；默认 ZRLE（无损）。
 *
 * 为什么需要它：
 *   x11vnc(libvncserver) 挑什么编码，很大程度看客户端广告了什么 —— 只要广告列表里出现
 *   Tight/TightPNG，它就优先 Tight+JPEG（有损，但 CPU 便宜很多）；只广告 ZRLE 时走无损。
 *   这个下拉框让「广告什么」由你决定：一次只广告选中的那一个编码（CopyRect/Raw 始终保留，
 *   那是滚动与兜底必需的）。实际生效的编码看左下角状态角标 —— 它统计真实解码器调用，不靠猜。
 *
 * 机制：
 *   - core/rfb.js 的 _sendEncodings() 会调用 window.__vpsEncodings() 取广告列表
 *     （见 novnc_new_deploy.sh 里 patch_page() 的第 4 步补丁）。
 *   - 本文件是经典脚本，先于页面 module 执行，所以连接时就已经生效；
 *     切换时立即重发 SetEncodings 并请求一次整屏刷新（不用重连，下一帧生效）。
 *   - 选择记在 localStorage（和 noVNC 自己的设置一样持久）；地址栏 ?encoding=xxx 可临时指定，
 *     优先级高于本地记录（但不会覆盖它）。
 *   - 想回默认：把下拉框选回「ZRLE（无损 · 默认）」，左下角角标变回绿色即生效。
 *
 * 关掉它：删掉 vnc.html 里那行 <script src="app/novnc-encoder.js"></script>（或删本文件）。
 */
(function () {
    'use strict';

    // [值, RFB 编码号, 显示名]
    var OPTIONS = [
        ['zrle',    16, 'ZRLE（无损 · 默认）'],
        ['tight',    7, 'Tight（JPEG 有损 · 最省 CPU）'],
        ['hextile',  5, 'Hextile（无损 · 省 CPU、更费带宽）'],
        ['zlib',     6, 'Zlib（无损）'],
        ['raw',      0, 'Raw（无损 · 最费带宽，仅诊断用）']
    ];
    var DEFAULT_KEY = 'zrle';
    var STORE_KEY = 'vpsEncoding';     // localStorage 里的键名
    var PARAM_KEY = 'encoding';        // ?encoding=tight

    var cur = DEFAULT_KEY;             // 当前选择
    var rfb = null;                    // app 里的 RFB 实例（切换时要用它重发编码）
    var RFB = null;                    // core/rfb.js 的模块导出（要用 RFB.messages）
    var sel = null;                    // 下拉框元素

    function find(key) {
        for (var i = 0; i < OPTIONS.length; i++) {
            if (OPTIONS[i][0] === key) { return OPTIONS[i]; }
        }
        return null;
    }

    // 页面 core/rfb.js 就是靠这个函数拿到「要广告的编码列表」
    window.__vpsEncodings = function () {
        var o = find(cur) || find(DEFAULT_KEY);
        return [o[1]];
    };

    // 给测试/脚本用的极简接口
    window.__vpsEncoding = {
        list: function () { return OPTIONS.map(function (o) { return o[0]; }); },
        get: function () { return cur; },
        set: function (key) { apply(key, true); }
    };

    function initial() {
        var key = null, v;
        try {
            v = new URLSearchParams(window.location.search).get(PARAM_KEY);
            if (v && find(v)) { key = v; }
        } catch (e) { /* 老浏览器：忽略 */ }
        if (!key) {
            try {
                v = window.localStorage.getItem(STORE_KEY);
                if (v && find(v)) { key = v; }
            } catch (e) { /* 隐私模式：忽略 */ }
        }
        return key || DEFAULT_KEY;
    }

    // 切编码：改状态 → 重发 SetEncodings → 请求一次整屏刷新（否则旧编码的像素会留在屏幕上）
    function apply(key, persist) {
        if (!find(key)) { key = DEFAULT_KEY; }
        var changed = (key !== cur);
        cur = key;
        if (sel && sel.value !== key) { sel.value = key; }
        if (persist) {
            try { window.localStorage.setItem(STORE_KEY, key); } catch (e) { /* 忽略 */ }
        }
        if (!changed || !rfb || !rfb._sock) { return; }
        try {
            rfb._sendEncodings();
            if (RFB && RFB.messages && rfb._rfbConnectionState === 'connected') {
                RFB.messages.fbUpdateRequest(rfb._sock, false, 0, 0, rfb._fbWidth, rfb._fbHeight);
            }
        } catch (e) { /* 切换失败不影响页面：下次连接会按新选择重发 */ }
        // 让状态角标重算（否则会把上一段时间的统计/JPEG 计数带过来）
        if (typeof window.__vpsBadgeReset === 'function') { window.__vpsBadgeReset(); }
    }

    // 在「高级」面板里、品质(Quality)那一项的上方插入下拉框
    function build() {
        var anchor = document.getElementById('noVNC_setting_quality');
        var li = anchor && anchor.closest ? anchor.closest('li') : null;
        if (!li || !li.parentNode) { return false; }
        if (document.getElementById('vpsEncodingItem')) { return true; }

        var item = document.createElement('li');
        item.id = 'vpsEncodingItem';

        var label = document.createElement('label');
        label.setAttribute('for', 'noVNC_setting_encoding');
        label.setAttribute('translate', 'no');          // 不让 noVNC 的 i18n 去翻它
        label.textContent = '编码：';
        item.appendChild(label);

        sel = document.createElement('select');
        sel.id = 'noVNC_setting_encoding';
        sel.setAttribute('translate', 'no');
        sel.title = '选择 RFB 编码；实际生效的编码看左下角状态角标';
        for (var i = 0; i < OPTIONS.length; i++) {
            var op = document.createElement('option');
            op.value = OPTIONS[i][0];
            op.textContent = OPTIONS[i][2];
            sel.appendChild(op);
        }
        sel.value = cur;
        sel.addEventListener('change', function () { apply(sel.value, true); });
        item.appendChild(sel);

        li.parentNode.insertBefore(item, li);
        return true;
    }

    // 挂钩 app 用的那份 core/rfb.js（ES module 有缓存，import 到的是同一个模块实例）
    function hook() {
        var url;
        try { url = new URL('core/rfb.js', document.baseURI).href; }
        catch (e) { return; }
        import(url).then(function (m) {
            RFB = m && m.default;
            if (!RFB || !RFB.prototype) { return; }
            ['_sendEncodings', '_framebufferUpdate'].forEach(function (fn) {
                var orig = RFB.prototype[fn];
                if (typeof orig !== 'function' || orig.__vpsEnc) { return; }
                var wrapped = function () {
                    rfb = this;      // 记下实例：切换编码时要靠它重发
                    return orig.apply(this, arguments);
                };
                wrapped.__vpsEnc = true;
                RFB.prototype[fn] = wrapped;
            });
        }).catch(function () { /* 拿不到模块就退化成「连接时生效、切换需重连」，不影响页面 */ });
    }

    cur = initial();
    if (!build()) {
        // 正常情况下本脚本就在 </body> 前，元素已存在；万一被挪到 <head> 就等 DOM 就绪再建。
        document.addEventListener('DOMContentLoaded', build);
    }
    hook();
})();
