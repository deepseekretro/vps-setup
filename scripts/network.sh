#!/bin/bash
set -euo pipefail

# ============================================
# 网络配置子菜单
# ============================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

# ============================================
# 网络配置子菜单
# ============================================

show_network_menu() {
    clear
    echo "=========================================="
    echo "   网络配置菜单"
    echo "=========================================="
    echo ""
    echo "1. 查看网络接口"
    echo "2. 查看路由表"
    echo "3. 查看 DNS 配置"
    echo ""
    echo "0. 返回主菜单"
    echo "=========================================="
}

view_interfaces() {
    echo ""
    echo "=========================================="
    echo "网络接口"
    echo "=========================================="
    echo ""
    ip addr show
    echo ""
    read -p "按 Enter 键返回..."
}

view_routes() {
    echo ""
    echo "=========================================="
    echo "路由表"
    echo "=========================================="
    echo ""
    ip route show
    echo ""
    read -p "按 Enter 键返回..."
}

view_dns() {
    echo ""
    echo "=========================================="
    echo "DNS 配置"
    echo "=========================================="
    echo ""
    cat /etc/resolv.conf
    echo ""
    read -p "按 Enter 键返回..."
}

network_menu() {
    while true; do
        show_network_menu
        read -p "请选择操作 [0-3]: " choice
        
        case $choice in
            1)
                view_interfaces
                ;;
            2)
                view_routes
                ;;
            3)
                view_dns
                ;;
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

# 启动网络配置菜单
network_menu
