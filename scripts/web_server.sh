#!/bin/bash
set -euo pipefail


# ============================================
# Web 服务器管理脚本
# 支持 OpenResty、Nginx、Caddy、PHP 8.5、NVM、Supervisor
# ============================================


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


# ============================================
# 安装 OpenResty
# ============================================


install_openresty() {
    clear
    echo "=========================================="
    echo "   安装 OpenResty"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    if command -v openresty &> /dev/null; then
        local version=$(openresty -v 2>&1 | grep -oP 'openresty/\K[0-9.]+')
        print_warning "OpenResty 已安装 (版本: $version)"
        echo ""
        read -p "是否重新安装？[y/N]: " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi
    
    print_info "开始安装 OpenResty..."
    echo ""
    
    # 安装依赖
    print_info "[1/5] 安装依赖包..."
    apt update
    apt install -y gnupg2 ca-certificates lsb-release debian-archive-keyring
    
    # 添加 GPG 密钥
    print_info "[2/5] 添加 OpenResty GPG 密钥..."
    curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg
    
    # 添加仓库
    print_info "[3/5] 添加 OpenResty 仓库..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian $(lsb_release -sc) openresty" \
        > /etc/apt/sources.list.d/openresty.list
    
    # 更新并安装
    print_info "[4/5] 安装 OpenResty..."
    apt update
    apt install -y openresty
    
    # 配置 OpenResty
    print_info "[5/5] 配置 OpenResty..."
    
    local or_base="/usr/local/openresty/nginx"
    local conf_dir="${or_base}/conf"
    local sites_avail="${conf_dir}/sites-available"
    local sites_enabled="${conf_dir}/sites-enabled"
    local ssl_dir="${conf_dir}/ssl"
    
    # 创建目录结构
    mkdir -p "$sites_avail" "$sites_enabled" "$ssl_dir" "${or_base}/logs"
    chown -R www-data:www-data "${or_base}/logs" 2>/dev/null || true
    
    # 创建临时目录
    for temp_dir in client_body proxy fastcgi uwsgi scgi; do
        mkdir -p "${or_base}/${temp_dir}_temp"
        chown -R www-data:www-data "${or_base}/${temp_dir}_temp"
    done
    
    # 备份原配置
    if [ -f "${conf_dir}/nginx.conf" ]; then
        cp "${conf_dir}/nginx.conf" "${conf_dir}/nginx.conf.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # 创建主配置
    cat > "${conf_dir}/nginx.conf" << 'NGXCONF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pcre_jit on;
pid logs/nginx.pid;
error_log logs/error.log warn;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include mime.types;
    default_type application/octet-stream;
    
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log logs/access.log main;
    error_log logs/error.log;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    client_max_body_size 512M;
    client_body_buffer_size 128k;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript 
               application/json application/javascript application/xml+rss;

    include sites-enabled/*.conf;
}
NGXCONF
    
    # 创建默认站点
    mkdir -p /var/www/html
    cat > /var/www/html/index.html << 'WELCOME'
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>OpenResty 欢迎页</title>
    <style>
        body { font-family: Arial; margin: 50px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #0066cc; }
        .info { background: #f0f0f0; padding: 20px; border-radius: 5px; margin: 20px 0; }
        .info p { margin: 10px 0; }
        code { background: #e8e8e8; padding: 2px 6px; border-radius: 3px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🎉 OpenResty 安装成功！</h1>
        <div class="info">
            <p><strong>配置目录：</strong><code>/usr/local/openresty/nginx/conf</code></p>
            <p><strong>站点目录：</strong><code>/var/www</code></p>
            <p><strong>日志目录：</strong><code>/usr/local/openresty/nginx/logs</code></p>
            <p><strong>虚拟主机：</strong><code>/usr/local/openresty/nginx/conf/sites-available</code></p>
        </div>
        <h2>管理命令</h2>
        <ul>
            <li>启动: <code>systemctl start openresty</code></li>
            <li>停止: <code>systemctl stop openresty</code></li>
            <li>重启: <code>systemctl restart openresty</code></li>
            <li>重载: <code>systemctl reload openresty</code></li>
            <li>状态: <code>systemctl status openresty</code></li>
        </ul>
    </div>
</body>
</html>
WELCOME
    
    chown -R www-data:www-data /var/www/html
    
    # 创建默认虚拟主机
    cat > "${sites_avail}/default.conf" << 'DEFCONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html index.htm;

    location / {
        try_files $uri $uri/ =404;
    }
}
DEFCONF
    
    ln -sf "${sites_avail}/default.conf" "${sites_enabled}/"
    
    # 测试配置
    if openresty -t; then
        print_success "配置测试通过"
    else
        print_error "配置测试失败"
        press_enter
        return
    fi
    
    # 启动服务
    systemctl enable openresty
    systemctl restart openresty
    
    echo ""
    print_success "OpenResty 安装完成！"
    echo ""
    print_info "安装信息："
    echo "  版本: $(openresty -v 2>&1 | grep -oP 'openresty/\K[0-9.]+')"
    echo "  配置: ${conf_dir}/nginx.conf"
    echo "  站点: ${sites_avail}"
    echo "  日志: ${or_base}/logs"
    echo ""
    print_info "访问 http://localhost 查看默认页面"
    
    press_enter
}


# ============================================
# 安装 Nginx
# ============================================


install_nginx() {
    clear
    echo "=========================================="
    echo "   安装 Nginx"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    if command -v nginx &> /dev/null; then
        local version=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')
        print_warning "Nginx 已安装 (版本: $version)"
        echo ""
        read -p "是否重新安装？[y/N]: " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi
    
    print_info "开始安装 Nginx..."
    echo ""
    
    # 安装
    print_info "[1/3] 安装 Nginx..."
    apt update
    apt install -y nginx
    
    # 配置
    print_info "[2/3] 配置 Nginx..."
    
    local conf_dir="/etc/nginx"
    local sites_avail="${conf_dir}/sites-available"
    local sites_enabled="${conf_dir}/sites-enabled"
    local ssl_dir="${conf_dir}/ssl"
    
    mkdir -p "$sites_avail" "$sites_enabled" "$ssl_dir"
    
    # 优化主配置
    local nginx_conf="${conf_dir}/nginx.conf"
    if [ -f "$nginx_conf" ]; then
        cp "$nginx_conf" "${nginx_conf}.bak.$(date +%Y%m%d_%H%M%S)"
        
        # 优化配置
        sed -i 's/worker_processes.*/worker_processes auto;/' "$nginx_conf"
        sed -i 's/# server_tokens off;/server_tokens off;/' "$nginx_conf"
        sed -i 's/# gzip/gzip/' "$nginx_conf"
        
        # 添加 client_max_body_size
        if ! grep -q "client_max_body_size" "$nginx_conf"; then
            sed -i '/http {/a \    client_max_body_size 512M;' "$nginx_conf"
        fi
    fi
    
    # 启动服务
    print_info "[3/3] 启动 Nginx..."
    systemctl enable nginx
    systemctl restart nginx
    
    echo ""
    print_success "Nginx 安装完成！"
    echo ""
    print_info "安装信息："
    echo "  版本: $(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')"
    echo "  配置: ${conf_dir}/nginx.conf"
    echo "  站点: ${sites_avail}"
    echo "  日志: /var/log/nginx"
    echo ""
    print_info "访问 http://localhost 查看默认页面"
    
    press_enter
}


# ============================================
# 安装 Caddy
# ============================================


install_caddy() {
    clear
    echo "=========================================="
    echo "   安装 Caddy"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    if command -v caddy &> /dev/null; then
        local version=$(caddy version | head -1 | awk '{print $1}')
        print_warning "Caddy 已安装 (版本: $version)"
        echo ""
        read -p "是否重新安装？[y/N]: " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi
    
    print_info "开始安装 Caddy..."
    echo ""
    
    # 安装依赖
    print_info "[1/4] 安装依赖..."
    apt update
    apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
    
    # 添加 GPG 密钥
    print_info "[2/4] 添加 Caddy GPG 密钥..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    
    # 添加仓库
    print_info "[3/4] 添加 Caddy 仓库..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    
    # 安装 Caddy
    print_info "[4/4] 安装 Caddy..."
    apt update
    apt install -y caddy
    
    # 配置
    mkdir -p /etc/caddy/sites
    
    # 创建简单配置
    cat > /etc/caddy/Caddyfile << 'CADDYCONF'
# Caddy 全局配置
{
    admin localhost:2019
    auto_https off
}

# 默认站点
:80 {
    root * /var/www/html
    file_server
    
    # PHP 支持（如果需要）
    # php_fastcgi unix//run/php/php8.5-fpm.sock
    
    log {
        output file /var/log/caddy/access.log
    }
}

# 导入站点配置
import /etc/caddy/sites/*.caddy
CADDYCONF
    
    # 创建默认页面
    mkdir -p /var/www/html
    cat > /var/www/html/index.html << 'WELCOME'
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Caddy 欢迎页</title>
    <style>
        body { font-family: Arial; margin: 50px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 10px; box-shadow: 0 10px 40px rgba(0,0,0,0.2); }
        h1 { color: #667eea; }
        .info { background: #f8f9fa; padding: 20px; border-radius: 5px; margin: 20px 0; border-left: 4px solid #667eea; }
        code { background: #e9ecef; padding: 2px 8px; border-radius: 3px; font-family: monospace; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🎉 Caddy 安装成功！</h1>
        <div class="info">
            <p><strong>配置文件：</strong><code>/etc/caddy/Caddyfile</code></p>
            <p><strong>站点目录：</strong><code>/var/www/html</code></p>
            <p><strong>日志目录：</strong><code>/var/log/caddy</code></p>
            <p><strong>虚拟主机：</strong><code>/etc/caddy/sites</code></p>
        </div>
        <h2>特性</h2>
        <ul>
            <li>自动 HTTPS（Let's Encrypt）</li>
            <li>HTTP/2 和 HTTP/3 支持</li>
            <li>简单的配置语法</li>
            <li>内置静态文件服务器</li>
        </ul>
        <h2>管理命令</h2>
        <ul>
            <li>启动: <code>systemctl start caddy</code></li>
            <li>停止: <code>systemctl stop caddy</code></li>
            <li>重启: <code>systemctl restart caddy</code></li>
            <li>重载: <code>systemctl reload caddy</code></li>
            <li>验证配置: <code>caddy validate --config /etc/caddy/Caddyfile</code></li>
        </ul>
    </div>
</body>
</html>
WELCOME
    
    chown -R caddy:caddy /var/www/html
    mkdir -p /var/log/caddy
    chown -R caddy:caddy /var/log/caddy
    
    # 启动服务
    systemctl enable caddy
    systemctl restart caddy
    
    echo ""
    print_success "Caddy 安装完成！"
    echo ""
    print_info "安装信息："
    echo "  版本: $(caddy version | head -1)"
    echo "  配置: /etc/caddy/Caddyfile"
    echo "  站点: /etc/caddy/sites"
    echo "  日志: /var/log/caddy"
    echo ""
    print_info "访问 http://localhost 查看默认页面"
    
    press_enter
}


# ============================================
# 安装 PHP 8.5
# ============================================


install_php85() {
    clear
    echo "=========================================="
    echo "   安装 PHP 8.5"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    # 检查是否已安装
    if command -v php8.5 &> /dev/null; then
        local version=$(php8.5 -v | head -1 | grep -oP 'PHP \K[0-9.]+')
        print_warning "PHP 8.5 已安装 (版本: $version)"
        echo ""
        read -p "是否重新安装？[y/N]: " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi
    
    print_info "开始安装 PHP 8.5..."
    echo ""
    
    print_info "📋 PHP 8.5 特性："
    echo "  - OPcache 现已内置到核心，无需单独安装"
    echo "  - 新增内置扩展：uri 和 lexbor"
    echo "  - 新增 max_memory_limit INI 指令"
    echo ""
    
    # 添加 Sury PHP 仓库
    print_info "[1/4] 添加 Sury PHP 仓库..."
    apt update
    apt install -y lsb-release ca-certificates apt-transport-https software-properties-common gnupg2
    
    # 添加 GPG 密钥
    curl -fsSL -o /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    
    # 添加仓库
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
    
    apt update
    
    # 安装 PHP 8.5 及常用扩展
    print_info "[2/4] 安装 PHP 8.5 和常用扩展..."
    
    # 注意：
    # - 不再需要 php8.5-opcache，因为 OPcache 已内置
    # - php8.5-mysql 包含 mysqli 和 mysqlnd
    apt install -y \
        php8.5-fpm \
        php8.5-cli \
        php8.5-common \
        php8.5-mysql \
        php8.5-pgsql \
        php8.5-sqlite3 \
        php8.5-curl \
        php8.5-gd \
        php8.5-mbstring \
        php8.5-xml \
        php8.5-zip \
        php8.5-intl \
        php8.5-bcmath \
        php8.5-redis \
        php8.5-imagick \
        php8.5-soap \
        php8.5-xmlrpc
    
    # 优化 PHP 配置
    print_info "[3/4] 优化 PHP 配置..."
    
    local php_ini_fpm="/etc/php/8.5/fpm/php.ini"
    local php_ini_cli="/etc/php/8.5/cli/php.ini"
    
    # 备份原配置
    if [ -f "$php_ini_fpm" ]; then
        cp "$php_ini_fpm" "${php_ini_fpm}.bak.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # 优化 FPM 配置
    if [ -f "$php_ini_fpm" ]; then
        # 基础设置
        sed -i 's/^upload_max_filesize.*/upload_max_filesize = 256M/' "$php_ini_fpm"
        sed -i 's/^post_max_size.*/post_max_size = 256M/' "$php_ini_fpm"
        sed -i 's/^memory_limit.*/memory_limit = 512M/' "$php_ini_fpm"
        sed -i 's/^max_execution_time.*/max_execution_time = 300/' "$php_ini_fpm"
        sed -i 's/^max_input_time.*/max_input_time = 300/' "$php_ini_fpm"
        sed -i 's/^;date.timezone.*/date.timezone = Asia\/Shanghai/' "$php_ini_fpm"
        
        # OPcache 优化（注意：PHP 8.5 中 OPcache 已内置，但仍可配置）
        # OPcache 默认已启用，这里只是调整参数
        sed -i 's/^;opcache.enable=.*/opcache.enable=1/' "$php_ini_fpm"
        sed -i 's/^;opcache.memory_consumption=.*/opcache.memory_consumption=256/' "$php_ini_fpm"
        sed -i 's/^;opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=16/' "$php_ini_fpm"
        sed -i 's/^;opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' "$php_ini_fpm"
        sed -i 's/^;opcache.revalidate_freq=.*/opcache.revalidate_freq=60/' "$php_ini_fpm"
        sed -i 's/^;opcache.enable_cli=.*/opcache.enable_cli=1/' "$php_ini_fpm"
        
        # PHP 8.5 新特性：max_memory_limit（可选）
        # 限制 memory_limit 可以设置的最大值
        if ! grep -q "max_memory_limit" "$php_ini_fpm"; then
            echo "" >> "$php_ini_fpm"
            echo "; PHP 8.5 新特性：限制 memory_limit 的最大值" >> "$php_ini_fpm"
            echo ";max_memory_limit = 1G" >> "$php_ini_fpm"
        fi
    fi
    
    # 优化 FPM 池配置
    local pool_conf="/etc/php/8.5/fpm/pool.d/www.conf"
    if [ -f "$pool_conf" ]; then
        cp "$pool_conf" "${pool_conf}.bak.$(date +%Y%m%d_%H%M%S)"
        
        # 动态进程管理
        sed -i 's/^pm = .*/pm = dynamic/' "$pool_conf"
        sed -i 's/^pm.max_children = .*/pm.max_children = 50/' "$pool_conf"
        sed -i 's/^pm.start_servers = .*/pm.start_servers = 5/' "$pool_conf"
        sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 5/' "$pool_conf"
        sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 10/' "$pool_conf"
        
        # 启用慢日志
        if ! grep -q "^slowlog" "$pool_conf"; then
            echo "" >> "$pool_conf"
            echo "; 慢查询日志" >> "$pool_conf"
            echo "slowlog = /var/log/php8.5-fpm-slow.log" >> "$pool_conf"
            echo "request_slowlog_timeout = 10s" >> "$pool_conf"
        fi
    fi
    
    # 启动服务
    print_info "[4/4] 启动 PHP-FPM..."
    systemctl enable php8.5-fpm
    systemctl restart php8.5-fpm
    
    # 验证 OPcache
    local opcache_status=$(php8.5 -m | grep -i opcache || echo "")
    
    echo ""
    print_success "PHP 8.5 安装完成！"
    echo ""
    echo "=========================================="
    print_info "安装信息"
    echo "=========================================="
    echo ""
    echo "版本信息："
    php8.5 -v | head -1
    echo ""
    
    echo "配置文件："
    echo "  FPM: ${php_ini_fpm}"
    echo "  CLI: ${php_ini_cli}"
    echo "  Pool: ${pool_conf}"
    echo ""
    
    echo "运行环境："
    echo "  FPM Socket: /run/php/php8.5-fpm.sock"
    echo "  慢日志: /var/log/php8.5-fpm-slow.log"
    echo ""
    
    echo "OPcache 状态："
    if [ -n "$opcache_status" ]; then
        print_success "  OPcache: 已内置并启用 ✓"
        echo "  （PHP 8.5 中 OPcache 已是核心组件）"
    else
        print_warning "  OPcache: 检测失败"
    fi
    echo ""
    
    echo "=========================================="
    print_info "已安装的扩展 ($(php8.5 -m | wc -l) 个)"
    echo "=========================================="
    echo ""
    
    # 分组显示扩展
    echo "核心扩展（内置）："
    php8.5 -m | grep -iE "(Core|date|hash|json|Reflection|SPL|standard|Zend OPcache|uri|lexbor)" | sed 's/^/  /'
    echo ""
    
    echo "数据库扩展："
    php8.5 -m | grep -iE "(mysqli|mysqlnd|pdo|pgsql|sqlite)" | sed 's/^/  /'
    echo ""
    
    echo "常用扩展："
    php8.5 -m | grep -viE "(Core|date|hash|json|Reflection|SPL|standard|Zend OPcache|uri|lexbor|mysqli|mysqlnd|pdo|pgsql|sqlite)" | sed 's/^/  /'
    echo ""
    
    echo "=========================================="
    print_info "服务状态"
    echo "=========================================="
    systemctl status php8.5-fpm --no-pager -l | head -10
    echo ""
    
    echo "=========================================="
    print_info "PHP 8.5 新特性"
    echo "=========================================="
    echo ""
    echo "✓ OPcache 现为内置组件（无需单独安装）"
    echo "✓ 新增 uri 和 lexbor 核心扩展"
    echo "✓ 新增 max_memory_limit INI 指令"
    echo "✓ Property hooks 特性"
    echo "✓ Asymmetric visibility 特性"
    echo "✓ 性能和安全性改进"
    echo ""
    
    print_warning "重要提示："
    echo "  1. OPcache 已自动启用，可通过 opcache.enable 配置"
    echo "  2. mysqli 扩展已包含在 php8.5-mysql 包中"
    echo "  3. 建议使用 PDO 或 MySQLi 进行数据库操作"
    echo "  4. 旧的 mysql 扩展已在 PHP 7.0 中移除"
    echo ""
    
    press_enter
}


# ============================================
# 安装 NVM (Node Version Manager)
# ============================================


install_nvm() {
    clear
    echo "=========================================="
    echo "   安装 NVM (Node.js 版本管理器)"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    print_warning "⚠️  安全建议："
    echo "  - NVM 应该以普通用户身份运行，而不是 root"
    echo "  - 建议为 Node.js 应用创建专用用户"
    echo "  - 这样可以隔离权限，提高安全性"
    echo ""
    
    # 选择安装方式
    echo "安装选项："
    echo "1. 为现有用户安装 NVM"
    echo "2. 创建新用户并安装 NVM（推荐）"
    echo "0. 取消"
    echo ""
    read -p "请选择 [0-2]: " choice
    
    case $choice in
        1)
            install_nvm_existing_user
            ;;
        2)
            install_nvm_new_user
            ;;
        0)
            print_info "已取消"
            press_enter
            return
            ;;
        *)
            print_error "无效选择"
            press_enter
            return
            ;;
    esac
}


# 为现有用户安装 NVM
install_nvm_existing_user() {
    echo ""
    print_info "为现有用户安装 NVM"
    echo ""
    
    # 列出现有用户（非系统用户）
    print_info "可用的用户："
    local count=0
    local -a users
    while IFS=: read -r username _ uid _ _ home shell; do
        # 只显示普通用户（UID >= 1000 且有有效 shell）
        if [ "$uid" -ge 1000 ] && [[ "$shell" =~ (bash|zsh|sh)$ ]]; then
            count=$((count+1))
            users+=("$username:$home")
            echo "  $count. $username (Home: $home)"
        fi
    done < /etc/passwd
    
    if [ "$count" -eq 0 ]; then
        print_error "未找到可用的普通用户"
        print_info "请先创建用户或选择创建新用户安装"
        press_enter
        return
    fi
    
    echo ""
    read -p "输入用户名: " target_user
    
    # 验证用户存在
    if ! id "$target_user" &>/dev/null; then
        print_error "用户不存在: $target_user"
        press_enter
        return
    fi
    
    # 获取用户 home 目录
    local user_home=$(eval echo ~$target_user)
    
    # 检查是否已安装
    if [ -d "$user_home/.nvm" ]; then
        print_warning "NVM 已经为用户 $target_user 安装"
        echo ""
        read -p "是否重新安装？[y/N]: " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi
    
    echo ""
    print_info "开始为用户 $target_user 安装 NVM..."
    
    # 下载并安装 NVM
    print_info "[1/3] 下载 NVM..."
    sudo -u "$target_user" bash << 'NVMINSTALL'
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
NVMINSTALL
    
    # 配置 shell
    print_info "[2/3] 配置 shell 环境..."
    local bashrc="$user_home/.bashrc"
    local profile="$user_home/.profile"
    
    # 确保配置已加载
    if [ -f "$bashrc" ]; then
        if ! grep -q 'NVM_DIR' "$bashrc"; then
            sudo -u "$target_user" bash << NVMCONFIG
cat >> "$bashrc" << 'EOF'

# NVM 配置
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && \. "\$NVM_DIR/bash_completion"
EOF
NVMCONFIG
        fi
    fi
    
    # 安装 Node.js LTS
    print_info "[3/3] 安装 Node.js LTS..."
    sudo -u "$target_user" bash << 'NODEINSTALL'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install --lts
nvm use --lts
nvm alias default lts/*
NODEINSTALL
    
    echo ""
    print_success "NVM 安装完成！"
    echo ""
    print_info "安装信息："
    echo "  用户: $target_user"
    echo "  NVM 目录: $user_home/.nvm"
    echo "  配置文件: $bashrc"
    echo ""
    print_info "使用方法："
    echo "  1. 切换到用户: su - $target_user"
    echo "  2. 查看版本: nvm --version"
    echo "  3. 列出已安装: nvm list"
    echo "  4. 安装版本: nvm install 18"
    echo "  5. 使用版本: nvm use 18"
    echo "  6. 查看 Node: node --version"
    echo ""
    print_warning "重要提示："
    echo "  - 需要重新登录或执行: source ~/.bashrc"
    echo "  - NVM 仅对用户 $target_user 可用"
    echo "  - Node.js 全局包将安装到用户目录，无需 sudo"
    
    press_enter
}


# 创建新用户并安装 NVM
install_nvm_new_user() {
    echo ""
    print_info "创建新用户并安装 NVM"
    echo ""
    
    # 输入新用户名
    read -p "新用户名 (默认: nodejs): " new_user
    new_user=${new_user:-nodejs}
    
    # 检查用户是否已存在
    if id "$new_user" &>/dev/null; then
        print_error "用户已存在: $new_user"
        echo ""
        read -p "是否为此用户安装 NVM？[y/N]: " use_existing
        if [[ ! "$use_existing" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    else
        # 创建用户
        print_info "创建用户: $new_user"
        
        # 询问是否创建密码
        echo ""
        read -p "是否为新用户设置密码？[Y/n]: " set_password
        
        if [[ ! "$set_password" =~ ^[Nn]$ ]]; then
            adduser --gecos "" "$new_user"
        else
            adduser --disabled-password --gecos "" "$new_user"
            print_warning "用户已创建但未设置密码"
            print_info "稍后可用 passwd $new_user 设置密码"
        fi
        
        print_success "用户创建完成"
    fi
    
    local user_home=$(eval echo ~$new_user)
    
    echo ""
    print_info "开始为用户 $new_user 安装 NVM..."
    
    # 下载并安装 NVM
    print_info "[1/3] 下载 NVM..."
    sudo -u "$new_user" bash << 'NVMINSTALL'
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
NVMINSTALL
    
    # 配置 shell
    print_info "[2/3] 配置 shell 环境..."
    local bashrc="$user_home/.bashrc"
    
    if [ -f "$bashrc" ]; then
        if ! grep -q 'NVM_DIR' "$bashrc"; then
            sudo -u "$new_user" bash << NVMCONFIG
cat >> "$bashrc" << 'EOF'

# NVM 配置
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && \. "\$NVM_DIR/bash_completion"
EOF
NVMCONFIG
        fi
    fi
    
    # 安装 Node.js LTS
    print_info "[3/3] 安装 Node.js LTS..."
    sudo -u "$new_user" bash << 'NODEINSTALL'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install --lts
nvm use --lts
nvm alias default lts/*
NODEINSTALL
    
    # 创建示例应用目录
    local app_dir="$user_home/apps"
    sudo -u "$new_user" mkdir -p "$app_dir"
    
    # 创建 README
    sudo -u "$new_user" bash << README
cat > "$app_dir/README.md" << 'EOF'
# Node.js 应用目录

这是 $new_user 用户的应用目录。

## 快速开始

\`\`\`bash
# 创建新项目
mkdir my-app && cd my-app
npm init -y

# 安装依赖
npm install express

# 创建简单服务器
cat > index.js << 'JS'
const express = require('express');
const app = express();
const port = 3000;

app.get('/', (req, res) => {
  res.send('Hello World!');
});

app.listen(port, () => {
  console.log(\\\`Server running at http://localhost:\\\${port}\\\`);
});
JS

# 运行
node index.js
\`\`\`

## 常用命令

- \`nvm list\` - 列出已安装的 Node.js 版本
- \`nvm install 18\` - 安装 Node.js 18
- \`nvm use 18\` - 使用 Node.js 18
- \`npm install -g pm2\` - 全局安装 PM2 进程管理器
EOF
README
    
    echo ""
    print_success "NVM 安装完成！"
    echo ""
    print_info "安装信息："
    echo "  用户: $new_user"
    echo "  Home: $user_home"
    echo "  NVM 目录: $user_home/.nvm"
    echo "  应用目录: $app_dir"
    echo ""
    print_info "Node.js 信息："
    sudo -u "$new_user" bash << 'NODEINFO'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
echo "  Node.js: $(node --version)"
echo "  npm: $(npm --version)"
echo "  已安装版本:"
nvm list | sed 's/^/    /'
NODEINFO
    
    echo ""
    print_info "使用方法："
    echo "  1. 切换到用户: su - $new_user"
    echo "  2. 查看版本: nvm --version"
    echo "  3. 安装其他版本: nvm install 16"
    echo "  4. 切换版本: nvm use 16"
    echo "  5. 运行应用: cd ~/apps && node app.js"
    echo ""
    print_warning "安全提示："
    echo "  - 此用户专门用于运行 Node.js 应用"
    echo "  - 不要以 root 运行 Node.js 应用"
    echo "  - 全局 npm 包将安装到用户目录，无需 sudo"
    echo "  - 建议使用 PM2 管理生产环境应用"
    
    press_enter
}


# ============================================
# 安装 Supervisor
# ============================================


install_supervisor() {
    clear
    echo "=========================================="
    echo "   安装 Supervisor"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    if command -v supervisorctl &> /dev/null; then
        local version=$(supervisorctl version 2>/dev/null)
        print_warning "Supervisor 已安装 (版本: $version)"
        echo ""
        read -p "是否重新安装？[y/N]: " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi
    
    print_info "开始安装 Supervisor..."
    echo ""
    
    print_info "[1/3] 更新软件包列表..."
    apt update
    
    print_info "[2/3] 安装 Supervisor..."
    apt install -y supervisor
    
    if [ $? -eq 0 ]; then
        print_success "Supervisor 安装成功"
        echo ""
        supervisorctl version
        
        print_info "[3/3] 配置 Supervisor..."
        
        # 启动服务
        systemctl start supervisor
        systemctl enable supervisor
        
        print_success "Supervisor 服务已启动并设置为开机自启"
        
        # 创建配置目录
        mkdir -p /etc/supervisor/conf.d
        
        # 创建日志目录
        mkdir -p /var/log/supervisor
        
        # 优化 supervisord 主配置
        local main_conf="/etc/supervisor/supervisord.conf"
        if [ -f "$main_conf" ]; then
            # 备份原配置
            cp "$main_conf" "${main_conf}.bak.$(date +%Y%m%d_%H%M%S)"
            
            # 确保包含 conf.d 目录
            if ! grep -q "files = /etc/supervisor/conf.d/\*.conf" "$main_conf"; then
                echo "" >> "$main_conf"
                echo "[include]" >> "$main_conf"
                echo "files = /etc/supervisor/conf.d/*.conf" >> "$main_conf"
            fi
        fi
        
        print_success "配置目录已创建: /etc/supervisor/conf.d"
        print_success "日志目录已创建: /var/log/supervisor"
        
        echo ""
        print_info "安装完成信息："
        echo "  配置文件: /etc/supervisor/supervisord.conf"
        echo "  程序配置目录: /etc/supervisor/conf.d/"
        echo "  日志目录: /var/log/supervisor/"
        echo "  Socket: /var/run/supervisor.sock"
        echo ""
        print_info "常用命令："
        echo "  查看状态: supervisorctl status"
        echo "  启动程序: supervisorctl start <name>"
        echo "  停止程序: supervisorctl stop <name>"
        echo "  重启程序: supervisorctl restart <name>"
        echo "  重载配置: supervisorctl reread && supervisorctl update"
        echo ""
        print_info "管理程序："
        echo "  可以使用主菜单中的 '容器和进程管理' 进行详细管理"
    else
        print_error "Supervisor 安装失败"
    fi
    
    press_enter
}


# ============================================
# 卸载服务
# ============================================


uninstall_service() {
    clear
    echo "=========================================="
    echo "   卸载 Web 服务"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    echo "可卸载的服务："
    echo "1. OpenResty"
    echo "2. Nginx"
    echo "3. Caddy"
    echo "4. PHP 8.5"
    echo "5. Supervisor"
    echo "0. 取消"
    echo ""
    read -p "请选择 [0-5]: " choice
    
    case $choice in
        1)
            uninstall_openresty
            ;;
        2)
            uninstall_nginx
            ;;
        3)
            uninstall_caddy
            ;;
        4)
            uninstall_php85
            ;;
        5)
            uninstall_supervisor
            ;;
        0)
            print_info "已取消"
            press_enter
            ;;
        *)
            print_error "无效选择"
            press_enter
            ;;
    esac
}


uninstall_openresty() {
    echo ""
    print_warning "⚠️  警告: 即将卸载 OpenResty 及其所有配置"
    echo ""
    read -p "确认卸载？输入 'yes' 确认: " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "正在卸载 OpenResty..."
    
    # 停止服务
    systemctl stop openresty 2>/dev/null || true
    systemctl disable openresty 2>/dev/null || true
    
    # 卸载软件包
    apt remove --purge -y openresty
    apt autoremove -y
    
    # 询问是否删除配置
    echo ""
    read -p "是否删除配置文件和日志？[y/N]: " delete_config
    if [[ "$delete_config" =~ ^[Yy]$ ]]; then
        rm -rf /usr/local/openresty
        rm -f /etc/apt/sources.list.d/openresty.list
        rm -f /usr/share/keyrings/openresty.gpg
        print_success "配置已删除"
    fi
    
    print_success "OpenResty 已卸载"
    press_enter
}


uninstall_nginx() {
    echo ""
    print_warning "⚠️  警告: 即将卸载 Nginx 及其所有配置"
    echo ""
    read -p "确认卸载？输入 'yes' 确认: " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "正在卸载 Nginx..."
    
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    
    apt remove --purge -y nginx nginx-common nginx-full
    apt autoremove -y
    
    echo ""
    read -p "是否删除配置文件和日志？[y/N]: " delete_config
    if [[ "$delete_config" =~ ^[Yy]$ ]]; then
        rm -rf /etc/nginx
        rm -rf /var/log/nginx
        print_success "配置已删除"
    fi
    
    print_success "Nginx 已卸载"
    press_enter
}


uninstall_caddy() {
    echo ""
    print_warning "⚠️  警告: 即将卸载 Caddy 及其所有配置"
    echo ""
    read -p "确认卸载？输入 'yes' 确认: " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "正在卸载 Caddy..."
    
    systemctl stop caddy 2>/dev/null || true
    systemctl disable caddy 2>/dev/null || true
    
    apt remove --purge -y caddy
    apt autoremove -y
    
    echo ""
    read -p "是否删除配置文件和日志？[y/N]: " delete_config
    if [[ "$delete_config" =~ ^[Yy]$ ]]; then
        rm -rf /etc/caddy
        rm -rf /var/log/caddy
        rm -f /etc/apt/sources.list.d/caddy-stable.list
        rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        print_success "配置已删除"
    fi
    
    print_success "Caddy 已卸载"
    press_enter
}


uninstall_php85() {
    echo ""
    print_warning "⚠️  警告: 即将卸载 PHP 8.5 及其所有扩展"
    echo ""
    read -p "确认卸载？输入 'yes' 确认: " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "正在卸载 PHP 8.5..."
    
    systemctl stop php8.5-fpm 2>/dev/null || true
    systemctl disable php8.5-fpm 2>/dev/null || true
    
    apt remove --purge -y 'php8.5*'
    apt autoremove -y
    
    echo ""
    read -p "是否删除配置文件？[y/N]: " delete_config
    if [[ "$delete_config" =~ ^[Yy]$ ]]; then
        rm -rf /etc/php/8.5
        print_success "配置已删除"
    fi
    
    print_success "PHP 8.5 已卸载"
    press_enter
}


uninstall_supervisor() {
    echo ""
    print_warning "⚠️  警告: 即将卸载 Supervisor 及其所有配置"
    echo ""
    read -p "确认卸载？输入 'yes' 确认: " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "正在卸载 Supervisor..."
    
    # 停止服务
    systemctl stop supervisor 2>/dev/null || true
    systemctl disable supervisor 2>/dev/null || true
    
    # 卸载软件包
    apt remove --purge -y supervisor
    apt autoremove -y
    
    # 询问是否删除配置和日志
    echo ""
    read -p "是否删除配置文件和日志？[y/N]: " delete_data
    if [[ "$delete_data" =~ ^[Yy]$ ]]; then
        rm -rf /etc/supervisor
        rm -rf /var/log/supervisor
        print_success "配置和日志已删除"
    fi
    
    print_success "Supervisor 已卸载"
    press_enter
}


# ============================================
# 查看服务状态
# ============================================


view_services_status() {
    clear
    echo "=========================================="
    echo "   Web 服务状态"
    echo "=========================================="
    echo ""
    
    # OpenResty
    if command -v openresty &> /dev/null; then
        echo -e "${CYAN}OpenResty${NC}"
        echo "  版本: $(openresty -v 2>&1 | grep -oP 'openresty/\K[0-9.]+')"
        systemctl is-active --quiet openresty && print_success "  状态: 运行中" || print_error "  状态: 已停止"
        echo ""
    fi
    
    # Nginx
    if command -v nginx &> /dev/null; then
        echo -e "${CYAN}Nginx${NC}"
        echo "  版本: $(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')"
        systemctl is-active --quiet nginx && print_success "  状态: 运行中" || print_error "  状态: 已停止"
        echo ""
    fi
    
    # Caddy
    if command -v caddy &> /dev/null; then
        echo -e "${CYAN}Caddy${NC}"
        echo "  版本: $(caddy version | head -1)"
        systemctl is-active --quiet caddy && print_success "  状态: 运行中" || print_error "  状态: 已停止"
        echo ""
    fi
    
    # PHP 8.5
    if command -v php8.5 &> /dev/null; then
        echo -e "${CYAN}PHP 8.5${NC}"
        echo "  版本: $(php8.5 -v | head -1 | grep -oP 'PHP \K[0-9.]+')"
        systemctl is-active --quiet php8.5-fpm && print_success "  状态: 运行中" || print_error "  状态: 已停止"
        echo "  Socket: /run/php/php8.5-fpm.sock"
        
        # 显示 OPcache 状态
        if php8.5 -m | grep -qi opcache; then
            print_success "  OPcache: 已内置 ✓"
        fi
        echo ""
    fi
    
    # Supervisor
    if command -v supervisorctl &> /dev/null; then
        echo -e "${CYAN}Supervisor${NC}"
        local version=$(supervisorctl version 2>/dev/null)
        echo "  版本: ${version}"
        if systemctl is-active --quiet supervisor; then
            print_success "  状态: 运行中"
            local running_programs=$(supervisorctl status 2>/dev/null | grep RUNNING | wc -l)
            local total_programs=$(supervisorctl status 2>/dev/null | wc -l)
            echo "  程序: ${running_programs} 运行中 / ${total_programs} 总计"
        else
            print_error "  状态: 已停止"
        fi
        echo ""
    fi
    
    # NVM (检查常见用户)
    echo -e "${CYAN}NVM (Node.js)${NC}"
    local found_nvm=false
    for user_home in /home/*; do
        if [ -d "$user_home/.nvm" ]; then
            local username=$(basename "$user_home")
            found_nvm=true
            echo "  用户: $username"
            if [ -f "$user_home/.nvm/alias/default" ]; then
                local node_version=$(cat "$user_home/.nvm/alias/default")
                echo "  默认版本: $node_version"
            fi
        fi
    done
    if ! $found_nvm; then
        echo "  未安装"
    fi
    echo ""
    
    echo "=========================================="
    
    press_enter
}


# ============================================
# 主菜单
# ============================================


show_webserver_menu() {
    clear
    echo "=========================================="
    echo "   Web 服务器管理"
    echo "=========================================="
    echo ""
    
    echo "【Web 服务器】"
    echo ""
    echo "1. 🚀 安装 OpenResty (Nginx + Lua)"
    echo "2. 🌐 安装 Nginx"
    echo "3. ⚡ 安装 Caddy"
    echo ""
    
    echo "【运行环境】"
    echo ""
    echo "4. 🐘 安装 PHP 8.5"
    echo "5. 📦 安装 NVM (Node.js 版本管理)"
    echo "6. 🔧 安装 Supervisor (进程管理)"
    echo ""
    
    echo "【管理工具】"
    echo ""
    echo "7. 📊 查看服务状态"
    echo "8. 🗑️  卸载服务"
    echo ""
    
    echo "0. 返回主菜单"
    echo "=========================================="
}


webserver_menu() {
    while true; do
        show_webserver_menu
        read -p "请选择 [0-8]: " choice
        
        case $choice in
            1)
                install_openresty
                ;;
            2)
                install_nginx
                ;;
            3)
                install_caddy
                ;;
            4)
                install_php85
                ;;
            5)
                install_nvm
                ;;
            6)
                install_supervisor
                ;;
            7)
                view_services_status
                ;;
            8)
                uninstall_service
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
webserver_menu
