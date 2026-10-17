#!/bin/bash
set -euo pipefail


# ============================================
# Rclone 配置管理脚本
# ============================================


# 配置
RCLONE_CONFIG_DIR="$HOME/.config/rclone"
RCLONE_CONFIG_FILE="$RCLONE_CONFIG_DIR/rclone.conf"
RCLONE_CACHE_DIR="/data/rclone-cache"
RCLONE_MOUNT_BASE="/mnt"
SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"
FUSE_CONF="/etc/fuse.conf"


# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'


print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }


# ============================================
# 辅助函数
# ============================================


# 检查 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "此功能需要 root 权限"
        print_info "请使用 sudo 运行主脚本"
        read -p "按 Enter 键继续..."
        return 1
    fi
    return 0
}


# 检查 rclone 是否安装
check_rclone_installed() {
    if command -v rclone &> /dev/null; then
        return 0
    else
        return 1
    fi
}


# 检查配置文件是否存在
check_config_exists() {
    if [ -f "$RCLONE_CONFIG_FILE" ]; then
        return 0
    else
        return 1
    fi
}


# 规范化配置文件格式（转换为 Unix 格式）
normalize_config_file() {
    if check_config_exists; then
        # 检查是否包含 \r（Windows 格式）
        if grep -q $'\r' "$RCLONE_CONFIG_FILE" 2>/dev/null; then
            # 转换为 Unix 格式
            if command -v dos2unix &> /dev/null; then
                dos2unix "$RCLONE_CONFIG_FILE" 2>/dev/null
            else
                # 使用 sed 或 tr 转换
                sed -i 's/\r$//' "$RCLONE_CONFIG_FILE" 2>/dev/null || {
                    tr -d '\r' < "$RCLONE_CONFIG_FILE" > "${RCLONE_CONFIG_FILE}.tmp" && \
                    mv "${RCLONE_CONFIG_FILE}.tmp" "$RCLONE_CONFIG_FILE"
                }
            fi
            return 0  # 已转换
        fi
    fi
    return 1  # 无需转换或文件不存在
}


# 获取配置的远程存储列表
get_remote_list() {
    if check_config_exists; then
        # 确保配置文件是 Unix 格式
        normalize_config_file
        # 读取远程配置名称
        grep "^\[" "$RCLONE_CONFIG_FILE" | tr -d '[]' | grep -v "^$"
    else
        echo ""
    fi
}


# ============================================
# 核心功能
# ============================================


# 安装 rclone
install_rclone() {
    clear
    echo "=========================================="
    echo "   安装 Rclone"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    if check_rclone_installed; then
        print_warning "Rclone 已安装"
        rclone version
        read -p "按 Enter 键继续..."
        return
    fi
    
    print_info "正在安装 Rclone..."
    echo ""
    
    # 安装依赖
    echo "[步骤 1/4] 安装依赖 (fuse3)..."
    if ! command -v fusermount3 &> /dev/null; then
        apt-get update
        apt-get install -y fuse3 unzip curl
        print_success "依赖安装完成"
    else
        print_success "依赖已存在"
    fi
    
    # 下载 rclone
    echo ""
    echo "[步骤 2/4] 下载 Rclone..."
    cd /tmp
    rm -rf rclone-*
    
    if curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip; then
        print_success "下载完成"
    else
        print_error "下载失败"
        read -p "按 Enter 键继续..."
        return 1
    fi
    
    # 解压安装
    echo ""
    echo "[步骤 3/4] 安装 Rclone..."
    unzip -q rclone-current-linux-amd64.zip
    cd rclone-*-linux-amd64
    
    cp rclone /usr/bin/
    chown root:root /usr/bin/rclone
    chmod 755 /usr/bin/rclone
    
    print_success "Rclone 安装完成"
    
    # 配置 fuse
    echo ""
    echo "[步骤 4/4] 配置 FUSE..."
    if ! grep -q "^user_allow_other" "$FUSE_CONF"; then
        echo "user_allow_other" >> "$FUSE_CONF"
        print_success "FUSE 配置完成"
    else
        print_success "FUSE 已配置"
    fi
    
    # 清理
    cd /tmp
    rm -rf rclone-*
    
    echo ""
    print_success "Rclone 安装完成！"
    echo ""
    rclone version
    
    read -p "按 Enter 键继续..."
}


# 配置 rclone.conf
setup_rclone_config() {
    clear
    echo "=========================================="
    echo "   配置 Rclone"
    echo "=========================================="
    echo ""
    
    # 创建配置目录
    mkdir -p "$RCLONE_CONFIG_DIR"
    
    if check_config_exists; then
        print_warning "配置文件已存在"
        echo ""
        echo "配置文件: $RCLONE_CONFIG_FILE"
        echo ""
        print_info "现有远程存储："
        local remotes=$(get_remote_list)
        if [ -n "$remotes" ]; then
            echo "$remotes" | while read -r remote; do
                echo "  • $remote"
            done
        else
            echo "  (空)"
        fi
        echo ""
        
        read -p "是否覆盖现有配置？[y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            print_info "已取消"
            read -p "按 Enter 键继续..."
            return
        fi
        
        # 备份现有配置
        cp "$RCLONE_CONFIG_FILE" "${RCLONE_CONFIG_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        print_success "已备份现有配置"
    fi
    
    echo ""
    print_info "请粘贴 rclone.conf 文件内容"
    print_warning "粘贴完成后，输入一个空行，然后输入 EOF 并按 Enter"
    echo ""
    echo "示例格式："
    echo "[onedrive]"
    echo "type = onedrive"
    echo "token = {...}"
    echo "drive_id = xxx"
    echo "drive_type = business"
    echo ""
    echo "开始粘贴："
    echo "----------------------------------------"
    
    # 读取多行输入
    local config_content=""
    local line_count=0
    
    while IFS= read -r line; do
        # 检查是否输入 EOF
        if [ "$line" = "EOF" ]; then
            break
        fi
        
        config_content+="$line"$'\n'
        ((line_count++))
    done
    
    echo "----------------------------------------"
    echo ""
    
    if [ $line_count -eq 0 ]; then
        print_error "未输入任何内容"
        read -p "按 Enter 键继续..."
        return 1
    fi
    
    
    # 写入配置文件
    echo "$config_content" > "$RCLONE_CONFIG_FILE"
    
    # 转换为 Unix 格式（LF），防止 Windows 格式（CRLF）导致的问题
    if command -v dos2unix &> /dev/null; then
        dos2unix "$RCLONE_CONFIG_FILE" 2>/dev/null
        print_success "已转换为 Unix 格式"
    else
        # 如果没有 dos2unix，使用 sed 或 tr 转换
        sed -i 's/\r$//' "$RCLONE_CONFIG_FILE" 2>/dev/null || tr -d '\r' < "$RCLONE_CONFIG_FILE" > "${RCLONE_CONFIG_FILE}.tmp" && mv "${RCLONE_CONFIG_FILE}.tmp" "$RCLONE_CONFIG_FILE"
        print_success "已清理换行符格式"
    fi
    
    chmod 600 "$RCLONE_CONFIG_FILE"
    
    print_success "配置文件已保存"
    echo ""
    print_info "配置文件: $RCLONE_CONFIG_FILE"
    print_info "读取到 $line_count 行配置"
    echo ""
    
    # 验证配置
    print_info "验证配置..."
    if rclone listremotes &> /dev/null; then
        print_success "配置验证成功"
        echo ""
        print_info "已配置的远程存储："
        rclone listremotes | while read -r remote; do
            echo "  • ${remote%:}"
        done
    else
        print_error "配置验证失败"
        print_warning "请检查配置文件格式"
    fi
    
    read -p "按 Enter 键继续..."
}


# 挂载远程存储
mount_remote() {
    clear
    echo "=========================================="
    echo "   挂载远程存储"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    if ! check_rclone_installed; then
        print_error "Rclone 未安装"
        read -p "按 Enter 键继续..."
        return
    fi
    
    if ! check_config_exists; then
        print_error "Rclone 配置文件不存在"
        print_info "请先配置 rclone.conf"
        read -p "按 Enter 键继续..."
        return
    fi
    
    # 获取远程存储列表
    local remotes=$(get_remote_list)
    if [ -z "$remotes" ]; then
        print_error "未找到任何远程存储配置"
        read -p "按 Enter 键继续..."
        return
    fi
    
    print_info "可用的远程存储："
    echo ""
    local i=1
    declare -A remote_map
    while IFS= read -r remote; do
        # 配置文件已被规范化，只需简单清理可能的空白字符
        remote=$(echo "$remote" | xargs)
        [ -z "$remote" ] && continue
        echo "$i. $remote"
        remote_map[$i]="$remote"
        ((i++))
    done <<< "$remotes"
    
    echo ""
    read -p "选择要挂载的远程存储 [1-$((i-1))]: " choice
    
    local selected_remote="${remote_map[$choice]}"
    
    if [ -z "$selected_remote" ]; then
        print_error "无效选择"
        read -p "按 Enter 键继续..."
        return
    fi
    
    # 配置挂载参数
    echo ""
    print_info "配置挂载参数"
    echo ""
    
    read -p "远程路径 (默认: /): " remote_path
    remote_path=${remote_path:-/}
    
    read -p "本地挂载点 (默认: ${RCLONE_MOUNT_BASE}/${selected_remote}): " mount_point
    mount_point=${mount_point:-${RCLONE_MOUNT_BASE}/${selected_remote}}
    
    read -p "缓存目录 (默认: ${RCLONE_CACHE_DIR}/${selected_remote}): " cache_dir
    cache_dir=${cache_dir:-${RCLONE_CACHE_DIR}/${selected_remote}}
    
    read -p "缓存大小 (默认: 512M): " cache_size
    cache_size=${cache_size:-512M}
    
    # 获取 www-data 用户 UID/GID
    local www_uid=$(id -u www-data 2>/dev/null || echo "33")
    local www_gid=$(id -g www-data 2>/dev/null || echo "33")
    
    # 创建目录
    echo ""
    echo "[步骤 1/3] 创建目录..."
    mkdir -p "$mount_point"
    mkdir -p "$cache_dir"
    chown -R www-data:www-data "$cache_dir"
    print_success "目录创建完成"
    
    # 生成挂载命令（不再需要 --config 参数，使用默认路径）
    local rclone_cmd="/usr/bin/rclone mount ${selected_remote}:${remote_path} ${mount_point} --cache-dir ${cache_dir} --vfs-cache-mode full --vfs-cache-max-size ${cache_size} --vfs-read-chunk-size 16M --allow-other --dir-cache-time 1h --poll-interval 1m --attr-timeout 1h --uid=${www_uid} --gid=${www_gid} --umask 002"
    
    # 测试挂载
    echo ""
    echo "[步骤 2/3] 测试挂载..."
    print_warning "测试挂载中，请等待..."
    echo ""
    
    read -p "是否进行测试挂载？[Y/n]: " test_mount
    if [[ ! "$test_mount" =~ ^[Nn]$ ]]; then
        print_info "执行命令: ${rclone_cmd} --verbose"
        echo ""
        timeout 10s bash -c "$rclone_cmd --verbose" &
        local mount_pid=$!
        
        sleep 5
        
        if mount | grep -q "$mount_point"; then
            print_success "挂载测试成功"
            kill $mount_pid 2>/dev/null || true
            umount "$mount_point" 2>/dev/null || fusermount -u "$mount_point" 2>/dev/null || true
        else
            print_error "挂载测试失败"
            kill $mount_pid 2>/dev/null || true
            read -p "按 Enter 键继续..."
            return 1
        fi
    fi
    
    # 配置 Supervisor
    echo ""
    echo "[步骤 3/3] 配置 Supervisor..."
    
    if ! command -v supervisorctl &> /dev/null; then
        print_warning "Supervisor 未安装"
        print_info "请先安装 Supervisor（容器管理菜单）"
        echo ""
        print_info "手动挂载命令："
        echo "$rclone_cmd"
        read -p "按 Enter 键继续..."
        return
    fi
    
    local supervisor_conf="${SUPERVISOR_CONF_DIR}/rclone-${selected_remote}.conf"
    
    cat > "$supervisor_conf" <<EOF
[program:rclone-${selected_remote}]
command=${rclone_cmd}
autostart=true
autorestart=true
user=root
redirect_stderr=true
stdout_logfile=/var/log/supervisor/rclone-${selected_remote}.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=3
stderr_logfile=/var/log/supervisor/rclone-${selected_remote}-error.log
stderr_logfile_maxbytes=50MB
stderr_logfile_backups=3
EOF
    
    print_success "Supervisor 配置已创建"
    echo ""
    
    # 重载 Supervisor
    print_info "重载 Supervisor..."
    supervisorctl reread
    supervisorctl update
    
    sleep 2
    
    if supervisorctl status rclone-${selected_remote} | grep -q "RUNNING"; then
        print_success "挂载服务已启动"
        echo ""
        print_info "挂载信息："
        echo "  远程: ${selected_remote}:${remote_path}"
        echo "  挂载点: ${mount_point}"
        echo "  缓存: ${cache_dir} (${cache_size})"
        echo "  配置: ${RCLONE_CONFIG_FILE}"
        echo "  状态: $(supervisorctl status rclone-${selected_remote} | awk '{print $2}')"
    else
        print_error "挂载服务启动失败"
        echo ""
        supervisorctl status rclone-${selected_remote}
    fi
    
    read -p "按 Enter 键继续..."
}


# 查看挂载状态
view_mount_status() {
    clear
    echo "=========================================="
    echo "   Rclone 挂载状态"
    echo "=========================================="
    echo ""
    
    # 检查系统挂载
    print_info "系统挂载点："
    echo ""
    if mount | grep rclone | grep -v grep; then
        echo ""
    else
        print_warning "未发现 rclone 挂载"
    fi
    
    echo ""
    echo "=========================================="
    
    # 检查 Supervisor 状态
    if command -v supervisorctl &> /dev/null; then
        echo ""
        print_info "Supervisor 服务状态："
        echo ""
        
        local rclone_services=$(supervisorctl status | grep rclone || echo "")
        if [ -n "$rclone_services" ]; then
            echo "$rclone_services"
        else
            print_warning "未配置 rclone 服务"
        fi
    fi
    
    # 显示配置文件路径
    echo ""
    echo "=========================================="
    print_info "配置信息："
    echo "  配置文件: ${RCLONE_CONFIG_FILE}"
    if check_config_exists; then
        echo "  状态: 存在"
        local remote_count=$(get_remote_list | wc -l)
        echo "  远程存储: ${remote_count} 个"
    else
        echo "  状态: 不存在"
    fi
    
    read -p "按 Enter 键继续..."
}


# 卸载挂载
umount_remote() {
    clear
    echo "=========================================="
    echo "   卸载远程存储"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    if ! command -v supervisorctl &> /dev/null; then
        print_error "Supervisor 未安装"
        read -p "按 Enter 键继续..."
        return
    fi
    
    # 列出 rclone 服务
    local rclone_services=$(supervisorctl status | grep "rclone-" | awk '{print $1}')
    
    if [ -z "$rclone_services" ]; then
        print_warning "未找到 rclone 挂载服务"
        read -p "按 Enter 键继续..."
        return
    fi
    
    print_info "当前 rclone 服务："
    echo ""
    
    local i=1
    declare -A service_map
    while IFS= read -r service; do
        local status=$(supervisorctl status "$service" | awk '{print $2}')
        echo "$i. $service [$status]"
        service_map[$i]="$service"
        ((i++))
    done <<< "$rclone_services"
    
    echo ""
    read -p "选择要卸载的服务 [1-$((i-1))]: " choice
    
    local selected_service="${service_map[$choice]}"
    if [ -z "$selected_service" ]; then
        print_error "无效选择"
        read -p "按 Enter 键继续..."
        return
    fi
    
    echo ""
    print_warning "确认卸载 $selected_service？"
    read -p "继续？[y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        read -p "按 Enter 键继续..."
        return
    fi
    
    # 停止服务
    print_info "停止服务..."
    supervisorctl stop "$selected_service"
    
    # 删除配置
    rm -f "${SUPERVISOR_CONF_DIR}/${selected_service}.conf"
    
    # 重载
    supervisorctl reread
    supervisorctl update
    
    print_success "服务已卸载"
    
    read -p "按 Enter 键继续..."
}


# 查看配置文件
view_config() {
    clear
    echo "=========================================="
    echo "   查看 Rclone 配置"
    echo "=========================================="
    echo ""
    
    if ! check_config_exists; then
        print_warning "配置文件不存在"
        echo ""
        echo "配置文件路径: $RCLONE_CONFIG_FILE"
        read -p "按 Enter 键继续..."
        return
    fi
    
    print_info "配置文件: $RCLONE_CONFIG_FILE"
    echo ""
    echo "=========================================="
    cat "$RCLONE_CONFIG_FILE"
    echo "=========================================="
    
    read -p "按 Enter 键继续..."
}


# ============================================
# 主菜单
# ============================================


show_rclone_menu() {
    clear
    
    local rclone_status="未安装"
    local config_status="未配置"
    local mount_count="0"
    
    if check_rclone_installed; then
        rclone_status="已安装"
        local version=$(rclone version 2>&1 | head -1 | awk '{print $2}')
        rclone_status="已安装 ($version)"
    fi
    
    if check_config_exists; then
        local remote_count=$(get_remote_list | wc -l)
        config_status="已配置 ($remote_count 个远程)"
    fi
    
    if command -v supervisorctl &> /dev/null; then
        mount_count=$(supervisorctl status 2>/dev/null | grep -c "rclone-" || echo "0")
    fi
    
    echo "=========================================="
    echo "   Rclone 配置管理"
    echo "=========================================="
    echo ""
    echo -e "${CYAN}当前状态:${NC}"
    echo -e "  Rclone: ${GREEN}${rclone_status}${NC}"
    echo -e "  配置文件: ${GREEN}${config_status}${NC}"
    echo -e "  配置路径: ${CYAN}${RCLONE_CONFIG_FILE}${NC}"
    echo -e "  挂载服务: ${GREEN}${mount_count} 个${NC}"
    echo ""
    echo "1. 安装 Rclone"
    echo "2. 配置 rclone.conf"
    echo "3. 挂载远程存储"
    echo "4. 查看挂载状态"
    echo "5. 卸载挂载"
    echo "6. 查看配置文件"
    echo ""
    echo "0. 返回主菜单"
    echo "=========================================="
}


rclone_menu() {
    while true; do
        show_rclone_menu
        read -p "请选择操作 [0-6]: " choice
        
        case $choice in
            1)
                install_rclone
                ;;
            2)
                setup_rclone_config
                ;;
            3)
                mount_remote
                ;;
            4)
                view_mount_status
                ;;
            5)
                umount_remote
                ;;
            6)
                view_config
                ;;
            0)
                print_success "返回主菜单"
                sleep 1
                return 0
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}


# 启动菜单
rclone_menu
