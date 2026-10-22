#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Selkies 试运行（第三套入口 /selkies）
#
# 与现有 noVNC(:1 上的 x11vnc) / /live(ffmpeg+MediaMTX) 完全独立：
#   - Selkies 自己独占一个进程和一个 TCP 端口（127.0.0.1:8095）
#   - 默认 WebSocket 传输：媒体走普通 WebSocket，经 nginx 同源反代，
#     不需要任何额外的 UDP 端口转发（这是它和 /live 最大的区别）
#   - 它自己抓 Xvfb :1 的画面、自己注入键鼠（XTEST）、自己抓 PulseAudio
#   - 只有有人打开页面时才启动采集/编码；没人看时约 1% CPU
#
# 反代位置写在 vnc_desktop_setup.sh 的 write_novnc_dropin() 里（检测到
# /usr/bin/selkies 存在才会生成 /selkies 段），所以本脚本只管装和跑。
#
# 用法：
#   bash scripts/selkies_trial.sh                 # 安装 + 启动
#   SELKIES_PASS=新密码 bash scripts/selkies_trial.sh   # 换密码
#   bash scripts/selkies_trial.sh --remove        # 卸载（保留 deb 包安装）
# ---------------------------------------------------------------------------
set -euo pipefail

SELKIES_VERSION="${SELKIES_VERSION:-2.0.0}"
SELKIES_PASS="${SELKIES_PASS:-Selkies2026}"
SELKIES_USER="${SELKIES_USER:-vncuser1}"
SELKIES_PORT="${SELKIES_PORT:-8095}"
SELKIES_SUBFOLDER="${SELKIES_SUBFOLDER:-/selkies}"
SELKIES_FPS="${SELKIES_FPS:-30}"
SELKIES_BITRATE_KBPS="${SELKIES_BITRATE_KBPS:-4000}"
SELKIES_AUDIO_BITRATE="${SELKIES_AUDIO_BITRATE:-192000}"
SELKIES_AUDIO_FRAME_MS="${SELKIES_AUDIO_FRAME_MS:-10}"  # 10ms：RED 冗余后单包 ~730B，避开 SRTP 1356B 上限
SELKIES_FILE_TRANSFERS="${SELKIES_FILE_TRANSFERS:-upload,download}"  # 文件传输方向；none/"" 关闭
SELKIES_FILE_DIR="${SELKIES_FILE_DIR:-/home/vncuser1/Desktop}"    # 上传落地 + 下载浏览的根目录
SELKIES_AUDIO_DEVICE="${SELKIES_AUDIO_DEVICE:-virtual_speaker.monitor}"
SELKIES_WIDTH="${SELKIES_WIDTH:-1920}"
SELKIES_HEIGHT="${SELKIES_HEIGHT:-1080}"
SELKIES_SHARING="${SELKIES_SHARING:-true}"  # true=多客户端并存；false=后连的接管（会踢掉前一个）
SELKIES_SECOND_SCREEN="${SELKIES_SECOND_SCREEN:-false}"  # true=允许客户端「Add Screen +」加第二块屏（会拉宽共享的 Xvfb root）
SELKIES_MODE="${SELKIES_MODE:-websockets}"   # websockets（默认，单 TCP 口）| webrtc（需宿主机转发 UDP）
SELKIES_UDP_PORT="${SELKIES_UDP_PORT:-59000}"       # webrtc 时的唯一媒体端口（UDP mux，一端口服务所有会话）
SELKIES_TCP_MUX_PORT="${SELKIES_TCP_MUX_PORT:-59001}"  # 可选：UDP 被墙时的 ICE-TCP 回退
SELKIES_PUBLIC_IP="${SELKIES_PUBLIC_IP:-45.12.52.180}" # 写进 host candidate 的公网 IP（= mediamtx 用的那个）
SELKIES_UNIT=/etc/systemd/system/selkies.service
XVFB_SS_DROPIN=/etc/systemd/system/xvfb@.service.d/50-second-screen.conf
GUARD_BIN=/usr/local/bin/openbox-guard
GUARD_UNIT=/etc/systemd/system/openbox-guard@.service
MODE_HOLD_UNIT=/etc/systemd/system/xvfb-mode@.service
MODE_HOLD_BIN=/usr/local/bin/xvfb-mode-hold
SHIFT_BIN=/usr/local/bin/desktop-layout-shift
SHIFT_UNIT=/etc/systemd/system/desktop-layout-shift@.service

say() { printf '  %s\n' "$*"; }

second_screen_on() {
    # Xvfb 运行期不能超过启动尺寸；RandR 模式又归创建它的客户端所有，
    # 客户端一退出模式就销毁（CRTC 退回 4K、root 却还是 1080p）。
    # 所以：4K 分配 + 常驻进程把可见桌面钉回配置尺寸，Type=notify 保证
    # LXDE 不会在 4K 那一刻启动。
    install -m 0755 /dev/stdin "${MODE_HOLD_BIN}" <<'HOLDER'
#!/usr/bin/env python3
"""把 Xvfb 的可见桌面钉在固定分辨率上，直到进程退出（RandR 模式锚点）。

Xvfb 的 framebuffer 在启动时分配、运行期不能变大；而 RandR 模式属于创建
它的 X 客户端，客户端一断开模式就被销毁、CRTC 退回启动模式，root 却还是
缩小后的尺寸 —— 两者不一致，GTK/openbox 会以为屏幕仍是 4K。常驻一条连接
才能让桌面尺寸保持诚实。systemd 里配 Type=notify，尺寸设好后才 READY。
"""
import os
import socket
import sys
import time

SELKIES_SITE = "/opt/selkies/lib/python3.11/site-packages"


def notify_ready(payload: str = "READY=1") -> None:
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        sock.connect(addr)
        sock.sendall(payload.encode())
    except OSError:
        pass
    finally:
        sock.close()


def main() -> int:
    target = sys.argv[1] if len(sys.argv) > 1 else "1920x1080"
    try:
        want_w, want_h = (int(part) for part in target.lower().split("x"))
    except ValueError:
        print(f"xvfb-mode-hold: 无效分辨率 '{target}'", file=sys.stderr)
        return 2

    sys.path.insert(0, SELKIES_SITE)
    from selkies.display_utils import _module_display, _sync_resize_randr

    got_w, got_h = _sync_resize_randr(target)
    print(f"xvfb-mode-hold: 已固定 {got_w}x{got_h}（请求 {want_w}x{want_h}）", flush=True)

    display = _module_display()
    notify_ready()
    while True:
        time.sleep(10)
        # Xvfb 重启/退出时抛异常，systemd 会重启我们并在新 X 上重新固定。
        display.sync()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
HOLDER

    cat > "${MODE_HOLD_UNIT}" <<'UNIT'
[Unit]
Description=Pin Xvfb :%i to the configured desktop resolution (RandR mode holder)
After=xvfb@%i.service
Before=vnc-desktop@%i.service x11vnc@%i.service
BindsTo=xvfb@%i.service

[Service]
Type=notify
NotifyAccess=main
Environment=DISPLAY=:%i
EnvironmentFile=-/home/vncuser1/.vnc/display-%i.conf
Environment=WIDTH=1920
Environment=HEIGHT=1080
ExecStart=/usr/local/bin/xvfb-mode-hold ${WIDTH}x${HEIGHT}
Restart=always
RestartSec=3
TimeoutStartSec=20
OOMScoreAdjust=-800

[Install]
WantedBy=multi-user.target
UNIT

    mkdir -p "$(dirname "${XVFB_SS_DROPIN}")"
    cat > "${XVFB_SS_DROPIN}" <<'DROPIN'
# 第二块屏（Selkies 的「Add Screen +」）需要比可见桌面更大的 framebuffer。
# Xvfb 的 framebuffer 在启动时定死、运行期不能再长，所以直接按 4K 分配；
# 可见桌面由 xvfb-mode@%i.service 缩回 display-%i.conf 里的 WIDTH x HEIGHT。
# 关闭第二块屏时删除本文件并 systemctl daemon-reload。
[Service]
ExecStart=
ExecStart=/usr/bin/Xvfb :%i -screen 0 3840x2160x${DEPTH} $EXTRA_XVFB_ARGS
DROPIN

    # Selkies 加第二块屏前会重启一次 openbox（让它重新读显示器集合）。
    # Xvfb 的 RandR 刚被改过时，新 openbox 可能直接退出，桌面就没有
    # 标题栏/关闭按钮了。这个守护进程每 5 秒补一次。
    install -m 0755 /dev/stdin "${GUARD_BIN}" <<'GUARD'
#!/bin/sh
# LXDE 会话还在、openbox 却不在时把它拉起来（Selkies 的多显示器 WM 重启兜底）。
set -u
CONFIG="${HOME:-/home/vncuser1}/.config/openbox/lxde-rc.xml"
while :; do
    if pgrep -x lxsession >/dev/null 2>&1 && ! pgrep -x openbox >/dev/null 2>&1; then
        /usr/bin/openbox --config-file "$CONFIG" --replace >/dev/null 2>&1 &
    fi
    sleep 5
done
GUARD

    cat > "${GUARD_UNIT}" <<'UNIT'
[Unit]
Description=Openbox guard (restore the LXDE window manager if it disappears)
After=vnc-desktop@%i.service
# Selkies 的“多显示器 WM 重启”在 Xvfb 上偶尔会让 openbox 退出；
# 没有 WM 时窗口没有标题栏、没有关闭按钮。
# 不绑定 vnc-desktop 的生命周期：桌面服务重启后也要继续守着。

[Service]
User=vncuser1
Environment=DISPLAY=:%i
Environment=XDG_CONFIG_HOME=/home/vncuser1/.config
ExecStart=/usr/local/bin/openbox-guard
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    # Selkies 的 left/up 只挪「主屏采集区」，Xvfb 不会搬窗口 —— noVNC 里就会
    # 永远看到「桌面在左、新空间在右」。这个守护进程盯着 selkies-primary 的
    # 偏移，把旧主屏那一块的窗口整体搬过去，左/上 才在 noVNC 里真的成立。
    install -m 0755 /dev/stdin "${SHIFT_BIN}" <<'SHIFT'
#!/bin/bash
# desktop-layout-shift —— 让「主屏」始终落在 Selkies 的 selkies-primary 区域
#
# Selkies 的 left/up（以及 noVNC 第二块屏的控制器）只是把「主屏」挪到
# x=1920 / y=1080；Xvfb 不会移动任何窗口。这个守护进程盯着
# `xrandr --listmonitors` 里 selkies-primary 的偏移，偏移一变就把
# 旧主屏那一块里的窗口（桌面图标等，面板不搬）整体搬到新的主屏位置。
#
# 只搬「旧主屏里」的窗口：拖到第二块屏里的窗口原地不动，切回去时正好
# 落在新的主屏区域里，不会被搬到屏幕外。第二块屏关掉时主屏回到 0,0，
# 内容也会自动搬回来（否则会留在已经缩小的 root 外面）。
#
# 用法：
#   desktop-layout-shift            常驻（systemd）
#   desktop-layout-shift --once     立即按当前监视器应用一次（控制器同步调用）
set -u

DISPLAY="${DISPLAY:-:1}"
export DISPLAY
PRIMARY_NAME="${PRIMARY_NAME:-selkies-primary}"
STATE_FILE="${STATE_FILE:-/run/desktop-layout-shift.state}"
LOCK_FILE="${LOCK_FILE:-/run/desktop-layout-shift.lock}"
INTERVAL="${INTERVAL:-0.5}"

log() { echo "desktop-layout-shift: $*"; }

# 输出: 宽 高 x y（找不到 selkies-primary 时输出 "0 0 0 0"）
read_primary() {
    local line geom
    line=$(xrandr --listmonitors 2>/dev/null | grep -m1 -- "$PRIMARY_NAME") || true
    if [ -z "$line" ]; then
        echo "0 0 0 0"
        return
    fi
    geom=$(sed -n 's|.*[[:space:]]\([0-9][0-9]*\)/[0-9][0-9]*x\([0-9][0-9]*\)/[0-9][0-9]*+\(-\{0,1\}[0-9][0-9]*\)+\(-\{0,1\}[0-9][0-9]*\).*|\1 \2 \3 \4|p' <<<"$line")
    echo "${geom:-0 0 0 0}"
}

read_screen() { # w h（没有 selkies-primary 时用整个屏幕）
    local line w h
    line=$(xrandr 2>/dev/null | grep -m1 "current")
    w=$(sed -n 's/.*current \([0-9][0-9]*\) x \([0-9][0-9]*\).*/\1/p' <<<"$line")
    h=$(sed -n 's/.*current \([0-9][0-9]*\) x \([0-9][0-9]*\).*/\2/p' <<<"$line")
    echo "${w:-1920} ${h:-1080}"
}

is_panel() { # id
    # 只认真正的面板窗口：DOCK 类型 + 宽度 >= 1000。
    # 不能只看 WM_CLASS —— lxpanel 的 tooltip（131x21）和 popup menu 也是
    # class "lxpanel"，以前会被当成面板搬到主屏底部，鼠标一碰面板就闪一下。
    local id=$1 geom W
    geom=$(xdotool getwindowgeometry --shell "$id" 2>/dev/null) || return 1
    W=$(sed -n 's/^WIDTH=//p' <<<"$geom")
    [ -n "$W" ] && [ "$W" -ge 1000 ] || return 1
    xprop -id "$id" _NET_WM_WINDOW_TYPE 2>/dev/null | grep -q "_NET_WM_WINDOW_TYPE_DOCK"
}


move_windows() { # old_x old_y old_w old_h dx dy
    local ox=$1 oy=$2 ow=$3 oh=$4 dx=$5 dy=$6
    local id geom X Y WIDTH HEIGHT cx cy moved=0
    if [ "$ow" -le 0 ] || [ "$oh" -le 0 ]; then
        return 0
    fi
    local cls
    for id in $(xdotool search --onlyvisible --name "." 2>/dev/null); do
        # lxpanel 是横跨整个 root 的一条（widthtype=percent 100），位置和 strut 由它自己管；
        # 不能被这里按「中心点」搬走（否则从 right 切 down 会跑到 -1920）。
        is_panel "$id" && continue
        geom=$(xdotool getwindowgeometry --shell "$id" 2>/dev/null) || continue
        X=$(sed -n 's/^X=//p' <<<"$geom")
        Y=$(sed -n 's/^Y=//p' <<<"$geom")
        WIDTH=$(sed -n 's/^WIDTH=//p' <<<"$geom")
        HEIGHT=$(sed -n 's/^HEIGHT=//p' <<<"$geom")
        [ -n "$X" ] && [ -n "$Y" ] && [ -n "$WIDTH" ] && [ -n "$HEIGHT" ] || continue
        cx=$((X + WIDTH / 2))
        cy=$((Y + HEIGHT / 2))
        if [ "$cx" -ge "$ox" ] && [ "$cx" -lt $((ox + ow)) ] && \
           [ "$cy" -ge "$oy" ] && [ "$cy" -lt $((oy + oh)) ]; then
            if xdotool windowmove "$id" $((X + dx)) $((Y + dy)) 2>/dev/null; then
                moved=$((moved + 1))
            fi
        fi
    done
    log "moved $moved window(s) by ($dx,$dy) away from primary ($ox,$oy ${ow}x${oh})"
}

apply_locked() {
    local ow oh ox oy sx sy sw sh
    exec 9>"$LOCK_FILE" || return 0
    flock 9 || return 0

    sx=0; sy=0; sw=1920; sh=1080
    if [ -r "$STATE_FILE" ]; then
        read -r sx sy sw sh < "$STATE_FILE" 2>/dev/null || true
    fi

    read -r ow oh ox oy <<<"$(read_primary)"
    read -r rw rh <<<"$(read_screen)"

    # 布局切换的中间态：set_mode 已经把 root 拉大、set_monitors 还没跑（open 时
    # 中间还要等 x11vnc-screen2 起来，约 2 秒），这期间 selkies-primary 是缺席的。
    # 以前这里退回「整个 root」-> 面板钉到 (0,2134)、所有窗口 -1920，等监视器
    # 回来再搬一遍，一次开关屏闪两下。现在改成「粘住上一次的主屏」：
    #   - 没监视器，或监视器装不进当前 root（root 刚缩回去）时，沿用 STATE_FILE；
    #   - 只有上一次的主屏也装不下（真的是回到单屏了），才退回左上角 1920x1080；
    #   - 缺席持续超过 10 秒也当作「真的没有第二块屏」，避免卡在旧位置。
    local npf=/run/desktop-layout-shift.noprimary np_now np_since np_stale
    np_stale=0
    if [ "$ow" -le 0 ] || [ "$oh" -le 0 ] || \
       [ $((ox + ow)) -gt "$rw" ] || [ $((oy + oh)) -gt "$rh" ]; then
        np_now=$(date +%s)
        np_since=$np_now
        if [ -s "$npf" ]; then
            np_since=$(cat "$npf" 2>/dev/null || echo "$np_now")
            case "$np_since" in ''|*[!0-9]*) np_since=$np_now ;; esac
        else
            echo "$np_now" > "$npf" 2>/dev/null || true
        fi
        [ $((np_now - np_since)) -ge 10 ] && np_stale=1
        if [ "$np_stale" -eq 0 ] && [ "$sw" -gt 0 ] && [ "$sh" -gt 0 ] && \
           [ $((sx + sw)) -le "$rw" ] && [ $((sy + sh)) -le "$rh" ]; then
            ox=$sx; oy=$sy; ow=$sw; oh=$sh
        else
            ow=$rw; [ "$ow" -gt 1920 ] && ow=1920
            oh=$rh; [ "$oh" -gt 1080 ] && oh=1080
            ox=0; oy=0
        fi
    else
        rm -f "$npf" 2>/dev/null || true
    fi

    if [ "$ox" != "$sx" ] || [ "$oy" != "$sy" ]; then
        move_windows "$sx" "$sy" "$sw" "$sh" $((ox - sx)) $((oy - sy))
        sx=$ox; sy=$oy
        [ "$ow" -gt 0 ] && sw=$ow
        [ "$oh" -gt 0 ] && sh=$oh
        printf '%s %s %s %s\n' "$sx" "$sy" "$sw" "$sh" > "$STATE_FILE" 2>/dev/null || true
        log "primary now ($sx,$sy ${sw}x${sh})"
    elif [ "$ow" -gt 0 ] && { [ "$ow" != "$sw" ] || [ "$oh" != "$sh" ]; }; then
        sw=$ow; sh=$oh
        printf '%s %s %s %s\n' "$sx" "$sy" "$sw" "$sh" > "$STATE_FILE" 2>/dev/null || true
    fi

    flock -u 9
}

if [ "${1:-}" = "--once" ]; then
    apply_locked
    exit 0
fi

log "start (interval ${INTERVAL}s)"
# 方向切换时控制器会先删 monitor 再建新的，中间有一瞬间「没有 selkies-primary」。
# 守护进程不要立刻把内容搬回 0,0，否则会和控制器打架（搬两次）。
missing=0
while :; do
    read -r _ow _oh _ox _oy <<<"$(read_primary)"
    if [ "$_ox" = "0" ] && [ "$_oy" = "0" ]; then
        missing=$((missing + 1))
        if [ "$missing" -lt 2 ]; then
            sleep "$INTERVAL"
            continue
        fi
    else
        missing=0
    fi
    apply_locked
    sleep "$INTERVAL"
done

SHIFT

    cat > "${SHIFT_UNIT}" <<'UNIT'
[Unit]
Description=Move desktop content onto the Selkies primary region (makes 左/上 real)
Documentation=file:///root/vps-setup/scripts/selkies_trial.sh
After=xvfb@%i.service vnc-desktop@%i.service
BindsTo=xvfb@%i.service

[Service]
Type=simple
Environment=DISPLAY=:%i
ExecStart=/usr/local/bin/desktop-layout-shift
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable xvfb-mode@1.service >/dev/null 2>&1 || true
    systemctl enable --now openbox-guard@1.service >/dev/null 2>&1 || true
    systemctl enable --now desktop-layout-shift@1.service >/dev/null 2>&1 || true
    say "第二块屏：已安装 xvfb-mode@1 + 4K framebuffer drop-in + openbox 守护 + 布局搬移"
    say "  ⚠️ 需要重启 xvfb@1 才会生效（会关掉桌面上所有窗口）"
    say "     之后在 Selkies 侧栏 Screen 区点「Add Screen +」"
}

second_screen_off() {
    systemctl disable --now xvfb-mode@1.service >/dev/null 2>&1 || true
    systemctl disable --now openbox-guard@1.service >/dev/null 2>&1 || true
    systemctl disable --now desktop-layout-shift@1.service >/dev/null 2>&1 || true
    rm -f "${MODE_HOLD_UNIT}" "${MODE_HOLD_BIN}" "${XVFB_SS_DROPIN}" \
          "${GUARD_UNIT}" "${GUARD_BIN}" "${SHIFT_BIN}" "${SHIFT_UNIT}"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--remove" ]; then
    systemctl disable --now selkies.service 2>/dev/null || true
    rm -f "${SELKIES_UNIT}"
    second_screen_off
    systemctl daemon-reload
    say "已停止并删除 selkies.service"
    say "deb 包仍在（卸载：apt-get remove -y selkies）；/selkies 反代段会在下次重跑"
    say "vnc_desktop_setup.sh 时自动消失（它只在 /usr/bin/selkies 存在时生成）。"
    exit 0
fi

# ---- 1) 安装 deb（只在缺失/版本不符时）----
have="$(dpkg-query -W -f='${Version}' selkies 2>/dev/null || true)"
if [ -z "${have}" ]; then
    . /etc/os-release
    distro="$([ "${ID}" = ubuntu ] && echo "ubuntu${VERSION_ID}" || echo "${VERSION_CODENAME}")"
    pkg="selkies-${SELKIES_VERSION}-${distro}-$(dpkg --print-architecture).deb"
    tmp="$(mktemp -d)"
    say "下载 ${pkg} …"
    curl -fL -o "${tmp}/${pkg}" \
        "https://github.com/selkies-project/selkies/releases/download/${SELKIES_VERSION}/${pkg}"
    apt-get install -y "${tmp}/${pkg}" >/dev/null
    rm -rf "${tmp}"
    say "已安装 $(dpkg-query -W -f='${Version}' selkies)（/opt/selkies，约 291 MB）"
else
    say "已安装 selkies ${have}"
fi

# ---- 2) systemd 单元 ----
# 注意几个刻意的选择：
#   --enable-resize=false：分辨率锁死 Xvfb 原生 1920x1080，绝不因为客户端
#       窗口大小去改 Xvfb（否则 noVNC 那边会被一起改掉）。不再加
#       manual-resolution：那会让客户端每次连接都刷一条 WARNING（它想关掉它）。
#   --use-cpu=true        ：没有 GPU，强制软件 x264
#   --video-bitrate=4000  ：CBR 4 Mbps，与 /live 的码率一致，便于对比
#   --mode 默认 websockets：单 TCP 口，不需要 UDP 转发
#   --enable-sharing 打开：多客户端并存；printing 关掉：试运行先缩小暴露面
manual_args=""
if [ "${SELKIES_SECOND_SCREEN}" = "true" ]; then
    # 第二块屏的尺寸来自浏览器弹窗（HiDPI 下是 2 倍物理像素，实测 2528x2720），
    # 不锁的话布局总尺寸会超过 4K framebuffer；锁死后每块屏都是主屏尺寸，
    # 两块并排正好 3840x1080。
    manual_args="--manual-width=${SELKIES_WIDTH} --manual-height=${SELKIES_HEIGHT}"
fi

if [ "${SELKIES_SECOND_SCREEN}" = "true" ]; then
    # Selkies 退出/崩溃时把 framebuffer 收回主屏尺寸，避免留下一条 3200x1080 的 root
    stop_reset="ExecStopPost=-/bin/sh -c 'DISPLAY=:1 xrandr --fb ${SELKIES_WIDTH}x${SELKIES_HEIGHT} 2>/dev/null || true'"
else
    stop_reset=""
fi

if [ "${SELKIES_MODE}" = "webrtc" ]; then
    webrtc_args=" \\
    --mode=webrtc --webrtc-udp-mux-port=${SELKIES_UDP_PORT} \\
    --webrtc-tcp-mux-port=${SELKIES_TCP_MUX_PORT} \\
    --webrtc-public-ip=${SELKIES_PUBLIC_IP} --webrtc-ice-lite=true"
else
    webrtc_args=""
fi

cat > "${SELKIES_UNIT}" <<EOF
[Unit]
Description=Selkies streaming server (Xvfb :1, websocket transport)
Documentation=https://docs.selkies.io/
After=network.target xvfb@1.service xvfb-mode@1.service pulseaudio-vnc.service
Wants=xvfb@1.service pulseaudio-vnc.service

[Service]
Type=simple
User=${SELKIES_USER}
Group=${SELKIES_USER}
RuntimeDirectory=selkies
StateDirectory=selkies
CacheDirectory=selkies
Environment=DISPLAY=:1
Environment=XDG_RUNTIME_DIR=/run/selkies
Environment=XDG_STATE_HOME=/var/lib/selkies
Environment=XDG_CACHE_HOME=/var/cache/selkies
Environment=PULSE_SERVER=unix:/run/pulse-vnc/pulse/native
ExecStart=/usr/bin/selkies \\
    --port=${SELKIES_PORT} --addr=127.0.0.1 --subfolder=${SELKIES_SUBFOLDER} \\
    --enable-https=false \\
    --basic-auth-user=${SELKIES_USER} --basic-auth-password=${SELKIES_PASS} \\
    --encoder=h264enc --use-cpu=true \\
    --enable-resize=false ${manual_args} \\
    --framerate=${SELKIES_FPS} --video-bitrate=${SELKIES_BITRATE_KBPS} --keyframe-interval=2 \\
    --rate-control-mode=cbr \\
    --audio-device-name=${SELKIES_AUDIO_DEVICE} \\
    --audio-bitrate=${SELKIES_AUDIO_BITRATE} --audio-frame-duration-ms=${SELKIES_AUDIO_FRAME_MS} \\
    --enable-sharing=${SELKIES_SHARING} --enable-shared=${SELKIES_SHARING} \\
    --enable-player2=false --enable-player3=false --enable-player4=false \\
    --file-transfers=${SELKIES_FILE_TRANSFERS} --file-manager-path=${SELKIES_FILE_DIR} \\
    --printing-enabled=false \\
    --second-screen=${SELKIES_SECOND_SCREEN} --gamepad-enabled=false \\
    --microphone-enabled=false --webcam-enabled=false${webrtc_args}
${stop_reset}
Restart=on-failure
RestartSec=3
OOMPolicy=continue

[Install]
WantedBy=multi-user.target
EOF

if [ "${SELKIES_SECOND_SCREEN}" = "true" ]; then
    second_screen_on
else
    second_screen_off
fi

systemctl daemon-reload
systemctl enable --now selkies.service >/dev/null 2>&1
systemctl restart selkies.service
sleep 3

# ---- 3) 自检 ----
say "服务: $(systemctl is-active selkies)"
code="$(curl -s -o /dev/null -w '%{http_code}' -u "${SELKIES_USER}:${SELKIES_PASS}" \
        "http://127.0.0.1:${SELKIES_PORT}${SELKIES_SUBFOLDER}/" || true)"
say "本地直连 ${SELKIES_SUBFOLDER}/ → ${code}（200 正常；401 表示密码不符）"
say "入口： https://<你的域名>${SELKIES_SUBFOLDER}/   用户 ${SELKIES_USER} / 密码 ${SELKIES_PASS}"
say "注意：nginx 的 ${SELKIES_SUBFOLDER} 段由 vnc_desktop_setup.sh 生成，"
say "      改动 systemd 单元后 nginx 无需重启。"
