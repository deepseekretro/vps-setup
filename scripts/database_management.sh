#!/bin/bash


# ============================================
# 数据库管理脚本
# 支持 PostgreSQL 和 MySQL/MariaDB
# ============================================


# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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


# ============================================
# PostgreSQL 管理函数
# ============================================


# 检查 PostgreSQL 是否安装
check_postgresql() {
    if command -v psql &> /dev/null; then
        return 0
    else
        return 1
    fi
}


# 检查 PostgreSQL APT 源是否已配置
check_pgdg_repo() {
    if [ -f "/etc/apt/sources.list.d/pgdg.list" ]; then
        return 0
    else
        return 1
    fi
}


# 配置 PostgreSQL 官方 APT 源（手动配置）
setup_pgdg_repo() {
    clear
    echo "=========================================="
    echo "   配置 PostgreSQL 官方 APT 源"
    echo "=========================================="
    echo ""
    
    if check_pgdg_repo; then
        print_warning "PostgreSQL 官方源已配置"
        cat /etc/apt/sources.list.d/pgdg.list
        echo ""
        read -p "是否重新配置？[y/N]: " reconfig
        if [[ ! "$reconfig" =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    
    # 直接执行手动配置
    setup_pgdg_repo_manual
}


# 手动配置 PostgreSQL 官方源
setup_pgdg_repo_manual() {
    echo ""
    print_info "使用手动配置..."
    echo ""
    
    # 安装依赖
    echo "[步骤 1/4] 安装依赖..."
    sudo apt update
    sudo apt install -y curl ca-certificates lsb-release
    print_success "依赖安装完成"
    
    # 下载并导入 GPG 密钥
    echo ""
    echo "[步骤 2/4] 导入 GPG 密钥..."
    sudo install -d /usr/share/postgresql-common/pgdg
    sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
    
    if [ $? -eq 0 ]; then
        print_success "GPG 密钥导入完成"
    else
        print_error "GPG 密钥导入失败"
        press_enter
        return 1
    fi
    
    # 创建 APT 源配置文件
    echo ""
    echo "[步骤 3/4] 创建 APT 源配置..."
    
    CODENAME=$(lsb_release -cs)
    
    sudo sh -c "echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main' > /etc/apt/sources.list.d/pgdg.list"
    
    print_success "APT 源配置完成"
    echo ""
    print_info "配置文件内容："
    cat /etc/apt/sources.list.d/pgdg.list
    
    # 更新软件包列表
    echo ""
    echo "[步骤 4/4] 更新软件包列表..."
    sudo apt update
    print_success "软件包列表已更新"
    
    echo ""
    print_success "PostgreSQL 官方源配置完成！"
    
    press_enter
}


# 安装 PostgreSQL
install_postgresql() {
    clear
    echo "=========================================="
    echo "   安装 PostgreSQL"
    echo "=========================================="
    echo ""
    
    if check_postgresql; then
        print_warning "PostgreSQL 已安装"
        psql --version
        echo ""
        read -p "是否继续安装其他版本？[y/N]: " continue_install
        if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi
    
    # 检查是否配置了 PGDG 源
    if ! check_pgdg_repo; then
        print_warning "未检测到 PostgreSQL 官方 APT 源"
        echo ""
        read -p "是否现在配置？[Y/n]: " setup_repo
        
        if [[ ! "$setup_repo" =~ ^[Nn]$ ]]; then
            setup_pgdg_repo
        else
            print_info "将从系统默认源安装 PostgreSQL"
        fi
    else
        print_success "已配置 PostgreSQL 官方源"
    fi
    
    echo ""
    print_info "选择要安装的版本："
    echo ""
    echo "1. PostgreSQL 18 (最新稳定版)"
    echo "2. PostgreSQL 17"
    echo "3. PostgreSQL 16"
    echo "4. PostgreSQL 15"
    echo "5. PostgreSQL 14"
    echo "6. 系统默认版本"
    echo "7. 自定义版本"
    echo "0. 取消"
    echo ""
    
    read -p "请选择 [0-7]: " version_choice
    
    case $version_choice in
        1)
            PG_VERSION="18"
            ;;
        2)
            PG_VERSION="17"
            ;;
        3)
            PG_VERSION="16"
            ;;
        4)
            PG_VERSION="15"
            ;;
        5)
            PG_VERSION="14"
            ;;
        6)
            PG_VERSION=""
            ;;
        7)
            read -p "请输入版本号 (如: 18): " PG_VERSION
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选择"
            press_enter
            return
            ;;
    esac
    
    echo ""
    print_info "正在安装 PostgreSQL ${PG_VERSION:-默认版本}..."
    echo ""
    
    # 更新软件包列表
    sudo apt update
    
    # 安装 PostgreSQL
    if [ -n "$PG_VERSION" ]; then
        sudo apt install -y postgresql-${PG_VERSION} postgresql-contrib-${PG_VERSION}
    else
        sudo apt install -y postgresql postgresql-contrib
    fi
    
    if [ $? -eq 0 ]; then
        print_success "PostgreSQL 安装成功"
        echo ""
        print_info "PostgreSQL 版本: $(psql --version)"
        echo ""
        print_info "PostgreSQL 服务状态:"
        sudo systemctl status postgresql --no-pager -l | head -10
        echo ""
        print_info "默认数据目录: /var/lib/postgresql/${PG_VERSION:-$(psql --version | grep -oP '\d+' | head -1)}/main"
        print_info "默认配置目录: /etc/postgresql/${PG_VERSION:-$(psql --version | grep -oP '\d+' | head -1)}/main"
    else
        print_error "PostgreSQL 安装失败"
    fi
    
    press_enter
}


# 创建 PostgreSQL 数据库
create_postgresql_database() {
    clear
    echo "=========================================="
    echo "   创建 PostgreSQL 数据库"
    echo "=========================================="
    echo ""
    
    read -p "数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    read -p "数据库用户名: " db_user
    if [ -z "$db_user" ]; then
        print_error "用户名不能为空"
        press_enter
        return
    fi
    
    read -sp "数据库密码: " db_password
    echo ""
    
    if [ -z "$db_password" ]; then
        print_error "密码不能为空"
        press_enter
        return
    fi
    
    echo ""
    print_info "正在创建数据库和用户..."
    
    # 创建用户
    sudo -u postgres psql << EOF
CREATE USER ${db_user} WITH PASSWORD '${db_password}';
CREATE DATABASE ${db_name} OWNER ${db_user};
GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};
\q
EOF
    
    if [ $? -eq 0 ]; then
        print_success "数据库创建成功"
        echo ""
        echo "数据库信息："
        echo "  数据库名: ${db_name}"
        echo "  用户名: ${db_user}"
        echo "  密码: ${db_password}"
        echo ""
        echo "连接命令："
        echo "  psql -U ${db_user} -d ${db_name} -h localhost"
    else
        print_error "数据库创建失败"
    fi
    
    press_enter
}


# 列出 PostgreSQL 数据库
list_postgresql_databases() {
    clear
    echo "=========================================="
    echo "   PostgreSQL 数据库列表"
    echo "=========================================="
    echo ""
    
    sudo -u postgres psql -c "\l"
    
    echo ""
    print_info "用户列表:"
    sudo -u postgres psql -c "\du"
    
    press_enter
}


# 备份 PostgreSQL 数据库
backup_postgresql_database() {
    clear
    echo "=========================================="
    echo "   备份 PostgreSQL 数据库"
    echo "=========================================="
    echo ""
    
    # 列出数据库
    print_info "可用的数据库："
    sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;"
    echo ""
    
    read -p "要备份的数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    # 备份目录
    backup_dir="/var/backups/postgresql"
    sudo mkdir -p "$backup_dir"
    
    # 备份文件名
    backup_file="${backup_dir}/${db_name}_$(date +%Y%m%d_%H%M%S).sql"
    
    print_info "正在备份数据库..."
    
    sudo -u postgres pg_dump "$db_name" > "$backup_file"
    
    if [ $? -eq 0 ]; then
        # 压缩备份
        gzip "$backup_file"
        print_success "备份完成"
        echo ""
        echo "备份文件: ${backup_file}.gz"
        echo "文件大小: $(du -h ${backup_file}.gz | awk '{print $1}')"
    else
        print_error "备份失败"
    fi
    
    press_enter
}


# 恢复 PostgreSQL 数据库
restore_postgresql_database() {
    clear
    echo "=========================================="
    echo "   恢复 PostgreSQL 数据库"
    echo "=========================================="
    echo ""
    
    backup_dir="/var/backups/postgresql"
    
    if [ ! -d "$backup_dir" ]; then
        print_error "备份目录不存在: $backup_dir"
        press_enter
        return
    fi
    
    # 列出备份文件
    print_info "可用的备份文件："
    ls -lh "$backup_dir"/*.sql.gz 2>/dev/null || echo "  没有找到备份文件"
    echo ""
    
    read -p "备份文件路径: " backup_file
    if [ ! -f "$backup_file" ]; then
        print_error "文件不存在"
        press_enter
        return
    fi
    
    read -p "目标数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    print_warning "此操作将覆盖数据库 ${db_name} 的所有数据"
    read -p "确认继续？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "正在恢复数据库..."
    
    # 解压并恢复
    if [[ "$backup_file" == *.gz ]]; then
        gunzip -c "$backup_file" | sudo -u postgres psql "$db_name"
    else
        sudo -u postgres psql "$db_name" < "$backup_file"
    fi
    
    if [ $? -eq 0 ]; then
        print_success "数据库恢复成功"
    else
        print_error "数据库恢复失败"
    fi
    
    press_enter
}


# 删除 PostgreSQL 数据库
delete_postgresql_database() {
    clear
    echo "=========================================="
    echo "   删除 PostgreSQL 数据库"
    echo "=========================================="
    echo ""
    
    # 列出数据库
    print_info "可用的数据库："
    sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;"
    echo ""
    
    read -p "要删除的数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    print_warning "警告：此操作将永久删除数据库 ${db_name}"
    read -p "请输入数据库名称以确认: " confirm_name
    
    if [ "$confirm_name" != "$db_name" ]; then
        print_error "名称不匹配，已取消"
        press_enter
        return
    fi
    
    print_info "正在删除数据库..."
    
    sudo -u postgres psql -c "DROP DATABASE ${db_name};"
    
    if [ $? -eq 0 ]; then
        print_success "数据库已删除"
    else
        print_error "数据库删除失败"
    fi
    
    press_enter
}


# PostgreSQL 服务管理
manage_postgresql_service() {
    clear
    echo "=========================================="
    echo "   PostgreSQL 服务管理"
    echo "=========================================="
    echo ""
    
    echo "1. 查看服务状态"
    echo "2. 启动服务"
    echo "3. 停止服务"
    echo "4. 重启服务"
    echo "5. 重新加载配置"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-5]: " choice
    
    case $choice in
        1)
            sudo systemctl status postgresql --no-pager -l
            ;;
        2)
            sudo systemctl start postgresql
            print_success "PostgreSQL 服务已启动"
            ;;
        3)
            sudo systemctl stop postgresql
            print_success "PostgreSQL 服务已停止"
            ;;
        4)
            sudo systemctl restart postgresql
            print_success "PostgreSQL 服务已重启"
            ;;
        5)
            sudo systemctl reload postgresql
            print_success "PostgreSQL 配置已重新加载"
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}


# PostgreSQL 子菜单
postgresql_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   PostgreSQL 管理"
        echo "=========================================="
        echo ""
        
        # 显示 PGDG 源状态
        if check_pgdg_repo; then
            print_success "PostgreSQL 官方源: 已配置"
        else
            echo -e "${YELLOW}○${NC} PostgreSQL 官方源: 未配置"
        fi
        
        if check_postgresql; then
            print_success "PostgreSQL: 已安装"
            pg_version=$(sudo -u postgres psql -V | awk '{print $3}')
            echo "  版本: ${pg_version}"
            
            # 显示服务状态
            if systemctl is-active --quiet postgresql; then
                print_success "服务状态: 运行中"
            else
                print_error "服务状态: 已停止"
            fi
        else
            print_warning "PostgreSQL: 未安装"
        fi
        
        echo ""
        echo "1. 配置 PostgreSQL 官方 APT 源"
        echo "2. 安装 PostgreSQL"
        echo "3. 创建数据库"
        echo "4. 列出数据库"
        echo "5. 备份数据库"
        echo "6. 恢复数据库"
        echo "7. 删除数据库"
        echo "8. 服务管理"
        echo "0. 返回上级菜单"
        echo ""
        
        read -p "请选择 [0-8]: " choice
        
        case $choice in
            1) setup_pgdg_repo ;;
            2) install_postgresql ;;
            3) create_postgresql_database ;;
            4) list_postgresql_databases ;;
            5) backup_postgresql_database ;;
            6) restore_postgresql_database ;;
            7) delete_postgresql_database ;;
            8) manage_postgresql_service ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}


# ============================================
# MySQL/MariaDB 管理函数
# ============================================


# 检查 MySQL 是否安装
check_mysql() {
    if command -v mysql &> /dev/null; then
        return 0
    else
        return 1
    fi
}


# 配置 MySQL 官方 APT 源
setup_mysql_repo() {
    echo ""
    print_info "配置 MySQL 官方 APT 源..."
    echo ""
    
    # 安装依赖
    echo "[步骤 1/4] 安装依赖..."
    sudo apt update
    sudo apt install -y wget lsb-release gnupg
    print_success "依赖安装完成"
    
    # 下载并安装 MySQL APT 配置包
    echo ""
    echo "[步骤 2/4] 下载 MySQL APT 配置包..."
    
    # 使用最新的 MySQL APT 配置包
    MYSQL_APT_CONFIG="mysql-apt-config_0.8.29-1_all.deb"
    wget https://dev.mysql.com/get/${MYSQL_APT_CONFIG} -O /tmp/${MYSQL_APT_CONFIG}
    
    if [ $? -eq 0 ]; then
        print_success "下载完成"
    else
        print_error "下载失败"
        return 1
    fi
    
    # 安装配置包（非交互式）
    echo ""
    echo "[步骤 3/4] 配置 MySQL APT 源..."
    
    # 预配置选择 MySQL 8.0
    sudo DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/${MYSQL_APT_CONFIG}
    
    # 清理
    rm -f /tmp/${MYSQL_APT_CONFIG}
    
    print_success "MySQL APT 源配置完成"
    
    # 更新软件包列表
    echo ""
    echo "[步骤 4/4] 更新软件包列表..."
    sudo apt update
    print_success "软件包列表已更新"
    
    echo ""
    print_success "MySQL 官方源配置完成！"
    echo ""
}


# 配置 MariaDB 官方 APT 源
setup_mariadb_repo() {
    echo ""
    print_info "配置 MariaDB 官方 APT 源..."
    echo ""
    
    # 安装依赖
    echo "[步骤 1/4] 安装依赖..."
    sudo apt update
    sudo apt install -y curl software-properties-common
    print_success "依赖安装完成"
    
    # 导入 GPG 密钥
    echo ""
    echo "[步骤 2/4] 导入 GPG 密钥..."
    
    curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc | sudo gpg --dearmor -o /usr/share/keyrings/mariadb-keyring.gpg
    
    if [ $? -eq 0 ]; then
        print_success "GPG 密钥导入完成"
    else
        print_error "GPG 密钥导入失败"
        return 1
    fi
    
    # 创建 APT 源配置文件
    echo ""
    echo "[步骤 3/4] 创建 APT 源配置..."
    
    CODENAME=$(lsb_release -cs)
    
    # MariaDB 11.4 LTS (最新稳定版)
    sudo sh -c "echo 'deb [signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://mirrors.aliyun.com/mariadb/repo/11.4/debian ${CODENAME} main' > /etc/apt/sources.list.d/mariadb.list"
    
    print_success "APT 源配置完成"
    echo ""
    print_info "配置文件内容："
    cat /etc/apt/sources.list.d/mariadb.list
    
    # 更新软件包列表
    echo ""
    echo "[步骤 4/4] 更新软件包列表..."
    sudo apt update
    print_success "软件包列表已更新"
    
    echo ""
    print_success "MariaDB 官方源配置完成！"
    echo ""
}


# 安装 MySQL
install_mysql() {
    clear
    echo "=========================================="
    echo "   安装 MySQL/MariaDB"
    echo "=========================================="
    echo ""
    
    if check_mysql; then
        print_warning "MySQL/MariaDB 已安装"
        mysql --version
        echo ""
        read -p "是否继续安装其他版本？[y/N]: " continue_install
        if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
            press_enter
            return
        fi
    fi
    
    echo "选择数据库类型："
    echo ""
    echo "1. MySQL 8.0 (官方最新稳定版)"
    echo "2. MariaDB 11.4 LTS (开源分支，最新长期支持版)"
    echo "3. 系统默认版本 (Debian 仓库版本)"
    echo "0. 取消"
    echo ""
    
    read -p "请选择 [0-3]: " db_type
    
    case $db_type in
        1)
            # MySQL 官方版本
            echo ""
            print_info "准备安装 MySQL 8.0..."
            echo ""
            
            # 配置 MySQL 官方源
            if [ ! -f "/etc/apt/sources.list.d/mysql.list" ]; then
                print_warning "未检测到 MySQL 官方源"
                read -p "是否现在配置 MySQL 官方源？[Y/n]: " setup_repo
                
                if [[ ! "$setup_repo" =~ ^[Nn]$ ]]; then
                    setup_mysql_repo
                    if [ $? -ne 0 ]; then
                        print_error "源配置失败"
                        press_enter
                        return
                    fi
                fi
            else
                print_success "已配置 MySQL 官方源"
            fi
            
            echo ""
            print_info "正在安装 MySQL 8.0..."
            sudo apt update
            sudo apt install -y mysql-server
            ;;
            
        2)
            # MariaDB 官方版本
            echo ""
            print_info "准备安装 MariaDB 11.4 LTS..."
            echo ""
            
            # 配置 MariaDB 官方源
            if [ ! -f "/etc/apt/sources.list.d/mariadb.list" ]; then
                print_warning "未检测到 MariaDB 官方源"
                read -p "是否现在配置 MariaDB 官方源？[Y/n]: " setup_repo
                
                if [[ ! "$setup_repo" =~ ^[Nn]$ ]]; then
                    setup_mariadb_repo
                    if [ $? -ne 0 ]; then
                        print_error "源配置失败"
                        press_enter
                        return
                    fi
                fi
            else
                print_success "已配置 MariaDB 官方源"
            fi
            
            echo ""
            print_info "正在安装 MariaDB 11.4..."
            sudo apt update
            sudo apt install -y mariadb-server
            ;;
            
        3)
            # 系统默认版本
            echo ""
            print_info "正在安装系统默认版本..."
            echo ""
            
            echo "选择数据库："
            echo "1. MySQL (系统默认)"
            echo "2. MariaDB (系统默认)"
            read -p "请选择 [1-2]: " default_choice
            
            sudo apt update
            
            case $default_choice in
                1)
                    sudo apt install -y mysql-server
                    ;;
                2)
                    sudo apt install -y mariadb-server
                    ;;
                *)
                    print_error "无效选择"
                    press_enter
                    return
                    ;;
            esac
            ;;
            
        0)
            return
            ;;
            
        *)
            print_error "无效选择"
            press_enter
            return
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        print_success "安装成功"
        echo ""
        print_info "版本: $(mysql --version)"
        echo ""
        
        # 检查服务状态
        if systemctl is-active --quiet mysql; then
            print_success "MySQL 服务运行中"
        elif systemctl is-active --quiet mariadb; then
            print_success "MariaDB 服务运行中"
        fi
        
        echo ""
        print_warning "建议运行安全配置："
        echo "  sudo mysql_secure_installation"
        echo ""
        print_info "默认情况下："
        echo "  • root 用户使用 unix_socket 认证"
        echo "  • 可以直接使用: sudo mysql"
    else
        print_error "安装失败"
    fi
    
    press_enter
}


# 创建 MySQL 数据库
create_mysql_database() {
    clear
    echo "=========================================="
    echo "   创建 MySQL 数据库"
    echo "=========================================="
    echo ""
    
    read -p "数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    read -p "数据库用户名: " db_user
    if [ -z "$db_user" ]; then
        print_error "用户名不能为空"
        press_enter
        return
    fi
    
    read -sp "数据库密码: " db_password
    echo ""
    
    if [ -z "$db_password" ]; then
        print_error "密码不能为空"
        press_enter
        return
    fi
    
    echo ""
    print_info "正在创建数据库和用户..."
    
    sudo mysql << EOF
CREATE DATABASE IF NOT EXISTS ${db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOF
    
    if [ $? -eq 0 ]; then
        print_success "数据库创建成功"
        echo ""
        echo "数据库信息："
        echo "  数据库名: ${db_name}"
        echo "  用户名: ${db_user}"
        echo "  密码: ${db_password}"
        echo ""
        echo "连接命令："
        echo "  mysql -u ${db_user} -p${db_password} ${db_name}"
    else
        print_error "数据库创建失败"
    fi
    
    press_enter
}


# 列出 MySQL 数据库
list_mysql_databases() {
    clear
    echo "=========================================="
    echo "   MySQL 数据库列表"
    echo "=========================================="
    echo ""
    
    sudo mysql -e "SHOW DATABASES;"
    
    echo ""
    print_info "用户列表:"
    sudo mysql -e "SELECT User, Host FROM mysql.user;"
    
    press_enter
}


# 备份 MySQL 数据库
backup_mysql_database() {
    clear
    echo "=========================================="
    echo "   备份 MySQL 数据库"
    echo "=========================================="
    echo ""
    
    # 列出数据库
    print_info "可用的数据库："
    sudo mysql -N -e "SHOW DATABASES;" | grep -v "information_schema\|performance_schema\|mysql\|sys"
    echo ""
    
    read -p "要备份的数据库名称 (all 表示所有): " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    # 备份目录
    backup_dir="/var/backups/mysql"
    sudo mkdir -p "$backup_dir"
    
    # 备份文件名
    if [ "$db_name" = "all" ]; then
        backup_file="${backup_dir}/all_databases_$(date +%Y%m%d_%H%M%S).sql"
        print_info "正在备份所有数据库..."
        sudo mysqldump --all-databases > "$backup_file"
    else
        backup_file="${backup_dir}/${db_name}_$(date +%Y%m%d_%H%M%S).sql"
        print_info "正在备份数据库..."
        sudo mysqldump "$db_name" > "$backup_file"
    fi
    
    if [ $? -eq 0 ]; then
        # 压缩备份
        gzip "$backup_file"
        print_success "备份完成"
        echo ""
        echo "备份文件: ${backup_file}.gz"
        echo "文件大小: $(du -h ${backup_file}.gz | awk '{print $1}')"
    else
        print_error "备份失败"
    fi
    
    press_enter
}


# 恢复 MySQL 数据库
restore_mysql_database() {
    clear
    echo "=========================================="
    echo "   恢复 MySQL 数据库"
    echo "=========================================="
    echo ""
    
    backup_dir="/var/backups/mysql"
    
    if [ ! -d "$backup_dir" ]; then
        print_error "备份目录不存在: $backup_dir"
        press_enter
        return
    fi
    
    # 列出备份文件
    print_info "可用的备份文件："
    ls -lh "$backup_dir"/*.sql.gz 2>/dev/null || echo "  没有找到备份文件"
    echo ""
    
    read -p "备份文件路径: " backup_file
    if [ ! -f "$backup_file" ]; then
        print_error "文件不存在"
        press_enter
        return
    fi
    
    read -p "目标数据库名称 (留空表示从备份恢复所有): " db_name
    
    print_warning "此操作将覆盖数据库数据"
    read -p "确认继续？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "正在恢复数据库..."
    
    # 解压并恢复
    if [[ "$backup_file" == *.gz ]]; then
        if [ -z "$db_name" ]; then
            gunzip -c "$backup_file" | sudo mysql
        else
            gunzip -c "$backup_file" | sudo mysql "$db_name"
        fi
    else
        if [ -z "$db_name" ]; then
            sudo mysql < "$backup_file"
        else
            sudo mysql "$db_name" < "$backup_file"
        fi
    fi
    
    if [ $? -eq 0 ]; then
        print_success "数据库恢复成功"
    else
        print_error "数据库恢复失败"
    fi
    
    press_enter
}


# 删除 MySQL 数据库
delete_mysql_database() {
    clear
    echo "=========================================="
    echo "   删除 MySQL 数据库"
    echo "=========================================="
    echo ""
    
    # 列出数据库
    print_info "可用的数据库："
    sudo mysql -N -e "SHOW DATABASES;" | grep -v "information_schema\|performance_schema\|mysql\|sys"
    echo ""
    
    read -p "要删除的数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    print_warning "警告：此操作将永久删除数据库 ${db_name}"
    read -p "请输入数据库名称以确认: " confirm_name
    
    if [ "$confirm_name" != "$db_name" ]; then
        print_error "名称不匹配，已取消"
        press_enter
        return
    fi
    
    print_info "正在删除数据库..."
    
    sudo mysql -e "DROP DATABASE ${db_name};"
    
    if [ $? -eq 0 ]; then
        print_success "数据库已删除"
    else
        print_error "数据库删除失败"
    fi
    
    press_enter
}


# MySQL 服务管理
manage_mysql_service() {
    clear
    echo "=========================================="
    echo "   MySQL 服务管理"
    echo "=========================================="
    echo ""
    
    echo "1. 查看服务状态"
    echo "2. 启动服务"
    echo "3. 停止服务"
    echo "4. 重启服务"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-4]: " choice
    
    # 检测使用的是 MySQL 还是 MariaDB
    service_name="mysql"
    if systemctl list-units --type=service | grep -q "mariadb"; then
        service_name="mariadb"
    fi
    
    case $choice in
        1)
            sudo systemctl status $service_name --no-pager -l
            ;;
        2)
            sudo systemctl start $service_name
            print_success "MySQL 服务已启动"
            ;;
        3)
            sudo systemctl stop $service_name
            print_success "MySQL 服务已停止"
            ;;
        4)
            sudo systemctl restart $service_name
            print_success "MySQL 服务已重启"
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}


# MySQL 子菜单
mysql_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   MySQL/MariaDB 管理"
        echo "=========================================="
        echo ""
        
        if check_mysql; then
            print_success "MySQL/MariaDB 已安装"
            mysql_version=$(mysql --version | awk '{print $5}' | sed 's/,//')
            echo "  版本: ${mysql_version}"
            
            # 显示服务状态
            if systemctl is-active --quiet mysql || systemctl is-active --quiet mariadb; then
                print_success "服务状态: 运行中"
            else
                print_error "服务状态: 已停止"
            fi
        else
            print_warning "MySQL/MariaDB 未安装"
        fi
        
        echo ""
        echo "1. 安装 MySQL/MariaDB"
        echo "2. 创建数据库"
        echo "3. 列出数据库"
        echo "4. 备份数据库"
        echo "5. 恢复数据库"
        echo "6. 删除数据库"
        echo "7. 服务管理"
        echo "0. 返回上级菜单"
        echo ""
        
        read -p "请选择 [0-7]: " choice
        
        case $choice in
            1) install_mysql ;;
            2) create_mysql_database ;;
            3) list_mysql_databases ;;
            4) backup_mysql_database ;;
            5) restore_mysql_database ;;
            6) delete_mysql_database ;;
            7) manage_mysql_service ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}


# ============================================
# 主菜单
# ============================================


main_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   数据库管理"
        echo "=========================================="
        echo ""
        
        # 显示安装状态
        if check_postgresql; then
            print_success "PostgreSQL: 已安装"
        else
            echo -e "${YELLOW}○${NC} PostgreSQL: 未安装"
        fi
        
        if check_mysql; then
            print_success "MySQL/MariaDB: 已安装"
        else
            echo -e "${YELLOW}○${NC} MySQL/MariaDB: 未安装"
        fi
        
        echo ""
        echo "1. PostgreSQL 管理"
        echo "2. MySQL/MariaDB 管理"
        echo ""
        echo "0. 返回主菜单"
        echo ""
        
        read -p "请选择 [0-2]: " choice
        
        case $choice in
            1) postgresql_menu ;;
            2) mysql_menu ;;
            0) exit 0 ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}


# 启动主菜单
main_menu
