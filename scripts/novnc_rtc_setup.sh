#!/usr/bin/env bash
# novnc_rtc_setup.sh —— noVNC over WebRTC（直连 UDP）通道的安装 / 卸载 / 自检
#
# 装出来的是什么：
#   /opt/vnc-rtc/src + bin/vnc-rtc-bridge   Go 桥（pion v4）：WebRTC DataChannel <-> TCP
#   /usr/local/bin/vnc-rtc-bridge           wrapper，读 /etc/default/vnc-rtc
#   /etc/systemd/system/vnc-rtc.service     信令 127.0.0.1:6091，ICE UDP 8190-8192（8193 留给音频直发）
#   /opt/tigervnc-1.16.2/bin/x0vncserver
#                                          5903，支持 ContinuousUpdates + 剪贴板
#                                          （1.12 没有剪贴板，1.15 才加，见下）
#   /usr/local/bin/x0vnc-view               通用 TigerVNC 实例入口（5901/5902/5903 共用）
#   /usr/local/bin/x0vnc-main               RTC 专用 wrapper，裁剪区读 /etc/vnc-rtc/x0vnc-geometry
#   /etc/systemd/system/x0vnc-main.service
#   /usr/share/novnc-rtc                    novnc-new 的副本：页面不变，只换传输层
#   nginx: /vnc-rtc/  /rtc/api/
#
# 明确不碰：
#   * x11vnc@1 / x11vnc-screen2 的任何 unit 与命令行（-defer 20 -wait 20 原样）
#   * /usr/share/novnc-new（WS 通道）
#   * 音频链路（8189/udp、MediaMTX）
#
# 为什么主屏用 TigerVNC 而不是 x11vnc：
#   x11vnc 不支持 ContinuousUpdates，客户端只能"问一次给一帧"，连续动画面 = 1/RTT。
#   200ms RTT 实测：x11vnc 3.2 帧/秒，X0tigervnc(CU) 12-17 帧/秒，带宽反而更低。
#   第二块屏（screen=2）仍然走 x11vnc 的 5902，保持原样。
#
# 用法：
#   ./novnc_rtc_setup.sh --install --public-ip 1.2.3.4
#   ./novnc_rtc_setup.sh --install            # 已有 /etc/default/vnc-rtc 就沿用其中的 PUBLIC_IP
#   ./novnc_rtc_setup.sh --check
#   ./novnc_rtc_setup.sh --uninstall
#
# 注意：重跑 vnc_desktop_setup.sh 会重写 /usr/local/bin/screen2ctl（它会丢掉
#       RTC 换区钩子），之后需要再跑一次本脚本的 --install。
#
# 宿主机（LXC 外面）还要放行 UDP：脚本结尾会把命令打出来。

set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PAYLOAD="$SELF_DIR/vnc-rtc"

RTC_DIR=/opt/vnc-rtc
RTC_BIN="$RTC_DIR/bin/vnc-rtc-bridge"
RTC_SRC="$RTC_DIR/src"
RTC_WRAP=/usr/local/bin/vnc-rtc-bridge
RTC_CFG=/etc/default/vnc-rtc
RTC_UNIT=/etc/systemd/system/vnc-rtc.service

X0_WRAP=/usr/local/bin/x0vnc-main
X0_UNIT=/etc/systemd/system/x0vnc-main.service
X0_GEOM_DIR=/etc/vnc-rtc
X0_GEOM="$X0_GEOM_DIR/x0vnc-geometry"

NOVNC_SRC=${NOVNC_SRC:-/usr/share/novnc-new}
NOVNC_RTC=${NOVNC_RTC:-/usr/share/novnc-rtc}

MODE=""
PUBLIC_IP=""
NO_RESTART=0

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --install)   MODE=install ;;
        --uninstall) MODE=uninstall ;;
        --check)     MODE=check ;;
        --public-ip) shift; PUBLIC_IP="${1:-}" ;;
        --novnc-src) shift; NOVNC_SRC="${1:-}" ;;
        --no-restart) NO_RESTART=1 ;;
        -h|--help)   usage ;;
        *) die "未知参数: $1（--help 看用法）" ;;
    esac
    shift
done
[ -n "$MODE" ] || usage
[ "$(id -u)" = 0 ] || die "需要 root"

# ---------------------------------------------------------------- nginx

nginx_detect() {
    if [ -x /usr/local/openresty/bin/openresty ]; then
        NGINX=/usr/local/openresty/bin/openresty
        NGINX_UNIT=openresty
    elif command -v nginx >/dev/null 2>&1; then
        NGINX=$(command -v nginx)
        NGINX_UNIT=nginx
    else
        NGINX=""; NGINX_UNIT=""
    fi
    CONF=""
    for c in /usr/local/openresty/nginx/conf/conf.d/50-novnc.conf \
             /etc/nginx/conf.d/50-novnc.conf \
             /etc/nginx/sites-enabled/novnc.conf; do
        [ -f "$c" ] && { CONF="$c"; break; }
    done
}

nginx_reload() {
    [ -n "${NGINX:-}" ] || { warn "没找到 nginx，跳过 reload"; return 0; }
    "$NGINX" -t >/dev/null 2>&1 || { "$NGINX" -t; die "nginx 配置校验失败，没 reload"; }
    if [ -n "${NGINX_UNIT:-}" ] && systemctl is-active --quiet "$NGINX_UNIT" 2>/dev/null; then
        systemctl reload "$NGINX_UNIT"
    else
        "$NGINX" -s reload 2>/dev/null || true
    fi
}

# 把 payload 里的 location 块插到 server { ... } 的最后（紧跟收尾大括号之前）
nginx_insert() {
    [ -n "${CONF:-}" ] || { warn "没找到 noVNC 的 nginx 配置文件，跳过（RTC 页面会 404）"; return 0; }
    python3 - "$CONF" "$PAYLOAD/50-novnc-rtc.conf" <<'PY'
import sys
conf, snip = sys.argv[1], sys.argv[2]
s = open(conf).read()
block = open(snip).read().rstrip("\n")
if "/vnc-rtc/" in s:
    print("  nginx: /vnc-rtc/ 已在，跳过")
    sys.exit(0)
i = s.rstrip().rfind("}")
if i < 0:
    sys.exit("  nginx: 找不到 server 的收尾大括号")
head = s[:i].rstrip("\n")
tail = s[i:]
open(conf, "w").write(head + "\n\n" + block + "\n" + tail)
print("  nginx: 已插入 /vnc-rtc/ 与 /rtc/api/")
PY
}

nginx_remove() {
    [ -n "${CONF:-}" ] && [ -f "$CONF" ] || return 0
    python3 - "$CONF" <<'PY'
import sys
conf = sys.argv[1]
s = open(conf).read()
mark = "    # ---- noVNC over WebRTC DataChannel: /vnc-rtc ----"
i = s.find(mark)
if i < 0:
    sys.exit(0)
j = s.rstrip().rfind("}")
open(conf, "w").write(s[:i].rstrip("\n") + "\n" + s[j:])
print("  nginx: 已移除 /vnc-rtc/ 块")
PY
}

# ---------------------------------------------------------------- 自检

do_check() {
    nginx_detect
    local ok=0
    printf '%-34s' "x0vnc-main 服务"
    systemctl is-active --quiet x0vnc-main && echo "active" || { echo "未运行"; ok=1; }
    printf '%-34s' "vnc-rtc 服务"
    systemctl is-active --quiet vnc-rtc && echo "active" || { echo "未运行"; ok=1; }
    local wsbackend wsname
    wsbackend=$(cat /etc/vnc-ws/backend 2>/dev/null || echo x11vnc)
    [ "$wsbackend" = tigervnc ] && wsname=TigerVNC || wsname=x11vnc
    printf '%-34s' "5901 ${wsname} / 5903 TigerVNC"
    ss -lnt 2>/dev/null | grep -q ':5901 ' && ss -lnt 2>/dev/null | grep -q ':5903 ' \
        && echo "都在" || { echo "有缺失"; ok=1; }
    printf '%-34s' "5903 TigerVNC 版本"
    local tvbin="" v=""
    for b in /opt/tigervnc-1.16.2/bin/x0vncserver /opt/tigervnc-1.15/bin/x0vncserver /usr/bin/X0tigervnc; do
        [ -x "$b" ] && { tvbin="$b"; break; }
    done
    v=$("${tvbin:-/bin/false}" -version 2>/dev/null | head -1)
    if [ -n "$v" ]; then
        echo "$v" | sed 's/.*version //'
        case "$v" in
            *"version 1.1"[5-9]*|*"version 1.2"*) ;;
            *) echo "    [!] 低于 1.15：剪贴板不可用"; ok=1 ;;
        esac
    else
        echo "找不到"; ok=1
    fi
    printf '%-34s' "UDP 8190-8192"
    if ss -lun 2>/dev/null | grep -qE ':(8190|8191|8192) '; then
        echo "已绑定"
    else
        echo "空闲（pion 按需绑定，正常）"
    fi
    printf '%-34s' "RTC 页面文件"
    [ -f "$NOVNC_RTC/app/rtc-transport.js" ] && [ -f "$NOVNC_RTC/vnc.html" ] \
        && echo "在" || { echo "缺"; ok=1; }
    printf '%-34s' "rtc-transport 已挂到页面"
    grep -q 'app/rtc-transport.js' "$NOVNC_RTC/vnc.html" 2>/dev/null && echo "是" || { echo "否"; ok=1; }
    printf '%-34s' "ui.js 已接 DataChannel"
    grep -q '__RTC_CHANNEL_FACTORY__' "$NOVNC_RTC/app/ui.js" 2>/dev/null && echo "是" || { echo "否"; ok=1; }
    printf '%-34s' "nginx /vnc-rtc/"
    grep -q '/vnc-rtc/' "${CONF:-/dev/null}" 2>/dev/null && echo "已配置" || { echo "未配置"; ok=1; }
    printf '%-34s' "screen2ctl 已支持 RTC 换区"
    grep -q 'retarget_rtc' /usr/local/bin/screen2ctl 2>/dev/null && echo "是" || { echo "否"; ok=1; }
    printf '%-34s' "信令 /health"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
        http://127.0.0.1:6091/health 2>/dev/null || true)
    if [ "$code" = "200" ]; then echo "HTTP 200"; else echo "无响应($code)"; ok=1; fi
    printf '%-34s' "信令 /rtc/api/（经 nginx）"
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 \
        -X POST -H 'Content-Type: application/json' -d '{}' \
        https://127.0.0.1/rtc/api/offer 2>/dev/null || true)
    if [ "$code" = "400" ]; then echo "HTTP 400（预期）"; else echo "异常($code)"; ok=1; fi
    [ "$ok" = 0 ] && log "自检通过" || warn "有项目不正常，见上"
    return "$ok"
}

# ---------------------------------------------------------------- TigerVNC

TIGERVNC_VER=${TIGERVNC_VER:-1.16.2}
TIGERVNC_SHA256_1162=5b70c84baefc09a030cfc78315c34ccb55b2a0dde4092b7da67a1962c5f0dea6

install_tigervnc() {
    local dir="/opt/tigervnc-$TIGERVNC_VER"
    if [ -x "$dir/bin/x0vncserver" ]; then
        log "TigerVNC $TIGERVNC_VER 已在（$dir）"
        return 0
    fi
    log "下载 TigerVNC $TIGERVNC_VER（1.12 没有剪贴板，必须用 >=1.15）"
    local url="https://sourceforge.net/projects/tigervnc/files/stable/$TIGERVNC_VER/tigervnc-$TIGERVNC_VER.x86_64.tar.gz/download"
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL --retry 2 --max-time 300 -o "$tmp/tv.tar.gz" "$url" \
        || { rm -rf "$tmp"; die "下载 TigerVNC 失败（可以手动放到 $dir）"; }
    local sum
    sum=$(sha256sum "$tmp/tv.tar.gz" | awk '{print $1}')
    if [ "$TIGERVNC_VER" = "1.16.2" ] && [ "$sum" != "$TIGERVNC_SHA256_1162" ]; then
        rm -rf "$tmp"
        die "TigerVNC 校验和不匹配：$sum"
    fi
    install -d "$dir"
    tar xzf "$tmp/tv.tar.gz" -C "$dir" --strip-components=2
    rm -rf "$tmp"
    [ -x "$dir/bin/x0vncserver" ] || die "解压后没有 $dir/bin/x0vncserver"
    "$dir/bin/x0vncserver" -version | sed 's/^/  /'
}

# ---------------------------------------------------------------- 安装

do_install() {
    [ -f "$PAYLOAD/main.go" ] || die "找不到载荷：$PAYLOAD/main.go"
    [ -d "$NOVNC_SRC" ] || die "找不到 $NOVNC_SRC（noVNC 装了吗？可以用 --novnc-src 指定）"

    # 1) TigerVNC（必须 >= 1.15：1.12 的 x0vncserver 没有剪贴板）
    install_tigervnc

    # 2) Go
    local go=""
    if command -v go >/dev/null 2>&1; then go=$(command -v go)
    elif [ -x /usr/local/go/bin/go ]; then go=/usr/local/go/bin/go
    fi
    [ -n "$go" ] || die "没找到 go。装一个（>=1.21）再跑：
    curl -fsSL https://go.dev/dl/go1.23.4.linux-amd64.tar.gz | tar -C /usr/local -xz
    export PATH=/usr/local/go/bin:\$PATH"

    # 3) 编译桥
    log "编译 vnc-rtc-bridge（$($go version)）"
    install -d "$RTC_SRC" "$RTC_DIR/bin"
    install -m 0644 "$PAYLOAD/main.go" "$RTC_SRC/main.go"
    install -m 0644 "$PAYLOAD/go.mod" "$RTC_SRC/go.mod"
    install -m 0644 "$PAYLOAD/go.sum" "$RTC_SRC/go.sum"
    ( cd "$RTC_SRC" && CGO_ENABLED=0 "$go" mod download >/dev/null 2>&1 || true )
    ( cd "$RTC_SRC" && CGO_ENABLED=0 "$go" build -trimpath -ldflags "-s -w" -o "$RTC_BIN" . ) \
        || die "编译失败"
    chmod 0755 "$RTC_BIN"

    # 4) 配置（只在缺的时候写，别覆盖用户改过的）
    if [ ! -f "$RTC_CFG" ]; then
        log "写 $RTC_CFG（PUBLIC_IP=${PUBLIC_IP:-未指定}）"
        cat > "$RTC_CFG" <<EOF
# noVNC over WebRTC 桥的配置
# VPS 换了公网 IP 就改这里，然后 systemctl restart vnc-rtc
PUBLIC_IP=${PUBLIC_IP}
LISTEN=127.0.0.1:6091
ICE_PORT_MIN=8190
ICE_PORT_MAX=8192

# SCTP 最小拥塞窗口（字节）。pion 默认初始只有 4380 字节，200ms RTT 下
# 实测 4MB 要 17s；设成 256KB 后同样的链路 3.8s。丢包链路上 512KB 反而更差。
SCTP_MIN_CWND=262144

# 主屏走 TigerVNC 5903（支持 CU），第二块屏沿用 x11vnc 5902
TARGET1=127.0.0.1:5903
TARGET2=127.0.0.1:5902
EOF
        chmod 0644 "$RTC_CFG"
    elif [ -n "$PUBLIC_IP" ]; then
        sed -i "s|^PUBLIC_IP=.*|PUBLIC_IP=$PUBLIC_IP|" "$RTC_CFG"
    fi
    if ! grep -q '^TARGET1=' "$RTC_CFG"; then
        printf '\n# RTC 主屏后端（TigerVNC 5903，支持 ContinuousUpdates）\nTARGET1=127.0.0.1:5903\nTARGET2=127.0.0.1:5902\n' >> "$RTC_CFG"
    fi
    if ! grep -q '^PUBLIC_IP=.\+' "$RTC_CFG"; then
        warn "$RTC_CFG 里 PUBLIC_IP 是空的：直连 UDP 会拿不到公网候选（用 --public-ip 指定）"
    fi

    log "写 $RTC_WRAP"
    cat > "$RTC_WRAP" <<'EOF'
#!/bin/sh
# 读取 /etc/default/vnc-rtc 后启动桥
[ -r /etc/default/vnc-rtc ] && . /etc/default/vnc-rtc
exec /opt/vnc-rtc/bin/vnc-rtc-bridge \
    -listen "${LISTEN:-127.0.0.1:6091}" \
    -public-ip "${PUBLIC_IP:-}" \
    -port-min "${ICE_PORT_MIN:-8190}" \
    -port-max "${ICE_PORT_MAX:-8192}" \
    -sctp-min-cwnd "${SCTP_MIN_CWND:-262144}" \
    -target1 "${TARGET1:-127.0.0.1:5903}" \
    -target2 "${TARGET2:-127.0.0.1:5902}" \
    "$@"
EOF
    chmod 0755 "$RTC_WRAP"

    log "写 $RTC_UNIT"
    cat > "$RTC_UNIT" <<'EOF'
[Unit]
Description=noVNC WebRTC DataChannel bridge (UDP -> VNC)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vnc-rtc-bridge
Restart=always
RestartSec=2
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF

    # 5) TigerVNC 抓屏（5903）
    log "写 $X0_WRAP / $X0_UNIT"
    install -d "$X0_GEOM_DIR"
    [ -f "$X0_GEOM" ] || echo "1920x1080+0+0" > "$X0_GEOM"
    install -m 0755 "$PAYLOAD/x0vnc-view" /usr/local/bin/x0vnc-view
    install -m 0755 "$PAYLOAD/x0vnc-main" "$X0_WRAP"
    cat > "$X0_UNIT" <<'EOF'
[Unit]
Description=TigerVNC scraping server for the WebRTC channel (port 5903)
After=vnc-desktop@1.service
Wants=vnc-desktop@1.service

[Service]
Type=simple
Environment=DISPLAY=:1
ExecStart=/usr/local/bin/x0vnc-main
Restart=always
RestartSec=2
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

    # 6) noVNC 副本 + 补丁
    log "准备 $NOVNC_RTC（从 $NOVNC_SRC 复制）"
    if [ ! -d "$NOVNC_RTC" ]; then
        cp -a "$NOVNC_SRC" "$NOVNC_RTC"
    fi
    install -m 0644 "$PAYLOAD/rtc-transport.js" "$NOVNC_RTC/app/rtc-transport.js"
    python3 - "$NOVNC_RTC" <<'PY'
import re, sys
root = sys.argv[1]

def patch(name, fn):
    p = root + "/" + name
    s = open(p).read()
    out = fn(s)
    if out == s:
        print("  %s: 无需改动" % name)
        return
    open(p, "w").write(out)
    print("  %s: 已打补丁" % name)

def vnc_html(s):
    if "app/rtc-transport.js" in s:
        return s
    assert "</head>" in s
    return s.replace("</head>", "    <script src=\"app/rtc-transport.js\"></script>\n</head>", 1)

def ui_js(s):
    if "__RTC_CHANNEL_FACTORY__" in s:
        return s
    lines = s.split("\n")
    for i, l in enumerate(lines):
        if "new RFB(document.getElementById('noVNC_container')" in l:
            j = i + 1
            assert "url.href," in lines[j], "ui.js: RFB 第二行不是 url.href"
            indent = lines[j][:len(lines[j]) - len(lines[j].lstrip())]
            lines[j] = indent + "(window.__RTC_CHANNEL_FACTORY__ ? window.__RTC_CHANNEL_FACTORY__() : null) || url.href,"
            return "\n".join(lines)
    raise SystemExit("ui.js: 找不到 new RFB(...) 构造")

def dual_js(s):
    if "/vnc-rtc/vnc.html" in s:
        return s
    s2 = re.sub(r"window\.open\('/vnc2', 'novnc-screen2',",
                "window.open('/vnc-rtc/vnc.html?autoconnect=true&reconnect=true&screen=2&shared=1',\n"
                "                            'novnc-screen2',", s, count=1)
    if s2 == s:
        print("  dualscreen-status.js: 没找到 window.open('/vnc2'...)（版本不同？）")
    return s2

def rfb_js(s):
    if "_pipelineRequests" in s:
        return s
    anchor = ("        RFB.messages.fbUpdateRequest(this._sock, false, 0, 0, "
              "this._fbWidth, this._fbHeight);\n\n        this._updateConnectionState('connected');")
    if anchor not in s:
        print("  rfb.js: 找不到请求/连接状态锚点，跳过 pipeline 补丁（CU 下本来也用不到）")
        return s
    block = """        RFB.messages.fbUpdateRequest(this._sock, false, 0, 0, this._fbWidth, this._fbHeight);

        /* vps-setup 实验：?pipeline=N 预先多压几个 FramebufferUpdateRequest。
           x11vnc 不支持 ContinuousUpdates 时，默认 1 个请求 = 1/RTT 帧；
           实测 200ms RTT 下 1→3.2 帧/秒，2→4.5 帧/秒，3 个无额外收益。
           TigerVNC(5903) 走 CU 时客户端根本不发请求，这个参数没有影响。 */
        this._pipelineRequests = Math.max(1, Math.min(4,
            parseInt(new URLSearchParams(location.search).get('pipeline') || '2', 10) || 2));
        if (this._pipelineRequests > 1) {
            for (let i = 1; i < this._pipelineRequests; i++) {
                RFB.messages.fbUpdateRequest(this._sock, true, 0, 0, this._fbWidth, this._fbHeight);
            }
            Log.Info("pipeline = " + this._pipelineRequests);
        }

        this._updateConnectionState('connected');"""
    return s.replace(anchor, block, 1)

patch("vnc.html", vnc_html)
patch("app/ui.js", ui_js)
patch("app/dualscreen-status.js", dual_js)
patch("core/rfb.js", rfb_js)
PY

    # 7) nginx
    nginx_detect
    nginx_insert
    nginx_reload

    # 8) screen2ctl：开/收第二块屏时把 TigerVNC 的裁剪区一起切
    patch_screen2ctl

    # 9) 起服务
    systemctl daemon-reload
    systemctl enable x0vnc-main vnc-rtc >/dev/null 2>&1 || true
    if [ "$NO_RESTART" = 0 ]; then
        systemctl restart x0vnc-main vnc-rtc
        sleep 2
    else
        systemctl start x0vnc-main vnc-rtc 2>/dev/null || true
    fi

    log "完成。自检："
    do_check || true

    cat <<EOF

宿主机（LXC 外面）还要做两件事，脚本在容器里做不了：

  1) 把 UDP 8190-8193 转发进容器（8190-8192 视频桥，8193 音频直发；容器地址按实际改）：
     iptables -t nat -A PREROUTING -i ens3 -p udp --dport 8190:8193 \\
         -j DNAT --to-destination $(ip -4 -o addr show eth0 2>/dev/null | head -1 | awk '{print $4}' | cut -d/ -f1):8190-8193

  2) 云防火墙放行 UDP 8190-8193。

入口：
  https://<你的域名>/vnc-rtc/        主屏（WebRTC，直连 UDP）
  https://<你的域名>/new_vnc/        WebSocket 老通道（原样保留）
  https://<你的域名>/vnc-rtc/vnc.html?...&screen=2   第二块屏
EOF
}

# ---------------------------------------------------------------- screen2ctl 补丁

patch_screen2ctl() {
    local f=/usr/local/bin/screen2ctl
    if [ ! -f "$f" ]; then
        warn "没有 $f（没装第二块屏？跳过）"
        return 0
    fi
    if grep -q 'retarget_rtc' "$f"; then
        log "screen2ctl 已支持 RTC 换区，跳过"
        return 0
    fi
    log "给 screen2ctl 加 RTC 换区钩子"
    cp "$f" "/var/backups/screen2ctl.pre-rtc.$(date +%s)"
    python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

anchor = "    return False\n\n\n# ------------------------------------------------------------------ 服务\n"
add = '''    return False


RTC_GEOM = "/etc/vnc-rtc/x0vnc-geometry"
RTC_UNIT = "x0vnc-main.service"


def root_geometry():
    """当前 root 分辨率（xrandr 的 current W x H）。"""
    out = run(["xrandr", "--current"])[0].stdout or ""
    m = re.search(r"current (\\d+) x (\\d+)", out)
    return (int(m.group(1)), int(m.group(2))) if m else None


def retarget_rtc(rect=None):
    """RTC 通道的后端是 TigerVNC（5903），裁剪区域只能在启动时定：
    开/收第二块屏时改配置并重启它。没装这套东西就静默跳过。
    只影响 /vnc-rtc/，WS 通道的 x11vnc 一个字节都不碰。"""
    if not os.path.isfile(RTC_GEOM):
        return
    if rect:
        geom = "%dx%d+%d+%d" % (rect["w"], rect["h"], rect["x"], rect["y"])
    else:
        w, h = root_geometry() or (PW, PH)
        geom = "%dx%d+0+0" % (w, h)
    try:
        with open(RTC_GEOM) as f:
            old = f.read().strip()
    except OSError:
        old = ""
    if geom == old:
        return
    try:
        with open(RTC_GEOM, "w") as f:
            f.write(geom + "\\n")
    except OSError as e:
        log("RTC 几何写入失败: %s" % e)
        return
    if run(["systemctl", "cat", RTC_UNIT], timeout=5)[0].returncode != 0:
        return
    run(["systemctl", "restart", RTC_UNIT], timeout=40)
    log("RTC 视图几何 -> %s" % geom)


# ------------------------------------------------------------------ 服务
'''
if s.count(anchor) != 1:
    raise SystemExit("screen2ctl: 找不到 verify_clip 之后的插入点")
s = s.replace(anchor, add)

a2 = "        verify_clip(None, want_main)\n        verify_clip(SECOND_REMOTE, want_second)\n"
if s.count(a2) != 1:
    raise SystemExit("screen2ctl: 找不到 open_second 的 verify_clip")
s = s.replace(a2, a2 + "        retarget_rtc(primary)\n")

a3 = '        _state.update(open=False, last_ping=0.0)\n    log("close (%s) own=%s" % (reason, own))\n'
if s.count(a3) != 1:
    raise SystemExit("screen2ctl: 找不到 close_second 的收尾")
s = s.replace(a3, "        retarget_rtc(None)\n" + a3)

# 看门狗：布局检查连续两次不一致才收，避免刚打开那一拍误收
oldw = '''        if now != _state.get("rects"):
            try:
                close_second("layout changed")
            except Exception as e:  # noqa: BLE001
                log("watchdog close failed: %s" % e)
            continue
'''
neww = '''        if now != _state.get("rects"):
            # 刚扩/刚收那一拍 xrandr 可能还没稳定；连续两次不一致才收。
            _state["layout_bad"] = _state.get("layout_bad", 0) + 1
            if _state["layout_bad"] >= 2:
                try:
                    close_second("layout changed")
                except Exception as e:  # noqa: BLE001
                    log("watchdog close failed: %s" % e)
            continue
        _state["layout_bad"] = 0
'''
if s.count(oldw) == 1:
    s = s.replace(oldw, neww)
else:
    print("  看门狗片段没匹配，跳过（不影响功能）")

open(p, "w").write(s)
PY
    python3 -m py_compile "$f"
    systemctl restart screen2ctl 2>/dev/null || true
    log "screen2ctl 补丁完成"
}

# ---------------------------------------------------------------- 卸载

do_uninstall() {
    log "停服务"
    systemctl disable --now vnc-rtc x0vnc-main >/dev/null 2>&1 || true
    rm -f "$RTC_UNIT" "$X0_UNIT"
    systemctl daemon-reload

    log "删文件"
    rm -f "$RTC_WRAP" "$X0_WRAP" "$RTC_CFG"
    rm -rf "$RTC_DIR" "$X0_GEOM_DIR" "$NOVNC_RTC"
    # TigerVNC 二进制与 new_vnc 通道共用；那边还在用就留着
    if [ "$(cat /etc/vnc-ws/backend 2>/dev/null)" != "tigervnc" ]; then
        rm -rf "/opt/tigervnc-$TIGERVNC_VER"
    fi

    nginx_detect
    nginx_remove
    nginx_reload

    warn "screen2ctl 里的 retarget_rtc 钩子保留（/etc/vnc-rtc 不在时它自动跳过），"
    warn "如果要彻底还原，用 /var/backups/screen2ctl.pre-rtc.* 覆盖回去。"
    log "卸载完成；x11vnc / WS 通道没动过"
}

case "$MODE" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    check)     do_check ;;
esac
