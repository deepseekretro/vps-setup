#!/bin/bash

press_enter() {
    echo ""
    echo -n "按 Enter 键继续..."
    read
    clear
}

# 一键配置所有应用日志轮转（3天）
setup_all_logs() {
    clear
    echo "============================================"
    echo "  一键配置所有应用日志轮转（保留3天）"
    echo "============================================"
    echo ""
    echo "将为以下应用配置日志轮转："
    echo "  • OpenResty"
    echo "  • PostgreSQL"
    echo "  • MySQL/MariaDB"
    echo "  • Fail2ban"
    echo "  • Supervisor 及其所有应用"
    echo ""
    echo -n "确认配置？(y/n): "
    read confirm
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "已取消"
        press_enter
        return
    fi
    
    echo ""
    echo "开始配置..."
    echo ""
    
    # OpenResty 配置
    echo "配置 OpenResty..."
    sudo tee /etc/logrotate.d/openresty > /dev/null << 'EOF'
/usr/local/openresty/nginx/logs/*.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        if [ -f /usr/local/openresty/nginx/logs/nginx.pid ]; then
            /bin/kill -USR1 $(cat /usr/local/openresty/nginx/logs/nginx.pid) 2>/dev/null || true
        fi
    endscript
}
EOF
    echo "✓ OpenResty 配置完成"
    
    # PostgreSQL 配置
    echo "配置 PostgreSQL..."
    sudo tee /etc/logrotate.d/postgresql-common > /dev/null << 'EOF'
/var/log/postgresql/*.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    su postgres postgres
    sharedscripts
}
EOF
    echo "✓ PostgreSQL 配置完成"
    
    # MySQL 配置
    echo "配置 MySQL..."
    sudo tee /etc/logrotate.d/mysql-server > /dev/null << 'EOF'
/var/log/mysql/*.log
/var/log/mysql/*/*.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        if [ -x /usr/bin/mysqladmin ]; then
            /usr/bin/mysqladmin --defaults-file=/etc/mysql/debian.cnf ping &>/dev/null
            if [ $? -eq 0 ]; then
                /usr/bin/mysqladmin --defaults-file=/etc/mysql/debian.cnf flush-logs
            fi
        fi
    endscript
}
EOF
    echo "✓ MySQL 配置完成"
    
    # Fail2ban 配置
    echo "配置 Fail2ban..."
    sudo tee /etc/logrotate.d/fail2ban > /dev/null << 'EOF'
/var/log/fail2ban.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    postrotate
        /usr/bin/fail2ban-client flushlogs 1>/dev/null 2>&1 || true
    endscript
}
EOF
    echo "✓ Fail2ban 配置完成"
    
    # Supervisor 配置
    echo "配置 Supervisor..."
    sudo tee /etc/logrotate.d/supervisor > /dev/null << 'EOF'
# Supervisor 主日志
/var/log/supervisor/supervisord.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        if [ -f /var/run/supervisord.pid ]; then
            kill -USR2 $(cat /var/run/supervisord.pid) 2>/dev/null || true
        fi
    endscript
}

# Supervisor 管理的所有应用日志
/var/log/supervisor/*.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        if [ -f /var/run/supervisord.pid ]; then
            kill -USR2 $(cat /var/run/supervisord.pid) 2>/dev/null || true
        fi
    endscript
}
EOF
    echo "✓ Supervisor 配置完成"
    
    echo ""
    echo "============================================"
    echo "✓ 所有应用日志轮转配置完成！"
    echo "============================================"
    echo ""
    echo "配置详情："
    echo "  - 轮转周期：每天凌晨（通过 cron）"
    echo "  - 保留时间：3 天"
    echo "  - 压缩方式：gzip（延迟一次压缩）"
    echo ""
    echo "配置文件位置："
    echo "  - /etc/logrotate.d/openresty"
    echo "  - /etc/logrotate.d/postgresql-common"
    echo "  - /etc/logrotate.d/mysql-server"
    echo "  - /etc/logrotate.d/fail2ban"
    echo "  - /etc/logrotate.d/supervisor"
    echo ""
    
    press_enter
}

# 单独配置 Supervisor
setup_supervisor() {
    clear
    echo "=== 配置 Supervisor 日志轮转 ==="
    echo ""
    echo "Supervisor 日志配置选项："
    echo ""
    echo "1. 使用 logrotate（推荐）"
    echo "   - 优点：统一管理，基于时间轮转（3天）"
    echo "   - 配置简单，与其他服务一致"
    echo ""
    echo "2. 使用 Supervisor 内置轮转"
    echo "   - 优点：不依赖外部工具"
    echo "   - 缺点：基于文件大小，难以统一3天策略"
    echo ""
    echo -n "选择配置方式 (1/2，默认1): "
    read config_type
    config_type=${config_type:-1}
    
    if [ "$config_type" = "1" ]; then
        # 使用 logrotate
        echo ""
        echo "配置 logrotate 方式..."
        echo ""
        
        sudo tee /etc/logrotate.d/supervisor > /dev/null << 'EOF'
# Supervisor 主日志
/var/log/supervisor/supervisord.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        if [ -f /var/run/supervisord.pid ]; then
            kill -USR2 $(cat /var/run/supervisord.pid) 2>/dev/null || true
        fi
    endscript
}

# Supervisor 管理的所有应用日志
/var/log/supervisor/*.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        if [ -f /var/run/supervisord.pid ]; then
            kill -USR2 $(cat /var/run/supervisord.pid) 2>/dev/null || true
        fi
    endscript
}
EOF
        
        echo "✓ Logrotate 配置已创建：/etc/logrotate.d/supervisor"
        echo ""
        echo "注意：需要在 Supervisor 程序配置中禁用内置轮转："
        echo ""
        echo "编辑 /etc/supervisor/conf.d/*.conf，添加："
        echo "  stdout_logfile_maxbytes=0"
        echo "  stderr_logfile_maxbytes=0"
        echo ""
        echo -n "是否自动修改现有 Supervisor 配置？(y/n): "
        read auto_modify
        
        if [ "$auto_modify" = "y" ] || [ "$auto_modify" = "Y" ]; then
            disable_supervisor_rotation
        fi
        
    else
        # 使用 Supervisor 内置轮转
        echo ""
        echo "配置 Supervisor 内置轮转..."
        echo ""
        echo "需要手动编辑每个程序的配置文件"
        echo "位置：/etc/supervisor/conf.d/*.conf"
        echo ""
        echo "在每个 [program:xxx] 段落添加："
        echo ""
        echo "  # 基于时间的近似方案（假设每天10MB日志）"
        echo "  stdout_logfile_maxbytes=10MB"
        echo "  stdout_logfile_backups=3"
        echo "  stderr_logfile_maxbytes=10MB"
        echo "  stderr_logfile_backups=3"
        echo ""
    fi
    
    press_enter
}

# 禁用 Supervisor 内置日志轮转
disable_supervisor_rotation() {
    echo ""
    echo "正在修改 Supervisor 配置文件..."
    
    local conf_dir="/etc/supervisor/conf.d"
    local modified=0
    
    if [ -d "$conf_dir" ]; then
        for conf_file in "$conf_dir"/*.conf; do
            if [ -f "$conf_file" ]; then
                echo "处理: $(basename $conf_file)"
                
                # 备份原文件
                sudo cp "$conf_file" "${conf_file}.bak.$(date +%Y%m%d)"
                
                # 检查并添加配置
                if ! grep -q "stdout_logfile_maxbytes=0" "$conf_file"; then
                    sudo sed -i '/^\[program:/a stdout_logfile_maxbytes=0' "$conf_file"
                    modified=$((modified+1))
                fi
                
                if ! grep -q "stderr_logfile_maxbytes=0" "$conf_file"; then
                    sudo sed -i '/^\[program:/a stderr_logfile_maxbytes=0' "$conf_file"
                fi
            fi
        done
        
        echo ""
        echo "✓ 已修改 $modified 个配置文件"
        echo "✓ 原文件已备份为 .bak.$(date +%Y%m%d)"
        echo ""
        echo "需要重新加载 Supervisor 配置："
        echo "  sudo supervisorctl reread"
        echo "  sudo supervisorctl update"
        echo ""
        echo -n "是否立即重新加载？(y/n): "
        read reload_now
        
        if [ "$reload_now" = "y" ] || [ "$reload_now" = "Y" ]; then
            sudo supervisorctl reread
            sudo supervisorctl update
            echo "✓ 配置已重新加载"
        fi
    else
        echo "错误：找不到 Supervisor 配置目录"
    fi
}

# 查看 Supervisor 日志配置
view_supervisor_config() {
    clear
    echo "=== Supervisor 日志配置 ==="
    echo ""
    echo "Supervisor 主配置："
    echo "-----------------------------------"
    grep -E "(logfile|logfile_maxbytes|logfile_backups)" /etc/supervisor/supervisord.conf 2>/dev/null || echo "未找到主配置"
    echo ""
    echo "应用程序配置："
    echo "-----------------------------------"
    
    local conf_dir="/etc/supervisor/conf.d"
    if [ -d "$conf_dir" ]; then
        for conf_file in "$conf_dir"/*.conf; do
            if [ -f "$conf_file" ]; then
                echo ""
                echo "文件: $(basename $conf_file)"
                grep -E "(stdout_logfile|stderr_logfile|logfile_maxbytes|logfile_backups)" "$conf_file" 2>/dev/null || echo "  无日志配置"
            fi
        done
    fi
    
    echo ""
    press_enter
}

# 查看 Supervisor 日志大小
check_supervisor_logs() {
    clear
    echo "=== Supervisor 日志文件大小 ==="
    echo ""
    
    if [ -d "/var/log/supervisor" ]; then
        echo "当前日志文件："
        sudo du -sh /var/log/supervisor/*.log 2>/dev/null | sort -h
        echo ""
        
        echo "已轮转的日志（压缩文件）："
        sudo find /var/log/supervisor -name "*.gz" -exec ls -lh {} \; 2>/dev/null | awk '{print $9, $5}'
        echo ""
        
        echo "总计："
        sudo du -sh /var/log/supervisor/
    else
        echo "未找到 Supervisor 日志目录"
    fi
    
    echo ""
    press_enter
}

# 测试 Supervisor 日志轮转
test_supervisor_rotation() {
    clear
    echo "=== 测试 Supervisor 日志轮转 ==="
    echo ""
    
    if [ -f /etc/logrotate.d/supervisor ]; then
        echo "测试 logrotate 配置..."
        echo ""
        sudo logrotate -d /etc/logrotate.d/supervisor
    else
        echo "未找到 logrotate 配置文件"
        echo "请先运行配置向导"
    fi
    
    echo ""
    press_enter
}

# 强制执行 Supervisor 日志轮转
force_supervisor_rotation() {
    clear
    echo "=== 强制执行 Supervisor 日志轮转 ==="
    echo ""
    echo -n "确认立即轮转 Supervisor 日志？(y/n): "
    read confirm
    
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f /etc/logrotate.d/supervisor ]; then
            sudo logrotate -f /etc/logrotate.d/supervisor
            echo ""
            echo "✓ 日志轮转执行完成！"
        else
            echo "错误：未找到配置文件"
        fi
    else
        echo "已取消"
    fi
    
    echo ""
    press_enter
}

# 创建 Supervisor 应用模板
create_supervisor_template() {
    clear
    echo "=== 创建 Supervisor 应用配置模板 ==="
    echo ""
    echo -n "请输入程序名称: "
    read program_name
    
    if [ -z "$program_name" ]; then
        echo "错误：程序名称不能为空"
        press_enter
        return
    fi
    
    echo -n "请输入启动命令: "
    read program_command
    
    if [ -z "$program_command" ]; then
        echo "错误：启动命令不能为空"
        press_enter
        return
    fi
    
    local conf_file="/etc/supervisor/conf.d/${program_name}.conf"
    
    sudo tee "$conf_file" > /dev/null << EOF
[program:${program_name}]
command=${program_command}
autostart=true
autorestart=true
startsecs=3
startretries=3

# 日志配置（配合 logrotate 使用）
stdout_logfile=/var/log/supervisor/%(program_name)s.log
stderr_logfile=/var/log/supervisor/%(program_name)s_error.log
stdout_logfile_maxbytes=0
stderr_logfile_maxbytes=0
stdout_logfile_backups=0
stderr_logfile_backups=0

# 环境变量（根据需要修改）
;environment=KEY="value"

# 用户（根据需要修改）
;user=www-data

# 工作目录（根据需要修改）
;directory=/path/to/app
EOF
    
    echo ""
    echo "✓ 配置文件已创建：$conf_file"
    echo ""
    echo "下一步操作："
    echo "  1. 编辑配置文件调整参数"
    echo "  2. sudo supervisorctl reread"
    echo "  3. sudo supervisorctl update"
    echo "  4. sudo supervisorctl start ${program_name}"
    echo ""
    
    press_enter
}

# Supervisor 子菜单
supervisor_submenu() {
    while true; do
        clear
        echo "============================================"
        echo "        Supervisor 日志管理"
        echo "============================================"
        echo ""
        echo "  1) 配置 Supervisor 日志轮转（3天）"
        echo "  2) 禁用内置轮转（切换到 logrotate）"
        echo "  3) 查看日志配置"
        echo "  4) 查看日志文件大小"
        echo "  5) 测试日志轮转"
        echo "  6) 强制执行日志轮转"
        echo "  7) 创建应用配置模板"
        echo ""
        echo "  0) 返回上级菜单"
        echo "============================================"
        echo -n "请选择 [0-7]: "
        read choice
        
        case $choice in
            1) setup_supervisor ;;
            2) disable_supervisor_rotation ;;
            3) view_supervisor_config ;;
            4) check_supervisor_logs ;;
            5) test_supervisor_rotation ;;
            6) force_supervisor_rotation ;;
            7) create_supervisor_template ;;
            0) return ;;
            *) echo "无效选择"; press_enter ;;
        esac
    done
}

# 其他函数保持不变...
# (之前的 setup_openresty, setup_postgresql, setup_mysql, setup_fail2ban 等函数)

# 测试配置
test_config() {
    clear
    echo "=== 测试日志轮转配置 ==="
    echo ""
    echo "选择要测试的配置："
    echo "  1) 测试所有配置"
    echo "  2) 仅测试 OpenResty"
    echo "  3) 仅测试 PostgreSQL"
    echo "  4) 仅测试 MySQL"
    echo "  5) 仅测试 Fail2ban"
    echo "  6) 仅测试 Supervisor"
    echo "  0) 返回"
    echo ""
    echo -n "请选择: "
    read test_choice
    
    case $test_choice in
        1)
            echo ""
            echo "测试所有配置..."
            sudo logrotate -d /etc/logrotate.conf
            ;;
        2)
            echo ""
            echo "测试 OpenResty 配置..."
            sudo logrotate -d /etc/logrotate.d/openresty
            ;;
        3)
            echo ""
            echo "测试 PostgreSQL 配置..."
            sudo logrotate -d /etc/logrotate.d/postgresql-common
            ;;
        4)
            echo ""
            echo "测试 MySQL 配置..."
            sudo logrotate -d /etc/logrotate.d/mysql-server
            ;;
        5)
            echo ""
            echo "测试 Fail2ban 配置..."
            sudo logrotate -d /etc/logrotate.d/fail2ban
            ;;
        6)
            echo ""
            echo "测试 Supervisor 配置..."
            sudo logrotate -d /etc/logrotate.d/supervisor
            ;;
        0)
            return
            ;;
    esac
    
    echo ""
    press_enter
}

# 查看所有日志大小
check_all_log_sizes() {
    clear
    echo "=== 所有应用日志文件大小 ==="
    echo ""
    
    echo "OpenResty 日志："
    sudo du -sh /usr/local/openresty/nginx/logs/*.log 2>/dev/null || echo "  未找到日志文件"
    echo ""
    
    echo "PostgreSQL 日志："
    sudo du -sh /var/log/postgresql/*.log 2>/dev/null || echo "  未找到日志文件"
    echo ""
    
    echo "MySQL 日志："
    sudo du -sh /var/log/mysql/*.log 2>/dev/null || echo "  未找到日志文件"
    echo ""
    
    echo "Fail2ban 日志："
    sudo du -sh /var/log/fail2ban.log 2>/dev/null || echo "  未找到日志文件"
    echo ""
    
    echo "Supervisor 日志："
    sudo du -sh /var/log/supervisor/*.log 2>/dev/null || echo "  未找到日志文件"
    echo ""
    
    echo "所有压缩日志（最近20个）："
    sudo find /usr/local/openresty/nginx/logs /var/log/postgresql /var/log/mysql /var/log/supervisor /var/log -maxdepth 1 -name "*.gz" -exec ls -lh {} \; 2>/dev/null | tail -20
    echo ""
    
    press_enter
}

# 主菜单
logrotate_menu() {
    while true; do
        clear
        echo "============================================"
        echo "     日志轮转管理（3天保留策略）"
        echo "============================================"
        echo ""
        echo "  1) 一键配置所有应用（推荐）"
        echo ""
        echo "--- Supervisor 专项管理 ---"
        echo "  2) Supervisor 日志管理"
        echo ""
        echo "--- 管理和测试 ---"
        echo "  3) 测试配置"
        echo "  4) 强制执行轮转"
        echo "  5) 查看所有日志大小"
        echo "  6) 查看轮转状态"
        echo ""
        echo "  0) 返回主菜单"
        echo "============================================"
        echo -n "请选择 [0-6]: "
        read choice
        echo ""
        
        case $choice in
            1) setup_all_logs ;;
            2) supervisor_submenu ;;
            3) test_config ;;
            4) 
                clear
                echo "=== 强制执行所有日志轮转 ==="
                echo ""
                echo -n "确认执行？(y/n): "
                read confirm
                if [ "$confirm" = "y" ]; then
                    sudo logrotate -f /etc/logrotate.conf
                    echo ""
                    echo "✓ 完成"
                fi
                press_enter
                ;;
            5) check_all_log_sizes ;;
            6)
                clear
                echo "=== Logrotate 状态 ==="
                echo ""
                if [ -f /var/lib/logrotate/status ]; then
                    sudo tail -50 /var/lib/logrotate/status
                else
                    echo "状态文件不存在"
                fi
                echo ""
                press_enter
                ;;
            0) return ;;
            *) echo "无效选择"; press_enter ;;
        esac
    done
}

# 启动菜单
logrotate_menu
