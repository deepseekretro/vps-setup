#!/bin/bash
set -euo pipefail

# ============================================
# 宿主机 ZRAM 压缩交换 子菜单
# 注意：zram 属于「宿主机」功能（LXC / 物理宿主）。
#       在容器内只能查看，部署/回滚会被拒绝。
# ============================================

BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/deepseekretro/vps-setup/main}"
ZRAM_URL="${BASE_URL}/zram-setup.sh"
TMP_SCRIPT="/tmp/zram-setup.sh"
LOCAL_SCRIPT="/usr/local/sbin/zram-setup.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }

# ============================================
# 环境检测
# ============================================

# 返回容器类型（成功=在容器内），否则失败
detect_container() {
    local v=""
    if command -v systemd-detect-virt &> /dev/null; then
        v=$(systemd-detect-virt --container 2>/dev/null || true)
        if [[ -n "$v" && "$v" != "none" ]]; then
            echo "$v"
            return 0
        fi
        return 1
    fi
    if grep -qaE '(^| )container=' /proc/1/environ 2>/dev/null; then
        echo "unknown"
        return 0
    fi
    if [[ -e /.dockerenv ]]; then
        echo "docker"
        return 0
    fi
    return 1
}

# 写操作前的守卫：容器内拒绝，非 root 拒绝
require_host() {
    local ctx=""
    if ctx=$(detect_container); then
        print_error "当前运行在容器内（${ctx}），zram 是宿主机功能，已拒绝执行写操作"
        echo ""
        print_warning "容器内可见的是【宿主机】的 /sys/block/zram0 和 /proc/swaps，"
        print_warning "在此部署/回滚会直接影响宿主机的 swap，因此被禁止。"
        echo ""
        echo "请在 LXC/物理宿主机上运行本工具，例如："
        echo "  bash <(curl -fsSL ${BASE_URL}/main.sh)"
        echo ""
        echo "或直接在宿主机上使用脚本本体："
        echo "  curl -fsSL ${ZRAM_URL} -o /usr/local/sbin/zram-setup.sh"
        echo "  chmod +x /usr/local/sbin/zram-setup.sh"
        echo ""
        return 1
    fi
    if [[ $EUID -ne 0 ]]; then
        print_error "需要 root 权限（宿主机上请用 sudo）"
        return 1
    fi
    return 0
}

fetch_script() {
    print_info "正在获取 zram-setup.sh ..."
    if curl -fsSL -H 'Cache-Control: no-cache' "${ZRAM_URL}?t=$(date +%s)" -o "$TMP_SCRIPT"; then
        chmod +x "$TMP_SCRIPT" 2>/dev/null || true
        print_success "已获取：$TMP_SCRIPT"
        return 0
    fi
    print_error "下载失败：${ZRAM_URL}"
    return 1
}

# 执行 zram-setup.sh，参数原样透传
run_zram() {
    local args=("$@")
    if ! fetch_script; then
        read -p "按 Enter 键返回..."
        return 1
    fi
    echo ""
    if (( ${#args[@]} )); then
        print_info "执行：zram-setup.sh ${args[*]}"
    else
        print_info "执行：zram-setup.sh（自动调参并部署）"
    fi
    echo ""
    local rc=0
    if (( ${#args[@]} )); then
        bash "$TMP_SCRIPT" "${args[@]}" || rc=$?
    else
        bash "$TMP_SCRIPT" || rc=$?
    fi
    echo ""
    if (( rc == 0 )); then
        print_success "执行完成"
    else
        print_error "执行失败（退出码 ${rc}）"
    fi
    read -p "按 Enter 键返回..."
    return 0
}

# ============================================
# 功能函数
# ============================================

# 只读：状态 / 预览 / 演练 / 帮助
run_readonly() {
    local args=("$@")
    local ctx=""
    if ctx=$(detect_container); then
        echo ""
        print_warning "正在容器内运行（${ctx}）：以下数据来自【宿主机】，仅供查看"
    fi
    run_zram "${args[@]}"
}

zram_status() {
    run_readonly --status
}

zram_explain() {
    run_readonly --explain
}

zram_dryrun() {
    run_readonly --dry-run
}

zram_deploy() {
    require_host || { read -p "按 Enter 键返回..."; return 1; }
    echo ""
    print_warning "即将按【自动调参】部署/更新 zram 压缩交换："
    echo "  • 会重新配置 /dev/zram0（必要时先 swapoff + reset）"
    echo "  • 会重写 /etc/systemd/system/zram-swap.service 与 /usr/local/sbin/zram-swap-*"
    echo "  • 会更新 /etc/sysctl.d/90-zram.conf（整机参数，影响所有容器）"
    echo "  • 已存在的非 zram swap（如 /swapfile）默认保持不动"
    echo ""
    read -p "确认执行？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消"
        read -p "按 Enter 键返回..."
        return 0
    fi
    echo ""
    print_info "提示：可先跑一次「自动调参预览」，确认数值再部署"
    run_zram
}

zram_custom() {
    require_host || { read -p "按 Enter 键返回..."; return 1; }
    echo ""
    echo "=========================================="
    echo "   自定义参数部署"
    echo "=========================================="
    echo ""
    print_info "所有项留空即使用自动调参值"
    echo ""

    local args=()
    local size="" algo="" ml="" sw="" sf="" ksm="" nosys=""

    read -p "zram 容量（如 2G / 1500M，留空=自动）: " size
    [[ -n "$size" ]] && args+=(--size "$size")

    read -p "压缩算法 [zstd/lz4/lzo-rle]（留空=自动）: " algo
    [[ -n "$algo" ]] && args+=(--algo "$algo")

    read -p "zram 真实内存上限（如 512M，留空=自动）: " ml
    [[ -n "$ml" ]] && args+=(--mem-limit "$ml")

    read -p "swappiness（留空=自动）: " sw
    [[ -n "$sw" ]] && args+=(--swappiness "$sw")

    read -p "磁盘 swapfile [auto/off/如 2G]（留空=auto）: " sf
    [[ -n "$sf" ]] && args+=(--swapfile "$sf")

    read -p "调整已存在的 swapfile 大小？(y/N): " rsw
    [[ "$rsw" == "y" || "$rsw" == "Y" ]] && args+=(--resize-swapfile)

    read -p "开启 KSM 页面去重？(y/N): " do_ksm
    [[ "$do_ksm" == "y" || "$do_ksm" == "Y" ]] && args+=(--ksm)

    read -p "跳过全局 vm.* 调参？(y/N): " nosys
    [[ "$nosys" == "y" || "$nosys" == "Y" ]] && args+=(--no-sysctl)

    echo ""
    if (( ${#args[@]} )); then
        print_info "将执行：zram-setup.sh ${args[*]}"
    else
        print_info "将执行：zram-setup.sh（全部自动调参）"
    fi
    read -p "确认执行？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消"
        read -p "按 Enter 键返回..."
        return 0
    fi

    if (( ${#args[@]} )); then
        run_zram "${args[@]}"
    else
        run_zram
    fi
}

zram_install() {
    require_host || { read -p "按 Enter 键返回..."; return 1; }
    echo ""
    if ! fetch_script; then
        read -p "按 Enter 键返回..."
        return 1
    fi
    if install -m 0755 "$TMP_SCRIPT" "$LOCAL_SCRIPT"; then
        print_success "已安装到 ${LOCAL_SCRIPT}"
        echo ""
        echo "以后可直接运行："
        echo "  sudo ${LOCAL_SCRIPT} --status"
        echo "  sudo ${LOCAL_SCRIPT} --dry-run"
        echo "  sudo ${LOCAL_SCRIPT}"
        echo "  sudo ${LOCAL_SCRIPT} --rollback"
    else
        print_error "安装失败"
    fi
    echo ""
    read -p "按 Enter 键返回..."
}

zram_rollback() {
    require_host || { read -p "按 Enter 键返回..."; return 1; }
    echo ""
    print_warning "回滚将执行："
    echo "  • 停用 zram-swap.service / zram-mem-limit.service"
    echo "  • swapoff /dev/zram0"
    echo "  • 删除本脚本生成的 unit、辅助脚本、sysctl 配置"
    echo "  • 仅当 swapfile 是本脚本创建时才会被删除"
    echo "  • 原有的 swap 设备不动"
    echo ""
    read -p "确认回滚？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消"
        read -p "按 Enter 键返回..."
        return 0
    fi
    run_zram --rollback
}

# ============================================
# 子菜单
# ============================================

show_zram_menu() {
    clear
    echo "=========================================="
    echo "   🧠 宿主机 ZRAM 压缩交换"
    echo "=========================================="
    echo ""

    local ctx=""
    if ctx=$(detect_container); then
        print_warning "运行环境：容器（${ctx}）→ 仅可查看，部署/回滚会被拒绝"
    else
        print_success "运行环境：宿主机（可直接部署）"
    fi
    echo ""

    echo "【查看】"
    echo "1. 当前状态 (--status)"
    echo "2. 自动调参预览 (--explain，不做任何改动)"
    echo "3. 演练部署 (--dry-run，打印将要执行的操作)"
    echo ""
    echo "【配置】"
    echo "4. 部署 / 更新（自动调参）"
    echo "5. 自定义参数部署"
    echo "6. 安装脚本到 ${LOCAL_SCRIPT}"
    echo ""
    echo "【维护】"
    echo "7. 回滚（卸载 zram，恢复原状）"
    echo ""
    echo "0. 返回主菜单"
    echo "=========================================="
}

zram_setup_menu() {
    while true; do
        show_zram_menu
        read -p "请选择操作 [0-7]: " choice

        case $choice in
            1) zram_status ;;
            2) zram_explain ;;
            3) zram_dryrun ;;
            4) zram_deploy ;;
            5) zram_custom ;;
            6) zram_install ;;
            7) zram_rollback ;;
            0)
                echo ""
                print_success "返回主菜单"
                sleep 1
                return 0
                ;;
            *)
                print_error "无效选择"
                sleep 2
                ;;
        esac
    done
}

# 启动宿主机 zram 菜单
zram_setup_menu
