#!/bin/bash
set -euo pipefail


# ============================================
# 安全与监控管理脚本
# 合并了安全配置和监控查看功能
# ============================================


# 配置
PUBKEY="${SSH_PUBKEY:-YOUR_SSH_PUBLIC_KEY_HERE}"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSH_DIR="$HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
FAIL2BAN_JAIL="/etc/fail2ban/jail.local"
MAX_RETRY=3


# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'


print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }


# ============================================
# 辅助函数
# ============================================


# 获取当前 SSH 端口
get_current_ssh_port() {
    local port=$(grep -E "^Port [0-9]+" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    if [ -z "$port" ]; then
        echo "22"
    else
        echo "$port"
    fi
}


# 获取已配置的 SSH 公钥
get_ssh_keys() {
    if [ -f "$AUTHORIZED_KEYS" ]; then
        local key_count=$(grep -v "^#\|^$" "$AUTHORIZED_KEYS" 2>/dev/null | wc -l)
        if [ "$key_count" -eq 0 ]; then
            echo "未配置"
        else
            echo "$key_count 个"
        fi
    else
        echo "未配置"
    fi
}


# 检查密码登录状态
get_password_auth_status() {
    local password_auth=$(grep -E "^PasswordAuthentication" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    
    if [ -z "$password_auth" ]; then
        # 如果没有配置，默认是 yes
        echo "已启用"
    elif [ "$password_auth" = "yes" ]; then
        echo "已启用"
    elif [ "$password_auth" = "no" ]; then
        echo "已禁用"
    else
        echo "未知"
    fi
}


# 显示 SSH 公钥详情
show_ssh_keys_detail() {
    echo ""
    echo "=========================================="
    echo "当前已配置的 SSH 公钥"
    echo "=========================================="
    echo ""
    
    if [ ! -f "$AUTHORIZED_KEYS" ]; then
        print_warning "未找到 authorized_keys 文件"
        echo "文件路径: $AUTHORIZED_KEYS"
        return
    fi
    
    local keys=$(grep -v "^#\|^$" "$AUTHORIZED_KEYS" 2>/dev/null)
    
    if [ -z "$keys" ]; then
        print_warning "未配置任何公钥"
        echo ""
        print_info "公钥文件: $AUTHORIZED_KEYS"
        return
    fi
    
    local index=1
    while IFS= read -r key; do
        if [ -n "$key" ]; then
            echo -e "${CYAN}[公钥 $index]${NC}"
            
            # 提取密钥类型
            local key_type=$(echo "$key" | awk '{print $1}')
            echo "  类型: $key_type"
            
            # 提取指纹
            local fingerprint=$(echo "$key" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
            if [ -n "$fingerprint" ]; then
                echo "  指纹: $fingerprint"
            fi
            
            # 提取注释（通常是邮箱或用户名）
            local comment=$(echo "$key" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i}' | sed 's/ $//')
            if [ -n "$comment" ]; then
                echo "  备注: $comment"
            fi
            
            # 显示密钥预览（前后各20个字符）
            local key_data=$(echo "$key" | awk '{print $2}')
            local key_len=${#key_data}
            if [ "$key_len" -gt 50 ]; then
                local preview="${key_data:0:20}...${key_data: -20}"
                echo "  预览: $preview"
            else
                echo "  预览: $key_data"
            fi
            
            echo ""
            ((index++))
        fi
    done <<< "$keys"
    
    echo "文件路径: $AUTHORIZED_KEYS"
    echo "=========================================="
}


# 生成随机端口 (20000-60000)
generate_random_port() {
    echo $((20000 + RANDOM % 40001))
}


# 检查端口是否被占用
check_port_available() {
    local port=$1
    if sudo ss -tunlp | grep -q ":${port} "; then
        return 1
    else
        return 0
    fi
}


# ============================================
# 安全配置功能函数
# ============================================


# 功能 1: 添加 SSH 公钥
setup_ssh_key() {
    echo ""
    echo "=========================================="
    echo "添加 SSH 公钥"
    echo "=========================================="
    
    # 先显示当前公钥
    show_ssh_keys_detail
    
    echo ""
    print_info "添加新的 SSH 公钥"
    echo ""
    
    # 检查公钥
    if [[ "$PUBKEY" == "YOUR_SSH_PUBLIC_KEY_HERE" ]]; then
        echo "请输入 SSH 公钥（完整的一行）："
        read -r PUBKEY
        
        if [[ -z "$PUBKEY" ]]; then
            print_error "公钥不能为空"
            read -p "按 Enter 键返回..."
            return 1
        fi
    fi
    
    # 检查 SSH 配置
    echo "[步骤 1/3] 检查 SSH 服务器配置..."
    
    if [[ ! -f "$SSHD_CONFIG" ]]; then
        print_error "未找到 $SSHD_CONFIG"
        read -p "按 Enter 键返回..."
        return 1
    fi
    
    NEEDS_RESTART=false
    
    if grep -q "^PubkeyAuthentication no" "$SSHD_CONFIG"; then
        sudo sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' "$SSHD_CONFIG"
        NEEDS_RESTART=true
    elif grep -q "^#PubkeyAuthentication" "$SSHD_CONFIG"; then
        sudo sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
        NEEDS_RESTART=true
    elif grep -q "^PubkeyAuthentication yes" "$SSHD_CONFIG"; then
        print_success "公钥认证已启用"
    else
        echo "PubkeyAuthentication yes" | sudo tee -a "$SSHD_CONFIG" > /dev/null
        NEEDS_RESTART=true
    fi
    
    # 重启 SSH 服务
    echo ""
    echo "[步骤 2/3] 应用 SSH 配置..."
    
    if $NEEDS_RESTART; then
        if sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null; then
            print_success "SSH 服务已重启"
        else
            print_error "SSH 服务重启失败"
            read -p "按 Enter 键返回..."
            return 1
        fi
    else
        print_success "无需重启 SSH 服务"
    fi
    
    # 添加公钥
    echo ""
    echo "[步骤 3/3] 添加公钥到 authorized_keys..."
    
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
    
    if grep -qF "$PUBKEY" "$AUTHORIZED_KEYS"; then
        print_success "公钥已存在"
    else
        echo "$PUBKEY" >> "$AUTHORIZED_KEYS"
        print_success "公钥添加成功"
    fi
    
    echo ""
    print_success "SSH 公钥配置完成！"
    echo ""
    
    # 显示更新后的公钥列表
    show_ssh_keys_detail
    
    read -p "按 Enter 键返回..."
}


# 功能 2: 禁用密码登录
disable_password_auth() {
    echo ""
    echo "=========================================="
    echo "禁用 SSH 密码登录"
    echo "=========================================="
    echo ""
    
    # 检查当前状态
    local current_status=$(get_password_auth_status)
    print_info "当前密码登录状态: $current_status"
    echo ""
    
    if [ "$current_status" = "已禁用" ]; then
        print_success "密码登录已经禁用，无需操作"
        read -p "按 Enter 键返回..."
        return 0
    fi
    
    # 检查是否有公钥
    local key_count=$(get_ssh_keys)
    if [ "$key_count" = "未配置" ]; then
        print_error "警告：未配置任何 SSH 公钥！"
        echo ""
        print_warning "禁用密码登录前必须先配置至少一个 SSH 公钥"
        print_info "否则将无法登录服务器！"
        echo ""
        read -p "是否先配置 SSH 公钥？[Y/n]: " setup_key
        
        if [[ ! "$setup_key" =~ ^[Nn]$ ]]; then
            setup_ssh_key
            return 0
        else
            print_error "已取消操作"
            read -p "按 Enter 键返回..."
            return 1
        fi
    fi
    
    # 显示警告
    echo -e "${RED}重要警告：${NC}"
    echo "  1. 禁用后只能使用 SSH 密钥登录"
    echo "  2. 必须确保公钥配置正确"
    echo "  3. 建议先在新窗口测试密钥登录"
    echo ""
    echo -e "${CYAN}当前已配置公钥：${key_count}${NC}"
    echo ""
    read -p "确认禁用密码登录？[y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消操作"
        read -p "按 Enter 键返回..."
        return 0
    fi
    
    # 备份配置文件
    echo ""
    echo "[步骤 1/3] 备份配置文件..."
    sudo cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"
    print_success "已备份配置文件"
    
    # 修改配置
    echo ""
    echo "[步骤 2/3] 修改 SSH 配置..."
    
    # 禁用密码认证
    if grep -q "^PasswordAuthentication" "$SSHD_CONFIG"; then
        sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    elif grep -q "^#PasswordAuthentication" "$SSHD_CONFIG"; then
        sudo sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    else
        echo "PasswordAuthentication no" | sudo tee -a "$SSHD_CONFIG" > /dev/null
    fi
    
    # 禁用质询响应认证
    if grep -q "^ChallengeResponseAuthentication" "$SSHD_CONFIG"; then
        sudo sed -i 's/^ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
    elif grep -q "^#ChallengeResponseAuthentication" "$SSHD_CONFIG"; then
        sudo sed -i 's/^#ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
    else
        echo "ChallengeResponseAuthentication no" | sudo tee -a "$SSHD_CONFIG" > /dev/null
    fi
    
    # 确保公钥认证启用
    if grep -q "^PubkeyAuthentication no" "$SSHD_CONFIG"; then
        sudo sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' "$SSHD_CONFIG"
    elif grep -q "^#PubkeyAuthentication" "$SSHD_CONFIG"; then
        sudo sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
    elif ! grep -q "^PubkeyAuthentication" "$SSHD_CONFIG"; then
        echo "PubkeyAuthentication yes" | sudo tee -a "$SSHD_CONFIG" > /dev/null
    fi
    
    print_success "配置已修改"
    
    # 重启 SSH 服务
    echo ""
    echo "[步骤 3/3] 重启 SSH 服务..."
    echo ""
    print_warning "即将重启 SSH 服务"
    print_error "请确保在另一个窗口测试过密钥登录！"
    echo ""
    read -p "确认重启 SSH 服务？[y/N]: " confirm_restart
    
    if [[ "$confirm_restart" =~ ^[Yy]$ ]]; then
        if sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null; then
            print_success "SSH 服务已重启"
            echo ""
            echo "=========================================="
            print_success "密码登录已禁用！"
            echo "=========================================="
            echo ""
            print_info "安全配置："
            echo "  • 密码登录: 已禁用"
            echo "  • 公钥登录: 已启用"
            echo "  • 配置公钥: $key_count"
            echo ""
            print_warning "请在新窗口测试密钥登录，确认成功后再关闭此会话！"
        else
            print_error "SSH 服务重启失败"
            echo ""
            print_warning "正在回滚配置..."
            sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$SSHD_CONFIG"
            sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null
            print_info "已回滚配置"
        fi
    else
        print_warning "已取消重启，配置已修改但未生效"
        print_info "手动重启 SSH 服务: sudo systemctl restart sshd"
    fi
    
    echo ""
    read -p "按 Enter 键返回..."
}


# 功能 3: 修改 SSH 端口
change_ssh_port() {
    echo ""
    echo "=========================================="
    echo "修改 SSH 端口"
    echo "=========================================="
    echo ""
    
    local current_port=$(get_current_ssh_port)
    print_info "当前 SSH 端口: $current_port"
    echo ""
    
    # 生成随机端口
    local new_port=$(generate_random_port)
    
    echo "将修改 SSH 端口为随机端口（20000-60000）"
    echo -e "${CYAN}建议端口: $new_port${NC}"
    echo ""
    read -p "使用建议端口？[Y/n]: " use_suggested
    
    if [[ "$use_suggested" =~ ^[Nn]$ ]]; then
        read -p "请输入自定义端口 (20000-60000): " custom_port
        
        # 验证端口范围
        if [[ ! "$custom_port" =~ ^[0-9]+$ ]] || [ "$custom_port" -lt 20000 ] || [ "$custom_port" -gt 60000 ]; then
            print_error "端口必须在 20000-60000 之间"
            read -p "按 Enter 键返回..."
            return 1
        fi
        
        new_port=$custom_port
    fi
    
    # 检查端口是否被占用
    echo ""
    echo "[步骤 1/5] 检查端口可用性..."
    if ! check_port_available "$new_port"; then
        print_error "端口 $new_port 已被占用"
        read -p "按 Enter 键返回..."
        return 1
    fi
    print_success "端口 $new_port 可用"
    
    # 备份配置文件
    echo ""
    echo "[步骤 2/5] 备份配置文件..."
    sudo cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"
    print_success "已备份到 ${SSHD_CONFIG}.backup.*"
    
    # 修改 SSH 配置
    echo ""
    echo "[步骤 3/5] 修改 SSH 配置..."
    if grep -q "^Port " "$SSHD_CONFIG"; then
        sudo sed -i "s/^Port .*/Port $new_port/" "$SSHD_CONFIG"
    else
        echo "Port $new_port" | sudo tee -a "$SSHD_CONFIG" > /dev/null
    fi
    print_success "SSH 端口已设置为 $new_port"
    
    # 更新 Fail2ban 配置
    echo ""
    echo "[步骤 4/5] 更新 Fail2ban 配置..."
    if [ -f "$FAIL2BAN_JAIL" ]; then
        if grep -q "^port = " "$FAIL2BAN_JAIL"; then
            sudo sed -i "s/^port = .*/port = $new_port/" "$FAIL2BAN_JAIL"
        else
            sudo sed -i "/\[sshd\]/a port = $new_port" "$FAIL2BAN_JAIL"
        fi
        
        # 重启 Fail2ban
        if sudo systemctl is-active --quiet fail2ban; then
            sudo systemctl restart fail2ban
            print_success "Fail2ban 配置已更新"
        else
            print_warning "Fail2ban 服务未运行"
        fi
    else
        print_warning "未找到 Fail2ban 配置文件"
    fi
    
    # 更新 UFW 规则
    echo ""
    echo "[步骤 5/5] 更新防火墙规则..."
    if command -v ufw &> /dev/null; then
        if sudo ufw status | grep -q "Status: active"; then
            # 添加新端口
            sudo ufw allow "$new_port/tcp" comment 'SSH'
            print_success "已添加新端口 $new_port 到防火墙"
            
            # 删除旧端口规则
            echo ""
            if [ "$current_port" != "$new_port" ]; then
                # 检查旧端口是否在防火墙规则中
                if sudo ufw status numbered | grep -q "$current_port/tcp"; then
                    print_info "检测到旧端口 $current_port 的防火墙规则"
                    read -p "是否删除旧端口 $current_port 的防火墙规则？[Y/n]: " remove_old
                    
                    if [[ ! "$remove_old" =~ ^[Nn]$ ]]; then
                        # 删除所有匹配的规则（可能有多条）
                        while sudo ufw status numbered | grep -q "$current_port/tcp"; do
                            local rule_num=$(sudo ufw status numbered | grep "$current_port/tcp" | head -1 | grep -oP '^\[\s*\K[0-9]+')
                            if [ -n "$rule_num" ]; then
                                echo "y" | sudo ufw delete "$rule_num" 2>/dev/null
                            else
                                break
                            fi
                        done
                        print_success "已删除旧端口 $current_port 的防火墙规则"
                    else
                        print_warning "保留旧端口 $current_port 的防火墙规则"
                    fi
                fi
            fi
            
            # 显示当前规则
            echo ""
            print_info "当前 SSH 相关防火墙规则："
            sudo ufw status numbered | grep -E "SSH|$new_port" || print_warning "未找到 SSH 规则"
        else
            print_warning "UFW 防火墙未启用"
            print_info "建议稍后运行选项 5 配置防火墙"
        fi
    else
        print_warning "未安装 UFW 防火墙"
        print_info "建议稍后运行选项 5 安装配置防火墙"
    fi
    
    # 重启 SSH 服务
    echo ""
    print_warning "即将重启 SSH 服务..."
    echo ""
    print_error "重要提醒："
    echo "  1. 新的 SSH 端口: $new_port"
    echo "  2. 旧的 SSH 端口: $current_port"
    echo "  3. 请使用新端口重新连接: ssh -p $new_port user@host"
    echo "  4. 建议在新窗口测试连接成功后再关闭当前会话"
    echo ""
    read -p "确认重启 SSH 服务？[y/N]: " confirm_restart
    
    if [[ "$confirm_restart" =~ ^[Yy]$ ]]; then
        if sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null; then
            print_success "SSH 服务已重启"
            echo ""
            echo "=========================================="
            print_success "SSH 端口修改完成！"
            echo "=========================================="
            echo ""
            echo -e "${CYAN}新的连接命令:${NC}"
            echo "  ssh -p $new_port $(whoami)@$(hostname -I | awk '{print $1}')"
            echo ""
            echo -e "${YELLOW}配置变更摘要:${NC}"
            echo "  • SSH 端口: $current_port -> $new_port"
            if [ -f "$FAIL2BAN_JAIL" ]; then
                echo "  • Fail2ban: 已更新"
            fi
            if command -v ufw &> /dev/null; then
                echo "  • 防火墙: 已更新"
            fi
            echo ""
            print_warning "请在新终端测试连接，确认成功后再关闭此会话！"
        else
            print_error "SSH 服务重启失败"
            echo ""
            print_warning "正在回滚配置..."
            sudo sed -i "s/^Port .*/Port $current_port/" "$SSHD_CONFIG"
            sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null
            print_info "已回滚到端口 $current_port"
        fi
    else
        print_warning "已取消重启，配置已修改但未生效"
        print_info "手动重启 SSH 服务: sudo systemctl restart sshd"
    fi
    
    echo ""
    read -p "按 Enter 键返回..."
}


# 功能 4: 安装配置 Fail2ban
setup_fail2ban() {
    echo ""
    echo "=========================================="
    echo "安装和配置 Fail2ban"
    echo "=========================================="
    
    local current_port=$(get_current_ssh_port)
    
    echo "[步骤 1/4] 检查安装状态..."
    
    if command -v fail2ban-client &> /dev/null; then
        print_success "Fail2ban 已安装"
    else
        print_warning "Fail2ban 未安装，正在安装..."
        sudo apt update
        sudo apt install -y fail2ban
        print_success "安装完成"
    fi
    
    echo ""
    echo "[步骤 2/4] 配置 Fail2ban..."
    
    if [[ -f "$FAIL2BAN_JAIL" ]]; then
        sudo cp "$FAIL2BAN_JAIL" "${FAIL2BAN_JAIL}.backup.$(date +%Y%m%d%H%M%S)"
    fi
    
    sudo tee "$FAIL2BAN_JAIL" > /dev/null <<EOF
[DEFAULT]
bantime = -1
findtime = 10m
maxretry = $MAX_RETRY
backend = systemd


[sshd]
enabled = true
port = $current_port
logpath = %(sshd_log)s
mode = aggressive
EOF


    print_success "配置文件已创建（SSH 端口: $current_port）"
    
    echo ""
    echo "[步骤 3/4] 启动服务..."
    
    sudo systemctl enable fail2ban
    sudo systemctl restart fail2ban
    print_success "Fail2ban 服务已启动"
    
    echo ""
    echo "[步骤 4/4] 验证配置..."
    sleep 2
    
    if sudo fail2ban-client status sshd &> /dev/null; then
        print_success "SSH 保护已启用"
        sudo fail2ban-client status sshd
    fi
    
    echo ""
    print_success "Fail2ban 配置完成！"
    read -p "按 Enter 键返回..."
}


# 功能 5: 配置防火墙
setup_firewall() {
    echo ""
    echo "=========================================="
    echo "安装和配置防火墙（UFW）"
    echo "=========================================="
    
    local current_port=$(get_current_ssh_port)
    
    echo "[步骤 1/5] 检查安装状态..."
    
    if command -v ufw &> /dev/null; then
        print_success "UFW 已安装"
    else
        print_warning "UFW 未安装，正在安装..."
        sudo apt update
        sudo apt install -y ufw
        print_success "安装完成"
    fi
    
    echo ""
    echo "[步骤 2/5] 配置规则..."
    
    read -p "是否重置现有规则？[y/N]: " reset
    if [[ "$reset" =~ ^[Yy]$ ]]; then
        echo "y" | sudo ufw reset
        print_success "规则已重置"
    fi
    
    echo ""
    echo "[步骤 3/5] 设置默认策略..."
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    print_success "默认策略已设置"
    
    echo ""
    echo "[步骤 4/5] 添加端口规则..."
    sudo ufw allow "$current_port/tcp" comment 'SSH'
    sudo ufw allow 80/tcp comment 'HTTP'
    sudo ufw allow 443/tcp comment 'HTTPS'
    print_success "端口 $current_port、80、443 已开放"
    
    echo ""
    echo "[步骤 5/5] 启用防火墙..."
    
    echo ""
    print_warning "启用防火墙后，只有允许的端口可以访问！"
    print_info "SSH 端口 $current_port 已添加到白名单"
    read -p "确认启用？[y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "y" | sudo ufw enable
        sudo systemctl enable ufw
        print_success "防火墙已启用"
    else
        print_warning "已取消启用"
    fi
    
    echo ""
    sudo ufw status verbose
    read -p "按 Enter 键返回..."
}


# 功能 6: 一键安全加固
quick_security() {
    echo ""
    echo "=========================================="
    echo "一键安全加固"
    echo "=========================================="
    echo ""
    echo "将依次执行："
    echo "1. 配置 SSH 公钥"
    echo "2. 禁用密码登录"
    echo "3. 修改 SSH 端口（随机）"
    echo "4. 安装配置 Fail2ban"
    echo "5. 安装配置防火墙"
    echo ""
    read -p "确认继续？[y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        setup_ssh_key
        disable_password_auth
        change_ssh_port
        setup_fail2ban
        setup_firewall
        echo ""
        print_success "一键安全加固完成！"
        read -p "按 Enter 键返回..."
    fi
}


# ============================================
# 监控查看功能函数
# ============================================


# 功能 7: 查看 Fail2ban 状态
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


# 功能 8: 查看防火墙状态
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


# 功能 9: 系统信息
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
# 主菜单
# ============================================


show_security_monitoring_menu() {
    clear
    local current_port=$(get_current_ssh_port)
    local key_count=$(get_ssh_keys)
    local password_status=$(get_password_auth_status)
    
    # 根据状态设置颜色
    local password_color="${RED}"
    if [ "$password_status" = "已禁用" ]; then
        password_color="${GREEN}"
    fi
    
    echo "=========================================="
    echo "   安全与监控管理菜单"
    echo "=========================================="
    echo ""
    echo -e "${CYAN}当前配置状态:${NC}"
    echo -e "  SSH 端口: ${GREEN}${current_port}${NC}"
    echo -e "  SSH 公钥: ${GREEN}${key_count}${NC}"
    echo -e "  密码登录: ${password_color}${password_status}${NC}"
    echo ""
    echo "【安全配置】"
    echo ""
    echo "1. 添加 SSH 公钥（启用密钥认证）"
    echo "2. 禁用密码登录（仅允许密钥登录）"
    echo "3. 修改 SSH 端口（随机 20000-60000）"
    echo "4. 安装配置 Fail2ban（3次失败永久封禁）"
    echo "5. 安装配置防火墙（默认开放SSH/80/443）"
    echo "6. 一键安全加固（执行1+2+3+4+5）"
    echo ""
    echo "【监控查看】"
    echo ""
    echo "7. 查看 Fail2ban 状态"
    echo "8. 查看防火墙状态"
    echo "9. 查看系统信息"
    echo ""
    echo "v. 查看公钥详情"
    echo "0. 返回主菜单"
    echo "=========================================="
}


security_monitoring_menu() {
    while true; do
        show_security_monitoring_menu
        read -p "请选择操作 [0-9/v]: " choice
        
        case $choice in
            1)
                setup_ssh_key
                ;;
            2)
                disable_password_auth
                ;;
            3)
                change_ssh_port
                ;;
            4)
                setup_fail2ban
                ;;
            5)
                setup_firewall
                ;;
            6)
                quick_security
                ;;
            7)
                view_fail2ban
                ;;
            8)
                view_firewall
                ;;
            9)
                view_system_info
                ;;
            v|V)
                show_ssh_keys_detail
                echo ""
                read -p "按 Enter 键返回..."
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


# 启动安全与监控菜单
security_monitoring_menu
