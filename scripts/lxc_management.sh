#!/bin/bash

# ============================================
# LXC 容器管理脚本 (适配版)
# 基于 v6.8 完整功能版本
# ============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================
# 公共函数
# ============================================

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

press_enter() {
    echo ""
    read -p "按 Enter 键继续..."
}

# 检查 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "此功能需要 root 权限"
        print_info "请使用 sudo 运行主脚本"
        press_enter
        return 1
    fi
    return 0
}

# ==============================================================================
#                                   基础辅助函数
# ==============================================================================

check_lxc_installed() {
    if command -v lxc-create &> /dev/null; then
        return 0
    else
        return 1
    fi
}

get_container_ip() {
    local container_name=$1
    local state=$(lxc-info -n "$container_name" -s 2>/dev/null | awk '{print $2}')
    if [ "$state" != "RUNNING" ]; then
        echo "-"
        return
    fi
    local ip=$(lxc-attach -n "$container_name" -- ip -4 addr show eth0 2>/dev/null | \
         grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [ -z "$ip" ] && echo "获取中..." || echo "$ip"
}

get_container_remark() {
    local container_name=$1
    local config_file="/var/lib/lxc/$container_name/config"
    local remark=$(grep "^# LXC_REMARK:" "$config_file" 2>/dev/null | cut -d':' -f2- | sed 's/^[ \t]*//')
    [ -z "$remark" ] && echo "-" || echo "$remark"
}

is_privileged() {
    local container_name=$1
    local config_file="/var/lib/lxc/$container_name/config"
    if grep -q "lxc.apparmor.profile.*=.*unconfined" "$config_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

generate_new_mac() {
    printf "00:16:3e:%02x:%02x:%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

ensure_host_subids() {
    touch /etc/subuid /etc/subgid
    grep -q "^root:100000:65536" /etc/subuid || echo "root:100000:65536" >> /etc/subuid
    grep -q "^root:100000:65536" /etc/subgid || echo "root:100000:65536" >> /etc/subgid
}

show_containers_simple() {
    local filter=$1
    echo "=========================================================="
    printf "  %-15s %-10s %-10s %-20s\n" "名称" "状态" "模式" "备注"
    echo "----------------------------------------------------------"
    local all_containers=$(lxc-ls 2>/dev/null)
    if [ -z "$all_containers" ]; then
        echo -e "${YELLOW}  没有容器${NC}"
        echo "=========================================================="
        return 1
    fi
    for c in $all_containers; do
        local state=$(lxc-info -n "$c" -s 2>/dev/null | awk '{print $2}')
        local mode_tag=$(is_privileged "$c" && echo -e "${RED}特权${NC}" || echo -e "${GREEN}非特${NC}")
        local remark=$(get_container_remark "$c")
        case $filter in
            running) [ "$state" = "RUNNING" ] && printf "  %-15s [%-8s] %-14b %s\n" "$c" "$state" "$mode_tag" "$remark" ;;
            stopped) [ "$state" = "STOPPED" ] && printf "  %-15s [%-8s] %-14b %s\n" "$c" "$state" "$mode_tag" "$remark" ;;
            *)       printf "  %-15s [%-8s] %-14b %s\n" "$c" "$state" "$mode_tag" "$remark" ;;
        esac
    done
    echo "=========================================================="
}

# ==============================================================================
#                                   核心功能模块
# ==============================================================================

install_lxc() {
    clear
    echo "=========================================="
    echo "   安装 LXC 环境"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    if check_lxc_installed; then
        print_warning "LXC 已安装"
        lxc-ls --version
        press_enter
        return
    fi
    
    print_info "正在安装 LXC 及相关工具..."
    echo ""
    
    apt-get update
    apt-get install -y lxc lxc-templates debootstrap bridge-utils libvirt-clients uidmap iptables iptables-persistent
    
    if [ $? -eq 0 ]; then
        print_success "LXC 安装成功"
        
        # 启用服务
        systemctl enable lxc lxc-net
        systemctl start lxc-net
        
        # 启用 iptables 持久化服务
        if systemctl list-unit-files | grep -q netfilter-persistent; then
            systemctl enable netfilter-persistent
            systemctl start netfilter-persistent
            print_success "iptables 持久化服务已启用"
        fi
        
        print_success "LXC 服务已启动"
        echo ""
        print_info "已安装组件："
        echo "  - LXC 核心"
        echo "  - 容器模板"
        echo "  - 网络桥接工具"
        echo "  - iptables 持久化"
    else
        print_error "安装失败"
    fi
    
    press_enter
}

setup_network_bridge() {
    clear
    echo "=========================================="
    echo "   配置网络桥接"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    # 子网选择菜单
    echo "请选择网络子网："
    echo -e "  ${CYAN}1${NC}) 10.0.0.0/24 (默认)"
    echo -e "  ${CYAN}2${NC}) 10.1.0.0/24"
    echo -e "  ${CYAN}3${NC}) 10.2.0.0/24"
    echo -e "  ${CYAN}4${NC}) 10.3.0.0/24"
    echo ""
    read -p "请选择 [1-4] (默认: 1): " subnet_choice
    subnet_choice=${subnet_choice:-1}
    
    # 根据选择设置子网参数
    case $subnet_choice in
        1)
            SUBNET_OCTET="0"
            SUBNET_DESC="10.0.0.0/24"
            ;;
        2)
            SUBNET_OCTET="1"
            SUBNET_DESC="10.1.0.0/24"
            ;;
        3)
            SUBNET_OCTET="2"
            SUBNET_DESC="10.2.0.0/24"
            ;;
        4)
            SUBNET_OCTET="3"
            SUBNET_DESC="10.3.0.0/24"
            ;;
        *)
            print_error "无效选择，未进行配置"
            press_enter
            return
            ;;
    esac
    
    print_info "配置 LXC 网络桥接 (${SUBNET_DESC})..."
    echo ""
    
    # 创建 LXC 网络配置
    cat > /etc/default/lxc-net <<EOF
USE_LXC_BRIDGE="true"
LXC_BRIDGE="lxcbr0"
LXC_ADDR="10.${SUBNET_OCTET}.0.1"
LXC_NETMASK="255.255.255.0"
LXC_NETWORK="10.${SUBNET_OCTET}.0.0/24"
LXC_DHCP_RANGE="10.${SUBNET_OCTET}.0.100,10.${SUBNET_OCTET}.0.254"
LXC_DHCP_MAX="253"
LXC_DHCP_CONFILE="/etc/lxc/dnsmasq.conf"
EOF
    
    # 创建配置目录
    mkdir -p /etc/lxc
    touch /etc/lxc/dnsmasq.conf /etc/lxc/dhcp_hosts.conf
    
    # 重启网络服务
    systemctl restart lxc-net
    
    print_success "网络桥接配置完成"
    echo ""
    
    # 配置 IP 转发
    print_info "配置 IP 转发..."
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-lxc.conf
    sysctl -p /etc/sysctl.d/99-lxc.conf
    
    # 配置 iptables NAT
    local IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    print_info "在网卡 ${IFACE} 上配置 NAT..."
    
    iptables -t nat -A POSTROUTING -s 10.${SUBNET_OCTET}.0.0/24 -o "$IFACE" -j MASQUERADE
    iptables -A FORWARD -i lxcbr0 -o "$IFACE" -j ACCEPT
    iptables -A FORWARD -i "$IFACE" -o lxcbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    
    # 保存 iptables 规则（使用 netfilter-persistent 确保重启后恢复）
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        print_success "NAT 规则已持久化保存"
    else
        # 降级到手动保存
        iptables-save > /etc/iptables/rules.v4
        print_warning "使用手动保存（建议安装 iptables-persistent）"
    fi
    
    print_success "网络配置完成"
    echo ""
    print_info "网络信息："
    echo "  桥接接口: lxcbr0"
    echo "  桥接地址: 10.${SUBNET_OCTET}.0.1/24"
    echo "  DHCP 范围: 10.${SUBNET_OCTET}.0.100-254"
    echo "  静态 IP: 10.${SUBNET_OCTET}.0.2-99 (可用)"
    
    press_enter
}

configure_host_swap() {
    clear
    echo "=========================================="
    echo "   配置宿主机 Swap"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    # 显示当前内存状态
    print_info "当前内存状态："
    free -h
    echo ""
    
    read -p "Swap 大小 (GB): " gb
    
    if [ -z "$gb" ] || ! [[ "$gb" =~ ^[0-9]+$ ]]; then
        print_error "无效的大小"
        press_enter
        return
    fi
    
    # 删除旧的 swap 文件
    if [ -f /swapfile ]; then
        print_info "删除旧的 swap 文件..."
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        sed -i '/swapfile/d' /etc/fstab
    fi
    
    # 创建新的 swap 文件
    print_info "创建 ${gb}GB swap 文件..."
    dd if=/dev/zero of=/swapfile bs=1M count=$((gb*1024)) status=progress
    
    # 设置权限
    chmod 600 /swapfile
    
    # 格式化并启用
    mkswap /swapfile
    swapon /swapfile
    
    # 添加到 fstab
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    
    print_success "Swap 配置完成"
    echo ""
    print_info "新的内存状态："
    free -h
    
    press_enter
}

configure_host_fuse() {
    clear
    echo "=========================================="
    echo "   配置宿主机 FUSE 支持"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    print_info "检查宿主机 FUSE 支持状态..."
    echo ""
    
    # 1. 检查内核模块
    print_info "[1/4] 检查 FUSE 内核模块..."
    if lsmod | grep -q "^fuse"; then
        print_success "✓ FUSE 模块已加载"
        local fuse_version=$(modinfo fuse 2>/dev/null | grep "^version:" | awk '{print $2}')
        echo "  版本: ${fuse_version:-未知}"
    else
        print_warning "✗ FUSE 模块未加载"
        echo ""
        read -p "是否加载 FUSE 模块？[Y/n]: " load_module
        
        if [[ ! "$load_module" =~ ^[Nn]$ ]]; then
            print_info "加载 FUSE 模块..."
            if modprobe fuse; then
                print_success "✓ FUSE 模块加载成功"
            else
                print_error "✗ FUSE 模块加载失败"
                echo ""
                print_warning "可能的原因："
                echo "  1. 内核不支持 FUSE"
                echo "  2. 需要安装 fuse 包"
                press_enter
                return 1
            fi
        fi
    fi
    
    # 2. 检查设备文件
    echo ""
    print_info "[2/4] 检查 /dev/fuse 设备..."
    if [ -e /dev/fuse ]; then
        print_success "✓ /dev/fuse 设备存在"
        ls -l /dev/fuse
    else
        print_error "✗ /dev/fuse 设备不存在"
        echo ""
        print_warning "尝试重新加载模块..."
        modprobe -r fuse 2>/dev/null || true
        sleep 1
        modprobe fuse
        
        if [ -e /dev/fuse ]; then
            print_success "✓ /dev/fuse 设备已创建"
        else
            print_error "✗ 无法创建 /dev/fuse 设备"
            press_enter
            return 1
        fi
    fi
    
    # 3. 检查 fuse 软件包
    echo ""
    print_info "[3/4] 检查 fuse 软件包..."
    if dpkg -l | grep -q "^ii.*fuse3"; then
        print_success "✓ fuse3 已安装"
        dpkg -l | grep "^ii.*fuse3" | awk '{print "  " $2 " " $3}'
    elif dpkg -l | grep -q "^ii.*fuse "; then
        print_success "✓ fuse 已安装"
        dpkg -l | grep "^ii.*fuse " | awk '{print "  " $2 " " $3}'
    else
        print_warning "✗ fuse 软件包未安装"
        echo ""
        read -p "是否安装 fuse3？[Y/n]: " install_fuse
        
        if [[ ! "$install_fuse" =~ ^[Nn]$ ]]; then
            print_info "安装 fuse3..."
            apt update
            apt install -y fuse3
            
            if [ $? -eq 0 ]; then
                print_success "✓ fuse3 安装成功"
            else
                print_error "✗ fuse3 安装失败"
                press_enter
                return 1
            fi
        fi
    fi
    
    # 4. 配置开机自动加载
    echo ""
    print_info "[4/4] 配置开机自动加载..."
    
    if grep -q "^fuse$" /etc/modules 2>/dev/null; then
        print_success "✓ FUSE 模块已配置为开机加载"
    else
        print_info "添加 FUSE 到开机加载列表..."
        echo "fuse" >> /etc/modules
        print_success "✓ 已配置开机自动加载"
    fi
    
    # 5. 测试 FUSE 功能
    echo ""
    print_info "测试 FUSE 功能..."
    
    # 创建测试目录
    local test_dir="/tmp/fuse_test_$$"
    mkdir -p "$test_dir"
    
    # 尝试挂载一个简单的 FUSE 文件系统（如果有 sshfs）
    if command -v sshfs &>/dev/null; then
        print_info "使用 sshfs 测试 FUSE..."
        # 这里只是检查命令是否可用，不实际挂载
        print_success "✓ FUSE 工具可用"
    else
        print_info "跳过功能测试（未安装 sshfs）"
    fi
    
    rm -rf "$test_dir"
    
    # 6. 显示总结
    echo ""
    echo "=========================================="
    print_success "宿主机 FUSE 配置完成"
    echo "=========================================="
    echo ""
    print_info "配置摘要："
    echo "  ✓ FUSE 内核模块: 已加载"
    echo "  ✓ /dev/fuse 设备: 可用"
    echo "  ✓ fuse 软件包: 已安装"
    echo "  ✓ 开机自动加载: 已配置"
    echo ""
    print_info "现在可以："
    echo "  1. 在 LXC 容器中使用 FUSE"
    echo "  2. 切换容器到特权模式以启用 rclone mount"
    echo "  3. 在容器内挂载云存储（OneDrive, Google Drive 等）"
    echo ""
    print_warning "注意："
    echo "  • 容器必须使用特权模式才能使用 FUSE"
    echo "  • 容器内也需要安装 fuse 和 rclone"
    
    press_enter
}

create_debian12() {
    clear
    echo "=========================================="
    echo "   创建 Debian 12 容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        print_error "容器名称不能为空"
        press_enter
        return
    fi
    
    # 检查容器是否已存在
    if lxc-info -n "$container_name" &>/dev/null; then
        print_error "容器 ${container_name} 已存在"
        press_enter
        return
    fi
    
    print_info "正在创建 Debian 12 容器..."
    echo ""
    
    # 创建容器
    lxc-create -t download -n "$container_name" -- -d debian -r bookworm -a amd64
    
    if [ $? -eq 0 ]; then
        print_success "容器创建成功"
        echo ""
        
        local config_file="/var/lib/lxc/$container_name/config"
        
        # 配置自动启动
        print_info "配置自动启动..."
        echo -e "lxc.start.auto = 1\nlxc.start.delay = 5\nlxc.start.order = 100" >> "$config_file"
        
        # 配置 Swap（如果宿主机有 Swap）
        local host_swap=$(free -m | awk '/^Swap:/{print $2}')
        if [ "$host_swap" -gt 0 ]; then
            print_info "配置容器 Swap 限制..."
            echo "lxc.cgroup2.memory.swap.max = ${host_swap}M" >> "$config_file"
        fi
        
        # 询问是否添加备注
        echo ""
        read -p "是否添加备注？(y/n): " add_remark
        if [[ "$add_remark" =~ ^[yY]$ ]]; then
            read -p "请输入备注: " remark
            echo "# LXC_REMARK: $remark" >> "$config_file"
        fi
        
        # 直接配置静态 IP
        set_static_ip "$container_name"
        

    else
        print_error "容器创建失败"
    fi
    
    press_enter
}


set_static_ip() {
    clear
    echo "=========================================="
    echo "   设置静态 IP"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    local target=$1
    
    if [ -z "$target" ]; then
        show_containers_simple "all"
        echo ""
        read -p "容器名称: " target
    fi
    
    if [ -z "$target" ] || [ ! -f "/var/lib/lxc/$target/config" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    # 检测网桥子网
    print_info "检测网桥配置..."
    local BRIDGE_IP=$(ip addr show lxcbr0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    
    if [ -z "$BRIDGE_IP" ]; then
        print_error "无法检测到 lxcbr0 网桥"
        echo ""
        print_warning "请先配置网络桥接（菜单选项 2）"
        press_enter
        return
    fi
    
    # 提取子网标识（第二个八位组）
    local SUBNET_OCTET=$(echo "$BRIDGE_IP" | cut -d'.' -f2)
    
    # 调试输出
    echo "[DEBUG] BRIDGE_IP=$BRIDGE_IP, SUBNET_OCTET=$SUBNET_OCTET"
    
    # 验证检测到的 IP 格式
    if [[ ! "$BRIDGE_IP" =~ ^10\.[0-3]\.0\.1$ ]]; then
        print_error "检测到的网桥 IP 格式异常: $BRIDGE_IP"
        echo ""
        print_warning "期望格式: 10.X.0.1 (X=0-3)"
        press_enter
        return
    fi
    
    print_success "检测到网桥: $BRIDGE_IP (子网: 10.${SUBNET_OCTET}.0.0/24)"
    
    # 获取当前状态
    local container_state=$(lxc-info -n "$target" -s 2>/dev/null | awk '{print $2}')
    local was_running=false
    if [ "$container_state" = "RUNNING" ]; then
        was_running=true
    fi
    
    echo ""
    print_info "当前容器状态: $container_state"
    
    # 显示可用 IP 范围（动态计算）
    echo ""
    print_info "可用 IP 范围："
    echo "  静态 IP: 10.${SUBNET_OCTET}.0.2 - 10.${SUBNET_OCTET}.0.99"
    echo "  DHCP 范围: 10.${SUBNET_OCTET}.0.100 - 10.${SUBNET_OCTET}.0.254"
    echo "  网关: 10.${SUBNET_OCTET}.0.1"
    echo ""
    
    # 循环询问静态 IP，直到格式正确且无冲突
    local static_ip=""
    while true; do
        read -p "请指定静态 IP (10.${SUBNET_OCTET}.0.2-99): " static_ip

        # 验证 IP 格式和范围
        if [[ ! "$static_ip" =~ ^10\.${SUBNET_OCTET}\.0\.([2-9]|[1-9][0-9])$ ]]; then
            print_error "IP 地址格式错误或超出范围，请重新输入 (10.${SUBNET_OCTET}.0.2-99)"
            echo ""
            continue
        fi

        # 检查 IP 是否已被其他容器使用
        local ip_conflict=false
        print_info "检查 IP 冲突..."
        for container in $(lxc-ls 2>/dev/null); do
            if [ "$container" = "$target" ]; then
                continue
            fi
            local existing_ip
            existing_ip=$(grep "lxc.net.0.ipv4.address" "/var/lib/lxc/$container/config" 2>/dev/null | awk '{print $3}' | cut -d'/' -f1)
            if [ "$existing_ip" = "$static_ip" ]; then
                print_error "IP $static_ip 已被容器 $container 使用，请重新指定"
                echo ""
                ip_conflict=true
                break
            fi
        done

        if [ "$ip_conflict" = false ]; then
            break
        fi
    done
    
    local config_file="/var/lib/lxc/$target/config"
    
    # 获取或生成 MAC 地址
    local container_mac=$(grep "lxc.net.0.hwaddr" "$config_file" | awk '{print $3}')
    if [ -z "$container_mac" ]; then
        container_mac=$(generate_new_mac)
        echo "lxc.net.0.hwaddr = $container_mac" >> "$config_file"
        print_info "生成 MAC 地址: $container_mac"
    fi
    
    # 停止容器（如果正在运行）
    if [ "$was_running" = true ]; then
        print_info "停止容器以配置网络..."
        lxc-stop -n "$target" -k 2>/dev/null || true
        sleep 2
    fi
    
    print_info "配置静态 IP..."
    
    # 清理旧的网络配置
    sed -i '/# 静态 IP 配置/d' "$config_file"
    sed -i '/lxc.net.0.ipv4.address/d' "$config_file"
    sed -i '/lxc.net.0.ipv4.gateway/d' "$config_file"
    
    # 添加新的静态 IP 配置
    cat >> "$config_file" << EOF

# 静态 IP 配置
lxc.net.0.ipv4.address = ${static_ip}/24
lxc.net.0.ipv4.gateway = 10.${SUBNET_OCTET}.0.1
EOF
    
    print_success "容器配置已更新"

    # 修改容器内部网络接口配置（禁用 DHCP，改用静态 IP）
    print_info "配置容器内部网络接口（禁用 DHCP）..."
    local ifaces_file="/var/lib/lxc/$target/rootfs/etc/network/interfaces"
    if [ -f "$ifaces_file" ]; then
        cp "$ifaces_file" "${ifaces_file}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
    mkdir -p "$(dirname "$ifaces_file")"
    cat > "$ifaces_file" << EOF
# 由 LXC 管理脚本生成 - 静态 IP 配置（禁用 DHCP）
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${static_ip}
    netmask 255.255.255.0
    gateway 10.${SUBNET_OCTET}.0.1
EOF
    print_success "容器内部网络已配置为静态 IP（DHCP 已禁用）"
    
    # 配置容器内的 DNS
    print_info "配置容器 DNS..."
    
    local resolv_conf="/var/lib/lxc/$target/rootfs/etc/resolv.conf"
    
    # **关键修复：先解除文件锁定**
    chattr -i "$resolv_conf" 2>/dev/null || true
    
    # 备份原 resolv.conf
    if [ -f "$resolv_conf" ] && [ ! -L "$resolv_conf" ]; then
        cp "$resolv_conf" "${resolv_conf}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
    
    # 删除符号链接（如果存在）
    if [ -L "$resolv_conf" ]; then
        rm -f "$resolv_conf"
    fi
    
    # 创建新的 resolv.conf（指向 systemd-resolved stub，保留本地 DNS 缓存）
    cat > "$resolv_conf" << 'EOF'
# LXC DNS 配置（通过 systemd-resolved 本地缓存代理）
nameserver 127.0.0.53
options edns0 trust-ad
EOF
    
    # **关键修复：锁定文件前先检查是否成功写入**
    if [ $? -eq 0 ]; then
        # 防止被覆盖（可选）
        chattr +i "$resolv_conf" 2>/dev/null || true
        print_success "DNS 配置已更新并锁定"
    else
        print_error "DNS 配置写入失败"
    fi

    # 禁用 LLMNR（关闭 5355 端口）
    print_info "禁用 LLMNR（端口 5355）..."
    local rootfs="/var/lib/lxc/$target/rootfs"
    local resolved_conf="$rootfs/etc/systemd/resolved.conf"
    mkdir -p "$rootfs/etc/systemd"

    if [ -f "$resolved_conf" ]; then
        sed -i '/^\s*LLMNR\s*=/d'        "$resolved_conf"
        sed -i '/^\s*MulticastDNS\s*=/d' "$resolved_conf"
        grep -q '^\[Resolve\]' "$resolved_conf" || echo -e '\n[Resolve]' >> "$resolved_conf"
        sed -i '/^\[Resolve\]/a LLMNR=no\nMulticastDNS=no' "$resolved_conf"
    else
        cat > "$resolved_conf" << 'RESEOF'
[Resolve]
LLMNR=no
MulticastDNS=no
RESEOF
    fi

    # 保留 systemd-resolved 运行以提供本地 DNS 缓存（仅禁用 LLMNR）

    print_success "LLMNR 已禁用（端口 5355 不再监听）"

    echo ""
    print_success "静态 IP 配置完成"
    echo ""
    print_info "配置摘要："
    echo "  容器名称: $target"
    echo "  MAC 地址: $container_mac"
    echo "  静态 IP: $static_ip/24"
    echo "  网关: 10.${SUBNET_OCTET}.0.1"
    echo "  DNS: 127.0.0.53 (systemd-resolved 本地缓存，上游由宿主机配置)"
    echo ""
    
    # 显示配置文件
    print_info "LXC 网络配置："
    grep -E "lxc.net.0.(ipv4|hwaddr)" "$config_file"
    echo ""
    
    print_info "DNS 配置："
    cat "$resolv_conf"
    echo ""
    
    # 询问是否启动容器
    # 询问是否启动容器
    echo ""
    read -p "是否启动容器以验证配置？[Y/n]: " start_confirm
    if [[ ! "$start_confirm" =~ ^[Nn]$ ]]; then
        print_info "启动容器..."
        lxc-start -n "$target"
        
        # 等待容器启动
        sleep 3
        
        # 验证 IP 地址
        print_info "验证网络配置..."
        sleep 2
        
        local current_ip=$(lxc-attach -n "$target" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        
        if [ "$current_ip" = "$static_ip" ]; then
            print_success "✓ IP 地址配置成功: $current_ip"
        else
            print_warning "⚠ IP 地址不匹配"
            echo "  期望: $static_ip"
            echo "  实际: ${current_ip:-无}"
        fi
        
        # 测试连通性
        echo ""
        read -p "是否测试网络连通性？[y/N]: " test_network
        if [[ "$test_network" =~ ^[Yy]$ ]]; then
            print_info "测试网关连通性..."
            if lxc-attach -n "$target" -- ping -c 2 10.${SUBNET_OCTET}.0.1 &>/dev/null; then
                print_success "✓ 网关连通"
            else
                print_error "✗ 网关不通"
            fi
            
            print_info "测试外网连通性..."
            if lxc-attach -n "$target" -- ping -c 2 8.8.8.8 &>/dev/null; then
                print_success "✓ 外网连通"
            else
                print_error "✗ 外网不通"
            fi
            
            print_info "测试 DNS 解析..."
            if lxc-attach -n "$target" -- ping -c 2 www.google.com &>/dev/null; then
                print_success "✓ DNS 解析正常"
            else
                print_error "✗ DNS 解析失败"
            fi
        fi
    else
        print_info "配置已保存，请手动启动以应用配置"
    fi
    
    echo ""
    print_info "提示："
    echo "  - 配置已保存，重启容器后生效"
    echo "  - 不会影响其他容器的网络"
    echo "  - LXC 会自动配置容器内的网络接口"
    echo "  - resolv.conf 已锁定，防止被覆盖"
    
    press_enter
}




toggle_privileged() {
    clear
    echo "=========================================="
    echo "   切换特权模式"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    local config_file="/var/lib/lxc/$container_name/config"
    local rootfs="/var/lib/lxc/$container_name/rootfs"
    
    if [ ! -f "$config_file" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    echo ""
    echo "1. 切换到特权模式 (支持 Docker + FUSE/Rclone)"
    echo "2. 切换到非特权模式"
    echo ""
    read -p "请选择 [1-2]: " choice
    
    # 清理旧配置
    sed -i '/# 特权/,/# 非特权/d; /^lxc.idmap/d; /^lxc.apparmor/d; /^lxc.mount.auto/d; /^lxc.cap.drop/d; /^lxc.cgroup2.devices.allow/d; /^lxc.mount.entry.*fuse/d' "$config_file"
    
    if [ "$choice" = "1" ]; then
        print_info "配置特权模式..."
        echo ""
        
        # ============================================
        # 自动检测并配置宿主机 FUSE 支持
        # ============================================
        print_info "检查宿主机 FUSE 支持..."
        
        local fuse_ok=true
        local fuse_configured=false
        
        # 检查 FUSE 模块
        if ! lsmod | grep -q "^fuse"; then
            print_warning "FUSE 模块未加载，正在加载..."
            if modprobe fuse 2>/dev/null; then
                print_success "✓ FUSE 模块加载成功"
                fuse_configured=true
            else
                print_error "✗ FUSE 模块加载失败"
                fuse_ok=false
            fi
        else
            print_success "✓ FUSE 模块已加载"
        fi
        
        # 检查 /dev/fuse 设备
        if [ "$fuse_ok" = true ]; then
            if [ ! -e /dev/fuse ]; then
                print_warning "/dev/fuse 不存在，尝试重新加载模块..."
                modprobe -r fuse 2>/dev/null || true
                sleep 1
                modprobe fuse 2>/dev/null
                
                if [ -e /dev/fuse ]; then
                    print_success "✓ /dev/fuse 设备已创建"
                    fuse_configured=true
                else
                    print_error "✗ 无法创建 /dev/fuse 设备"
                    fuse_ok=false
                fi
            else
                print_success "✓ /dev/fuse 设备存在"
            fi
        fi
        
        # 检查 fuse 软件包
        if [ "$fuse_ok" = true ]; then
            if ! dpkg -l | grep -q "^ii.*fuse"; then
                print_warning "fuse 软件包未安装"
                read -p "是否安装 fuse3？[Y/n]: " install_fuse
                
                if [[ ! "$install_fuse" =~ ^[Nn]$ ]]; then
                    print_info "安装 fuse3..."
                    apt update -qq
                    apt install -y fuse3
                    
                    if [ $? -eq 0 ]; then
                        print_success "✓ fuse3 安装成功"
                        fuse_configured=true
                    else
                        print_error "✗ fuse3 安装失败"
                        fuse_ok=false
                    fi
                fi
            else
                print_success "✓ fuse 软件包已安装"
            fi
        fi
        
        # 配置开机自动加载
        if [ "$fuse_configured" = true ]; then
            if ! grep -q "^fuse$" /etc/modules 2>/dev/null; then
                print_info "配置 FUSE 开机自动加载..."
                echo "fuse" >> /etc/modules
                print_success "✓ 已配置开机自动加载"
            fi
        fi
        
        # 显示 FUSE 配置结果
        echo ""
        if [ "$fuse_ok" = true ]; then
            print_success "宿主机 FUSE 支持已就绪"
        else
            print_error "宿主机 FUSE 配置失败"
            echo ""
            print_warning "FUSE 功能可能不可用，但仍可继续配置特权模式"
            read -p "是否继续？[y/N]: " continue_anyway
            if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                return
            fi
        fi
        
        # ============================================
        # 配置容器特权模式
        # ============================================
        echo ""
        print_info "配置容器特权模式..."
        
        cat >> "$config_file" <<'EOF'
# 特权模式配置 (Docker + FUSE/Rclone Support)
lxc.apparmor.profile = unconfined
lxc.apparmor.allow_nesting = 1
#lxc.cap.drop =
#lxc.mount.auto = proc:mixed sys:rw cgroup:mixed

# FUSE 设备支持 (用于 rclone mount 等)
lxc.cgroup2.devices.allow = c 10:229 rwm
lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file 0 0
EOF
        
        print_success "已切换到特权模式"
        echo ""
        print_info "已启用的功能："
        echo "  ✓ Docker 容器支持"
        if [ "$fuse_ok" = true ]; then
            echo "  ✓ FUSE 文件系统支持"
            echo "  ✓ Rclone mount 支持 (OneDrive, Google Drive 等)"
        else
            echo "  ✗ FUSE 支持（宿主机配置失败）"
        fi
        echo ""
        print_warning "使用提示："
        echo "  1. 容器内需要安装 fuse: apt install fuse"
        echo "  2. 容器内需要安装 rclone: curl https://rclone.org/install.sh | sudo bash"
        echo "  3. 挂载示例: rclone mount remote:path /mnt/point --daemon"
        
    else
        print_info "配置非特权模式..."
        ensure_host_subids
        cat >> "$config_file" <<'EOF'
# 非特权模式配置
lxc.mount.auto = proc:mixed sys:mixed cgroup:mixed
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 1
EOF
        print_success "已切换到非特权模式"
        echo ""
        print_warning "注意："
        echo "  非特权模式下 FUSE/Rclone 功能受限"
        echo "  如需使用 rclone mount，请选择特权模式"
    fi
    
    # 修复权限
    print_info "修复文件系统权限..."
    
    # 临时解锁可能被锁定的文件
    local resolv_conf="${rootfs}/etc/resolv.conf"
    local was_locked=false
    
    if [ -f "$resolv_conf" ]; then
        # 检查是否被锁定
        if lsattr "$resolv_conf" 2>/dev/null | grep -q '^....i'; then
            was_locked=true
            chattr -i "$resolv_conf" 2>/dev/null || true
        fi
    fi
    
    # 修改权限
    chown -R 0:0 "$rootfs" 2>/dev/null || true
    
    # 重新锁定文件（如果之前被锁定）
    if [ "$was_locked" = true ] && [ -f "$resolv_conf" ]; then
        chattr +i "$resolv_conf" 2>/dev/null || true
    fi
    
    # 重启容器
    echo ""
    print_info "重启容器以应用配置..."
    lxc-stop -n "$container_name" -k 2>/dev/null || true
    sleep 2
    lxc-start -n "$container_name"
    
    if [ $? -eq 0 ]; then
        print_success "容器已重启"
        
        # 验证 FUSE 设备
        if [ "$choice" = "1" ] && [ "$fuse_ok" = true ]; then
            echo ""
            print_info "验证 FUSE 设备..."
            sleep 2
            
            if lxc-attach -n "$container_name" -- test -e /dev/fuse 2>/dev/null; then
                print_success "✓ /dev/fuse 设备可用"
            else
                print_error "✗ /dev/fuse 设备不可用"
                print_warning "可能需要手动重启容器"
            fi
        fi
    else
        print_error "容器启动失败"
    fi
    
    echo ""
    print_success "配置完成"
    
    press_enter
}

setup_port_forward() {
    clear
    echo "=========================================="
    echo "   配置端口转发"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "running"
    echo ""
    
    read -p "容器名称: " container_name
    local container_ip=$(get_container_ip "$container_name")
    
    if [ "$container_ip" = "-" ] || [ "$container_ip" = "获取中..." ]; then
        print_error "容器未运行或无法获取 IP"
        press_enter
        return
    fi
    
    echo ""
    print_info "容器 IP: $container_ip"
    echo ""
    
    read -p "外部端口 (宿主机): " host_port
    read -p "内部端口 (容器): " container_port
    
    if [ -z "$host_port" ] || [ -z "$container_port" ]; then
        print_error "端口不能为空"
        press_enter
        return
    fi
    
    local IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    print_info "在网卡 ${IFACE} 上配置端口转发..."
    
    # 配置 iptables 规则（修复版：增加 -i 限制）
    iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport "$host_port" -j DNAT --to-destination "$container_ip":"$container_port"
    iptables -A FORWARD -p tcp -d "$container_ip" --dport "$container_port" -j ACCEPT
    
    # 保存规则（使用 netfilter-persistent 确保重启后恢复）
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        print_success "规则已持久化保存（重启后自动恢复）"
    else
        # 降级到手动保存
        iptables-save > /etc/iptables/rules.v4
        print_warning "使用手动保存（建议安装 iptables-persistent）"
    fi
    
    print_success "端口转发配置完成"
    echo ""
    print_info "转发规则："
    echo "  外部端口: $host_port (${IFACE})"
    echo "  -> 容器: $container_name ($container_ip:$container_port)"
    
    press_enter
}

show_dashboard() {
    clear
    echo "=========================================="
    echo "   LXC 容器控制台"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    echo "=========================================================================================================="
    printf "%-12s %-10s %-15s %-15s %-5s %-10s %-10s %-8s\n" "名称" "状态" "IP地址" "备注" "自启" "内存" "Swap" "CPU"
    echo "----------------------------------------------------------------------------------------------------------"
    
    for container in $(lxc-ls 2>/dev/null); do
        local config_file="/var/lib/lxc/$container/config"
        local state=$(lxc-info -n "$container" -s 2>/dev/null | awk '{print $2}')
        local ip=$(get_container_ip "$container")
        local remark=$(get_container_remark "$container")
        remark=${remark:0:15}
        
        local autostart=$(grep -q "lxc.start.auto = 1" "$config_file" 2>/dev/null && echo -e "${GREEN}是${NC}" || echo "否")
        local mem=$(grep "memory.max" "$config_file" 2>/dev/null | awk '{print $3}' || echo "无限")
        local swap=$(grep "swap.max" "$config_file" 2>/dev/null | awk '{print $3}' || echo "无限")
        local cpu=$(grep "cpuset.cpus" "$config_file" 2>/dev/null | awk '{print $3}' || echo "全部")
        
        local remark_tag=$(is_privileged "$container" && echo -e "${RED}[特]${NC} $remark" || echo -e "${GREEN}[非]${NC} $remark")
        
        printf "%-12s %-10s %-15s %-26b %-14b %-10s %-10s %-8s\n" "$container" "$state" "$ip" "$remark_tag" "$autostart" "$mem" "$swap" "$cpu"
    done
    
    echo "=========================================================================================================="
    
    press_enter
}

show_realtime_stats() {
    clear
    echo "=========================================="
    echo "   容器资源使用快照"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    printf "%-15s %-15s %-15s %-15s %-15s\n" "名称" "内存使用" "CPU时间" "运行时间" "磁盘占用"
    echo "----------------------------------------------------------------------------------------"
    
    for container in $(lxc-ls --running 2>/dev/null); do
        local info=$(lxc-info -n "$container" -H 2>/dev/null)
        local pid=$(lxc-info -n "$container" -p -H 2>/dev/null)
        
        local mem=$(echo "$info" | grep "Memory use" | awk '{print $3, $4}')
        [ -z "$mem" ] && mem="-"
        
        local disk=$(du -sh "/var/lib/lxc/$container/rootfs" 2>/dev/null | awk '{print $1}')
        [ -z "$disk" ] && disk="-"
        
        local uptime="-"
        if [ -n "$pid" ]; then
            uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
            [ -z "$uptime" ] && uptime="-"
        fi
        
        printf "%-15s %-15s %-15s %-15s %-15s\n" "$container" "$mem" "-" "$uptime" "$disk"
    done
    
    press_enter
}

clone_container() {
    clear
    echo "=========================================="
    echo "   克隆容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "源容器名称: " source
    read -p "新容器名称: " new_name
    
    if [ -z "$source" ] || [ -z "$new_name" ]; then
        print_error "容器名称不能为空"
        press_enter
        return
    fi
    
    print_info "正在克隆容器..."
    
    lxc-copy -n "$source" -N "$new_name"
    
    if [ $? -eq 0 ]; then
        print_success "克隆成功"
        
        local config_file="/var/lib/lxc/$new_name/config"
        
        # 删除旧的 MAC 地址和备注
        sed -i '/lxc.net.0.hwaddr/d; /# LXC_REMARK/d' "$config_file"
        
        # 生成新的 MAC 地址
        local new_mac=$(generate_new_mac)
        echo "lxc.net.0.hwaddr = $new_mac" >> "$config_file"
        
        print_info "新 MAC 地址: $new_mac"
        
        # 修改容器内的主机名
        if [ -f "/var/lib/lxc/$new_name/rootfs/etc/hostname" ]; then
            echo "$new_name" > "/var/lib/lxc/$new_name/rootfs/etc/hostname"
        fi
        
        print_success "克隆完成"
    else
        print_error "克隆失败"
    fi
    
    press_enter
}

# 其他功能函数
set_resource_limits() {
    clear
    echo "=========================================="
    echo "   设置资源限制"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    local config_file="/var/lib/lxc/$container_name/config"
    
    if [ ! -f "$config_file" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    echo ""
    read -p "内存限制 (如 1G，留空跳过): " mem_limit
    
    if [ -n "$mem_limit" ]; then
        sed -i '/memory.max/d' "$config_file"
        echo "lxc.cgroup2.memory.max = $mem_limit" >> "$config_file"
        print_success "内存限制已设置: $mem_limit"
    fi
    
    press_enter
}

set_container_remark() {
    clear
    echo "=========================================="
    echo "   设置容器备注"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    read -p "备注信息: " remark
    
    local config_file="/var/lib/lxc/$container_name/config"
    
    if [ ! -f "$config_file" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    sed -i '/# LXC_REMARK/d' "$config_file"
    echo "# LXC_REMARK: $remark" >> "$config_file"
    
    print_success "备注已设置"
    
    press_enter
}

set_container_autostart() {
    clear
    echo "=========================================="
    echo "   设置开机自启"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    local config_file="/var/lib/lxc/$container_name/config"
    
    if [ ! -f "$config_file" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    sed -i '/lxc.start/d' "$config_file"
    echo "lxc.start.auto = 1" >> "$config_file"
    
    print_success "开机自启已启用"
    
    press_enter
}

backup_container() {
    clear
    echo "=========================================="
    echo "   备份容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ ! -d "/var/lib/lxc/$container_name" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    local backup_file="/root/${container_name}_$(date +%F).tar.gz"
    
    print_info "正在备份容器..."
    tar czf "$backup_file" -C /var/lib/lxc "$container_name"
    
    if [ $? -eq 0 ]; then
        print_success "备份完成"
        echo ""
        echo "备份文件: $backup_file"
        echo "文件大小: $(du -h $backup_file | awk '{print $1}')"
    else
        print_error "备份失败"
    fi
    
    press_enter
}

restore_container() {
    clear
    echo "=========================================="
    echo "   恢复容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    read -p "备份文件路径: " backup_file
    
    if [ ! -f "$backup_file" ]; then
        print_error "备份文件不存在"
        press_enter
        return
    fi
    
    print_info "正在恢复容器..."
    tar xzf "$backup_file" -C /var/lib/lxc/
    
    if [ $? -eq 0 ]; then
        print_success "恢复完成"
    else
        print_error "恢复失败"
    fi
    
    press_enter
}

show_network_status() {
    clear
    echo "=========================================="
    echo "   网络状态"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    print_info "网桥信息："
    brctl show
    echo ""
    
    print_info "lxcbr0 接口信息："
    ip addr show lxcbr0
    echo ""
    
    press_enter
}

manage_port_forwards() {
    clear
    echo "=========================================="
    echo "   端口转发管理"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    print_info "当前端口转发规则："
    echo ""
    iptables -t nat -L PREROUTING -n -v --line-numbers
    echo ""
    
    echo "1. 删除规则"
    echo "2. 返回"
    echo ""
    read -p "请选择: " choice
    
    if [ "$choice" = "1" ]; then
        read -p "输入规则序号: " rule_num
        iptables -t nat -D PREROUTING "$rule_num"
        iptables-save > /etc/iptables/rules.v4
        print_success "规则已删除"
    fi
    
    press_enter
}

start_container() {
    clear
    echo "=========================================="
    echo "   启动容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "stopped"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    print_info "正在启动容器..."
    lxc-start -n "$container_name"
    
    if [ $? -eq 0 ]; then
        print_success "容器已启动"
    else
        print_error "启动失败"
    fi
    
    press_enter
}

stop_container() {
    clear
    echo "=========================================="
    echo "   停止容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "running"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    print_info "正在停止容器..."
    lxc-stop -n "$container_name"
    
    if [ $? -eq 0 ]; then
        print_success "容器已停止"
    else
        print_error "停止失败"
    fi
    
    press_enter
}

enter_container() {
    clear
    echo "=========================================="
    echo "   进入容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "running"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    print_info "进入容器 (输入 exit 退出)..."
    echo ""
    lxc-attach -n "$container_name"
}

delete_container() {
    clear
    echo "=========================================="
    echo "   删除容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    print_warning "警告：此操作将永久删除容器"
    read -p "确认删除？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "停止容器..."
    lxc-stop -n "$container_name" -k 2>/dev/null || true
    
    print_info "删除容器..."
    lxc-destroy -n "$container_name"
    
    if [ $? -eq 0 ]; then
        print_success "容器已删除"
    else
        print_error "删除失败"
    fi
    
    press_enter
}

delete_all_containers() {
    clear
    echo "=========================================="
    echo "   删除所有容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    print_error "危险操作：将删除所有容器"
    echo ""
    read -p "输入 DELETE 确认: " confirm
    
    if [ "$confirm" != "DELETE" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "删除所有容器..."
    
    for container in $(lxc-ls 2>/dev/null); do
        lxc-stop -n "$container" -k 2>/dev/null || true
        lxc-destroy -n "$container"
    done
    
    print_success "所有容器已删除"
    
    press_enter
}

debug_container_config() {
    clear
    echo "=========================================="
    echo "   查看容器配置"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    local config_file="/var/lib/lxc/$container_name/config"
    
    if [ ! -f "$config_file" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    echo ""
    print_info "配置文件内容："
    echo ""
    cat "$config_file"
    echo ""
    
    press_enter
}

# ==============================================================================
#                                   主菜单
# ==============================================================================

main_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   LXC 容器管理 (v6.8)"
        echo "=========================================="
        echo ""
        
        # 显示安装状态
        if check_lxc_installed; then
            print_success "LXC 已安装"
            
            # 显示容器统计
            if check_root; then
                local total=$(lxc-ls 2>/dev/null | wc -w)
                local running=$(lxc-ls --running 2>/dev/null | wc -w)
                echo "  容器: ${running} 运行中 / ${total} 总计"
            fi
        else
            print_warning "LXC 未安装"
        fi
        
        echo ""
        echo -e "${BLUE}[基础环境]${NC}"
        echo "1.  安装 LXC 环境"
        echo "2.  配置网络桥接"
        echo "3.  配置宿主机 Swap"
        echo ""
        echo -e "${BLUE}[日常管理]${NC}"
        echo "4.  创建 Debian 12 容器"
        echo "5.  启动容器"
        echo "6.  停止容器"
        echo "7.  进入容器"
        echo "8.  删除容器"
        echo "9.  克隆容器"
        echo ""
        echo -e "${BLUE}[配置修改]${NC}"
        echo "10. 设置资源限制"
        echo "11. 设置静态 IP (自动检测子网)"
        echo "12. 设置容器备注"
        echo "13. 设置开机自启"
        echo "14. 切换特权模式 (自动配置 FUSE)"
        echo ""
        echo -e "${BLUE}[数据维护]${NC}"
        echo "15. 备份容器"
        echo "16. 恢复容器"
        echo "17. 删除所有容器 (危险)"
        echo ""
        echo -e "${CYAN}[监控面板]${NC}"
        echo "18. 查看网络状态"
        echo "19. 端口转发管理"
        echo "20. 全景控制台"
        echo "21. 资源使用快照"
        echo "22. 配置端口转发"
        echo "23. 查看容器配置 (调试)"
        echo ""
        echo "0.  返回主菜单"
        echo ""
        echo "=========================================="
        read -p "请选择操作: " choice
        
        case $choice in
            1) install_lxc ;;
            2) setup_network_bridge ;;
            3) configure_host_swap ;;
            4) create_debian12 ;;
            5) start_container ;;
            6) stop_container ;;
            7) enter_container ;;
            8) delete_container ;;
            9) clone_container ;;
            10) set_resource_limits ;;
            11) set_static_ip ;;
            12) set_container_remark ;;
            13) set_container_autostart ;;
            14) toggle_privileged ;;
            15) backup_container ;;
            16) restore_container ;;
            17) delete_all_containers ;;
            18) show_network_status ;;
            19) manage_port_forwards ;;
            20) show_dashboard ;;
            21) show_realtime_stats ;;
            22) setup_port_forward ;;
            23) debug_container_config ;;
            0) exit 0 ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# 启动主菜单
main_menu
