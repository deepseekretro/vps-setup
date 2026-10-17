#!/bin/bash
set -euo pipefail

# ============================================
# 监控查看子菜单
# ============================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

# ============================================
# 功能函数
# ============================================

# 功能 1: 查看 Fail2ban 状态
view_fail2ban() {
    echo ""
    echo "=========================================="
    echo "Fail2ban 状态"
    echo "=========================================="
    
    if ! command -v fail2ban-client &> /dev/null; then
        print_error "Fail2ban 未安装"
        read -p "按 Enter 键返回..."
        return 1
    fi
    
    echo ""
    echo "【服务状态】"
    sudo systemctl status fail2ban --no-pager | head -n 5
    
    echo ""
    echo "【监控状态】"
    sudo fail2ban-client status
    
    echo ""
    echo "【SSH 保护详情】"
    if sudo fail2ban-client status sshd &> /dev/null; then
        sudo fail2ban-client status sshd
    else
        print_error "SSH 保护未启用"
    fi
    
    echo ""
    read -p "按 Enter 键返回..."
}

# 功能 2: 查看防火墙状态
view_firewall() {
    echo ""
    echo "=========================================="
    echo "防火墙状态"
    echo "=========================================="
    
    if ! command -v ufw &> /dev/null; then
        print_error "UFW 未安装"
        read -p "按 Enter 键返回..."
        return 1
    fi
    
    echo ""
    sudo ufw status verbose
    
    echo ""
    echo "【规则列表（带编号）】"
    sudo ufw status numbered
    
    echo ""
    read -p "按 Enter 键返回..."
}

# 功能 3: 系统信息
view_system_info() {
    echo ""
    echo "=========================================="
    echo "系统信息"
    echo "=========================================="
    
    echo ""
    echo "【系统版本】"
    cat /etc/os-release | grep -E "PRETTY_NAME|VERSION"
    
    echo ""
    echo "【内核版本】"
    uname -r
    
    echo ""
    echo "【主机名】"
    hostname
    
    echo ""
    echo "【IP 地址】"
    hostname -I
    
    echo ""
    echo "【内存使用】"
    free -h
    
    echo ""
    echo "【磁盘使用】"
    df -h | grep -E "Filesystem|/$"
    
    echo ""
    echo "【CPU 信息】"
    lscpu | grep -E "Model name|CPU\(s\):"
    
    echo ""
    read -p "按 Enter 键返回..."
}

# ============================================
# 监控查看子菜单
# ============================================

show_monitoring_menu() {
    clear
    echo "=========================================="
    echo "   监控查看菜单"
    echo "=========================================="
    echo ""
    echo "1. 查看 Fail2ban 状态"
    echo "2. 查看防火墙状态"
    echo "3. 查看系统信息"
    echo ""
    echo "0. 返回主菜单"
    echo "=========================================="
}

monitoring_menu() {
    while true; do
        show_monitoring_menu
        read -p "请选择操作 [0-3]: " choice
        
        case $choice in
            1)
                view_fail2ban
                ;;
            2)
                view_firewall
                ;;
            3)
                view_system_info
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

# 启动监控查看菜单
monitoring_menu
