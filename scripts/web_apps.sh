#!/bin/bash
set -euo pipefail


# ============================================
# Web 应用安装管理脚本
# 支持 Tiny Tiny RSS, WordPress, phpMyAdmin, DokuWiki
# 功能：覆盖安装、数据备份、Basic Auth、SSL 证书
# 兼容：OpenResty 和 Nginx
# ============================================


# 配置变量
WEB_ROOT="/var/www"
PHP_VERSION="8.5"
PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
BACKUP_DIR="/root/web_backups"

# Web 服务器配置（将在初始化时设置）
WEB_SERVER=""           # "openresty" 或 "nginx"
NGINX_CONF_DIR=""       # Nginx/OpenResty 配置根目录
SITES_AVAIL=""          # sites-available 目录
SITES_ENABLED=""        # sites-enabled 目录
SSL_DIR=""              # SSL 证书目录
NGINX_BIN=""            # nginx/openresty 可执行文件
SERVICE_NAME=""         # 服务名称


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


# ============================================
# Web 服务器检测和初始化
# ============================================


# 检测并初始化 Web 服务器配置
init_webserver_config() {
    # 检测 OpenResty
    if command -v openresty &> /dev/null; then
        WEB_SERVER="openresty"
        NGINX_BIN="openresty"
        SERVICE_NAME="openresty"
        
        # OpenResty 标准路径
        if [ -d "/usr/local/openresty/nginx" ]; then
            NGINX_CONF_DIR="/usr/local/openresty/nginx/conf"
        else
            # 备用路径
            NGINX_CONF_DIR="/etc/openresty"
        fi
        
        SITES_AVAIL="${NGINX_CONF_DIR}/sites-available"
        SITES_ENABLED="${NGINX_CONF_DIR}/sites-enabled"
        SSL_DIR="${NGINX_CONF_DIR}/ssl"
        
        return 0
    fi
    
    # 检测 Nginx
    if command -v nginx &> /dev/null; then
        WEB_SERVER="nginx"
        NGINX_BIN="nginx"
        SERVICE_NAME="nginx"
        
        # Nginx 标准路径
        NGINX_CONF_DIR="/etc/nginx"
        SITES_AVAIL="${NGINX_CONF_DIR}/sites-available"
        SITES_ENABLED="${NGINX_CONF_DIR}/sites-enabled"
        SSL_DIR="${NGINX_CONF_DIR}/ssl"
        
        return 0
    fi
    
    # 未检测到任何 Web 服务器
    WEB_SERVER="none"
    return 1
}


# 显示 Web 服务器信息
show_webserver_info() {
    if [ "$WEB_SERVER" = "none" ]; then
        echo -e "${YELLOW}○${NC} Web 服务器: 未安装"
        return
    fi
    
    local version=""
    if [ "$WEB_SERVER" = "openresty" ]; then
        version=$(openresty -v 2>&1 | grep -oP 'openresty/\K[0-9.]+' || echo "unknown")
        print_success "Web 服务器: OpenResty ${version}"
    else
        version=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "unknown")
        print_success "Web 服务器: Nginx ${version}"
    fi
    
    echo "  配置目录: ${NGINX_CONF_DIR}"
    echo "  站点目录: ${SITES_AVAIL}"
    echo "  SSL 目录: ${SSL_DIR}"
}


# 检查 Web 服务器是否安装
check_webserver() {
    init_webserver_config
    [ "$WEB_SERVER" != "none" ]
}


# 重载 Web 服务器
reload_webserver() {
    if [ "$WEB_SERVER" = "none" ]; then
        print_error "未检测到 Web 服务器"
        return 1
    fi
    
    # 测试配置
    if $NGINX_BIN -t 2>/dev/null; then
        systemctl reload "$SERVICE_NAME"
        print_success "${WEB_SERVER} 配置已重载"
        return 0
    else
        print_error "${WEB_SERVER} 配置测试失败"
        $NGINX_BIN -t
        return 1
    fi
}


# ============================================
# 辅助函数
# ============================================


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


# 检查必要工具
ensure_tools() {
    local tools="wget curl openssl unzip git"
    local missing=""
    
    for tool in $tools; do
        if ! command -v $tool &> /dev/null; then
            missing="$missing $tool"
        fi
    done
    
    # 检查 htpasswd (apache2-utils)
    if ! command -v htpasswd &> /dev/null; then
        missing="$missing apache2-utils"
    fi
    
    if [ -n "$missing" ]; then
        print_info "安装必要工具:$missing"
        apt update -qq
        apt install -y $missing
        print_success "工具安装完成"
    fi
}


# 检查服务
check_php() { command -v php &> /dev/null; }
check_mysql() { command -v mysql &> /dev/null; }
check_postgresql() { command -v psql &> /dev/null; }


# 生成随机密码
generate_password() {
    local length=${1:-16}
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "$length"
}


# 生成自签名 SSL 证书
generate_ssl_cert() {
    local domain=$1
    local key_file="${SSL_DIR}/${domain}.key"
    local cert_file="${SSL_DIR}/${domain}.crt"
    
    mkdir -p "$SSL_DIR"
    
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$key_file" \
        -out "$cert_file" \
        -subj "/CN=${domain}" &>/dev/null
    
    echo "$cert_file:$key_file"
}


# 创建 MySQL 数据库
create_mysql_db() {
    local db_name=$1
    local db_user=$2
    local db_pass=$3
    
    mysql << EOF
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${db_user}'@'localhost';
CREATE USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOF
}


# 创建 PostgreSQL 数据库
create_postgresql_db() {
    local db_name=$1
    local db_user=$2
    local db_pass=$3
    
    sudo -u postgres psql << EOF
DROP USER IF EXISTS ${db_user};
CREATE USER ${db_user} WITH PASSWORD '${db_pass}';
DROP DATABASE IF EXISTS ${db_name};
CREATE DATABASE ${db_name} OWNER ${db_user};
GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};
\q
EOF
}


# 备份站点
backup_site() {
    local site_dir=$1
    local site_name=$(basename "$site_dir")
    
    mkdir -p "$BACKUP_DIR"
    
    local backup_file="${BACKUP_DIR}/${site_name}_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    print_info "备份站点到: $backup_file"
    tar czf "$backup_file" -C "$(dirname "$site_dir")" "$(basename "$site_dir")" 2>/dev/null
    
    print_success "备份完成 ($(du -h "$backup_file" | awk '{print $1}'))"
}


# 删除站点配置和文件
remove_site() {
    local domain=$1
    local site_dir="${WEB_ROOT}/${domain}"
    
    # 删除 Nginx/OpenResty 配置
    rm -f "${SITES_ENABLED}/${domain}.conf"
    rm -f "${SITES_AVAIL}/${domain}.conf"
    
    # 删除 SSL 证书
    rm -f "${SSL_DIR}/${domain}.key"
    rm -f "${SSL_DIR}/${domain}.crt"
    
    # 删除站点目录
    if [ -d "$site_dir" ]; then
        rm -rf "$site_dir"
    fi
}


# 确保配置目录存在
ensure_config_dirs() {
    mkdir -p "$SITES_AVAIL" "$SITES_ENABLED" "$SSL_DIR"
    
    # 检查主配置文件是否包含 sites-enabled
    local main_conf="${NGINX_CONF_DIR}/nginx.conf"
    
    if [ -f "$main_conf" ]; then
        if ! grep -q "include.*sites-enabled" "$main_conf"; then
            print_warning "${WEB_SERVER} 主配置未包含 sites-enabled"
            print_info "请在 http 块中添加: include ${SITES_ENABLED}/*.conf;"
        fi
    fi
}


# 检查依赖是否满足
check_dependencies() {
    local app_name=$1
    local missing=""
    
    # 检查 Web 服务器
    if [ "$WEB_SERVER" = "none" ]; then
        missing="${missing}\n  - Web 服务器 (Nginx/OpenResty)"
    fi
    
    # 检查 PHP
    if ! check_php; then
        missing="${missing}\n  - PHP ${PHP_VERSION}"
    fi
    
    # 根据应用检查数据库
    case $app_name in
        "wordpress"|"phpmyadmin")
            if ! check_mysql; then
                missing="${missing}\n  - MySQL/MariaDB"
            fi
            ;;
        "ttrss")
            if ! check_postgresql; then
                missing="${missing}\n  - PostgreSQL"
            fi
            ;;
    esac
    
    if [ -n "$missing" ]; then
        print_error "缺少必要组件:"
        echo -e "$missing"
        echo ""
        print_info "请先使用主菜单的其他选项安装以下组件："
        echo "  - Web 服务器管理 -> 安装 Nginx/OpenResty"
        echo "  - 数据库管理 -> 安装数据库"
        return 1
    fi
    
    return 0
}


# ============================================
# 安装 phpMyAdmin (带 Basic Auth)
# ============================================


install_phpmyadmin() {
    clear
    echo "=========================================="
    echo "   安装 phpMyAdmin"
    echo "=========================================="
    echo ""
    
    check_root || return
    init_webserver_config
    ensure_tools
    
    # 检查依赖
    if ! check_dependencies "phpmyadmin"; then
        press_enter
        return
    fi
    
    ensure_config_dirs
    
    # 配置参数
    read -p "域名 (如: pma.example.com, 默认: _): " domain
    domain=${domain:-_}
    
    local install_dir="${WEB_ROOT}/phpmyadmin"
    
    # 检查是否已存在
    if [ -d "$install_dir" ]; then
        echo ""
        print_warning "phpMyAdmin 已安装在: $install_dir"
        echo -n "是否覆盖安装? (yes/no): "
        read -r confirm
        if [[ "$confirm" != "yes" ]]; then
            print_info "已取消"
            press_enter
            return
        fi
        
        # 备份
        backup_site "$install_dir"
        
        # 删除旧配置
        remove_site "$domain"
        rm -f "${NGINX_CONF_DIR}/.htpasswd_phpmyadmin"
    fi
    
    # Basic Auth 配置
    echo ""
    print_info "配置 Basic Auth 认证"
    read -p "用户名 (默认: admin): " pma_user
    pma_user=${pma_user:-admin}
    
    read -sp "密码 (留空自动生成): " pma_pass
    echo ""
    
    if [ -z "$pma_pass" ]; then
        pma_pass=$(generate_password 12)
        print_info "生成的密码: $pma_pass"
    fi
    
    echo ""
    print_info "安装配置："
    echo "  Web 服务器: ${WEB_SERVER}"
    echo "  域名: ${domain}"
    echo "  目录: ${install_dir}"
    echo "  Basic Auth 用户: ${pma_user}"
    echo ""
    
    read -p "确认安装？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 下载 phpMyAdmin
    echo ""
    print_info "[1/5] 下载 phpMyAdmin..."
    mkdir -p "$install_dir"
    cd /tmp
    
    # 获取最新版本
    PMA_VERSION="5.2.1"
    wget -q --show-progress "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz" -O pma.tar.gz
    
    tar xzf pma.tar.gz
    cp -r "phpMyAdmin-${PMA_VERSION}-all-languages"/* "$install_dir/"
    rm -rf pma.tar.gz "phpMyAdmin-${PMA_VERSION}-all-languages"
    
    # 配置 phpMyAdmin
    print_info "[2/5] 配置 phpMyAdmin..."
    cd "$install_dir"
    cp config.sample.inc.php config.inc.php
    
    local blowfish_secret=$(generate_password 32)
    sed -i "s|\$cfg\['blowfish_secret'\] = ''|\$cfg['blowfish_secret'] = '${blowfish_secret}'|" config.inc.php
    
    # 启用任意服务器连接（支持远程 MySQL/MariaDB）
    cat >> config.inc.php << 'PMACONFIG'

/* 允许连接到任意 MySQL/MariaDB 服务器 */
$cfg['AllowArbitraryServer'] = true;

/* 默认服务器配置（可选） */
$cfg['Servers'][$i]['host'] = 'localhost';
$cfg['Servers'][$i]['port'] = '';
$cfg['Servers'][$i]['socket'] = '';
$cfg['Servers'][$i]['auth_type'] = 'cookie';
$cfg['Servers'][$i]['AllowNoPassword'] = false;
PMACONFIG
    
    mkdir -p tmp
    chown -R www-data:www-data "$install_dir"
    chmod -R 755 "$install_dir"
    chmod 777 tmp
    
    # 创建 Basic Auth
    print_info "[3/5] 配置 Basic Auth..."
    htpasswd -bc "${NGINX_CONF_DIR}/.htpasswd_phpmyadmin" "$pma_user" "$pma_pass"
    
    # 生成 SSL 证书
    print_info "[4/5] 生成 SSL 证书..."
    local ssl_files=$(generate_ssl_cert "$domain")
    local ssl_cert=$(echo "$ssl_files" | cut -d: -f1)
    local ssl_key=$(echo "$ssl_files" | cut -d: -f2)
    
    # 创建 Nginx 配置
    print_info "[5/5] 配置 ${WEB_SERVER}..."
    cat > "${SITES_AVAIL}/phpmyadmin.conf" << PMACONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    
    root ${install_dir};
    index index.php;
    
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    access_log /var/log/${WEB_SERVER}/phpmyadmin.access.log;
    error_log /var/log/${WEB_SERVER}/phpmyadmin.error.log;
    
    # Basic Auth 认证
    auth_basic "phpMyAdmin Access";
    auth_basic_user_file ${NGINX_CONF_DIR}/.htpasswd_phpmyadmin;
    
    client_max_body_size 512M;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass unix:${PHP_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    
    # 安全加固
    location ~ ^/(libraries|setup|sql)/ {
        deny all;
    }
    
    location ~ /\. {
        deny all;
    }
}
PMACONF
    
    # 创建日志目录
    mkdir -p "/var/log/${WEB_SERVER}"
    
    ln -sf "${SITES_AVAIL}/phpmyadmin.conf" "${SITES_ENABLED}/"
    reload_webserver
    
    # 保存信息
    cat > /root/phpmyadmin-info.txt << INFO
phpMyAdmin 安装信息
===================
Web 服务器: ${WEB_SERVER}
访问地址: https://${domain}
安装目录: ${install_dir}

Basic Auth 认证
----------------
用户名: ${pma_user}
密码: ${pma_pass}

配置文件
--------
${WEB_SERVER} 配置: ${SITES_AVAIL}/phpmyadmin.conf
密码文件: ${NGINX_CONF_DIR}/.htpasswd_phpmyadmin
SSL 证书: ${ssl_cert}
SSL 密钥: ${ssl_key}

使用说明
--------
1. 访问时首先需要通过 Basic Auth 认证
2. 登录界面会显示"服务器"输入框，可以输入：
   - localhost (本地数据库)
   - 远程服务器 IP 或域名 (如: 192.168.1.100 或 db.example.com)
   - 带端口的服务器地址 (如: 192.168.1.100:3307)
3. 输入数据库用户名和密码登录
4. 支持连接多个不同的 MySQL/MariaDB 服务器

重要提示
--------
- 已启用 AllowArbitraryServer，可连接任意 MySQL/MariaDB 服务器
- 建议使用 Let's Encrypt 配置真实 SSL 证书
- 定期更新 phpMyAdmin 到最新版本
- 限制访问 IP 地址（可选）
- 确保远程数据库允许此服务器的 IP 连接

MySQL SSL 连接配置（可选）
--------------------------
如需通过 SSL 连接到 MySQL/MariaDB，需要完成以下步骤：

1. MySQL 服务器端配置：
   在 MySQL 服务器上启用 SSL（编辑 /etc/mysql/my.cnf 或 /etc/my.cnf）：
   
   [mysqld]
   ssl-ca=/var/lib/mysql/ca-cert.pem
   ssl-cert=/var/lib/mysql/server-cert.pem
   ssl-key=/var/lib/mysql/server-key.pem
   require_secure_transport=ON
   
   重启 MySQL 服务：systemctl restart mariadb

2. 获取证书文件：
   从 MySQL 服务器复制以下文件到 phpMyAdmin 服务器：
   - ca-cert.pem (CA 证书)
   - client-cert.pem (客户端证书)
   - client-key.pem (客户端密钥)
   
   建议存放在：${install_dir}/ssl/

3. 配置 phpMyAdmin：
   编辑 ${install_dir}/config.inc.php，取消注释并修改 SSL 配置：
   
   \$cfg['Servers'][\$i]['ssl'] = true;
   \$cfg['Servers'][\$i]['ssl_key'] = '${install_dir}/ssl/client-key.pem';
   \$cfg['Servers'][\$i]['ssl_cert'] = '${install_dir}/ssl/client-cert.pem';
   \$cfg['Servers'][\$i]['ssl_ca'] = '${install_dir}/ssl/ca-cert.pem';
   \$cfg['Servers'][\$i]['ssl_verify'] = true;

4. 设置证书权限：
   chown www-data:www-data ${install_dir}/ssl/*.pem
   chmod 600 ${install_dir}/ssl/*.pem


管理命令
--------
查看日志: tail -f /var/log/${WEB_SERVER}/phpmyadmin.access.log
重启服务: systemctl reload ${SERVICE_NAME}

生成时间: $(date)
INFO
    
    chmod 600 /root/phpmyadmin-info.txt
    
    echo ""
    print_success "phpMyAdmin 安装完成！"
    echo ""
    cat /root/phpmyadmin-info.txt
    
    press_enter
}


# ============================================
# 安装 WordPress
# ============================================


install_wordpress() {
    clear
    echo "=========================================="
    echo "   安装 WordPress"
    echo "=========================================="
    echo ""
    
    check_root || return
    init_webserver_config
    ensure_tools
    
    # 检查依赖
    if ! check_dependencies "wordpress"; then
        press_enter
        return
    fi
    
    ensure_config_dirs
    
    # 配置参数
    read -p "站点域名 (如: blog.example.com): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local install_dir="${WEB_ROOT}/${domain}"
    local db_name="wp_${domain//./_}"
    local db_user="${db_name}_user"
    local db_pass=""
    
    # 检查是否已存在
    if [ -d "$install_dir" ]; then
        echo ""
        print_warning "WordPress 站点已存在: $install_dir"
        echo -n "是否覆盖安装? (yes/no): "
        read -r overwrite
        if [[ "$overwrite" != "yes" ]]; then
            print_info "已取消"
            press_enter
            return
        fi
        
        # 读取旧数据库信息
        local old_db_name=""
        local old_db_user=""
        if [ -f "$install_dir/SITE-INFO.txt" ]; then
            old_db_name=$(grep "数据库名:" "$install_dir/SITE-INFO.txt" | awk '{print $2}')
            old_db_user=$(grep "数据库用户:" "$install_dir/SITE-INFO.txt" | awk '{print $2}')
        fi
        
        # 备份
        backup_site "$install_dir"
        
        # 删除旧配置
        remove_site "$domain"
        
        # 询问是否删除旧数据库
        if [ -n "$old_db_name" ]; then
            echo -n "是否删除旧数据库 ${old_db_name}? (yes/no): "
            read -r delete_db
            if [[ "$delete_db" == "yes" ]]; then
                mysql -e "DROP DATABASE IF EXISTS \`${old_db_name}\`;" 2>/dev/null
                mysql -e "DROP USER IF EXISTS '${old_db_user}'@'localhost';" 2>/dev/null
                print_success "已删除旧数据库"
            fi
        fi
    fi
    
    # 数据库配置
    echo ""
    print_info "数据库配置"
    
    # 询问数据库类型
    echo ""
    echo "选择数据库位置："
    echo "  1) 本地数据库 (localhost)"
    echo "  2) 远程数据库"
    read -p "请选择 [1/2] (默认: 1): " db_location_choice
    db_location_choice=${db_location_choice:-1}
    
    local db_host="localhost"
    local create_database=true
    
    if [[ "$db_location_choice" == "2" ]]; then
        create_database=false
        echo ""
        print_info "远程数据库配置"
        read -p "数据库主机地址 (默认: 10.0.0.2): " db_host
        db_host=${db_host:-10.0.0.2}
        
        read -p "数据库端口 (默认: 3306): " db_port
        db_port=${db_port:-3306}
        
        # 如果端口不是 3306，添加到主机地址
        if [ "$db_port" != "3306" ]; then
            db_host="${db_host}:${db_port}"
        fi
        
        print_warning "请确保远程数据库已创建并授权此服务器访问"
    else
        db_host="localhost"
        print_info "将在本地创建数据库"
    fi
    
    echo ""
    read -p "数据库名 (默认: ${db_name}): " custom_db_name
    db_name=${custom_db_name:-$db_name}
    
    read -p "数据库用户 (默认: ${db_user}): " custom_db_user
    db_user=${custom_db_user:-$db_user}
    
    read -sp "数据库密码 (留空自动生成): " db_pass
    echo ""
    
    if [ -z "$db_pass" ]; then
        if [ "$create_database" = true ]; then
            db_pass=$(generate_password 16)
            print_info "生成的密码: $db_pass"
        else
            print_error "远程数据库必须提供密码"
            press_enter
            return
        fi
    fi
    
    echo ""
    print_info "安装配置："
    echo "  Web 服务器: ${WEB_SERVER}"
    echo "  域名: ${domain}"
    echo "  目录: ${install_dir}"
    echo "  数据库主机: ${db_host}"
    echo "  数据库名: ${db_name}"
    echo "  数据库用户: ${db_user}"
    echo "  配置目录: ${SITES_AVAIL}"
    echo ""
    
    read -p "确认安装？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 创建数据库（仅本地）
    echo ""
    if [ "$create_database" = true ]; then
        print_info "[1/5] 创建本地数据库..."
        create_mysql_db "$db_name" "$db_user" "$db_pass"
    else
        print_info "[1/5] 跳过数据库创建（使用远程数据库）..."
        print_warning "请确保远程数据库 ${db_name} 已存在并授权"
    fi
    
    # 下载 WordPress
    print_info "[2/5] 下载 WordPress..."
    mkdir -p "$install_dir"
    cd /tmp
    wget -q --show-progress -O wordpress.tar.gz https://wordpress.org/latest.tar.gz
    tar xzf wordpress.tar.gz
    cp -r wordpress/* "$install_dir/"
    rm -rf wordpress wordpress.tar.gz
    
    # 配置 WordPress
    print_info "[3/5] 配置 WordPress..."
    cd "$install_dir"
    cp wp-config-sample.php wp-config.php
    
    sed -i "s/database_name_here/${db_name}/" wp-config.php
    sed -i "s/username_here/${db_user}/" wp-config.php
    sed -i "s/password_here/${db_pass}/" wp-config.php
    sed -i "s/localhost/${db_host}/" wp-config.php
    
    # 生成安全密钥
    curl -s https://api.wordpress.org/secret-key/1.1/salt/ >> wp-config.php
    
    # 设置权限
    chown -R www-data:www-data "$install_dir"
    find "$install_dir" -type d -exec chmod 755 {} \;
    find "$install_dir" -type f -exec chmod 644 {} \;
    
    # 生成 SSL 证书
    print_info "[4/5] 生成 SSL 证书..."
    local ssl_files=$(generate_ssl_cert "$domain")
    local ssl_cert=$(echo "$ssl_files" | cut -d: -f1)
    local ssl_key=$(echo "$ssl_files" | cut -d: -f2)
    
    # 创建配置文件
    print_info "[5/5] 配置 ${WEB_SERVER}..."
    cat > "${SITES_AVAIL}/${domain}.conf" << WPCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    
    root ${install_dir};
    index index.php index.html;
    
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    access_log /var/log/${WEB_SERVER}/${domain}.access.log;
    error_log /var/log/${WEB_SERVER}/${domain}.error.log;
    
    client_max_body_size 512M;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass unix:${PHP_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 365d;
        add_header Cache-Control "public, immutable";
    }
    
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
    
    location ~ /\. {
        deny all;
    }
}
WPCONF
    
    # 创建日志目录
    mkdir -p "/var/log/${WEB_SERVER}"
    
    ln -sf "${SITES_AVAIL}/${domain}.conf" "${SITES_ENABLED}/"
    reload_webserver
    
    # 保存信息
    cat > "$install_dir/SITE-INFO.txt" << INFO
WordPress 站点信息
==================
Web 服务器: ${WEB_SERVER}
域名: ${domain}
目录: ${install_dir}

数据库信息
----------
数据库主机: ${db_host}
数据库名: ${db_name}
数据库用户: ${db_user}
数据库密码: ${db_pass}

访问地址
--------
前台: https://${domain}
后台: https://${domain}/wp-admin/
安装: https://${domain}/wp-admin/install.php

配置文件
--------
WordPress: ${install_dir}/wp-config.php
${WEB_SERVER}: ${SITES_AVAIL}/${domain}.conf
SSL 证书: ${ssl_cert}

管理命令
--------
查看日志: tail -f /var/log/${WEB_SERVER}/${domain}.access.log
重启服务: systemctl reload ${SERVICE_NAME}
备份站点: tar czf wordpress-backup.tar.gz ${install_dir}

生成时间: $(date)
INFO
    
    chmod 600 "$install_dir/SITE-INFO.txt"
    
    echo ""
    print_success "WordPress 安装完成！"
    echo ""
    cat "$install_dir/SITE-INFO.txt"
    echo ""
    print_warning "请访问安装向导完成 WordPress 初始化配置"
    
    press_enter
}


# ============================================
# 安装 Tiny Tiny RSS
# ============================================


install_ttrss() {
    clear
    echo "=========================================="
    echo "   安装 Tiny Tiny RSS"
    echo "=========================================="
    echo ""
    
    check_root || return
    init_webserver_config
    ensure_tools
    
    # 检查依赖
    if ! check_dependencies "ttrss"; then
        press_enter
        return
    fi
    
    ensure_config_dirs
    
    # 检测 PostgreSQL 端口
    echo ""
    print_info "检测 PostgreSQL 配置..."
    
    local detected_pg_port=$(sudo -u postgres psql -t -c "SHOW port;" 2>/dev/null | tr -d ' ')
    
    if [ -z "$detected_pg_port" ]; then
        print_warning "无法检测 PostgreSQL 端口，使用默认值 5432"
        detected_pg_port="5432"
    else
        print_success "PostgreSQL 端口: $detected_pg_port"
    fi
    
    # 检查 PostgreSQL 是否在监听该端口
    if netstat -tuln 2>/dev/null | grep -q ":${detected_pg_port}.*LISTEN" || \
       ss -tuln 2>/dev/null | grep -q ":${detected_pg_port}.*LISTEN"; then
        print_success "PostgreSQL 正在监听端口 ${detected_pg_port}"
    else
        print_warning "PostgreSQL 可能未在端口 ${detected_pg_port} 监听"
        echo ""
        print_info "检查命令："
        echo "  sudo netstat -tulnp | grep postgres"
        echo "  sudo ss -tulnp | grep postgres"
    fi
    
    # 配置参数
    echo ""
    read -p "域名 (如: rss.example.com): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local install_dir="${WEB_ROOT}/${domain}"
    local db_name="ttrss"
    local db_user="ttrss"
    local db_pass=""
    local db_port="$detected_pg_port"
    local overwrite_install=false
    
    # 检查是否已存在
    if [ -d "$install_dir" ]; then
        echo ""
        print_warning "检测到 Tiny Tiny RSS 已存在"
        echo "  目录: $install_dir"
        
        # 检查是否有配置文件
        if [ -f "$install_dir/config.php" ]; then
            echo ""
            print_info "检测到现有配置，可以选择："
            echo "  1. 覆盖安装（删除所有数据，重新安装）"
            echo "  2. 重新配置（保留代码，只更新配置）"
            echo "  3. 取消"
            echo ""
            read -p "请选择 [1-3]: " reinstall_choice
            
            case $reinstall_choice in
                1)
                    print_warning "⚠️  覆盖安装将删除："
                    echo "  - 所有订阅数据"
                    echo "  - 用户账号"
                    echo "  - 配置文件"
                    echo "  - 数据库"
                    echo ""
                    read -p "输入 'DELETE' 确认删除所有数据: " confirm_delete
                    
                    if [ "$confirm_delete" != "DELETE" ]; then
                        print_info "已取消"
                        press_enter
                        return
                    fi
                    
                    overwrite_install=true
                    
                    # 停止更新守护进程
                    print_info "停止服务..."
                    systemctl stop tt-rss-update 2>/dev/null || true
                    systemctl disable tt-rss-update 2>/dev/null || true
                    
                    # 备份
                    backup_site "$install_dir"
                    
                    # 删除旧配置和代码
                    remove_site "$domain"
                    rm -rf "$install_dir"
                    
                    # 删除数据库（稍后会重新创建）
                    print_info "删除旧数据库..."
                    sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${db_name};" 2>/dev/null || true
                    sudo -u postgres psql -c "DROP USER IF EXISTS ${db_user};" 2>/dev/null || true
                    
                    # 删除服务文件
                    rm -f /etc/systemd/system/tt-rss-update.service
                    systemctl daemon-reload
                    ;;
                2)
                    print_info "重新配置模式（保留代码）"
                    overwrite_install=false
                    
                    # 停止服务
                    systemctl stop tt-rss-update 2>/dev/null || true
                    ;;
                3)
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
        else
            print_warning "目录存在但无配置文件，将清空目录重新安装"
            rm -rf "$install_dir"
            overwrite_install=true
        fi
    else
        overwrite_install=true
    fi
    
    # 数据库配置
    echo ""
    print_info "数据库配置"
    read -p "数据库名 (默认: ${db_name}): " custom_db_name
    db_name=${custom_db_name:-$db_name}
    
    read -p "数据库用户 (默认: ${db_user}): " custom_db_user
    db_user=${custom_db_user:-$db_user}
    
    read -sp "数据库密码 (留空自动生成): " db_pass
    echo ""
    
    if [ -z "$db_pass" ]; then
        db_pass=$(generate_password 16)
        print_info "生成的密码: $db_pass"
    fi
    
    read -p "数据库端口 (默认: ${db_port}): " custom_db_port
    db_port=${custom_db_port:-$db_port}
    
    # 更新守护进程配置
    echo ""
    print_info "更新守护进程配置"
    read -p "并发任务数 (默认: 10): " update_tasks
    update_tasks=${update_tasks:-10}
    
    read -p "更新间隔(分钟) (默认: 3): " update_interval
    update_interval=${update_interval:-3}
    
    echo ""
    print_info "安装配置："
    echo "  Web 服务器: ${WEB_SERVER}"
    echo "  域名: ${domain}"
    echo "  目录: ${install_dir}"
    echo "  数据库: PostgreSQL"
    echo "  数据库名: ${db_name}"
    echo "  数据库用户: ${db_user}"
    echo "  数据库端口: ${db_port}"
    echo "  并发任务: ${update_tasks}"
    echo "  更新间隔: ${update_interval} 分钟"
    echo "  模式: $([ "$overwrite_install" = true ] && echo '全新安装' || echo '重新配置')"
    echo ""
    
    read -p "确认安装？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 如果是全新安装，下载代码
    if [ "$overwrite_install" = true ]; then
        # 创建数据库
        echo ""
        print_info "[1/6] 创建数据库..."
        create_postgresql_db "$db_name" "$db_user" "$db_pass"
        
        # 下载 Tiny Tiny RSS
        print_info "[2/6] 下载 Tiny Tiny RSS..."
        mkdir -p "$install_dir"
        cd /tmp
        rm -rf tt-rss
        
        if ! git clone --depth=1 https://git.tt-rss.org/fox/tt-rss.git; then
            print_error "下载失败，请检查网络连接"
            press_enter
            return
        fi
        
        cp -r tt-rss/* "$install_dir/"
        rm -rf tt-rss
        
        step_num=3
    else
        echo ""
        print_info "跳过代码下载（使用现有代码）"
        step_num=1
    fi
    
    # 配置 Tiny Tiny RSS (使用 putenv 方式)
    print_info "[${step_num}/6] 配置 Tiny Tiny RSS..."
    cd "$install_dir"
    
    # 创建简化的配置文件（使用 putenv）
    cat > config.php << 'TTRSSCONFIG'
<?php
// ************************************
// Tiny Tiny RSS 配置文件 (Environment)
// ************************************

// PostgreSQL 数据库配置
putenv('TTRSS_DB_TYPE=pgsql');
putenv('TTRSS_DB_HOST=127.0.0.1');
putenv('TTRSS_DB_PORT=DB_PORT_PLACEHOLDER');
putenv('TTRSS_DB_NAME=DB_NAME_PLACEHOLDER');
putenv('TTRSS_DB_USER=DB_USER_PLACEHOLDER');
putenv('TTRSS_DB_PASS=DB_PASS_PLACEHOLDER');

// TTRSS 访问 URL
putenv('TTRSS_SELF_URL_PATH=SELF_URL_PLACEHOLDER');

// PHP CLI 路径
putenv('TTRSS_PHP_EXECUTABLE=/usr/bin/php');
?>
TTRSSCONFIG
    
    # 替换占位符
    sed -i "s|DB_PORT_PLACEHOLDER|${db_port}|g" config.php
    sed -i "s|DB_NAME_PLACEHOLDER|${db_name}|g" config.php
    sed -i "s|DB_USER_PLACEHOLDER|${db_user}|g" config.php
    sed -i "s|DB_PASS_PLACEHOLDER|${db_pass}|g" config.php
    sed -i "s|SELF_URL_PLACEHOLDER|https://${domain}/|g" config.php
    
    ((step_num++))
    
    # 设置文件权限
    print_info "[${step_num}/6] 设置文件权限..."
    chown -R www-data:www-data "$install_dir"
    chmod -R 755 "$install_dir"
    
    # 创建必要的目录
    mkdir -p "$install_dir"/{lock,cache,feed-icons}
    chown -R www-data:www-data "$install_dir"/{lock,cache,feed-icons}
    chmod -R 777 "$install_dir"/{lock,cache,feed-icons}
    
    ((step_num++))
    
    # 初始化数据库结构
    print_info "[${step_num}/6] 初始化数据库结构..."
    cd "$install_dir"
    
    # 确保 update.php 存在
    if [ ! -f "update.php" ]; then
        print_error "update.php 不存在！"
        press_enter
        return
    fi
    
    # 使用 update.php 初始化数据库
    print_info "执行数据库结构初始化（可能需要几分钟）..."
    sudo -u www-data php update.php --update-schema=force 2>&1 | tee /tmp/ttrss-update.log
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        print_success "数据库结构初始化成功"
    else
        print_error "数据库结构初始化失败"
        echo ""
        print_info "错误日志："
        cat /tmp/ttrss-update.log
        echo ""
        print_warning "你可能需要检查："
        echo "  1. 数据库连接是否正常"
        echo "  2. 配置文件是否正确: $install_dir/config.php"
        echo "  3. PostgreSQL 是否在端口 ${db_port} 监听"
        echo ""
        print_info "手动修复命令："
        echo "  cd $install_dir"
        echo "  sudo -u www-data php update.php --update-schema=force"
        echo ""
        read -p "是否继续安装？[y/N]: " continue_install
        if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi
    
    # 验证数据库表是否创建成功
    print_info "验证数据库表..."
    local table_count=$(sudo -u postgres psql -d "$db_name" -t -c \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ')
    
    if [ -n "$table_count" ] && [ "$table_count" -gt 0 ]; then
        print_success "数据库包含 ${table_count} 个表"
    else
        print_error "数据库表创建失败！"
        echo ""
        print_warning "请手动执行以下命令初始化数据库："
        echo "  cd $install_dir"
        echo "  sudo -u www-data php update.php --update-schema=force"
        echo ""
        read -p "按 Enter 继续..."
    fi
    
    ((step_num++))
    
    # 生成 SSL 证书
    print_info "[${step_num}/6] 生成 SSL 证书..."
    local ssl_files=$(generate_ssl_cert "$domain")
    local ssl_cert=$(echo "$ssl_files" | cut -d: -f1)
    local ssl_key=$(echo "$ssl_files" | cut -d: -f2)
    
    ((step_num++))
    
    # 创建 Web 服务器配置
    print_info "[${step_num}/6] 配置 ${WEB_SERVER}..."
    cat > "${SITES_AVAIL}/${domain}.conf" << TTRSSCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    
    root ${install_dir};
    index index.php;
    
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    # 增加上传限制
    client_max_body_size 512M;
    
    access_log /var/log/${WEB_SERVER}/${domain}.access.log;
    error_log /var/log/${WEB_SERVER}/${domain}.error.log;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
    }
    
    # 保护敏感文件
    location ~ /\. {
        deny all;
    }
    
    location ~ /(config\.php|\.git) {
        deny all;
    }
    
    # 缓存静态资源
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
TTRSSCONF
    
    # 创建日志目录
    mkdir -p "/var/log/${WEB_SERVER}"
    
    ln -sf "${SITES_AVAIL}/${domain}.conf" "${SITES_ENABLED}/"
    reload_webserver
    
    ((step_num++))
    
    # 配置更新守护进程（多进程模式）
    print_info "[${step_num}/6] 配置更新守护进程（多进程模式）..."
    
    cat > /etc/systemd/system/tt-rss-update.service << TTRSSSERVICE
[Unit]
Description=Tiny Tiny RSS update daemon (multi-process)
After=network.target postgresql.service ${SERVICE_NAME}.service
Wants=postgresql.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${install_dir}
ExecStart=/usr/bin/php ${install_dir}/update_daemon2.php --tasks ${update_tasks} --interval ${update_interval} --quiet
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# 安全加固
PrivateTmp=yes
NoNewPrivileges=true

# 资源限制（可选）
# MemoryMax=512M
# CPUQuota=50%

[Install]
WantedBy=multi-user.target
TTRSSSERVICE
    
    systemctl daemon-reload
    systemctl enable tt-rss-update
    systemctl start tt-rss-update
    
    # 等待服务启动
    sleep 3
    
    # 检查服务状态
    if systemctl is-active --quiet tt-rss-update; then
        print_success "更新服务已启动"
        echo ""
        print_info "更新守护进程配置："
        echo "  - 并发任务数: ${update_tasks}"
        echo "  - 更新间隔: ${update_interval} 分钟"
        echo "  - 静默模式: 已启用"
        echo "  - 日志: systemd journal (自动轮转)"
    else
        print_warning "更新服务启动失败，请检查日志: journalctl -u tt-rss-update -n 50"
    fi
    
    # 保存信息
    cat > "$install_dir/TTRSS-INFO.txt" << INFO
========================================
Tiny Tiny RSS 安装信息
========================================

安装类型: $([ "$overwrite_install" = true ] && echo '全新安装' || echo '重新配置')
安装时间: $(date)

Web 配置
--------
Web 服务器: ${WEB_SERVER}
域名: ${domain}
安装目录: ${install_dir}
访问地址: https://${domain}

数据库信息
----------
类型: PostgreSQL
主机: 127.0.0.1
端口: ${db_port} (自动检测)
数据库名: ${db_name}
数据库用户: ${db_user}
数据库密码: ${db_pass}

更新守护进程
------------
并发任务数: ${update_tasks}
更新间隔: ${update_interval} 分钟
静默模式: 已启用
日志方式: systemd journal (自动轮转)
服务文件: /etc/systemd/system/tt-rss-update.service

默认账号
--------
用户名: admin
默认密码: password
⚠️  请立即修改！

配置文件
--------
TTRSS 配置: ${install_dir}/config.php (putenv 方式)
Web 服务器: ${SITES_AVAIL}/${domain}.conf
SSL 证书: ${ssl_cert}
SSL 密钥: ${ssl_key}
更新服务: /etc/systemd/system/tt-rss-update.service

重要目录
--------
锁目录: ${install_dir}/lock
缓存目录: ${install_dir}/cache
图标目录: ${install_dir}/feed-icons

PostgreSQL 检测
---------------
检测到的端口: ${detected_pg_port}
使用的端口: ${db_port}

检查 PostgreSQL 端口:
  sudo -u postgres psql -c "SHOW port;"
  sudo netstat -tulnp | grep postgres
  sudo ss -tulnp | grep postgres

管理命令
--------
查看更新服务状态:
  systemctl status tt-rss-update

重启更新服务:
  systemctl restart tt-rss-update

停止更新服务:
  systemctl stop tt-rss-update

查看更新日志（实时）:
  journalctl -u tt-rss-update -f

查看最近日志:
  journalctl -u tt-rss-update -n 100

查看今天的日志:
  journalctl -u tt-rss-update --since today

查看访问日志:
  tail -f /var/log/${WEB_SERVER}/${domain}.access.log

查看错误日志:
  tail -f /var/log/${WEB_SERVER}/${domain}.error.log

重启 Web 服务:
  systemctl reload ${SERVICE_NAME}

手动触发更新（测试）:
  cd ${install_dir}
  sudo -u www-data php update.php --feeds

日志管理
--------
查看 journal 配置:
  cat /etc/systemd/journald.conf

查看 journal 磁盘使用:
  journalctl --disk-usage

清理旧日志（保留最近 100MB）:
  journalctl --vacuum-size=100M

清理旧日志（保留最近 7 天）:
  journalctl --vacuum-time=7d

只查看错误日志:
  journalctl -u tt-rss-update -p err

数据库管理
----------
初始化/更新数据库结构:
  cd ${install_dir}
  sudo -u www-data php update.php --update-schema=force

检查数据库表:
  sudo -u postgres psql -d ${db_name} -c "\dt"

查看表数量:
  sudo -u postgres psql -d ${db_name} -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';"

连接数据库:
  sudo -u postgres psql -d ${db_name}

查看订阅统计:
  sudo -u postgres psql -d ${db_name} -c "SELECT COUNT(*) FROM ttrss_feeds;"

首次设置步骤
------------
1. 访问: https://${domain}
2. 使用默认账号登录 (admin/password)
3. 立即修改密码！
4. 访问 设置 → 偏好设置 进行个性化配置
5. 添加 RSS 订阅源
6. 等待自动更新（间隔 ${update_interval} 分钟）

配置说明
--------
配置文件使用 putenv() 方式，环境变量前缀为 TTRSS_
必需配置项：
  - TTRSS_DB_TYPE: 数据库类型
  - TTRSS_DB_HOST: 数据库主机
  - TTRSS_DB_PORT: 数据库端口（自动检测）
  - TTRSS_DB_NAME: 数据库名
  - TTRSS_DB_USER: 数据库用户
  - TTRSS_DB_PASS: 数据库密码
  - TTRSS_SELF_URL_PATH: 访问 URL
  - TTRSS_PHP_EXECUTABLE: PHP 路径

其他配置由 TTRSS 自动管理，无需手动设置。

更新守护进程参数:
  --tasks ${update_tasks}      # 并发更新任务数
  --interval ${update_interval}    # 更新间隔（分钟）
  --quiet           # 静默模式，减少日志输出

性能优化建议
------------
1. 调整并发任务数:
   编辑 /etc/systemd/system/tt-rss-update.service
   修改 --tasks 参数（建议 5-20）
   systemctl daemon-reload && systemctl restart tt-rss-update

2. 调整更新间隔:
   修改 --interval 参数（建议 3-30 分钟）

3. 监控资源使用:
   top -u www-data
   htop -u www-data

4. 添加资源限制（可选）:
   编辑服务文件，取消注释:
   MemoryMax=512M
   CPUQuota=50%

5. 管理 journal 日志大小:
   编辑 /etc/systemd/journald.conf
   设置 SystemMaxUse=100M

故障排查
--------
如果出现 "Base database schema is missing" 错误：
  1. 手动初始化数据库:
     cd ${install_dir}
     sudo -u www-data php update.php --update-schema=force
  
  2. 检查配置文件:
     cat ${install_dir}/config.php
  
  3. 检查数据库连接:
     sudo -u postgres psql -d ${db_name} -c "SELECT version();"

如果页面无法访问：
  1. 检查 Web 服务: systemctl status ${SERVICE_NAME}
  2. 检查 PHP-FPM: systemctl status php*-fpm
  3. 检查错误日志: tail -f /var/log/${WEB_SERVER}/${domain}.error.log

如果 Feed 不更新：
  1. 检查更新服务: systemctl status tt-rss-update
  2. 查看更新日志: journalctl -u tt-rss-update -f
  3. 手动运行更新: cd ${install_dir} && sudo -u www-data php update.php --feeds
  4. 检查订阅源是否有效

如果更新服务频繁重启：
  1. 查看日志: journalctl -u tt-rss-update -n 200 --no-pager
  2. 检查 PHP 错误: tail -f /var/log/php*-fpm.log
  3. 降低并发任务数（--tasks）
  4. 增加内存限制

备份建议
--------
1. 数据库备份:
   sudo -u postgres pg_dump ${db_name} > ttrss-backup-\$(date +%F).sql

2. 配置备份:
   tar czf ttrss-config-\$(date +%F).tar.gz ${install_dir}/config.php

3. 完整备份:
   tar czf ttrss-full-\$(date +%F).tar.gz ${install_dir}

4. 恢复数据库:
   sudo -u postgres psql -d ${db_name} < ttrss-backup-YYYY-MM-DD.sql

5. 自动备份（cron）:
   0 2 * * * sudo -u postgres pg_dump ${db_name} | gzip > /backup/ttrss-\$(date +\%F).sql.gz

安全提示
--------
⚠️  立即修改默认密码！
⚠️  定期备份数据库
⚠️  保护好数据库密码
⚠️  使用 HTTPS 访问
⚠️  定期更新 TTRSS: cd ${install_dir} && git pull
⚠️  监控服务状态
⚠️  限制并发任务避免资源耗尽
⚠️  定期清理日志: journalctl --vacuum-time=30d

更新 TTRSS
----------
1. 备份数据库和配置
2. 停止更新服务: systemctl stop tt-rss-update
3. 更新代码: cd ${install_dir} && sudo -u www-data git pull
4. 更新数据库: sudo -u www-data php update.php --update-schema
5. 重启服务: systemctl start tt-rss-update
6. 检查状态: systemctl status tt-rss-update

========================================
INFO
    
    chmod 600 "$install_dir/TTRSS-INFO.txt"
    
    echo ""
    print_success "Tiny Tiny RSS 安装完成！"
    echo ""
    echo "=========================================="
    cat "$install_dir/TTRSS-INFO.txt"
    echo "=========================================="
    echo ""
    print_warning "⚠️  重要：请立即访问 https://${domain} 并修改默认密码！"
    echo ""
    print_info "信息已保存到: $install_dir/TTRSS-INFO.txt"
    
    press_enter
}


# ============================================
# 安装 DokuWiki
# ============================================


install_dokuwiki() {
    clear
    echo "=========================================="
    echo "   安装 DokuWiki"
    echo "=========================================="
    echo ""
    
    check_root || return
    init_webserver_config
    ensure_tools
    
    # 检查依赖
    if ! check_dependencies "dokuwiki"; then
        press_enter
        return
    fi
    
    ensure_config_dirs
    
    # 配置参数
    read -p "域名 (如: wiki.example.com): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local install_dir="${WEB_ROOT}/${domain}"
    
    # 检查是否已存在
    if [ -d "$install_dir" ]; then
        echo ""
        print_warning "DokuWiki 已存在: $install_dir"
        echo -n "是否覆盖安装? (yes/no): "
        read -r overwrite
        if [[ "$overwrite" != "yes" ]]; then
            print_info "已取消"
            press_enter
            return
        fi
        
        # 询问是否备份数据
        if [ -d "$install_dir/data" ]; then
            echo -n "是否备份现有数据? (yes/no): "
            read -r backup_confirm
            if [[ "$backup_confirm" == "yes" ]]; then
                backup_site "$install_dir"
            fi
        fi
        
        # 删除旧配置
        remove_site "$domain"
    fi
    
    echo ""
    print_info "安装配置："
    echo "  Web 服务器: ${WEB_SERVER}"
    echo "  域名: ${domain}"
    echo "  目录: ${install_dir}"
    echo "  数据库: 无需数据库（使用文件存储）"
    echo ""
    
    read -p "确认安装？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 下载 DokuWiki
    echo ""
    print_info "[1/4] 下载 DokuWiki..."
    mkdir -p "$install_dir"
    cd /tmp
    wget -q --show-progress -O dokuwiki.tar.gz \
        "https://download.dokuwiki.org/src/dokuwiki/dokuwiki-stable.tgz"
    
    tar xzf dokuwiki.tar.gz -C "$install_dir" --strip-components=1
    rm dokuwiki.tar.gz
    
    # 设置权限
    print_info "[2/4] 设置权限..."
    chown -R www-data:www-data "$install_dir"
    chmod -R 755 "$install_dir"
    chmod -R 775 "$install_dir/data" "$install_dir/conf"
    
    # 生成 SSL 证书
    print_info "[3/4] 生成 SSL 证书..."
    local ssl_files=$(generate_ssl_cert "$domain")
    local ssl_cert=$(echo "$ssl_files" | cut -d: -f1)
    local ssl_key=$(echo "$ssl_files" | cut -d: -f2)
    
    # 创建 Nginx 配置
    print_info "[4/4] 配置 ${WEB_SERVER}..."
    cat > "${SITES_AVAIL}/${domain}.conf" << WIKICONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    
    root ${install_dir};
    index doku.php;
    
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    access_log /var/log/${WEB_SERVER}/${domain}.access.log;
    error_log /var/log/${WEB_SERVER}/${domain}.error.log;
    
    client_max_body_size 50M;
    
    # 安全加固：禁止访问敏感目录
    location ~ /(data|conf|bin|inc|vendor)/ {
        deny all;
    }
    
    location ~ /\.ht {
        deny all;
    }
    
    location / {
        try_files \$uri \$uri/ @dokuwiki;
    }
    
    location @dokuwiki {
        rewrite ^/_media/(.*) /lib/exe/fetch.php?media=\$1 last;
        rewrite ^/_detail/(.*) /lib/exe/detail.php?media=\$1 last;
        rewrite ^/_export/([^/]+)/(.*) /doku.php?do=export_\$1&id=\$2 last;
        rewrite ^/(.*) /doku.php?id=\$1&\$args last;
    }
    
    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass unix:${PHP_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param REDIRECT_STATUS 200;
    }
    
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 365d;
        add_header Cache-Control "public, immutable";
    }
}
WIKICONF
    
    # 创建日志目录
    mkdir -p "/var/log/${WEB_SERVER}"
    
    ln -sf "${SITES_AVAIL}/${domain}.conf" "${SITES_ENABLED}/"
    reload_webserver
    
    # 保存信息
    cat > "$install_dir/WIKI-INFO.txt" << INFO
DokuWiki 安装信息
=================
Web 服务器: ${WEB_SERVER}
域名: ${domain}
目录: ${install_dir}

访问地址
--------
前台: https://${domain}
安装向导: https://${domain}/install.php
管理面板: https://${domain}/?do=admin

配置文件
--------
${WEB_SERVER}: ${SITES_AVAIL}/${domain}.conf
SSL 证书: ${ssl_cert}
数据目录: ${install_dir}/data
配置目录: ${install_dir}/conf
主配置: ${install_dir}/conf/local.php

安装步骤
--------
1. 访问: https://${domain}/install.php
2. 完成 DokuWiki 初始化配置
   - 设置 Wiki 名称
   - 创建管理员账号
   - 配置 ACL 权限
3. 安装完成后删除 install.php:
   rm ${install_dir}/install.php

特性
----
- 无需数据库，使用文件存储
- 内置 ACL 权限管理系统
- 支持多种标记语法
- 版本控制和历史记录
- 丰富的插件和模板

管理命令
--------
查看日志: tail -f /var/log/${WEB_SERVER}/${domain}.access.log
备份数据: tar czf wiki-backup.tar.gz ${install_dir}/data ${install_dir}/conf
重启服务: systemctl reload ${SERVICE_NAME}

生成时间: $(date)
INFO
    
    chmod 600 "$install_dir/WIKI-INFO.txt"
    
    echo ""
    print_success "DokuWiki 安装完成！"
    echo ""
    cat "$install_dir/WIKI-INFO.txt"
    echo ""
    print_warning "⚠️  重要: 请立即访问 https://${domain}/install.php 完成初始化！"
    print_warning "⚠️  配置完成后务必删除 install.php 文件！"
    
    press_enter
}


# ============================================
# 配置 Rclone 挂载
# ============================================

install_rclone() {
    clear
    echo "=========================================="
    echo "   配置 Rclone 挂载"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    # 检查是否在 LXC 容器中
    local in_lxc=false
    local container_name=""
    
    if [ -f "/proc/1/environ" ] && grep -qa "container=lxc" /proc/1/environ 2>/dev/null; then
        in_lxc=true
    elif grep -q "lxc" /proc/1/cgroup 2>/dev/null; then
        in_lxc=true
    fi
    
    # 尝试获取容器名称
    if [ "$in_lxc" = true ]; then
        container_name=$(hostname)
    fi
    
    if [ "$in_lxc" = true ]; then
        print_warning "检测到 LXC 容器环境: ${container_name}"
        echo ""
        print_info "原生 LXC 容器使用 FUSE 需要在宿主机上配置："
        echo ""
        echo "1. 编辑容器配置文件（在宿主机执行）："
        echo "   ${GREEN}vim /var/lib/lxc/${container_name}/config${NC}"
        echo ""
        echo "2. 添加以下配置行："
        echo "   ${CYAN}lxc.apparmor.profile = unconfined${NC}"
        echo "   ${CYAN}lxc.cgroup2.devices.allow = c 10:229 rwm${NC}"
        echo "   ${CYAN}lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file 0 0${NC}"
        echo ""
        echo "   或者更简单的方式（允许所有设备）："
        echo "   ${CYAN}lxc.apparmor.profile = unconfined${NC}"
        echo "   ${CYAN}lxc.cgroup2.devices.allow = a${NC}"
        echo ""
        echo "3. 重启容器（在宿主机执行）："
        echo "   ${GREEN}lxc-stop -n ${container_name}${NC}"
        echo "   ${GREEN}lxc-start -n ${container_name}${NC}"
        echo ""
        echo "4. 验证（在容器内执行）："
        echo "   ${CYAN}ls -l /dev/fuse${NC}"
        echo ""
        print_warning "注意：必须重启容器才能生效！"
        echo ""
        
        # 检查 /dev/fuse 是否存在
        if [ ! -e "/dev/fuse" ]; then
            print_error "/dev/fuse 设备不存在"
            echo ""
            print_info "这表明宿主机尚未为此容器启用 FUSE"
            echo ""
            print_info "完整配置示例（在宿主机 /var/lib/lxc/${container_name}/config 中）："
            cat << 'LXCCONFIG'
# FUSE 支持
lxc.apparmor.profile = unconfined
lxc.cgroup2.devices.allow = c 10:229 rwm
lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file 0 0

# 或者允许所有设备（更简单但安全性稍低）
# lxc.apparmor.profile = unconfined
# lxc.cgroup2.devices.allow = a
LXCCONFIG
            echo ""
            read -p "是否已在宿主机上配置 FUSE？[y/N]: " fuse_configured
            if [[ ! "$fuse_configured" =~ ^[Yy]$ ]]; then
                print_info "请先在宿主机上配置 FUSE，然后重新运行此脚本"
                echo ""
                print_info "快速操作（在宿主机执行）："
                echo "  1. 编辑配置: vim /var/lib/lxc/${container_name}/config"
                echo "  2. 添加上述 FUSE 配置"
                echo "  3. 重启容器: lxc-stop -n ${container_name} && lxc-start -n ${container_name}"
                echo "  4. 进入容器: lxc-attach -n ${container_name}"
                echo "  5. 验证设备: ls -l /dev/fuse"
                press_enter
                return
            fi
        else
            print_success "/dev/fuse 设备存在"
            ls -l /dev/fuse
            echo ""
            print_success "LXC FUSE 配置正确"
        fi
    fi
    
    # 检查并安装依赖
    echo ""
    print_info "检查依赖..."
    
    # 安装 fuse3
    if ! command -v fusermount3 >/dev/null 2>&1; then
        print_info "安装 fuse3..."
        apt-get update -qq && apt-get install -y fuse3
    else
        print_success "fuse3 已安装"
    fi
    
    # 检查并加载 FUSE 内核模块
    print_info "检查 FUSE 内核模块..."
    if ! lsmod | grep -q "^fuse" && ! grep -q "fuse" /proc/filesystems 2>/dev/null; then
        print_warning "FUSE 内核模块未加载"
        
        if [ "$in_lxc" = true ]; then
            print_info "LXC 容器中 FUSE 模块由宿主机管理"
            
            # 检查 /dev/fuse 是否可用
            if [ -c "/dev/fuse" ]; then
                print_success "FUSE 设备可用"
            else
                print_error "FUSE 设备不可用"
                echo ""
                print_info "请在宿主机上确保 FUSE 模块已加载："
                echo "  sudo modprobe fuse"
                echo "  echo 'fuse' >> /etc/modules"
                echo ""
                print_info "然后配置容器（见上面的配置说明）"
                echo ""
                read -p "是否继续尝试？[y/N]: " continue_anyway
                if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                    press_enter
                    return
                fi
            fi
        else
            print_info "加载 FUSE 模块..."
            if modprobe fuse 2>/dev/null; then
                print_success "FUSE 模块加载成功"
            else
                print_error "无法加载 FUSE 模块"
                press_enter
                return
            fi
        fi
    else
        print_success "FUSE 可用"
    fi
    
    # 验证 FUSE 设备
    if [ ! -e "/dev/fuse" ]; then
        print_error "/dev/fuse 设备不存在"
        
        if [ "$in_lxc" = true ]; then
            echo ""
            print_error "LXC 容器未正确配置 FUSE"
            echo ""
            print_info "在宿主机编辑: /var/lib/lxc/${container_name}/config"
            echo ""
            echo "添加以下行："
            echo "  lxc.apparmor.profile = unconfined"
            echo "  lxc.cgroup2.devices.allow = c 10:229 rwm"
            echo "  lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file 0 0"
            echo ""
            echo "然后重启容器:"
            echo "  lxc-stop -n ${container_name}"
            echo "  lxc-start -n ${container_name}"
            echo ""
            print_warning "必须重启容器！"
            press_enter
            return
        else
            print_info "尝试创建 FUSE 设备..."
            if mknod /dev/fuse c 10 229 2>/dev/null; then
                chmod 666 /dev/fuse
                print_success "FUSE 设备创建成功"
            else
                print_error "无法创建 FUSE 设备"
                press_enter
                return
            fi
        fi
    else
        print_success "FUSE 设备存在: /dev/fuse"
        
        # 检查设备权限
        local fuse_perms=$(ls -l /dev/fuse | awk '{print $1}')
        echo "  权限: $fuse_perms"
        if [[ "$fuse_perms" =~ rw.*rw ]]; then
            print_success "FUSE 设备权限正常"
        else
            print_warning "FUSE 设备权限可能不足，尝试修复..."
            chmod 666 /dev/fuse 2>/dev/null || true
        fi
    fi
    
    # 配置 FUSE 模块开机自动加载（非 LXC 环境）
    if [ "$in_lxc" = false ]; then
        if ! grep -q "^fuse$" /etc/modules 2>/dev/null; then
            print_info "配置 FUSE 模块开机自动加载..."
            echo "fuse" >> /etc/modules
            print_success "已添加到 /etc/modules"
        fi
    fi
    
    # 安装 rclone
    if ! command -v rclone >/dev/null 2>&1; then
        print_info "安装 rclone..."
        cd /tmp
        rm -rf rclone-*
        wget -q --show-progress https://downloads.rclone.org/rclone-current-linux-amd64.zip
        unzip -q rclone-current-linux-amd64.zip
        cd rclone-*-linux-amd64
        cp rclone /usr/bin/
        chown root:root /usr/bin/rclone
        chmod 755 /usr/bin/rclone
        cd /tmp
        rm -rf rclone-*
        print_success "rclone 已安装"
    else
        local rclone_version=$(rclone version | head -1 | awk '{print $2}')
        print_success "rclone 已安装 (${rclone_version})"
    fi
    
    # 检查 Supervisor
    if ! command -v supervisorctl >/dev/null 2>&1; then
        print_warning "Supervisor 未安装"
        echo ""
        read -p "是否安装 Supervisor？[Y/n]: " install_supervisor
        if [[ ! "$install_supervisor" =~ ^[Nn]$ ]]; then
            print_info "安装 Supervisor..."
            apt-get update -qq && apt-get install -y supervisor
            systemctl enable supervisor
            systemctl start supervisor
            print_success "Supervisor 已安装"
        else
            print_warning "跳过 Supervisor 安装，将无法自动启动挂载"
        fi
    else
        print_success "Supervisor 已安装"
    fi
    
    # 配置 fuse.conf
    if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
        print_info "配置 FUSE..."
        echo "user_allow_other" >> /etc/fuse.conf
        print_success "FUSE 配置完成"
    else
        print_success "FUSE 已配置"
    fi
    
    # 测试 FUSE 是否真的可用
    echo ""
    print_info "测试 FUSE 功能..."
    if timeout 5 fusermount3 --version >/dev/null 2>&1; then
        print_success "fusermount3 工作正常"
    else
        print_warning "fusermount3 测试超时或失败"
    fi
    
    # 配置参数
    echo ""
    print_info "Rclone 挂载配置"
    echo ""
    
    # 检查是否已有 rclone 配置
    if [ -f "/root/.config/rclone/rclone.conf" ]; then
        print_info "检测到现有 rclone 配置"
        echo ""
        rclone listremotes
        echo ""
    else
        print_warning "未检测到 rclone 配置"
        echo ""
        print_info "请先运行以下命令配置远程存储："
        echo "  rclone config"
        echo ""
        read -p "是否现在配置？[Y/n]: " config_now
        if [[ ! "$config_now" =~ ^[Nn]$ ]]; then
            rclone config
        else
            print_info "已取消，请稍后运行 'rclone config' 配置"
            press_enter
            return
        fi
    fi
    
    # 输入配置参数
    echo ""
    read -p "远程名称 (如: onedrive): " remote_name
    if [ -z "$remote_name" ]; then
        print_error "远程名称不能为空"
        press_enter
        return
    fi
    
    # 验证远程是否存在
    if ! rclone listremotes | grep -q "^${remote_name}:$"; then
        print_error "远程 '${remote_name}' 不存在"
        echo ""
        print_info "可用的远程："
        rclone listremotes
        press_enter
        return
    fi
    
    read -p "远程路径 (默认: /，根目录): " remote_path
    remote_path=${remote_path:-/}
    
    read -p "本地挂载点 (默认: /mnt/${remote_name}): " mount_point
    mount_point=${mount_point:-/mnt/${remote_name}}
    
    read -p "缓存目录 (默认: /data/rclone-cache/${remote_name}): " cache_dir
    cache_dir=${cache_dir:-/data/rclone-cache/${remote_name}}
    
    read -p "缓存大小 (默认: 2G): " cache_size
    cache_size=${cache_size:-2G}
    
    read -p "读取块大小 (默认: 16M): " chunk_size
    chunk_size=${chunk_size:-16M}
    
    # 创建目录
    print_info "创建目录..."
    mkdir -p "$mount_point"
    mkdir -p "$cache_dir"
    
    # 获取 www-data UID/GID
    local WWW_UID=$(id -u www-data 2>/dev/null || echo "33")
    local WWW_GID=$(id -g www-data 2>/dev/null || echo "33")
    
    # 设置缓存目录权限
    chown -R www-data:www-data "$cache_dir"
    chmod -R 755 "$cache_dir"
    
    print_success "目录创建完成"
    
    # 构建 rclone 命令
    local RCLONE_CMD="/usr/bin/rclone mount ${remote_name}:${remote_path} ${mount_point} \
--vfs-cache-mode full \
--vfs-cache-max-age 24h \
--vfs-cache-max-size 2G \
--buffer-size 256M \
--vfs-read-chunk-size 64M \
--vfs-read-chunk-streams 8 \
--allow-other \
--dir-cache-time 24h \
--poll-interval 1m \
--attr-timeout 24h \
--uid=33 \
--gid=33 \
--umask 002"
    
    echo ""
    print_info "挂载配置："
    echo "  环境: $([ "$in_lxc" = true ] && echo "LXC 容器 (${container_name})" || echo '物理机/虚拟机')"
    echo "  远程: ${remote_name}:${remote_path}"
    echo "  挂载点: ${mount_point}"
    echo "  UID/GID: 33/33 (www-data)"
    echo "  缓存模式: full (完整缓存)"
    echo "  缓存大小: 2G"
    echo "  缓存时间: 24h"
    echo "  读取块: 64M (8 streams)"
    echo "  缓冲区: 256M"
    echo ""
    
    read -p "确认配置？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 测试挂载
    echo ""
    print_info "测试挂载连接..."
    if timeout 30 rclone lsd "${remote_name}:${remote_path}" >/dev/null 2>&1; then
        print_success "远程连接正常"
    else
        print_error "无法连接到远程存储"
        echo ""
        print_info "请检查："
        echo "  1. rclone 配置是否正确: rclone config"
        echo "  2. 网络连接是否正常"
        echo "  3. 远程路径是否存在: rclone lsd ${remote_name}:"
        echo ""
        read -p "是否继续？[y/N]: " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi
    
    # 创建 Supervisor 配置
    if command -v supervisorctl >/dev/null 2>&1; then
        print_info "配置 Supervisor..."
        
        local service_name="rclone-${remote_name}"
        local supervisor_conf="/etc/supervisor/conf.d/${service_name}.conf"
        
        cat > "$supervisor_conf" << SUPERVISORCONF
[program:${service_name}]
command=${RCLONE_CMD}
autostart=true
autorestart=true
user=root
redirect_stderr=true
stdout_logfile=/var/log/supervisor/${service_name}.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
startsecs=10
startretries=3
SUPERVISORCONF
        
        print_success "Supervisor 配置完成"
        
        # 重载并启动
        print_info "启动 rclone 挂载..."
        supervisorctl reread
        supervisorctl update
        sleep 5
        
        # 检查状态
        if supervisorctl status "$service_name" | grep -q "RUNNING"; then
            print_success "rclone 挂载已启动"
            
            # 验证挂载点
            sleep 2
            if mountpoint -q "$mount_point" 2>/dev/null; then
                print_success "挂载点验证成功: $mount_point"
                echo ""
                print_info "挂载内容："
                timeout 10 ls -lh "$mount_point" 2>/dev/null | head -10 || echo "列出内容超时或为空"
            else
                print_warning "挂载点验证失败"
                echo ""
                print_info "查看日志："
                echo "  tail -30 /var/log/supervisor/${service_name}.log"
                echo ""
                tail -30 "/var/log/supervisor/${service_name}.log" 2>/dev/null || true
            fi
        else
            print_error "rclone 挂载启动失败"
            echo ""
            print_info "查看状态："
            supervisorctl status "$service_name"
            echo ""
            print_info "查看日志："
            echo "  tail -f /var/log/supervisor/${service_name}.log"
            echo ""
            if [ -f "/var/log/supervisor/${service_name}.log" ]; then
                tail -30 "/var/log/supervisor/${service_name}.log"
            fi
            echo ""
            print_info "手动测试挂载："
            echo "  ${RCLONE_CMD} --verbose"
        fi
    else
        print_warning "Supervisor 未安装，无法自动启动"
        echo ""
        print_info "手动挂载命令："
        echo "  ${RCLONE_CMD} --verbose"
    fi
    
    # 保存信息
    local info_file="/root/rclone-${remote_name}-info.txt"
    cat > "$info_file" << INFO
========================================
Rclone 挂载信息
========================================

配置时间: $(date)
运行环境: $([ "$in_lxc" = true ] && echo "LXC 容器 (${container_name})" || echo '物理机/虚拟机')

$([ "$in_lxc" = true ] && cat << LXC_INFO

LXC 容器配置（Debian 原生 LXC）
--------------------------------
配置文件位置（在宿主机）: /var/lib/lxc/${container_name}/config

必需的配置行:
  lxc.apparmor.profile = unconfined
  lxc.cgroup2.devices.allow = c 10:229 rwm
  lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file 0 0

或者更简单（允许所有设备）:
  lxc.apparmor.profile = unconfined
  lxc.cgroup2.devices.allow = a

修改配置后必须重启容器（在宿主机）:
  lxc-stop -n ${container_name}
  lxc-start -n ${container_name}

验证配置（在容器内）:
  ls -l /dev/fuse

宿主机管理命令:
  列出容器: lxc-ls -f
  进入容器: lxc-attach -n ${container_name}
  查看配置: cat /var/lib/lxc/${container_name}/config
  容器日志: journalctl -u lxc@${container_name}

LXC_INFO
)

挂载配置
--------
远程名称: ${remote_name}
远程路径: ${remote_path}
本地挂载点: ${mount_point}
缓存目录: ${cache_dir}
缓存大小: ${cache_size}
读取块大小: ${chunk_size}
缓存模式: full (完整缓存)

权限配置
--------
UID: ${WWW_UID} (www-data)
GID: ${WWW_GID} (www-data)
umask: 002

Supervisor 服务
---------------
服务名: rclone-${remote_name}
配置文件: /etc/supervisor/conf.d/rclone-${remote_name}.conf
日志文件: /var/log/supervisor/rclone-${remote_name}.log

管理命令
--------
查看状态:
  supervisorctl status rclone-${remote_name}

启动服务:
  supervisorctl start rclone-${remote_name}

停止服务:
  supervisorctl stop rclone-${remote_name}

重启服务:
  supervisorctl restart rclone-${remote_name}

查看日志（实时）:
  tail -f /var/log/supervisor/rclone-${remote_name}.log

查看日志（最近）:
  tail -100 /var/log/supervisor/rclone-${remote_name}.log

手动挂载命令（调试用）:
  ${RCLONE_CMD} --verbose

手动卸载:
  fusermount -u ${mount_point}
  或
  fusermount3 -u ${mount_point}

检查挂载
--------
验证挂载点:
  mountpoint ${mount_point}

查看挂载内容:
  ls -lh ${mount_point}

测试读取:
  rclone lsd ${remote_name}:${remote_path}

检查 FUSE 设备:
  ls -l /dev/fuse
  lsmod | grep fuse
  grep fuse /proc/filesystems

缓存管理
--------
查看缓存大小:
  du -sh ${cache_dir}

清理缓存:
  rm -rf ${cache_dir}/*
  supervisorctl restart rclone-${remote_name}

Rclone 配置
-----------
配置文件: /root/.config/rclone/rclone.conf

查看所有远程:
  rclone listremotes

编辑配置:
  rclone config

测试连接:
  rclone lsd ${remote_name}:

性能优化建议
------------
当前配置已优化为高性能模式:
  • 缓存模式: full (完整缓存)
  • 缓存大小: 2G
  • 缓存时间: 24h (目录/属性)
  • 读取块: 64M × 8 streams (并行读取)
  • 缓冲区: 256M

如需调整参数:
1. 编辑配置文件:
   nano /etc/supervisor/conf.d/rclone-${remote_name}.conf

2. 修改 command 行中的参数:
   --vfs-cache-max-size 2G        # 缓存大小
   --vfs-read-chunk-size 64M      # 读取块大小
   --buffer-size 256M             # 缓冲区大小

3. 重启服务:
   supervisorctl reread && supervisorctl restart rclone-${remote_name}

4. 监控资源使用:
   top -p \$(pgrep rclone)
   watch -n 1 du -sh /var/cache/rclone

故障排查
--------
$([ "$in_lxc" = true ] && cat << LXC_TROUBLESHOOT

LXC 容器特定问题（Debian 原生 LXC）:
  
  1. FUSE 设备不存在:
     在宿主机编辑: /var/lib/lxc/${container_name}/config
     添加上述配置行
     重启容器: lxc-stop -n ${container_name} && lxc-start -n ${container_name}
  
  2. 挂载失败 "fuse device not found":
     检查 /dev/fuse 是否存在: ls -l /dev/fuse
     确认容器已重启生效
     在宿主机检查配置: cat /var/lib/lxc/${container_name}/config | grep -E "fuse|devices"
  
  3. 权限被拒绝:
     确认已添加: lxc.apparmor.profile = unconfined
     确认已添加: lxc.cgroup2.devices.allow = c 10:229 rwm
  
  4. 宿主机 FUSE 模块:
     在宿主机加载: modprobe fuse
     开机自动加载: echo 'fuse' >> /etc/modules

LXC_TROUBLESHOOT
)

如果挂载失败:
  1. 检查日志: tail -f /var/log/supervisor/rclone-${remote_name}.log
  2. 验证配置: rclone config show
  3. 测试连接: rclone lsd ${remote_name}:
  4. 手动挂载: ${RCLONE_CMD} --verbose
  5. 检查 FUSE: ls -l /dev/fuse

如果性能慢:
  1. 检查网络: ping -c 5 8.8.8.8
  2. 检查缓存: du -sh /var/cache/rclone
  3. 当前已使用高性能配置 (2G缓存, 64M×8并行读取)
  4. 可考虑增大缓存: --vfs-cache-max-size 4G

如果无法写入:
  1. 检查缓存模式: 当前已使用 --vfs-cache-mode full
  2. 检查权限: ls -ld ${mount_point}
  3. 检查 uid/gid: 当前使用 33/33 (www-data)

卸载服务
--------
1. 停止服务:
   supervisorctl stop rclone-${remote_name}

2. 卸载挂载点:
   fusermount -u ${mount_point}

3. 删除配置:
   rm /etc/supervisor/conf.d/rclone-${remote_name}.conf
   supervisorctl reread

4. 清理缓存（可选）:
   rm -rf ${cache_dir}

5. 删除挂载点（可选）:
   rmdir ${mount_point}

安全提示
--------
⚠️  rclone.conf 包含敏感信息，请妥善保管
⚠️  定期检查缓存大小，避免磁盘占满
⚠️  使用 HTTPS 传输确保数据安全
⚠️  定期更新 rclone 到最新版本
$([ "$in_lxc" = true ] && echo "⚠️  LXC 容器备份前请先卸载 rclone")

更新 rclone
-----------
cd /tmp
wget https://downloads.rclone.org/rclone-current-linux-amd64.zip
unzip -q rclone-current-linux-amd64.zip
cd rclone-*-linux-amd64
cp rclone /usr/bin/
supervisorctl restart rclone-${remote_name}

========================================
INFO
    
    chmod 600 "$info_file"
    
    echo ""
    print_success "Rclone 挂载配置完成！"
    echo ""
    echo "=========================================="
    cat "$info_file"
    echo "=========================================="
    echo ""
    print_info "信息已保存到: $info_file"
    
    # 显示 FUSE 状态
    echo ""
    print_info "FUSE 状态检查："
    echo "  运行环境: $([ "$in_lxc" = true ] && echo "LXC 容器 (${container_name})" || echo '物理机/虚拟机')"
    echo "  设备文件: $(ls -l /dev/fuse 2>/dev/null | awk '{print $1, $5, $6}' || echo '不存在')"
    echo "  fusermount: $(which fusermount3 2>/dev/null || echo '未安装')"
    
    if [ "$in_lxc" = true ]; then
        echo ""
        print_warning "LXC 提示：如遇问题，请在宿主机确认："
        echo "  cat /var/lib/lxc/${container_name}/config | grep -E 'fuse|devices|apparmor'"
    fi
    
    press_enter
}



# ============================================
# 安装 Copyparty 文件服务器
# ============================================

install_copyparty() {
    clear
    echo "=========================================="
    echo "   安装 Copyparty 文件服务器"
    echo "=========================================="
    echo ""
    
    check_root || return
    init_webserver_config
    ensure_tools
    
    # 检查 Web 服务器
    if [ "$WEB_SERVER" = "none" ]; then
        print_error "未检测到 Web 服务器 (Nginx/OpenResty)"
        echo ""
        print_info "Copyparty 需要反向代理，请先安装 Web 服务器"
        press_enter
        return
    fi
    
    ensure_config_dirs
    
    # 检查 Python3
    if ! command -v python3 &> /dev/null; then
        print_warning "Python3 未安装"
        read -p "是否安装 Python3？[Y/n]: " install_python
        if [[ ! "$install_python" =~ ^[Nn]$ ]]; then
            apt-get update -qq && apt-get install -y python3 python3-pip
        else
            print_error "Python3 是必需的"
            press_enter
            return
        fi
    fi
    
    # 检查 Supervisor
    if ! command -v supervisorctl >/dev/null 2>&1; then
        print_warning "Supervisor 未安装"
        read -p "是否安装 Supervisor？[Y/n]: " install_supervisor
        if [[ ! "$install_supervisor" =~ ^[Nn]$ ]]; then
            apt-get update -qq && apt-get install -y supervisor
            systemctl enable supervisor
            systemctl start supervisor
        else
            print_error "Supervisor 是必需的"
            press_enter
            return
        fi
    fi
    
    # 配置参数
    echo ""
    read -p "域名 (如: files.example.com): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local install_dir="${WEB_ROOT}/copyparty"
    local data_dir="/data/copyparty"
    local cache_dir="/var/cache/copyparty"
    local share_dir="/mnt"
    local listen_port="3923"
    local admin_user="admin"
    local admin_pass=""
    
    # 检查是否已存在
    if [ -d "$install_dir" ]; then
        echo ""
        print_warning "Copyparty 已安装在: $install_dir"
        echo -n "是否覆盖安装? (yes/no): "
        read -r overwrite
        if [[ "$overwrite" != "yes" ]]; then
            print_info "已取消"
            press_enter
            return
        fi
        
        # 停止服务
        supervisorctl stop copyparty 2>/dev/null || true
        
        # 备份
        backup_site "$install_dir"
        
        # 删除旧配置
        remove_site "$domain"
        rm -rf "$install_dir"
        rm -f /etc/supervisor/conf.d/copyparty.conf
    fi
    
    # 配置参数
    echo ""
    print_info "Copyparty 配置"
    
    read -p "数据目录 (默认: ${data_dir}): " custom_data_dir
    data_dir=${custom_data_dir:-$data_dir}
    
    read -p "缓存目录 (默认: ${cache_dir}): " custom_cache_dir
    cache_dir=${custom_cache_dir:-$cache_dir}
    
    read -p "共享目录 (默认: ${share_dir}): " custom_share_dir
    share_dir=${custom_share_dir:-$share_dir}
    
    read -p "监听端口 (默认: ${listen_port}): " custom_port
    listen_port=${custom_port:-$listen_port}
    
    read -p "管理员用户名 (默认: ${admin_user}): " custom_admin
    admin_user=${custom_admin:-$admin_user}
    
    read -sp "管理员密码 (留空自动生成): " admin_pass
    echo ""
    
    if [ -z "$admin_pass" ]; then
        admin_pass=$(generate_password 12)
        print_info "生成的密码: $admin_pass"
    fi
    
    echo ""
    print_info "安装配置："
    echo "  Web 服务器: ${WEB_SERVER}"
    echo "  域名: ${domain}"
    echo "  安装目录: ${install_dir}"
    echo "  数据目录: ${data_dir}"
    echo "  缓存目录: ${cache_dir}"
    echo "  共享目录: ${share_dir}"
    echo "  监听端口: ${listen_port}"
    echo "  管理员: ${admin_user}"
    echo ""
    
    read -p "确认安装？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 安装依赖
    echo ""
    print_info "[1/7] 安装依赖..."
    apt-get update -qq
    apt-get install -y ffmpeg python3-mutagen python3-pillow
    print_success "依赖安装完成"
    
    # 创建目录
    print_info "[2/7] 创建目录..."
    mkdir -p "$install_dir"
    mkdir -p "$data_dir"
    mkdir -p "$cache_dir"
    mkdir -p "$share_dir"
    
    chown -R www-data:www-data "$data_dir"
    chown -R www-data:www-data "$cache_dir"
    chmod -R 755 "$data_dir"
    chmod -R 755 "$cache_dir"
    
    print_success "目录创建完成"
    
    # 下载 Copyparty
    print_info "[3/7] 下载 Copyparty..."
    cd /tmp
    rm -f copyparty.py
    
    if wget -q --show-progress "https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py" -O copyparty.py; then
        if [ ! -s "copyparty.py" ]; then
            print_error "下载的文件为空"
            press_enter
            return
        fi
        
        mv copyparty.py "${install_dir}/"
        chmod +x "${install_dir}/copyparty.py"
        chown -R www-data:www-data "$install_dir"
        print_success "Copyparty 下载完成"
    else
        print_error "下载失败"
        press_enter
        return
    fi
    
    # 创建配置文件
    print_info "[4/7] 创建配置文件..."
    
    # 创建配置目录
    mkdir -p /etc/copyparty
    
    # 创建配置文件（使用明文密码）
    cat > /etc/copyparty/copyparty.conf << COPYCONF
# Copyparty 配置文件
# 官方文档: https://github.com/9001/copyparty

[global]
  # 监听地址和端口（反向代理模式）
  i: 127.0.0.1
  p: ${listen_port}
  rproxy: -1

  # 数据库和缓存位置
  hist: ${cache_dir}

  # 缩略图配置
  no-vthumb

  # 缩略图缓存清理：每12小时运行一次，删除30天未使用的缩略图
  th-clean: 43200
  th-maxage: 2592000

  # 启用索引和媒体标签扫描
  e2d
  e2ts

  # 标签扫描配置
  mtag-mt: 2
  mtag-to: 10

  # 文件系统重扫描和数据库调度
  re-maxage: 0
  db-act: 60

  # 并发配置
  j: 4
  nc: 128
  th-mt: 4

  # 功能开关（性能优化）
  no-dhash
  no-acode
  no-voldump
  no-dirsz
  no-clone
  no-scandir

  # 禁用文件哈希
  no-hash: .*

[accounts]
  ${admin_user}: ${admin_pass}

[/]
  # Web "/" 映射到文件系统 ${share_dir}
  ${share_dir}
  accs:
    A: ${admin_user}
COPYCONF

    chown root:www-data /etc/copyparty/copyparty.conf
    chmod 640 /etc/copyparty/copyparty.conf  # root 可读写，www-data 可读
    print_success "配置文件创建完成: /etc/copyparty/copyparty.conf"
    
    # 创建 Supervisor 配置
    print_info "[5/7] 配置 Supervisor..."
    
    cat > /etc/supervisor/conf.d/copyparty.conf << SUPCONF
[program:copyparty]
command=/usr/bin/nice -n 10 /usr/bin/python3 ${install_dir}/copyparty.py -c /etc/copyparty/copyparty.conf
directory=${install_dir}
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=/var/log/supervisor/copyparty.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
environment=PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
startsecs=10
startretries=3
SUPCONF
    
    supervisorctl reread
    supervisorctl update
    print_success "Supervisor 配置完成"
    
    # 生成 SSL 证书
    print_info "[6/7] 生成 SSL 证书..."
    local ssl_files=$(generate_ssl_cert "$domain")
    local ssl_cert=$(echo "$ssl_files" | cut -d: -f1)
    local ssl_key=$(echo "$ssl_files" | cut -d: -f2)
    
    # 创建 Nginx 反向代理配置
    print_info "[7/7] 配置 ${WEB_SERVER}..."
    cat > "${SITES_AVAIL}/${domain}.conf" << COPYPROXYCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    access_log /var/log/${WEB_SERVER}/${domain}.access.log;
    error_log /var/log/${WEB_SERVER}/${domain}.error.log;
    
    # 增加超时和缓冲区大小
    client_max_body_size 10G;
    client_body_buffer_size 512k;
    
    proxy_connect_timeout 600;
    proxy_send_timeout 600;
    proxy_read_timeout 600;
    send_timeout 600;
    
    proxy_buffering off;
    proxy_request_buffering off;
    
    location / {
        proxy_pass http://127.0.0.1:${listen_port};
        proxy_http_version 1.1;
        
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket 支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 防止代理缓存
        proxy_cache_bypass \$http_upgrade;
    }
    
    # 静态资源缓存
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://127.0.0.1:${listen_port};
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
COPYPROXYCONF
    
    mkdir -p "/var/log/${WEB_SERVER}"
    ln -sf "${SITES_AVAIL}/${domain}.conf" "${SITES_ENABLED}/"
    reload_webserver
    
    # 启动服务
    print_info "启动 Copyparty..."
    sleep 3
    
    if supervisorctl status copyparty | grep -q "RUNNING"; then
        print_success "Copyparty 已启动"
    else
        print_warning "Copyparty 启动可能失败，请检查日志"
        echo ""
        print_info "查看日志："
        echo "  tail -30 /var/log/supervisor/copyparty.log"
        if [ -f "/var/log/supervisor/copyparty.log" ]; then
            echo ""
            tail -30 /var/log/supervisor/copyparty.log
        fi
    fi
    
    # 保存信息
    cat > "${install_dir}/COPYPARTY-INFO.txt" << INFO
========================================
Copyparty 文件服务器安装信息
========================================

安装时间: $(date)

Web 配置
--------
Web 服务器: ${WEB_SERVER}
域名: ${domain}
访问地址: https://${domain}
安装目录: ${install_dir}

服务配置
--------
监听地址: 127.0.0.1:${listen_port}
数据目录: ${data_dir}
缓存目录: ${cache_dir}
共享目录: ${share_dir}

管理员账号
----------
用户名: ${admin_user}
密码: ${admin_pass}
⚠️  请妥善保管密码！

权限配置
--------
管理员权限: A (完全控制，包括删除/移动)
共享目录权限: ${admin_user} 拥有完全访问权限

性能优化
--------
✓ 禁用缩略图生成 (--no-thumb)
✓ 禁用文件哈希 (--no-hash)
✓ 禁用 scandir (--no-scandir)
✓ 最小化数据库写入 (--db-act 0)
✓ 高并发支持 (-j 16, -nc 64)
✓ 降低 CPU 优先级 (nice -n 10)
✓ 禁用代理缓存 (proxy_buffering off)

配置文件
--------
Copyparty 主程序: ${install_dir}/copyparty.py
Copyparty 配置: /etc/copyparty/copyparty.conf
Supervisor 配置: /etc/supervisor/conf.d/copyparty.conf
Web 服务器配置: ${SITES_AVAIL}/${domain}.conf
SSL 证书: ${ssl_cert}
SSL 密钥: ${ssl_key}

日志文件
--------
Copyparty: /var/log/supervisor/copyparty.log
Web 访问: /var/log/${WEB_SERVER}/${domain}.access.log
Web 错误: /var/log/${WEB_SERVER}/${domain}.error.log

管理命令
--------
查看服务状态:
  supervisorctl status copyparty

启动服务:
  supervisorctl start copyparty

停止服务:
  supervisorctl stop copyparty

重启服务:
  supervisorctl restart copyparty

查看日志（实时）:
  tail -f /var/log/supervisor/copyparty.log

查看日志（最近）:
  tail -100 /var/log/supervisor/copyparty.log

重启 Web 服务:
  systemctl reload ${SERVICE_NAME}

功能说明
--------
1. 管理员拥有完全控制权（上传、下载、删除、移动）
2. 支持文件上传、下载、在线预览
3. 支持音频/视频/图片预览（需 FFmpeg）
4. 支持文件搜索和标签
5. 支持文件分享链接
6. 支持批量操作
7. 零 IO 优化，适合挂载的网络存储

使用指南
--------
1. 访问 https://${domain}
2. 使用管理员账号登录
3. 上传/管理文件
4. 创建分享链接
5. 设置文件权限

命令行参数说明
--------------
-i 127.0.0.1        # 监听本地（通过反向代理访问）
-p ${listen_port}            # 监听端口
-a ${admin_user}:xxx        # 管理员账号
-v ${share_dir}::A,${admin_user}  # 挂载点和权限（A=完全控制）
-e2d                # 启用 2D 编码
-e2ts               # 启用时间戳
--hist ${cache_dir}  # 历史记录目录
-j 16               # 并发 Web 线程
-nc 64              # 网络连接数
--no-acode          # 禁用音频编码
--rproxy -1         # 反向代理模式
--no-voldump        # 禁用卷转储
--no-thumb          # 禁用缩略图（性能优化）
--no-hash .*        # 禁用文件哈希（性能优化）
--no-clone          # 禁用克隆
--no-scandir        # 禁用 scandir（FUSE 优化）
--db-act 0          # 最小化数据库活动

性能调优建议
------------
1. 增加并发:
   修改 -j 和 -nc 参数

2. 启用缩略图（小文件）:
   移除 --no-thumb 参数

3. 启用文件哈希（去重）:
   移除 --no-hash 参数

4. 监控资源:
   top -u www-data
   htop -u www-data

5. 调整上传大小限制:
   编辑 Nginx 配置中的 client_max_body_size

故障排查
--------
如果无法访问:
  1. 检查服务: supervisorctl status copyparty
  2. 检查日志: tail -f /var/log/supervisor/copyparty.log
  3. 检查 Web 服务: systemctl status ${SERVICE_NAME}
  4. 检查端口: netstat -tlnp | grep ${listen_port}

如果上传失败:
  1. 检查磁盘空间: df -h
  2. 检查目录权限: ls -ld ${share_dir}
  3. 增大上传限制: client_max_body_size
  4. 检查超时设置

如果性能差:
  1. 检查缓存目录: du -sh ${cache_dir}
  2. 检查共享目录类型（本地/网络）
  3. 调整并发参数
  4. 查看资源使用: top -u www-data

如果预览失败:
  1. 检查 FFmpeg: ffmpeg -version
  2. 检查 Python 库: pip3 list | grep -E 'mutagen|pillow'
  3. 查看错误日志

修改配置
--------
编辑配置文件:
  nano /etc/copyparty/copyparty.conf

修改后重启服务:
  supervisorctl restart copyparty

配置文件说明:
  [global]     - 全局配置（端口、缓存、性能等）
  [accounts]   - 用户账号（用户名:明文密码）
  [/]          - 共享目录配置（路径和权限）

添加新用户:
  1. 编辑配置文件:
     nano /etc/copyparty/copyparty.conf
  
  2. 在 [accounts] 部分添加:
     newuser: newpassword
  
  3. 重启服务:
     supervisorctl restart copyparty

安全提示:
  - 配置文件权限为 640 (root:www-data)
  - root 可读写，www-data 仅可读
  - 建议使用强密码
  - 定期更换密码

更新 Copyparty
--------------
cd /tmp
wget https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py -O copyparty.py
supervisorctl stop copyparty
mv copyparty.py ${install_dir}/
chmod +x ${install_dir}/copyparty.py
chown www-data:www-data ${install_dir}/copyparty.py
supervisorctl start copyparty

卸载服务
--------
1. 停止服务:
   supervisorctl stop copyparty

2. 删除配置:
   rm /etc/supervisor/conf.d/copyparty.conf
   supervisorctl reread
   supervisorctl update

3. 删除 Web 配置:
   rm ${SITES_ENABLED}/${domain}.conf
   rm ${SITES_AVAIL}/${domain}.conf
   systemctl reload ${SERVICE_NAME}

4. 删除文件（可选）:
   rm -rf ${install_dir}
   rm -rf ${cache_dir}

5. 保留数据（可选）:
   ${data_dir}
   ${share_dir}

安全提示
--------
⚠️  修改默认管理员密码
⚠️  定期备份数据
⚠️  限制访问 IP（可选）
⚠️  使用强密码
⚠️  定期更新 Copyparty
⚠️  监控磁盘使用

参考资源
--------
官方文档: https://github.com/9001/copyparty
Wiki: https://github.com/9001/copyparty/blob/hovudstraum/docs/README.md

========================================
INFO
    
    chmod 600 "${install_dir}/COPYPARTY-INFO.txt"
    
    echo ""
    print_success "Copyparty 安装完成！"
    echo ""
    echo "=========================================="
    cat "${install_dir}/COPYPARTY-INFO.txt"
    echo "=========================================="
    echo ""
    print_warning "⚠️  请妥善保管管理员密码！"
    print_info "信息已保存到: ${install_dir}/COPYPARTY-INFO.txt"
    
    press_enter
}


# ============================================
# 安装 qBittorrent + Jellyfin (组合)
# Jellyfin: 根路径 /
# qBittorrent: 子路径 /bt
# ============================================

install_qb_jellyfin() {
    clear
    echo "=========================================="
    echo "   安装 qBittorrent + Jellyfin"
    echo "=========================================="
    echo ""
    
    check_root || return
    init_webserver_config
    ensure_tools
    
    # 检查 Web 服务器
    if [ "$WEB_SERVER" = "none" ]; then
        print_error "未检测到 Web 服务器 (Nginx/OpenResty)"
        echo ""
        print_info "需要反向代理，请先安装 Web 服务器"
        press_enter
        return
    fi
    
    ensure_config_dirs
    
    # 配置参数
    echo ""
    print_info "将安装 qBittorrent + Jellyfin 组合"
    echo "  - Jellyfin: 根路径 /"
    echo "  - qBittorrent: 子路径 /bt"
    echo ""
    
    read -p "域名 (如: media.example.com): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local qb_port="8080"
    local jf_port="8096"
    local download_dir="/home/qbittorrent-nox/Downloads"
    
    # Basic Auth 配置
    echo ""
    print_info "配置 Basic Auth 认证（保护 qBittorrent）"
    read -p "用户名 (默认: admin): " auth_user
    auth_user=${auth_user:-admin}
    
    read -sp "密码 (留空自动生成): " auth_pass
    echo ""
    
    if [ -z "$auth_pass" ]; then
        auth_pass=$(generate_password 12)
        print_info "生成的密码: $auth_pass"
    fi
    
    echo ""
    print_info "安装配置："
    echo "  Web 服务器: ${WEB_SERVER}"
    echo "  域名: ${domain}"
    echo "  Jellyfin: https://${domain}/ (端口 ${jf_port})"
    echo "  qBittorrent: https://${domain}/bt (端口 ${qb_port})"
    echo "  下载目录: ${download_dir}"
    echo "  Basic Auth: ${auth_user}"
    echo ""
    
    read -p "确认安装？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # ============ 安装 qBittorrent ============
    echo ""
    echo "=========================================="
    print_info "第一部分：安装 qBittorrent-nox"
    echo "=========================================="
    echo ""
    
    print_info "[1/10] 安装 qBittorrent-nox..."
    apt update -qq
    apt install -y qbittorrent-nox
    print_success "qBittorrent-nox 安装完成"
    
    print_info "[2/10] 创建 qBittorrent 用户和组..."
    groupadd -f -r qbittorrent-nox
    if ! id "qbittorrent-nox" &>/dev/null; then
        useradd -m -r -s /usr/sbin/nologin -g qbittorrent-nox qbittorrent-nox
    fi
    print_success "用户创建完成"
    
    print_info "[3/10] 创建目录..."
    mkdir -p /home/qbittorrent-nox/.config/qBittorrent
    mkdir -p "$download_dir"
    echo -e "[LegalNotice]\nAccepted=true" > /home/qbittorrent-nox/.config/qBittorrent/qBittorrent.conf
    chown -R qbittorrent-nox:qbittorrent-nox /home/qbittorrent-nox
    print_success "目录创建完成"
    
    print_info "[4/10] 配置 qBittorrent systemd 服务..."
    cat > /etc/systemd/system/qbittorrent-nox.service << 'QBSERVICE'
[Unit]
Description=qBittorrent Command Line Client
After=network.target

[Service]
User=qbittorrent-nox
Group=qbittorrent-nox
UMask=0022
Type=simple
ExecStart=/usr/bin/qbittorrent-nox --webui-port=8080
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
QBSERVICE
    
    systemctl daemon-reload
    systemctl enable qbittorrent-nox
    systemctl start qbittorrent-nox
    print_success "qBittorrent 服务配置完成"
    
    # ============ 安装 Jellyfin ============
    echo ""
    echo "=========================================="
    print_info "第二部分：安装 Jellyfin"
    echo "=========================================="
    echo ""
    
    print_info "[5/10] 添加 Jellyfin 仓库..."
    apt install -y curl gnupg lsb-release
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg --yes
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/jellyfin.gpg] https://repo.jellyfin.org/debian $(lsb_release -c -s) main" > /etc/apt/sources.list.d/jellyfin.list
    print_success "仓库添加完成"
    
    print_info "[6/10] 安装 Jellyfin..."
    apt update -qq
    apt install -y jellyfin
    print_success "Jellyfin 安装完成"
    
    print_info "[7/10] 配置 Jellyfin 权限..."
    usermod -aG qbittorrent-nox jellyfin
    chmod g+x /home/qbittorrent-nox
    chmod -R 750 "$download_dir"
    systemctl enable jellyfin
    systemctl restart jellyfin
    print_success "Jellyfin 权限配置完成"
    
    # ============ 配置反向代理 ============
    echo ""
    echo "=========================================="
    print_info "第三部分：配置反向代理"
    echo "=========================================="
    echo ""
    
    print_info "[8/10] 配置 Basic Auth..."
    htpasswd -bc "${NGINX_CONF_DIR}/.htpasswd_qbittorrent" "$auth_user" "$auth_pass"
    print_success "Basic Auth 配置完成"
    
    print_info "[9/10] 生成 SSL 证书..."
    local ssl_files=$(generate_ssl_cert "$domain")
    local ssl_cert=$(echo "$ssl_files" | cut -d: -f1)
    local ssl_key=$(echo "$ssl_files" | cut -d: -f2)
    
    print_info "[10/10] 配置 ${WEB_SERVER}..."
    cat > "${SITES_AVAIL}/${domain}.conf" << MEDIACONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    access_log /var/log/${WEB_SERVER}/${domain}.access.log;
    error_log /var/log/${WEB_SERVER}/${domain}.error.log;
    
    client_max_body_size 0;
    
    # qBittorrent 子路径（需要 Basic Auth）
    location /bt {
        return 302 \$scheme://\$host/bt/;
    }
    
    location /bt/ {
        # Basic Auth 认证
        auth_basic "qBittorrent Access";
        auth_basic_user_file ${NGINX_CONF_DIR}/.htpasswd_qbittorrent;
        
        proxy_pass http://127.0.0.1:${qb_port}/;
        proxy_http_version 1.1;
        
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        
        # WebSocket 支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 超时设置
        proxy_connect_timeout 600;
        proxy_send_timeout 600;
        proxy_read_timeout 600;
        send_timeout 600;
    }
    
    # Jellyfin 根路径（无需认证）
    location / {
        proxy_pass http://127.0.0.1:${jf_port};
        proxy_http_version 1.1;
        
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        
        # WebSocket 支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 禁用缓冲
        proxy_buffering off;
    }
}
MEDIACONF
    
    mkdir -p "/var/log/${WEB_SERVER}"
    ln -sf "${SITES_AVAIL}/${domain}.conf" "${SITES_ENABLED}/"
    reload_webserver
    print_success "反向代理配置完成"
    
    # 检查服务状态
    echo ""
    echo "=========================================="
    print_info "检查服务状态"
    echo "=========================================="
    echo ""
    
    sleep 3
    
    if systemctl is-active --quiet qbittorrent-nox; then
        print_success "✓ qBittorrent-nox 运行中"
    else
        print_error "✗ qBittorrent-nox 未运行"
    fi
    
    if systemctl is-active --quiet jellyfin; then
        print_success "✓ Jellyfin 运行中"
    else
        print_error "✗ Jellyfin 未运行"
    fi
    
    # 保存信息
    cat > /root/media-server-info.txt << INFO
媒体服务器安装信息
==================
安装时间: $(date)

访问信息
--------
域名: https://${domain}

Jellyfin 媒体服务器
-------------------
访问地址: https://${domain}/
首次访问: 需要完成初始化向导

qBittorrent WebUI
-----------------
访问地址: https://${domain}/bt
Basic Auth 用户: ${auth_user}
Basic Auth 密码: ${auth_pass}
qBittorrent 用户: admin
qBittorrent 密码: 查看日志获取临时密码

服务配置
--------
qBittorrent 端口: ${qb_port}
Jellyfin 端口: ${jf_port}
下载目录: ${download_dir}
Jellyfin 配置: /etc/jellyfin
Jellyfin 数据: /var/lib/jellyfin

权限配置
--------
• Jellyfin 用户已加入 qbittorrent-nox 组
• Jellyfin 可访问 qBittorrent 下载目录
• 下载的媒体文件可直接在 Jellyfin 中播放

管理命令
--------
qBittorrent:
  systemctl status qbittorrent-nox
  systemctl restart qbittorrent-nox
  journalctl -u qbittorrent-nox -f

Jellyfin:
  systemctl status jellyfin
  systemctl restart jellyfin
  journalctl -u jellyfin -f

获取 qBittorrent 临时密码:
  journalctl -u qbittorrent-nox -n 50 | grep password

配置文件
--------
qBittorrent systemd: /etc/systemd/system/qbittorrent-nox.service
Jellyfin systemd: /lib/systemd/system/jellyfin.service
Web 配置: ${SITES_AVAIL}/${domain}.conf
Basic Auth: ${NGINX_CONF_DIR}/.htpasswd_qbittorrent
SSL 证书: ${ssl_cert}

使用流程
--------
1. 访问 Jellyfin (https://${domain}/)
   - 完成初始化向导
   - 添加媒体库: ${download_dir}
   - 播放下载的媒体文件

2. 访问 qBittorrent (https://${domain}/bt)
   - 输入 Basic Auth: ${auth_user} / ${auth_pass}
   - 登录 qBittorrent: admin / [临时密码]
   - 下载种子到 ${download_dir}

安全提示
--------
⚠️  创建 Jellyfin 管理员账号（强密码）
⚠️  修改 qBittorrent WebUI 密码
⚠️  定期更新软件
⚠️  监控磁盘使用
⚠️  Jellyfin 无 Basic Auth（方便访问）
⚠️  qBittorrent 有 Basic Auth 保护
INFO
    
    chmod 600 /root/media-server-info.txt
    
    echo ""
    print_success "媒体服务器安装完成！"
    echo ""
    cat /root/media-server-info.txt
    echo ""
    print_info "信息已保存到: /root/media-server-info.txt"
    
    press_enter
}



# ============================================
# 列出所有站点
# ============================================


list_sites() {
    clear
    echo "=========================================="
    echo "   已部署的站点"
    echo "=========================================="
    echo ""
    
    init_webserver_config
    
    if [ "$WEB_SERVER" = "none" ]; then
        print_warning "未检测到 Web 服务器"
        press_enter
        return
    fi
    
    if [ ! -d "$SITES_ENABLED" ] || [ -z "$(ls -A "$SITES_ENABLED" 2>/dev/null)" ]; then
        print_warning "暂无已部署的站点"
        press_enter
        return
    fi
    
    local count=0
    for conf in "$SITES_ENABLED"/*.conf; do
        [ -f "$conf" ] || continue
        
        local name=$(basename "$conf" .conf)
        local domain=$(grep "server_name" "$conf" | grep -v "return" | head -1 | awk '{print $2}' | tr -d ';')
        local root=$(grep "root" "$conf" | head -1 | awk '{print $2}' | tr -d ';')
        
        count=$((count+1))
        echo -e "${CYAN}[$count] ${domain}${NC}"
        echo "    目录: $root"
        echo "    配置: $conf"
        
        # 检查是否有信息文件
        if [ -f "$root/SITE-INFO.txt" ]; then
            echo "    类型: WordPress"
            echo "    信息: $root/SITE-INFO.txt"
        elif [ -f "$root/WIKI-INFO.txt" ]; then
            echo "    类型: DokuWiki"
            echo "    信息: $root/WIKI-INFO.txt"
        elif [ -f "$root/TTRSS-INFO.txt" ]; then
            echo "    类型: Tiny Tiny RSS"
            echo "    信息: $root/TTRSS-INFO.txt"
        elif [ "$root" = "${WEB_ROOT}/phpmyadmin" ]; then
            echo "    类型: phpMyAdmin"
            echo "    信息: /root/phpmyadmin-info.txt"
        fi
        
        # 检查 SSL 证书
        local ssl_cert="${SSL_DIR}/${domain}.crt"
        if [ -f "$ssl_cert" ]; then
            local expire_date=$(openssl x509 -in "$ssl_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
            echo "    SSL: ${expire_date}"
        fi
        
        echo ""
    done
    
    echo "----------------------------------------"
    print_success "总计: $count 个站点 (${WEB_SERVER})"
    
    # 显示备份信息
    if [ -d "$BACKUP_DIR" ]; then
        local backup_count=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
        if [ "$backup_count" -gt 0 ]; then
            echo ""
            print_info "备份文件: $backup_count 个 (${BACKUP_DIR})"
        fi
    fi
    
    press_enter
}


# ============================================
# 删除站点
# ============================================


delete_site() {
    clear
    echo "=========================================="
    echo "   删除站点"
    echo "=========================================="
    echo ""
    
    init_webserver_config
    
    # 先列出站点
    if [ "$WEB_SERVER" = "none" ]; then
        print_error "未检测到 Web 服务器"
        press_enter
        return
    fi
    
    if [ ! -d "$SITES_ENABLED" ] || [ -z "$(ls -A "$SITES_ENABLED" 2>/dev/null)" ]; then
        print_warning "暂无已部署的站点"
        press_enter
        return
    fi
    
    print_info "当前站点列表："
    echo ""
    
    local count=0
    local -a domains
    for conf in "$SITES_ENABLED"/*.conf; do
        [ -f "$conf" ] || continue
        local domain=$(grep "server_name" "$conf" | grep -v "return" | head -1 | awk '{print $2}' | tr -d ';')
        count=$((count+1))
        domains+=("$domain")
        echo "  $count. $domain"
    done
    
    echo ""
    read -p "输入要删除的域名: " domain
    
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local site_dir="${WEB_ROOT}/${domain}"
    local site_conf="${SITES_AVAIL}/${domain}.conf"
    
    # 特殊处理 phpmyadmin
    if [ "$domain" = "_" ] || [ "$domain" = "phpmyadmin" ]; then
        site_dir="${WEB_ROOT}/phpmyadmin"
        site_conf="${SITES_AVAIL}/phpmyadmin.conf"
    fi
    
    if [ ! -f "$site_conf" ]; then
        print_error "站点不存在: $domain"
        press_enter
        return
    fi
    
    # 读取数据库信息
    local db_name=""
    local db_user=""
    local db_type=""
    
    if [ -f "$site_dir/SITE-INFO.txt" ]; then
        db_name=$(grep "数据库名:" "$site_dir/SITE-INFO.txt" | awk '{print $2}')
        db_user=$(grep "数据库用户:" "$site_dir/SITE-INFO.txt" | awk '{print $2}')
        db_type="mysql"
    elif [ -f "$site_dir/TTRSS-INFO.txt" ]; then
        db_name=$(grep "数据库名:" "$site_dir/TTRSS-INFO.txt" | awk '{print $2}')
        db_user=$(grep "数据库用户:" "$site_dir/TTRSS-INFO.txt" | awk '{print $2}')
        db_type="postgresql"
    fi
    
    # 显示将删除的内容
    echo ""
    print_warning "将删除以下内容:"
    echo "  - 站点目录: $site_dir"
    echo "  - ${WEB_SERVER} 配置: $site_conf"
    echo "  - SSL 证书: ${SSL_DIR}/${domain}.*"
    [ -n "$db_name" ] && echo "  - 数据库: $db_name ($db_type)"
    
    # 特殊文件
    if [ "$domain" = "_" ] || [ "$domain" = "phpmyadmin" ]; then
        echo "  - Basic Auth: ${NGINX_CONF_DIR}/.htpasswd_phpmyadmin"
    fi
    
    echo ""
    read -p "确认删除？输入域名以确认: " confirm
    
    if [ "$confirm" != "$domain" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 询问是否备份
    echo ""
    read -p "删除前是否备份? (yes/no): " backup_confirm
    if [[ "$backup_confirm" == "yes" ]]; then
        if [ -d "$site_dir" ]; then
            backup_site "$site_dir"
        fi
    fi
    
    # 删除站点
    print_info "正在删除站点..."
    
    # 停止相关服务
    if [ -f "/etc/systemd/system/ttrss-update.service" ]; then
        systemctl stop ttrss-update 2>/dev/null || true
        systemctl disable ttrss-update 2>/dev/null || true
        rm -f /etc/systemd/system/ttrss-update.service
        systemctl daemon-reload
        print_success "已停止 TTRSS 更新服务"
    fi
    
    # 删除文件和配置
    remove_site "$domain"
    
    # 删除特殊文件
    if [ "$domain" = "_" ] || [ "$domain" = "phpmyadmin" ]; then
        rm -f "${NGINX_CONF_DIR}/.htpasswd_phpmyadmin"
        rm -f /root/phpmyadmin-info.txt
    fi
    
    # 删除数据库
    if [ -n "$db_name" ]; then
        echo ""
        echo -n "是否删除数据库 ${db_name}? (yes/no): "
        read -r delete_db
        if [[ "$delete_db" == "yes" ]]; then
            if [ "$db_type" = "mysql" ]; then
                mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`;" 2>/dev/null
                mysql -e "DROP USER IF EXISTS '${db_user}'@'localhost';" 2>/dev/null
            elif [ "$db_type" = "postgresql" ]; then
                sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${db_name};" 2>/dev/null
                sudo -u postgres psql -c "DROP USER IF EXISTS ${db_user};" 2>/dev/null
            fi
            print_success "已删除数据库"
        fi
    fi
    
    reload_webserver
    
    echo ""
    print_success "站点 ${domain} 已删除！"
    
    press_enter
}


# ============================================
# 系统诊断
# ============================================


diagnose() {
    clear
    echo "=========================================="
    echo "   系统诊断"
    echo "=========================================="
    echo ""
    
    init_webserver_config
    
    print_info "服务状态:"
    echo ""
    
    if [ "$WEB_SERVER" != "none" ]; then
        systemctl is-active --quiet "$SERVICE_NAME" && print_success "${WEB_SERVER}: 运行中" || print_error "${WEB_SERVER}: 已停止"
    else
        print_warning "Web 服务器: 未安装"
    fi
    
    systemctl is-active --quiet php${PHP_VERSION}-fpm && print_success "PHP ${PHP_VERSION}: 运行中" || echo -e "${YELLOW}○${NC} PHP ${PHP_VERSION}: 未运行"
    systemctl is-active --quiet mariadb && print_success "MariaDB: 运行中" || systemctl is-active --quiet mysql && print_success "MySQL: 运行中" || echo -e "${YELLOW}○${NC} MySQL/MariaDB: 未运行"
    systemctl is-active --quiet postgresql && print_success "PostgreSQL: 运行中" || echo -e "${YELLOW}○${NC} PostgreSQL: 未运行"
    
    # 检查 TTRSS 更新服务
    if systemctl is-active --quiet ttrss-update 2>/dev/null; then
        print_success "TTRSS Update: 运行中"
    fi
    
    echo ""
    print_info "版本信息:"
    echo ""
    
    if [ "$WEB_SERVER" != "none" ]; then
        show_webserver_info
        echo ""
    fi
    
    if check_php; then
        echo "  PHP: $(php -r 'echo PHP_VERSION;')"
        echo "  PHP Socket: ${PHP_SOCK}"
        if [ -S "$PHP_SOCK" ]; then
            print_success "  PHP-FPM Socket: 正常"
        else
            print_error "  PHP-FPM Socket: 未找到"
        fi
    fi
    
    if check_mysql; then
        echo "  MySQL/MariaDB: $(mysql --version | grep -oP 'Ver \K[0-9.]+')"
    fi
    
    if check_postgresql; then
        echo "  PostgreSQL: $(psql --version | grep -oP 'psql \(PostgreSQL\) \K[0-9.]+')"
    fi
    
    echo ""
    print_info "站点统计:"
    echo ""
    
    if [ -d "$SITES_ENABLED" ]; then
        local site_count=$(ls -1 "$SITES_ENABLED"/*.conf 2>/dev/null | wc -l)
        echo "  已部署站点: $site_count 个"
    else
        echo "  已部署站点: 0 个"
    fi
    
    local backup_count=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    echo "  备份文件: $backup_count 个"
    
    if [ -d "$SSL_DIR" ]; then
        local ssl_count=$(ls -1 "$SSL_DIR"/*.crt 2>/dev/null | wc -l)
        echo "  SSL 证书: $ssl_count 个"
    fi
    
    if [ "$WEB_SERVER" != "none" ]; then
        echo ""
        print_info "${WEB_SERVER} 配置测试:"
        echo ""
        $NGINX_BIN -t 2>&1 | tail -2
    fi
    
    echo ""
    print_info "磁盘使用:"
    echo ""
    df -h "$WEB_ROOT" | tail -1 | awk '{print "  Web 目录: " $3 " / " $2 " (" $5 ")"}'
    if [ -d "$BACKUP_DIR" ]; then
        local backup_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
        echo "  备份目录: ${backup_size}"
    fi
    
    press_enter
}


# ============================================
# 查看站点信息
# ============================================


view_site_info() {
    clear
    echo "=========================================="
    echo "   查看站点信息"
    echo "=========================================="
    echo ""
    
    init_webserver_config
    
    if [ "$WEB_SERVER" = "none" ]; then
        print_error "未检测到 Web 服务器"
        press_enter
        return
    fi
    
    if [ ! -d "$SITES_ENABLED" ] || [ -z "$(ls -A "$SITES_ENABLED" 2>/dev/null)" ]; then
        print_warning "暂无已部署的站点"
        press_enter
        return
    fi
    
    print_info "当前站点列表："
    echo ""
    
    local count=0
    for conf in "$SITES_ENABLED"/*.conf; do
        [ -f "$conf" ] || continue
        local domain=$(grep "server_name" "$conf" | grep -v "return" | head -1 | awk '{print $2}' | tr -d ';')
        count=$((count+1))
        echo "  $count. $domain"
    done
    
    echo ""
    read -p "输入要查看的域名: " domain
    
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local site_dir="${WEB_ROOT}/${domain}"
    
    # 特殊处理 phpmyadmin
    if [ "$domain" = "_" ] || [ "$domain" = "phpmyadmin" ]; then
        if [ -f "/root/phpmyadmin-info.txt" ]; then
            echo ""
            cat /root/phpmyadmin-info.txt
        else
            print_error "未找到站点信息"
        fi
        press_enter
        return
    fi
    
    # 查找信息文件
    local info_file=""
    if [ -f "$site_dir/SITE-INFO.txt" ]; then
        info_file="$site_dir/SITE-INFO.txt"
    elif [ -f "$site_dir/WIKI-INFO.txt" ]; then
        info_file="$site_dir/WIKI-INFO.txt"
    elif [ -f "$site_dir/TTRSS-INFO.txt" ]; then
        info_file="$site_dir/TTRSS-INFO.txt"
    fi
    
    if [ -n "$info_file" ] && [ -f "$info_file" ]; then
        echo ""
        cat "$info_file"
    else
        print_error "未找到站点信息文件"
    fi
    
    press_enter
}


# ============================================
# 主菜单
# ============================================

show_webapp_menu() {
    clear
    
    # 初始化 Web 服务器配置
    init_webserver_config
    
    echo "=========================================="
    echo "   Web 应用安装管理"
    echo "=========================================="
    echo ""
    
    # 显示环境状态
    echo "【系统环境】"
    echo ""
    
    # Web 服务器状态
    if [ "$WEB_SERVER" != "none" ]; then
        local version=""
        if [ "$WEB_SERVER" = "openresty" ]; then
            version=$(openresty -v 2>&1 | grep -oP 'openresty/\K[0-9.]+' || echo "unknown")
            echo -e "${GREEN}✓${NC} Web 服务器: OpenResty ${version}"
        else
            version=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "unknown")
            echo -e "${GREEN}✓${NC} Web 服务器: Nginx ${version}"
        fi
    else
        echo -e "${YELLOW}○${NC} Web 服务器: 未安装"
    fi
    
    # PHP 状态
    if check_php; then
        local php_ver=$(php -v | head -1 | awk '{print $2}' | cut -d- -f1)
        echo -e "${GREEN}✓${NC} PHP: ${php_ver}"
    else
        echo -e "${YELLOW}○${NC} PHP: 未安装"
    fi
    
    # MySQL/MariaDB 状态
    if check_mysql; then
        local mysql_ver=$(mysql --version | awk '{print $5}' | cut -d, -f1)
        echo -e "${GREEN}✓${NC} MySQL/MariaDB: ${mysql_ver}"
    else
        echo -e "${YELLOW}○${NC} MySQL/MariaDB: 未安装"
    fi
    
    # PostgreSQL 状态
    if check_postgresql; then
        local pg_ver=$(sudo -u postgres psql --version | awk '{print $3}')
        echo -e "${GREEN}✓${NC} PostgreSQL: ${pg_ver}"
    else
        echo -e "${YELLOW}○${NC} PostgreSQL: 未安装"
    fi
    
    # Python3 状态
    if command -v python3 &> /dev/null; then
        local py_ver=$(python3 --version | awk '{print $2}')
        echo -e "${GREEN}✓${NC} Python3: ${py_ver}"
    else
        echo -e "${YELLOW}○${NC} Python3: 未安装"
    fi
    
    # Supervisor 状态
    if command -v supervisorctl &> /dev/null; then
        echo -e "${GREEN}✓${NC} Supervisor: 已安装"
    else
        echo -e "${YELLOW}○${NC} Supervisor: 未安装"
    fi
    
    # Rclone 状态
    if command -v rclone &> /dev/null; then
        local rclone_ver=$(rclone version | head -1 | awk '{print $2}')
        echo -e "${GREEN}✓${NC} Rclone: ${rclone_ver}"
    else
        echo -e "${YELLOW}○${NC} Rclone: 未安装"
    fi
    
    echo ""
    echo "【Web 应用安装】"
    echo ""
    echo "1. 📝 WordPress (博客/CMS)"
    echo "   需要: Nginx/OpenResty + PHP + MySQL"
    echo ""
    echo "2. 📰 Tiny Tiny RSS (RSS 阅读器)"
    echo "   需要: Nginx/OpenResty + PHP + PostgreSQL"
    echo ""
    echo "3. 🗄️  phpMyAdmin (数据库管理)"
    echo "   需要: Nginx/OpenResty + PHP + MySQL"
    echo ""
    echo "4. 📚 DokuWiki (无数据库 Wiki)"
    echo "   需要: Nginx/OpenResty + PHP"
    echo ""
    echo "5. ☁️  Rclone 挂载 (云存储挂载)"
    echo "   需要: fuse3 + rclone + Supervisor"
    echo ""
    echo "6. 📁 Copyparty (文件服务器)"
    echo "   需要: Nginx/OpenResty + Python3 + Supervisor"
    echo ""
    echo "7. 📥🎬 qBittorrent + Jellyfin (媒体中心)"
    echo "   需要: Nginx/OpenResty + qbittorrent-nox + Jellyfin"
    echo ""
    echo "【站点管理】"
    echo ""
    echo "8. 📋 列出所有站点"
    echo "9. 📄 查看站点信息"
    echo "10. ❌ 删除站点"
    echo ""
    echo "【系统管理】"
    echo ""
    echo "11. 🔄 重启服务"
    echo "12. 🔍 系统诊断"
    echo ""
    echo "0. 返回主菜单"
    echo "=========================================="
}


# ============================================
# Web 应用菜单主循环
# ============================================

webapp_menu() {
    while true; do
        show_webapp_menu
        read -p "请选择 [0-12]: " choice
        
        case $choice in
            1)
                install_wordpress
                ;;
            2)
                install_ttrss
                ;;
            3)
                install_phpmyadmin
                ;;
            4)
                install_dokuwiki
                ;;
            5)
                install_rclone
                ;;
            6)
                install_copyparty
                ;;
            7)
                install_qb_jellyfin
                ;;
            8)
                list_sites
                ;;
            9)
                view_site_info
                ;;
            10)
                delete_site
                ;;
            11)
                clear
                echo "=========================================="
                echo "   重启服务"
                echo "=========================================="
                echo ""
                
                init_webserver_config
                
                print_info "正在重启服务..."
                echo ""
                
                # 重启 Web 服务器
                if [ "$WEB_SERVER" != "none" ]; then
                    print_info "重启 ${WEB_SERVER}..."
                    systemctl restart "$SERVICE_NAME"
                    if systemctl is-active --quiet "$SERVICE_NAME"; then
                        print_success "${WEB_SERVER} 已重启"
                    else
                        print_error "${WEB_SERVER} 重启失败"
                    fi
                fi
                
                # 重启 PHP-FPM
                if check_php; then
                    print_info "重启 PHP-FPM..."
                    systemctl restart php${PHP_VERSION}-fpm 2>/dev/null || systemctl restart php*-fpm 2>/dev/null || true
                    if systemctl is-active --quiet php${PHP_VERSION}-fpm 2>/dev/null || systemctl is-active --quiet php*-fpm 2>/dev/null; then
                        print_success "PHP-FPM 已重启"
                    else
                        print_warning "PHP-FPM 重启失败或未安装"
                    fi
                fi
                
                # 重启 MySQL/MariaDB
                if check_mysql; then
                    print_info "重启 MySQL/MariaDB..."
                    systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
                    if systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null; then
                        print_success "MySQL/MariaDB 已重启"
                    else
                        print_warning "MySQL/MariaDB 重启失败或未安装"
                    fi
                fi
                
                # 重启 PostgreSQL
                if check_postgresql; then
                    print_info "重启 PostgreSQL..."
                    systemctl restart postgresql 2>/dev/null || true
                    if systemctl is-active --quiet postgresql 2>/dev/null; then
                        print_success "PostgreSQL 已重启"
                    else
                        print_warning "PostgreSQL 重启失败或未安装"
                    fi
                fi
                
                # 重启 TTRSS 更新服务
                if systemctl list-unit-files | grep -q "tt-rss-update"; then
                    print_info "重启 TTRSS 更新服务..."
                    systemctl restart tt-rss-update 2>/dev/null || true
                    if systemctl is-active --quiet tt-rss-update 2>/dev/null; then
                        print_success "TTRSS 更新服务已重启"
                    else
                        print_warning "TTRSS 更新服务重启失败"
                    fi
                fi
                
                # 重启 Supervisor
                if command -v supervisorctl &> /dev/null; then
                    print_info "重启 Supervisor 服务..."
                    supervisorctl restart all 2>/dev/null || true
                    print_success "Supervisor 服务已重启"
                fi
                
                echo ""
                print_success "所有服务重启完成"
                press_enter
                ;;
            12)
                diagnose
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
webapp_menu
