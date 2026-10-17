#!/usr/bin/env bash
set -euo pipefail

# =====================================================
# 固定路径常量
# =====================================================
GOST_DIR="/opt/gost"
GOST_BIN="${GOST_DIR}/gost"
XRAY_DIR="/opt/xray"
XRAY_BIN="${XRAY_DIR}/xray"

LOG_GOST="/var/log/gost"
LOG_XRAY="/var/log/xray"

# OpenResty 前缀（deb 包默认）
OR_PREFIX="/usr/local/openresty"
OR_CONF_DIR="${OR_PREFIX}/nginx/conf"
OR_ENABLED_SITES="${OR_CONF_DIR}/sites-enabled"
OR_SSL_DIR="${OR_CONF_DIR}/ssl"

SYSCTL_CONF="/etc/sysctl.d/99-lxc-host-network.conf"
SYSCTL_BACKUP="/etc/sysctl.d/99-lxc-host-network.conf.bak"
GAI_CONF="/etc/gai.conf"

# 配置文件路径
CONF_FILE="/etc/gost-xray/settings.env"

# =====================================================
# 加载持久化配置（不存在则空）
# =====================================================
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

# 应用默认值（配置文件中未设置的项）
SS_METHOD="${SS_METHOD:-chacha20-ietf-poly1305}"
SS_PASS="${SS_PASS:-changeme_ss_pass}"
SS_PORT="${SS_PORT:-8338}"
MWSS_USER="${MWSS_USER:-proxyuser}"
MWSS_PASS="${MWSS_PASS:-changeme_mws_pass}"
MWSS_HOST="${MWSS_HOST:-your.domain.com}"
MWS_PATH="${MWS_PATH:-/mws}"
XRAY_XHTTP4_PORT="${XRAY_XHTTP4_PORT:-8443}"

# =====================================================
# 基础函数
# =====================================================
[[ $EUID -eq 0 ]] || { echo " 请使用 root 运行"; exit 1; }
pause() { read -rp "按 Enter 继续..."; }

# =====================================================
# 交互式配置并保存
# =====================================================
configure_settings() {
  clear
  echo "========================================"
  echo "   当前配置"
  echo "========================================"
  echo ""
  echo "  MWSS_HOST        : ${MWSS_HOST}"
  echo "  MWS_PATH         : ${MWS_PATH}"
  echo "  MWSS_USER        : ${MWSS_USER}"
  echo "  MWSS_PASS        : ${MWSS_PASS}"
  echo "  SS_PASS          : ${SS_PASS}"
  echo "  SS_PORT          : ${SS_PORT}"
  echo "  XRAY_XHTTP4_PORT : ${XRAY_XHTTP4_PORT}"
  echo ""
  # 有配置文件则询问是否修改；首次运行直接进入填写
  if [[ -f "$CONF_FILE" ]]; then
    read -rp "是否修改配置？[y/N]: " _chg
    [[ "$_chg" =~ ^[Yy]$ ]] || { echo "未修改。"; return; }
  fi

  echo ""
  echo "（直接回车保持当前值）"
  echo ""

  local _v
  read -rp "MWSS_HOST  域名        [${MWSS_HOST}]: "        _v; [[ -n "$_v" ]] && MWSS_HOST="$_v"
  read -rp "MWS_PATH   路径        [${MWS_PATH}]: "        _v; [[ -n "$_v" ]] && MWS_PATH="$_v"
  read -rp "MWSS_USER  mws 用户名  [${MWSS_USER}]: "       _v; [[ -n "$_v" ]] && MWSS_USER="$_v"
  read -rp "MWSS_PASS  mws 密码    [${MWSS_PASS}]: "       _v; [[ -n "$_v" ]] && MWSS_PASS="$_v"
  read -rp "SS_PASS    SS 密码     [${SS_PASS}]: "          _v; [[ -n "$_v" ]] && SS_PASS="$_v"
  read -rp "SS_PORT    SS 端口     [${SS_PORT}]: "          _v; [[ -n "$_v" ]] && SS_PORT="$_v"
  read -rp "XRAY_PORT  Xray 内端口 [${XRAY_XHTTP4_PORT}]: " _v; [[ -n "$_v" ]] && XRAY_XHTTP4_PORT="$_v"

  # 保存到配置文件
  mkdir -p "$(dirname "$CONF_FILE")"
  cat > "$CONF_FILE" << ENVEOF
# 由 install_gost_xray.sh 自动生成，请勿手动删除
SS_METHOD="${SS_METHOD}"
SS_PASS="${SS_PASS}"
SS_PORT="${SS_PORT}"
MWSS_USER="${MWSS_USER}"
MWSS_PASS="${MWSS_PASS}"
MWSS_HOST="${MWSS_HOST}"
MWS_PATH="${MWS_PATH}"
XRAY_XHTTP4_PORT="${XRAY_XHTTP4_PORT}"
ENVEOF
  chmod 600 "$CONF_FILE"

  echo ""
  echo "✔ 已保存到 ${CONF_FILE}"
  echo ""
  echo "  MWSS_HOST        : ${MWSS_HOST}"
  echo "  MWS_PATH         : ${MWS_PATH}"
  echo "  MWSS_USER        : ${MWSS_USER}"
  echo "  MWSS_PASS        : ${MWSS_PASS}"
  echo "  SS_PASS          : ${SS_PASS}"
  echo "  SS_PORT          : ${SS_PORT}"
  echo "  XRAY_XHTTP4_PORT : ${XRAY_XHTTP4_PORT}"
  pause
}


get_public_ip() {
  curl -4 -fsSL https://api.ipify.org || echo "YOUR_SERVER_IP"
}

is_lxc() {
  grep -qa container=lxc /proc/1/environ 2>/dev/null
}

is_dual_stack() {
  ip -6 addr show scope global | grep -q inet6 \
  && ip -6 route show default | grep -q default
}

prefer_ipv4() {
  grep -q '^precedence ::ffff:0:0/96' "$GAI_CONF" 2>/dev/null || \
    echo "precedence ::ffff:0:0/96  100" >> "$GAI_CONF"
}

apply_sysctl() {
  sysctl --system >/dev/null
}

open_ports() {
  for p in "$@"; do
    if command -v ufw >/dev/null 2>&1; then
      ufw allow "${p}/tcp" || true
      ufw allow "${p}/udp" || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port="${p}/tcp" || true
      firewall-cmd --permanent --add-port="${p}/udp" || true
      firewall-cmd --reload || true
    else
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
      iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
    fi
  done
}

# =====================================================
# 母鸡内核参数（三档）
# =====================================================
profile_safe() {
cat << 'EOF' > "$SYSCTL_CONF"
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 87380 16777216
EOF
}

profile_recommended() {
cat << 'EOF' > "$SYSCTL_CONF"
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 131072 33554432
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
EOF
}

profile_aggressive() {
cat << 'EOF' > "$SYSCTL_CONF"
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 262144 67108864
net.ipv4.tcp_wmem=4096 262144 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_syncookies=1
EOF
}

kernel_menu() {
  is_lxc && { echo " LXC 容器不能修改母鸡内核"; pause; return; }
  while true; do
    clear
    echo "==== 母鸡网络优化 ===="
    echo "1) 安全档"
    echo "2) 推荐档 "
    echo "3) 激进档"
    echo "4) 回滚"
    echo "0) 返回"
    read -rp "选择: " k
    case "$k" in
      1|2|3)
        cp -f "$SYSCTL_CONF" "$SYSCTL_BACKUP" 2>/dev/null || true
        [[ $k == 1 ]] && profile_safe
        [[ $k == 2 ]] && profile_recommended
        [[ $k == 3 ]] && profile_aggressive
        apply_sysctl
        is_dual_stack && prefer_ipv4
        pause ;;
      4)
        [[ -f "$SYSCTL_BACKUP" ]] && cp "$SYSCTL_BACKUP" "$SYSCTL_CONF" && apply_sysctl
        pause ;;
      0) return ;;
    esac
  done
}

# =====================================================
# 状态查看
# =====================================================
show_status() {
  clear
  echo "环境        : $(is_lxc && echo LXC || echo 母鸡)"
  echo "内核版本    : $(uname -r)"
  echo
  echo "IPv6 双栈    : $(is_dual_stack && echo 是 || echo 否)"
  grep -q '^precedence ::ffff:0:0/96' "$GAI_CONF" && \
    echo "IPv4 优先   : 已启用" || echo "IPv4 优先   : 未启用"
  echo
  sysctl net.ipv4.tcp_congestion_control
  sysctl net.core.default_qdisc
  echo
  sysctl net.core.rmem_max
  sysctl net.core.wmem_max
  sysctl net.ipv4.tcp_rmem
  sysctl net.ipv4.tcp_wmem
  echo
  echo "Xray IPv4 会绑定：https://${MWSS_HOST}:443 → 127.0.0.1:${XRAY_XHTTP4_PORT}"
  if [[ -n "${XRAY_IPV6ADDR}" ]]; then
    echo "Xray IPv6 会绑定：[${XRAY_IPV6ADDR}]:443（公网 IPv6）"
  else
    echo "Xray IPv6：未检测到公网 IPv6，IPv6 443 节点将跳过"
  fi
  pause
}

# =====================================================
# 安装 Gost（单进程：mws + ss）
# =====================================================
install_gost() {
  apt-get update -y
  apt-get install -y curl tar supervisor ca-certificates jq

  ARCH=$(uname -m)
  [[ $ARCH == x86_64 ]] && GOARCH=amd64 || GOARCH=arm64

  TAG=$(curl -fsSL https://api.github.com/repos/go-gost/gost/releases/latest \
        | jq -r .tag_name)
  URL=$(curl -fsSL https://api.github.com/repos/go-gost/gost/releases/tags/${TAG} \
        | jq -r '.assets[]?.browser_download_url' | grep linux | grep ${GOARCH} | head -n1)

  mkdir -p "$GOST_DIR" "$LOG_GOST"
  local TMP_GOST
  TMP_GOST=$(mktemp -d)
  curl -fsSL "$URL" -o "${TMP_GOST}/gost.tgz"
  tar -xzf "${TMP_GOST}/gost.tgz" -C "${TMP_GOST}"
  install -m 0755 "$(find "${TMP_GOST}" -type f -name gost | head -n1)" "$GOST_BIN"
  rm -rf "${TMP_GOST}"

  # 写入 gost YAML 配置（权限 600，密码不暴露在进程列表）
  mkdir -p /etc/gost
  cat > /etc/gost/config.yaml << EOF
services:
  - name: mws-proxy
    addr: "127.0.0.1:18080"
    handler:
      type: auto
      auth:
        username: "${MWSS_USER}"
        password: "${MWSS_PASS}"
    listener:
      type: mws
      metadata:
        path: "${MWS_PATH}"

  - name: ss-tcp
    addr: ":${SS_PORT}"
    handler:
      type: ss
      auth:
        username: "${SS_METHOD}"
        password: "${SS_PASS}"
    listener:
      type: tcp

  - name: ss-udp
    addr: ":${SS_PORT}"
    handler:
      type: ssu
      auth:
        username: "${SS_METHOD}"
        password: "${SS_PASS}"
    listener:
      type: udp
EOF
  chmod 600 /etc/gost/config.yaml

  cat > /etc/supervisor/conf.d/gost.conf << EOF
[program:gost]
command=${GOST_BIN} -C /etc/gost/config.yaml
autorestart=true
stdout_logfile=${LOG_GOST}/gost.log
redirect_stderr=true
EOF

  systemctl enable --now supervisor >/dev/null 2>&1 || true
  supervisorctl reread
  supervisorctl update
  supervisorctl restart gost

  # 放行 SS 端口（TCP + UDP）
  open_ports "${SS_PORT}"

  IP=$(get_public_ip)
  cat <<EOM
========================================
 Gost 已安装（单进程）
- mws（反代后端） : mws://127.0.0.1:18080?path=${MWS_PATH}
- 认证             : ${MWSS_USER} / ${MWSS_PASS}
- SS（TCP/UDP）    : ss://${SS_METHOD}:${SS_PASS}@${IP}:${SS_PORT}
========================================
EOM
}

# =====================================================
# 安装 OpenResty + 反代 gost（自签证书）
# - 生成新的 nginx.conf（user www-data; include enabled-sites/*.conf）
# - 写入 enabled-sites/gost_mws.conf 反代到 127.0.0.1:18080
# =====================================================
install_openresty_proxy() {
  apt-get update -y
  apt-get install -y curl gnupg ca-certificates lsb-release

  # 安装官方 APT 源 & OpenResty
  curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg
  codename=$(lsb_release -sc)
  echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian ${codename} openresty" \
    > /etc/apt/sources.list.d/openresty.list
  apt-get update -y
  apt-get install -y openresty

  # 目录准备
  mkdir -p "${OR_ENABLED_SITES}" "${OR_SSL_DIR}"

  # 自签证书（CN = 域名）
  if [[ ! -s "${OR_SSL_DIR}/gost.key" || ! -s "${OR_SSL_DIR}/gost.crt" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "${OR_SSL_DIR}/gost.key" \
      -out "${OR_SSL_DIR}/gost.crt" \
      -days 3650 \
      -subj "/CN=${MWSS_HOST}"
  fi

  # 幂等 nginx.conf：只在不包含 sites-enabled include 时才写入
  if grep -q 'sites-enabled' "${OR_CONF_DIR}/nginx.conf" 2>/dev/null; then
    echo "nginx.conf 已包含 sites-enabled include，跳过覆写"
  else
    [[ -f "${OR_CONF_DIR}/nginx.conf" ]] && \
      cp -a "${OR_CONF_DIR}/nginx.conf" "${OR_CONF_DIR}/nginx.conf.bak.$(date +%s)"
    cat > "${OR_CONF_DIR}/nginx.conf" <<'NGINX_MAIN'
user  www-data;
worker_processes  auto;

error_log  logs/error.log warn;
pid        logs/nginx.pid;

events {
    worker_connections  10240;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;

    # WebSocket 升级映射
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    # 包含反代站点
    include sites-enabled/*.conf;
}
NGINX_MAIN
    echo "nginx.conf 已初始化"
  fi

  # 幂等写入反代站点（sites-enabled/gost_mws.conf）
  cat > "${OR_ENABLED_SITES}/gost_mws.conf" <<EOF
server {
    # http2 已安全启用：TLS 在 OpenResty 终止，Xray 只见 HTTP/1.1 内部连接
    listen              443 ssl http2;
    listen              [::]:443 ssl http2;   # 同时监听 IPv6，兼容无 IPv4 的机器
    server_name         ${MWSS_HOST};

    ssl_certificate     ${OR_SSL_DIR}/gost.crt;
    ssl_certificate_key ${OR_SSL_DIR}/gost.key;

    proxy_read_timeout  3600s;
    proxy_send_timeout  3600s;

    # Gost mws 反代（WebSocket）
    location ${MWS_PATH} {
        proxy_pass              http://127.0.0.1:18080;
        proxy_http_version      1.1;
        proxy_set_header        Upgrade \$http_upgrade;
        proxy_set_header        Connection \$connection_upgrade;
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto \$scheme;
    }

    # Xray xhttp 反代（流式 HTTP/1.1，不做协议升级）
    location / {
        proxy_pass              http://127.0.0.1:${XRAY_XHTTP4_PORT};
        proxy_http_version      1.1;
        # 显式清除 Upgrade/Connection，防止 gost 的 connection_upgrade map 干扰
        proxy_set_header        Upgrade    "";
        proxy_set_header        Connection "";
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto \$scheme;
        # xhttp 流式传输，必须关闭缓冲
        proxy_buffering         off;
        proxy_request_buffering off;
    }
}

# 可选：80 -> 443 跳转
server {
    listen      80;
    server_name ${MWSS_HOST};
    return 308 https://\$host\$request_uri;
}
EOF

  # 测试并启动
  openresty -t
  systemctl enable --now openresty
  systemctl reload openresty

  # 放行 443
  open_ports 443

  cat <<EOM
========================================
 OpenResty 已部署并作为 gost 反代 + IPv4 Xray xhttp 反代
- 主配置 : ${OR_CONF_DIR}/nginx.conf （user www-data; include sites-enabled/*.conf）
- 站点   : ${OR_ENABLED_SITES}/gost_mws.conf
- 证书   : ${OR_SSL_DIR}/gost.crt / ${OR_SSL_DIR}/gost.key （自签）
- IPv4=https://${MWSS_HOST} 走 OpenResty 443 → 127.0.0.1:${XRAY_XHTTP4_PORT}（Xray─xhttp）
- mws 服务 : https://${MWSS_HOST}${MWS_PATH}
========================================
EOM
}

# =====================================================
# 安装 Xray（VLESS-xhttp，由 OpenResty 双栈反代）
# =====================================================
install_xray() {
  echo
  echo "=> Xray 节点："
  echo "   统一监听 127.0.0.1:${XRAY_XHTTP4_PORT}"
  echo "   OpenResty 同时监听 IPv4 443 和 IPv6 443，全部反代到 Xray"
  echo

  apt-get install -y unzip openssl curl jq

  ARCH=$(uname -m)
  [[ $ARCH == x86_64 ]] && PKG="Xray-linux-64.zip" || PKG="Xray-linux-arm64-v8a.zip"
  VER=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | jq -r .tag_name)

  mkdir -p "$XRAY_DIR" /etc/xray/tls "$LOG_XRAY"
  curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/${VER}/${PKG}" -o /tmp/xray.zip
  unzip -o /tmp/xray.zip -d /tmp/xray
  install -m 0755 /tmp/xray/xray "$XRAY_BIN"

  UUID=$(cat /proc/sys/kernel/random/uuid)

  cat > /etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${XRAY_XHTTP4_PORT},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

  cat > /etc/supervisor/conf.d/xray.conf <<EOF
[program:xray]
command=${XRAY_BIN} run -config /etc/xray/config.json
autorestart=true
stdout_logfile=${LOG_XRAY}/xray.log
redirect_stderr=true
EOF

  systemctl enable --now supervisor >/dev/null 2>&1 || true
  supervisorctl reread
  supervisorctl update
  supervisorctl restart xray


  cat <<EOM
========================================
 Xray (VLESS-xhttp) 已安装
- UUID     : ${UUID}
- IPv4 节点 : https://${MWSS_HOST}:443
  说明：OpenResty 443 → 127.0.0.1:${XRAY_XHTTP4_PORT}（Xray 无 TLS xhttp）
  示例：vless://${UUID}@${MWSS_HOST}:443?encryption=none&security=tls&type=xhttp&host=${MWSS_HOST}&sni=${MWSS_HOST}&allowInsecure=0
========================================
EOM
}

# 打印二维码（自动安装 qrencode）
print_qr() {
  local data="$1"
  local label="${2:-}"
  if ! command -v qrencode >/dev/null 2>&1; then
    echo "  [安装 qrencode...]"
    apt-get install -y -q qrencode >/dev/null 2>&1 || { echo "  [qrencode 安装失败，跳过二维码]"; return; }
  fi
  [[ -n "$label" ]] && echo "  ▼ ${label}"
  echo ""
  qrencode -t ANSIUTF8 -m 2 "$data"
  echo ""
}

# =====================================================
# 查看当前连接配置
# =====================================================
show_connections() {
  clear
  echo "========================================"
  echo "   当前连接配置"
  echo "========================================"
  echo ""

  # 先读取域名（后面两个区块共用）
  local domain
  domain=$(grep -rh 'server_name' /usr/local/openresty/nginx/conf/sites-enabled/ 2>/dev/null \
           | grep -v '#' | awk '/server_name/{print $2}' | tr -d ';' | head -n1)
  domain=${domain:-"YOUR_DOMAIN"}

  # 交互式输入优选 Cloudflare IP
  echo "域名：${domain}"
  echo ""
  echo "  提示：可通过 https://github.com/XIU2/CloudflareSpeedTest 测试得到延迟最低的优选 IP"
  echo ""
  read -rp "请输入优选 Cloudflare IP（直接回车则使用域名）：" cf_ip
  local cf_target
  if [[ -n "$cf_ip" ]]; then
    cf_target="$cf_ip"
    echo ""
    echo "⚠ 连接目标：${cf_target}（优选 CF IP），SNI/host 保持域名 ${domain}"
  else
    cf_target="$domain"
    echo ""
    echo "⚠ 连接目标：${cf_target}（域名）"
  fi
  echo ""

  # 读取 Gost 配置
  local GOST_CONF="/etc/gost/config.yaml"
  if [[ -f "$GOST_CONF" ]]; then
    echo "■ Gost 配置：${GOST_CONF}"
    echo "-----------------------------------------"
    local mws_user mws_pass mws_path ss_pass ss_method ss_port
    mws_user=$(awk '/name: mws-proxy/{found=1} found && /username:/{gsub(/"|\x27/,"",$2); print $2; exit}' "$GOST_CONF")
    mws_pass=$(awk '/name: mws-proxy/{found=1} found && /password:/{gsub(/"|\x27/,"",$2); print $2; exit}' "$GOST_CONF")
    mws_path=$(awk '/name: mws-proxy/{found=1} found && /path:/{gsub(/"|\x27/,"",$2); print $2; exit}' "$GOST_CONF")
    ss_method=$(awk '/name: ss-tcp/{found=1} found && /username:/{gsub(/"|\x27/,"",$2); print $2; exit}' "$GOST_CONF")
    ss_pass=$(awk '/name: ss-tcp/{found=1} found && /password:/{gsub(/"|\x27/,"",$2); print $2; exit}' "$GOST_CONF")
    ss_port=$(awk '/name: ss-tcp/{found=1} found && /addr:/{gsub(/":.*/,"",$2); gsub(/[":]*/,"",$2); match($2,/[0-9]+/); print substr($2,RSTART,RLENGTH); exit}' "$GOST_CONF")
    # addr 字段中 ":port" 格式
    ss_port=$(awk '/name: ss-tcp/{found=1} found && /addr:/{match($2,/[0-9]+/); print substr($2,RSTART,RLENGTH); exit}' "$GOST_CONF")

    local pub_ip or_host
    pub_ip=$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")
    or_host="$domain"   # 使用已获取的全局域名

    echo "  mws 用户名  : ${mws_user}"
    echo "  mws 密码    : ${mws_pass}"
    echo "  mws 路径    : ${mws_path}"
    echo "  SS 加密方式 : ${ss_method}"
    echo "  SS 密码     : ${ss_pass}"
    echo "  SS 端口     : ${ss_port}"
    echo ""
    echo "  ── Gost 客户端连接命令 ──────────────────────"
    echo ""
    echo "  [mwss] 经 Cloudflare/OpenResty TLS 443（推荐）："
    echo "  ./gost -L=:1080 -F \"mwss://${mws_user}:${mws_pass}@${cf_target}:443?path=${mws_path}&secure=true&serverName=${or_host}&host=${or_host}\""
    echo ""
    echo "  [mws]  直连服务器 IP（不经 CDN，速度更快但暴露 IP）："
    echo "  ./gost -L=:1080 -F \"mws://${mws_user}:${mws_pass}@${pub_ip}:443?path=${mws_path}\""
    echo ""
    echo "  [ss]   Shadowsocks 连接串（ShadowRocket / Clash 等客户端）："
    ss_b64=$(printf '%s:%s' "${ss_method}" "${ss_pass}" | base64 -w0)
    local ss_uri="ss://${ss_b64}@${pub_ip}:${ss_port}"
    echo "  ${ss_uri}"
    print_qr "${ss_uri}" "SS 扫码导入"
  else
    echo "  [未找到] ${GOST_CONF}，请先安装 Gost"
  fi

  echo ""
  echo "========================================"
  echo ""

  # 读取 Xray 配置
  local XRAY_CONF="/etc/xray/config.json"
  if [[ -f "$XRAY_CONF" ]]; then
    echo "■ Xray 配置：${XRAY_CONF}"
    echo "-----------------------------------------"
    local uuid xhttp_port xhttp_ipv6
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$XRAY_CONF" 2>/dev/null)
    xhttp_port=$(jq -r '.inbounds[0].port // empty' "$XRAY_CONF" 2>/dev/null)
    # 检测 IPv6 入站（第二个 inbound）
    xhttp_ipv6=$(jq -r '.inbounds[1].listen // empty' "$XRAY_CONF" 2>/dev/null)

    local host
    host="$domain"   # 使用已获取的全局域名

    echo "  UUID       : ${uuid}"
    echo "  域名       : ${host}"
    echo "  连接目标   : ${cf_target}"
    echo "  IPv4 端口   : 443 (经 OpenResty 反代 → 127.0.0.1:${xhttp_port})"
    echo ""
    echo "  [IPv4] VLESS-xhttp 连接串："
    local v4_uri="vless://${uuid}@${cf_target}:443?encryption=none&security=tls&type=xhttp&host=${host}&sni=${host}&path=%2F&allowInsecure=0"
    echo "  ${v4_uri}"
    print_qr "${v4_uri}" "VLESS IPv4 扫码导入"

    if [[ -n "${xhttp_ipv6}" ]]; then
      echo ""
      echo "  [IPv6] VLESS-xhttp 连接串："
      local v6_uri="vless://${uuid}@[${xhttp_ipv6}]:443?encryption=none&security=tls&type=xhttp&path=%2F&allowInsecure=0"
      echo "  ${v6_uri}"
      print_qr "${v6_uri}" "VLESS IPv6 扫码导入"
    fi
  else
    echo "  [未找到] ${XRAY_CONF}，请先安装 Xray"
  fi

  echo ""
  echo "========================================"
  pause
}

# 首次运行未找到配置文件时自动进入配置向导
if [[ ! -f "$CONF_FILE" ]]; then
  echo ""
  echo "未检测到配置文件 ${CONF_FILE}，请先完成初始配置。"
  configure_settings
fi

while true; do
  clear
  echo "========== 管理菜单 =========="
  echo "1) 母鸡网络优化"
  echo "2) 查看系统状态"
  echo "3) 修改配置"
  echo "4) 安装 Gost（mws + ss）"
  echo "5) 部署 OpenResty 反代（自签证书）"
  echo "6) 安装 Xray (VLESS-xhttp)"
  echo "7) Supervisor 状态"
  echo "8) 生成客户端连接 / 优选 IP"
  echo "0) 退出"
  read -rp "选择: " c
  case "$c" in
    1) kernel_menu ;;
    2) show_status ;;
    3) configure_settings ;;
    4) install_gost; pause ;;
    5) install_openresty_proxy; pause ;;
    6) install_xray; pause ;;
    7) supervisorctl status; pause ;;
    8) show_connections ;;
    0) exit 0 ;;
  esac
done
