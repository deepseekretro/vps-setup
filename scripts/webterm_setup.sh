#!/bin/bash

# =======================================================
# ⌨️  Web Terminal（多标签网页终端）安装 / 管理模块
#
#  后端: python3 + websockets 的 PTY 桥
#        /var/www/web-terminal/app.py  →  监听 127.0.0.1:9000（可改）
#  前端: xterm.js 多标签界面（静态文件 + /ws WebSocket）
#  反代: OpenResty / Nginx 站点，走「增量」方式：
#        只写 conf.d/10-webterm.conf 与 webterm-server.inc 两个脚本自有文件；
#        你的 nginx.conf 一个字都不改（除非它完全没有 conf.d include，那时只补插 1 行并备份）
#  鉴权: 整站 basic auth（随机密码，记录在 /root/.webterm-credentials，600，绝不进仓库）
#
# 落盘位置：
#   /var/www/web-terminal/app.py, static/    （来自仓库 assets/web-terminal/）
#   /etc/systemd/system/webterminal.service
#   <conf>/conf.d/10-webterm.conf            （脚本自有的站点，可反复覆盖）
#   <conf>/webterm-server.inc                （脚本自有的站点本体，被上面 include）
#   <conf>/htpasswd                          （basic auth，默认路径，已存在则沿用你的）
#
# 幂等：重跑会沿用原有端口、原有密码、原有 htpasswd 路径；
#       检测到「已有别人写好的 Web Terminal 站点」时只更新应用/服务/密码，不动 nginx。
# =======================================================

BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/deepseekretro/vps-setup/main}"

# 落盘位置（WEBTERM_* 环境变量仅用于沙箱测试时重定向）
APP_DIR="${WEBTERM_APP_DIR:-/var/www/web-terminal}"
STATIC_DIR="${APP_DIR}/static"
SVC_NAME="${WEBTERM_SVC_NAME:-webterminal.service}"
SVC_FILE="${WEBTERM_SVC_FILE:-/etc/systemd/system/${SVC_NAME}}"
ASSET_BASE="${WEBTERM_ASSET_BASE:-${BASE_URL}/assets/web-terminal}"
CRED_FILE="${WEBTERM_CRED_FILE:-/root/.webterm-credentials}"
CONFIG_MARK="# Managed by vps-setup (webterm_setup.sh)"
AUTH_USER_DEFAULT="admin"
BACKEND_DEFAULT_PORT=9000

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }

press_enter() { read -p "按 Enter 键继续..." _ 2>/dev/null || true; }

check_root() {
    if [ "$EUID" -ne 0 ]; then echo "❌ 请使用 root 权限运行"; exit 1; fi
}

# -------------------------------------------------------
# 通用小工具
# -------------------------------------------------------

# 索引被清理过时，装「没装过的包」会报 no installation candidate
ensure_apt_lists() {
    [ -n "$(find /var/lib/apt/lists -maxdepth 1 -name '*_Packages*' 2>/dev/null | head -1)" ] && return 0
    echo "ℹ️ apt 索引已被清理，先补一次 apt update ..."
    apt update
}

# 只补装「确实缺失」的包（已装的不重复 apt install）
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

# root 私有凭据文件（KEY=VALUE，600，绝不进仓库）
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

# 随机密码：只取字母数字，避免 sticky 字符在 URL / 终端里被吞
gen_password() {
    local p=""
    while [ "${#p}" -lt 14 ]; do
        p=$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-14)
    done
    printf '%s' "${p}"
}

# 版本比较：version_ge 1.25.1 1.25.1 → 0
version_ge() {
    [ "$1" = "$2" ] && return 0
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]
}

port_listening() {
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

detect_container() {
    grep -qaE '(docker|lxc|containerd)' /proc/1/cgroup 2>/dev/null && return 0
    [ -f /.dockerenv ] && return 0
    [ -n "${container:-}" ] && return 0
    return 1
}

# -------------------------------------------------------
# 探测：Web 服务器 / 端口 / 已有站点
# -------------------------------------------------------

WS_KIND="none"; WS_BIN=""; WS_VER=""; WS_PREFIX=""
WS_CONF_DIR=""; WS_MAIN_CONF=""; WS_DROPIN_DIR=""; WS_DROPIN=""
WS_SERVER_INC=""; WS_MAIN_BAK=""; WS_UNIT=""
BACKEND_PORT=""; HTPASSWD_FILE=""; AUTH_USER=""
SITE_HTTP_PORT=""; SITE_HTTPS_PORT=""
HTPASSWD_FILE_FOUND=""; SSL_CRT_FOUND=""; SSL_KEY_FOUND=""
SSL_CRT="/etc/ssl/localcerts/selfsigned.crt"
SSL_KEY="/etc/ssl/localcerts/selfsigned.key"

detect_web_server() {
    # 测试接缝：显式给出配置目录时完全不自动探测，避免误改真实机器上的配置。
    if [ -n "${WEBTERM_TEST_CONF_DIR:-}" ]; then
        if [ ! -d "${WEBTERM_TEST_CONF_DIR}" ]; then
            print_error "测试接缝失效：${WEBTERM_TEST_CONF_DIR} 不是目录，已中止（不碰任何真实配置）"
            WS_KIND="none"; WS_CONF_DIR=""
            return 1
        fi
        WS_KIND="test"
        WS_CONF_DIR="${WEBTERM_TEST_CONF_DIR}"
        WS_BIN="${WEBTERM_TEST_BIN:-$(command -v nginx || echo nginx)}"
        WS_UNIT="${WEBTERM_TEST_UNIT:-}"
    else
        local prefix="" bin=""
        bin=$(command -v openresty 2>/dev/null || true)
        [ -x /usr/local/openresty/nginx/sbin/nginx ] && bin=/usr/local/openresty/nginx/sbin/nginx
        if [ -n "${bin}" ]; then
            WS_KIND="openresty"
            prefix=$(${bin} -V 2>&1 | tr ' ' '\n' | grep -m1 '^--prefix=' | cut -d= -f2)
            WS_PREFIX=${prefix:-/usr/local/openresty/nginx}
            WS_BIN="${WS_PREFIX}/sbin/nginx"
            [ -x "${WS_BIN}" ] || WS_BIN="${bin}"
            WS_CONF_DIR="${WS_PREFIX}/conf"
            WS_UNIT="openresty"
        else
            bin=$(command -v nginx 2>/dev/null || true)
            if [ -n "${bin}" ]; then
                WS_KIND="nginx"
                WS_PREFIX=$(${bin} -V 2>&1 | tr ' ' '\n' | grep -m1 '^--prefix=' | cut -d= -f2)
                WS_PREFIX=${WS_PREFIX:-/usr/share/nginx}
                WS_BIN="${bin}"
                local cp
                cp=$(${bin} -V 2>&1 | tr ' ' '\n' | grep -m1 '^--conf-path=' | cut -d= -f2)
                WS_CONF_DIR="${cp:+$(dirname "${cp}")}"
                WS_CONF_DIR=${WS_CONF_DIR:-/etc/nginx}
                WS_UNIT="nginx"
            fi
        fi
    fi

    if [ -z "${WS_CONF_DIR}" ]; then
        WS_KIND="none"
        return 1
    fi
    WS_MAIN_CONF="${WS_CONF_DIR}/nginx.conf"
    WS_DROPIN_DIR="${WS_CONF_DIR}/conf.d"
    WS_DROPIN="${WS_DROPIN_DIR}/10-webterm.conf"
    WS_SERVER_INC="${WS_CONF_DIR}/webterm-server.inc"
    WS_MAIN_BAK="${WS_MAIN_CONF}.vps-setup-webterm.bak"
    WS_VER=$("${WS_BIN}" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    return 0
}

# 后端端口：优先沿用服务单元里记录的；其次沿用已有站点反代到的端口；否则 9000 起找空闲口
ws_backend_port() {
    local p f
    if [ -f "${SVC_FILE}" ]; then
        p=$(grep -hoE 'TERM_PORT=[0-9]+' "${SVC_FILE}" 2>/dev/null | head -1 | grep -oE '[0-9]+')
        [ -n "${p}" ] && { printf '%s' "${p}"; return; }
    fi
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        case "${f}" in *.bak|*.bak.*|*.default|*.orig|*.httpbak|*vps-setup*) continue ;; esac
        [ -f "${f}" ] || continue
        grep -qE 'location[[:space:]]+/ws' "${f}" 2>/dev/null || continue
        p=$(grep -ohE 'proxy_pass[[:space:]]+https?://(127\.0\.0\.1|localhost):[0-9]+' "${f}" 2>/dev/null \
            | grep -oE '[0-9]+$' | head -1)
        [ -n "${p}" ] && { printf '%s' "${p}"; return; }
    done < <(ws_candidate_files)
    for p in $(seq "${BACKEND_DEFAULT_PORT}" $((BACKEND_DEFAULT_PORT + 9))); do
        if port_listening "${p}"; then
            systemctl is-active --quiet "${SVC_NAME}" 2>/dev/null && { printf '%s' "${p}"; return; }
            continue
        fi
        printf '%s' "${p}"; return
    done
    printf '%s' "${BACKEND_DEFAULT_PORT}"
}

# 需要扫描的配置文件（主配置 + conf.d 等，排除脚本自有文件与备份）
ws_candidate_files() {
    printf '%s\n' "${WS_MAIN_CONF}"
    find "${WS_CONF_DIR}" -maxdepth 2 \( -name '*.conf' -o -name '*.inc' \) 2>/dev/null
}

# 是否已有「别人写好的」Web Terminal 站点（我们自己的文件带 CONFIG_MARK，按标记排除）
#   注意：不能按文件名排除 —— 你手工写的站点很可能就叫 webterm-server.inc，
#   与脚本生成的文件同名；只有带脚本标记的才算是「我们的」。
existing_backend_refs() {
    local f
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        case "${f}" in
            "${WS_DROPIN}") continue ;;
            *.bak|*.bak.*|*.default|*.orig|*.httpbak|*vps-setup*) continue ;;
        esac
        [ -f "${f}" ] || continue
        grep -qF "${CONFIG_MARK}" "${f}" 2>/dev/null && continue
        grep -qE "proxy_pass[[:space:]]+https?://(127\.0\.0\.1|localhost):${BACKEND_PORT}([^0-9]|$)" "${f}" 2>/dev/null || continue
        grep -qE 'web-terminal|webterm|location[[:space:]]+/ws' "${f}" 2>/dev/null || continue
        printf '%s\n' "${f}"
    done < <(ws_candidate_files)
}

# 已有站点监听的端口：找到「引用该站点文件」的配置（通常是你的 nginx.conf），
# 从里面解析 listen 行，输出 "<端口> <ssl|plain>"（去重）
existing_site_ports() {
    local ref f line
    while IFS= read -r ref; do
        while IFS= read -r f; do
            [ -f "${f}" ] || continue
            grep -qF "${ref}" "${f}" 2>/dev/null || continue
            while IFS= read -r line; do
                [ -n "${line}" ] || continue
                printf '%s\n' "${line}"
            done < <(grep -hoE '^[[:space:]]*listen[[:space:]]+([0-9]+)([[:space:]]+ssl)?' "${f}" 2>/dev/null \
                     | sed -E 's/^[[:space:]]*listen[[:space:]]+//; s/[[:space:]]+/ /g' \
                     | awk '{ if ($2 == "ssl") print $1" ssl"; else print $1" plain" }')
        done < <(ws_candidate_files)
    done < <(existing_backend_refs)
}

# 从已有配置里取 basic auth 用户文件 / 证书路径 / 用户名
detect_site_extras() {
    local f line
    HTPASSWD_FILE_FOUND=""; SSL_CRT_FOUND=""; SSL_KEY_FOUND=""
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        case "${f}" in *.bak|*.bak.*|*.default|*.orig|*.httpbak|*vps-setup*) continue ;; esac
        [ -f "${f}" ] || continue
        line=$(grep -hE '^[[:space:]]*auth_basic_user_file[[:space:]]+' "${f}" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')
        [ -n "${line}" ] && [ -z "${HTPASSWD_FILE_FOUND}" ] && { HTPASSWD_FILE_FOUND="${line}"; }
        line=$(grep -hE '^[[:space:]]*ssl_certificate[[:space:]]+' "${f}" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')
        [ -n "${line}" ] && [ -z "${SSL_CRT_FOUND}" ] && { SSL_CRT_FOUND="${line}"; }
        line=$(grep -hE '^[[:space:]]*ssl_certificate_key[[:space:]]+' "${f}" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')
        [ -n "${line}" ] && [ -z "${SSL_KEY_FOUND}" ] && { SSL_KEY_FOUND="${line}"; }
    done < <(ws_candidate_files)
}

# nginx worker 用户（basic auth 文件权限要让它读得到）
worker_user() {
    local u
    u=$(grep -hE '^[[:space:]]*user[[:space:]]+' "${WS_MAIN_CONF}" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')
    [ -n "${u}" ] || u="nobody"
    id -u "${u}" >/dev/null 2>&1 || u="nobody"
    printf '%s' "${u}"
}

# -------------------------------------------------------
# nginx 增量配置
# -------------------------------------------------------

# 写任何文件前的自检：所有目标路径必须落在 WS_CONF_DIR 之内
# （一个测试接缝/路径推导出错，就会把文件写到真实配置上 —— 这里直接拦住）
ws_assert_paths() {
    [ -n "${WS_CONF_DIR}" ] || { print_error "内部错误：配置目录为空，已中止（不写任何文件）"; return 1; }
    [ -d "${WS_CONF_DIR}" ] || { print_error "内部错误：配置目录不存在：${WS_CONF_DIR}"; return 1; }
    case "${WS_DROPIN}" in
        "${WS_CONF_DIR}"/*) ;;
        *) print_error "内部错误：drop-in 路径越界（${WS_DROPIN}），已中止"; return 1 ;;
    esac
    case "${WS_SERVER_INC}" in
        "${WS_CONF_DIR}"/*) ;;
        *) print_error "内部错误：站点文件路径越界（${WS_SERVER_INC}），已中止"; return 1 ;;
    esac
    return 0
}

# 主配置里是否已经有会加载到我们 drop-in 目录的 include
# （相对路径按「配置文件所在目录」解析 —— nginx 实测行为）
ws_include_present() {
    local inc cand dir
    while IFS= read -r inc; do
        inc=$(printf '%s' "${inc}" | sed -E 's/^[[:space:]]*include[[:space:]]+//; s/;[[:space:]]*$//')
        [ -n "${inc}" ] || continue
        if [ "${inc#/}" != "${inc}" ]; then
            dir=$(dirname "${inc}")
            [ "$(readlink -f "${dir}" 2>/dev/null)" = "$(readlink -f "${WS_DROPIN_DIR}" 2>/dev/null)" ] && return 0
        else
            for cand in "${WS_CONF_DIR}/${inc}" "${WS_PREFIX}/${inc}"; do
                dir=$(dirname "${cand}")
                [ "$(readlink -f "${dir}" 2>/dev/null)" = "$(readlink -f "${WS_DROPIN_DIR}" 2>/dev/null)" ] && return 0
            done
        fi
    done < <(grep -hE '^[[:space:]]*include[[:space:]]+' "${WS_MAIN_CONF}" 2>/dev/null)
    return 1
}

ws_backup_main_conf() {
    [ -f "${WS_MAIN_BAK}" ] || cp -a "${WS_MAIN_CONF}" "${WS_MAIN_BAK}"
}

# 没有 nginx.conf（极端情况）：写一份脚本自有的最小基底
ws_write_minimal_conf() {
    ws_assert_paths || return 1
    mkdir -p "${WS_CONF_DIR}" "${WS_DROPIN_DIR}"
    cat > "${WS_MAIN_CONF}" <<EOF
${CONFIG_MARK}
# 本文件由脚本生成的「最小基底」：只加载 mime.types 与 conf.d/*.conf。
# 你自己的 server / upstream 请放进 ${WS_DROPIN_DIR}/ 下的独立 .conf 文件，
# 本脚本以后重跑不会再覆盖它们。
user www-data;
worker_processes auto;
events { worker_connections 1024; }
http {
    include mime.types;
    default_type application/octet-stream;
    include ${WS_DROPIN_DIR}/*.conf;
}
EOF
}

# 已有 nginx.conf 但没有任何 conf.d include：在 http{} 开头补插 1 行（带标记）
ws_add_include() {
    local f="${WS_MAIN_CONF}" tmp="${WS_MAIN_CONF}.vps-setup.new"
    ws_assert_paths || return 1
    ws_backup_main_conf
    awk -v mark="    ${CONFIG_MARK} (增量插入：加载 conf.d 下的 Web Terminal 站点，删本行即可回收)" \
        -v inc="    include ${WS_DROPIN_DIR}/*.conf;" '
        { print }
        !done && $0 ~ /^[[:space:]]*http[[:space:]]*\{/ {
            print mark
            print inc
            done = 1
        }
    ' "${f}" > "${tmp}" && mv "${tmp}" "${f}"
    grep -qF "${WS_DROPIN_DIR}/*.conf" "${f}" 2>/dev/null
}

# 端口是否已被占用（我们自己的 drop-in 不算，备份文件不算）
ws_port_taken() {
    local port="$1" f
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        [ "${f}" = "${WS_DROPIN}" ] && continue
        case "${f}" in *.bak|*.bak.*|*.default|*.orig|*.httpbak|*vps-setup*) continue ;; esac
        [ -f "${f}" ] || continue
        sed 's/#.*$//' "${f}" 2>/dev/null \
            | grep -qE "(^|[^0-9a-zA-Z_])listen[[:space:]]+(\[::\]:)?${port}([[:space:];]|$)" && return 0
    done < <(ws_candidate_files)
    return 1
}

# 端口选择：已装过就沿用 drop-in 里的；否则按候选列表取第一个空闲口
ws_pick_port() {
    local kind="$1" cur cand
    if [ -f "${WS_DROPIN}" ]; then
        if [ "${kind}" = "http" ]; then
            cur=$(grep -oE 'listen[[:space:]]+[0-9]+([[:space:]]+ssl)?;' "${WS_DROPIN}" 2>/dev/null \
                  | grep -vE 'listen[[:space:]]+[0-9]+[[:space:]]+ssl;' | grep -oE '[0-9]+' | head -1)
        else
            cur=$(grep -oE 'listen[[:space:]]+[0-9]+[[:space:]]+ssl' "${WS_DROPIN}" 2>/dev/null | grep -oE '[0-9]+' | head -1)
        fi
        [ -n "${cur}" ] && { printf '%s' "${cur}"; return; }
    fi
    if [ "${kind}" = "http" ]; then
        for cand in 80 8080 8000 8888 9080; do
            ws_port_taken "${cand}" && continue
            printf '%s' "${cand}"; return
        done
        printf '%s' 8080
    else
        for cand in 443 8443 9443 10443 12443; do
            ws_port_taken "${cand}" && continue
            printf '%s' "${cand}"; return
        done
        printf '%s' 8443
    fi
}

# 自签证书（与 noVNC 模块共用同一份，避免装两套证书）
ws_ensure_cert() {
    mkdir -p "$(dirname "${SSL_CRT}")"
    if [ -f "${SSL_CRT}" ] && [ -f "${SSL_KEY}" ]; then return 0; fi
    echo "ℹ️ 生成自签证书：${SSL_CRT}"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${SSL_KEY}" -out "${SSL_CRT}" \
        -subj "/C=CN/ST=Shanghai/O=WebTerminal/CN=webterm" >/dev/null 2>&1
    chmod 644 "${SSL_CRT}" 2>/dev/null || true
    chmod 600 "${SSL_KEY}" 2>/dev/null || true
}

# 站点本体（被 http 与 https 两个 server 共同 include）
ws_write_server_inc() {
    ws_assert_paths || return 1
    [ -n "${BACKEND_PORT}" ] || BACKEND_PORT="${BACKEND_DEFAULT_PORT}"
    # 同名但不是我们生成的文件 → 绝不覆盖，改用脚本自己的文件名
    if [ -f "${WS_SERVER_INC}" ] && ! grep -qF "${CONFIG_MARK}" "${WS_SERVER_INC}" 2>/dev/null; then
        WS_SERVER_INC="${WS_CONF_DIR}/webterm-server.vps-setup.inc"
        print_warning "已存在同名文件（不是脚本生成的）→ 改用 ${WS_SERVER_INC}，不覆盖你的文件"
    fi
    [ -n "${HTPASSWD_FILE}" ] || HTPASSWD_FILE="${WS_CONF_DIR}/htpasswd"
    mkdir -p "${WS_CONF_DIR}"
    [ -f "${WS_SERVER_INC}" ] && cp -a "${WS_SERVER_INC}" "${WS_SERVER_INC}.vps-setup.bak"
    cat > "${WS_SERVER_INC}" <<EOF
${CONFIG_MARK} (Web Terminal 站点本体，被 conf.d 里的 server 块 include)
        root ${STATIC_DIR};
        index index.html;

        # --- 整站 basic auth -------------------------------------------------
        # 必须覆盖 HTML 文档，而不只是 /ws：Chromium（Chrome/Edge）在 WebSocket
        # 握手返回 401 时不会弹认证框，只保护 /ws 会表现为「连不上又没有任何提示」。
        auth_basic "Web Terminal";
        auth_basic_user_file ${HTPASSWD_FILE};

        # --- WebSocket 终端后端 ---------------------------------------------
        location /ws {
            proxy_pass http://127.0.0.1:${BACKEND_PORT};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            # 长连接：给足读写超时，否则空闲一会儿就被断开
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;
        }

        # --- 静态资源（xterm.js 等）缓存 7 天 --------------------------------
        location /vendor/ {
            expires 7d;
            add_header Cache-Control "public";
            try_files \$uri =404;
        }

        # --- 前端静态文件（不缓存，便于更新）---------------------------------
        location = /index.html { add_header Cache-Control "no-store"; }
        location = /app.js     { add_header Cache-Control "no-store"; }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
EOF
}

ws_write_dropin() {
    local http2_line="" listen_ssl="listen ${SITE_HTTPS_PORT} ssl;"
    ws_assert_paths || return 1
    if version_ge "${WS_VER}" "1.25.1"; then
        http2_line="    http2 on;"
    else
        listen_ssl="listen ${SITE_HTTPS_PORT} ssl http2;"
    fi
    mkdir -p "${WS_DROPIN_DIR}"
    [ -f "${WS_DROPIN}" ] && cp -a "${WS_DROPIN}" "${WS_DROPIN}.vps-setup.bak"
    cat > "${WS_DROPIN}" <<EOF
${CONFIG_MARK}
# 本文件完全由脚本管理：重跑只会覆盖本文件与 webterm-server.inc，
# 不会动你的 nginx.conf，也不会动 conf.d 下其它 *.conf。
# 卸载：删掉本文件（以及主配置里带同样注释的 include 行）后重载即可。
server {
    listen ${SITE_HTTP_PORT};
    server_name _;
    include ${WS_SERVER_INC};
}

server {
    ${listen_ssl}
${http2_line}
    server_name _;
    ssl_certificate     ${SSL_CRT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:WebTermSSL:10m;
    ssl_session_timeout 1h;
    # 故意不设 Strict-Transport-Security：自签证书 + HSTS 会让 http 入口彻底打不开
    include ${WS_SERVER_INC};
}
EOF
}

# 校验 + 加载；nginx -t 不通过就回滚本次写入，绝不让原有服务起不来
ws_reload_safe() {
    local out rc
    ws_assert_paths || return 1
    out=$("${WS_BIN}" -t 2>&1); rc=$?
    if [ "${rc}" -ne 0 ]; then
        print_error "nginx 配置校验未通过，已回滚本次改动（你的原配置/原服务不受影响）："
        printf '%s\n' "${out}" | sed 's/^/    /'
        if [ -f "${WS_DROPIN}.vps-setup.bak" ]; then
            mv -f "${WS_DROPIN}.vps-setup.bak" "${WS_DROPIN}"
        else
            rm -f "${WS_DROPIN}"
        fi
        if [ -f "${WS_SERVER_INC}.vps-setup.bak" ]; then
            mv -f "${WS_SERVER_INC}.vps-setup.bak" "${WS_SERVER_INC}"
        fi
        if [ "${WS_MAIN_CHANGED:-0}" = "1" ] && [ -f "${WS_MAIN_BAK}" ]; then
            mv -f "${WS_MAIN_BAK}" "${WS_MAIN_CONF}"
            echo "    已恢复主配置：${WS_MAIN_CONF}"
        fi
        return 1
    fi
    rm -f "${WS_DROPIN}.vps-setup.bak" "${WS_SERVER_INC}.vps-setup.bak"
    if [ -n "${WS_UNIT}" ] && systemctl is-active --quiet "${WS_UNIT}" 2>/dev/null; then
        "${WS_BIN}" -s reload 2>/dev/null || systemctl restart "${WS_UNIT}"
        print_success "${WS_UNIT} 已 reload（现有连接不中断）"
    elif [ -n "${WS_UNIT}" ]; then
        systemctl enable "${WS_UNIT}" >/dev/null 2>&1 || true
        systemctl start "${WS_UNIT}" >/dev/null 2>&1 || true
        print_success "${WS_UNIT} 已启动"
    fi
    return 0
}

# -------------------------------------------------------
# 安装步骤
# -------------------------------------------------------

install_app_files() {
    echo "--- 下载 Web Terminal 应用与前端（来自仓库 assets/web-terminal/）---"
    mkdir -p "${STATIC_DIR}/vendor"
    local ts rel ok=0
    ts=$(date +%s)
    for rel in app.py static/index.html static/app.js static/keymap.js \
               static/vendor/xterm.js static/vendor/xterm.css static/vendor/addon-fit.js; do
        if curl -fsSL -H 'Cache-Control: no-cache' "${ASSET_BASE}/${rel}?t=${ts}" -o "${APP_DIR}/${rel}"; then
            ok=$((ok + 1))
        else
            print_error "下载失败: ${ASSET_BASE}/${rel}"
        fi
    done
    if [ "${ok}" -ne 7 ] || ! grep -q 'import websockets' "${APP_DIR}/app.py" 2>/dev/null; then
        print_error "应用文件不完整（${ok}/7），已中止。请检查网络或仓库地址：${ASSET_BASE}"
        return 1
    fi
    chmod 755 "${APP_DIR}"
    chmod 644 "${APP_DIR}/app.py" "${APP_DIR}"/static/*.html "${APP_DIR}"/static/*.js 2>/dev/null || true
    chmod 644 "${APP_DIR}"/static/vendor/* 2>/dev/null || true
    chmod -R a+rX "${STATIC_DIR}" 2>/dev/null || true
    print_success "应用已就绪：${APP_DIR}（app.py + 前端 $(du -sh "${STATIC_DIR}" 2>/dev/null | cut -f1)）"
}

install_service_unit() {
    echo "--- 安装 systemd 服务（${SVC_NAME}）---"
    cat > "${SVC_FILE}" <<EOF
[Unit]
Description=Web Terminal WebSocket backend (PTY bridge)
After=network.target

[Service]
Type=simple
Environment=TERM_PORT=${BACKEND_PORT}
ExecStart=/usr/bin/python3 ${APP_DIR}/app.py
Restart=on-failure
RestartSec=3
WorkingDirectory=${APP_DIR}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SVC_NAME}" >/dev/null 2>&1 || true
    systemctl restart "${SVC_NAME}"
    sleep 1
    if systemctl is-active --quiet "${SVC_NAME}"; then
        print_success "${SVC_NAME} 已运行（127.0.0.1:${BACKEND_PORT}）"
    else
        print_error "${SVC_NAME} 启动失败，日志："
        journalctl -u "${SVC_NAME}" -n 15 --no-pager | sed 's/^/    /'
        return 1
    fi
}

# 写入/更新 htpasswd 里某个用户（apr1，与 nginx 兼容；保留其它用户行）
htpasswd_write() {
    local user="$1" pass="$2" file="$3" tmp
    mkdir -p "$(dirname "${file}")"
    tmp="${file}.tmp.$$"
    grep -vE "^${user}:" "${file}" > "${tmp}" 2>/dev/null || : > "${tmp}"
    printf '%s:%s\n' "${user}" "$(openssl passwd -apr1 "${pass}")" >> "${tmp}"
    cat "${tmp}" > "${file}"; rm -f "${tmp}"
}

# 记录里的明文密码和 htpasswd 现有行是否一致（比 salt 重新哈希对比）
htpasswd_matches() {
    local user="$1" pass="$2" file="$3" cur salt want
    cur=$(sed -n "s|^${user}:||p" "${file}" 2>/dev/null | head -1)
    [ -n "${cur}" ] || return 1
    salt=$(printf '%s' "${cur}" | sed -n 's/^\$apr1\$\([^$]*\)\$.*/\1/p')
    [ -n "${salt}" ] || return 1
    want=$(openssl passwd -apr1 -salt "${salt}" "${pass}" 2>/dev/null)
    [ -n "${want}" ] && [ "${want}" = "${cur}" ]
}

# basic auth：沿用已有 htpasswd 路径与用户名；
#   密码只在「记录里没有、且 htpasswd 里也没有该用户」时才随机生成 —— 绝不悄悄改掉你已有的密码
setup_auth() {
    echo "--- 配置访问密码（nginx basic auth）---"
    local pass has_entry=0 wu
    if [ -n "${HTPASSWD_FILE_FOUND:-}" ]; then
        HTPASSWD_FILE="${HTPASSWD_FILE_FOUND}"
        AUTH_USER=$(awk -F: 'NR==1{print $1}' "${HTPASSWD_FILE}" 2>/dev/null)
        [ -n "${AUTH_USER}" ] || AUTH_USER="${AUTH_USER_DEFAULT}"
        print_info "沿用你已有的用户文件与用户名：${HTPASSWD_FILE}（用户 ${AUTH_USER}）"
    else
        HTPASSWD_FILE="${WS_CONF_DIR}/htpasswd"
        AUTH_USER=$(cred_get WEBTERM_USER) || AUTH_USER="${AUTH_USER_DEFAULT}"
    fi

    pass=$(cred_get WEBTERM_PASS) || pass=""
    grep -qE "^${AUTH_USER}:" "${HTPASSWD_FILE}" 2>/dev/null && has_entry=1

    if [ -z "${pass}" ] && [ "${has_entry}" -eq 1 ]; then
        # 已有密码，但明文不在我们的记录里 —— 保持原样，不猜也不改
        print_info "用户 ${AUTH_USER} 已有密码（明文未记录），保持不变；如需查看/重设请用菜单 [3]"
    elif [ -n "${pass}" ] && [ "${has_entry}" -eq 1 ] && htpasswd_matches "${AUTH_USER}" "${pass}" "${HTPASSWD_FILE}"; then
        print_success "密码核对一致（记录在 ${CRED_FILE}；菜单 [2] 查看、[3] 重设）"
    else
        [ -n "${pass}" ] || pass=$(gen_password)
        htpasswd_write "${AUTH_USER}" "${pass}" "${HTPASSWD_FILE}"
        cred_set WEBTERM_PASS "${pass}"
        print_success "已写入访问账号：${AUTH_USER} / ${pass}"
    fi
    # worker 用户要读得到；其它用户读不到
    wu=$(worker_user)
    chown root:"$(id -gn "${wu}" 2>/dev/null || echo root)" "${HTPASSWD_FILE}" 2>/dev/null || true
    chmod 640 "${HTPASSWD_FILE}" 2>/dev/null || true

    cred_set WEBTERM_USER "${AUTH_USER}"
    cred_set WEBTERM_HTPASSWD "${HTPASSWD_FILE}"
}

# 站点：已有别人的配置就一个字都不动
configure_nginx_site() {
    local pts
    echo "--- 配置 HTTPS 站点（增量式：只写 conf.d 文件，不覆盖你已有的 nginx.conf）---"
    [ -n "${BACKEND_PORT}" ] || BACKEND_PORT=$(ws_backend_port)

    if [ -n "$(existing_backend_refs | head -1)" ]; then
        EXISTING_SITE=1
        print_info "检测到你的配置里已经有 Web Terminal 站点（反代到 127.0.0.1:${BACKEND_PORT}）："
        existing_backend_refs | sed 's/^/    /'
        pts=$(existing_site_ports | sort -u | tr '\n' ' ')
        [ -n "${pts}" ] && echo "    监听端口：${pts}"
        print_info "为不破坏你现有站点，本次只更新应用/服务/密码，nginx 配置一个字都不动。"
        return 0
    fi

    mkdir -p "${WS_DROPIN_DIR}"
    WS_MAIN_CHANGED=0
    rm -f "${WS_MAIN_BAK}"

    if [ ! -f "${WS_MAIN_CONF}" ]; then
        ws_write_minimal_conf
        WS_MAIN_CHANGED=1
        echo "ℹ️ 之前没有 nginx.conf，已生成最小基底：${WS_MAIN_CONF}"
    elif ws_include_present; then
        echo "ℹ️ 你的 nginx.conf 已加载 ${WS_DROPIN_DIR} —— 主配置不做任何改动"
    elif ws_add_include; then
        WS_MAIN_CHANGED=1
        echo "ℹ️ 你的 nginx.conf 没有 conf.d include，已增量补插 1 行（备份：${WS_MAIN_BAK}）"
    else
        print_warning "你的 nginx.conf 里没找到 http { 块，无法自动补 include，已放弃改动。"
        echo "   请手工在 http {} 内加一行：include ${WS_DROPIN_DIR}/*.conf;"
        return 1
    fi

    SITE_HTTP_PORT=$(ws_pick_port http)
    SITE_HTTPS_PORT=$(ws_pick_port https)
    ws_ensure_cert
    ws_write_server_inc || return 1
    ws_write_dropin || return 1
    ws_reload_safe || return 1
    return 0
}

do_install() {
    echo "=========================================="
    echo "   ⌨️  Web Terminal 安装 / 更新"
    echo "=========================================="
    check_root
    ensure_pkgs python3 python3-websockets ca-certificates curl openssl

    detect_web_server || true
    if [ "${WS_KIND}" = "none" ]; then
        print_warning "没找到 OpenResty / Nginx —— 先装应用与后端服务；"
        echo "   装好 Web 服务器后重跑本模块即可自动补上 HTTPS 站点（主菜单 [6] Web服务管理）。"
        # 没有 Web 服务器时只借一个约定路径放 htpasswd，不做任何 nginx 操作
        WS_CONF_DIR="/usr/local/openresty/nginx/conf"
    fi
    BACKEND_PORT=$(ws_backend_port)
    if [ "${WS_KIND}" != "none" ]; then
        detect_site_extras
    fi

    install_app_files || return 1
    install_service_unit || return 1
    setup_auth || return 1

    EXISTING_SITE=0
    if [ "${WS_KIND}" != "none" ]; then
        configure_nginx_site || true
    fi

    echo
    echo "=========================================="
    print_success "Web Terminal 安装完成"
    echo "=========================================="
    print_webterm_info
    echo
    print_warning "后端会以 root 身份开 shell（整站受 basic auth + HTTPS 保护），请勿把端口裸暴露给公网之外的人。"
    if detect_container; then
        echo "ℹ️ 检测到当前运行在容器内：端口如需外部访问，请在宿主机做转发（LXC/宿主 iptables/nft）。"
    fi
}

# -------------------------------------------------------
# 展示 / 菜单
# -------------------------------------------------------

print_webterm_info() {
    local ip ver user pass hp="" sp="" url existing_ports="" p kind
    ip=$(hostname -I 2>/dev/null | awk '{print $1}'); ip=${ip:-<服务器IP>}
    ver=$(grep -hoE 'TERM_PORT=[0-9]+' "${SVC_FILE}" 2>/dev/null | head -1 | grep -oE '[0-9]+')
    ver=${ver:-${BACKEND_PORT:-${BACKEND_DEFAULT_PORT}}}
    user=$(cred_get WEBTERM_USER) || user="${AUTH_USER_DEFAULT}"
    pass=$(cred_get WEBTERM_PASS) || pass=""

    detect_web_server >/dev/null 2>&1 || true
    if [ -f "${WS_DROPIN}" ]; then
        hp=$(sed -n 's/^[[:space:]]*listen[[:space:]]\+\([0-9]\+\);.*/\1/p' "${WS_DROPIN}" 2>/dev/null | head -1)
        sp=$(sed -n 's/^[[:space:]]*listen[[:space:]]\+\([0-9]\+\)[[:space:]]\+ssl.*/\1/p' "${WS_DROPIN}" 2>/dev/null | head -1)
    fi
    if [ -z "${sp}" ] && [ -n "${WS_CONF_DIR}" ]; then
        [ -n "${BACKEND_PORT}" ] || BACKEND_PORT=$(ws_backend_port)
        existing_ports=$(existing_site_ports | sort -u)
        EXISTING_SITE=$([ -n "${existing_ports}" ] && echo 1 || echo 0)
    fi

    echo " 应用目录 : ${APP_DIR}"
    echo " 后端进程 : ${SVC_NAME} → 127.0.0.1:${ver}"
    systemctl is-active --quiet "${SVC_NAME}" 2>/dev/null && echo "   └ 状态: active ✅" || echo "   └ 状态: 未运行 ⚠️（菜单 [1] 安装/修复）"
    echo " 访问账号 : ${user}"
    if [ -n "${pass}" ]; then
        echo " 访问密码 : ${pass}"
    else
        echo " 访问密码 : （明文未记录 —— 菜单 [3] 重设）"
    fi
    if [ -n "${sp}" ]; then
        url="https://${ip}"; [ "${sp}" != "443" ] && url="https://${ip}:${sp}"
        echo " 访问地址 : ${url}/    （自签证书需点一次「继续访问」）"
    elif [ -n "${existing_ports}" ]; then
        echo " 访问地址 : 沿用你自己写的站点（脚本未改动 nginx）："
        while IFS=' ' read -r p kind; do
            [ -n "${p}" ] || continue
            if [ "${kind}" = "ssl" ]; then
                url="https://${ip}"; [ "${p}" != "443" ] && url="https://${ip}:${p}"
            else
                url="http://${ip}"; [ "${p}" != "80" ] && url="http://${ip}:${p}"
            fi
            echo "            ${url}/"
        done <<< "${existing_ports}"
        echo "            （命中文件见「检测到你的配置里已经有 Web Terminal 站点」提示）"
    elif [ -n "${hp}" ]; then
        url="http://${ip}"; [ "${hp}" != "80" ] && url="http://${ip}:${hp}"
        echo " 访问地址 : ${url}/"
    else
        echo " 访问地址 : 未配置站点（菜单 [1] 安装，或用你自己写好的站点）"
    fi
    if [ -f "${CRED_FILE}" ]; then
        echo " 凭据文件 : ${CRED_FILE} (权限 $(stat -c %a "${CRED_FILE}" 2>/dev/null))"
    fi
}

show_status() {
    clear
    echo "=========================================="
    echo "   ⌨️  Web Terminal 状态"
    echo "=========================================="
    echo ""
    print_webterm_info
    echo ""
    echo "--- 最近日志（journalctl -u ${SVC_NAME}）---"
    journalctl -u "${SVC_NAME}" -n 12 --no-pager 2>/dev/null | sed 's/^/  /' || true
    echo ""
    read -p "按 Enter 键继续..." _ 2>/dev/null || true
}

reset_password() {
    echo "--- 重设 Web Terminal 访问密码 ---"
    check_root
    local u cur user pass
    detect_web_server >/dev/null 2>&1 || true
    detect_site_extras
    HTPASSWD_FILE="${HTPASSWD_FILE_FOUND:-${WS_CONF_DIR}/htpasswd}"
    [ -n "${WS_CONF_DIR}" ] || HTPASSWD_FILE="/usr/local/openresty/nginx/conf/htpasswd"
    user=$(cred_get WEBTERM_USER) || user=$(awk -F: 'NR==1{print $1}' "${HTPASSWD_FILE}" 2>/dev/null)
    user=${user:-${AUTH_USER_DEFAULT}}

    echo "  当前用户: ${user}"
    echo "  用户文件: ${HTPASSWD_FILE}"
    echo ""
    echo "  [1] 随机生成新密码（推荐）"
    echo "  [2] 手工输入新密码"
    echo "  [0] 取消"
    read -p "请选择: " u
    case "${u}" in
        1) pass=$(gen_password) ;;
        2)
            if [ ! -t 0 ]; then echo "ℹ️ 当前不是交互终端，已取消。"; return 1; fi
            local p1 p2
            while true; do
                read -r -s -p "新密码: " p1; echo
                [ -n "${p1}" ] || { echo "  ⚠️ 不能为空"; continue; }
                read -r -s -p "再输入一次: " p2; echo
                [ "${p1}" = "${p2}" ] || { echo "  ⚠️ 两次不一致"; continue; }
                break
            done
            pass="${p1}"
            ;;
        *) echo "已取消"; return 0 ;;
    esac

    mkdir -p "$(dirname "${HTPASSWD_FILE}")"
    local tmp="${HTPASSWD_FILE}.tmp"
    grep -vE "^${user}:" "${HTPASSWD_FILE}" > "${tmp}" 2>/dev/null || : > "${tmp}"
    printf '%s:%s\n' "${user}" "$(openssl passwd -apr1 "${pass}")" >> "${tmp}"
    cat "${tmp}" > "${HTPASSWD_FILE}"; rm -f "${tmp}"
    chmod 640 "${HTPASSWD_FILE}" 2>/dev/null || true
    cred_set WEBTERM_USER "${user}"
    cred_set WEBTERM_PASS "${pass}"
    cred_set WEBTERM_HTPASSWD "${HTPASSWD_FILE}"
    print_success "已更新：${user} / ${pass}"
    if [ -n "${WS_UNIT:-}" ]; then
        systemctl is-active --quiet "${WS_UNIT}" 2>/dev/null && "${WS_BIN}" -s reload 2>/dev/null || true
    fi
}

uninstall_webterm() {
    echo "--- 卸载 Web Terminal ---"
    check_root
    echo " 将执行：停止并禁用 ${SVC_NAME}；删除服务单元；"
    echo "         删除脚本自有的 ${WS_DROPIN:-conf.d/10-webterm.conf} 与 ${WS_SERVER_INC:-webterm-server.inc}"
    echo "         （应用目录 ${APP_DIR} 与 ${CRED_FILE} 也会删除）"
    echo " 不会动你的 nginx.conf 与其它站点。"
    read -p "确认卸载？(y/N): " c
    case "${c}" in y|Y) ;; *) echo "已取消"; return 0 ;; esac

    systemctl disable --now "${SVC_NAME}" >/dev/null 2>&1 || true
    rm -f "${SVC_FILE}"
    systemctl daemon-reload 2>/dev/null || true
    detect_web_server >/dev/null 2>&1 || true
    if [ -n "${WS_DROPIN}" ]; then
        rm -f "${WS_DROPIN}"
        [ -f "${WS_SERVER_INC}" ] && rm -f "${WS_SERVER_INC}"
        systemctl is-active --quiet "${WS_UNIT}" 2>/dev/null && "${WS_BIN}" -s reload 2>/dev/null || true
    fi
    rm -rf "${APP_DIR}"
    rm -f "${CRED_FILE}"
    print_success "已卸载（你的 nginx.conf 与其它站点未受影响）"
}

main_menu() {
    while true; do
        clear
        echo "=== ⌨️  Web Terminal（多标签网页终端） ==="
        echo " 应用: ${APP_DIR}    后端: 127.0.0.1:${BACKEND_DEFAULT_PORT}"
        systemctl is-active --quiet "${SVC_NAME}" 2>/dev/null \
            && echo " 服务: ${SVC_NAME} (active)" || echo " 服务: ${SVC_NAME} (未运行)"
        echo "--------------------------------------------------"
        echo " [1] 安装 / 更新（应用 + 服务 + HTTPS 站点 + 密码）"
        echo " [2] 查看运行状态 / 访问地址 / 账号密码"
        echo " [3] 重设访问密码 (basic auth)"
        echo " [4] 卸载 Web Terminal"
        echo " [0] 退出"
        read -p "选项: " c || { echo; echo "（输入结束，退出）"; exit 0; }
        case "${c}" in
            1) do_install ;;
            2) show_status ;;
            3) reset_password; press_enter ;;
            4) uninstall_webterm; press_enter ;;
            0) exit 0 ;;
        esac
        echo ""
        read -p "按回车继续..." _ 2>/dev/null || { echo; exit 0; }
    done
}

check_root

# 测试接缝：WEBTERM_NO_MAIN=1 时只加载函数定义，不跑菜单/入口（供沙箱测试用）
if [ "${WEBTERM_NO_MAIN:-0}" = "1" ]; then
    if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi
    exit 0
fi

# 非交互入口：--install / --status / --show-credentials / --reset-password
case "${1:-}" in
    --install)
        do_install
        exit $?
        ;;
    --status)
        detect_web_server >/dev/null 2>&1 || true
        print_webterm_info
        exit 0
        ;;
    --show-credentials)
        print_webterm_info
        exit 0
        ;;
    --reset-password)
        reset_password
        exit $?
        ;;
esac

main_menu
