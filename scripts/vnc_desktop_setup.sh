#!/bin/bash

# =======================================================
# 🚀 Debian 12 VNC - Systemd 级联服务架构版 (Pipeline Edition)
# 核心架构：
#   - xvfb@.service        (虚拟帧缓冲显存服务)
#   - vnc-desktop@.service (LXDE 桌面会话，BindsTo=xvfb)
#   - x11vnc@.service      (VNC 网络服务，BindsTo=xvfb)
#   - vnc-wsproxy.service  (单进程 WebSocket 网关：6081/6082/6083 → 5901/5902/5903)
#   - vnc-stack@.target    (级联总调度单元)
#   - mt5-watchdog@.service (MT5 交易软件 7*24 智能自愈守护)
# 优势：
#   1. 完全抛弃长脚本后台跑任务，各组件由 Systemd 独立追踪真实 PID
#   2. BindsTo 强绑定：任何核心组件崩溃，整个链路安全平滑重启，杜绝黑屏假死
#   3. 独立服务日志：可通过 journalctl 精确追溯具体是桌面、显卡还是网络问题
# =======================================================

VNC_USER="vncuser1"
SWAP_SIZE="2G"
SWAP_FILE="/swapfile"

# 虚拟桌面（工作区）数：openbox 开箱默认 2 个。远程桌面里多出来的工作区没有实际用途，
# 只会制造「窗口切到另一个桌面后不见了」这种玄学问题，默认收敛成 1 个。
#   LXDE_DESKTOPS=1  只保留一个桌面（默认）
#   LXDE_DESKTOPS=2  保留 openbox 默认的两个
#   LXDE_DESKTOPS=0  完全不碰，保留现场配置
# 有终端时会询问（直接回车＝当前值，新装为 1）；非交互重跑时沿用现场值，不悄悄改。
LXDE_DESKTOPS="${LXDE_DESKTOPS:-}"

# new_vnc（WebSocket 通道 5901/5902）用哪个 VNC 服务端：
#   WS_BACKEND=x11vnc    默认。双屏开/关稳定，运行时 `-R clip:` 裁剪无缝；没有 CU。
#   WS_BACKEND=tigervnc  更高效（ContinuousUpdates + 剪贴板），但目前开关第二块屏会花屏，不推荐。
# 有终端时会询问；非交互默认 x11vnc。选择写进 /etc/vnc-ws/backend，
# screen2ctl 按它决定用 clip 还是改几何重启。
WS_BACKEND="${WS_BACKEND:-}"
# WebSocket 网关类型：single=单进程 Go 代理（安装时探测 vnc-wsproxy/）；legacy=websockify@.service
WS_BRIDGE_KIND="legacy"

# 运行时探测实际装的是哪种网关（菜单/状态用）
bridge_service_name() {
    if [ "${WS_BRIDGE_KIND}" = "single" ] || [ -f /etc/systemd/system/vnc-wsproxy.service ]; then
        echo "vnc-wsproxy"
    else
        echo "websockify@1"
    fi
}

# 账号密码记录文件（root 私有，600）：
#   只在这里记录「明文」的桌面用户密码与 VNC 连接密码，供菜单 [11] 查看。
#   注意：绝不要放进仓库（仓库是公开的）。
CRED_FILE="/root/.vnc-desktop-credentials"

update_variables() {
    USER_HOME="/home/${VNC_USER}"
    NOVNC_WEB_ROOT="/usr/share/novnc"

    # 第二套 noVNC（官方最新正式版）：
    #   Debian 12 自带的 novnc 是 1.3.0，core/decoders/ 里没有 ZRLE（也不发 encoding 16），
    #   而 ZRLE 是协议层面保证无损的编码，x11vnc(libvncserver) 原生支持。
    #   部署脚本：scripts/novnc_new_deploy.sh → ${NOVNC_NEW_WEB_ROOT}
    #   对外地址：/new_vnc 虚拟目录（与上面的 / 站点互不影响，可分别卸载）
    NOVNC_NEW_WEB_ROOT="${NOVNC_NEW_WEB_ROOT:-/usr/share/novnc-new}"
    NOVNC_NEW_VERSION="${NOVNC_NEW_VERSION:-v1.7.0}"
    VNC_PASSWD_FILE="${USER_HOME}/.vnc/passwd"
    VNC_CONF_DIR="${USER_HOME}/.vnc"
    DESKTOP_DIR="${USER_HOME}/Desktop"

    SSL_CERT_DIR="/etc/ssl/localcerts"
    SSL_KEY="${SSL_CERT_DIR}/selfsigned.key"
    SSL_CRT="${SSL_CERT_DIR}/selfsigned.crt"

    # OpenResty 增量配置（默认值；运行时由 detect_openresty_paths 按 nginx -V 修正）
    OR_PREFIX="/usr/local/openresty/nginx"
    OR_NGINX_BIN="${OR_PREFIX}/sbin/nginx"
    OR_CONF_DIR="${OR_PREFIX}/conf"
    OR_MAIN_CONF="${OR_CONF_DIR}/nginx.conf"
    OR_DROPIN_DIR="${OR_CONF_DIR}/conf.d"
    OR_DROPIN="${OR_DROPIN_DIR}/50-novnc.conf"
    OR_MAIN_BAK="${OR_MAIN_CONF}.vps-setup.bak"
    VNC_CONFIG_MARK="# Managed by vps-setup (vnc_desktop_setup.sh)"

    # lxpanel / pcmanfm / openbox（连带 lxde-common / lxsession / openbox-lxde-session）
    # 都是 lxde-core 的硬依赖，会随它一起装上，不必重复列出；
    # lxterminal 是「切换分辨率」工具双击时用的终端，lxappearance/lxde-icon-theme 是外观件。
    # dmz-cursor-theme：提供 DMZ-White / DMZ-Black 鼠标指针主题。
    #   lxsession 生成的会话配置里 sGtk/CursorThemeName 默认就是 DMZ-White，
    #   少这个包时 GTK 程序找不到主题，指针会退回 X 内置的旧样式（看起来「不对」）。
    PKG_LXDE="lxde-core lxterminal lxappearance lxde-icon-theme dmz-cursor-theme"

    # 桌面真实声音：pulseaudio 造虚拟声卡，ffmpeg 编码 Opus 推给 MediaMTX。
    PKG_AUDIO="pulseaudio pulseaudio-utils ffmpeg"
    # 图形化音量控制（远程桌面里用）+ SVG 图标加载器（没有它 pavucontrol 会报 pixbuf 警告、
    # 部分图标不显示）。
    PKG_AUDIO_GUI="pavucontrol librsvg2-common"

    # ---- 桌面真实声音：PulseAudio 虚拟声卡 -> Opus -> WebRTC ----
    # 默认直发（vnc-audio-rtc，AUDIO_BACKEND=go）：
    #       桌面应用 -> virtual_speaker -> gopus（进程内） -> pion WebRTC(UDP 8193) -> vnc.html
    # ffmpeg 回退（AUDIO_BACKEND=ffmpeg）：
    #       桌面应用 -> virtual_speaker -> ffmpeg -> RTP(UDP 127.0.0.1:8195)
    #       -> pion WebRTC(UDP 8193) -> vnc.html
    # 没有 vnc-audio-rtc payload 时：-> RTSP -> MediaMTX -> WHEP(UDP 8189)
    # 端口：AUDIO_UDP_PORT(8189) 给 MediaMTX/实时画面；AUDIO_RTC_ICE_PORT(8193) 给音频直发。
    #       两者都要宿主机 DNAT；RTC 视频桥只占 8190-8192。
    AUDIO_SINK="virtual_speaker"
    AUDIO_PATH="desktop"
    AUDIO_RTSP_PORT="8554"       # RTSP 推流口（只本机 ffmpeg 用）
    AUDIO_WHEP_PORT="8889"       # WHEP 信令口（由 nginx 同源反代，浏览器只见到 443）
    AUDIO_API_PORT="9997"        # MediaMTX 诊断 API
    AUDIO_UDP_PORT="8189"        # WebRTC 媒体口（唯一需要转发到容器的 UDP 端口）
    AUDIO_PULSE_RUNTIME="/run/pulse-vnc"
    AUDIO_PATCH_DIR="/root/novnc-audio"   # vnc.html 补丁的备份 + 重应用脚本
    AUDIO_PUBLIC_HOST="${AUDIO_PUBLIC_HOST:-}"  # 对外播报的公网 IP/域名；留空=自动探测
    MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-}"    # 留空=自动取最新；也可固定如 v1.21.2

    # ---- 桌面音频直发（vnc-audio-rtc）：PulseAudio → Opus → pion WebRTC ----
    # 和 Selkies 的结构一致：不再经过 RTSP/TCP 和 MediaMTX 二次转发。
    # 只有仓库里带了 vnc-audio-rtc/vnc-audio-rtc 才启用；否则 /whep 仍走 MediaMTX。
    AUDIO_RTC_PORT="6092"          # WHEP 信令（nginx 同源反代）
    AUDIO_RTC_ICE_PORT="8193"      # 复用宿主已转发的 UDP 段；视频桥限在 8190-8192
    AUDIO_RTC_UNIT=""
    _audio_rtc_payload="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/vnc-audio-rtc/vnc-audio-rtc"
    if [ -x "${_audio_rtc_payload}" ]; then
        AUDIO_RTC_UNIT="vnc-audio-rtc.service"
        AUDIO_WHEP_PROXY="127.0.0.1:${AUDIO_RTC_PORT}/whep"
    else
        AUDIO_WHEP_PROXY="127.0.0.1:${AUDIO_WHEP_PORT}/${AUDIO_PATH}/whep"
    fi

    # ---- 桌面视频（独立通道，/live 页面）：与 noVNC/x11vnc 完全无关，不接管键鼠 ----
    # 链路：Xvfb(:1) --x11grab--> ffmpeg(H.264+Opus) --RTSP--> MediaMTX --WHEP--> /live 页面
    # 只在有人观看时由 MediaMTX 的 runOnDemand 拉起，离开 10 秒后自动退出。
    VIDEO_PATH="desktop_av"                     # MediaMTX 里的路径名
    VIDEO_BIN="/usr/local/bin/desktop-video-bridge"
    VIDEO_ENV_FILE="/etc/default/desktop-video" # 分辨率/帧率/码率（改完下次观看生效）
    VIDEO_WEB_ROOT="/usr/share/desktop-live"    # /live 页面的静态文件目录
    VIDEO_CAPTURE="${VIDEO_CAPTURE:-1920x1080}" # 抓屏分辨率（= Xvfb 实际分辨率）
    VIDEO_SIZE="${VIDEO_SIZE:-1920x1080}"       # 输出分辨率（= 桌面原生，1:1；1 vCPU 上约 47% 单核）
                                                # 想省 CPU 改成 1280x720（约 21~24%），代价是 125% 缩放的客户端会再放大 1.5 倍
    VIDEO_FPS="${VIDEO_FPS:-30}"
    VIDEO_BITRATE="${VIDEO_BITRATE:-4M}"
    VIDEO_AUDIO_BITRATE="${VIDEO_AUDIO_BITRATE:-192k}"

    # ---- Selkies 试运行（/selkies）：与 noVNC/x11vnc 完全独立的第三套入口 ----
    # 传输默认 WebSocket（单 TCP 口，由 nginx 同源反代），不需要额外 UDP 转发；
    # WebRTC 传输是可选项（--mode=webrtc），那种情况才要再开 UDP。
    SELKIES_BIN="/usr/bin/selkies"
    SELKIES_HTTP_PORT="8095"          # 只监听 127.0.0.1
    SELKIES_SUBFOLDER="/selkies"      # 反代路径前缀（= selkies --subfolder）

    # Opus 码率（送进浏览器的音频码率）。默认 192k。
    #   指定优先级：--audio-bitrate=256k / AUDIO_BITRATE=256k > 交互询问（回车=默认）
    #               > 非交互时沿用已装值 > 默认 192k
    #   合法范围 6k~510k（Opus 立体声上限）。实测：膝点在 192~256k（再往上 ≤0.1 dB），
    #   而带宽是 192k≈200 / 256k≈272 / 320k≈357 kbit/s（单听众，VBR）。
    AUDIO_BITRATE_DEFAULT="192k"
    AUDIO_BITRATE="${AUDIO_BITRATE:-}"
    AUDIO_BITRATE_MIN="6"
    AUDIO_BITRATE_MAX="510"

    # 音频后端：go（默认，进程内 PulseAudio+gopus）/ ffmpeg（外部 ffmpeg → 本机 RTP）。
    # 已装过且没指定时沿用 /etc/default/vnc-audio-rtc 里的值，不会被默默改掉。
    AUDIO_BACKEND="${AUDIO_BACKEND:-}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then echo "❌ 请使用 root 权限运行"; exit 1; fi
}

# -------------------------------------------------------
# 通用小工具
# -------------------------------------------------------

# 索引被 housekeeping_disk 清掉时，装「没装过的包」会报 no installation candidate
# （装已装的包不受影响）—— 所以真正要装东西前先确认索引还在
# 注意：/var/lib/apt/lists 下的 partial/、auxfiles/、lock 会一直存在，不能只看目录是否为空
ensure_apt_lists() {
    [ -n "$(find /var/lib/apt/lists -maxdepth 1 -name '*_Packages*' 2>/dev/null | head -1)" ] && return 0
    echo "ℹ️ apt 索引已被清理，先补一次 apt update ..."
    apt update
}

# 只补装「确实缺失」的包：避免重复 apt install，更避免在 1 核机上白等一次 apt update
ensure_pkgs() {
    local need="" p
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || need="${need} ${p}"
    done
    [ -n "${need}" ] || return 0
    echo "ℹ️ 补装缺失依赖:${need}"
    ensure_apt_lists
    apt install -y --no-install-recommends ${need}
}

# 会话自启动（幂等：缺哪行补哪行）
#   @lxpanel/@pcmanfm 起面板与桌面图标，autocutsel×2 做剪贴板双向同步，
#   @fcitx 起输入法，@xset 关屏保/息屏（防长时间放置黑屏）
ensure_session_autostart() {
    local f="${USER_HOME}/.config/lxsession/LXDE/autostart" line
    mkdir -p "${USER_HOME}/.config/lxsession/LXDE"
    [ -f "${f}" ] || : > "${f}"
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        grep -qF "${line}" "${f}" || echo "${line}" >> "${f}"
    done << 'EOF_AUTOSTART'
@lxpanel --profile LXDE
@pcmanfm --desktop --profile LXDE
@autocutsel -s CLIPBOARD -fork
@autocutsel -s PRIMARY -fork
@fcitx
@xset s off -dpms s noblank
EOF_AUTOSTART
    chown ${VNC_USER}:${VNC_USER} "${f}" 2>/dev/null || true
}

# 保证会话里有窗口管理器（openbox）—— 桌面「窗口没有标题栏 / 没有关闭按钮」的根治点。
#
# 现象：桌面能进、面板和图标都在，但所有窗口都没有标题栏，没有关闭/最小化/最大化
#       按钮，也不能拖动或缩放（其实是没有窗口管理器在跑）。
# 原因：lxsession 一旦存在用户级 desktop.conf，就【只读用户文件】，不再合并
#       /etc/xdg/lxsession/LXDE/desktop.conf 的默认值；而 [Session] 组里缺
#       window_manager 键时，lxsession 根本不启动窗口管理器。触发路径：
#       加固模块 [10] 先于流水线模块 [6] 运行时会用 printf 写出一个只含
#       polkit/command= 的空壳 desktop.conf，[6] 里的「文件不存在才 cp」随即被跳过，
#       系统默认的 window_manager=openbox-lxde 就永远进不来；
#       之后 lxsession 还会把这个空壳回写成完整配置（但不含 window_manager），
#       于是窗口管理器永久失效。
# 处理：幂等补齐该键（值取自系统默认：openbox-lxde，由 openbox-lxde-session 提供，
#       作用是让 openbox 读取 LXDE 的 lxde-rc.xml）。
ensure_session_window_manager() {
    local lx_dir="${USER_HOME}/.config/lxsession/LXDE"
    local lx_conf="${lx_dir}/desktop.conf"
    local wm="${SESSION_WM:-openbox-lxde}"

    mkdir -p "${lx_dir}"
    # 用户配置不存在时，先照抄系统默认（本身就带 window_manager）
    if [ ! -f "${lx_conf}" ] && [ -f /etc/xdg/lxsession/LXDE/desktop.conf ]; then
        cp /etc/xdg/lxsession/LXDE/desktop.conf "${lx_conf}"
    fi
    [ -f "${lx_conf}" ] || printf '[Session]\n' > "${lx_conf}"

    if grep -q '^window_manager=' "${lx_conf}"; then
        sed -i "s|^window_manager=.*|window_manager=${wm}|" "${lx_conf}"
    elif grep -q '^\[Session\]$' "${lx_conf}"; then
        awk -v line="window_manager=${wm}" \
            'BEGIN{done=0} {print} /^\[Session\]$/ && !done {print line; done=1}' \
            "${lx_conf}" > "${lx_conf}.new" && mv "${lx_conf}.new" "${lx_conf}"
    else
        { printf '[Session]\nwindow_manager=%s\n' "${wm}"; cat "${lx_conf}"; } > "${lx_conf}.new" \
            && mv "${lx_conf}.new" "${lx_conf}"
    fi
    chown ${VNC_USER}:${VNC_USER} "${lx_conf}" 2>/dev/null || true

    if grep -q '^window_manager=' "${lx_conf}"; then
        echo "✅ 窗口管理器已就绪：window_manager=${wm}（窗口有标题栏与关闭按钮）"
    else
        echo "⚠️ 写入 window_manager 失败，窗口会没有关闭按钮，请检查 ${lx_conf}"
    fi
}

# 虚拟桌面数：把 openbox 的 <desktops><number> 收敛成指定的个数。
#   openbox --reconfigure 只重读键位/主题，不改桌面数，所以会话在跑时走 EWMH
#   （xdotool set_num_desktops / wmctrl -n）。
setup_lxde_desktops() {
    local f="${USER_HOME}/.config/openbox/lxde-rc.xml"
    local cur="" want="${LXDE_DESKTOPS}"

    # 现场值：只认 <desktops> 段里的那一处 <number>
    if [ -f "${f}" ]; then
        cur=$(sed -n '/<desktops>/,/<\/desktops>/ s|.*<number>\([0-9][0-9]*\)</number>.*|\1|p' "${f}" | head -1)
    fi

    if [ -z "${want}" ]; then
        if [ -t 0 ] && [ -t 1 ]; then
            local def="${cur:-1}"
            echo "虚拟桌面（工作区）："
            echo "  LXDE/openbox 默认给 2 个；远程桌面只需要 1 个。"
            [ -n "${cur}" ] && echo "  当前配置：${cur} 个"
            while true; do
                if ! read -r -p "  保留几个桌面？[1=只要一个（推荐）/ 2=保留默认] [${def}]: " want; then
                    echo
                    want="${def}"
                    break
                fi
                [ -z "${want}" ] && want="${def}"
                case "${want}" in
                    0|1|2) break ;;
                    *) echo "  ⚠️ 只支持 1（去掉多余桌面）/ 2（保留两个）/ 0（不修改）" ;;
                esac
            done
        else
            want="${cur:-1}"
            echo "ℹ️ 非交互模式：虚拟桌面数沿用 ${want}（新装默认 1；可用 LXDE_DESKTOPS=2 保留两个）"
        fi
    fi
    LXDE_DESKTOPS="${want}"

    case "${want}" in
        0)
            echo "⏭  虚拟桌面：保留现场设置（LXDE_DESKTOPS=0）"
            return 0
            ;;
        1|2) ;;
        *)
            echo "⚠️ LXDE_DESKTOPS=${want} 不支持（只认 1 / 2 / 0），跳过"
            return 0
            ;;
    esac

    # 还没登录过桌面时用户配置可能不存在：先铺一份系统模板，免得首次登录又变回 2
    if [ ! -f "${f}" ] && [ -f /etc/xdg/openbox/LXDE/rc.xml ]; then
        install -d -o "${VNC_USER}" -g "${VNC_USER}" "$(dirname "${f}")"
        install -o "${VNC_USER}" -g "${VNC_USER}" -m 0644 /etc/xdg/openbox/LXDE/rc.xml "${f}"
    fi
    if [ ! -f "${f}" ]; then
        echo "⚠️ 找不到 ${f}，无法设置虚拟桌面数（进一次桌面后重跑本步即可）"
        return 0
    fi

    if ! grep -q '<desktops>' "${f}"; then
        # 老配置没有这一段：补在 </openbox_config> 前面
        sed -i "s|</openbox_config>|  <desktops>\n    <number>${want}</number>\n  </desktops>\n</openbox_config>|" "${f}"
    elif ! sed -n '/<desktops>/,/<\/desktops>/ p' "${f}" | grep -q '<number>'; then
        # 有段但没有 number
        sed -i "s|<desktops>|<desktops>\n    <number>${want}</number>|" "${f}"
    else
        sed -i -E "/<desktops>/,/<\/desktops>/ s|<number>[0-9]+</number>|<number>${want}</number>|" "${f}"
    fi
    chown "${VNC_USER}:${VNC_USER}" "${f}" 2>/dev/null || true

    # 会话在跑就立刻生效（root 连 :1 没问题；没有 xdotool 就退到 wmctrl）
    if [ -S /tmp/.X11-unix/X1 ] && pgrep -u "${VNC_USER}" -x openbox >/dev/null 2>&1; then
        if command -v xdotool >/dev/null 2>&1; then
            DISPLAY=:1 xdotool set_num_desktops "${want}" >/dev/null 2>&1 || true
        elif command -v wmctrl >/dev/null 2>&1; then
            DISPLAY=:1 wmctrl -n "${want}" >/dev/null 2>&1 || true
        fi
    fi

    local now=""
    [ -S /tmp/.X11-unix/X1 ] && now=$(DISPLAY=:1 xprop -root _NET_NUMBER_OF_DESKTOPS 2>/dev/null | sed 's/.*= *//')
    if [ "${now}" = "${want}" ]; then
        echo "✅ 虚拟桌面：${want} 个（已生效）"
    else
        echo "✅ 虚拟桌面：配置已设为 ${want} 个${now:+，当前会话 ${now} 个（重登录后生效）}"
    fi
}

# 磁盘打理：清掉安装期索引缓存 + 给 journald 日志设上限（可反复执行）
#   /var/lib/apt/lists 装完能到 ~85 MiB（下次 apt update 会自动重下）
#   journald 默认无上限（最多可吃磁盘 10%），这里固定 64 MiB
housekeeping_disk() {
    echo "--- 清理安装缓存与日志 ---"

    local before after
    before=$(du -sm /var/lib/apt/lists 2>/dev/null | cut -f1); before=${before:-0}
    rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    apt-get clean 2>/dev/null || true
    after=$(du -sm /var/lib/apt/lists 2>/dev/null | cut -f1); after=${after:-0}
    echo "✅ 已清空 apt 索引缓存（释放约 $((before - after)) MiB）"

    local jconf=/etc/systemd/journald.conf.d/99-vps-setup.conf
    mkdir -p /etc/systemd/journald.conf.d
    if grep -q '^SystemMaxUse=64M' "${jconf}" 2>/dev/null; then
        echo "ℹ️ journald 日志上限已是 64M"
    else
        printf '[Journal]\nSystemMaxUse=64M\nSystemKeepFree=256M\n' > "${jconf}"
        systemctl restart systemd-journald 2>/dev/null || true
        echo "✅ journald 日志上限已设为 64M（${jconf}）"
    fi
    journalctl --vacuum-size=64M >/dev/null 2>&1 || true
}

configure_username() {
    clear
    echo "========================================"
    echo "👤  VNC 运行用户配置 (权限隔离)"
    echo "========================================"
    echo "安全规范：VNC 桌面及 MT5 将以该特定普通用户权限安全隔离运行。"
    echo "当前默认用户: ${VNC_USER}"
    echo ""
    read -p "请输入用户名 [回车默认: vncuser1]: " input_user

    if [ ! -z "$input_user" ]; then
        VNC_USER="$input_user"
    fi

    update_variables
    echo "----------------------------------------"
    echo "✅ 服务绑定用户: ${VNC_USER}"
    echo "📂 用户主目录:   ${USER_HOME}"
    echo "----------------------------------------"
    sleep 1
}

# -------------------------------------------------------
# 凭据记录：/root/.vnc-desktop-credentials (600)
#   每行 KEY=VALUE：VNC_USER / DESKTOP_PASS / VNC_PASS
#   读取不用 source，避免密码里的特殊字符被 shell 解析。
# -------------------------------------------------------
cred_get() {
    [ -f "${CRED_FILE}" ] || return 1
    local v
    v=$(sed -n "s|^$1=||p" "${CRED_FILE}" 2>/dev/null | head -1)
    [ -n "${v}" ] || return 1
    printf '%s' "${v}"
}

cred_set() {
    local key="$1" val="$2" tmp
    touch "${CRED_FILE}"
    chmod 600 "${CRED_FILE}"
    tmp=$(mktemp)
    grep -v "^${key}=" "${CRED_FILE}" > "${tmp}" 2>/dev/null || true
    printf '%s=%s\n' "${key}" "${val}" >> "${tmp}"
    cat "${tmp}" > "${CRED_FILE}"
    rm -f "${tmp}"
}

# 判断账户是否有「可用的」Linux 密码（passwd -S 第二列 = P 才算可用）
#   L  = 锁定/无密码 —— adduser --disabled-password 建出来的就是这个，sudo 必然认证失败
#   NP = 无密码
# 注意：这与 VNC 连接密码（~/.vnc/passwd，由 x11vnc -storepasswd 生成）完全是两回事！
user_has_no_password() {
    case "$(passwd -S "${VNC_USER}" 2>/dev/null | awk '{print $2}')" in
        P) return 1 ;;   # 已有可用密码
        *) return 0 ;;   # L / NP / 取不到 → 视为没有可用密码
    esac
}

# 交互读取两遍密码（不回显）；成功返回 0 并把明文放进 READ_PASS
read_new_password() {
    local prompt="$1" max="${2:-0}" p1 p2
    if [ ! -t 0 ]; then
        echo "ℹ️ 当前不是交互终端，无法读取密码。"
        return 1
    fi
    while true; do
        read -r -s -p "${prompt}: " p1 || { echo; echo "  ℹ️ 输入结束（EOF/Ctrl+D），已取消。"; return 1; }
        echo
        [ -z "${p1}" ] && { echo "  ⚠️ 不能为空，请重试（Ctrl+C 可放弃）"; continue; }
        if [ "${max}" -gt 0 ] && [ "${#p1}" -gt "${max}" ]; then
            echo "  ⚠️ 最多 ${max} 位（当前 ${#p1} 位），请重试"; continue
        fi
        read -r -s -p "请再输入一次确认: " p2 || { echo; echo "  ℹ️ 输入结束（EOF/Ctrl+D），已取消。"; return 1; }
        echo
        [ "${p1}" = "${p2}" ] || { echo "  ⚠️ 两次输入不一致，请重试"; continue; }
        break
    done
    READ_PASS="${p1}"
    return 0
}

# 设置桌面用户 Linux 密码（只设这一次），并记录明文到凭据文件
set_desktop_password() {
    echo "🔑 设置 ${VNC_USER} 的 Linux 密码（sudo/本地登录用；与 VNC 连接密码不是一回事）"
    if [ -t 0 ]; then
        read_new_password "请输入 ${VNC_USER} 的新密码" || {
            echo "ℹ️ 已取消。之后可用菜单 [11] 或 passwd ${VNC_USER} 设置。"
            return 1
        }
    else
        # 非交互（脚本化安装）：自动生成并记录，绝不把"没有密码"静默略过
        READ_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
        echo "ℹ️ 非交互终端：已自动生成随机密码（菜单 [11] 可查看）"
    fi
    printf '%s:%s\n' "${VNC_USER}" "${READ_PASS}" | chpasswd
    if user_has_no_password; then
        echo "⚠️ 密码写入失败（/etc/shadow 仍不可用）。稍后可执行：passwd ${VNC_USER}"
        return 1
    fi
    cred_set DESKTOP_PASS "${READ_PASS}"
    echo "✅ 已设置并记录密码（菜单 [11] 可查看）"
    return 0
}

# 设置 VNC 连接密码（只设这一次），并记录明文；VNC 协议上限 8 位
set_vnc_password() {
    echo "🔑 设置 VNC 连接密码（noVNC 网页里输入的密码；VNC 协议上限 8 位）"
    if [ -t 0 ]; then
        read_new_password "请输入 VNC 连接密码" 8 || {
            echo "ℹ️ 已取消。之后可用菜单 [11] 重设。"
            return 1
        }
    else
        READ_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8)
        echo "ℹ️ 非交互终端：已自动生成随机 VNC 密码（菜单 [11] 可查看）"
    fi
    mkdir -p "${VNC_CONF_DIR}"
    if ! x11vnc -storepasswd "${READ_PASS}" "${VNC_PASSWD_FILE}" >/dev/null 2>&1; then
        echo "❌ x11vnc -storepasswd 执行失败，VNC 密码未改动"
        return 1
    fi
    chown ${VNC_USER}:${VNC_USER} "${VNC_PASSWD_FILE}" 2>/dev/null || true
    chmod 600 "${VNC_PASSWD_FILE}"
    cred_set VNC_PASS "${READ_PASS}"
    echo "✅ 已设置并记录 VNC 连接密码（若 x11vnc 正在运行：systemctl restart x11vnc@1）"
    return 0
}

# 确保桌面账户有可用密码，并把明文记录到凭据文件
ensure_recorded_desktop_password() {
    if ! user_has_no_password; then
        if cred_get DESKTOP_PASS >/dev/null; then
            echo "✅ 桌面用户 ${VNC_USER} 已有可用密码（已记录，菜单 [11] 可查看）"
        else
            echo "✅ 桌面用户 ${VNC_USER} 已有可用密码（历史设置、明文未记录；如需展示可在菜单 [11] 重设）"
        fi
        return 0
    fi
    echo "========================================"
    echo "⚠️ 用户 ${VNC_USER} 当前没有可用的 Linux 密码"
    echo "   （/etc/shadow 为 ! 状态 → sudo 一定认证失败；"
    echo "     它和 VNC 连接密码 ~/.vnc/passwd 不是一回事）"
    echo "   这里只需设置这一次，之后不再询问。"
    echo "========================================"
    set_desktop_password
}

# VNC 连接密码：文件已存在就不覆盖（只设置一次）；明文未记录时提示可用菜单 [11] 重设
ensure_vnc_password() {
    if [ -f "${VNC_PASSWD_FILE}" ]; then
        chmod 600 "${VNC_PASSWD_FILE}" 2>/dev/null || true
        if cred_get VNC_PASS >/dev/null; then
            echo "✅ VNC 连接密码已存在且已记录（菜单 [11] 可查看）"
        else
            echo "✅ VNC 连接密码文件已存在（历史设置、明文未记录；如需展示可在菜单 [11] 重设）"
        fi
        return 0
    fi
    echo "========================================"
    echo "🔑 首次设置 VNC 连接密码（只设这一次，之后不再询问）"
    echo "   用途：noVNC 网页里输入的密码；VNC 协议上限 8 位。"
    echo "========================================"
    set_vnc_password
}

# 创建/补齐桌面运行用户（幂等：已存在则只补组与目录）
# 密码统一交给 ensure_desktop_user_and_password 处理，避免各菜单反复追问
create_desktop_user() {
    if ! id "${VNC_USER}" &>/dev/null; then
        echo "📁 创建服务用户 ${VNC_USER}..."
        adduser --disabled-password --gecos "" --home ${USER_HOME} ${VNC_USER}
        usermod -aG sudo ${VNC_USER}

        echo "📁 正在强制生成英文基础目录..."
        su - ${VNC_USER} -c "LC_ALL=C xdg-user-dirs-update --force"
    else
        echo "ℹ️ 用户 ${VNC_USER} 已存在，跳过创建（仅补齐组与目录）。"
        usermod -aG sudo ${VNC_USER} 2>/dev/null || true
    fi

    mkdir -p ${USER_HOME}/Desktop ${USER_HOME}/.vnc ${USER_HOME}/.config/autostart
    chown -R ${VNC_USER}:${VNC_USER} ${USER_HOME}
    loginctl enable-linger ${VNC_USER} 2>/dev/null || true
}

# -------------------------------------------------------
# 桌面用户 + 密码：全程只设置一次
#   首次：询问一次用户名（默认 vncuser1）→ 建账户 → 设一次密码 → 记录到凭据文件
#   之后：凭据文件里已有用户名且账户密码可用 → 直接跳过，不再询问
#   查看 / 重设：见菜单 [11]（或 --show-credentials）
# -------------------------------------------------------
ensure_desktop_user_and_password() {
    local stored reset_choice
    stored=$(cred_get VNC_USER)

    # 已配置好 → 不打扰用户
    if [ -n "${stored}" ]; then
        VNC_USER="${stored}"
        update_variables
        if id "${VNC_USER}" &>/dev/null && ! user_has_no_password; then
            echo "ℹ️ 桌面用户已配置：${VNC_USER}（跳过用户名/密码设置；查看或重设见菜单 [11]）"
            create_desktop_user >/dev/null 2>&1 || true
            return 0
        fi
    fi

    # 首次配置：只在这里询问一次用户名
    if [ -z "${stored}" ]; then
        configure_username
        cred_set VNC_USER "${VNC_USER}"

        # 历史安装的账户已存在时，给一次「保留 / 重置」选择
        if id "${VNC_USER}" &>/dev/null; then
            echo "========================================"
            echo "⚠️ 检测到用户 ${VNC_USER} 已存在！"
            echo "========================================"
            echo " [1] 保留现有数据（仅修复组权限并确认密码）[默认]"
            echo " [2] 彻底重置用户（清空家目录，重新生成纯净英文环境）"
            read -p "请选择处理方式 [1/2, 默认 1]: " reset_choice
            if [ "${reset_choice}" = "2" ]; then
                echo "⚠️ 正在彻底清理并重置用户 ${VNC_USER}..."
                pkill -u "${VNC_USER}" 2>/dev/null || true
                deluser --remove-home "${VNC_USER}" >/dev/null 2>&1 || true
            else
                echo "ℹ️ 已选择保留现有用户 ${VNC_USER} 及全部数据。"
            fi
        fi
    fi

    create_desktop_user
    ensure_recorded_desktop_password
}

# =======================================================
# 桌面加固：屏蔽「注销/关机」入口与「屏幕锁」，让点击无反应
#   - lxpanel：移除右下角「屏幕锁 / 注销」按钮 + 主菜单里的注销项
#   - 注销/锁屏程序：dpkg-divert 备份后替换为空操作（点击无任何反应）
#   - 隐藏 lxde-logout / lxde-screenlock 桌面条目（用户级 Hidden=true，升级不复活）
#   - 屏保/息屏：light-locker / xscreensaver / DPMS 全部关闭
#   - polkit 认证代理（lxpolkit）关闭：本桌面是 systemd 系统服务、没有 logind 会话，
#     lxpolkit 必然注册失败并把 "No session for pid <PID>" 弹成「错误」对话框
#     （每次切分辨率/重启桌面都弹一次）。这里不需要 polkit 授权，直接关掉。
# 幂等：重复执行只做校验与补齐。
# =======================================================
silence_desktop_bins() {
    local p bin

    # 用户级隐藏「注销 / 锁屏」桌面条目（覆盖系统 .desktop，避免菜单里复活）
    local apps_dir="${USER_HOME}/.local/share/applications"
    mkdir -p "${apps_dir}"
    for p in lxde-logout lxde-screenlock xscreensaver; do
        cat > "${apps_dir}/${p}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${p} (disabled)
Hidden=true
NoDisplay=true
EOF
    done
    chown -R ${VNC_USER}:${VNC_USER} "${USER_HOME}/.local" 2>/dev/null || true

    # 隐藏 light-locker 自启动（防止长时间无人后黑屏上锁）
    if [ -f /etc/xdg/autostart/light-locker.desktop ]; then
        sed -i '/^Hidden=/d' /etc/xdg/autostart/light-locker.desktop
        echo "Hidden=true" >> /etc/xdg/autostart/light-locker.desktop
    fi

    # 注销/锁屏程序 → 空操作（原程序备份为同名 .real，恢复见函数末尾提示）
    for p in lxde-logout lxsession-logout lxlock light-locker xscreensaver; do
        bin=$(command -v "${p}" 2>/dev/null || true)
        [ -z "${bin}" ] && continue
        [ -f "${bin}.real" ] && continue      # 已处理过（幂等）
        dpkg-divert --add --rename --divert "${bin}.real" "${bin}" >/dev/null 2>&1 || true
        cat > "${bin}" << 'EOF_SILENT'
#!/bin/sh
# 已被 vps-setup 桌面加固禁用（原程序见同目录同名 .real）
exit 0
EOF_SILENT
        chmod +x "${bin}"
    done
}

harden_desktop_session() {
    echo "--- 桌面加固：屏蔽「注销 / 关机 / 屏幕锁」---"
    silence_desktop_bins

    # ---- 1) 处理 lxpanel 面板配置：去掉「注销」「屏幕锁」按钮与菜单注销项 ----
    local panel_src="/etc/xdg/lxpanel/LXDE/panels/panel"
    local panel_dir="${USER_HOME}/.config/lxpanel/LXDE/panels"
    local panel_dst="${panel_dir}/panel"
    local panel_in=""
    [ -f "${panel_dst}" ] && panel_in="${panel_dst}"          # 已有用户配置以它为准
    [ -z "${panel_in}" ] && [ -f "${panel_src}" ] && panel_in="${panel_src}"

    if [ -n "${panel_in}" ]; then
        mkdir -p "${panel_dir}"
        local awkf; awkf=$(mktemp)
        cat > "${awkf}" << 'EOF_AWK'
# 1) 含 lxde-logout / lxde-screenlock 按钮的整块 Plugin {...} 直接丢弃
# 2) 保留的 Plugin 内，删除 config 为 command=logout 的 item {...}
function strip_item(text,    n, a, i, out, in_item, buf, drop) {
    n = split(text, a, "\n")
    out = ""; in_item = 0; drop = 0; buf = ""
    for (i = 1; i <= n; i++) {
        if (a[i] == "" && i == n) continue
        if (!in_item && a[i] ~ /^[[:space:]]*item[[:space:]]*\{[[:space:]]*$/) {
            in_item = 1; drop = 0; buf = a[i] "\n"; continue
        }
        if (in_item) {
            buf = buf a[i] "\n"
            if (a[i] ~ /command[[:space:]]*=[[:space:]]*logout/) drop = 1
            if (a[i] ~ /^[[:space:]]*\}[[:space:]]*$/) {
                in_item = 0
                if (!drop) out = out buf
            }
            continue
        }
        out = out a[i] "\n"
    }
    return out
}
BEGIN { inplug = 0; plug = "" }
/^Plugin[[:space:]]*\{/ { inplug = 1; plug = $0 "\n"; next }
inplug {
    plug = plug $0 "\n"
    if ($0 ~ /^\}[[:space:]]*$/) {
        inplug = 0
        if (plug !~ /lxde-logout\.desktop|lxde-screenlock\.desktop/) printf "%s", strip_item(plug)
    }
    next
}
{ print }
EOF_AWK
        if awk -f "${awkf}" "${panel_in}" > "${panel_dst}.new" 2>/dev/null \
           && [ "$(wc -c < "${panel_dst}.new" 2>/dev/null || echo 0)" -gt 200 ] \
           && ! grep -q "lxde-logout\.desktop\|lxde-screenlock\.desktop" "${panel_dst}.new"; then
            mv "${panel_dst}.new" "${panel_dst}"
            echo "✅ lxpanel 面板：已移除右下角「注销 / 屏幕锁」按钮与菜单里的注销项"
        else
            rm -f "${panel_dst}.new"
            echo "⚠️ lxpanel 面板配置处理失败，保持原样"
        fi
        rm -f "${awkf}"

        # 面板固定 1920 宽、贴「虚拟屏右下角」，用 lxpanel 自己的定位规则：
        #   monitor=-1    位置按整个屏幕算。默认 monitor=0 会让面板永远粘在
        #                 x=0，Selkies left 布局时它就跑到了第二块屏上。
        #   align=right   x = 屏宽 - 1920：单屏 = 0；left 布局（3840 宽）= 1920，
        #                 正好落在主屏（left 时主屏被挪到右侧）。
        #   setpartialstrut=1  自带 strut，范围就是面板自己那 1920，无死条。
        # 不需要任何钉面板的守护进程。
        sed -i \
            -e 's/^\([[:space:]]*\)widthtype=.*/\1widthtype=pixel/' \
            -e 's/^\([[:space:]]*\)width=.*/\1width=1920/' \
            -e 's/^\([[:space:]]*\)align=.*/\1align=right/' \
            -e 's/^\([[:space:]]*\)setpartialstrut=.*/\1setpartialstrut=1/' \
            "${panel_dst}" 2>/dev/null || true
        if grep -q '^[[:space:]]*monitor=' "${panel_dst}" 2>/dev/null; then
            sed -i 's/^\([[:space:]]*\)monitor=.*/\1monitor=-1/' "${panel_dst}"
        else
            sed -i '0,/^[[:space:]]*align=.*/s//&\n    monitor=-1/' "${panel_dst}" 2>/dev/null || true
        fi
        echo "✅ lxpanel 面板：1920 宽、贴右下角（单屏=0 / left 布局=主屏）、自带 strut"
    else
        echo "ℹ️ 未找到 lxpanel 面板配置（可能尚未安装 LXDE 桌面核心），跳过"
    fi
    chown -R ${VNC_USER}:${VNC_USER} "${USER_HOME}/.config/lxpanel" 2>/dev/null || true

    # ---- 2) 会话自启动：面板/桌面图标/剪贴板/输入法/防息屏（幂等补齐）----
    local lx_dir="${USER_HOME}/.config/lxsession/LXDE"
    mkdir -p "${lx_dir}"
    ensure_session_autostart
    chown -R ${VNC_USER}:${VNC_USER} "${lx_dir}" 2>/dev/null || true

    # ---- 3) 关闭 lxpolkit（polkit 认证代理），消除「No session for pid N」弹框 ----
    #
    # 现象：每次切分辨率（= 重启 xvfb@N，BindsTo 连带重启整个桌面）后，桌面上都会弹出一个
    #       标题为「错误」的对话框，正文是 "No session for pid <PID>"。
    # 原因：本桌面跑在 systemd 系统服务 vnc-desktop@N.service 里，不是 logind 登录会话
    #       （loginctl list-sessions 为空）。lxpolkit 启动时会执行
    #           polkit_unix_session_new_for_process_sync(getpid(), ...)
    #       查「自己属于哪个会话」，必然失败；lxpolkit 的源码随即把这个 GError 的文本
    #       直接 show_msg() 成 GTK 错误框（lxsession/lxpolkit/lxpolkit.c）。
    #       PID 就是那一次 lxpolkit 自己的 pid，所以每次重启数字都不一样。
    # 处理：这个桌面里没有任何需要 polkit 授权的东西（注销/关机入口已在本模块屏蔽），
    #       所以直接把代理关掉：既不再弹框，也保持「不做管理员授权就拿不到特权」的严格姿态。
    #       注意：不要改成给服务加 PAMName=login 去「真修」——那会让桌面被 polkit 当成
    #       本地活动会话，logind 的关机/重启等 allow_active 动作会变成免密执行。
    local lx_conf="${lx_dir}/desktop.conf"
    if [ ! -f "${lx_conf}" ]; then
        printf '[Session]\npolkit/command=\n' > "${lx_conf}"
    elif grep -q '^polkit/command=' "${lx_conf}"; then
        sed -i 's|^polkit/command=.*|polkit/command=|' "${lx_conf}"
    elif grep -q '^\[Session\]' "${lx_conf}"; then
        awk 'BEGIN{done=0} {print} /^\[Session\]$/ && !done {print "polkit/command="; done=1}' \
            "${lx_conf}" > "${lx_conf}.new" && mv "${lx_conf}.new" "${lx_conf}"
    else
        { printf '[Session]\npolkit/command=\n'; cat "${lx_conf}"; } > "${lx_conf}.new" \
            && mv "${lx_conf}.new" "${lx_conf}"
    fi
    chown ${VNC_USER}:${VNC_USER} "${lx_conf}" 2>/dev/null || true

    # 兜底：本模块可能是最先创建 desktop.conf 的模块（只写了 polkit 键的空壳），
    #       必须把窗口管理器键补回去，否则桌面会「能进，但窗口没有关闭按钮」。
    ensure_session_window_manager

    if grep -q '^polkit/command=lxpolkit' "${lx_conf}" 2>/dev/null; then
        echo "⚠️ lxpolkit 关闭失败，请检查 ${lx_conf}"
    else
        echo "✅ 已关闭 lxpolkit 认证代理（不再弹「No session for pid N」错误框）"
    fi

    # 双保险：系统级自启条目也置 Hidden=true（Debian 默认已是，防止将来被改动）
    if [ -f /etc/xdg/autostart/lxpolkit.desktop ] \
       && ! grep -q '^Hidden=true' /etc/xdg/autostart/lxpolkit.desktop; then
        sed -i '/^Hidden=/d' /etc/xdg/autostart/lxpolkit.desktop
        echo "Hidden=true" >> /etc/xdg/autostart/lxpolkit.desktop
    fi

    echo "✅ 桌面加固完成（注销/关机/屏幕锁入口均已失效）"
    echo "   如需恢复注销功能: dpkg-divert --remove /usr/bin/lxde-logout"
    echo "   并删除 ${USER_HOME}/.config/lxpanel/LXDE/panels/panel 后重启桌面服务。"
}

# 检测是否运行在容器内（LXC/Docker/Podman/OpenVZ...），返回类型字符串
#
# 为什么容器内绝不能碰 swap：
#   Linux 的 swap 不参与命名空间隔离 —— 容器里执行 swapon 会直接给【宿主机内核】
#   添加/替换 swap 设备。在 LXC 里 a /swapfile 指向容器 rootfs（即宿主磁盘上的文件），
#   一旦 swapon，宿主的 swap 就被容器改写了，属于跨边界的高危操作。
detect_container() {
    local t=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        t=$(systemd-detect-virt --container 2>/dev/null || true)
        if [ -n "$t" ] && [ "$t" != "none" ]; then echo "$t"; return 0; fi
    fi
    if [ -f /run/systemd/container ] && [ -s /run/systemd/container ]; then
        cat /run/systemd/container; return 0
    fi
    [ -f /.dockerenv ] && { echo "docker"; return 0; }
    [ -d /proc/vz ] && [ -f /proc/vz/veinfo ] && { echo "openvz"; return 0; }
    if grep -qaE '(^| )container=' /proc/1/environ 2>/dev/null; then
        tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n 's/^container=//p' | head -1
        return 0
    fi
    if grep -qaE 'lxc|docker|kubepods|containerd|podman|garden' /proc/1/cgroup 2>/dev/null; then
        echo "unknown"; return 0
    fi
    return 1
}

setup_swap() {
    echo "--- 检查 Swap ---"

    local ctype=""
    if ctype=$(detect_container); then
        echo "ℹ️ 检测到容器环境（${ctype}），已跳过容器内 swapfile 的创建与启用。"
        echo "   swap 统一由宿主机管理；容器内 swapon 会直接作用于宿主机内核（跨边界风险）。"
        return 0
    fi

    # 已是活动 swap（不依赖 fstab 判断）—— 直接跳过，避免 fallocate 覆盖正在使用的 swap 文件
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${SWAP_FILE}"; then
        echo "✅ Swap 已激活（${SWAP_FILE}）。"
        return 0
    fi

    if grep -q "${SWAP_FILE}" /etc/fstab; then
        echo "✅ Swap 已在 /etc/fstab 中配置（${SWAP_FILE}）。"
        if [ -f "${SWAP_FILE}" ]; then
            swapon "${SWAP_FILE}" 2>/dev/null && echo "   已按 fstab 重新启用。" || true
        fi
        return 0
    fi

    echo "创建 Swap..."
    fallocate -l ${SWAP_SIZE} ${SWAP_FILE}; chmod 600 ${SWAP_FILE}
    mkswap ${SWAP_FILE}; swapon ${SWAP_FILE}
    echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
}

setup_system_and_user_and_locale() {
    # 桌面运行用户 + 密码：只设置一次（已有记录则直接跳过）
    echo "--- 0. 设置桌面运行用户（只设置一次）---"
    ensure_desktop_user_and_password

    echo "--- 1. 更新系统与基础依赖 ---"
    setup_swap
    apt update
    # 全部 --no-install-recommends：避免拉进 zenity/libwebkit2gtk/ghostscript/
    # imagemagick/gstreamer/mesa-vulkan 等数百 MiB 的推荐包（实测可省 300~500 MiB）
    # 注：xauth / x11-utils / fontconfig 虽被上游列为 Recommends，但本方案实际要用，
    #     故显式列出（合计仅约 1.4 MiB）。
    apt install -y --no-install-recommends curl wget sudo gnupg2 sed locales xdg-user-dirs openssl haveged \
        xvfb x11vnc xauth x11-utils fontconfig apt-transport-https ca-certificates procps \
        wmctrl xdotool autocutsel lsb-release x11-xserver-utils
    mkdir -p /etc/pipewire && touch /etc/pipewire/client.conf

    echo "--- 2. 安装中文字体 ---"
    # 只装微米黑（体积小、覆盖常用简繁中文）；如需更多字形可自行追加 fonts-wqy-zenhei
    apt install -y --no-install-recommends fonts-wqy-microhei

    echo "--- 3. 安装 Fcitx4 + Google 拼音 ---"
    apt install -y --no-install-recommends fcitx fcitx-googlepinyin fcitx-ui-classic fcitx-config-gtk \
                    fcitx-frontend-gtk2 fcitx-frontend-gtk3 fcitx-frontend-qt5 \
                    dbus-x11 im-config libgtk2.0-bin libgtk-3-bin at-spi2-core

    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
    update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8

    timedatectl set-timezone Asia/Shanghai

    # 账户与密码已在上面的 ensure_desktop_user_and_password 里统一处理（只设一次）

    # 启用用户会话永久驻留（防止无 SSH 连接时被系统回收）
    su - ${VNC_USER} -c "im-config -n fcitx"
    echo "✅ 系统与用户初始化完成。"
}

install_lxde_desktop() {
    # 用户名/密码只设置一次：已有记录则直接跳过（不再询问），查看/重设见菜单 [11]。
    echo "--- 0. 桌面运行用户（只设置一次）---"
    ensure_desktop_user_and_password

    echo "--- 安装 LXDE 桌面核心 ---"
    ensure_apt_lists
    apt install -y --no-install-recommends ${PKG_LXDE}
    echo "✅ LXDE 桌面核心安装完成（桌面运行用户: ${VNC_USER}）"

    # 装完立即加固：屏蔽右下角「注销/屏幕锁」按钮与菜单注销项
    harden_desktop_session
}

install_wine_env() {
    echo "--- 正在安装 Wine (64位 + 32位 全功能版) ---"
    dpkg --add-architecture i386
    apt update
    apt install -y --no-install-recommends winetricks wine wine32 wine64 libwine libwine:i386 fonts-wine
    chown -R ${VNC_USER}:${VNC_USER} ${USER_HOME}

    echo "⚙️ 正在初始化 Wine 前缀..."
    su - ${VNC_USER} -c "
        export WINEPREFIX=${USER_HOME}/.wine
        export WINEDEBUG=-all
        xvfb-run -a wineboot --init >/dev/null 2>&1
        xvfb-run -a winetricks -q fakechinese corefonts >/dev/null 2>&1
    "

    cat > /usr/local/bin/wine-cn <<EOF
#!/bin/bash
export LC_ALL=zh_CN.UTF-8
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export DISPLAY=:1
wine "\$@"
EOF
    chmod +x /usr/local/bin/wine-cn
    echo "✅ Wine 安装完成。"
}

install_edge_browser() {
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main" > /etc/apt/sources.list.d/microsoft-edge.list
    apt update; apt install -y --no-install-recommends microsoft-edge-stable
}

# -------------------------------------------------------
# OpenResty 增量配置（不再整份覆盖 nginx.conf）
#
#   旧做法是 `cat > /etc/openresty/nginx.conf` 整份覆盖 —— 你原有的 server /
#   upstream / webterm 等配置会被一起抹掉。现在改成增量：
#     · 你的 nginx.conf 能不动就不动：只有它内部没有任何 conf.d include 时，
#       才补插 1 行带标记的 include（插前自动备份，nginx -t 失败自动回滚）。
#     · noVNC 站点的 server 块只写脚本自己的 conf.d/50-novnc.conf，可反复覆盖；
#       删掉该文件 + reload 就等于卸载 noVNC 站点，与你其它配置互不影响。
#     · 端口：优先 443；若已被别的 server 块占用就自动退到 8443，之后一直沿用。
#     · 老版本（内联式）留下的 noVNC server 块会被摘出来放进 drop-in，
#       你后来加在 nginx.conf 里的其它内容保持不变。
#
#   路径以 nginx -V 的 --prefix 为准（/etc/openresty 是 <prefix>/conf 的软链）。
# -------------------------------------------------------

detect_openresty_paths() {
    local bin="/usr/local/openresty/nginx/sbin/nginx"
    OR_PREFIX=""
    if [ -x "${bin}" ]; then
        OR_PREFIX=$(${bin} -V 2>&1 | tr ' ' '\n' | grep -m1 '^--prefix=' | cut -d= -f2)
    fi
    OR_PREFIX=${OR_PREFIX:-/usr/local/openresty/nginx}
    OR_NGINX_BIN="${OR_PREFIX}/sbin/nginx"
    [ -x "${OR_NGINX_BIN}" ] || OR_NGINX_BIN="$(command -v nginx 2>/dev/null || echo ${OR_PREFIX}/sbin/nginx)"
    OR_CONF_DIR="${OR_PREFIX}/conf"
    OR_MAIN_CONF="${OR_CONF_DIR}/nginx.conf"
    # 注意：nginx 的相对 include 是按「配置文件所在目录」解析的（实测），
    # 所以 drop-in 目录放在 nginx.conf 旁边，老版本写的 `include conf.d/*.conf;` 正好指到这里。
    OR_DROPIN_DIR="${OR_CONF_DIR}/conf.d"
    OR_DROPIN="${OR_DROPIN_DIR}/50-novnc.conf"
    OR_MAIN_BAK="${OR_MAIN_CONF}.vps-setup.bak"
}

# 主配置里是否已经有会加载到我们 drop-in 目录的 include
#   绝对路径直接用；相对路径按「配置文件所在目录」解析（nginx 实测行为），
#   同时顺带用 prefix 也试一次（兼容不同实现），比较前用 readlink -f 归一化
novnc_include_present() {
    local inc cand dir
    while IFS= read -r inc; do
        inc=$(printf '%s' "${inc}" | sed -E 's/^[[:space:]]*include[[:space:]]+//; s/;[[:space:]]*$//')
        [ -n "${inc}" ] || continue
        if [ "${inc#/}" != "${inc}" ]; then
            for cand in "${inc}"; do
                dir=$(dirname "${cand}")
                [ "$(readlink -f "${dir}" 2>/dev/null)" = "$(readlink -f "${OR_DROPIN_DIR}" 2>/dev/null)" ] && return 0
            done
        else
            for cand in "${OR_CONF_DIR}/${inc}" "${OR_PREFIX}/${inc}"; do
                dir=$(dirname "${cand}")
                [ "$(readlink -f "${dir}" 2>/dev/null)" = "$(readlink -f "${OR_DROPIN_DIR}" 2>/dev/null)" ] && return 0
            done
        fi
    done < <(grep -hE '^[[:space:]]*include[[:space:]]+' "${OR_MAIN_CONF}" 2>/dev/null)
    return 1
}

# 端口是否已被「别人的」server 块占用（我们自己的 drop-in 不算；备份文件不算）
#   注意：listen 可能和 server 写在同一行，也可能被注释掉 —— 先剥注释再匹配
novnc_port_taken() {
    local port="$1" f
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        [ "${f}" = "${OR_DROPIN}" ] && continue
        [ -f "${f}" ] || continue
        sed 's/#.*$//' "${f}" 2>/dev/null \
            | grep -qE "(^|[^0-9a-zA-Z_])listen[[:space:]]+(\[::\]:)?${port}([[:space:];]|$)" && return 0
    done < <(printf '%s\n' "${OR_MAIN_CONF}"; find "${OR_CONF_DIR}" -maxdepth 2 -name '*.conf' 2>/dev/null)
    return 1
}

# 端口选择：已装过就沿用 drop-in 里的端口；否则优先 443，被占则 8443/9443/10443
pick_novnc_port() {
    if [ -n "${NOVNC_PORT:-}" ]; then echo "${NOVNC_PORT}"; return; fi
    if [ -f "${OR_DROPIN}" ]; then
        local cur
        cur=$(grep -oE 'listen[[:space:]]+[0-9]+' "${OR_DROPIN}" 2>/dev/null | head -1 | grep -oE '[0-9]+')
        [ -n "${cur}" ] && { echo "${cur}"; return; }
    fi
    local cand
    for cand in 443 8443 9443 10443; do
        novnc_port_taken "${cand}" && continue
        echo "${cand}"; return
    done
    echo 8443
}

# 改主配置前只备份一次（同一次运行里回滚用同一份）
backup_main_conf() {
    [ -f "${OR_MAIN_BAK}" ] || cp -a "${OR_MAIN_CONF}" "${OR_MAIN_BAK}"
}

# 全新机器：没有 nginx.conf 时，写一份脚本自有的最小基底（noVNC 本体在 conf.d）
write_minimal_openresty_conf() {
    mkdir -p "${OR_CONF_DIR}" "${OR_DROPIN_DIR}"
    cat > "${OR_MAIN_CONF}" <<EOF
${VNC_CONFIG_MARK}
# 本文件由脚本生成的「最小基底」：只加载 mime.types 与 conf.d/*.conf。
# 你自己的 server / upstream 请放进 ${OR_DROPIN_DIR}/ 下的独立 .conf 文件，
# 本脚本以后重跑不会再覆盖它们。
user www-data;
worker_processes auto;
events { worker_connections 1024; }
http {
    include mime.types;
    default_type application/octet-stream;
    include ${OR_DROPIN_DIR}/*.conf;
}
EOF
}

# 已有 nginx.conf 但里面没有任何 conf.d include：在 http{} 开头补插 1 行（带标记）
add_novnc_include() {
    local f="${OR_MAIN_CONF}" tmp="${OR_MAIN_CONF}.vps-setup.new"
    backup_main_conf
    awk -v mark="    ${VNC_CONFIG_MARK} (增量插入：加载 conf.d 下的 noVNC 站点，删本行即可回收)" \
        -v inc="    include ${OR_DROPIN_DIR}/*.conf;" '
        { print }
        !done && $0 ~ /^[[:space:]]*http[[:space:]]*\{/ {
            print mark
            print inc
            done = 1
        }
    ' "${f}" > "${tmp}" && mv "${tmp}" "${f}"
    grep -qF "${OR_DROPIN_DIR}/*.conf" "${f}" 2>/dev/null
}

# 老版本把 noVNC 的 server 块内联写在 nginx.conf 里：按花括号配对把它整块摘掉
# （只摘含我们签名 rewrite 的那一块，其它 server 块原样保留）
strip_legacy_novnc_block() {
    local f="${OR_MAIN_CONF}" tmp="${OR_MAIN_CONF}.vps-setup.new"
    grep -qE '^[[:space:]]*server[[:space:]]*\{' "${f}" 2>/dev/null || return 1
    backup_main_conf
    awk -v sig="rewrite ^/vnc(" '
        !inblk && /^[[:space:]]*server[[:space:]]*\{/ { inblk=1; depth=0; buf=""; drop=0 }
        inblk {
            buf = buf $0 "\n"
            s=$0; o=gsub(/\{/, "&", s); s=$0; c=gsub(/\}/, "&", s)
            depth += o - c
            if (depth <= 0) {
                inblk=0
                if (index(buf, sig) == 0) printf "%s", buf
            }
            next
        }
        { print }
    ' "${f}" > "${tmp}" && mv "${tmp}" "${f}"
    grep -qF 'rewrite ^/vnc(' "${f}" 2>/dev/null && return 1
    return 0
}

# 写 noVNC 站点本体（脚本自有的 drop-in 文件，可反复覆盖）
write_novnc_dropin() {
    local port="$1" i ws="" whep="" newvn=""
    for ((i=1; i<=3; i++)); do
        ws+="    location /websockify/${i} {
        proxy_pass http://127.0.0.1:$((6080+i))/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"Upgrade\";
        proxy_set_header Host \$host;
        proxy_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
"
    done
    # 桌面音频：WHEP 信令反代到本机（与 vnc.html 同源，免 CORS / 免混合内容）
    # 有 vnc-audio-rtc 就直发（媒体走 UDP ${AUDIO_RTC_ICE_PORT}），没有则回退 MediaMTX（UDP ${AUDIO_UDP_PORT}）
    whep="    # 桌面音频：WebRTC(WHEP) 信令 → 本机（vnc-audio-rtc 直发 / MediaMTX 回退）
    location = /whep {
        proxy_pass http://${AUDIO_WHEP_PROXY};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        client_max_body_size 1m;
    }

    # 桌面视频（WebRTC/WHEP）：/live 页面看画面；只播，不接管键鼠。
    # 与 /whep（音频）各自一条流，互不影响；媒体同样走宿主机转发进来的 UDP。
    location = /whep-av {
        proxy_pass http://127.0.0.1:${AUDIO_WHEP_PORT}/${VIDEO_PATH}/whep;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        client_max_body_size 1m;
    }

    location = /live {
        alias ${VIDEO_WEB_ROOT}/index.html;
        default_type text/html;
        add_header Cache-Control \"no-cache\";
    }

"
    # noVNC 自己的第二块屏：复用或撑开扩展桌面 / 两个运行时 clip。
    # 控制器只监听 127.0.0.1:6090，这里反代成 /second/api/。
    secondapi="    # noVNC 第二块屏控制器（screen2ctl，只监听 127.0.0.1:6090）
    location /second/api/ {
        proxy_pass http://127.0.0.1:6090/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_read_timeout 15s;
        proxy_send_timeout 15s;
        client_max_body_size 4k;
    }

"
    # 第二套 noVNC（官方最新版）→ /new_vnc：只有该目录真的存在时才生成，
    # 否则本段为空（对 1.3.0 的 / 站点零影响）。目录由 scripts/novnc_new_deploy.sh 部署。
    if [ -d "${NOVNC_NEW_WEB_ROOT}" ]; then
        newvn="    # ---- 第二套 noVNC（官方 ${NOVNC_NEW_VERSION}）: /new_vnc ----
    location /new_vnc/ {
        alias ${NOVNC_NEW_WEB_ROOT}/;
        index vnc.html;
        add_header Cache-Control \"no-cache\";
    }
    location = /new_vnc {
        return 302 /new_vnc/vnc.html?path=/websockify/1&autoconnect=true&reconnect=true;
    }
"
        for ((i=1; i<=3; i++)); do
            newvn+="    location /new_vnc/websockify/${i} {
        proxy_pass http://127.0.0.1:$((6080+i))/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"Upgrade\";
        proxy_set_header Host \$host;
        proxy_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
"
        done
    fi
    # ---- Selkies（/selkies）：独立服务 + 独立 WebSocket 传输；没装就生成空串 ----
    selk=""
    if [ -x "${SELKIES_BIN}" ]; then
        selk="    # ---- Selkies（WebSocket 传输）: ${SELKIES_SUBFOLDER} ----
    # 与 noVNC/x11vnc 各自独立；媒体走普通 WebSocket，不需要额外 UDP 转发

    location = ${SELKIES_SUBFOLDER} {
        return 301 ${SELKIES_SUBFOLDER}/;
    }
    location ${SELKIES_SUBFOLDER}/ {
        proxy_pass http://127.0.0.1:${SELKIES_HTTP_PORT};
        proxy_set_header Accept-Encoding "";
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"Upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        client_max_body_size 512m;
    }

"
    fi
    mkdir -p "${OR_DROPIN_DIR}"
    [ -f "${OR_DROPIN}" ] && cp -a "${OR_DROPIN}" "${OR_DROPIN}.vps-setup.bak"
    cat > "${OR_DROPIN}" <<EOF
${VNC_CONFIG_MARK}
# 本文件完全由脚本管理：升级/重跑只会覆盖本文件，不会动你的 nginx.conf，
# 也不会动 conf.d 下其它 *.conf 文件。
# 卸载 noVNC 站点：删掉本文件（+ 主配置里带同样标记的 include 行）后重载 openresty 即可。
server {
    listen ${port} ssl;
    server_name _;
    ssl_certificate ${SSL_CRT};
    ssl_certificate_key ${SSL_KEY};

    # /vnc1 /vnc2 /vnc3 → 三个 websockify 后端；/view 为只读入口
    # 第二块屏必须 shared=1：否则 x11vnc 收到 shared=0 会把主视图那条连接踢掉
    rewrite ^/vnc2/?\$ /vnc.html?path=websockify/2&autoconnect=true&reconnect=true&shared=1 redirect;
    rewrite ^/vnc([0-9]+)/?\$ /vnc.html?path=websockify/\$1&autoconnect=true&reconnect=true redirect;
    rewrite ^/view/?\$ /vnc.html?path=websockify/3&view_only=true&autoconnect=true redirect;

    location / {
        root ${NOVNC_WEB_ROOT};
        index vnc.html;
        try_files \$uri \$uri/ =404;
        add_header Cache-Control "no-cache";
    }

${secondapi}${newvn}${whep}${selk}${ws}}
EOF
}

# 校验 + 加载；nginx -t 不通过就回滚本次写入，绝不让原有服务起不来
reload_openresty_safe() {
    local out
    out=$("${OR_NGINX_BIN}" -t 2>&1)
    if [ $? -ne 0 ]; then
        echo "❌ nginx 配置校验未通过，已回滚本次改动（你的原配置/原服务不受影响）："
        printf '%s\n' "${out}" | sed 's/^/    /'
        if [ -f "${OR_DROPIN}.vps-setup.bak" ]; then
            mv -f "${OR_DROPIN}.vps-setup.bak" "${OR_DROPIN}"
        else
            rm -f "${OR_DROPIN}"
        fi
        if [ "${OR_MAIN_CHANGED:-0}" = "1" ] && [ -f "${OR_MAIN_BAK}" ]; then
            mv -f "${OR_MAIN_BAK}" "${OR_MAIN_CONF}"
            echo "    已恢复主配置：${OR_MAIN_CONF}"
        fi
        return 1
    fi
    rm -f "${OR_DROPIN}.vps-setup.bak"
    if systemctl is-active --quiet openresty 2>/dev/null; then
        "${OR_NGINX_BIN}" -s reload 2>/dev/null || systemctl restart openresty
        echo "✅ openresty 已 reload（现有连接不中断）"
    else
        systemctl start openresty >/dev/null 2>&1 || true
        echo "✅ openresty 已启动"
    fi
    return 0
}

# noVNC 自己的第二块屏：
#   Selkies 已经扩了就直接复用（只上 clip）；没人扩就自己撑成 3840x1080
#   （第二块在左 0,0 / 主屏在右 1920,0），再用 x11vnc 的运行时 clip 把两块
#   分别喂给 :5901（主 noVNC）和 :5902（第二台 noVNC，/vnc2），都是 1:1。
# 依赖：Xvfb 按 4K 分配（scripts/selkies_trial.sh 装的 50-second-screen.conf）。
install_second_screen_control() {
    echo "--- noVNC 第二块屏（/vnc2 + /second/api/）---"

    install -m 0755 /dev/stdin /usr/local/bin/screen2ctl <<'SCREEN2CTL'
#!/usr/bin/env python3
"""screen2ctl —— noVNC 的第二块屏（主视图在右，第二块在左）。

VNC 服务端有两种后端（看 /etc/vnc-ws/backend）：

  - tigervnc：改几何文件 + 重启 x0vnc-ws / x0vnc-ws-second（切屏时主视图重连约 2 秒）
  - x11vnc ：运行时 `-R clip:`（无缝，但没有 ContinuousUpdates）

两种来源，优先复用：

  1) Selkies 已经把桌面扩开了（root 里有 selkies-primary / selkies-display2）
     → 直接拿来用：只给两个 x11vnc 上 clip + 起 x11vnc-screen2，
       不改 root、不改监视器、不动别人的东西。收起时也只清 clip。

  2) 没有人扩 → 自己扩成 3840x1080（第二块在左 0,0，主屏在右 1920,0）：
     - dualscreen-mode.service（xvfb-mode-hold 3840x1080）把 root 撑起来
     - --setmonitor 建 selkies-primary(1920,0) / selkies-display2(0,0)
     - desktop-layout-shift 把窗口搬到主屏；lxpanel 按自己的配置贴到 x=1920
     收起时按相反顺序还原（先把模式切回 1920x1080，再停 holder）。

HTTP 只在 127.0.0.1:6090，nginx 反代成 /second/api/：

    GET  /state   机器真实状态 + 控制器状态
    POST /open    确保扩展、上 clip、起第二块屏
    POST /close   收起（自己扩的才缩回去）
    POST /ping    心跳；30 秒没心跳自动收摊
"""

import json
import os
import re
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

DISPLAY = ":1"
PW, PH = 1920, 1080
BIG_MODE = "%dx%d" % (3840, PH)          # 两块并排：左 0,0 / 右 1920,0
SMALL_MODE = "%dx%d" % (PW, PH)

SECOND_PORT = 5902
SECOND_UNIT = "x11vnc-screen2.service"
SECOND_REMOTE = "X11VNC_REMOTE_SCREEN2"
MODE_UNIT = "dualscreen-mode.service"

IDLE_TIMEOUT = 30.0
LISTEN = ("127.0.0.1", 6090)

_lock = threading.Lock()
_state = {
    "open": False,
    "last_ping": 0.0,
}


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


# ------------------------------------------------------------------ X 查询

def run(cmd, prop=None, timeout=20):
    env = {k: v for k, v in os.environ.items() if k != "X11VNC_REMOTE"}
    env["DISPLAY"] = DISPLAY
    if prop:
        env["X11VNC_REMOTE"] = prop
    t0 = time.time()
    try:
        r = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
        return r, time.time() - t0
    except Exception as e:  # noqa: BLE001
        return subprocess.CompletedProcess(cmd, 1, "", str(e)), time.time() - t0


def xrandr_text():
    return run(["xrandr"])[0].stdout


def output_name():
    for line in xrandr_text().splitlines():
        m = re.match(r"^(\S+) connected", line)
        if m:
            return m.group(1)
    return "screen"


def current_mode():
    m = re.search(r"current (\d+) x (\d+)", xrandr_text())
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def monitors():
    """--setmonitor 明确建的那些（跳过 xrandr 自动生成的 +output 条目）。"""
    out = []
    for line in run(["xrandr", "--listmonitors"])[0].stdout.splitlines():
        m = re.match(
            r"\s*\d+:\s+([*+]*)(\S+)\s+(\d+)/\d+x(\d+)/\d+\+(-?\d+)\+(-?\d+)", line)
        if not m:
            continue
        marks, name, w, h, x, y = m.groups()
        if "+" in marks:
            continue
        out.append({"name": name, "primary": "*" in marks,
                    "x": int(x), "y": int(y), "w": int(w), "h": int(h)})
    return out


def pick_rects():
    """(主屏 rect, 第二块屏 rect)，按监视器名字/主标记挑。"""
    mons = monitors()
    if len(mons) < 2:
        return None, None
    primary = None
    for m in mons:
        if m["name"].endswith("primary") or m["primary"]:
            primary = m
    if primary is None:
        primary = mons[0]
    secondary = next((m for m in mons if m is not primary), None)
    return primary, secondary


def direction_of(primary, secondary):
    if not primary or not secondary:
        return None
    if primary["x"] > secondary["x"]:
        return "left"
    if primary["y"] > secondary["y"]:
        return "up"
    if secondary["x"] > primary["x"]:
        return "right"
    if secondary["y"] > primary["y"]:
        return "down"
    return None


def unit_active(unit):
    r, _ = run(["systemctl", "is-active", "--quiet", unit], timeout=5)
    return r.returncode == 0


def machine_state():
    mode = current_mode()
    primary, secondary = pick_rects()
    extended = bool(primary and secondary and (mode[0] > PW or mode[1] > PH))

    source = None
    if unit_active(MODE_UNIT):
        source = "novnc"          # 这个扩展是 noVNC 自己撑起来的
    elif monitors() and all(m["name"].startswith("selkies-") for m in monitors()):
        source = "selkies"

    def rect(m):
        return None if m is None else {k: m[k] for k in ("x", "y", "w", "h")}

    return {
        "extended": extended,
        "source": source,
        "direction": direction_of(primary, secondary) if extended else None,
        "mode": list(mode),
        "primary": rect(primary) if extended else None,
        "secondary": rect(secondary) if extended else None,
    }


def set_mode(mode):
    r, _ = run(["xrandr", "--output", output_name(), "--mode", mode])
    if r.returncode != 0:
        log("set_mode %s failed: %s" % (mode, (r.stderr or r.stdout).strip()))
    return r.returncode == 0


# ------------------------------------------------------------------ 监视器 / 窗口

def set_monitors(primary, secondary, tries=6):
    # 同名 monitor 不能原地改坐标（BadValue），必须先删再建。
    # root 刚变大的那一瞬间 X 那边可能还没完全切过去，setmonitor 会 BadValue，
    # 所以这里重试几次并核对结果。
    fmt = "%d/508x%d/286" % (PW, PH)
    for i in range(tries):
        clear_monitors()
        r1, _ = run(["xrandr", "--setmonitor", "selkies-primary",
                     "%s+%d+%d" % (fmt, primary[0], primary[1]), "none"])
        r2, _ = run(["xrandr", "--setmonitor", "selkies-display2",
                     "%s+%d+%d" % (fmt, secondary[0], secondary[1]), "none"])
        if r1.returncode == 0 and r2.returncode == 0 and len(monitors()) >= 2:
            return True
        log("set_monitors 第 %d 次失败: %s | %s"
            % (i + 1, (r1.stderr or r1.stdout).strip(), (r2.stderr or r2.stdout).strip()))
        time.sleep(0.3)
    return False


def clear_monitors():
    run(["xrandr", "--delmonitor", "selkies-primary"])
    run(["xrandr", "--delmonitor", "selkies-display2"])


def restore_small():
    """自己扩失败时把桌面收回单屏（顺序：先删监视器/切模式，再停 holder）。"""
    clear_monitors()
    view_set("main", (0, 0, PW, PH))
    set_mode(SMALL_MODE)
    view_clear("main")
    stop_mode_unit()


def place_desktop(primary):
    """把 pcmanfm 的桌面窗挪到主屏。

    LXDE 的桌面图标是 pcmanfm 那个铺满 root 的窗画的；root 一变大，它就
    铺满 3840，图标留在最左边（第二块屏），主屏看着像「没有桌面」。
    挪到主屏 x 之后图标就跟着回主屏；缩回单屏时 pcmanfm 会自己重新铺满，
    不用管。
    """
    if not primary or (primary["x"] == 0 and primary["y"] == 0):
        return
    root_w, root_h = current_mode()
    for wid in run(["xdotool", "search", "--class", "pcmanfm"])[0].stdout.split():
        if not wid.isdigit():
            continue
        g = run(["xdotool", "getwindowgeometry", "--shell", wid])[0].stdout
        mw = re.search(r"WIDTH=(\d+)", g)
        mh = re.search(r"HEIGHT=(\d+)", g)
        if not mw or not mh:
            continue
        if int(mw.group(1)) >= root_w - 10 and int(mh.group(1)) >= root_h - 40:
            run(["xdotool", "windowmove", "--sync", wid,
                 str(primary["x"]), str(primary["y"])])
            log("desktop -> %d,%d" % (primary["x"], primary["y"]))


def shift_once():
    r, _ = run(["/usr/local/bin/desktop-layout-shift", "--once"], timeout=20)
    if r.stdout.strip():
        log(r.stdout.strip().replace("\n", " | "))


# ------------------------------------------------------------------ x11vnc clip

_last_clip = {}


def query_clip(prop, timeout=3):
    r, _ = run(["x11vnc", "-query", "clip"], prop=prop, timeout=timeout)
    m = re.search(r"ans=clip:(\S*)", r.stdout + r.stderr)
    return m.group(1) if m else None


def _send(prop, cmd):
    """发一条 -R，并按「服务端是否忙」决定返回前要不要等一拍。

    x11vnc 的远端命令走同一个 X property：上一条还没被读走时再发下一条
    会把它冲掉。换 clip 会重建 framebuffer，这期间 -R 会等上好几秒；
    这时候必须让服务端先把这个命令消费完，否则紧接着的 query 会顶掉它。
    """
    now = time.monotonic()
    wait = 0.6 - (now - _last_clip.get(prop, 0))
    if wait > 0:
        time.sleep(wait)
    r, dt = run(["x11vnc", "-R", cmd], prop=prop, timeout=20)
    _last_clip[prop] = time.monotonic()
    log("x11vnc[%s] %s (%.2fs)" % (prop or "main", cmd, dt))
    time.sleep(1.4 if dt > 0.6 else 0.15)
    return r.returncode == 0


def set_clip(prop, x, y, w=PW, h=PH):
    want = "%dx%d+%d+%d" % (w, h, x, y)
    _send(prop, "clip:" + want)
    return want


def clear_clip(prop):
    _send(prop, "clip:")


def verify_clip(prop, want, tries=3):
    for _ in range(tries):
        time.sleep(0.8)
        got = query_clip(prop)
        if got is None:
            continue
        if got == want:
            return True
        log("clip[%s] 期望 %s，实际 %s，补发" % (prop or "main", want, got or "(空)"))
        _send(prop, "clip:" + want)
    return False


# ------------------------------------------------------------------ 视图几何（WS 通道两种后端）

WS_BACKEND_FILE = "/etc/vnc-ws/backend"
WS_GEOM = {"main": "/etc/vnc-ws/main-geometry",
           "second": "/etc/vnc-ws/second-geometry"}
WS_UNIT = {"main": "x0vnc-ws.service",
           "second": "x0vnc-ws-second.service"}


def ws_tigervnc():
    try:
        with open(WS_BACKEND_FILE) as f:
            return f.read().strip() == "tigervnc"
    except OSError:
        return False


def read_file(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def geom_str(rect):
    return "%dx%d+%d+%d" % (rect[2], rect[3], rect[0], rect[1])


def view_set(which, rect):
    """把某个视图钉到 rect。

    x11vnc：运行时 `-R clip:`，无缝。
    TigerVNC：写几何文件并重启对应 unit（几何只能在启动时定）。
    """
    want = geom_str(rect)
    if not ws_tigervnc():
        return set_clip(None if which == "main" else SECOND_REMOTE, *rect)
    path = WS_GEOM[which]
    if read_file(path) == want:
        return want
    try:
        with open(path, "w") as f:
            f.write(want + "\n")
    except OSError as e:
        log("几何写入失败 %s: %s" % (path, e))
        return want
    run(["systemctl", "restart", WS_UNIT[which]], timeout=40)
    log("%s 视图几何 -> %s（%s 已重启）" % (which, want, WS_UNIT[which]))
    return want


def view_clear(which):
    if not ws_tigervnc():
        clear_clip(None if which == "main" else SECOND_REMOTE)
        return
    w, h = root_geometry() or (PW, PH)
    view_set(which, (0, 0, w, h))


def view_verify(which, want):
    if ws_tigervnc():
        return read_file(WS_GEOM[which]) == want
    return verify_clip(None if which == "main" else SECOND_REMOTE, want)


RTC_GEOM = "/etc/vnc-rtc/x0vnc-geometry"
RTC_UNIT = "x0vnc-main.service"


def root_geometry():
    """当前 root 分辨率（xrandr 的 current W x H）。"""
    out = run(["xrandr", "--current"])[0].stdout or ""
    m = re.search(r"current (\d+) x (\d+)", out)
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
            f.write(geom + "\n")
    except OSError as e:
        log("RTC 几何写入失败: %s" % e)
        return
    if run(["systemctl", "cat", RTC_UNIT], timeout=5)[0].returncode != 0:
        return
    run(["systemctl", "restart", RTC_UNIT], timeout=40)
    log("RTC 视图几何 -> %s" % geom)


# ------------------------------------------------------------------ 服务

def port_open(port, timeout=0.3):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


def start_second(rect=None):
    if port_open(SECOND_PORT):
        return True
    if ws_tigervnc():
        if rect:
            try:
                with open(WS_GEOM["second"], "w") as f:
                    f.write(geom_str(rect) + "\n")
            except OSError as e:
                log("第二块屏几何写入失败: %s" % e)
        unit = WS_UNIT["second"]
    else:
        unit = SECOND_UNIT
    run(["systemctl", "start", unit], timeout=20)
    for _ in range(40):
        if port_open(SECOND_PORT):
            return True
        time.sleep(0.1)
    return False


def stop_second():
    unit = WS_UNIT["second"] if ws_tigervnc() else SECOND_UNIT
    run(["systemctl", "stop", unit], timeout=20)


def start_mode_unit():
    if unit_active(MODE_UNIT) and current_mode() == (3840, PH):
        return True
    run(["systemctl", "start", MODE_UNIT], timeout=25)
    for _ in range(60):
        if current_mode() == (3840, PH):
            return True
        time.sleep(0.1)
    return False


def stop_mode_unit():
    run(["systemctl", "stop", MODE_UNIT], timeout=20)


# ------------------------------------------------------------------ 打开 / 收起

def is_open():
    """第二块屏是否真的开着：以 5902 是否在监听为准（重启控制器也不会看错）。"""
    return _state["open"] or port_open(SECOND_PORT)


def open_second():
    with _lock:
        if is_open():
            _state.update(open=True, last_ping=time.time())
            return {"ok": True, "reused": True}

        mode = current_mode()
        own = False

        # 先把主视图钉在 0,0：root 变大时主 noVNC 的画布尺寸不会跟着变
        if mode == (PW, PH):
            view_set("main", (0, 0, PW, PH))
            view_verify("main", "%dx%d+0+0" % (PW, PH))
            if not start_mode_unit():
                restore_small()
                return {"ok": False, "error": "无法切到 %s（dualscreen-mode 没起来）" % BIG_MODE}
            own = True
            # root 变大之后才建监视器：主屏放右边 1920,0，第二块放左边 0,0
            if not set_monitors((PW, 0), (0, 0)):
                restore_small()
                return {"ok": False, "error": "建立两块监视器失败"}

        primary, secondary = pick_rects()
        if not primary or not secondary:
            if own:
                restore_small()
            return {"ok": False, "error": "没有两块监视器，扩展没建起来"}

        if not start_second((secondary["x"], secondary["y"],
                             secondary["w"], secondary["h"])):
            if own:
                restore_small()
            return {"ok": False, "error": "第二块屏服务没起来"}

        # 先搬窗口/桌面，再重启抓屏服务。
        # TigerVNC 的裁剪几何只能在启动时定；如果先重启再搬，新进程抓到的是
        # “搬之前”的画面，之后只要漏掉一块 damage，主屏就会留下黑块/错位
        # （表现就是“花”）。x11vnc 是运行时 clip，顺序无所谓，这里统一按安全顺序。
        shift_once()
        place_desktop(primary)
        time.sleep(0.3)          # 让 openbox/pcmanfm 把重绘做完再抓第一帧
        want_main = view_set("main", (primary["x"], primary["y"],
                                      primary["w"], primary["h"]))
        want_second = view_set("second", (secondary["x"], secondary["y"],
                                          secondary["w"], secondary["h"]))
        view_verify("main", want_main)
        view_verify("second", want_second)
        retarget_rtc(primary)

        _state.update(open=True, last_ping=time.time(),
                      rects=((primary["x"], primary["y"], primary["w"], primary["h"]),
                             (secondary["x"], secondary["y"], secondary["w"], secondary["h"])))
        _state["layout_bad"] = 0
        log("open primary=(%d,%d) secondary=(%d,%d) own=%s"
            % (primary["x"], primary["y"], secondary["x"], secondary["y"], own))
        return {"ok": True, "own": own}


def close_second(reason="request"):
    with _lock:
        if not is_open():
            _state.update(open=False, last_ping=0.0)
            return {"ok": True, "open": False}
        was_open = True
        own = unit_active(MODE_UNIT)

        stop_second()
        if not ws_tigervnc():
            clear_clip(SECOND_REMOTE)

        if own:
            # 自己扩的：按相反顺序缩回去
            clear_monitors()
            shift_once()                     # 内容先搬回 0,0
            view_set("main", (0, 0, PW, PH)) # 主视图仍钉在 0,0（画布尺寸不变）
            set_mode(SMALL_MODE)             # 1920x1080 由 xvfb-mode@1 一直握着
            view_clear("main")               # root 已经是 1080p
            stop_mode_unit()
        else:
            # 别人（Selkies）扩的：只还回几何，别的都不动
            view_clear("main")

        retarget_rtc(None)
        _state.update(open=False, last_ping=0.0)
    log("close (%s) own=%s" % (reason, own))
    return {"ok": True, "open": False, "was_open": was_open}


def state():
    s = machine_state()
    s.update(open=is_open(), screen2=port_open(SECOND_PORT),
             own=unit_active(MODE_UNIT))
    return s


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _reply(self, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _route(self):
        path = (urlparse(self.path).path or "/").rstrip("/") or "/"
        if path in ("/state", "/status"):
            self._reply(state())
        elif path == "/open":
            self._reply(open_second())
        elif path == "/close":
            self._reply(close_second("http"))
        elif path == "/ping":
            _state["last_ping"] = time.time()
            self._reply({"ok": True})
        else:
            self._reply({"ok": False, "error": "not found"})

    def do_GET(self):
        self._route()

    def do_POST(self):
        self._route()


def watchdog():
    while True:
        time.sleep(2)
        if not is_open():
            continue

        # 布局被别的程序改了（最典型：Selkies 关掉它自己的第二块屏，
        # root 缩回 1080p）—— 这时我们的 clip 已经越界，赶紧收摊。
        primary, secondary = pick_rects()
        now = None
        if primary and secondary:
            now = ((primary["x"], primary["y"], primary["w"], primary["h"]),
                   (secondary["x"], secondary["y"], secondary["w"], secondary["h"]))
        if now != _state.get("rects"):
            # 刚扩/刚收那一拍 xrandr 可能还没稳定；连续两次不一致才收，
            # 避免刚打开就被自己收掉（实测偶发一次）。
            _state["layout_bad"] = _state.get("layout_bad", 0) + 1
            if _state["layout_bad"] >= 2:
                try:
                    close_second("layout changed")
                except Exception as e:  # noqa: BLE001
                    log("watchdog close failed: %s" % e)
            continue
        _state["layout_bad"] = 0

        if time.time() - _state["last_ping"] > IDLE_TIMEOUT:
            try:
                close_second("idle timeout")
            except Exception as e:  # noqa: BLE001
                log("watchdog close failed: %s" % e)


def main():
    if port_open(SECOND_PORT):
        # 控制器被重启过、但第二块还在跑：接着管，别当成新开的
        _state.update(open=True, last_ping=time.time())
        primary, secondary = pick_rects()
        if primary and secondary:
            _state["rects"] = ((primary["x"], primary["y"], primary["w"], primary["h"]),
                               (secondary["x"], secondary["y"], secondary["w"], secondary["h"]))
        log("接管已经开着的第二块屏")
    log("listening on %s:%d" % LISTEN)
    threading.Thread(target=watchdog, daemon=True).start()
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()


if __name__ == "__main__":
    main()
SCREEN2CTL

    cat > /etc/systemd/system/x11vnc-screen2.service <<'UNIT'
[Unit]
Description=x11vnc second-screen server on :1 (clip applied at runtime by screen2ctl)
After=xvfb@1.service vnc-desktop@1.service
Requires=xvfb@1.service
BindsTo=xvfb@1.service

[Service]
Type=simple
User=vncuser1
Group=vncuser1
Environment=DISPLAY=:1
# 独立通信通道：主实例用默认 X11VNC_REMOTE，第二块屏用这个，
# 这样 -R clip:... 不会同时改到主实例。
Environment=X11VNC_REMOTE=X11VNC_REMOTE_SCREEN2
ExecStartPre=/bin/sh -c 'TIMEOUT=50; while [ ! -S /tmp/.X11-unix/X1 ]; do sleep 0.2; TIMEOUT=$((TIMEOUT-1)); if [ $TIMEOUT -le 0 ]; then exit 1; fi; done'
# 注意：不要在这里加 -clip。x11vnc 0.9.16 只在启动时没带 -clip 的情况下
# 才接受运行时的 `-R clip:WxH+X+Y`；方向切换靠的就是这个。
ExecStart=/usr/bin/x11vnc -display :1 -rfbport 5902 -forever -shared -rfbauth /home/vncuser1/.vnc/passwd -defer 20 -wait 20 -nowireframe
Restart=always
RestartSec=3
TimeoutStopSec=3
# x11vnc 收到 SIGTERM 会退 2，别让 systemd 记成 failed
SuccessExitStatus=2 143
OOMScoreAdjust=-800

[Install]
WantedBy=multi-user.target
UNIT

    cat > /etc/systemd/system/screen2ctl.service <<'UNIT'
[Unit]
Description=noVNC second-screen controller (extend root + per-view clips)
After=xvfb@1.service x11vnc@1.service

[Service]
Type=simple
Environment=DISPLAY=:1
ExecStart=/usr/local/bin/screen2ctl
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

    cat > /etc/systemd/system/dualscreen-mode.service <<'UNIT'
[Unit]
Description=Hold the extended 3840x1080 framebuffer for the noVNC second screen
After=xvfb@1.service
BindsTo=xvfb@1.service

[Service]
Type=simple
Environment=DISPLAY=:1
ExecStart=/usr/local/bin/xvfb-mode-hold 3840x1080
Restart=no
TimeoutStartSec=20
OOMScoreAdjust=-800
UNIT

    systemctl daemon-reload
    # x11vnc-screen2 不 enable：只在打开第二块屏时由 screen2ctl 按需拉起
    if [ "${WS_BRIDGE_KIND}" = "single" ]; then
        # 单进程网关已经常驻监听 6082，这里只启控制器
        systemctl enable screen2ctl.service >/dev/null 2>&1 || true
        systemctl start screen2ctl.service >/dev/null 2>&1 || true
    else
        systemctl enable screen2ctl.service websockify@2.service >/dev/null 2>&1 || true
        systemctl start screen2ctl.service websockify@2.service >/dev/null 2>&1 || true
    fi

    if [ -f /etc/systemd/system/xvfb@.service.d/50-second-screen.conf ]; then
        echo "✅ 第二块屏：/vnc2（noVNC 1.5）、/new_vnc/vnc.html?path=/websockify/2（1.7）"
    else
        echo "⚠️ 没有 4K framebuffer 的 drop-in：第二块屏会报「framebuffer 上限不足 4K」"
        echo "   先跑 scripts/selkies_trial.sh（second_screen_on 会加那份 drop-in）"
    fi
}

install_novnc_and_openresty() {
    echo "--- 配置 HTTPS 和 noVNC（增量式：只加 conf.d 文件，不覆盖你已有的 nginx.conf）---"
    # 这几个包 [1] 已装；单独跑本步时才补装（不会重复 apt update）
    ensure_pkgs haveged gnupg2 ca-certificates lsb-release

    mkdir -p /usr/share/keyrings
    wget -qO - https://openresty.org/package/pubkey.gpg | gpg --dearmor --yes -o /usr/share/keyrings/openresty.gpg
    echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian $(lsb_release -sc) openresty" | tee /etc/apt/sources.list.d/openresty.list
    apt update; apt install -y --no-install-recommends openresty novnc websockify

    mkdir -p ${SSL_CERT_DIR}
    if [ ! -f "${SSL_CRT}" ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout ${SSL_KEY} -out ${SSL_CRT} -subj "/C=CN/ST=Shanghai/O=VNC/CN=vnc-web"
        chmod 644 ${SSL_CRT}; chmod 600 ${SSL_KEY}
    fi

    detect_openresty_paths
    mkdir -p "${OR_PREFIX}/logs" /var/log/nginx/ "${OR_DROPIN_DIR}"
    chown -R www-data:www-data "${OR_PREFIX}/logs" /var/log/nginx/ 2>/dev/null || true

    patch_novnc_utf8_clipboard
    patch_novnc_expose_ui
    # HiDPI：Scaling mode=无 时 1 帧像素 = 1 物理像素（同样会被 novnc 包升级覆盖，每次重打）
    patch_novnc_hidpi
    # 桌面真实声音的页面补丁（novnc 包升级会覆盖 vnc.html，所以每次跑本步都重打一遍）
    patch_novnc_desktop_audio
    patch_novnc_second_screen
    install_dualscreen_status

    OR_MAIN_CHANGED=0
    rm -f "${OR_MAIN_BAK}"          # 每次运行都用当次状态做回滚备份

    if [ ! -f "${OR_MAIN_CONF}" ]; then
        write_minimal_openresty_conf
        OR_MAIN_CHANGED=1
        echo "ℹ️ 之前没有 nginx.conf，已生成最小基底：${OR_MAIN_CONF}"
    else
        # 1) 老版本内联的 noVNC server 块 → 摘到 conf.d 去（否则会和 drop-in 抢端口）
        if grep -qF 'rewrite ^/vnc(' "${OR_MAIN_CONF}" 2>/dev/null; then
            if strip_legacy_novnc_block; then
                OR_MAIN_CHANGED=1
                echo "ℹ️ 检测到旧版内联 noVNC server 块，已摘出为独立文件（备份：${OR_MAIN_BAK}）"
            else
                echo "⚠️ 尝试摘出旧版内联 noVNC 块失败，已放弃改动主配置。"
            fi
        fi
        # 2) 确保主配置会加载 conf.d（已在则一个字都不改）
        if novnc_include_present; then
            echo "ℹ️ 你的 nginx.conf 已加载 conf.d —— 主配置不做任何改动"
        elif add_novnc_include; then
            OR_MAIN_CHANGED=1
            echo "ℹ️ 你的 nginx.conf 没有 conf.d include，已增量补插 1 行（备份：${OR_MAIN_BAK}）"
        else
            echo "⚠️ 你的 nginx.conf 里没找到 http { 块，无法自动补 include，已放弃改动。"
            echo "   请手工在 http {} 内加一行：include ${OR_DROPIN_DIR}/*.conf;"
            return 1
        fi
    fi

    # 3) noVNC 站点本体（我们自己的文件）
    local port; port=$(pick_novnc_port)
    write_novnc_dropin "${port}"

    # 4) 校验通过才加载，失败自动回滚
    reload_openresty_safe || return 1
    systemctl enable openresty >/dev/null 2>&1 || true

    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}'); ip=${ip:-<服务器IP>}
    local port_tag=""
    [ "${port}" != "443" ] && port_tag=":${port}"
    echo "✅ noVNC 站点已就绪：${OR_DROPIN}（listen ${port} ssl）"
    echo "   访问地址：https://${ip}${port_tag}/vnc1   只读：https://${ip}${port_tag}/view"
    [ "${port}" != "443" ] && echo "   ⚠️ 443 已被你其它 server 块占用，noVNC 改用 ${port}；记得在防火墙/端口转发里放行 ${port}"
    echo "   自签证书首次访问需点一次「继续访问」。"
    command -v curl >/dev/null 2>&1 && {
        local code
        code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${port}/vnc.html" 2>/dev/null)
        case "${code}" in
            200|30*) echo "   自检：本地 https://127.0.0.1:${port}/vnc.html → HTTP ${code} ✅" ;;
            *)       echo "   自检：本地 https://127.0.0.1:${port}/vnc.html → HTTP ${code:-无响应} ⚠️（可看 journalctl -u openresty）" ;;
        esac
    }
}

patch_novnc_hidpi() {
    echo "--- 配置 noVNC HiDPI 补丁（Scaling mode=无 时 1 帧像素 = 1 物理像素）---"
    local rfb_js="${NOVNC_WEB_ROOT}/core/rfb.js"

    if [ ! -f "$rfb_js" ]; then
        echo "  ⚠️ 找不到 ${rfb_js}，跳过"
        return 0
    fi

    if grep -q "vps-setup: HiDPI" "$rfb_js" 2>/dev/null; then
        echo "  · 已是「1 帧像素 = 1 物理像素」（跳过）"
        return 0
    fi

    # 原版 _updateScale() 在「Scaling mode = None」时写死 display.scale = 1.0，
    # 于是画布 CSS 尺寸 = 帧尺寸；在 devicePixelRatio≠1 的屏上（例如 Windows 系统
    # 显示缩放 125%），浏览器还要把画布再放大 1.25 倍 → 重采样发虚。
    # 改成 1/DPR：画布 CSS 尺寸 = 帧尺寸/DPR，物理尺寸恰好等于帧尺寸，不再重采样。
    # 必须走 display.scale（即 _rescale()），它会同时更新 _scale —— 鼠标坐标就是靠
    # absX/absY 除以 _scale 换算的（core/rfb.js: pointerEvent(this._display.absX(x), ...)），
    # 所以改了缩放比例，鼠标位置依然准确。
    python3 - "$rfb_js" <<'PY' || true
import sys
p = sys.argv[1]
MARK = "            // vps-setup: HiDPI —— Mode=无 时按 1/devicePixelRatio 缩放"
tgt = ("        if (!this._scaleViewport) {\n"
       "            this._display.scale = 1.0;\n")
repl = (tgt + MARK + "\n"
        "            //   画布 CSS 尺寸 = 帧尺寸/DPR，物理尺寸 = 帧尺寸，不再被浏览器放大重采样。\n"
        "            //   display.scale 会走 _rescale() 并同步更新 _scale，鼠标坐标换算不受影响。\n"
        "            this._display.scale = 1.0 / (window.devicePixelRatio || 1);\n")
s = open(p, encoding="utf-8").read()
if s.count(tgt) == 1:
    open(p, "w", encoding="utf-8").write(s.replace(tgt, repl, 1))
    print("  · HiDPI：Mode=无 时按 1/DPR 缩放（1 帧像素 = 1 物理像素）")
else:
    print("  · HiDPI：⚠️ _updateScale() 里的期望片段匹配数≠1，未改动")
PY

    if command -v node >/dev/null 2>&1; then
        # 注意：1.3.0 的 core/rfb.js 是 ES module（有 import），而它的目录里没有
        # package.json 声明 "type": "module"，直接 `node --check` 会被当成 CommonJS
        # 报 "Cannot use import statement outside a module"（误报）。拷成 .mjs 再检查。
        local _tmp
        _tmp="$(mktemp --suffix=.mjs)"
        if cp "$rfb_js" "$_tmp" && node --check "$_tmp" >/dev/null 2>&1; then
            echo "  · core/rfb.js 语法检查通过（按 ES module）"
        else
            echo "  ⚠️ core/rfb.js 语法检查未通过，请检查（备份见 /root/novnc-backup/）"
        fi
        rm -f "$_tmp"
    fi
}

patch_novnc_utf8_clipboard() {
    echo "--- 配置 noVNC 中文剪贴板双向无乱码补丁 ---"
    local rfb_js="${NOVNC_WEB_ROOT}/core/rfb.js"
    local ui_js="${NOVNC_WEB_ROOT}/app/ui.js"

    if [ -f "$rfb_js" ]; then
        # 1. 出站 (Web -> Linux): 使用 TextEncoder 产生纯净 UTF-8 字节流
        python3 -c "
with open('$rfb_js', 'r') as f: content = f.read()
target = '''            let data = new Uint8Array(text.length);
            for (let i = 0; i < text.length; i++) {
                // FIXME: text can have values outside of Latin1/Uint8
                data[i] = text.charCodeAt(i);
            }

            RFB.messages.clientCutText(this._sock, data);'''
repl = '''            const data = new TextEncoder().encode(text);
            RFB.messages.clientCutText(this._sock, data);'''
if target in content:
    with open('$rfb_js', 'w') as f: f.write(content.replace(target, repl))
" 2>/dev/null || true

        # 2. 进站 (Linux -> Web): 使用 TextDecoder 进行 UTF-8 解码，杜绝 Latin-1 乱码
        python3 -c "
with open('$rfb_js', 'r') as f: content = f.read()
target = 'const text = this._sock.rQshiftStr(length);'
repl = '''const bytes = new Uint8Array(this._sock.rQshiftBytes(length));
            let text;
            try { text = new TextDecoder(\"utf-8\").decode(bytes); }
            catch(e) { text = String.fromCharCode.apply(null, bytes); }'''
if target in content:
    with open('$rfb_js', 'w') as f: f.write(content.replace(target, repl))
" 2>/dev/null || true
    fi

    if [ -f "$ui_js" ]; then
        # 3. 增强实时同步：添加 input 事件监听，粘贴或输入即刻同步
        if ! grep -q "addEventListener('input', UI.clipboardSend)" "$ui_js" 2>/dev/null; then
            sed -i '/addEventListener('"'"'change'"'"', UI.clipboardSend);/a \        document.getElementById("noVNC_clipboard_text").addEventListener("input", UI.clipboardSend);' "$ui_js" 2>/dev/null || true
        fi

        # 4. 优化自动重连：无论正常或异常中断均触发自动重连，解决长时间不用黑屏假死
        python3 -c "
with open('$ui_js', 'r') as f: content = f.read()
target = '''        if (!e.detail.clean) {
            UI.updateVisualState('disconnected');
            if (wasConnected) {
                UI.showStatus(_(\"Something went wrong, connection is closed\"),
                              'error');
            } else {
                UI.showStatus(_(\"Failed to connect to server\"), 'error');
            }
        } else if (UI.getSetting('reconnect', false) === true && !UI.inhibitReconnect) {
            UI.updateVisualState('reconnecting');

            const delay = parseInt(UI.getSetting('reconnect_delay'));
            UI.reconnectCallback = setTimeout(UI.reconnect, delay);
            return;'''
repl = '''        if (UI.getSetting('reconnect', false) === true && !UI.inhibitReconnect) {
            UI.updateVisualState('reconnecting');

            const delay = parseInt(UI.getSetting('reconnect_delay'));
            UI.reconnectCallback = setTimeout(UI.reconnect, delay);
            return;
        } else if (!e.detail.clean) {
            UI.updateVisualState('disconnected');
            if (wasConnected) {
                UI.showStatus(_(\"Something went wrong, connection is closed\"),
                              'error');
            } else {
                UI.showStatus(_(\"Failed to connect to server\"), 'error');
            }'''
if target in content:
    with open('$ui_js', 'w') as f: f.write(content.replace(target, repl))
" 2>/dev/null || true
    fi

    echo "✅ noVNC 中文剪贴板双向补丁已就绪。"
}

# 把 UI 对象暴露到 window。
# noVNC 的 app/ui.js 是 ES module，UI 默认不挂在 window 上；注入脚本
# （连接保活、双屏状态）需要它才能拿到 UI.rfb / UI.reconnect。
patch_novnc_expose_ui() {
    local root ui_js
    for root in "${NOVNC_WEB_ROOT}" "${NOVNC_NEW_WEB_ROOT}"; do
        ui_js="${root}/app/ui.js"
        [ -f "${ui_js}" ] || continue
        if ! grep -q "window.UI = UI" "${ui_js}" 2>/dev/null; then
            printf '\n/* vps-setup: 暴露给注入脚本（连接保活、双屏状态）使用 */\nwindow.UI = UI;\n' >> "${ui_js}"
            echo "  · 已把 UI 暴露到 window：${ui_js}"
        fi
    done
}

# =======================================================
# 桌面真实声音：PulseAudio 虚拟声卡 -> ffmpeg(Opus) -> MediaMTX -> WebRTC
# =======================================================
#
# 为什么这么做：
#   容器里没有 /dev/snd、没有声卡，桌面应用本来无处发声（不是配置错了）。
#   用 PulseAudio 的 module-null-sink 造一块「虚拟声卡」，桌面所有应用的出声
#   都进它；再从它的 monitor 源录出来编码成 Opus 推给 MediaMTX，
#   最后浏览器用 WHEP(WebRTC) 拉流播放。端到端约 0.2~0.5 秒。
#
# 端口分工（容器侧）：
#   8189/udp  WebRTC 媒体  ← 唯一需要宿主机 DNAT 进来的端口
#   8554/tcp  RTSP 推流    仅 127.0.0.1
#   8889/tcp  WHEP 信令    仅 127.0.0.1，由 nginx 反代到 443（同源，免 CORS）
#   9997/tcp  诊断 API     仅 127.0.0.1
#
# 宿主机上需要你做的一步：见 install_desktop_audio 末尾打印的内容（或 --audio-help）。

# 自动探测公网 IP —— 容器出网会被宿主机 SNAT，探测到的就是宿主机的公网 IP，
# 也就是 WebRTC 需要对外播报的那个地址。
detect_public_ip() {
    local url ip
    for url in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
        ip=$(curl -fsS --max-time 6 "${url}" 2>/dev/null | tr -d '[:space:]')
        case "${ip}" in
            *[0-9].[0-9]*) echo "${ip}"; return 0 ;;
        esac
    done
    return 1
}

# ---- 1) PulseAudio：虚拟声卡 + 常驻守护进程 ----
install_pulseaudio_virtual_sink() {
    echo "--- 安装 PulseAudio 虚拟声卡（容器无声卡也能出声）---"
    ensure_pkgs ${PKG_AUDIO} ${PKG_AUDIO_GUI}

    # 1.1 虚拟声卡本身。
    #     /etc/pulse/default.pa 的最后一行是 .include default.pa.d，
    #     所以本 drop-in 在 module-always-sink 之后执行，set-default-sink 不会被 auto_null 抢走。
    #     采样率直接定 48k：Opus / WebRTC 都是 48k，省掉一次重采样（1 核机很宝贵）。
    mkdir -p /etc/pulse/default.pa.d
    cat > /etc/pulse/default.pa.d/50-vnc-virtual-sink.pa <<EOF
### 由 vps-setup (vnc_desktop_setup.sh) 生成
load-module module-null-sink sink_name=${AUDIO_SINK} rate=48000 channels=2 format=s16le sink_properties=device.description=VirtualSpeaker
set-default-sink ${AUDIO_SINK}
EOF

    # 1.2 所有客户端都连我们这一个守护进程：禁止 autospawn 出第二个实例
    #     （否则桌面里的应用可能自起一个空的 PA，声音就进错地方了）
    mkdir -p /etc/pulse/client.conf.d
    cat > /etc/pulse/client.conf.d/90-vnc.conf <<EOF
### 由 vps-setup 生成
autospawn = no
default-server = unix:${AUDIO_PULSE_RUNTIME}/pulse/native
EOF

    # 1.3 空闲也不退出（-1 = 永不），否则 systemd 会以为「正常结束」而不再拉起
    mkdir -p /etc/pulse/daemon.conf.d
    cat > /etc/pulse/daemon.conf.d/90-vnc.conf <<EOF
### 由 vps-setup 生成
# 重采样器：默认的 speex-float-1 偏低，实测 44.1k->48k 时最上面半个八度掉 ~3.4 dB
# （>16k 频段：PA -41.5 dB vs soxr -38.1 dB，原始 -37.5 dB）。只有 44.1k 的源
# （网页音频/MP3）会走这条路径。代价是重采样时多用一点 CPU。
exit-idle-time = -1
resample-method = soxr-vhq
EOF

    # 1.4 守护进程：以桌面用户身份跑；RuntimeDirectory 保证 socket 路径固定
    cat > /etc/systemd/system/pulseaudio-vnc.service <<EOF
[Unit]
Description=PulseAudio daemon (virtual sound card for the VNC desktop)
Documentation=man:pulseaudio(1)
After=network.target

[Service]
Type=notify
TimeoutStartSec=25
User=${VNC_USER}
Group=${VNC_USER}
RuntimeDirectory=pulse-vnc
RuntimeDirectoryMode=0755
Environment=XDG_RUNTIME_DIR=${AUDIO_PULSE_RUNTIME}
Environment=HOME=${USER_HOME}
ExecStart=/usr/bin/pulseaudio --daemonize=no --log-target=journal
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable pulseaudio-vnc >/dev/null 2>&1 || true
    systemctl restart pulseaudio-vnc
    sleep 2
    if ! systemctl is-active --quiet pulseaudio-vnc; then
        echo "❌ pulseaudio-vnc 没起来，最近日志："
        journalctl -u pulseaudio-vnc -n 15 --no-pager | sed 's/^/    /'
        return 1
    fi

    local sinks
    sinks=$(runuser -u "${VNC_USER}" -- env HOME="${USER_HOME}" DISPLAY= \
            pactl list short sinks 2>/dev/null)
    if echo "${sinks}" | grep -q "[[:space:]]${AUDIO_SINK}[[:space:]]"; then
        echo "✅ 虚拟声卡就绪：$(echo "${sinks}" | grep "[[:space:]]${AUDIO_SINK}[[:space:]]" | awk '{print $2, $4, $5, $6}')"
    else
        echo "⚠️ 守护进程在跑，但没看到 ${AUDIO_SINK}："
        echo "${sinks}" | sed 's/^/    /'
        return 1
    fi
}

# ---- 2) MediaMTX：RTSP 收流，WebRTC(WHEP) 发流 ----
install_mediamtx() {
    echo "--- 安装 MediaMTX（RTSP -> WebRTC 网关）---"
    local ver="${MEDIAMTX_VERSION}" arch_tag tmp url
    case "$(dpkg --print-architecture 2>/dev/null)" in
        amd64) arch_tag="amd64" ;;
        arm64) arch_tag="arm64" ;;
        *)     echo "⚠️ 不支持的架构，跳过 MediaMTX"; return 1 ;;
    esac

    # 版本：默认取 GitHub 最新；网络不通/限流时退回脚本定版
    if [ -z "${ver}" ]; then
        ver=$(curl -fsS --max-time 10 \
              https://api.github.com/repos/bluenviron/mediamtx/releases/latest 2>/dev/null \
              | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])' 2>/dev/null)
    fi
    ver="${ver:-v1.21.2}"

    # 已经装好、且没要求换版本 → 不重复下载
    local need=0
    [ -n "${MEDIAMTX_VERSION}" ] && need=1
    /usr/local/bin/mediamtx --version >/dev/null 2>&1 || need=1

    if [ "${need}" -eq 1 ]; then
        tmp=$(mktemp -d)
        url="https://github.com/bluenviron/mediamtx/releases/download/${ver}/mediamtx_${ver}_linux_${arch_tag}.tar.gz"
        echo "ℹ️ 下载 MediaMTX ${ver} (${arch_tag}) ..."
        if ! curl -fsSL --max-time 240 -o "${tmp}/mediamtx.tar.gz" "${url}"; then
            rm -rf "${tmp}"; echo "❌ 下载失败：${url}"; return 1
        fi
        if ! tar xzf "${tmp}/mediamtx.tar.gz" -C "${tmp}" mediamtx; then
            rm -rf "${tmp}"; echo "❌ 解包失败"; return 1
        fi
        install -m 0755 "${tmp}/mediamtx" /usr/local/bin/mediamtx
        rm -rf "${tmp}"
    fi
    echo "ℹ️ 版本：$(/usr/local/bin/mediamtx --version 2>/dev/null | head -1)"

    # WebRTC 要对外播报的地址：不指定就什么都播不出来（只能拿到容器内网地址）
    local hosts_line="[]"
    [ -n "${AUDIO_PUBLIC_HOST}" ] && hosts_line="[${AUDIO_PUBLIC_HOST}]"

    cat > /etc/mediamtx.yml <<EOF
###############################################
# MediaMTX 配置 —— 桌面音频 -> WebRTC
# 由 vps-setup (vnc_desktop_setup.sh) 生成
#   数据流: ffmpeg(PulseAudio monitor) --RTSP--> MediaMTX --WebRTC/WHEP--> 浏览器
###############################################

logLevel: info
logDestinations: [stdout]

# 诊断用 API，只监听本机
api: yes
apiAddress: 127.0.0.1:${AUDIO_API_PORT}
metrics: no
pprof: no

# ---- RTSP：只给本机 ffmpeg 推流用 ----
rtsp: yes
rtspAddress: 127.0.0.1:${AUDIO_RTSP_PORT}
rtspTransports: [tcp]
rtspEncryption: "no"

# ---- 其它协议一律关掉，省 CPU / 少开端口 ----
rtmp: no
hls: no
srt: no
moq: no
playback: no

# ---- WebRTC ----
webrtc: yes
webrtcAddress: 127.0.0.1:${AUDIO_WHEP_PORT}   # 信令，由 nginx 反代成 443 同源
webrtcLocalUDPAddress: :${AUDIO_UDP_PORT}     # 媒体（宿主机已 DNAT 进来）
webrtcLocalTCPAddress: ""                     # 需要时可改成 :${AUDIO_UDP_PORT} 走 ICE-TCP
webrtcIPsFromInterfaces: false                # 容器在 NAT 后，内网地址对客户端没用
webrtcAdditionalHosts: ${hosts_line}
webrtcAllowOrigins: ["*"]

paths:
  ${AUDIO_PATH}:
    # 桌面声音（noVNC 页面的「🔊 桌面声音」）：runOnDemand = 有人听才拉起 ffmpeg，
    # 最后一个听众离开 10 秒后自动退出（没人听时 CPU 占用为 0）。
    # 以前是常驻的 desktop-audio-bridge.service，24/7 空转 ~1% 单核。
    source: publisher
    runOnDemand: /usr/local/bin/desktop-audio-publish
    runOnDemandRestart: yes
    runOnDemandCloseAfter: 10s
    # 明确不落盘：本链路只做实时转发，音频不进磁盘
    # （真要录制再改 yes + recordPath）
    record: no

  ${VIDEO_PATH}:
    # 桌面视频（/live 页面看画面）：runOnDemand = 有人看才拉起 ffmpeg，
    # 最后一个人离开 10 秒后自动退出（不观看时 CPU 占用为 0）。
    # 与 noVNC 的音频路径完全独立，互不影响。
    runOnDemand: ${VIDEO_BIN}
    runOnDemandRestart: yes
    runOnDemandCloseAfter: 10s
    # 明确不落盘：只做实时转发
    record: no
EOF

    cat > /etc/systemd/system/mediamtx.service <<EOF
[Unit]
Description=MediaMTX (RTSP -> WebRTC gateway for the desktop audio)
Documentation=https://github.com/bluenviron/mediamtx
After=network.target

[Service]
Type=simple
User=${VNC_USER}
Group=${VNC_USER}
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx.yml
Restart=always
RestartSec=3
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mediamtx >/dev/null 2>&1 || true
    systemctl restart mediamtx
    sleep 2
    if ! systemctl is-active --quiet mediamtx; then
        echo "❌ mediamtx 没起来（大概率是配置键名和你下载的版本不一致），最近日志："
        journalctl -u mediamtx -n 20 --no-pager | sed 's/^/    /'
        return 1
    fi
    echo "✅ MediaMTX 就绪：udp/${AUDIO_UDP_PORT}  rtsp/${AUDIO_RTSP_PORT}(本机)  whep/${AUDIO_WHEP_PORT}(本机)"
    if [ -z "${AUDIO_PUBLIC_HOST}" ]; then
        echo "⚠️ 没探测到公网 IP：WebRTC 只能播报容器内网地址，浏览器多半连不上。"
        echo "   请指定后重跑：AUDIO_PUBLIC_HOST=<公网IP或域名> bash $0 --audio"
    fi
}

# ---- 3) 桥接：虚拟声卡 monitor -> Opus -> RTSP ----
# ---- Opus 码率：校验与选择 ----

# 规范化成 ffmpeg 要的 "NNNk"（接受 192 / 192k / 192K）；
# 非法或超出 ${AUDIO_BITRATE_MIN}~${AUDIO_BITRATE_MAX} 返回非 0（不输出）。
normalize_bitrate() {
    local v="${1//[[:space:]]/}"
    case "${v}" in
        *[kK]) v="${v%[kK]}" ;;
    esac
    case "${v}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "${v}" -lt "${AUDIO_BITRATE_MIN}" ] || [ "${v}" -gt "${AUDIO_BITRATE_MAX}" ]; then
        return 1
    fi
    echo "${v}k"
}

# 读当前已安装的码率（读不到就什么都不输出）
detect_installed_bitrate() {
    local cur
    # 优先读 /etc/default/desktop-audio（当前格式），兼容早期的单元/脚本内写法
    cur=$(sed -n 's/^DESKTOP_AUDIO_BITRATE=\([0-9]\+k\).*/\1/p' \
              /etc/default/desktop-audio 2>/dev/null | head -1)
    if [ -z "${cur}" ]; then
        cur=$(sed -n 's/^Environment=DESKTOP_AUDIO_BITRATE=\([0-9]\+k\).*/\1/p' \
                  /etc/systemd/system/desktop-audio-bridge.service 2>/dev/null | head -1)
    fi
    if [ -z "${cur}" ]; then
        cur=$(sed -n 's/.*-b:a[[:space:]]*\([0-9]\+k\).*/\1/p' \
                  /usr/local/bin/desktop-audio-bridge 2>/dev/null | head -1)
    fi
    [ -n "${cur}" ] && echo "${cur}"
    return 0
}

# 决定本次使用的 Opus 码率（结果写回 AUDIO_BITRATE）
resolve_audio_bitrate() {
    local cur ans
    cur=$(detect_installed_bitrate)

    # 1) 命令行 --audio-bitrate=... / 环境变量 AUDIO_BITRATE=...：直接用，不询问
    if [ -n "${AUDIO_BITRATE}" ]; then
        if ! ans=$(normalize_bitrate "${AUDIO_BITRATE}"); then
            echo "❌ 码率 '${AUDIO_BITRATE}' 不合法：请用 ${AUDIO_BITRATE_MIN}k~${AUDIO_BITRATE_MAX}k（例如 192k）"
            return 1
        fi
        AUDIO_BITRATE="${ans}"
        echo "ℹ️ 音频码率：${AUDIO_BITRATE}（命令行/环境变量指定）"
        return 0
    fi

    # 2) 有终端：询问，直接回车 = 默认
    #    注意判定条件是 stdin 与 stdout 都是终端：把输出重定向到文件（--audio > log）
    #    时不问，免得提示语进了日志、人却看不见还以为卡住。
    if [ -t 0 ] && [ -t 1 ]; then
        echo "Opus 音频码率："
        echo "  常用 128k / 192k（默认）/ 256k / 320k，范围 ${AUDIO_BITRATE_MIN}k~${AUDIO_BITRATE_MAX}k。"
        echo "  实测膝点在 192~256k（再往上几乎无收益）；带宽 192k≈200 / 256k≈272 / 320k≈357 kbit/s。"
        [ -n "${cur}" ] && echo "  当前已安装：${cur}（直接回车＝改成默认 ${AUDIO_BITRATE_DEFAULT}）"
        while true; do
            if ! read -r -p "  码率 [${AUDIO_BITRATE_DEFAULT}]: " ans; then
                echo
                echo "  ℹ️ 输入结束（EOF/Ctrl+D），用默认 ${AUDIO_BITRATE_DEFAULT}。"
                ans="${AUDIO_BITRATE_DEFAULT}"
                break
            fi
            [ -z "${ans}" ] && ans="${AUDIO_BITRATE_DEFAULT}"
            if ans=$(normalize_bitrate "${ans}"); then
                break
            fi
            echo "  ⚠️ 不合法：请输入 ${AUDIO_BITRATE_MIN}k~${AUDIO_BITRATE_MAX}k（如 192k）"
        done
        AUDIO_BITRATE="${ans}"
        echo "  → 本次采用 ${AUDIO_BITRATE}"
        return 0
    fi

    # 3) 非交互（管道/脚本调用）：已装过就沿用，避免重跑脚本时默默改掉你选的码率
    if [ -n "${cur}" ]; then
        AUDIO_BITRATE="${cur}"
        echo "ℹ️ 非交互模式：沿用已安装的码率 ${AUDIO_BITRATE}（可用 --audio-bitrate=256k 改）"
    else
        AUDIO_BITRATE="${AUDIO_BITRATE_DEFAULT}"
        echo "ℹ️ 非交互模式：码率取默认 ${AUDIO_BITRATE}（可用 --audio-bitrate=256k 改）"
    fi
    return 0
}

install_desktop_audio_bridge() {
    echo "--- 安装音频桥接（虚拟声卡 -> Opus -> RTSP，按需拉起）---"

    # 参数单独放一个文件：改码率不用碰 systemd，也不影响别的通道
    cat > /etc/default/desktop-audio <<EOF
# 桌面声音（noVNC 页面里的「🔊 桌面声音」）采集/编码参数。
# 由 vps-setup (vnc_desktop_setup.sh) 生成；改完不用重启任何服务 ——
# 下一个听众连上来时按需启动编码（go 后端或 MediaMTX/ffmpeg）。
DESKTOP_AUDIO_SRC=${AUDIO_SINK}.monitor
DESKTOP_AUDIO_RTSP=rtsp://127.0.0.1:${AUDIO_RTSP_PORT}/${AUDIO_PATH}
# Opus 码率（安装时选的；膝点 192~256k，见 README「码率怎么选」）
DESKTOP_AUDIO_BITRATE=${AUDIO_BITRATE}
EOF

    # WebRTC 只认 Opus/PCMU/PCMA，而 MediaMTX 不做转码，所以这里必须直接编 Opus。
    # 单次执行（不循环）：MediaMTX 负责在有人听时拉起、没人听后杀掉。
    cat > /usr/local/bin/desktop-audio-publish <<'EOF_DESKTOP_AUDIO_PUBLISH'
#!/bin/bash
# 桌面声音 -> WebRTC：由 MediaMTX 的 runOnDemand 按需拉起。
# 有人听才编码，最后一个听众离开 10 秒后 MediaMTX 直接杀掉本进程（不再常驻编码）。
# 由 vps-setup (vnc_desktop_setup.sh) 生成；改了脚本请重跑脚本，别只改这里。
# 纯实时转发：不落盘、不录屏。
set -u

ENV_FILE="${DESKTOP_AUDIO_ENV:-/etc/default/desktop-audio}"
if [ -r "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${ENV_FILE}"
fi

RTSP_URL="${DESKTOP_AUDIO_RTSP:-rtsp://127.0.0.1:8554/desktop}"
SRC="${DESKTOP_AUDIO_SRC:-virtual_speaker.monitor}"
BITRATE="${DESKTOP_AUDIO_BITRATE:-192k}"

echo "[desktop-audio-publish] ${SRC} -> ${RTSP_URL} (Opus ${BITRATE})"
# asetpts=N/SR/TB：PulseAudio 的包时间戳会抖（偶尔倒退），libopus 遇到倒退还
# 会丢帧；实测 5 秒里就少 2 帧、最大空 47ms —— 开音频那一下的"爆音"就是它。
# 按采样计数重新生成 PTS 后，5 秒 250 帧，间隔稳稳 20ms，编码器不再丢帧。
#
# -fragment_size 3840：PulseAudio 默认约 50ms 一块，编码器一次吐出 2~3 帧，
# RTP 到达就是成串的；改成 20ms 一块后实测 50.0 包/秒、最大到达间隔 40ms（原 100ms）。
#
# application=lowdelay + frame_duration=20 是实测出来的（码率曲线膝点 192~256k，
# 各频段 192/256/320 差 <0.12 dB，20 kHz 以上 Opus 一律没有）——详见 README。
# exec：本进程就是 ffmpeg，MediaMTX 发 SIGTERM 直接落到编码器上，不留孤儿。
exec ffmpeg -hide_banner -nostdin -loglevel warning \
    -f pulse -fragment_size 3840 -i "${SRC}" \
    -af asetpts=N/SR/TB \
    -ac 2 -ar 48000 \
    -c:a libopus -b:a "${BITRATE}" -application lowdelay -frame_duration 20 \
    -f rtsp -rtsp_transport tcp "${RTSP_URL}"
EOF_DESKTOP_AUDIO_PUBLISH
    chmod 0755 /usr/local/bin/desktop-audio-publish

    # ---- 桌面音频直发（vnc-audio-rtc）：/whep 不再经过 MediaMTX ----
    # 和 Selkies 一样：PulseAudio → Opus → RTP → pion WebRTC 直发，
    # 没有 RTSP/TCP 合包，也没有 MediaMTX 二次转发。
    if [ "${AUDIO_RTC_UNIT}" = "vnc-audio-rtc.service" ] && [ -x "${_audio_rtc_payload}" ]; then
        install -m 0755 "${_audio_rtc_payload}" /usr/local/bin/vnc-audio-rtc
        install -m 0755 "$(dirname "${_audio_rtc_payload}")/desktop-audio-rtc-publish" /usr/local/bin/desktop-audio-rtc-publish

        # 后端选择：命令行/环境变量优先；否则沿用已装值；新装默认 go。
        local _audio_backend="${AUDIO_BACKEND:-}"
        if [ -z "${_audio_backend}" ]; then
            _audio_backend=$(sed -n 's/^AUDIO_BACKEND=\(go\|ffmpeg\)$/\1/p' \
                                /etc/default/vnc-audio-rtc 2>/dev/null | tail -1)
        fi
        [ -n "${_audio_backend}" ] || _audio_backend=go
        _audio_backend=$(echo "${_audio_backend}" | tr '[:upper:]' '[:lower:]')
        case "${_audio_backend}" in
            go|ffmpeg) ;;
            *)
                echo "❌ AUDIO_BACKEND 只能是 go 或 ffmpeg，当前 '${_audio_backend}'"
                return 1
                ;;
        esac
        cat > /etc/default/vnc-audio-rtc <<EOF
# vnc-audio-rtc 音频后端：
#   go     = 进程内 PulseAudio + gopus（默认；不占 8195，无外部 ffmpeg）
#   ffmpeg = 外部 desktop-audio-rtc-publish → RTP 127.0.0.1:8195
# 改完执行：systemctl restart vnc-audio-rtc
AUDIO_BACKEND=${_audio_backend}
EOF

        local _pub_ip="" _bind_ip="" _pub_arg="" _bind_arg=""
        if [ -r /etc/default/vnc-rtc ]; then
            _pub_ip=$(sed -n 's/^PUBLIC_IP=//p' /etc/default/vnc-rtc 2>/dev/null | tail -1)
        fi
        [ -n "${_pub_ip}" ] || _pub_ip="${AUDIO_PUBLIC_HOST}"
        [ -n "${_pub_ip}" ] || _pub_ip=$(detect_public_ip 2>/dev/null || true)
        [ -n "${_pub_ip}" ] && _pub_arg="-public-ip ${_pub_ip}"
        _bind_ip=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        [ -n "${_bind_ip}" ] && _bind_arg="-bind-ip ${_bind_ip}"

        cat > /etc/systemd/system/vnc-audio-rtc.service <<EOF
[Unit]
Description=Desktop audio over WebRTC (PulseAudio -> Opus -> pion, no MediaMTX)
After=network-online.target pulseaudio-vnc.service
Wants=network-online.target pulseaudio-vnc.service

[Service]
Type=simple
User=${VNC_USER}
Group=${VNC_USER}
Environment=XDG_RUNTIME_DIR=${AUDIO_PULSE_RUNTIME}
Environment=HOME=/home/${VNC_USER}
Environment=PULSE_SERVER=unix:${AUDIO_PULSE_RUNTIME}/pulse/native
# DESKTOP_AUDIO_SRC / DESKTOP_AUDIO_BITRATE 来自 desktop-audio；AUDIO_BACKEND 来自本服务
EnvironmentFile=-/etc/default/desktop-audio
EnvironmentFile=-/etc/default/vnc-audio-rtc
ExecStart=/usr/local/bin/vnc-audio-rtc -listen 127.0.0.1:${AUDIO_RTC_PORT} ${_pub_arg} ${_bind_arg} -ice-port ${AUDIO_RTC_ICE_PORT} -rtp 127.0.0.1:8195 -publish /usr/local/bin/desktop-audio-rtc-publish
Restart=always
RestartSec=2
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF

        # 视频桥让出 8193：老配置还占着的话音频服务绑不上
        if [ -r /etc/default/vnc-rtc ] && grep -q '^ICE_PORT_MAX=8193$' /etc/default/vnc-rtc; then
            sed -i 's/^ICE_PORT_MAX=8193$/ICE_PORT_MAX=8192/' /etc/default/vnc-rtc
            systemctl try-restart vnc-rtc.service >/dev/null 2>&1 || true
        fi
        systemctl daemon-reload
        systemctl enable vnc-audio-rtc.service >/dev/null 2>&1 || true
        systemctl restart vnc-audio-rtc.service >/dev/null 2>&1 || true
        if systemctl is-active --quiet vnc-audio-rtc.service; then
            echo "✅ 桌面音频直发：vnc-audio-rtc（后端 ${_audio_backend}，WHEP ${AUDIO_RTC_PORT}，ICE UDP ${AUDIO_RTC_ICE_PORT}）"
        else
            echo "⚠️ vnc-audio-rtc 没起来，看 journalctl -u vnc-audio-rtc；/whep 仍可回退 MediaMTX"
        fi
    fi

    # 老版本是常驻服务：24/7 空转（实测 1% 单核），而且会跟 runOnDemand 抢同一个发布者。
    # 这里停掉并移除旧的单元/脚本；要回到常驻模式见 README 的「回滚」。
    systemctl disable --now desktop-audio-bridge >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/desktop-audio-bridge.service
    rm -f /usr/local/bin/desktop-audio-bridge
    systemctl daemon-reload

    echo "✅ 音频桥接已改为按需：有人听才拉起（MediaMTX runOnDemand），离开 10 秒自动退出。"
    echo "   码率：${AUDIO_BITRATE}（/etc/default/desktop-audio）"
}

# ---- 3.5) 桌面视频：Xvfb --x11grab--> H.264+Opus --> RTSP/MediaMTX ----
# 独立于 noVNC 的一条「只播」通道：现有 x11vnc 的配置一个字节都不动，
# 这条路径只是另外读 :1 的画面 + 同一个虚拟声卡。
# 有人打开 /live 时由 MediaMTX 的 runOnDemand 拉起，最后一个人离开 10 秒后自动退出。
install_desktop_video() {
    echo "--- 安装桌面视频通道（/live：WebRTC 看画面，不接管键鼠）---"

    cat > ${VIDEO_BIN} <<'EOF_DESKTOP_VIDEO_BRIDGE'
#!/bin/bash
# 桌面视频 -> WebRTC：由 MediaMTX 的 runOnDemand 按需拉起（有人看才编码，没人看就退出）。
# 由 vps-setup (vnc_desktop_setup.sh) 生成；改了脚本请重跑脚本，别只改这里。
# 纯实时转发：不落盘、不录屏；与 noVNC/x11vnc 完全独立（不碰 5901 那条连接）。
set -u

ENV_FILE="${DESKTOP_VIDEO_ENV:-/etc/default/desktop-video}"
if [ -r "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

RTSP_URL="${DESKTOP_VIDEO_RTSP:-rtsp://127.0.0.1:8554/desktop_av}"
CAPTURE="${DESKTOP_VIDEO_CAPTURE:-1920x1080}"   # 屏幕实际分辨率（抓屏用）
SIZE="${DESKTOP_VIDEO_SIZE:-1280x720}"         # 输出分辨率（低于抓屏分辨率会缩放）
FPS="${DESKTOP_VIDEO_FPS:-30}"                 # 输出帧率
BITRATE="${DESKTOP_VIDEO_BITRATE:-4M}"         # 视频码率
SRC="${DESKTOP_AUDIO_SRC:-virtual_speaker.monitor}"
AUDIO_BITRATE="${DESKTOP_VIDEO_AUDIO_BITRATE:-192k}"

export DISPLAY="${DISPLAY:-:1}"
export HOME="${HOME:-/home/vncuser1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/pulse-vnc}"

args=(
    -hide_banner -nostdin -loglevel warning
    # 画面：抓整个屏幕，光标烧进画面（页面上看到的光标位置就是点击真正落下的位置）
    -f x11grab -draw_mouse 1 -framerate "$FPS" -video_size "$CAPTURE" -i "$DISPLAY"
    # 声音：与 /desktop 音频路径同一个源，进同一条流 -> 音画同步由同一条时间轴保证
    -f pulse -fragment_size 3840 -i "$SRC"
)
if [ "$SIZE" != "$CAPTURE" ]; then
    args+=(-vf "scale=${SIZE}:flags=fast_bilinear")
fi
args+=(
    -c:v libx264 -preset ultrafast -tune zerolatency
    -g "$FPS" -keyint_min "$FPS"          # 1 秒一个关键帧：丢包最多卡 1 秒
    -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$BITRATE"
    -pix_fmt yuv420p
    -af asetpts=N/SR/TB
    -c:a libopus -b:a "$AUDIO_BITRATE" -application lowdelay -frame_duration 20 -ac 2 -ar 48000
    -f rtsp -rtsp_transport tcp "$RTSP_URL"
)

echo "[desktop-video-bridge] ${CAPTURE}@${FPS} -> ${SIZE} ${BITRATE} + ${SRC} ${AUDIO_BITRATE} -> ${RTSP_URL}"
exec ffmpeg "${args[@]}"
EOF_DESKTOP_VIDEO_BRIDGE
    chmod 0755 ${VIDEO_BIN}

    cat > ${VIDEO_ENV_FILE} <<EOF
# 桌面视频 WebRTC（/live 页面）的参数 —— 由 vps-setup 生成
# 改完不需要重启任何服务：下一次有人打开 /live 时，MediaMTX 会按新参数拉起 ffmpeg。
# （如果正有人在看，先关掉页面等 10 秒让它退出，再重新打开。）

# 抓屏分辨率（Xvfb 的实际分辨率，:1）
DESKTOP_VIDEO_CAPTURE=${VIDEO_CAPTURE}

# 输出分辨率：默认 = 桌面原生 1920x1080（1:1，实测约 48% 单核）。
# 想省 CPU 可改 1280x720（约 21~24%），但 125% 缩放的客户端会再放大 1.49 倍（发软）；
# 页面上的「1:1 像素」模式可以直接对比两种锐度。
DESKTOP_VIDEO_SIZE=${VIDEO_SIZE}

# 输出帧率（1 秒一个关键帧）
DESKTOP_VIDEO_FPS=${VIDEO_FPS}

# 视频码率上限（H.264：只影响带宽/画质，几乎不影响 CPU；静止画面实际远低于此值）
DESKTOP_VIDEO_BITRATE=${VIDEO_BITRATE}

# 声音：与 noVNC 的桌面音频同一个源（PulseAudio 虚拟声卡 monitor），同一条流里发
DESKTOP_VIDEO_AUDIO_BITRATE=${VIDEO_AUDIO_BITRATE}

# 推流目标（MediaMTX 的 RTSP，只监听本机）
DESKTOP_VIDEO_RTSP=rtsp://127.0.0.1:${AUDIO_RTSP_PORT}/${VIDEO_PATH}
EOF
    chmod 0644 ${VIDEO_ENV_FILE}

    mkdir -p ${VIDEO_WEB_ROOT}
    cat > ${VIDEO_WEB_ROOT}/index.html <<'EOF_DESKTOP_VIDEO_HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>桌面视频 · WebRTC</title>
<style>
  html, body { margin:0; height:100%; background:#000; overflow:hidden; color:#ddd;
    font:13px/1.5 system-ui, -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif; }
  #v { position:absolute; inset:0; width:100%; height:100%; object-fit:contain; background:#000; }
  /* object-fit:contain 是为了观看；这条通道不接收键鼠，所以黑边不会影响点击定位 */
  /* object-fit:fill 表示铺满；1:1 由 JS 设死宽高（视频像素 : 屏幕物理像素 = 1:1，最锐） */
  #v.mode-fill { object-fit:fill; }
  #v.mode-pixel { object-fit:fill; left:50%; top:50%; transform:translate(-50%, -50%);
    width:auto; height:auto; right:auto; bottom:auto; }
  #hud { position:absolute; left:10px; bottom:10px; padding:6px 10px; border-radius:6px;
    background:rgba(0,0,0,.55); white-space:pre; pointer-events:none; font-variant-numeric:tabular-nums; }
  #hud.warn { color:#ffb64d; }
  #bar { position:absolute; right:10px; top:10px; display:flex; gap:6px; }
  button { background:rgba(30,30,30,.82); color:#ddd; border:1px solid #555; border-radius:6px;
    padding:5px 10px; cursor:pointer; font:inherit; }
  button:hover { background:#3a3a3a; }
  #msg { position:absolute; inset:0; display:flex; align-items:center; justify-content:center;
    flex-direction:column; gap:8px; text-align:center; padding:24px; pointer-events:none; }
  #msg.hide { display:none; }
  #msg b { font-size:15px; font-weight:600; }
  #msg small { color:#999; max-width:560px; }
</style>
</head>
<body>
<video id="v" playsinline autoplay muted></video>
<div id="hud"></div>
<div id="bar">
  <button id="snd">声音：关</button>
  <button id="zoom">缩放：适应窗口</button>
  <button id="fs">全屏</button>
  <button id="re">重连</button>
</div>
<div id="msg"><b>正在连接桌面视频…</b><small>这条通道只负责「看」；键鼠操作仍然在 noVNC 页面。<br>声音默认关闭，需要时点右上角「声音：关」（浏览器要求先有一次点击）。</small></div>

<script>
(function () {
  'use strict';

  var WHEP = '/whep-av';
  var v = document.getElementById('v');
  var hud = document.getElementById('hud');
  var msg = document.getElementById('msg');

  var pc = null, statTimer = null, backoff = 0, stopped = false;
  var lastBytes = 0, lastT = 0;
  var wantSound = false;
  var iceErrors = [];

  function setMsg(html, show) {
    if (html !== null) { msg.innerHTML = html; }
    msg.classList.toggle('hide', !show);
  }

  function teardown() {
    if (statTimer) { clearInterval(statTimer); statTimer = null; }
    if (pc) { try { pc.close(); } catch (e) {} pc = null; }
  }

  function scheduleReconnect(reason) {
    if (stopped) { return; }
    teardown();
    setMsg('<b>连接断开，正在重连…</b><small>' + reason + '</small>', true);
    var wait = Math.min(8000, 500 * Math.pow(2, backoff++));
    setTimeout(connect, wait);
  }

  function connect() {
    if (stopped) { return; }
    teardown();
    setMsg('<b>正在连接桌面视频…</b><small>这条通道只负责「看」；键鼠操作仍然在 noVNC 页面。<br>声音默认关闭，需要时点右上角「声音：关」（浏览器要求先有一次点击）。</small>', true);

    var p = new RTCPeerConnection({ iceServers: [] });
    pc = p;
    p.addTransceiver('video', { direction: 'recvonly' });
    p.addTransceiver('audio', { direction: 'recvonly' });

    p.ontrack = function (ev) {
      v.srcObject = (ev.streams && ev.streams[0]) ? ev.streams[0] : new MediaStream([ev.track]);
      // 默认静音：浏览器只允许「静音」自动播放。声音由右上角按钮开启（那是用户手势）。
      v.muted = !wantSound;
      var pr = v.play();
      if (pr && pr.then) {
        pr.then(function () {
          setMsg(null, false);
          backoff = 0;
          startStats(p);
          applyZoom();
        }).catch(function () {
          setMsg('<b>浏览器拦了自动播放</b><small>点一下页面任意位置继续。</small>', true);
        });
      }
    };

    p.onicecandidateerror = function (e) {
      iceErrors.push((e.errorCode || '') + ' ' + (e.url || '') + ' ' + (e.errorText || ''));
      if (iceErrors.length > 5) { iceErrors.shift(); }
    };

    p.onconnectionstatechange = function () {
      if (p !== pc) { return; }
      var cs = p.connectionState;
      if (cs === 'failed' || cs === 'disconnected' || cs === 'closed') {
        scheduleReconnect('连接状态：' + cs);
      }
    };

    p.createOffer()
      .then(function (o) { return p.setLocalDescription(o); })
      .then(function () {
        return new Promise(function (resolve) {
          if (p.iceGatheringState === 'complete') { resolve(); return; }
          var done = false;
          function finish() {
            if (done) { return; }
            done = true;
            clearTimeout(t);
            p.removeEventListener('icegatheringstatechange', onState);
            resolve();
          }
          function onState() { if (p.iceGatheringState === 'complete') { finish(); } }
          var t = setTimeout(finish, 2500);
          p.addEventListener('icegatheringstatechange', onState);
        });
      })
      .then(function () {
        return fetch(WHEP, {
          method: 'POST',
          headers: { 'Content-Type': 'application/sdp' },
          body: p.localDescription.sdp,
          cache: 'no-store'
        });
      })
      .then(function (res) {
        if (!res.ok) { throw new Error('信令 HTTP ' + res.status); }
        return res.text();
      })
      .then(function (answer) {
        return p.setRemoteDescription({ type: 'answer', sdp: answer });
      })
      .catch(function (e) {
        if (p === pc) { scheduleReconnect('连接失败：' + (e && e.message ? e.message : e)); }
      });
  }

  function startStats(p) {
    if (statTimer) { clearInterval(statTimer); }
    lastBytes = 0; lastT = 0;
    statTimer = setInterval(function () {
      if (p !== pc) { return; }
      p.getStats(null).then(function (rs) {
        var vi = null, au = null, pair = null;
        rs.forEach(function (r) {
          if (r.type === 'inbound-rtp' && r.kind === 'video') { vi = r; }
          if (r.type === 'inbound-rtp' && r.kind === 'audio') { au = r; }
          if (r.type === 'candidate-pair' && r.state === 'succeeded' &&
              (r.nominated || r.selected)) { pair = r; }
        });
        if (!vi) { return; }

        var now = performance.now();
        var mbps = 0;
        if (lastT && vi.bytesReceived >= lastBytes) {
          var dt = (now - lastT) / 1000;
          if (dt > 0.2) { mbps = (vi.bytesReceived - lastBytes) * 8 / dt / 1e6; }
        }
        lastBytes = vi.bytesReceived;
        lastT = now;

        var jb = (vi.jitterBufferDelay && vi.jitterBufferEmittedCount)
          ? (vi.jitterBufferDelay / vi.jitterBufferEmittedCount * 1000) : 0;
        var fps = vi.framesPerSecond || 0;
        var dropped = (vi.framesDropped || 0) + (v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality().droppedVideoFrames : 0);
        var lost = vi.packetsLost || 0;
        var rtt = pair && pair.currentRoundTripTime ? (pair.currentRoundTripTime * 1000) : 0;

        hud.textContent =
          (v.videoWidth || 0) + '×' + (v.videoHeight || 0) +
          ' · ' + fps.toFixed(1) + ' fps' +
          ' · 已解码 ' + (vi.framesDecoded || 0) +
          ' · 丢帧 ' + dropped + '\n' +
          mbps.toFixed(2) + ' Mbps' +
          ' · 缓冲 ' + jb.toFixed(0) + ' ms' +
          ' · RTT ' + rtt.toFixed(0) + ' ms' +
          ' · 丢包 ' + lost;

        hud.classList.toggle('warn', dropped > 0 || lost > 0 || fps < 20);
      }).catch(function () {});
    }, 1000);
  }

  // 诊断用：浏览器控制台里敲 __liveDebug() 可看连接状态（不影响播放）
  window.__liveDebug = function () {
    return {
      state: pc ? pc.connectionState : 'none',
      ice: pc ? pc.iceConnectionState : 'none',
      signaling: pc ? pc.signalingState : 'none',
      iceErrors: iceErrors,
      muted: v.muted, wantSound: wantSound,
      zoom: ZOOM[zoomMode % ZOOM.length],
      box: (function () { var r = v.getBoundingClientRect(); return Math.round(r.width) + 'x' + Math.round(r.height); })(),
      dpr: window.devicePixelRatio,
      size: (v.videoWidth || 0) + 'x' + (v.videoHeight || 0),
      currentTime: v.currentTime, readyState: v.readyState
    };
  };

  var zoomBtn = document.getElementById('zoom');
  var zoomMode = 0;
  var ZOOM = ['fit', 'pixel', 'fill'];
  var ZOOM_LABEL = { fit: '适应窗口', pixel: '1:1 像素', fill: '铺满' };

  // 缩放方式：
  //   fit   = 整屏按比例放进窗口（默认，可能上下或左右留黑边）
  //   pixel = 1 个视频像素 = 1 个屏幕物理像素（最锐；125% 缩放下会显示得比窗口小）
  //   fill  = 拉满整个窗口（会变形，只用来对比）
  function applyZoom() {
    var m = ZOOM[zoomMode % ZOOM.length];
    v.classList.remove('mode-fill', 'mode-pixel');
    if (m === 'fill') { v.classList.add('mode-fill'); }
    if (m === 'pixel') {
      v.classList.add('mode-pixel');
      var dpr = window.devicePixelRatio || 1;
      if (v.videoWidth) {
        v.style.width = (v.videoWidth / dpr) + 'px';
        v.style.height = (v.videoHeight / dpr) + 'px';
      }
    } else {
      v.style.width = '';
      v.style.height = '';
    }
    zoomBtn.textContent = '缩放：' + ZOOM_LABEL[m];
  }
  zoomBtn.addEventListener('click', function () {
    zoomMode = (zoomMode + 1) % ZOOM.length;
    applyZoom();
  });
  window.addEventListener('resize', applyZoom);

  var sndBtn = document.getElementById('snd');
  sndBtn.addEventListener('click', function () {
    wantSound = !wantSound;
    v.muted = !wantSound;
    sndBtn.textContent = wantSound ? '声音：开' : '声音：关';
    if (wantSound) { v.play().catch(function () {}); }
  });

  document.getElementById('fs').addEventListener('click', function () {
    if (document.fullscreenElement) {
      document.exitFullscreen();
    } else if (document.documentElement.requestFullscreen) {
      document.documentElement.requestFullscreen();
    }
  });

  document.getElementById('re').addEventListener('click', function () {
    backoff = 0;
    connect();
  });

  document.addEventListener('click', function () {
    if (!msg.classList.contains('hide')) {
      v.play().then(function () { setMsg(null, false); }).catch(function () {});
    }
  });

  window.addEventListener('beforeunload', function () { stopped = true; teardown(); });

  connect();
})();
</script>
</body>
</html>
EOF_DESKTOP_VIDEO_HTML
    chmod 0644 ${VIDEO_WEB_ROOT}/index.html

    echo "✅ 桌面视频通道就绪：/live（H.264+Opus over WebRTC）"
    echo "   参数文件：${VIDEO_ENV_FILE}（分辨率/帧率/码率；下次打开页面时生效）"
    echo "   按需编码：没人看时 ffmpeg 不运行，CPU 占用为 0"
}

# ---- 4) 页面补丁：vnc.html 里加播放器（novnc 包升级会覆盖，所以可反复重打）----
# 母本存在 ${AUDIO_PATCH_DIR}，升级后跑 ${AUDIO_PATCH_DIR}/apply.sh 即可复原。
patch_novnc_desktop_audio() {
    # 音频后端没装时不改页面（免得出现一个点了没反应的开关）
    if [ ! -x /usr/local/bin/mediamtx ]; then
        echo "ℹ️ 还没装音频后端，暂不改 vnc.html（装好后重跑本步或菜单 [13] 会自动补上）"
        return 0
    fi
    echo "--- 给 noVNC 页面加「桌面声音」开关 ---"
    if [ ! -d "${NOVNC_WEB_ROOT}/app" ]; then
        echo "⚠️ 找不到 ${NOVNC_WEB_ROOT}/app，跳过"
        return 0
    fi

    mkdir -p "${AUDIO_PATCH_DIR}"

    # 4.1 播放器脚本（母本 + 副本）
    cat > "${AUDIO_PATCH_DIR}/desktop-audio.js" <<'EOF_DESKTOP_AUDIO_JS'
/*
 * desktop-audio.js —— 由 vps-setup 添加
 *
 * 在 noVNC 页面里接收「桌面真实声音」。
 * 服务端链路：
 *   桌面应用 -> PulseAudio 虚拟声卡(virtual_speaker)
 *            -> ffmpeg(Opus) -> MediaMTX(RTSP) -> 本脚本(WHEP/WebRTC)
 *
 * 信令走 /whep（nginx 同源反代到 MediaMTX 的 /desktop/whep），
 * 媒体走宿主机转发进来的 UDP 8189。
 *
 * 用法：页面上勾选「🔊 桌面声音」即可（浏览器要求一次用户手势才允许播放）。
 * 状态栏会显示实时接收码率（Opus 是 VBR：放音乐时高，静音时会掉到几 kbit/s）。
 */
(function () {
    'use strict';

    var WHEP_URL = '/whep';
    var MAX_BACKOFF = 8000;   // 重连最大间隔(ms)
    var CHECK_EVERY = 5000;   // 看门狗间隔(ms)
    var STALL_LIMIT = 2;      // 连续几次没收到新数据就重连
    var STAT_EVERY = 2000;    // 码率刷新间隔(ms)

    var el = document.getElementById('desktopAudio');
    var box = document.getElementById('desktopAudioBar');
    var cb = document.getElementById('desktopAudioToggle');
    var vol = document.getElementById('desktopAudioVolume');
    var st = document.getElementById('desktopAudioState');
    if (!el || !cb) { return; }

    var pc = null;
    var running = false;
    var backoff = 0;
    var retryTimer = null;
    var watchTimer = null;
    var statTimer = null;
    var curState = '';        // 状态文字（不含码率）
    var kbps = -1;            // 最近测得的接收码率(kbit/s)，-1 = 还没测到

    function render() {
        if (!st) { return; }
        var t = curState;
        if (kbps >= 0) {
            var v = (kbps < 10) ? kbps.toFixed(1) : String(Math.round(kbps));
            t = t ? t + ' · ' + v + ' kbit/s' : v + ' kbit/s';
        }
        st.textContent = t ? '（' + t + '）' : '';
    }

    function setState(s) {
        curState = s || '';
        render();
    }

    function clearTimers() {
        if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
        if (watchTimer) { clearInterval(watchTimer); watchTimer = null; }
        if (statTimer) { clearInterval(statTimer); statTimer = null; }
        kbps = -1;
        render();
    }

    function scheduleReconnect(why) {
        if (!running || retryTimer) { return; }
        clearTimers();
        var delay = Math.min(1000 * Math.pow(2, backoff), MAX_BACKOFF);
        backoff += 1;
        setState(why + '，' + Math.round(delay / 1000) + ' 秒后重连');
        retryTimer = setTimeout(function () {
            retryTimer = null;
            connect();
        }, delay);
    }

    function startWatchdog(myPc) {
        var lastBytes = -1;
        var stall = 0;
        if (watchTimer) { clearInterval(watchTimer); }
        watchTimer = setInterval(function () {
            if (!running || myPc !== pc) { return; }
            if (myPc.connectionState === 'failed' || myPc.connectionState === 'closed') {
                scheduleReconnect('连接断开');
                return;
            }
            myPc.getStats(null).then(function (report) {
                var bytes = 0;
                report.forEach(function (r) {
                    if (r.type === 'inbound-rtp' && r.bytesReceived) { bytes += r.bytesReceived; }
                });
                if (bytes > lastBytes) {
                    lastBytes = bytes;
                    stall = 0;
                    backoff = 0;
                    if (el.paused && el.srcObject) {
                        el.play().then(function () { setState('播放中'); }).catch(function () {});
                    }
                } else {
                    stall += 1;
                    if (lastBytes >= 0 && stall >= STALL_LIMIT) {
                        scheduleReconnect('音频中断');
                    }
                }
            }).catch(function () {});
        }, CHECK_EVERY);
    }

    // 每 2 秒从 getStats 算一次"实际收到多少"（含 RTP 头等开销）
    function startStats(myPc) {
        if (statTimer) { clearInterval(statTimer); }
        var lastB = 0;
        var lastT = 0;
        statTimer = setInterval(function () {
            if (!running || myPc !== pc) { return; }
            myPc.getStats(null).then(function (report) {
                var bytes = 0;
                report.forEach(function (r) {
                    if (r.type === 'inbound-rtp' && r.bytesReceived &&
                        r.kind !== 'video' && r.mediaType !== 'video') {
                        bytes += r.bytesReceived;
                    }
                });
                var now = (window.performance && performance.now) ? performance.now() : Date.now();
                if (lastT && bytes >= lastB) {
                    var dt = (now - lastT) / 1000;
                    if (dt > 0.2) {
                        kbps = (bytes - lastB) * 8 / dt / 1000;
                        render();
                    }
                }
                lastB = bytes;
                lastT = now;
            }).catch(function () {});
        }, STAT_EVERY);
    }

    function connect() {
        if (!running) { return; }
        if (pc) { try { pc.close(); } catch (e) {} pc = null; }
        setState('连接中…');

        var myPc = new RTCPeerConnection({ iceServers: [] });
        pc = myPc;
        myPc.addTransceiver('audio', { direction: 'recvonly' });

        myPc.ontrack = function (ev) {
            el.srcObject = (ev.streams && ev.streams[0]) ? ev.streams[0] : new MediaStream([ev.track]);
            el.volume = parseFloat(vol ? vol.value : '1');
            var p = el.play();
            if (p && p.then) {
                p.then(function () {
                    backoff = 0;
                    if (box) { box.classList.remove('blocked'); }
                    setState('播放中');
                }).catch(function () {
                    if (box) { box.classList.add('blocked'); }
                    setState('浏览器拦了自动播放，点一下音频条');
                });
            }
        };

        myPc.onconnectionstatechange = function () {
            if (!running || myPc !== pc) { return; }
            var cs = myPc.connectionState;
            if (cs === 'failed' || cs === 'disconnected' || cs === 'closed') {
                scheduleReconnect('连接断开');
            }
        };

        myPc.createOffer()
            .then(function (offer) { return myPc.setLocalDescription(offer); })
            .then(function () {
                // 等 ICE 收集完成再发（非 trickle），最多等 2.5 秒
                return new Promise(function (resolve) {
                    if (myPc.iceGatheringState === 'complete') { resolve(); return; }
                    var done = false;
                    function finish() {
                        if (done) { return; }
                        done = true;
                        clearTimeout(timer);
                        myPc.removeEventListener('icegatheringstatechange', onState);
                        resolve();
                    }
                    function onState() {
                        if (myPc.iceGatheringState === 'complete') { finish(); }
                    }
                    var timer = setTimeout(finish, 2500);
                    myPc.addEventListener('icegatheringstatechange', onState);
                });
            })
            .then(function () {
                return fetch(WHEP_URL, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/sdp' },
                    body: myPc.localDescription.sdp,
                    cache: 'no-store'
                });
            })
            .then(function (res) {
                if (!res.ok) { throw new Error('信令 HTTP ' + res.status); }
                return res.text();
            })
            .then(function (answer) {
                return myPc.setRemoteDescription({ type: 'answer', sdp: answer });
            })
            .then(function () {
                if (myPc === pc) { startWatchdog(myPc); startStats(myPc); }
            })
            .catch(function (e) {
                if (myPc === pc) {
                    scheduleReconnect('连接失败: ' + (e && e.message ? e.message : e));
                }
            });
    }

    function stop() {
        running = false;
        clearTimers();
        if (pc) { try { pc.close(); } catch (e) {} pc = null; }
        el.srcObject = null;
        if (box) { box.classList.remove('blocked'); }
        setState('已关闭');
    }

    cb.addEventListener('change', function () {
        if (cb.checked) {
            running = true;
            backoff = 0;
            connect();
        } else {
            stop();
        }
    });

    if (vol) {
        vol.addEventListener('input', function () {
            el.volume = parseFloat(vol.value);
        });
    }

    // 自动播放被拦时，点音频条重试
    if (box) {
        box.addEventListener('click', function (ev) {
            if (el.paused && el.srcObject && ev.target !== cb && ev.target !== vol) {
                el.play().then(function () {
                    box.classList.remove('blocked');
                    setState('播放中');
                }).catch(function () {});
            }
        });
    }

    window.addEventListener('beforeunload', function () {
        if (pc) { try { pc.close(); } catch (e) {} }
    });
})();
EOF_DESKTOP_AUDIO_JS
    install -m 0644 "${AUDIO_PATCH_DIR}/desktop-audio.js" "${NOVNC_WEB_ROOT}/app/desktop-audio.js"

    # 4.2 要插进 vnc.html 的片段
    cat > "${AUDIO_PATCH_DIR}/vnc-html-snippet.html" <<'EOF_DESKTOP_AUDIO_HTML'
    <!-- ==== 桌面音频（WebRTC/WHEP）——由 vps-setup 添加 ==== -->
    <!-- 升级 novnc 包会覆盖 vnc.html，重新应用：bash /root/novnc-audio/apply.sh -->
    <style>
        #desktopAudioBar {
            position: fixed; right: 8px; bottom: 8px; z-index: 2147483647;
            background: rgba(0, 0, 0, .65); color: #eee; padding: 4px 8px;
            border-radius: 6px; font: 12px/1.6 sans-serif;
            display: flex; align-items: center; gap: 6px; user-select: none;
        }
        #desktopAudioBar label { display: flex; align-items: center; gap: 3px; cursor: pointer; margin: 0; color: #eee; }
        #desktopAudioBar input[type=range] { width: 70px; margin: 0; }
        #desktopAudioBar.blocked { outline: 2px solid #e33; }
        #desktopAudioState { opacity: .8; white-space: nowrap; }
    </style>
    <audio id="desktopAudio" autoplay></audio>
    <div id="desktopAudioBar">
        <label><input type="checkbox" id="desktopAudioToggle"> 🔊 桌面声音</label>
        <input type="range" id="desktopAudioVolume" min="0" max="1" step="0.05" value="1" title="音量">
        <span id="desktopAudioState"></span>
    </div>
    <script src="app/desktop-audio.js"></script>
EOF_DESKTOP_AUDIO_HTML

    # 4.3 一键重应用脚本（apt 升级 novnc 覆盖 vnc.html 之后跑它）
    cat > "${AUDIO_PATCH_DIR}/apply.sh" <<'EOF_DESKTOP_AUDIO_APPLY'
#!/bin/bash
# 给 noVNC 的 vnc.html 加上「桌面真实声音」（WebRTC/WHEP）。
#
# novnc 包升级会覆盖 /usr/share/novnc/vnc.html（以及 app/ 下的文件），
# 升级后重跑本脚本即可复原。可重复执行（幂等）。
#
#   用法: bash /root/novnc-audio/apply.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NOVNC_DIR="${NOVNC_DIR:-/usr/share/novnc}"

if [ ! -d "$NOVNC_DIR" ]; then
    echo "[apply] 找不到 $NOVNC_DIR" >&2
    exit 1
fi

install -m 0644 "$HERE/desktop-audio.js" "$NOVNC_DIR/app/desktop-audio.js"
echo "[apply] 已安装 $NOVNC_DIR/app/desktop-audio.js"

python3 - "$NOVNC_DIR/vnc.html" "$HERE/vnc-html-snippet.html" <<'PY'
import sys

target, snippet_path = sys.argv[1], sys.argv[2]
with open(target, encoding="utf-8") as fh:
    html = fh.read()

if "desktopAudioBar" in html:
    print("[apply] vnc.html 里已经有桌面音频片段，跳过")
    raise SystemExit(0)

with open(snippet_path, encoding="utf-8") as fh:
    snippet = fh.read()

marker = "</body>"
pos = html.rfind(marker)
if pos < 0:
    print("[apply] 找不到 </body>，无法插入", file=sys.stderr)
    raise SystemExit(1)

with open(target + ".bak-desktop-audio", "w", encoding="utf-8") as fh:
    fh.write(html)

html = html[:pos] + snippet + "\n" + html[pos:]
with open(target, "w", encoding="utf-8") as fh:
    fh.write(html)

print("[apply] 已把桌面音频片段插入 vnc.html")
print("[apply] 原文件备份在 %s.bak-desktop-audio" % target)
PY
EOF_DESKTOP_AUDIO_APPLY
    chmod 0755 "${AUDIO_PATCH_DIR}/apply.sh"

    # 4.4 幂等插入（已插过就跳过）
    python3 - "${NOVNC_WEB_ROOT}/vnc.html" "${AUDIO_PATCH_DIR}/vnc-html-snippet.html" <<'EOF_PATCH_PY'
import sys

target, snippet_path = sys.argv[1], sys.argv[2]
with open(target, encoding="utf-8") as fh:
    html = fh.read()

if "desktopAudioBar" in html:
    print("✅ vnc.html 里已有「桌面声音」开关，跳过")
    raise SystemExit(0)

with open(snippet_path, encoding="utf-8") as fh:
    snippet = fh.read()

pos = html.rfind("</body>")
if pos < 0:
    print("⚠️ vnc.html 里找不到 </body>，没法插入", file=sys.stderr)
    raise SystemExit(1)

with open(target + ".bak-desktop-audio", "w", encoding="utf-8") as fh:
    fh.write(html)
with open(target, "w", encoding="utf-8") as fh:
    fh.write(html[:pos] + snippet + "\n" + html[pos:])

print("✅ 已把「桌面声音」开关插入 vnc.html（原文件备份：%s.bak-desktop-audio）" % target)
EOF_PATCH_PY
}

# ---- 4.5) 页面补丁：设置面板里加「第二块屏方向」 -------------------------
# Selkies 第二块屏的方向只由弹窗地址的 #display2-<方向> 决定。这里在 noVNC
# 的设置面板里加一个下拉框，写 localStorage（同源）；Selkies 页面由 nginx
# 注入的脚本读同一个键，改写「Add Screen +」打开的地址。
# novnc 包升级覆盖 vnc.html 后，重跑 `vnc_desktop_setup.sh --novnc-patch` 复原。
patch_novnc_second_screen() {
    mkdir -p "${AUDIO_PATCH_DIR}"
    cat > "${AUDIO_PATCH_DIR}/second-screen.js" <<'EOF_SECOND_SCREEN_JS'
/*
 * second-screen.js —— 由 vps-setup 添加
 *
 * noVNC 自己的第二块屏（不依赖 Selkies）：
 *
 *   主页面（/ 和 /new_vnc/）：设置面板里给「第二块屏方向」和「打开第二块屏」。
 *   第二块屏页面（/vnc2，或 path 以 websockify/2 结尾）：心跳 + 方向同步。
 *
 * 服务端在 /second/api/（screen2ctl 服务）：
 *   - 把 Xvfb 的可见桌面扩成 4K（Xvfb 启动时已按 4K 分配）；
 *   - 用 x11vnc 的运行时 clip 把「主屏」给 :5901（noVNC 主视图）、
 *     「第二块屏」给 :5902（noVNC 第二视图），两块都是 1920x1080，1:1；
 *   - 摆 lxpanel、并用 desktop-layout-shift 把窗口搬到主屏那一块。
 *
 * 方向存在 localStorage['selkies-second-screen-position']。Selkies 页面里注入的
 * /selkies-second-screen.js 读同一个键，所以那边的第二块屏也会跟着一起变。
 */
(function () {
    'use strict';

    var KEY = 'selkies-second-screen-position';
    var VALID = ['auto', 'right', 'down', 'left', 'up'];
    var LABELS = {
        auto: '跟随浏览器（默认）',
        right: '右',
        down: '下',
        left: '左',
        up: '上'
    };
    var API = '/second/api/';

    function read() {
        try {
            var v = localStorage.getItem(KEY);
            return VALID.indexOf(v) >= 0 ? v : 'auto';
        } catch (e) {
            return 'auto';
        }
    }

    function write(value) {
        try {
            if (value === 'auto') {
                localStorage.removeItem(KEY);
            } else {
                localStorage.setItem(KEY, value);
            }
        } catch (e) {
            /* 隐私模式等：忽略，设置只在本次生效 */
        }
    }

    /* auto 时给服务端一个具体方向 */
    function direction() {
        var v = read();
        return v === 'auto' ? 'right' : v;
    }

    function api(path) {
        try {
            return fetch(API + path, { method: 'POST', keepalive: true })
                .catch(function () { return null; });
        } catch (e) {
            return Promise.resolve(null);
        }
    }

    /* 第二块屏页面：URL 里 path=.../websockify/2 */
    function isSecondView() {
        var m = /(?:^|[?&])path=([^&]*)/.exec(location.search);
        var p = m ? decodeURIComponent(m[1]) : '';
        return /websockify\/2\/?$/.test(p);
    }

    function secondUrl() {
        if (location.pathname.indexOf('/new_vnc') === 0) {
            return '/new_vnc/vnc.html?path=/websockify/2&autoconnect=true&reconnect=true&shared=1';
        }
        return '/vnc2';
    }

    function initSecondView() {
        document.title = '第二块屏 — noVNC';
        /* noVNC 的 shared 默认是 true，但设置存在 localStorage 里；
           万一主页面被改成「不共享」，第二个连接会把主连接踢掉（x11vnc 收到
           shared=0 会断开已有客户端）。这里在 UI 读设置之前先钉死。 */
        try { localStorage.setItem('shared', 'true'); } catch (e) { /* 忽略 */ }
        /* 打开时把布局摆好（按钮那边也会先调一次，这里是给直接刷新用） */
        api('open?dir=' + direction());
        setInterval(function () { api('ping'); }, 5000);
        window.addEventListener('storage', function (e) {
            if (e.key === KEY || e.key === null) {
                api('dir?dir=' + direction());
            }
        });
        window.addEventListener('pagehide', function () {
            if (navigator.sendBeacon) {
                navigator.sendBeacon(API + 'close');
            } else {
                api('close');
            }
        });
    }

    function build() {
        var panel = document.getElementById('noVNC_settings');
        if (!panel) return;
        var list = panel.querySelector('ul');
        if (!list) return;
        if (document.getElementById('secondScreenDirection')) return;

        var li = document.createElement('li');
        li.id = 'secondScreenSetting';

        var label = document.createElement('label');
        label.setAttribute('for', 'secondScreenDirection');
        label.textContent = '第二块屏方向:';
        li.appendChild(label);

        var select = document.createElement('select');
        select.id = 'secondScreenDirection';
        select.style.width = '100%';
        VALID.forEach(function (value) {
            var option = document.createElement('option');
            option.value = value;
            option.textContent = LABELS[value];
            select.appendChild(option);
        });
        select.value = read();
        select.addEventListener('change', function () {
            write(select.value);
            /* 已经开着的第二块屏就地换边，不用重开 */
            api('dir?dir=' + direction());
        });
        li.appendChild(select);

        /* 打开 noVNC 自己的第二块屏（不是 Selkies 的弹窗） */
        var openButton = document.createElement('button');
        openButton.type = 'button';
        openButton.textContent = '打开第二块屏';
        openButton.style.marginTop = '4px';
        openButton.style.width = '100%';
        openButton.addEventListener('click', function () {
            /* 先把布局摆上（不等返回），再同步开窗：
               window.open 必须在点击的同步上下文里，否则会被浏览器拦。 */
            api('open?dir=' + direction());
            window.open(secondUrl(), '_blank');
        });
        li.appendChild(openButton);

        /* 1.5 的面板标题是 li.noVNC_heading，插在它后面；1.7 标题在 ul 外 */
        var first = list.firstChild;
        if (first && first.classList && first.classList.contains('noVNC_heading')) {
            list.insertBefore(li, first.nextSibling);
        } else {
            list.insertBefore(li, first);
        }
    }

    if (isSecondView()) {
        initSecondView();
        return;
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', build);
    } else {
        build();
    }
})();

EOF_SECOND_SCREEN_JS

    local root
    for root in "${NOVNC_WEB_ROOT}" "${NOVNC_NEW_WEB_ROOT}"; do
        [ -f "${root}/vnc.html" ] || continue
        [ -d "${root}/app" ] || continue
        install -m 0644 "${AUDIO_PATCH_DIR}/second-screen.js" "${root}/app/second-screen.js"
        python3 - "${root}/vnc.html" <<'EOF_SECOND_SCREEN_PATCH'
import sys

target = sys.argv[1]
with open(target, encoding="utf-8") as fh:
    html = fh.read()

tag = '<script src="app/second-screen.js"></script>'
if tag in html:
    print("✅ %s 里已有「第二块屏方向」设置，跳过" % target)
    raise SystemExit(0)

pos = html.rfind("</body>")
if pos < 0:
    print("⚠️ %s 里找不到 </body>，没法插入" % target, file=sys.stderr)
    raise SystemExit(1)

with open(target, "w", encoding="utf-8") as fh:
    fh.write(html[:pos] + "    " + tag + "\n" + html[pos:])
print("✅ 已把「第二块屏方向」设置插入 %s" % target)
EOF_SECOND_SCREEN_PATCH
    done
}

# ---- 4.x) noVNC 设置面板：双屏状态行 + 打开第二块屏按钮 ----
#
# 状态和控制全走 /second/api/（screen2ctl）：前端不存状态，
# 机器是不是扩展桌面、副屏在哪边，都是服务端现场从 xrandr 读的。
# 按钮弹出的 /vnc2 是同一个 noVNC，只是连 websockify/2（第二块 x11vnc）。
install_dualscreen_status() {
    local root
    for root in "${NOVNC_WEB_ROOT}" "${NOVNC_NEW_WEB_ROOT}"; do
        [ -f "${root}/vnc.html" ] || continue
        [ -d "${root}/app" ] || continue

        cat > "${root}/app/dualscreen-status.js" <<'DUALSTATE_JS'
/*
 * dualscreen-status.js —— 由 vps-setup 添加
 *
 * 在 noVNC 的「设置」面板里加：
 *   - 一行只读状态：这台机器现在是不是扩展桌面（双屏），副屏在哪边；
 *   - 一个按钮：打开/关闭第二块屏（弹出新窗口 /vnc2，主视图留在主屏）。
 *
 * 状态与控制都走服务端 /second/api/（screen2ctl）：
 *
 *   GET  /state  机器真实状态 + 控制器状态（现场读 xrandr，不存状态）
 *   POST /open   确保扩展（Selkies 已扩就复用，没有就自己扩成 3840x1080）
 *   POST /close  收起（自己扩的才缩回去）
 *   POST /ping   心跳，30 秒没有就自动收摊
 *
 * GET /state 只在设置面板打开时轮询，面板一关就停，平时一个请求都不发。
 * 心跳（POST /ping）与面板无关：第二块屏开着就一直发。
 *
 * 第二块屏页面（?path=websockify/2）只发心跳，不显示这一行。
 */
(function () {
    'use strict';

    var API = '/second/api/';
    var POLL = 3000;
    var PING = 10000;
    var LABEL = { left: '左', right: '右', up: '上', down: '下' };

    var openedWin = null;
    var pingTimer = null;
    var pollTimer = null;
    var busy = false;

    function el(id) {
        return document.getElementById(id);
    }

    function isSecondView() {
        return location.href.indexOf('websockify/2') >= 0;
    }

    /* ---------------------------------------------------------------- 设置面板 */

    function build() {
        var panel = el('noVNC_settings');
        if (!panel) {
            return false;
        }
        var list = panel.querySelector('ul');
        if (!list || el('dualScreenSetting')) {
            return true;
        }

        var li = document.createElement('li');
        li.id = 'dualScreenSetting';

        var label = document.createElement('label');
        label.textContent = '双屏（机器）:';
        label.title = '这台机器的扩展桌面状态，由服务端从 X 现场读取；Selkies 开的也算';
        li.appendChild(label);

        var value = document.createElement('span');
        value.id = 'dualScreenValue';
        value.textContent = '…';
        value.style.fontWeight = 'bold';
        li.appendChild(value);

        var detail = document.createElement('div');
        detail.id = 'dualScreenDetail';
        detail.style.cssText = 'opacity:.7;font-size:.85em;margin-top:2px;';
        li.appendChild(detail);

        var button = document.createElement('button');
        button.type = 'button';
        button.id = 'dualScreenButton';
        button.textContent = '打开第二块屏';
        button.style.cssText = 'margin-top:4px;width:100%;';
        button.addEventListener('click', function () {
            if (busy) {
                return;
            }
            var isOpen = button.getAttribute('data-open') === '1';
            if (isOpen) {
                closeSecond();
            } else {
                openSecond();
            }
        });
        li.appendChild(button);

        /* 放在 Settings 标题下面，一眼能看到 */
        var head = list.firstElementChild;
        if (head) {
            list.insertBefore(li, head.nextSibling);
        } else {
            list.appendChild(li);
        }
        return true;
    }

    function renderButton(isOpen) {
        var button = el('dualScreenButton');
        if (!button) {
            return;
        }
        button.setAttribute('data-open', isOpen ? '1' : '0');
        button.textContent = isOpen ? '关闭第二块屏' : '打开第二块屏';
        button.disabled = busy;
    }

    function render(s) {
        var value = el('dualScreenValue');
        var detail = el('dualScreenDetail');
        if (!value || !detail) {
            return;
        }

        if (!s || s.error) {
            value.textContent = '未知';
            value.style.color = 'inherit';
            detail.textContent = '';
            renderButton(false);
            return;
        }

        if (!s.extended) {
            value.textContent = '关';
            value.style.color = '#9a9a9a';
            detail.textContent = s.mode ? '当前 ' + s.mode[0] + '×' + s.mode[1] : '';
            renderButton(false);
            return;
        }

        var where = s.direction ? ('副屏在' + (LABEL[s.direction] || s.direction)) : '已扩展';
        value.textContent = '开 · ' + where;
        value.style.color = '#4caf50';

        var bits = [];
        if (s.source === 'selkies') {
            bits.push('Selkies');
        } else if (s.source === 'novnc') {
            bits.push('noVNC');
        } else if (s.source) {
            bits.push(s.source);
        }
        if (s.mode) {
            bits.push(s.mode[0] + '×' + s.mode[1]);
        }
        if (s.primary) {
            bits.push('主屏 ' + s.primary.x + ',' + s.primary.y);
        }
        detail.textContent = bits.join(' · ');

        renderButton(!!s.open);
        /* 心跳只在这个页面自己开的弹窗还活着时发（/vnc2 页面本身也会发）。
           状态显示已关掉就停，避免面板关掉以后没人再把它停掉。 */
        if (!s.open) {
            stopPing();
        } else if (openedWin) {
            startPing();
        }
    }

    /* ---------------------------------------------------------------- 请求 */

    function getState() {
        return fetch(API + 'state', { cache: 'no-store' }).then(function (r) {
            return r.json();
        });
    }

    function post(path) {
        return fetch(API + path, { method: 'POST', cache: 'no-store' }).then(function (r) {
            return r.json();
        });
    }

    function refresh() {
        getState().then(render).catch(function () { render(null); });
    }

    /* ---------------------------------------------------------------- 心跳 */

    function startPing() {
        if (pingTimer) {
            return;
        }
        ping();
        pingTimer = setInterval(ping, PING);
    }

    function stopPing() {
        if (pingTimer) {
            clearInterval(pingTimer);
            pingTimer = null;
        }
    }

    function ping() {
        post('ping').catch(function () {});
        /* 弹窗被关掉（或被用户拖走关掉）→ 立刻收摊，不等 30 秒看门狗 */
        if (openedWin && openedWin.closed) {
            openedWin = null;
            stopPing();
            post('close').then(refresh).catch(function () {});
        }
    }

    /* ---------------------------------------------------------------- 开 / 关 */

    function openSecond() {
        busy = true;
        renderButton(false);

        /* window.open 必须在点击的同步上下文里，否则会被浏览器拦。
           弹窗里的 noVNC 带 reconnect=true，所以先开窗、后上 clip 没关系：
           连不上会自己重试，clip 好了就接上了。 */
        var w = window.open('/vnc2', 'novnc-screen2',
                            'popup=1,width=1280,height=720');
        if (w) {
            openedWin = w;
        }

        post('open').then(function (r) {
            if (!r || !r.ok) {
                /* 开不起来就把弹窗关掉，别留一个永远连不上的窗口 */
                if (openedWin) {
                    try { openedWin.close(); } catch (e) { /* 忽略 */ }
                    openedWin = null;
                }
                post('close').catch(function () {});
                return;
            }
            if (openedWin) {
                startPing();
            }
        }).catch(function () {
            post('close').catch(function () {});
        }).then(function () {
            busy = false;
            refresh();
        });
    }

    function closeSecond() {
        busy = true;
        renderButton(true);
        if (openedWin) {
            try {
                openedWin.close();
            } catch (e) {
                /* 忽略 */
            }
            openedWin = null;
        }
        stopPing();
        post('close').then(function () {
            busy = false;
            refresh();
        }).catch(function () {
            busy = false;
            refresh();
        });
    }

    /* ---------------------------------------------------------------- 轮询 */

    /* 只在设置面板打开时查状态。
       noVNC 打开面板时会给 #noVNC_settings 加 noVNC_open 类，关掉时去掉，
       所以直接盯这个类的变化，不用改 noVNC 自己的代码。 */
    function startPolling() {
        if (pollTimer) {
            return;
        }
        refresh();
        pollTimer = setInterval(refresh, POLL);
    }

    function stopPolling() {
        if (pollTimer) {
            clearInterval(pollTimer);
            pollTimer = null;
        }
    }

    function watchPanel() {
        var panel = el('noVNC_settings');
        if (!panel) {
            return;
        }
        if (panel.classList.contains('noVNC_open')) {
            startPolling();
        }
        if (!window.MutationObserver) {
            return;
        }
        new MutationObserver(function () {
            if (panel.classList.contains('noVNC_open')) {
                startPolling();
            } else {
                stopPolling();
            }
        }).observe(panel, { attributes: true, attributeFilter: ['class'] });
    }

    /* ---------------------------------------------------------------- 启动 */

    function start() {
        if (isSecondView()) {
            /* 第二块屏：只负责心跳，让控制器知道这个视图还活着 */
            startPing();
            return;
        }

        var tries = 0;
        (function boot() {
            if (build()) {
                watchPanel();
                return;
            }
            if (++tries < 40) {
                setTimeout(boot, 250);
            }
        })();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
    } else {
        start();
    }
})();

/* ------------------------------------------------------------------ *
 * 连接保活（noVNC 自己没有心跳）
 *
 * RFB 协议没有 ping，noVNC 也不发周期性消息：屏幕静止、又没人动鼠标时，
 * 上下行可以长时间一个数据帧都没有。websockify 的 --heartbeat 发的是
 * WebSocket 控制帧（ping/pong），有些 NAT / 代理只认数据帧，链路会被
 * 当成空闲掐掉。
 *
 * 这里每 20s 把"最后一次鼠标位置"原样重发一次 PointerEvent：
 *   - 坐标和按键都没变，画面上完全看不出来；
 *   - 直接调 RFB 内部的 _sendMouse，绕开 DOM 事件，不会把控制条弹出来；
 *   - 只在已连接、且用户动过鼠标之后才发，不干扰拖拽。
 * 另外：从后台切回前台时，如果 noVNC 正在等重连（默认要等 5s），立刻重连。
 * ------------------------------------------------------------------ */
(function () {
    var KEEPALIVE_MS = 20000;

    function connectedRfb() {
        var r = (window.UI && window.UI.rfb) ? window.UI.rfb : null;
        if (!r) return null;
        if (r._rfbConnectionState !== 'connected') return null;
        return r;
    }

    setInterval(function () {
        try {
            var r = connectedRfb();
            if (!r || !r._mousePos || typeof r._sendMouse !== 'function') return;
            r._sendMouse(r._mousePos.x, r._mousePos.y, r._mouseButtonMask || 0);
        } catch (e) { /* 保活失败绝不能影响正常使用 */ }
    }, KEEPALIVE_MS);

    document.addEventListener('visibilitychange', function () {
        if (document.visibilityState !== 'visible') return;
        try {
            /* reconnectCallback 非空 = noVNC 已经发现断开、正在等下一次重试 */
            if (window.UI && UI.reconnectCallback) UI.reconnect();
        } catch (e) {}
    });
})();
DUALSTATE_JS

        python3 - "${root}/vnc.html" "${root}/vnc_auto.html" <<'DUALSTATE_PATCH'
import os
import sys

tag = '<script src="app/dualscreen-status.js"></script>'
for target in sys.argv[1:]:
    if not os.path.isfile(target):
        continue
    with open(target, encoding="utf-8") as fh:
        html = fh.read()
    if tag in html:
        print("  %s 里已有「双屏」设置，跳过" % target)
        continue
    pos = html.rfind("</body>")
    if pos < 0:
        print("  ⚠️ %s 找不到 </body>，没法插入" % target, file=sys.stderr)
        continue
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(html[:pos] + "    " + tag + "\n" + html[pos:])
    print("  已把「双屏」设置插入 %s" % target)
DUALSTATE_PATCH
    done
}

# ---- 5) 自检 ----
verify_desktop_audio() {
    echo "--- 音频链路自检 ---"
    local bad=0 u missing="" codec code sdp ans

    # (1) 虚拟声卡
    if runuser -u "${VNC_USER}" -- env HOME="${USER_HOME}" DISPLAY= \
            pactl list short sinks 2>/dev/null | grep -q "[[:space:]]${AUDIO_SINK}[[:space:]]"; then
        echo "  [1/5] 虚拟声卡 ${AUDIO_SINK} 存在 ✅"
    else
        echo "  [1/5] 虚拟声卡 ${AUDIO_SINK} 不存在 ❌"
        bad=1
    fi

    # (2) 三个服务
    for u in pulseaudio-vnc mediamtx; do
        systemctl is-active --quiet "${u}" || missing="${missing} ${u}"
    done
    if [ -z "${missing}" ]; then
        echo "  [2/5] 服务都在跑（pulseaudio-vnc / mediamtx；音频编码器按需拉起）✅"
    else
        echo "  [2/5] 没在跑：${missing} ❌"
        bad=1
    fi

    # (3) RTSP 里是不是 Opus（AAC 的话 WebRTC 侧会没声音，必须确认）
    if command -v ffprobe >/dev/null 2>&1; then
        codec=$(timeout 15 ffprobe -v error -rtsp_transport tcp -select_streams a:0 \
                -show_entries stream=codec_name -of csv=p=0 \
                "rtsp://127.0.0.1:${AUDIO_RTSP_PORT}/${AUDIO_PATH}" 2>/dev/null)
        if [ "${codec}" = "opus" ]; then
            echo "  [3/5] RTSP 音频编码 = opus ✅"
        else
            echo "  [3/5] RTSP 里读不到 opus（读到：${codec:-空}）❌"
            bad=1
        fi
    fi

    # (4) 页面里有没有播放器
    if grep -q "desktopAudioBar" "${NOVNC_WEB_ROOT}/vnc.html" 2>/dev/null \
       && [ -f "${NOVNC_WEB_ROOT}/app/desktop-audio.js" ]; then
        echo "  [4/5] vnc.html 已带「桌面声音」开关 ✅"
    else
        echo "  [4/5] vnc.html 里没有播放器 ❌"
        bad=1
    fi

    # (5) 经 nginx 的 /whep 能不能拿到 WebRTC 应答（顺手确认候选地址是公网 IP）
    if [ -f "${OR_DROPIN}" ] && command -v curl >/dev/null 2>&1; then
        sdp="/tmp/whep_selftest_$$.sdp"
        ans="/tmp/whep_selftest_$$.answer"
        cat > "${sdp}" <<'EOF_SELFTEST_SDP'
v=0
o=- 1 1 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
m=audio 9 UDP/TLS/RTP/SAVPF 111
c=IN IP4 0.0.0.0
a=ice-ufrag:selftest
a=ice-pwd:selftestselftestselftest
a=ice-options:trickle
a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
a=setup:actpass
a=mid:0
a=recvonly
a=rtcp-mux
a=rtpmap:111 opus/48000/2
a=fmtp:111 minptime=10;useinbandfec=1
EOF_SELFTEST_SDP
        code=$(curl -sk --max-time 10 -o "${ans}" -w '%{http_code}' -X POST \
                "https://127.0.0.1:$(pick_novnc_port)/whep" \
                -H 'Content-Type: application/sdp' --data-binary @"${sdp}" 2>/dev/null)
        _whep_pub=""
        if [ -r /etc/default/vnc-rtc ]; then
            _whep_pub=$(sed -n 's/^PUBLIC_IP=//p' /etc/default/vnc-rtc 2>/dev/null | tail -1)
        fi
        [ -n "${_whep_pub}" ] || _whep_pub="${AUDIO_PUBLIC_HOST}"

        if [ "${AUDIO_RTC_UNIT}" = "vnc-audio-rtc.service" ]; then
            if [ "${code}" = "200" ] && grep -q "opus/48000" "${ans}" 2>/dev/null \
               && grep -q "a=sendonly" "${ans}" 2>/dev/null; then
                echo "  [5/5] 经 nginx 的 /whep 拿到 vnc-audio-rtc 应答（HTTP 200，opus/sendonly）✅"
                if [ -n "${_whep_pub}" ]; then
                    if grep -q "${_whep_pub} ${AUDIO_RTC_ICE_PORT}" "${ans}" 2>/dev/null; then
                        echo "        候选地址里播报了 ${_whep_pub}:${AUDIO_RTC_ICE_PORT} ✅"
                    else
                        echo "        ⚠️ 候选地址里没看到 ${_whep_pub}:${AUDIO_RTC_ICE_PORT}，检查 /etc/default/vnc-rtc 的 PUBLIC_IP"
                    fi
                fi
            else
                echo "  [5/5] vnc-audio-rtc /whep 自检失败（HTTP ${code:-无响应}）❌"
                bad=1
            fi
        elif [ "${code}" = "201" ] && grep -q "opus/48000" "${ans}" 2>/dev/null; then
            echo "  [5/5] 经 nginx 的 /whep 拿到 WebRTC 应答（HTTP 201，opus）✅"
            if [ -n "${AUDIO_PUBLIC_HOST}" ]; then
                if grep -q "${AUDIO_PUBLIC_HOST} ${AUDIO_UDP_PORT}" "${ans}" 2>/dev/null; then
                    echo "        候选地址里播报了 ${AUDIO_PUBLIC_HOST}:${AUDIO_UDP_PORT} ✅"
                else
                    echo "        ⚠️ 候选地址里没看到 ${AUDIO_PUBLIC_HOST}:${AUDIO_UDP_PORT}，检查 AUDIO_PUBLIC_HOST"
                fi
            fi
        else
            echo "  [5/5] /whep 自检失败（HTTP ${code:-无响应}）❌"
            bad=1
        fi
        rm -f "${sdp}" "${ans}"
    else
        echo "  [5/5] 跳过（noVNC 站点还没配好）"
    fi

    echo
    if [ "${bad}" -eq 0 ]; then
        echo "🎧 容器侧全绿。剩下就是宿主机把 UDP ${AUDIO_UDP_PORT} 转进来，然后在页面上勾选「🔊 桌面声音」。"
    else
        echo "⚠️ 有项目没通过，按上面提示排查（journalctl -u pulseaudio-vnc / mediamtx）。"
    fi
    return "${bad}"
}

# ---- 6) 宿主机侧要做的端口转发（容器里没有 iptables，也不该有）----
audio_host_help() {
    local ip cur cur_backend
    cur="${AUDIO_BITRATE:-$(detect_installed_bitrate)}"
    cur_backend=$(sed -n 's/^AUDIO_BACKEND=\(go\|ffmpeg\)$/\1/p' \
                      /etc/default/vnc-audio-rtc 2>/dev/null | tail -1)
    ip=$(hostname -I 2>/dev/null | awk '{print $1}'); ip=${ip:-10.0.0.2}
    echo "------------------------------------------------------------"
    echo "音频码率：${cur:-未安装}（可选 ${AUDIO_BITRATE_MIN}k~${AUDIO_BITRATE_MAX}k，默认 ${AUDIO_BITRATE_DEFAULT}）"
    echo "  改法：bash $0 --audio-bitrate=256k --audio"
    echo "  实测膝点在 192~256k；带宽 192k≈200 / 256k≈272 / 320k≈357 kbit/s（单听众）"
    echo "音频后端：${cur_backend:-go}（go=进程内 PulseAudio+gopus，ffmpeg=外部 ffmpeg→RTP）"
    echo "  改法：编辑 /etc/default/vnc-audio-rtc 的 AUDIO_BACKEND，然后 systemctl restart vnc-audio-rtc"
    echo "------------------------------------------------------------"
    echo "容器内网地址：${ip}（上面命令里的 DNAT 目标）"
    echo "在【宿主机】上执行下面两条 —— 把 <公网网卡> 换成宿主机的公网网卡名"
    echo "（在宿主机上用 ip route show default 看，例如 ens3 / eth0）："
    echo
    echo "  iptables -t nat -A PREROUTING -i <公网网卡> -p udp --dport ${AUDIO_UDP_PORT} -j DNAT --to-destination ${ip}:${AUDIO_UDP_PORT}"
    echo "  iptables -A FORWARD -d ${ip}/32 -p udp --dport ${AUDIO_UDP_PORT} -j ACCEPT"
    echo
    echo "持久化（重启不丢）："
    echo "  apt-get install -y iptables-persistent && netfilter-persistent save"
    echo
    echo "验证（宿主机上抓包；同时在浏览器里勾选「桌面声音」，应看到有包进出）："
    echo "  tcpdump -ni any udp port ${AUDIO_UDP_PORT}"
    echo
    echo "注意：别把上面两条 iptables 写成反斜杠换行的多行命令 —— 反斜杠后面多一个空格就不是续行了。"
    echo "------------------------------------------------------------"
}

# ---- 总入口 ----
install_desktop_audio() {
    echo "=== 桌面真实声音（浏览器里能听到桌面在放什么）==="
    echo "    应用 -> 虚拟声卡 -> Opus -> pion WebRTC -> vnc.html（默认 go 后端）"
    echo

    resolve_audio_bitrate || return 1

    detect_openresty_paths

    if [ -z "${AUDIO_PUBLIC_HOST}" ]; then
        AUDIO_PUBLIC_HOST=$(detect_public_ip || true)
        [ -n "${AUDIO_PUBLIC_HOST}" ] \
            && echo "ℹ️ 探测到公网 IP：${AUDIO_PUBLIC_HOST}（会写进 WebRTC 候选地址）" \
            || echo "⚠️ 没探测到公网 IP（离线/被墙），稍后请用 AUDIO_PUBLIC_HOST=... 重跑"
    fi

    install_pulseaudio_virtual_sink || return 1
    install_mediamtx              || return 1
    install_desktop_audio_bridge  || return 1
    install_desktop_video        || return 1
    patch_novnc_desktop_audio
    patch_novnc_second_screen
    install_dualscreen_status

    # 让 nginx 的 /whep 反代生效（独立跑 --audio 时也要更新）
    if [ -f "${OR_DROPIN}" ]; then
        write_novnc_dropin "$(pick_novnc_port)"
        reload_openresty_safe || echo "⚠️ openresty 重载失败，请手动检查"
    fi

    sleep 4
    verify_desktop_audio || true

    echo
    echo "提示：桌面里已经在跑的程序（浏览器等）需要重启一次才会把声音送进虚拟声卡。"
    echo "     桌面上测试：audio 文件用 paplay 播，或在浏览器里放点声音。"
    echo
    echo "音量：桌面里保持 100%（默认就是），不要超 —— 超 100% 是数字放大，会在编码前"
    echo "     削波，属于不可逆硬失真。听感用浏览器右下角那个滑块调（它只影响你自己）。"
    echo "     图形界面：开始菜单 → 声音和视频 → PulseAudio 音量控制（或终端敲 pavucontrol）。"
    echo
    echo "码率：本次采用 ${AUDIO_BITRATE}（页面右下角会显示实时码率）。想改："
    echo "      bash $0 --audio-bitrate=256k --audio        # 重跑即可（也可 128k/320k）"
    echo "      或直接改 /etc/default/desktop-audio 里的 DESKTOP_AUDIO_BITRATE=..."
    echo "      （不用重启：下一个听众连上时按新码率拉起）"
    audio_host_help
}


# =======================================================
# 核心亮点：Systemd 级联服务流水线模板生成
# =======================================================
install_systemd_pipeline_units() {
    echo "--- 正在安装 Systemd 级联微服务架构 ---"

    mkdir -p ${VNC_CONF_DIR}

    # 1. 初始化分辨率独立配置文件 (默认 1920x1080)
    if [ ! -f "${VNC_CONF_DIR}/display-1.conf" ]; then
        cat > "${VNC_CONF_DIR}/display-1.conf" << 'EOF'
WIDTH=1920
HEIGHT=1080
DEPTH=24
# EXTRA_XVFB_ARGS=""
EOF
        chown -R ${VNC_USER}:${VNC_USER} ${VNC_CONF_DIR}
    fi

    # 确保 LXDE 会话配置（desktop.conf + 窗口管理器 + 会话自启动；统一由 helper 维护）
    mkdir -p "${USER_HOME}/.config/lxsession/LXDE"
    ensure_session_window_manager
    ensure_session_autostart
    setup_lxde_desktops
    chown -R ${VNC_USER}:${VNC_USER} "${USER_HOME}/.config"

    # 2. Xvfb 基础帧缓冲显存服务单元 (特定普通用户执行 + 独立日志)
    cat > /etc/systemd/system/xvfb@.service << EOF
[Unit]
Description=X Virtual Framebuffer Display Server on Display :%i
After=network.target

[Service]
Type=simple
User=${VNC_USER}
Group=${VNC_USER}
EnvironmentFile=-${USER_HOME}/.vnc/display-%i.conf
Environment=WIDTH=1920
Environment=HEIGHT=1080
Environment=DEPTH=24
ExecStartPre=-/bin/rm -f /tmp/.X%i-lock /tmp/.X11-unix/X%i
ExecStart=/usr/bin/Xvfb :%i -screen 0 \${WIDTH}x\${HEIGHT}x\${DEPTH} \$EXTRA_XVFB_ARGS
ExecStopPost=-/usr/local/bin/vnc-alert post-stop %n %i \$SERVICE_RESULT \$EXIT_CODE \$EXIT_STATUS
TimeoutStopSec=3
Restart=always
RestartSec=3
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF

    # 3. LXDE 桌面环境服务单元 (强绑定 BindsTo=xvfb)
    cat > /etc/systemd/system/vnc-desktop@.service << EOF
[Unit]
Description=LXDE Desktop Session on Display :%i
After=xvfb@%i.service network.target xvfb-mode@%i.service
Requires=xvfb@%i.service
BindsTo=xvfb@%i.service

[Service]
Type=simple
User=${VNC_USER}
Group=${VNC_USER}
WorkingDirectory=${USER_HOME}
Environment=DISPLAY=:%i
Environment=GTK_IM_MODULE=fcitx
Environment=QT_IM_MODULE=fcitx
Environment=XMODIFIERS=@im=fcitx
Environment=LC_ALL=zh_CN.UTF-8

# 等待 X11 Socket 出现就绪
ExecStartPre=/bin/sh -c 'TIMEOUT=50; while [ ! -S /tmp/.X11-unix/X%i ]; do sleep 0.2; TIMEOUT=\$((TIMEOUT-1)); if [ \$TIMEOUT -le 0 ]; then exit 1; fi; done'
# 禁用休眠、防黑屏
ExecStartPre=-/usr/bin/xset s off -dpms s noblank
ExecStart=/usr/bin/dbus-launch --exit-with-session /usr/bin/startlxde
TimeoutStopSec=3
Restart=always
RestartSec=3
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF

    # 4. x11vnc RFB 传输网络服务 (强绑定 BindsTo=xvfb)
    cat > /etc/systemd/system/x11vnc@.service << EOF
[Unit]
Description=x11vnc Server on Display :%i
After=xvfb@%i.service vnc-desktop@%i.service xvfb-mode@%i.service
Requires=xvfb@%i.service
BindsTo=xvfb@%i.service

[Service]
Type=simple
User=${VNC_USER}
Group=${VNC_USER}
Environment=DISPLAY=:%i
ExecStartPre=/bin/sh -c 'TIMEOUT=50; while [ ! -S /tmp/.X11-unix/X%i ]; do sleep 0.2; TIMEOUT=\$((TIMEOUT-1)); if [ \$TIMEOUT -le 0 ]; then exit 1; fi; done'
ExecStart=/usr/bin/x11vnc -display :%i -rfbport 590%i -forever -shared -rfbauth ${VNC_PASSWD_FILE}
ExecStartPost=-/usr/local/bin/vnc-alert post-start %n %i
ExecStopPost=-/usr/local/bin/vnc-alert post-stop %n %i \$SERVICE_RESULT \$EXIT_CODE \$EXIT_STATUS
SuccessExitStatus=2 15
TimeoutStopSec=3
Restart=always
RestartSec=3
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF

    # 拖动/缩放窗口不要线框：x11vnc 默认 -wireframe。
    # 单独加 drop-in 覆盖 ExecStart，10-defer.conf（-defer 20 -wait 20）保持原样。
    install -d /etc/systemd/system/x11vnc@.service.d
    cat > /etc/systemd/system/x11vnc@.service.d/20-nowireframe.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/bin/x11vnc -display :%i -rfbport 590%i -forever -shared -rfbauth ${VNC_PASSWD_FILE} -defer 20 -wait 20 -nowireframe
EOF

    # 5. WebSocket 网关：优先单进程 Go 代理（一个进程映射 6081/6082/6083），
    #    找不到 vnc-wsproxy/ payload 时回退到 websockify@.service（旧行为）。
    WS_BRIDGE_KIND="legacy"
    _wsproxy_payload="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/vnc-wsproxy/vnc-wsproxy"
    if [ -x "${_wsproxy_payload}" ]; then
        install -m 0755 "${_wsproxy_payload}" /usr/local/bin/vnc-wsproxy
        cat > /etc/systemd/system/vnc-wsproxy.service << EOF
[Unit]
Description=noVNC WebSocket to VNC TCP proxy (single process, multi-port)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vnc-wsproxy -map 127.0.0.1:6081=127.0.0.1:5901 -map 127.0.0.1:6082=127.0.0.1:5902 -map 127.0.0.1:6083=127.0.0.1:5903
Restart=always
RestartSec=3
TimeoutStopSec=5
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF
        systemctl disable --now websockify@1 websockify@2 >/dev/null 2>&1 || true
        WS_BRIDGE_KIND="single"
        echo "✅ WebSocket 网关：vnc-wsproxy（单进程，6081→5901 / 6082→5902 / 6083→5903）"
    else
        echo "⚠️ 未找到 vnc-wsproxy/vnc-wsproxy，回退到 websockify（每个显示一个进程）"
        cat > /etc/systemd/system/websockify@.service << EOF
[Unit]
Description=Websockify for Display :%i
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/websockify --heartbeat 30 127.0.0.1:608%i 127.0.0.1:590%i
TimeoutStopSec=3
Restart=always
RestartSec=3
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF
    fi
    if [ "${WS_BRIDGE_KIND}" = "single" ]; then
        WS_BRIDGE_UNIT="vnc-wsproxy.service"
    else
        WS_BRIDGE_UNIT="websockify@%i.service"
    fi

    # 6. 总调度 Target (一键启停全部级联节点)
    cat > /etc/systemd/system/vnc-stack@.target << EOF
[Unit]
Description=VNC Full Stack Pipeline for Display :%i
Wants=xvfb@%i.service vnc-desktop@%i.service ${WS_BRIDGE_UNIT} ${AUDIO_RTC_UNIT} mt5-watchdog@%i.service
After=xvfb@%i.service vnc-desktop@%i.service ${WS_BRIDGE_UNIT} ${AUDIO_RTC_UNIT} mt5-watchdog@%i.service

[Install]
WantedBy=multi-user.target
EOF

    # 7. MT5 智能守护 (强绑定桌面)
    cat > /etc/systemd/system/mt5-watchdog@.service << EOF
[Unit]
Description=MetaTrader 5 Auto-Recovery Watchdog on Display :%i
After=vnc-desktop@%i.service
Requires=vnc-desktop@%i.service
BindsTo=vnc-desktop@%i.service

[Service]
Type=simple
User=${VNC_USER}
Group=${VNC_USER}
Environment=DISPLAY=:%i
Environment=WINEPREFIX=${USER_HOME}/.wine
Environment=WINEDEBUG=-all
ExecStart=/bin/bash ${USER_HOME}/mt5_watchdog.sh
ExecStop=-/usr/bin/wineserver -k
ExecStopPost=-/usr/local/bin/vnc-alert mt5-service-stop %n %i \$SERVICE_RESULT \$EXIT_CODE \$EXIT_STATUS
TimeoutStopSec=3
Restart=always
RestartSec=5
OOMScoreAdjust=-900

[Install]
WantedBy=multi-user.target
EOF

    # 8. 分辨率热切换：路径单元（免 root 触发器） + 应用单元（root 执行）
    install_res_watch_units

    systemctl daemon-reload
    echo "✅ Systemd 级联服务单元部署就绪！"
}

# =======================================================
# 分辨率热切换的「免 root」通道
#   桌面工具只改写用户自己的 ~/.vnc/display-1.conf（本来就不需要特权），
#   vnc-res-watch.path 监听到文件变化 → 触发 vnc-res-apply@1.service（root）
#   → systemctl restart xvfb@1。这样桌面用户双击运行不再需要 sudo/密码。
# =======================================================
install_res_watch_units() {
    cat > /etc/systemd/system/vnc-res-apply@.service << EOF
[Unit]
Description=Apply VNC display resolution change for Display :%i
After=xvfb@%i.service

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart xvfb@%i
TimeoutStartSec=60
EOF

    cat > /etc/systemd/system/vnc-res-watch.path << EOF
[Unit]
Description=Watch ${USER_HOME}/.vnc/display-1.conf for resolution changes
After=xvfb@1.service

[Path]
# 用 PathChanged（写入并关闭后触发），不会读到写了一半的配置
PathChanged=${USER_HOME}/.vnc/display-1.conf
Unit=vnc-res-apply@1.service

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

setup_mt5_watchdog_script() {
    local watchdog_script="${USER_HOME}/mt5_watchdog.sh"

    cat > "${watchdog_script}" << 'EOF_WATCHDOG'
#!/bin/bash
export WINEPREFIX="${HOME}/.wine"
export WINEDEBUG=-all
export DISPLAY="${DISPLAY:-:1}"
DISP_NUM="${DISPLAY#:}"

find_mt5() {
    find "$WINEPREFIX/drive_c/Program Files" -maxdepth 3 -name "terminal64.exe" 2>/dev/null | head -n 1
}

get_pid() {
    pgrep -u "$(whoami)" -f "terminal64.exe" | head -n 1
}

LAST_PID=""
LAST_STATE="INIT"
LAST_LAUNCH_TIME=0

# 初始获取运行状态
CURRENT_PID=$(get_pid)
if [ -n "$CURRENT_PID" ]; then
    LAST_PID="$CURRENT_PID"
    LAST_STATE="RUNNING"
else
    LAST_STATE="STOPPED"
fi

while true; do
    CURRENT_PID=$(get_pid)

    if [ "$LAST_STATE" = "RUNNING" ]; then
        if [ -z "$CURRENT_PID" ]; then
            # 状态改变：MT5 关闭/退出/崩溃
            LAST_STATE="STOPPED"
            /usr/local/bin/vnc-alert mt5-exit "$DISP_NUM" "0" "用户手动关闭或意外终止" >/dev/null 2>&1 || true
            LAST_PID=""
        elif [ "$CURRENT_PID" != "$LAST_PID" ]; then
            # PID 发生变更
            /usr/local/bin/vnc-alert mt5-exit "$DISP_NUM" "0" "进程已终止更换" >/dev/null 2>&1 || true
            /usr/local/bin/vnc-alert mt5-restart "$DISP_NUM" "$CURRENT_PID" >/dev/null 2>&1 || true
            LAST_PID="$CURRENT_PID"
        fi
    elif [ "$LAST_STATE" = "STOPPED" ]; then
        if [ -n "$CURRENT_PID" ]; then
            # 状态改变：MT5 成功拉起就绪
            LAST_STATE="RUNNING"
            LAST_PID="$CURRENT_PID"
            /usr/local/bin/vnc-alert mt5-restart "$DISP_NUM" "$CURRENT_PID" >/dev/null 2>&1 || true
        else
            # MT5 处于未运行状态，执行自愈启动（带 10 秒防重复启动保护）
            NOW=$(date +%s)
            if [ $((NOW - LAST_LAUNCH_TIME)) -ge 10 ]; then
                LAST_LAUNCH_TIME=$NOW
                MT5_EXE=$(find_mt5)
                if [ -n "$MT5_EXE" ] && [ -f "$MT5_EXE" ]; then
                    wine-stable "$MT5_EXE" >/dev/null 2>&1 &
                fi
            fi
        fi
    fi

    sleep 2
done
EOF_WATCHDOG

    chmod +x "${watchdog_script}"
    chown ${VNC_USER}:${VNC_USER} "${watchdog_script}"
}

create_pipeline_res_tool() {
    local tool_path="${DESKTOP_DIR}/切换分辨率(Systemd版).sh"

    cat > "${tool_path}" << 'EOF_TOOL'
#!/bin/bash
# ------------------------------------------------------------------
# 分辨率热切换工具（免 root 版）
#   1) 只改写用户自己的 ~/.vnc/display-1.conf —— 本来就不需要特权
#   2) systemd 路径单元 vnc-res-watch.path 监听到文件变化后，
#      由 root 执行 vnc-res-apply@1.service → systemctl restart xvfb@1
#   双击运行不再需要 sudo / 密码。
# ------------------------------------------------------------------
CONF="/home/CURRENT_VNC_USER_PLACEHOLDER/.vnc/display-1.conf"

# 双击（没有终端）时自动用 lxterminal 重新打开自己，保证能选菜单、能看到结果
if [ ! -t 0 ] || [ ! -t 1 ]; then
    if command -v lxterminal >/dev/null 2>&1; then
        exec lxterminal --title="切换分辨率" -e "bash \"$0\""
    fi
    echo "⚠️ 请在终端中运行本脚本（右键 → 在终端中执行）"
    sleep 5
    exit 1
fi

clear
echo "=== Systemd 级联服务架构 - 分辨率切换工具 ==="
echo " [1] 1920 x 1080 (1080P 标准全高清)"
echo " [2] 1280 x 720  (720P 极简省流)"
echo " [3] 2560 x 1440 (2K 横屏)"
echo " [4] 1080 x 1920 (手机竖屏)"
echo " [5] 1440 x 2560 (2K 竖屏)"
echo " [6] 2560 x 2880 (超大方屏 / MT5 多图表神器)"
echo " [7] 2550 x 2715 (定制专属大方屏)"
read -p "请选择分辨率 [1-7]: " res_c

case $res_c in
    2) W=1280; H=720 ;;
    3) W=2560; H=1440 ;;
    4) W=1080; H=1920 ;;
    5) W=1440; H=2560 ;;
    6) W=2560; H=2880 ;;
    7) W=2550; H=2715 ;;
    *) W=1920; H=1080 ;;
esac

cat > "$CONF" << EOF
WIDTH=$W
HEIGHT=$H
DEPTH=24
# EXTRA_XVFB_ARGS=""
EOF

echo ""
echo "⚙️ 分辨率已保存为 ${W}x${H}。"
if systemctl is-active --quiet vnc-res-watch.path 2>/dev/null; then
    echo "🔄 已通过 systemd 路径单元下发重启指令（无需密码）。"
    echo "✅ 请 3-5 秒后刷新 noVNC 网页：桌面会话会短暂重启，属于正常现象。"
else
    echo "⚠️ 未检测到 vnc-res-watch.path，请手动执行: sudo systemctl restart xvfb@1"
fi
sleep 2
EOF_TOOL

    sed -i "s/CURRENT_VNC_USER_PLACEHOLDER/${VNC_USER}/g" "${tool_path}"
    chmod +x "${tool_path}"
    chown ${VNC_USER}:${VNC_USER} "${tool_path}"
}

create_edge_tool() {
    echo "--- 生成 Edge 控制工具 ---"
    # wmctrl/xdotool [1] 已装；单独跑本步时才补装（不再白等一次 apt update）
    ensure_pkgs wmctrl xdotool
    local tool_path="${DESKTOP_DIR}/重置Edge窗口.sh"

    cat > "${tool_path}" << 'EOF'
#!/bin/bash
if [ "$EUID" -eq 0 ]; then su - CURRENT_VNC_USER_PLACEHOLDER -c "bash $0"; exit; fi
export DISPLAY=:1
if ! pgrep -f "msedge" > /dev/null; then
    microsoft-edge --disable-gpu --no-first-run --no-default-browser-check &
    sleep 3
fi
SCREEN_W=$(xdotool getdisplaygeometry | awk '{print $1}')
SCREEN_H=$(xdotool getdisplaygeometry | awk '{print $2}')
echo "1. 手机模式 (500x900)"
echo "2. 影院模式 (1920x1080)"
echo "3. 网页全览"
read -p "选择: " l
case $l in
    1) W=500; H=900; X=$(( (SCREEN_W - W) / 2 )); Y=100 ;;
    2) W=1920; H=1080; X=$(( (SCREEN_W - W) / 2 )); Y=$(( (SCREEN_H - H) / 2 )) ;;
    *) W=$(( SCREEN_W - 40 )); H=$(( SCREEN_H - 100 )); X=20; Y=40 ;;
esac
wmctrl -r "Microsoft Edge" -b remove,maximized_vert,maximized_horz
wmctrl -r "Microsoft Edge" -e 0,$X,$Y,$W,$H
wmctrl -a "Microsoft Edge"
EOF

    sed -i "s/CURRENT_VNC_USER_PLACEHOLDER/${VNC_USER}/g" "${tool_path}"
    chmod +x "${tool_path}"
    chown ${VNC_USER}:${VNC_USER} "${tool_path}"
    echo "✅ Edge 控制工具已生成至桌面: ${tool_path}"
}

install_gost_ipv6() {
    echo "--- 正在安装 Gost 隧道代理 (Systemd 微服务版) ---"
    local gost_dir="/opt/gost"
    mkdir -p "${gost_dir}"

    if [ ! -f "${gost_dir}/gost" ]; then
        echo "⬇️ 正在下载 Gost 核心二进制..."
        cd /tmp
        wget -q --show-progress "https://github.com/ginuerzh/gost/releases/download/v2.12.0/gost_2.12.0_linux_amd64.tar.gz" -O gost.tar.gz || {
            echo "❌ Gost 下载失败，请检查网络连接。"
            return 1
        }
        tar -xzf gost.tar.gz
        mv gost "${gost_dir}/gost"
        chmod +x "${gost_dir}/gost"
        rm -f gost.tar.gz
    fi

    echo "⚙️ 配置 Gost 连接参数："
    read -p "用户名 [回车默认: user]: " U; U=${U:-user}
    read -p "密码 [回车默认: pass]: " P; P=${P:-pass}
    read -p "端口 [回车默认: 443]: " PO; PO=${PO:-443}

    # 平稳接管：若曾有 supervisor 配置则关闭以避免端口冲突
    if [ -f /etc/supervisor/conf.d/gost.conf ]; then
        echo "ℹ️ 检测到旧版 Supervisor 中的 gost 配置，正在平滑迁移至 Systemd..."
        supervisorctl stop gost 2>/dev/null || true
        mv /etc/supervisor/conf.d/gost.conf /etc/supervisor/conf.d/gost.conf.bak 2>/dev/null || true
        supervisorctl update 2>/dev/null || true
    fi

    # 创建标准 Systemd 服务单元
    cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=GOST Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=${gost_dir}/gost -L "mwss://${U}:${P}@[:]:${PO}"
WorkingDirectory=${gost_dir}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost
    systemctl restart gost
    echo "=========================================================="
    echo "✅ Gost 隧道服务已成功以 Systemd 微服务形式启动！"
    echo "   协议链接: mwss://${U}:${P}@[:]:${PO}"
    echo "   状态查看: systemctl status gost"
    echo "=========================================================="
}


# ---------------------------------------------------------------- new_vnc 后端

choose_ws_backend() {
    if [ -z "${WS_BACKEND}" ]; then
        WS_BACKEND=$(cat /etc/vnc-ws/backend 2>/dev/null || true)
    fi
    if [ -z "${WS_BACKEND}" ]; then
        if [ -t 0 ] && [ -t 1 ]; then
            echo "new_vnc（WebSocket 通道，5901/5902）用哪个 VNC 服务端？"
            echo "  1) x11vnc（默认：双屏开/关稳定，运行时裁剪无缝）"
            echo "  2) TigerVNC（更高效：ContinuousUpdates + 剪贴板；但开关第二块屏会花屏，暂不推荐）"
            while true; do
                if ! read -r -p "  选择 [1/2]（默认 1）: " a; then
                    echo
                    a=1
                fi
                a="${a:-1}"
                case "$a" in
                    1) WS_BACKEND=x11vnc; break ;;
                    2) WS_BACKEND=tigervnc; break ;;
                    *) echo "  只支持 1 / 2" ;;
                esac
            done
        else
            WS_BACKEND=x11vnc
            echo "ℹ️ 非交互模式：new_vnc 后端用 x11vnc（WS_BACKEND=tigervnc 可改，但双屏会花屏）"
        fi
    fi
    case "${WS_BACKEND}" in
        tigervnc|x11vnc) ;;
        *)
            echo "⚠️ WS_BACKEND=${WS_BACKEND} 不支持（只认 tigervnc / x11vnc），按 x11vnc 处理"
            WS_BACKEND=x11vnc
            ;;
    esac
}

install_ws_tigervnc() {
    local ver=1.16.2
    local dir="/opt/tigervnc-${ver}"
    if [ ! -x "${dir}/bin/x0vncserver" ]; then
        echo "--- 安装 TigerVNC ${ver}（Debian 12 自带的 1.12 没有剪贴板）---"
        local url="https://sourceforge.net/projects/tigervnc/files/stable/${ver}/tigervnc-${ver}.x86_64.tar.gz/download"
        local tmp sum
        tmp=$(mktemp -d)
        if ! curl -fsSL --retry 2 --max-time 300 -o "${tmp}/tv.tar.gz" "${url}"; then
            rm -rf "${tmp}"
            echo "⚠️ TigerVNC 下载失败"
            return 1
        fi
        sum=$(sha256sum "${tmp}/tv.tar.gz" | awk '{print $1}')
        if [ "${sum}" != "5b70c84baefc09a030cfc78315c34ccb55b2a0dde4092b7da67a1962c5f0dea6" ]; then
            rm -rf "${tmp}"
            echo "⚠️ TigerVNC 校验和不匹配：${sum}"
            return 1
        fi
        install -d "${dir}"
        tar xzf "${tmp}/tv.tar.gz" -C "${dir}" --strip-components=2
        rm -rf "${tmp}"
        [ -x "${dir}/bin/x0vncserver" ] || { echo "⚠️ 解压后没有 x0vncserver"; return 1; }
    fi

    install -d /etc/vnc-ws
    [ -f /etc/vnc-ws/main-geometry ] || echo "1920x1080+0+0" > /etc/vnc-ws/main-geometry
    [ -f /etc/vnc-ws/second-geometry ] || echo "1920x1080+0+0" > /etc/vnc-ws/second-geometry
    echo tigervnc > /etc/vnc-ws/backend

    install -m 0755 /dev/stdin /usr/local/bin/x0vnc-view <<'X0VIEW'
#!/bin/sh
# 通用 TigerVNC 抓屏实例入口：x0vnc-view <端口> <几何文件> <桌面名>
#
# 与 x11vnc 通道完全独立，只读同一个 X display。几何在启动时定死，
# 改几何 = 改文件 + 重启对应 unit（screen2ctl 负责）。
#
# 必须 >= 1.15：1.12（Debian 12 自带）没有剪贴板重定向。
#
# -AcceptSetDesktopSize=0 是硬要求：TigerVNC 默认允许客户端改桌面尺寸，
# 第二块屏的浏览器一缩放就会发 SetDesktopSize，把 X 根窗口改掉，
# 首屏（5901）/RTC（5903）的裁剪几何立刻失效 → 花屏/黑块。
# 布局只由 screen2ctl 管，客户端不许改。
# 二进制定在 /opt/tigervnc-<ver>/bin/x0vncserver，由安装脚本下载。
PORT=$1
GEOMFILE=$2
NAME=$3
GEOM=$(cat "$GEOMFILE" 2>/dev/null || true)
for BIN in /opt/tigervnc-1.16.2/bin/x0vncserver \
           /opt/tigervnc-1.15/bin/x0vncserver \
           /usr/bin/X0tigervnc; do
    [ -x "$BIN" ] && break
done
exec "$BIN" \
    -display :1 \
    -rfbport "$PORT" \
    -rfbauth /home/vncuser1/.vnc/passwd \
    -AlwaysShared \
    -FrameRate 30 \
    -AcceptSetDesktopSize=0 \
    -desktop "$NAME" \
    ${GEOM:+-Geometry "$GEOM"}
X0VIEW
    install -m 0755 /dev/stdin /usr/local/bin/x0vnc-ws-main <<'WSMAIN'
#!/bin/sh
# /new_vnc（WebSocket 通道）主视图的 TigerVNC（端口 5901）。
# 几何由 screen2ctl 写 /etc/vnc-ws/main-geometry 并重启本 unit。
exec /usr/local/bin/x0vnc-view 5901 /etc/vnc-ws/main-geometry vncuser1
WSMAIN
    install -m 0755 /dev/stdin /usr/local/bin/x0vnc-ws-second <<'WSSECOND'
#!/bin/sh
# /new_vnc 第二块屏的 TigerVNC（端口 5902），由 screen2ctl 按需启动。
exec /usr/local/bin/x0vnc-view 5902 /etc/vnc-ws/second-geometry vncuser1-2
WSSECOND
    cat > /etc/systemd/system/x0vnc-ws.service <<'WSUNIT'
[Unit]
Description=TigerVNC scraping server for the WebSocket channel (port 5901)
After=vnc-desktop@1.service
Wants=vnc-desktop@1.service

[Service]
Type=simple
Environment=DISPLAY=:1
ExecStart=/usr/local/bin/x0vnc-ws-main
Restart=always
RestartSec=2
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
WSUNIT
    cat > /etc/systemd/system/x0vnc-ws-second.service <<'WSUNIT2'
[Unit]
Description=TigerVNC second-screen server for the WebSocket channel (port 5902, on demand)
After=vnc-desktop@1.service x0vnc-ws.service
Wants=vnc-desktop@1.service

[Service]
Type=simple
Environment=DISPLAY=:1
ExecStart=/usr/local/bin/x0vnc-ws-second
Restart=always
RestartSec=2
LimitNOFILE=4096
WSUNIT2

    systemctl daemon-reload
    systemctl disable --now x11vnc@1 >/dev/null 2>&1 || true
    systemctl enable x0vnc-ws >/dev/null 2>&1 || true
    systemctl stop x0vnc-ws-second >/dev/null 2>&1 || true
    if systemctl is-active --quiet vnc-desktop@1 2>/dev/null; then
        systemctl restart x0vnc-ws >/dev/null 2>&1 || true
    fi
    return 0
}

setup_ws_backend() {
    choose_ws_backend
    install -d /etc/systemd/system/vnc-stack@.target.d
    if [ "${WS_BACKEND}" = "tigervnc" ]; then
        if install_ws_tigervnc; then
            cat > /etc/systemd/system/vnc-stack@.target.d/50-ws-backend.conf <<'BACKEND'
[Unit]
Wants=x0vnc-ws.service
After=x0vnc-ws.service
BACKEND
            systemctl daemon-reload
            echo "✅ new_vnc 后端：TigerVNC（5901/5902，ContinuousUpdates + 剪贴板）"
            return 0
        fi
        echo "⚠️ TigerVNC 装不上，本次退回 x11vnc"
        WS_BACKEND=x11vnc
    fi

    install -d /etc/vnc-ws
    echo x11vnc > /etc/vnc-ws/backend
    cat > /etc/systemd/system/vnc-stack@.target.d/50-ws-backend.conf <<'BACKEND'
[Unit]
Wants=x11vnc@%i.service
After=x11vnc@%i.service
BACKEND
    systemctl disable --now x0vnc-ws x0vnc-ws-second >/dev/null 2>&1 || true
    systemctl enable x11vnc@1 >/dev/null 2>&1 || true
    systemctl daemon-reload
    if systemctl is-active --quiet vnc-desktop@1 2>/dev/null; then
        systemctl restart x11vnc@1 >/dev/null 2>&1 || true
    fi
    echo "✅ new_vnc 后端：x11vnc（5901/5902）"
}

activate_pipeline_services() {
    echo "--- 配置 VNC 密码与启动级联服务 ---"

    ensure_vnc_password

    setup_mt5_watchdog_script
    create_pipeline_res_tool

    # 启动前再加固一次（面板/菜单/锁屏入口），保证新会话起来即是加固后的样子
    harden_desktop_session

    # 平稳过渡：停止并禁用旧版单体服务 (防止显示号 :1 与 5901 冲突)
    if systemctl is-active vnc-server >/dev/null 2>&1 || systemctl is-enabled vnc-server >/dev/null 2>&1; then
        echo "🛑 正在平稳过渡：停止并注销旧版 vnc-server 服务..."
        systemctl stop vnc-server 2>/dev/null || true
        systemctl disable vnc-server 2>/dev/null || true
        pkill -u ${VNC_USER} -f "start_vnc_boot.sh" 2>/dev/null || true
    fi

    # 启用全部级联服务单元（VNC 服务端由 setup_ws_backend 按选择启用/禁用）
    if [ "${WS_BRIDGE_KIND}" = "single" ]; then BRIDGE_ENABLE="vnc-wsproxy"; else BRIDGE_ENABLE="websockify@1"; fi
    systemctl enable xvfb@1 vnc-desktop@1 "${BRIDGE_ENABLE}" vnc-stack@1.target mt5-watchdog@1 2>/dev/null || true
    # noVNC 自己的第二块屏（/vnc2）：控制器 + 第二台 x11vnc + websockify@2
    install_second_screen_control
    # new_vnc 的 VNC 服务端：TigerVNC（默认）或 x11vnc
    setup_ws_backend
    systemctl restart vnc-stack@1.target

    # 起来后校验窗口管理器：没有它，桌面里所有窗口都会缺标题栏/关闭按钮
    local _wm_pid="" _i
    for _i in $(seq 1 20); do
        _wm_pid=$(pgrep -u ${VNC_USER} -f 'openbox' 2>/dev/null | head -1 || true)
        [ -n "${_wm_pid}" ] && break
        sleep 0.5
    done
    if [ -n "${_wm_pid}" ]; then
        echo "✅ 窗口管理器 (openbox, pid ${_wm_pid}) 已在运行"
    else
        echo "⚠️ 未检测到窗口管理器进程：窗口会没有标题栏与关闭按钮。"
        echo "   请检查 ${USER_HOME}/.config/lxsession/LXDE/desktop.conf 是否有 window_manager=openbox-lxde"
    fi

    # 分辨率热切换的免 root 通道（单元模板已由 install_systemd_pipeline_units 写好并 reload）
    systemctl enable vnc-res-watch.path 2>/dev/null || true
    systemctl restart vnc-res-watch.path 2>/dev/null || true

    echo "=========================================================="
    echo "✅ Systemd 级联服务流水线已激活并开机自启！"
    echo "   - xvfb@1.service         (虚拟显存)"
    echo "   - vnc-desktop@1.service  (LXDE 桌面环境)"
    echo "   - x11vnc@1.service       (VNC 传输协议)"
    if [ "${WS_BRIDGE_KIND}" = "single" ]; then
        echo "   - vnc-wsproxy.service   (单进程 WebSocket 网关：6081/6082/6083)"
    else
        echo "   - websockify@1.service   (WebSocket 网页桥接)"
    fi
    echo "   - mt5-watchdog@1.service (MT5 7*24 自动自愈)"
    echo "   - vnc-res-watch.path     (分辨率热切换：桌面免密码触发)"
    echo "=========================================================="

    # 收尾顺手打理磁盘（清 apt 索引缓存 + 给日志设上限）
    housekeeping_disk
}

# -------------------------------------------------------
# 账号密码一览（菜单 [11] / --show-credentials）
# -------------------------------------------------------
print_credentials() {
    local u dp vp ip state
    u=$(cred_get VNC_USER); u=${u:-${VNC_USER}}
    dp=$(cred_get DESKTOP_PASS)
    vp=$(cred_get VNC_PASS)
    ip=$(hostname -I 2>/dev/null | awk '{print $1}'); ip=${ip:-<服务器IP>}

    echo "=========================================================="
    echo "                 🖥️  桌面 / VNC 账号密码"
    echo "=========================================================="
    echo " 桌面运行用户 (Linux) : ${u}"
    if [ -n "${dp}" ]; then
        echo " 桌面用户密码         : ${dp}"
    else
        echo " 桌面用户密码         : （未记录 —— 用下方 [1] 重设）"
    fi
    if id "${u}" &>/dev/null; then
        state=$(passwd -S "${u}" 2>/dev/null | awk '{print $2}')
        if [ "${state}" = "P" ]; then
            echo "   └ 实时核对: 账户存在，密码可用 ✅"
        else
            echo "   └ 实时核对: 账户存在，但密码不可用 ⚠️（用下方 [1] 设置）"
        fi
    else
        echo "   └ 实时核对: 账户不存在 ⚠️"
    fi
    echo "   用途: sudo / 本地登录；与 VNC 连接密码不是一回事。"
    echo
    echo " VNC 连接用户         : ${u}   （x11vnc 只认证密码，没有独立用户名）"
    if [ -n "${vp}" ]; then
        echo " VNC 连接密码         : ${vp}"
    else
        echo " VNC 连接密码         : （未记录 —— 用下方 [2] 重设）"
    fi
    if [ -f "${VNC_PASSWD_FILE}" ]; then
        echo "   └ 密码文件: ${VNC_PASSWD_FILE} （存在）"
    else
        echo "   └ 密码文件: ${VNC_PASSWD_FILE} （缺失，用下方 [2] 生成）"
    fi
    echo "   注意: VNC 协议密码上限 8 位，超出部分无效。"
    echo
    local vurl="https://<你的服务器公网IP>/vnc1"
    detect_openresty_paths
    if [ -f "${OR_DROPIN}" ]; then
        local vp_port
        vp_port=$(grep -oE 'listen[[:space:]]+[0-9]+' "${OR_DROPIN}" 2>/dev/null | head -1 | grep -oE '[0-9]+')
        [ -n "${vp_port}" ] && [ "${vp_port}" != "443" ] && vurl="https://<你的服务器公网IP>:${vp_port}/vnc1"
    fi
    echo " 访问地址             : ${vurl}"
    # 若已按 README 附录把 noVNC 挂到现有 443 站点的 /novnc/，顺手提示同端口入口
    if grep -rqsE 'include[[:space:]]+[^;]*novnc-proxy\.inc' "${OR_CONF_DIR}" 2>/dev/null; then
        echo "   └ 443 上也可用（已挂 /novnc/ 反代）: https://<你的服务器公网IP>/vnc1"
    fi
    echo "   └ 本机 IP: ${ip}（容器/内网地址，仅供参考；自签证书需点「继续访问」）"
    if [ -f "${CRED_FILE}" ]; then
        echo " 凭据记录文件         : ${CRED_FILE} (权限 $(stat -c %a "${CRED_FILE}" 2>/dev/null))"
    else
        echo " 凭据记录文件         : ${CRED_FILE} (尚未生成)"
    fi
    echo "=========================================================="
}

show_credentials() {
    local c cur
    while true; do
        clear
        print_credentials
        echo " [1] 重设桌面用户密码    [2] 重设 VNC 连接密码    [0] 返回"
        read -p "请选择: " c
        cur=$(cred_get VNC_USER); cur=${cur:-${VNC_USER}}
        case "${c}" in
            1)
                VNC_USER="${cur}"; update_variables
                set_desktop_password || true
                read -p "按回车返回..." _
                ;;
            2)
                VNC_USER="${cur}"; update_variables
                set_vnc_password || true
                read -p "按回车返回..." _
                ;;
            *) return 0 ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        echo "=== Debian 12 VNC (Systemd 级联服务微服务版) ==="
        echo "当前运行用户: ${VNC_USER} (已隔离)"
        echo "--------------------------------------------------"
        echo " [1] 初始化系统环境 (中文语言/用户隔离/LXC检查)"
        echo " [2] 安装 LXDE 桌面核心"
        echo " [3] 安装 Wine 环境"
        echo " [4] 安装 Edge 浏览器"
        echo " [5] 安装 HTTPS (OpenResty+NoVNC)"
        echo " [6] 安装并激活 Systemd 级联服务流水线 (推荐)"
        echo " [7] 生成 Edge 控制工具 (桌面快捷)"
        echo " [8] 安装 Gost 隧道代理 (Systemd 微服务版)"
        echo " [9] 查看各微服务运行状态 (systemctl)"
        echo " [10] 屏蔽桌面「注销/关机/屏幕锁」(桌面加固)"
        echo " [11] 查看 / 重设 桌面与 VNC 账号密码"
        echo " [12] 清理安装缓存与日志 (省磁盘)"
        echo " [13] 安装桌面真实声音 (虚拟声卡 -> WebRTC，浏览器里可听)"
        echo " [99] 停止所有服务 (VNC级联与Gost)"
        echo " [0] 退出"
        read -p "选项: " c
        case $c in
            1) setup_system_and_user_and_locale ;;
            2) install_lxde_desktop ;;
            3) install_wine_env ;;
            4) install_edge_browser ;;
            5) install_novnc_and_openresty ;;
            6) 
                install_systemd_pipeline_units
                activate_pipeline_services
                ;;
            7) create_edge_tool ;;
            8) install_gost_ipv6 ;;
            9) 
                systemctl status xvfb@1 vnc-desktop@1 x11vnc@1 "$(bridge_service_name)" mt5-watchdog@1 vnc-res-watch.path gost --no-pager
                ;;
            99) 
                systemctl stop vnc-stack@1.target xvfb@1 vnc-desktop@1 x11vnc@1 "$(bridge_service_name)" mt5-watchdog@1 gost 2>/dev/null || true
                echo "已停止所有服务。"
                ;;
            10)
                harden_desktop_session
                echo "🔄 正在重启桌面会话以让面板配置生效..."
                systemctl restart vnc-desktop@1 2>/dev/null || true
                ;;
            11) show_credentials ;;
            12) housekeeping_disk ;;
            13) install_desktop_audio ;;
            0) exit 0 ;;
        esac
        read -p "按回车继续..."
    done
}

check_root

# ---- 通用前置参数解析：--audio-bitrate=<码率>[k] / --audio-backend=go|ffmpeg ----
#   bash 本脚本 --audio-bitrate=256k --audio-backend=go --audio
#   码率不给就用交互询问 / 已装值 / 默认 192k（见 resolve_audio_bitrate）；
#   后端不给就沿用已装值 / 默认 go（见 install_desktop_audio_bridge）。
_argv=()
while [ $# -gt 0 ]; do
    case "$1" in
        --audio-bitrate=*) AUDIO_BITRATE="${1#*=}" ;;
        --audio-bitrate)   AUDIO_BITRATE="${2:-}"; shift ;;
        --audio-backend=*) AUDIO_BACKEND="${1#*=}" ;;
        --audio-backend)   AUDIO_BACKEND="${2:-}"; shift ;;
        *) _argv+=("$1") ;;
    esac
    shift
done
set -- ${_argv[@]+"${_argv[@]}"}

# 模块入口不再询问桌面运行用户，只按默认/当前 VNC_USER 初始化派生路径
# （USER_HOME、.vnc、Desktop 等，供 [3]-[8] 使用）。
# 桌面运行用户 + 密码：由 [1] / [2] 调用 ensure_desktop_user_and_password 统一处理，
# 只设置一次（记录在 /root/.vnc-desktop-credentials）；查看/重设见菜单 [11]。
update_variables

# 非交互入口：--harden [用户名]
#   仅执行桌面加固（屏蔽注销/关机/屏幕锁），供脚本化调用或事后补做
if [ "${1:-}" = "--harden" ]; then
    check_root
    if [ -n "${2:-}" ]; then
        VNC_USER="$2"
        update_variables
    fi
    harden_desktop_session
    exit 0
fi

# 非交互入口：--res-tool [用户名]
#   安装/刷新分辨率热切换的免 root 通道（vnc-res-watch.path）并重新生成桌面工具
if [ "${1:-}" = "--res-tool" ]; then
    check_root
    if [ -n "${2:-}" ]; then
        VNC_USER="$2"
        update_variables
    fi
    install_res_watch_units
    create_pipeline_res_tool
    systemctl enable vnc-res-watch.path 2>/dev/null || true
    systemctl restart vnc-res-watch.path 2>/dev/null || true
    echo "✅ 免 root 分辨率通道就绪：vnc-res-watch.path"
    echo "✅ 桌面工具已刷新：${DESKTOP_DIR}/切换分辨率(Systemd版).sh"
    exit 0
fi

# 非交互入口：--show-credentials [用户名]
#   打印桌面运行用户 / 密码 与 VNC 连接用户 / 密码（读取 /root/.vnc-desktop-credentials）
if [ "${1:-}" = "--show-credentials" ]; then
    check_root
    _u=$(cred_get VNC_USER); [ -n "${_u}" ] && VNC_USER="${_u}"
    [ -n "${2:-}" ] && VNC_USER="$2"
    update_variables
    print_credentials
    exit 0
fi

# 非交互入口：--audio [用户名]
#   一键装好整条桌面音频链路（虚拟声卡 -> Opus -> MediaMTX -> WHEP -> vnc.html）
#   可选：AUDIO_PUBLIC_HOST=<公网IP/域名>  bash 本脚本 --audio
#   可选：--audio-bitrate=256k  （默认 192k；已装过且没指定时沿用已装值，不会被默默改掉）
#   可选：MEDIAMTX_VERSION=v1.21.2
if [ "${1:-}" = "--audio" ]; then
    check_root
    [ -n "${2:-}" ] && VNC_USER="$2"
    update_variables
    install_desktop_audio
    exit $?
fi

# 非交互入口：--audio-help [用户名]
#   只打印宿主机侧需要做的 UDP 端口转发命令（不改动系统）
if [ "${1:-}" = "--audio-help" ]; then
    [ -n "${2:-}" ] && VNC_USER="$2"
    update_variables
    audio_host_help
    exit 0
fi

# 非交互入口：--novnc-patch
#   只重打 1.3.0 老站点页面的三个补丁（剪贴板 UTF-8 / HiDPI / 桌面音频条），
#   不动 nginx、不装包。novnc 包升级覆盖了 core/rfb.js、app/ui.js、vnc.html 之后跑它即可。
if [ "${1:-}" = "--novnc-patch" ]; then
    check_root
    update_variables
    patch_novnc_utf8_clipboard
    patch_novnc_expose_ui
    patch_novnc_hidpi
    patch_novnc_desktop_audio
    patch_novnc_second_screen
    install_dualscreen_status
    echo "✅ 1.3.0（${NOVNC_WEB_ROOT}）页面补丁已重打；浏览器 Ctrl+F5 生效"
    exit 0
fi

# 非交互入口：--novnc-web
#   只刷新 noVNC 站点的 nginx 配置（是否生成 /new_vnc，取决于
#   ${NOVNC_NEW_WEB_ROOT} 是否存在；由 scripts/novnc_new_deploy.sh 负责铺文件）。
#   写完后先 nginx -t，不通过自动回滚，绝不让线上站点起不来。
if [ "${1:-}" = "--novnc-web" ]; then
    check_root
    update_variables
    if [ ! -f "${OR_DROPIN}" ]; then
        echo "❌ 还没装过 noVNC 站点（缺 ${OR_DROPIN}）；先完整跑一次安装或 --audio"
        exit 1
    fi
    _listen_port=$(grep -m1 -oE '^[[:space:]]*listen[[:space:]]+[0-9]+' "${OR_DROPIN}" | awk '{print $2}')
    _listen_port="${_listen_port:-443}"
    if [ -d "${NOVNC_NEW_WEB_ROOT}" ]; then
        echo "ℹ️ 刷新 nginx 配置：listen ${_listen_port}，/new_vnc 启用（${NOVNC_NEW_VERSION} @ ${NOVNC_NEW_WEB_ROOT}）"
    else
        echo "ℹ️ 刷新 nginx 配置：listen ${_listen_port}，/new_vnc 未启用（缺 ${NOVNC_NEW_WEB_ROOT}）"
    fi
    write_novnc_dropin "${_listen_port}" || exit 1
    reload_openresty_safe || exit 1
    exit 0
fi

main_menu

