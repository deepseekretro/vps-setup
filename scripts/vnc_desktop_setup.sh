#!/bin/bash

# =======================================================
# 🚀 Debian 12 VNC - Systemd 级联服务架构版 (Pipeline Edition)
# 核心架构：
#   - xvfb@.service        (虚拟帧缓冲显存服务)
#   - vnc-desktop@.service (LXDE 桌面会话，BindsTo=xvfb)
#   - x11vnc@.service      (VNC 网络服务，BindsTo=xvfb)
#   - websockify@.service  (WebSocket 网关服务)
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

# 账号密码记录文件（root 私有，600）：
#   只在这里记录「明文」的桌面用户密码与 VNC 连接密码，供菜单 [11] 查看。
#   注意：绝不要放进仓库（仓库是公开的）。
CRED_FILE="/root/.vnc-desktop-credentials"

update_variables() {
    USER_HOME="/home/${VNC_USER}"
    NOVNC_WEB_ROOT="/usr/share/novnc"
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
    PKG_LXDE="lxde-core lxterminal lxappearance lxde-icon-theme"
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
    local port="$1" i ws=""
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
    rewrite ^/vnc([0-9]+)/?\$ /vnc.html?path=websockify/\$1&autoconnect=true&reconnect=true redirect;
    rewrite ^/view/?\$ /vnc.html?path=websockify/3&view_only=true&autoconnect=true redirect;

    location / {
        root ${NOVNC_WEB_ROOT};
        index vnc.html;
        try_files \$uri \$uri/ =404;
        add_header Cache-Control "no-cache";
    }

${ws}}
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

    # 确保 LXDE 会话配置（desktop.conf + 会话自启动，自启动统一由 helper 维护）
    local lx_dir="${USER_HOME}/.config/lxsession/LXDE"
    mkdir -p "${lx_dir}"
    if [ ! -f "${lx_dir}/desktop.conf" ] && [ -f /etc/xdg/lxsession/LXDE/desktop.conf ]; then
        cp /etc/xdg/lxsession/LXDE/desktop.conf "${lx_dir}/desktop.conf"
    fi
    ensure_session_autostart
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
After=xvfb@%i.service network.target
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
After=xvfb@%i.service vnc-desktop@%i.service
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

    # 5. Websockify 网关服务
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

    # 6. 总调度 Target (一键启停全部级联节点)
    cat > /etc/systemd/system/vnc-stack@.target << EOF
[Unit]
Description=VNC Full Stack Pipeline for Display :%i
Wants=xvfb@%i.service vnc-desktop@%i.service x11vnc@%i.service websockify@%i.service mt5-watchdog@%i.service
After=xvfb@%i.service vnc-desktop@%i.service x11vnc@%i.service websockify@%i.service mt5-watchdog@%i.service

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

    # 启用全部级联服务单元
    systemctl enable xvfb@1 vnc-desktop@1 x11vnc@1 websockify@1 vnc-stack@1.target mt5-watchdog@1 2>/dev/null || true
    systemctl restart vnc-stack@1.target

    # 分辨率热切换的免 root 通道（单元模板已由 install_systemd_pipeline_units 写好并 reload）
    systemctl enable vnc-res-watch.path 2>/dev/null || true
    systemctl restart vnc-res-watch.path 2>/dev/null || true

    echo "=========================================================="
    echo "✅ Systemd 级联服务流水线已激活并开机自启！"
    echo "   - xvfb@1.service         (虚拟显存)"
    echo "   - vnc-desktop@1.service  (LXDE 桌面环境)"
    echo "   - x11vnc@1.service       (VNC 传输协议)"
    echo "   - websockify@1.service   (WebSocket 网页桥接)"
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
                systemctl status xvfb@1 vnc-desktop@1 x11vnc@1 websockify@1 mt5-watchdog@1 vnc-res-watch.path gost --no-pager
                ;;
            99) 
                systemctl stop vnc-stack@1.target xvfb@1 vnc-desktop@1 x11vnc@1 websockify@1 mt5-watchdog@1 gost 2>/dev/null || true
                echo "已停止所有服务。"
                ;;
            10)
                harden_desktop_session
                echo "🔄 正在重启桌面会话以让面板配置生效..."
                systemctl restart vnc-desktop@1 2>/dev/null || true
                ;;
            11) show_credentials ;;
            12) housekeeping_disk ;;
            0) exit 0 ;;
        esac
        read -p "按回车继续..."
    done
}

check_root

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

main_menu

