/*
 * rtc-transport.js —— noVNC 的 WebRTC 传输层（vps-setup 添加，仅 /vnc-rtc/ 使用）
 *
 * noVNC 1.7 的 RFB 原生支持 RTCDataChannel（core/websock.js 里写得很清楚：
 * "WebSocket and RTCDataChannel are two examples"）。所以这里只做三件事：
 *   1. 建 RTCPeerConnection + DataChannel；
 *   2. 把 offer 发给 /rtc/api/offer，拿回 answer（非 trickle，一次请求）；
 *   3. 把 DataChannel 交给 app/ui.js（它已经改成优先用 window.__RTC_CHANNEL_FACTORY__）。
 *
 * 页面参数：
 *   ?screen=1  主屏（默认）→ 服务端转 127.0.0.1:5901
 *   ?screen=2  第二块屏      → 服务端转 127.0.0.1:5902
 */
(function () {
    'use strict';

    if (!window.RTCPeerConnection) {
        /* 不支持就什么都不设，ui.js 会退回原来的 WebSocket 路径 */
        console.warn('[rtc] 浏览器不支持 WebRTC，回退 WebSocket');
        return;
    }

    var SIGNAL = '/rtc/api/offer';
    var SCREEN = new URLSearchParams(location.search).get('screen') || '1';
    var SIGNAL_TIMEOUT = 12000;
    var STUN = [
        'stun:stun.cloudflare.com:3478',
        'stun:stun.l.google.com:19302',
    ];

    /* 左下角已经有 novnc-badge 的 vpsBadge（编码/帧率），RTC 角标要叠在它上面，
       否则两个都定在 bottom:8px 会完全重合。 */
    function placeBadge(el) {
        var vb = document.getElementById('vpsBadge');
        if (!vb) {
            el.style.bottom = '8px';
            return;
        }
        var h = window.innerHeight - vb.getBoundingClientRect().top;
        el.style.bottom = Math.round(h + 8) + 'px';
    }

    function badge(text, color) {
        var el = document.getElementById('rtcBadge');
        if (!el) {
            el = document.createElement('div');
            el.id = 'rtcBadge';
            /* 默认 41px：vpsBadge 高约 25px + 间距 8px，等它挂载后再按实测高度校正 */
            el.style.cssText = 'position:fixed;left:8px;bottom:41px;z-index:2147483647;' +
                'background:rgba(0,0,0,.65);color:#eee;padding:3px 8px;border-radius:6px;' +
                'font:12px/1.6 sans-serif;user-select:none;pointer-events:none;opacity:.9';
            (document.body || document.documentElement).appendChild(el);
            /* vpsBadge 在页面末尾才加载，轮询等它出现（最多 3 秒） */
            (function waitVps(n) {
                if (document.getElementById('vpsBadge') || n >= 20) {
                    placeBadge(el);
                    return;
                }
                setTimeout(function () { waitVps(n + 1); }, 150);
            })(0);
        }
        placeBadge(el);
        el.textContent = text;
        el.style.color = color || '#eee';
    }

    function iceDone(pc) {
        return new Promise(function (resolve) {
            if (pc.iceGatheringState === 'complete') {
                return resolve();
            }
            var done = false;
            function finish() {
                if (!done) {
                    done = true;
                    resolve();
                }
            }
            pc.addEventListener('icegatheringstatechange', function () {
                if (pc.iceGatheringState === 'complete') {
                    finish();
                }
            });
            setTimeout(finish, 5000);
        });
    }

    /* 每 2 秒把 RTT 和下行速率写到角标上，方便和 WebSocket 通道直接对比 */
    function startStats(pc) {
        var lastBytes = null;
        var lastT = null;
        var timer = setInterval(function () {
            pc.getStats().then(function (stats) {
                var bytes = 0;
                var rtt = null;
                stats.forEach(function (r) {
                    if (r.type === 'data-channel' && typeof r.bytesReceived === 'number') {
                        bytes += r.bytesReceived;
                    }
                    if (r.type === 'candidate-pair' &&
                        (r.selected || r.nominated) &&
                        typeof r.currentRoundTripTime === 'number') {
                        rtt = r.currentRoundTripTime;
                    }
                });
                var now = performance.now();
                var rate = null;
                if (lastBytes !== null && now > lastT) {
                    rate = (bytes - lastBytes) / ((now - lastT) / 1000) / 1048576;
                }
                lastBytes = bytes;
                lastT = now;
                badge('WebRTC 已连接' +
                      (rtt !== null ? ' · RTT ' + Math.round(rtt * 1000) + 'ms' : '') +
                      (rate !== null ? ' · ↓ ' + rate.toFixed(2) + ' MB/s' : ''),
                      '#4caf50');
            }).catch(function () {});
        }, 2000);

        pc.addEventListener('connectionstatechange', function () {
            if (pc.connectionState === 'failed' || pc.connectionState === 'closed') {
                clearInterval(timer);
            }
        });
    }

    window.__RTC_CHANNEL_FACTORY__ = function () {        var pc = new RTCPeerConnection({
            iceServers: STUN.map(function (u) { return { urls: u }; }),
        });
        var dc = pc.createDataChannel('rfb', { ordered: true });

        /* 注意：不能用 dc.onopen = ...，noVNC 的 RFB.attach() 会把 onopen/onmessage
         * 全部接管，直接覆盖掉。必须用 addEventListener 挂自己的监听。 */
        dc.addEventListener('open', function () {
            clearTimeout(timer);
            startStats(pc);
        });
        dc.addEventListener('close', function () {
            badge('WebRTC 已断开', '#e33');
        });

        pc.onconnectionstatechange = function () {
            if (pc.connectionState === 'failed') {
                badge('WebRTC 失败，请用 /new_vnc/ 走 WebSocket', '#e33');
                console.error('[rtc] connection failed');
            }
        };

        var timer = setTimeout(function () {
            if (dc.readyState !== 'open') {
                badge('WebRTC 协商超时，请用 /new_vnc/ 走 WebSocket', '#e33');
            }
        }, SIGNAL_TIMEOUT);
        dc.addEventListener('open', function () { clearTimeout(timer); });

        badge('WebRTC 协商中…', '#ffb300');

        (async function () {
            try {
                var offer = await pc.createOffer();
                await pc.setLocalDescription(offer);
                await iceDone(pc);

                var r = await fetch(SIGNAL + '?screen=' + encodeURIComponent(SCREEN), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        sdp: pc.localDescription.sdp,
                        type: 'offer',
                    }),
                    cache: 'no-store',
                });
                if (!r.ok) {
                    throw new Error('信令返回 ' + r.status + ' ' + (await r.text()).slice(0, 200));
                }
                var ans = await r.json();
                await pc.setRemoteDescription({ type: 'answer', sdp: ans.sdp });
                console.info('[rtc] answer 已应用，等待 ICE');
            } catch (e) {
                clearTimeout(timer);
                console.error('[rtc] 协商失败:', e);
                badge('WebRTC 协商失败，请用 /new_vnc/ 走 WebSocket', '#e33');
            }
        })();

        return dc;
    };
})();
