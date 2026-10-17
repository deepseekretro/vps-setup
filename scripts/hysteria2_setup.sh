#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Hysteria2 节点安装 / 管理（宿主机专用）
#   https://v2.hysteria.network/
#
# 用法：
#   bash hysteria2_setup.sh                 # 交互菜单
#   bash hysteria2_setup.sh --install       # 直接安装/重装（随机密码）
#   bash hysteria2_setup.sh --dry-run       # 演练，不写系统
#   bash hysteria2_setup.sh --status        # 运行状态
#   bash hysteria2_setup.sh --info          # 连接信息（密码 + 链接）
#   bash hysteria2_setup.sh --restart       # 重启服务
#   bash hysteria2_setup.sh --uninstall     # 卸载
#
# 可选参数：
#   --port 443              监听 UDP 端口
#   --domain bing.com       SNI / 自签证书 CN
#   --mask-url URL          masquerade 伪装目标（默认 https://bing.com/）
#   --no-qr                 不输出二维码
#   --new-password          强制重新生成随机密码
#   --keep-password         沿用已有密码（默认交互询问）
# ============================================

# ─────────────── 默认配置 ───────────────
PORT="443"
DOMAIN="bing.com"
MASK_URL="https://bing.com/"

HY_BIN="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
TLS_DIR="${CONFIG_DIR}/tls"
TLS_CRT="${TLS_DIR}/hy2.crt"
TLS_KEY="${TLS_DIR}/hy2.key"
SERVICE_NAME="hysteria-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

MODE="menu"
DRY=0
QR=1
FORCE_NEW_PASS=0
KEEP_PASS=0
ASSUME_YES=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { printf '\033[1;34m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

print_success() { ok "$1"; }
print_error()   { err "$1"; }
print_warning() { warn "$1"; }
print_info()    { printf '\033[0;34mℹ\033[0m %s\n' "$1"; }

# ─────────────── 参数解析 ───────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)       MODE="install";   shift ;;
    --status)        MODE="status";    shift ;;
    --info)          MODE="info";      shift ;;
    --restart)       MODE="restart";   shift ;;
    --uninstall)     MODE="uninstall"; shift ;;
    --dry-run)       DRY=1;            shift ;;
    --port)          PORT="$2";        shift 2 ;;
    --domain)        DOMAIN="$2";      shift 2 ;;
    --mask-url)      MASK_URL="$2";    shift 2 ;;
    --no-qr)         QR=0;             shift ;;
    --new-password)  FORCE_NEW_PASS=1; shift ;;
    --keep-password) KEEP_PASS=1;      shift ;;
    -y|--yes)        ASSUME_YES=1;     shift ;;
    -h|--help)       sed -n '2,24p' "$0"; exit 0 ;;
    *) err "未知参数: $1（--help 看用法）"; exit 1 ;;
  esac
done

# ─────────────── 通用辅助 ───────────────
run() { if (( DRY )); then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }

put() { # 内容从 stdin 写入文件（dry-run 只打印）
  local path="$1"
  if (( DRY )); then
    printf '   [dry-run] 写入 %s:\n' "$path"
    sed 's/^/       | /'
  else
    mkdir -p "$(dirname "$path")"
    cat > "$path"
    printf '   wrote %s\n' "$path"
  fi
}

randpass() { # 24 位随机密码（字母+数字，URL 安全）
  local p=""
  p=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' || true)
  p="${p:0:24}"
  if (( ${#p} < 20 )); then
    p=$(openssl rand -hex 16)
  fi
  printf '%s' "$p"
}

current_pass() { # 从已有配置里读回密码
  [[ -f "$CONFIG_FILE" ]] || return 1
  sed -n 's/^[[:space:]]*password:[[:space:]]*//p' "$CONFIG_FILE" | head -1 \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

get_public_ip() {
  curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null \
    || curl -fsSL --max-time 8 https://ifconfig.me 2>/dev/null \
    || echo "unknown"
}

# systemctl is-active 对不存在的单元也会打印 inactive，这里收敛成一行
svc_state() {
  local s=""
  s=$(systemctl is-active "$SERVICE_NAME.service" 2>/dev/null | head -1 || true)
  printf '%s' "${s:-unknown}"
}

# ─────────────── 环境检测 ───────────────
detect_container() {
  local v=""
  if command -v systemd-detect-virt &> /dev/null; then
    v=$(systemd-detect-virt --container 2>/dev/null || true)
    if [[ -n "$v" && "$v" != "none" ]]; then echo "$v"; return 0; fi
    return 1
  fi
  if grep -qaE '(^| )container=' /proc/1/environ 2>/dev/null; then echo "unknown"; return 0; fi
  if [[ -e /.dockerenv ]]; then echo "docker"; return 0; fi
  return 1
}

require_host() {
  local ctx=""
  if ctx=$(detect_container); then
    err "当前运行在容器内（${ctx}），已拒绝安装/卸载"
    echo ""
    warn "Hysteria2 需要监听宿主机 UDP ${PORT} 并配置宿主防火墙，"
    warn "在容器内安装后外网无法直达（宿主机没有对应的 UDP 转发规则）。"
    echo ""
    echo "请在 LXC/物理宿主机上运行本工具："
    echo "  bash <(curl -fsSL ${BASE_URL:-https://raw.githubusercontent.com/deepseekretro/vps-setup/main}/main.sh)"
    echo "或直接在宿主机上执行本脚本："
    echo "  sudo bash hysteria2_setup.sh --install"
    echo ""
    return 1
  fi
  if [[ $EUID -ne 0 ]]; then
    err "需要 root 权限（宿主机上请用 sudo）"
    return 1
  fi
  return 0
}

# ─────────────── 安装相关 ───────────────
ensure_deps() {
  log "检查依赖"
  local miss=() opt=()
  for c in curl jq openssl; do
    command -v "$c" &> /dev/null || miss+=("$c")
  done
  # qrencode 只用于终端二维码展示，属可选依赖
  command -v qrencode &> /dev/null || opt+=("qrencode")

  if (( ${#miss[@]} )); then
    if (( DRY )); then
      echo "   [dry-run] apt-get install -y ${miss[*]} ca-certificates"
    else
      ok "安装缺失依赖：${miss[*]}"
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y "${miss[@]}" ca-certificates
    fi
  else
    ok "依赖齐全（curl / jq / openssl）"
  fi

  if (( ${#opt[@]} )); then
    if (( DRY )); then
      echo "   [dry-run] apt-get install -y ${opt[*]}（可选，用于输出二维码）"
    elif (( QR )); then
      if apt-get install -y "${opt[@]}" >/dev/null 2>&1; then
        ok "已安装可选依赖：${opt[*]}（用于二维码）"
      else
        warn "可选依赖 ${opt[*]} 安装失败，将不显示二维码"
      fi
    fi
  else
    ok "二维码依赖就绪（qrencode）"
  fi
}

hy_arch() {
  case "$(uname -m)" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l)  echo "armv7" ;;
    *)       err "不支持的系统架构: $(uname -m)"; return 1 ;;
  esac
}

fetch_version() {
  if ! command -v jq &> /dev/null; then
    if (( DRY )); then warn "dry-run：未安装 jq，跳过版本查询" >&2; fi
    return 0
  fi
  curl -fsSL --max-time 20 https://api.github.com/repos/apernet/hysteria/releases/latest \
    | jq -r '.tag_name // empty'
}

open_port() {
  local port="$1"
  if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    run ufw allow "${port}/udp" >/dev/null 2>&1 || true
    ok "[UFW] 已放行 UDP ${port}"
  fi
  if command -v iptables &> /dev/null; then
    run iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null \
      || run iptables -I INPUT -p udp --dport "$port" -j ACCEPT
    run ip6tables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null \
      || run ip6tables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    ok "[iptables] 已放行 UDP ${port}"
    # iptables 规则默认不持久化，重启即失效
    if command -v netfilter-persistent &> /dev/null; then
      run netfilter-persistent save >/dev/null 2>&1 || true
      ok "[netfilter-persistent] 规则已保存（重启后仍生效）"
    else
      warn "未检测到 netfilter-persistent，规则重启后会丢失，请自行持久化"
    fi
  fi
}

gen_cert() {
  if [[ -s "$TLS_CRT" && -s "$TLS_KEY" ]]; then
    ok "TLS 证书已存在，跳过（${TLS_CRT}）"
    return 0
  fi
  log "生成自签 TLS 证书（CN/SAN = ${DOMAIN}）"
  run mkdir -p "$TLS_DIR"
  run openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$TLS_KEY" -out "$TLS_CRT" \
    -days 3650 -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN}"
  ok "证书已生成"
}

write_config() {
  local pass="$1"
  log "写入配置 ${CONFIG_FILE}"
  put "$CONFIG_FILE" <<EOF
listen: :${PORT}

tls:
  cert: ${TLS_CRT}
  key:  ${TLS_KEY}

auth:
  type: password
  password: ${pass}

masquerade:
  type: proxy
  proxy:
    url: ${MASK_URL}
    rewriteHost: true
EOF
}

write_unit() {
  log "写入 systemd 单元 ${SERVICE_FILE}"
  put "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria 2 Server Service
Documentation=https://v2.hysteria.network/
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_DIR}
ExecStart=${HY_BIN} server -c ${CONFIG_FILE}
Restart=always
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

# 标准输出及错误重定向到 journald
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

do_install() {
  log "================ Hysteria2 安装 ================"
  echo "   监听      UDP ${PORT}"
  echo "   SNI/证书  ${DOMAIN}"
  echo "   伪装目标  ${MASK_URL}"
  echo ""

  ensure_deps

  local arch ver url
  arch=$(hy_arch)
  ok "系统架构：$(uname -m) → ${arch}"

  ver=$(fetch_version)
  if [[ -z "$ver" ]]; then
    if (( DRY )); then
      ver="<LATEST>"
    else
      err "获取最新版本失败（GitHub API 不可达？）"
      return 1
    fi
  fi
  url="https://github.com/apernet/hysteria/releases/download/${ver}/hysteria-linux-${arch}"
  ok "版本：${ver}"
  echo "   下载：${url}"

  # 密码：沿用 / 新建
  local pass="" existing=""
  existing=$(current_pass || true)
  if [[ -n "$existing" ]]; then
    if (( FORCE_NEW_PASS )); then
      pass=$(randpass)
      warn "已存在配置 → 按要求生成新密码"
    elif (( KEEP_PASS )); then
      pass="$existing"
      ok "已存在配置 → 沿用原密码"
    else
      echo ""
      print_info "检测到已有配置 ${CONFIG_FILE}"
      local ans=""
      # 非交互（无 tty / 管道 / 被其它脚本调用）时 read 会失败，
      # set -e 下会直接中断，这里兜住并按默认「保留」处理
      read -p "保留现有密码？(Y=保留 / n=生成新随机密码): " ans || true
      if [[ "$ans" == "n" || "$ans" == "N" ]]; then
        pass=$(randpass)
        ok "已生成新随机密码"
      else
        pass="$existing"
        ok "沿用原密码"
      fi
    fi
  else
    pass=$(randpass)
    ok "已生成随机密码"
  fi
  [[ -n "$pass" ]] || { err "密码生成失败"; return 1; }

  # 端口占用提示
  if command -v ss &> /dev/null; then
    if ss -lun 2>/dev/null | awk '{print $5}' | grep -qE "(:|\.)${PORT}\$"; then
      warn "UDP ${PORT} 似乎已被占用，请确认不会冲突"
    fi
  fi

  run mkdir -p "$(dirname "$HY_BIN")" "$CONFIG_DIR" "$TLS_DIR"

  log "下载二进制"
  run curl -fsSL "$url" -o "$HY_BIN"
  run chmod +x "$HY_BIN"
  if (( ! DRY )); then
    "$HY_BIN" version 2>&1 | head -2 | sed 's/^/   /' || true
  fi

  gen_cert
  write_config "$pass"
  write_unit

  log "启用并启动服务"
  run systemctl daemon-reload
  # 注意：Type=simple 的单元若已经 active，`enable --now` 不会重跑 ExecStart，
  # 这里显式 restart，保证重装后加载的是新配置/新密码。
  run systemctl enable "$SERVICE_NAME.service"
  run systemctl restart "$SERVICE_NAME.service"

  log "放行防火墙端口"
  open_port "$PORT"

  echo ""
  if (( DRY )); then
    warn "以上为演练，未对系统做任何改动"
    echo ""
  fi
  print_conn_info "$pass" "$ver"
}

# ─────────────── 状态 / 信息 ───────────────
print_qr() { # print_qr <内容>：用 qrencode 在终端渲染二维码
  local text="$1"
  (( QR )) || return 0
  [[ -n "$text" ]] || return 0
  if ! command -v qrencode &> /dev/null; then
    echo "  （未安装 qrencode，跳过二维码：apt-get install -y qrencode）"
    return 0
  fi
  echo " 扫码导入（手机客户端）："
  echo ""
  if ! qrencode -t ANSIUTF8 -m 1 "$text" 2>/dev/null; then
    qrencode -t UTF8 -m 1 "$text" || warn "二维码渲染失败"
  fi
  echo ""
}

print_conn_info() {
  local pass="${1:-$(current_pass || true)}"
  local ver="${2:-未知}"
  local ip link
  ip=$(get_public_ip)
  link="hy2://${pass}@${ip}:${PORT}/?sni=${DOMAIN}&insecure=1"

  echo "========================================"
  echo " Hysteria2 连接信息"
  echo "----------------------------------------"
  echo "  版本    : ${ver}"
  echo "  状态    : $(svc_state)"
  echo "  端口    : UDP ${PORT}"
  echo "  SNI     : ${DOMAIN}（仅用于 TLS/SNI）"
  echo "  密码    : ${pass:-（未找到，见 ${CONFIG_FILE}）}"
  echo "----------------------------------------"
  echo " 导入链接："
  echo " ${link}"
  echo "========================================"
  echo ""
  print_qr "$link"
  echo " 提示：insecure=1 是因为使用自签证书；如已换成受信任证书可去掉。"
  echo ""
}

show_status() {
  local ctx=""
  if ctx=$(detect_container); then
    warn "正在容器内运行（${ctx}）：以下状态/信息来自本容器，不是宿主机"
    echo ""
  fi
  echo "── 服务 ────────────────────────────────"
  if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
    systemctl status "$SERVICE_NAME.service" --no-pager -l 2>&1 | head -12 | sed 's/^/  /'
  else
    echo "  (未安装 ${SERVICE_NAME}.service)"
  fi
  echo "── 监听 ────────────────────────────────"
  if command -v ss &> /dev/null; then
    ss -lunp 2>/dev/null | grep -E "[:.]${PORT}[[:space:]]" | sed 's/^/  /' || echo "  (UDP ${PORT} 无监听)"
  fi
  echo "── 二进制 ──────────────────────────────"
  if [[ -x "$HY_BIN" ]]; then
    printf '  %s\n' "$HY_BIN"
    "$HY_BIN" version 2>&1 | head -2 | sed 's/^/  /' || true
  else
    echo "  (未安装)"
  fi
  echo "── 配置 ────────────────────────────────"
  if [[ -f "$CONFIG_FILE" ]]; then
    grep -vE "password:" "$CONFIG_FILE" | sed 's/^/  /'
    echo "  (password 字段已隐藏，可用「连接信息」查看)"
  else
    echo "  (${CONFIG_FILE} 不存在)"
  fi
  echo ""
}

show_info() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    warn "未找到配置 ${CONFIG_FILE}，Hysteria2 可能尚未安装"
    echo ""
    return 0
  fi
  local ver="未知" v=""
  if [[ -x "$HY_BIN" ]]; then
    v=$("$HY_BIN" version 2>/dev/null | awk -F'\t' '/^Version:/{print $2; exit}' || true)
    if [[ -n "$v" ]]; then ver="$v"; fi
  fi
  print_conn_info "" "$ver"
}

do_restart() {
  log "重启 ${SERVICE_NAME}"
  run systemctl restart "$SERVICE_NAME.service"
  sleep 1
  ok "当前状态：$(svc_state)"
}

show_logs() {
  log "最近 50 行日志"
  journalctl -u "$SERVICE_NAME" -n 50 --no-pager -o cat 2>&1 | sed 's/^/  /' || true
  echo ""
}

follow_logs() {
  warn "实时日志：按 Ctrl-C 退出"
  echo ""
  journalctl -u "$SERVICE_NAME" -f -o cat || true
}

do_uninstall() {
  echo ""
  warn "将执行："
  echo "  • systemctl disable --now ${SERVICE_NAME}"
  echo "  • 删除 ${SERVICE_FILE}"
  echo "  • 删除 ${HY_BIN}"
  echo "  • 可选删除 ${CONFIG_DIR}（含自签证书）"
  echo "  • 防火墙放行规则【不会】自动删除，需手动清理"
  echo ""
  if (( ASSUME_YES )); then
    local c="y"
  else
    local c=""
    read -p "确认卸载？(y/N): " c || true
  fi
  if [[ "$c" != "y" && "$c" != "Y" ]]; then
    print_info "已取消"
    return 0
  fi

  log "停止并禁用服务"
  run systemctl disable --now "$SERVICE_NAME.service" 2>/dev/null || true
  run rm -f "$SERVICE_FILE"
  run systemctl daemon-reload
  run rm -f "$HY_BIN"

  local delcfg=""
  if (( ASSUME_YES )); then
    delcfg="n"
  else
    read -p "是否一并删除 ${CONFIG_DIR}（含证书与密码）？(y/N): " delcfg || true
  fi
  if [[ "$delcfg" == "y" || "$delcfg" == "Y" ]]; then
    run rm -rf "$CONFIG_DIR"
    ok "已删除 ${CONFIG_DIR}"
  else
    print_info "保留 ${CONFIG_DIR}（如需恢复只需重新安装）"
  fi

  echo ""
  ok "卸载完成"
  warn "如需彻底清理端口放行：iptables -D INPUT -p udp --dport ${PORT} -j ACCEPT"
  echo ""
}

# ─────────────── 菜单 ───────────────
show_menu() {
  clear
  echo "=========================================="
  echo "   🚀 Hysteria2 节点（宿主机）"
  echo "=========================================="
  echo ""

  local ctx=""
  if ctx=$(detect_container); then
    print_warning "运行环境：容器（${ctx}）→ 仅可查看，安装/卸载会被拒绝"
  else
    print_success "运行环境：宿主机"
  fi
  echo ""

  local st="${RED}未安装${NC}"
  if [[ -f "$CONFIG_FILE" ]]; then
    if systemctl is-active "$SERVICE_NAME.service" &> /dev/null; then
      st="${GREEN}运行中${NC}"
    else
      st="${YELLOW}已安装但未运行${NC}"
    fi
  fi
  echo -e "当前状态：${st}   端口：UDP ${PORT}   伪装：${MASK_URL}"
  echo ""

  echo "【安装】"
  echo "1. 安装 / 重装（随机密码）"
  echo "2. 演练安装（--dry-run，不写系统）"
  echo ""
  echo "【查看】"
  echo "3. 运行状态"
  echo "4. 连接信息（密码 + 导入链接）"
  echo "5. 最近日志"
  echo "6. 实时日志（Ctrl-C 退出）"
  echo ""
  echo "【维护】"
  echo "7. 重启服务"
  echo "8. 卸载"
  echo ""
  echo "0. 返回主菜单"
  echo "=========================================="
}

pause() { read -p "按 Enter 键返回..." _ || true; }

hysteria2_menu() {
  while true; do
    show_menu
    read -p "请选择操作 [0-8]: " choice || return 0

    case $choice in
      1) require_host && do_install; pause ;;
      2) DRY=1; do_install; DRY=0; pause ;;
      3) show_status; pause ;;
      4) show_info; pause ;;
      5) show_logs; pause ;;
      6) follow_logs; pause ;;
      7) require_host && do_restart; pause ;;
      8) do_uninstall; pause ;;
      0) echo ""; print_success "返回主菜单"; sleep 1; return 0 ;;
      *) print_error "无效选择"; sleep 2 ;;
    esac
  done
}

# ─────────────── 入口 ───────────────
case "$MODE" in
  install)   require_host && do_install; exit $? ;;
  status)    show_status; exit 0 ;;
  info)      show_info; exit 0 ;;
  restart)   require_host && do_restart; exit $? ;;
  uninstall) require_host && do_uninstall; exit $? ;;
  menu)      hysteria2_menu ;;
esac
