#!/bin/bash
set -euo pipefail

# ============================================
# 系统配置子菜单
# ============================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }

# ============================================
# 功能函数
# ============================================

# 功能 1: 修改 Hostname
change_hostname() {
    echo ""
    echo "=========================================="
    echo "修改系统 Hostname"
    echo "=========================================="
    
    CURRENT_HOSTNAME=$(hostname)
    echo "当前 hostname: $CURRENT_HOSTNAME"
    echo ""
    
    read -p "请输入新的 hostname（留空取消）: " NEW_HOSTNAME
    
    if [[ -z "$NEW_HOSTNAME" ]]; then
        print_warning "已取消"
        read -p "按 Enter 键返回..."
        return 0
    fi
    
    if [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
        print_error "hostname 只能包含字母、数字和连字符"
        read -p "按 Enter 键返回..."
        return 1
    fi
    
    if [[ "$NEW_HOSTNAME" == "$CURRENT_HOSTNAME" ]]; then
        print_warning "新旧 hostname 相同"
        read -p "按 Enter 键返回..."
        return 0
    fi
    
    echo ""
    echo "正在修改 hostname 为: $NEW_HOSTNAME"
    
    echo ""
    echo "[步骤 1/4] 更新 /etc/hosts..."
    
    if ! grep -q "127.0.0.1.*localhost" /etc/hosts; then
        sudo sed -i '1i 127.0.0.1\tlocalhost' /etc/hosts
    fi
    
    if grep -q "127.0.1.1" /etc/hosts; then
        sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME $CURRENT_HOSTNAME/" /etc/hosts
        print_success "已更新 /etc/hosts（临时保留旧 hostname）"
    else
        echo "127.0.1.1	$NEW_HOSTNAME $CURRENT_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
        print_success "已添加记录到 /etc/hosts"
    fi
    
    echo ""
    echo "[步骤 2/4] 修改 /etc/hostname..."
    echo "$NEW_HOSTNAME" | sudo tee /etc/hostname > /dev/null
    print_success "已更新 /etc/hostname"
    
    echo ""
    echo "[步骤 3/4] 应用新的 hostname..."
    if command -v hostnamectl &> /dev/null; then
        sudo hostnamectl set-hostname "$NEW_HOSTNAME"
        print_success "已使用 hostnamectl 设置 hostname"
    else
        sudo hostname "$NEW_HOSTNAME"
        print_success "已使用 hostname 命令设置"
    fi
    
    echo ""
    echo "[步骤 4/4] 清理 /etc/hosts..."
    sudo sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
    print_success "已清理旧 hostname 记录"
    
    echo ""
    print_success "Hostname 修改完成！"
    echo "旧 hostname: $CURRENT_HOSTNAME"
    echo "新 hostname: $NEW_HOSTNAME"
    
    read -p "按 Enter 键返回..."
}

# 功能 2: 更新系统
update_system() {
    echo ""
    echo "=========================================="
    echo "更新系统"
    echo "=========================================="
    
    echo "[步骤 1/3] 更新软件包列表..."
    sudo apt update
    
    echo ""
    echo "[步骤 2/3] 升级软件包..."
    sudo apt upgrade -y
    
    echo ""
    echo "[步骤 3/3] 清理不需要的软件包..."
    sudo apt autoremove -y
    sudo apt autoclean
    
    echo ""
    print_success "系统更新完成！"
    read -p "按 Enter 键返回..."
}

# 功能 3: 设置时区
set_timezone() {
    echo ""
    echo "=========================================="
    echo "设置时区"
    echo "=========================================="
    
    echo "当前时区: $(timedatectl | grep "Time zone" | awk '{print $3}')"
    echo ""
    echo "常用时区："
    echo "1. Asia/Shanghai (中国标准时间)"
    echo "2. America/New_York (美国东部时间)"
    echo "3. Europe/London (英国时间)"
    echo "4. Asia/Tokyo (日本时间)"
    echo "5. 自定义"
    echo ""
    
    read -p "请选择 [1-5]: " tz_choice
    
    case $tz_choice in
        1) TIMEZONE="Asia/Shanghai" ;;
        2) TIMEZONE="America/New_York" ;;
        3) TIMEZONE="Europe/London" ;;
        4) TIMEZONE="Asia/Tokyo" ;;
        5)
            read -p "请输入时区（如 Asia/Shanghai）: " TIMEZONE
            ;;
        *)
            print_error "无效选择"
            read -p "按 Enter 键返回..."
            return 1
            ;;
    esac
    
    echo ""
    echo "正在设置时区为: $TIMEZONE"
    
    if sudo timedatectl set-timezone "$TIMEZONE"; then
        print_success "时区设置成功"
        echo "当前时间: $(date)"
    else
        print_error "时区设置失败"
    fi
    
    read -p "按 Enter 键返回..."
}

# ============================================
# 系统配置子菜单
# ============================================

show_system_menu() {
    clear
    echo "=========================================="
    echo "   系统配置菜单"
    echo "=========================================="
    echo ""
    echo "1. 修改系统 Hostname"
    echo "2. 更新系统软件包"
    echo "3. 设置时区"
    echo ""
    echo "0. 返回主菜单"
    echo "=========================================="
}

system_menu() {
    while true; do
        show_system_menu
        read -p "请选择操作 [0-3]: " choice
        
        case $choice in
            1)
                change_hostname
                ;;
            2)
                update_system
                ;;
            3)
                set_timezone
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

# 启动系统配置菜单
system_menu


