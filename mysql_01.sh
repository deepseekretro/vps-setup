#!/bin/bash

# MySQL 菜单式管理器（带配置文件支持）
# 配置文件: ~/.mysql_manager.conf
# 版本: 2.5 (最终修复版)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 配置文件路径
CONFIG_FILE="$HOME/.mysql_manager.conf"
HTTP_CREDS_FILE="$HOME/.mysql_manager_http_creds.conf"
CURRENT_PROFILE=""

# 默认连接参数
DB_HOST="localhost"
DB_PORT="3306"
DB_USER="root"
DB_PASSWORD=""
DB_NAME=""

# 初始化配置文件
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
# MySQL Manager 配置文件
# 格式: [profile_name]
# host=主机地址
# port=端口
# user=用户名
# password=密码（可选）
# database=默认数据库（可选）
#
# 示例:
# [production]
# host=192.168.1.100
# port=3306
# user=admin
# password=secret123
# database=myapp

EOF
        chmod 600 "$CONFIG_FILE"
        echo -e "${GREEN}已创建配置文件: $CONFIG_FILE${NC}"
        sleep 1
    fi
}

# 读取所有配置名称
list_profiles() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return
    fi
    grep -v '^[[:space:]]*#' "$CONFIG_FILE" | grep -oP '(?<=\[)[^\]]+(?=\])'
}

# 加载指定配置
load_profile() {
    local profile=$1
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在${NC}"
        return 1
    fi
    
    if ! grep -v '^[[:space:]]*#' "$CONFIG_FILE" | grep -q "^\[$profile\]"; then
        echo -e "${RED}配置 '$profile' 不存在${NC}"
        return 1
    fi
    
    DB_HOST=""
    DB_PORT=""
    DB_USER=""
    DB_PASSWORD=""
    DB_NAME=""
    
    local in_section=0
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ "$line" =~ ^#.* ]] && continue
        [ -z "$line" ] && continue
        
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            local section_name="${BASH_REMATCH[1]}"
            if [ "$section_name" == "$profile" ]; then
                in_section=1
            else
                if [ $in_section -eq 1 ]; then
                    break
                fi
                in_section=0
            fi
            continue
        fi
        
        if [ $in_section -eq 1 ]; then
            if [[ "$line" =~ ^host=(.*)$ ]]; then
                DB_HOST="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^port=(.*)$ ]]; then
                DB_PORT="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^user=(.*)$ ]]; then
                DB_USER="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^password=(.*)$ ]]; then
                DB_PASSWORD="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^database=(.*)$ ]]; then
                DB_NAME="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$CONFIG_FILE"
    
    if [ -z "$DB_HOST" ] && [ -z "$DB_USER" ]; then
        echo -e "${RED}配置 '$profile' 数据不完整或格式错误${NC}"
        return 1
    fi
    
    DB_HOST=${DB_HOST:-localhost}
    DB_PORT=${DB_PORT:-3306}
    DB_USER=${DB_USER:-root}
    
    CURRENT_PROFILE="$profile"
    echo -e "${GREEN}✓ 已加载配置: $profile${NC}"
    return 0
}

# 保存当前配置
save_profile() {
    local profile=$1
    local is_overwrite=0
    
    if [ -z "$profile" ]; then
        read -p "请输入配置名称: " profile
    fi
    
    if [ -z "$profile" ]; then
        echo -e "${RED}配置名称不能为空${NC}"
        return 1
    fi
    
    if ! [[ "$profile" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}配置名称只能包含字母、数字、下划线和中划线${NC}"
        return 1
    fi
    
    if grep -v '^[[:space:]]*#' "$CONFIG_FILE" 2>/dev/null | grep -q "^\[$profile\]"; then
        echo -e "${YELLOW}警告: 配置 '$profile' 已经存在${NC}"
        
        echo -e "${CYAN}已保存的配置信息:${NC}"
        local old_host old_port old_user old_db
        local in_section=0
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ "$line" =~ ^#.* ]] && continue
            [ -z "$line" ] && continue
            
            if [[ "$line" =~ ^\[(.+)\]$ ]]; then
                if [ "${BASH_REMATCH[1]}" == "$profile" ]; then
                    in_section=1
                else
                    if [ $in_section -eq 1 ]; then
                        break
                    fi
                    in_section=0
                fi
                continue
            fi
            
            if [ $in_section -eq 1 ]; then
                if [[ "$line" =~ ^host=(.*)$ ]]; then
                    old_host="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^port=(.*)$ ]]; then
                    old_port="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^user=(.*)$ ]]; then
                    old_user="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^database=(.*)$ ]]; then
                    old_db="${BASH_REMATCH[1]}"
                fi
            fi
        done < "$CONFIG_FILE"
        
        echo "  主机: ${old_host:-未设置}"
        echo "  端口: ${old_port:-未设置}"
        echo "  用户: ${old_user:-未设置}"
        echo "  数据库: ${old_db:-未设置}"
        echo ""
        
        echo -e "${CYAN}新的配置信息:${NC}"
        echo "  主机: $DB_HOST"
        echo "  端口: $DB_PORT"
        echo "  用户: $DB_USER"
        echo "  数据库: ${DB_NAME:-未设置}"
        echo ""
        
        read -p "是否覆盖原配置？(yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            echo -e "${YELLOW}取消保存操作${NC}"
            return 0
        fi
        
        is_overwrite=1
    fi
    
    if [ $is_overwrite -eq 1 ]; then
        local temp_file=$(mktemp)
        local in_section=0
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ ^\[$profile\]$ ]]; then
                in_section=1
                continue
            fi
            if [ $in_section -eq 1 ]; then
                if [[ "$line" =~ ^\[.+\]$ ]]; then
                    in_section=0
                    echo "$line" >> "$temp_file"
                fi
            else
                echo "$line" >> "$temp_file"
            fi
        done < "$CONFIG_FILE"
        mv "$temp_file" "$CONFIG_FILE"
        echo -e "${GREEN}✓ 已删除旧配置${NC}"
    fi
    
    echo "" >> "$CONFIG_FILE"
    cat >> "$CONFIG_FILE" << EOF
[$profile]
host=$DB_HOST
port=$DB_PORT
user=$DB_USER
password=$DB_PASSWORD
database=$DB_NAME
EOF
    
    CURRENT_PROFILE="$profile"
    chmod 600 "$CONFIG_FILE"
    
    if [ $is_overwrite -eq 1 ]; then
        echo -e "${GREEN}✓ 配置 '$profile' 已更新${NC}"
    else
        echo -e "${GREEN}✓ 配置 '$profile' 已保存${NC}"
    fi
}

# 删除配置
delete_profile() {
    local profiles=($(list_profiles))
    
    if [ ${#profiles[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有可删除的配置${NC}"
        return
    fi
    
    echo -e "${CYAN}可用的配置：${NC}"
    for i in "${!profiles[@]}"; do
        if [ "${profiles[$i]}" == "$CURRENT_PROFILE" ]; then
            echo "  $((i+1)). ${GREEN}${profiles[$i]} (当前)${NC}"
        else
            echo "  $((i+1)). ${profiles[$i]}"
        fi
    done
    echo ""
    
    read -p "请选择要删除的配置 [1-${#profiles[@]}]: " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#profiles[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
    
    local profile="${profiles[$((choice-1))]}"
    
    read -p "确认删除配置 '$profile' 吗？(yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}取消删除${NC}"
        return 0
    fi
    
    local temp_file=$(mktemp)
    local in_section=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^\[$profile\]$ ]]; then
            in_section=1
            continue
        fi
        if [ $in_section -eq 1 ]; then
            if [[ "$line" =~ ^\[.+\]$ ]]; then
                in_section=0
                echo "$line" >> "$temp_file"
            fi
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$CONFIG_FILE"
    mv "$temp_file" "$CONFIG_FILE"
    
    echo -e "${GREEN}✓ 配置 '$profile' 已删除${NC}"
    
    if [ "$CURRENT_PROFILE" == "$profile" ]; then
        CURRENT_PROFILE=""
        echo -e "${YELLOW}当前配置已被删除，请重新选择连接${NC}"
    fi
}

# 选择历史连接
select_profile() {
    local profiles=($(list_profiles))
    
    if [ ${#profiles[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有保存的配置，请先创建连接配置${NC}"
        return 1
    fi
    
    clear
    echo -e "${CYAN}======== 历史连接 ========${NC}"
    for i in "${!profiles[@]}"; do
        if [ "${profiles[$i]}" == "$CURRENT_PROFILE" ]; then
            echo -e "  $((i+1)). ${GREEN}${profiles[$i]} (当前)${NC}"
        else
            echo "  $((i+1)). ${profiles[$i]}"
        fi
    done
    echo "  0. 返回"
    echo ""
    
    read -p "请选择配置 [0-${#profiles[@]}]: " choice
    
    if [ "$choice" == "0" ]; then
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#profiles[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
    
    load_profile "${profiles[$((choice-1))]}"
}

# 检查 MySQL 客户端是否安装
check_mysql_client() {
    if ! command -v mysql &> /dev/null; then
        echo -e "${RED}错误: 未检测到 mysql 客户端${NC}"
        echo ""
        echo -e "${YELLOW}MySQL 客户端未安装，需要安装才能使用此脚本。${NC}"
        echo ""
        read -p "是否现在安装 MySQL 客户端？[Y/n]: " install_choice
        
        if [[ ! "$install_choice" =~ ^[Nn]$ ]]; then
            echo ""
            echo -e "${BLUE}正在安装 MySQL 客户端...${NC}"
            echo ""
            
            # Debian 12 默认使用 MariaDB 客户端
            if sudo apt-get update && sudo apt-get install -y default-mysql-client; then
                echo ""
                echo -e "${GREEN}✓ MySQL 客户端安装成功！${NC}"
                echo ""
                
                # 显示安装的版本
                if command -v mysql &> /dev/null; then
                    mysql --version
                fi
                echo ""
                echo -e "${CYAN}提示: Debian 12 默认安装的是 MariaDB 客户端，与 MySQL 完全兼容${NC}"
                echo ""
                read -p "按 Enter 键继续..."
            else
                echo ""
                echo -e "${RED}✗ 安装失败${NC}"
                echo ""
                echo -e "${YELLOW}请手动安装 MySQL 客户端：${NC}"
                echo "  sudo apt-get update"
                echo "  sudo apt-get install -y default-mysql-client"
                echo ""
                exit 1
            fi
        else
            echo ""
            echo -e "${YELLOW}已取消安装，脚本无法继续运行${NC}"
            exit 1
        fi
    fi
    
    if ! command -v mysqldump &> /dev/null; then
        echo -e "${RED}错误: 未检测到 mysqldump 工具${NC}"
        echo -e "${YELLOW}这通常不应该发生，mysqldump 应该随 MySQL 客户端一起安装${NC}"
        echo ""
        echo -e "${YELLOW}请尝试重新安装：${NC}"
        echo "  sudo apt-get install --reinstall default-mysql-client"
        echo ""
        exit 1
    fi
}

# 测试连接
test_connection() {
    echo -e "${BLUE}测试连接: $DB_USER@$DB_HOST:$DB_PORT${NC}"
    if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1;" 2>/dev/null; then
        echo -e "${GREEN}✓ 连接成功！${NC}"
        return 0
    else
        echo -e "${RED}✗ 连接失败，请检查主机、端口、用户名或密码${NC}"
        return 1
    fi
}

# 显示数据库列表
show_databases() {
    echo -e "${BLUE}可用的数据库列表：${NC}"
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "SHOW DATABASES;" 2>/dev/null || {
        echo -e "${RED}获取数据库列表失败${NC}"
        return 1
    }
}

# 选择数据库
select_database() {
    echo -e "${BLUE}可用的数据库列表：${NC}"
    
    local databases=($(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -N -e "SHOW DATABASES;" 2>/dev/null))
    
    if [ ${#databases[@]} -eq 0 ]; then
        echo -e "${RED}获取数据库列表失败或没有可用数据库${NC}"
        return 1
    fi
    
    for i in "${!databases[@]}"; do
        if [ "${databases[$i]}" == "$DB_NAME" ]; then
            echo -e "  $((i+1)). ${GREEN}${databases[$i]} (当前)${NC}"
        else
            echo "  $((i+1)). ${databases[$i]}"
        fi
    done
    echo "  0. 返回"
    echo ""
    
    read -p "请选择数据库 [0-${#databases[@]}]: " choice
    
    if [ "$choice" == "0" ]; then
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#databases[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
    
    DB_NAME="${databases[$((choice-1))]}"
    echo -e "${GREEN}✓ 已选择数据库: $DB_NAME${NC}"
}

# 显示表列表（增强版 - 最终修复版）
show_tables() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}        显示表列表和数据${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo ""
    
    # 获取数据库列表
    local databases=($(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -N -e "SHOW DATABASES;" 2>/dev/null | grep -v -E '^(information_schema|mysql|performance_schema|sys)$'))
    
    if [ ${#databases[@]} -eq 0 ]; then
        echo -e "${RED}没有可用的数据库${NC}"
        return 1
    fi
    
    echo -e "${CYAN}可用的数据库列表：${NC}"
    for i in "${!databases[@]}"; do
        local db="${databases[$i]}"
        # 使用 SHOW TABLES 计数，更兼容
        local table_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$db" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
        
        if [ "$db" == "$DB_NAME" ]; then
            echo -e "  $((i+1)). ${GREEN}$db${NC} ${YELLOW}(当前)${NC} - ${table_count:-0} 张表"
        else
            echo "  $((i+1)). $db - ${table_count:-0} 张表"
        fi
    done
    echo "  0. 返回"
    echo ""
    
    read -p "请选择数据库 [0-${#databases[@]}]: " choice
    
    if [ "$choice" == "0" ]; then
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#databases[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
    
    local selected_db="${databases[$((choice-1))]}"
    DB_NAME="$selected_db"
    
    echo ""
    echo -e "${BLUE}正在获取数据库 ${CYAN}$selected_db${BLUE} 的表信息...${NC}"
    echo ""
    
    # 修复：使用 SHOW TABLES 而不是 information_schema
    local table_list=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$selected_db" -N -e "SHOW TABLES;" 2>/dev/null)
    
    if [ -z "$table_list" ]; then
        echo -e "${YELLOW}数据库 '$selected_db' 中没有表${NC}"
        return 0
    fi
    
    # 解析表信息到数组
    declare -a table_names
    declare -A table_rows
    declare -A table_sizes
    declare -A table_engines
    declare -A table_comments
    
    local index=0
    while IFS= read -r table; do
        [ -z "$table" ] && continue
        table_names[$index]="$table"
        
        # 获取每个表的详细信息
        local table_status=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$selected_db" -e "SHOW TABLE STATUS LIKE '$table'\\G" 2>/dev/null)
        
        # 解析表状态信息
        local rows=$(echo "$table_status" | grep "Rows:" | awk '{print $2}')
        local data_length=$(echo "$table_status" | grep "Data_length:" | awk '{print $2}')
        local index_length=$(echo "$table_status" | grep "Index_length:" | awk '{print $2}')
        local engine=$(echo "$table_status" | grep "Engine:" | awk '{print $2}')
        local comment=$(echo "$table_status" | grep "Comment:" | awk '{$1=""; print $0}' | sed 's/^[[:space:]]*//')
        
        # 计算大小（MB）
        local size_bytes=$((data_length + index_length))
        local size_mb=$(echo "scale=2; $size_bytes / 1024 / 1024" | bc 2>/dev/null)
        
        table_rows["$table"]="${rows:-0}"
        table_sizes["$table"]="${size_mb:-0.00}"
        table_engines["$table"]="${engine:-Unknown}"
        table_comments["$table"]="${comment}"
        
        ((index++))
    done <<< "$table_list"
    
    if [ ${#table_names[@]} -eq 0 ]; then
        echo -e "${YELLOW}数据库 '$selected_db' 中没有表${NC}"
        return 0
    fi
    
    # 显示表列表
    clear
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  数据库: ${YELLOW}$selected_db${NC}"
    echo -e "${CYAN}  总表数: ${YELLOW}${#table_names[@]}${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo -e "${GREEN}表列表：${NC}"
    printf "${CYAN}%-4s %-30s %12s %10s %-10s %s${NC}\n" "序号" "表名" "行数" "大小(MB)" "引擎" "注释"
    echo "--------------------------------------------------------------------------------"
    
    for i in "${!table_names[@]}"; do
        local tname="${table_names[$i]}"
        local trows="${table_rows[$tname]}"
        local tsize="${table_sizes[$tname]}"
        local tengine="${table_engines[$tname]}"
        local tcomment="${table_comments[$tname]}"
        
        # 截断过长的注释
        if [ ${#tcomment} -gt 20 ]; then
            tcomment="${tcomment:0:17}..."
        fi
        
        printf "%-4s %-30s %12s %10s %-10s %s\n" "$((i+1))." "$tname" "$trows" "$tsize" "$tengine" "$tcomment"
    done
    
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # 询问是否显示数据
    read -p "是否显示每个表的最新数据？(yes/no) [yes]: " show_data
    show_data=${show_data:-yes}
    
    if [ "$show_data" != "yes" ]; then
        return 0
    fi
    
    # 询问显示多少条记录
    echo ""
    read -p "每个表显示多少条最新记录？[默认: 5]: " record_count
    record_count=${record_count:-5}
    
    if ! [[ "$record_count" =~ ^[0-9]+$ ]] || [ "$record_count" -lt 1 ]; then
        echo -e "${RED}无效的记录数${NC}"
        return 1
    fi
    
    # 询问排序方式
    echo ""
    echo -e "${YELLOW}记录排序方式：${NC}"
    echo "  1. 按主键倒序（推荐）"
    echo "  2. 自动检测时间字段排序"
    echo "  3. 不排序（显示前N条）"
    echo ""
    read -p "请选择排序方式 [1-3, 默认: 1]: " sort_mode
    sort_mode=${sort_mode:-1}
    
    # 显示每个表的数据
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  开始显示表数据...${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    local processed=0
    local total=${#table_names[@]}
    
    for table in "${table_names[@]}"; do
        processed=$((processed + 1))
        
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}[$processed/$total] 表: ${YELLOW}$table${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        # 获取表的行数
        local row_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$selected_db" -N -e "SELECT COUNT(*) FROM \`$table\`;" 2>/dev/null)
        
        if [ -z "$row_count" ] || [ "$row_count" -eq 0 ]; then
            echo -e "${YELLOW}  (空表，没有记录)${NC}"
            echo ""
            continue
        fi
        
        echo -e "${CYAN}  总记录数: $row_count${NC}"
        
        # 构建查询语句
        local query=""
        
        case $sort_mode in
            1)
                # 按主键倒序
                local primary_key=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$selected_db" -N -e "SHOW KEYS FROM \`$table\` WHERE Key_name = 'PRIMARY';" 2>/dev/null | awk '{print $5}' | head -1)
                
                if [ -n "$primary_key" ]; then
                    query="SELECT * FROM \`$table\` ORDER BY \`$primary_key\` DESC LIMIT $record_count;"
                    echo -e "${CYAN}  排序: $primary_key (主键) DESC${NC}"
                else
                    query="SELECT * FROM \`$table\` LIMIT $record_count;"
                    echo -e "${YELLOW}  (无主键，显示前$record_count条)${NC}"
                fi
                ;;
            2)
                # 自动检测时间字段
                local time_field=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$selected_db" -N -e "SHOW COLUMNS FROM \`$table\` WHERE Type LIKE '%datetime%' OR Type LIKE '%timestamp%' OR Field LIKE '%time%' OR Field LIKE '%date%';" 2>/dev/null | awk '{print $1}' | head -1)
                
                if [ -n "$time_field" ]; then
                    query="SELECT * FROM \`$table\` ORDER BY \`$time_field\` DESC LIMIT $record_count;"
                    echo -e "${CYAN}  排序: $time_field (时间) DESC${NC}"
                else
                    local primary_key=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$selected_db" -N -e "SHOW KEYS FROM \`$table\` WHERE Key_name = 'PRIMARY';" 2>/dev/null | awk '{print $5}' | head -1)
                    if [ -n "$primary_key" ]; then
                        query="SELECT * FROM \`$table\` ORDER BY \`$primary_key\` DESC LIMIT $record_count;"
                        echo -e "${CYAN}  排序: $primary_key (主键) DESC${NC}"
                    else
                        query="SELECT * FROM \`$table\` LIMIT $record_count;"
                        echo -e "${YELLOW}  (无时间字段，显示前$record_count条)${NC}"
                    fi
                fi
                ;;
            3)
                # 不排序
                query="SELECT * FROM \`$table\` LIMIT $record_count;"
                echo -e "${CYAN}  (不排序)${NC}"
                ;;
        esac
        
        echo ""
        
        # 执行查询并显示结果
        if ! mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$selected_db" -t -e "$query" 2>/dev/null; then
            echo -e "${RED}  ✗ 查询失败${NC}"
        fi
        
        echo ""
    done
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✓ 完成！已显示 $processed 张表的数据${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# 进入 MySQL 控制台
enter_mysql_console() {
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}        进入 MySQL 控制台${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo ""
    echo -e "${BLUE}连接信息：${NC}"
    echo -e "  主机: ${YELLOW}$DB_HOST${NC}"
    echo -e "  端口: ${YELLOW}$DB_PORT${NC}"
    echo -e "  用户: ${YELLOW}$DB_USER${NC}"
    [ -n "$DB_NAME" ] && echo -e "  数据库: ${YELLOW}$DB_NAME${NC}"
    echo ""
    echo -e "${YELLOW}提示: 输入 'exit' 或按 Ctrl+D 退出控制台${NC}"
    echo ""
    
    # 进入 MySQL 控制台
    if [ -n "$DB_NAME" ]; then
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME"
    else
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD"
    fi
    
    echo ""
    echo -e "${GREEN}✓ 已退出 MySQL 控制台${NC}"
}

# 备份数据库（增强版 - 先选择数据库）
backup_database() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}        备份数据库${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo ""
    
    # 获取数据库列表（排除系统数据库）
    local databases=($(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -N -e "SHOW DATABASES;" 2>/dev/null | grep -v -E '^(information_schema|mysql|performance_schema|sys)$'))
    
    if [ ${#databases[@]} -eq 0 ]; then
        echo -e "${RED}没有可备份的数据库${NC}"
        return 1
    fi
    
    echo -e "${CYAN}可用的数据库列表：${NC}"
    for i in "${!databases[@]}"; do
        local db="${databases[$i]}"
        
        # 获取数据库大小和表数量
        local table_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$db" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
        local db_size=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -N -e "SELECT ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db';" 2>/dev/null)
        
        if [ "$db" == "$DB_NAME" ]; then
            echo -e "  $((i+1)). ${GREEN}$db${NC} ${YELLOW}(当前)${NC} - ${table_count:-0} 张表, ${db_size:-0} MB"
        else
            echo "  $((i+1)). $db - ${table_count:-0} 张表, ${db_size:-0} MB"
        fi
    done
    echo "  0. 返回"
    echo ""
    
    read -p "请选择要备份的数据库 [0-${#databases[@]}]: " choice
    
    if [ "$choice" == "0" ]; then
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#databases[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
    
    local backup_db="${databases[$((choice-1))]}"
    
    # 显示备份详情
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}        备份确认${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "数据库: ${YELLOW}$backup_db${NC}"
    
    local table_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$backup_db" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
    local db_size=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -N -e "SELECT ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$backup_db';" 2>/dev/null)
    
    echo -e "表数量: ${CYAN}${table_count:-0}${NC}"
    echo -e "数据库大小: ${CYAN}${db_size:-0} MB${NC}"
    echo ""
    
    # 显示前5个表
    if [ "${table_count:-0}" -gt 0 ]; then
        echo -e "${CYAN}包含的表（前5个）：${NC}"
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$backup_db" -N -e "SHOW TABLES;" 2>/dev/null | head -5 | while read table; do
            echo "  - $table"
        done
        if [ "${table_count:-0}" -gt 5 ]; then
            echo "  ..."
        fi
        echo ""
    fi
    
    read -p "确认备份数据库 '$backup_db'？(yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}已取消备份操作${NC}"
        return 0
    fi
    
    # 生成备份文件名
    timestamp=$(date +"%Y%m%d_%H%M%S")
    backup_file="${backup_db}_backup_${timestamp}.sql.bz2"
    
    echo ""
    echo -e "${BLUE}正在备份数据库 $backup_db 到 $backup_file ...${NC}"
    echo -e "${CYAN}备份参数: --single-transaction --quick --routines --triggers --events${NC}"
    echo ""
    
    # 显示进度提示
    echo -e "${YELLOW}提示: 大型数据库备份可能需要较长时间，请耐心等待...${NC}"
    echo ""
    
    if mysqldump -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" \
        --databases "${backup_db}" \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --events \
        --hex-blob \
        --add-drop-database \
        --default-character-set=utf8mb4 \
        2>/dev/null | bzip2 > "${backup_file}"; then
        
        file_size=$(ls -lh "${backup_file}" | awk '{print $5}')
        echo -e "${GREEN}✓ 备份成功！${NC}"
        echo ""
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}        备份完成${NC}"
        echo -e "${CYAN}========================================${NC}"
        echo -e "  数据库: ${YELLOW}$backup_db${NC}"
        echo -e "  文件名: ${CYAN}${backup_file}${NC}"
        echo -e "  文件大小: ${CYAN}${file_size}${NC}"
        echo -e "  压缩格式: ${CYAN}bzip2${NC}"
        echo -e "  保存位置: ${CYAN}$(pwd)/${backup_file}${NC}"
        echo ""
        
        # 计算压缩比
        if [ -n "$db_size" ] && [ "$db_size" != "NULL" ] && [ "$db_size" != "0" ]; then
            local file_size_mb=$(ls -l "${backup_file}" | awk '{printf "%.2f", $5/1024/1024}')
            local compress_ratio=$(echo "scale=2; (1 - $file_size_mb / $db_size) * 100" | bc 2>/dev/null)
            if [ -n "$compress_ratio" ]; then
                echo -e "  压缩率: ${CYAN}${compress_ratio}%${NC}"
                echo ""
            fi
        fi
        
        read -p "是否预览备份内容前100行？(yes/no): " preview
        if [ "$preview" == "yes" ]; then
            echo ""
            echo -e "${BLUE}======== 备份内容预览（前100行）========${NC}"
            bzcat "${backup_file}" | head -n 100
            echo -e "${BLUE}========================================${NC}"
        fi
        
        # 询问是否切换到备份的数据库
        echo ""
        if [ "$DB_NAME" != "$backup_db" ]; then
            read -p "是否切换到数据库 '$backup_db'？(yes/no): " switch_db
            if [ "$switch_db" == "yes" ]; then
                DB_NAME="$backup_db"
                echo -e "${GREEN}✓ 已切换到数据库: $DB_NAME${NC}"
            fi
        fi
    else
        echo -e "${RED}✗ 备份失败${NC}"
        rm -f "${backup_file}"
        
        echo ""
        echo -e "${YELLOW}可能的失败原因：${NC}"
        echo "  1. 权限不足（需要 SELECT, SHOW VIEW, TRIGGER 权限）"
        echo "  2. 磁盘空间不足"
        echo "  3. 数据库连接超时"
        echo "  4. 某些表被锁定"
        
        return 1
    fi
}

# 显示错误日志
show_error_log() {
    if [ -f /tmp/mysql_error.log ]; then
        local error_content=$(cat /tmp/mysql_error.log)
        if [ -n "$error_content" ]; then
            echo -e "${RED}错误信息：${NC}"
            cat /tmp/mysql_error.log
        fi
        rm -f /tmp/mysql_error.log
    fi
}

# 执行还原操作
perform_restore() {
    local selected_file="$1"
    
    if [ ! -f "$selected_file" ]; then
        echo -e "${RED}文件不存在: $selected_file${NC}"
        return 1
    fi
    
    local has_create_db=0
    local original_db=""
    
    echo -e "${BLUE}正在分析备份文件...${NC}"
    
    if bzcat "$selected_file" | grep -q '^CREATE DATABASE'; then
        has_create_db=1
        original_db=$(bzcat "$selected_file" | grep -m 1 '^CREATE DATABASE' | sed -n 's/.*`\([^`]*\)`.*/\1/p')
    fi
    
    if [ $has_create_db -eq 0 ]; then
        if bzcat "$selected_file" | grep -q '^/\*!.*CREATE DATABASE'; then
            has_create_db=1
            original_db=$(bzcat "$selected_file" | grep -m 1 'CREATE DATABASE' | sed -n 's/.*`\([^`]*\)`.*/\1/p')
        fi
    fi
    
    local has_use_db=0
    if bzcat "$selected_file" | grep -q '^USE '; then
        has_use_db=1
    fi
    
    echo ""
    echo -e "${CYAN}备份文件分析结果：${NC}"
    echo -e "  文件: ${selected_file}"
    if [ $has_create_db -eq 1 ]; then
        echo -e "  包含 CREATE DATABASE: ${GREEN}是${NC}"
        [ -n "$original_db" ] && echo -e "  原始数据库名: ${YELLOW}$original_db${NC}"
    else
        echo -e "  包含 CREATE DATABASE: ${RED}否${NC}"
    fi
    if [ $has_use_db -eq 1 ]; then
        echo -e "  包含 USE 语句: ${GREEN}是${NC}"
    else
        echo -e "  包含 USE 语句: ${RED}否${NC}"
    fi
    echo ""
    
    echo -e "${YELLOW}选择还原方式：${NC}"
    echo "  1. 直接还原（保留原始数据库名: ${original_db:-无}）"
    echo "  2. 还原到自定义数据库（替换数据库名）"
    echo "  3. 还原到已选择的数据库（覆盖当前数据库）"
    echo "  0. 返回"
    echo ""
    
    read -p "请选择 [0-3]: " restore_mode
    
    case $restore_mode in
        0)
            return 0
            ;;
        1)
            if [ $has_create_db -eq 0 ]; then
                echo -e "${RED}错误: 备份文件中没有 CREATE DATABASE 语句，无法直接还原${NC}"
                echo -e "${YELLOW}请选择方式 2 或 3${NC}"
                return 1
            fi
            
            if [ -z "$original_db" ]; then
                echo -e "${RED}无法从备份文件中提取数据库名${NC}"
                return 1
            fi
            
            echo -e "${BLUE}正在直接还原到数据库: $original_db${NC}"
            echo -e "${YELLOW}说明: 如果数据库已存在且备份包含 DROP TABLE，会先删除同名表${NC}"
            echo ""
            read -p "确认继续？(yes/no): " confirm
            
            if [ "$confirm" != "yes" ]; then
                echo -e "${YELLOW}取消还原操作${NC}"
                return 0
            fi
            
            if bzcat "$selected_file" | mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" 2>/tmp/mysql_error.log; then
                echo -e "${GREEN}✓ 还原成功！${NC}"
                echo -e "  数据库: ${CYAN}$original_db${NC}"
                
                local table_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$original_db" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
                echo -e "  表数量: ${CYAN}${table_count:-0}${NC}"
                
                read -p "是否切换到该数据库？(yes/no): " switch_db
                if [ "$switch_db" == "yes" ]; then
                    DB_NAME="$original_db"
                    echo -e "${GREEN}✓ 已切换到数据库: $DB_NAME${NC}"
                fi
            else
                echo -e "${RED}✗ 还原失败${NC}"
                show_error_log
                return 1
            fi
            ;;
        2)
            read -p "请输入目标数据库名称: " target_db
            if [ -z "$target_db" ]; then
                echo -e "${RED}数据库名称不能为空${NC}"
                return 1
            fi
            
            if ! [[ "$target_db" =~ ^[a-zA-Z0-9_]+$ ]]; then
                echo -e "${RED}数据库名称只能包含字母、数字和下划线${NC}"
                return 1
            fi
            
            if [ $has_create_db -eq 1 ]; then
                echo -e "${BLUE}正在还原到数据库: $target_db${NC}"
                echo -e "${YELLOW}说明: 会将备份中的数据库名 '$original_db' 替换为 '$target_db'${NC}"
                echo ""
                
                local temp_sql=$(mktemp) || {
                    echo -e "${RED}创建临时文件失败${NC}"
                    return 1
                }
                trap "rm -f '$temp_sql'" RETURN
                chmod 600 "$temp_sql"
                
                echo -e "${BLUE}正在处理备份文件...${NC}"
                bzcat "$selected_file" | sed \
                    -e 's/`'"$original_db"'`/`'"$target_db"'`/g' \
                    -e "s/'$original_db'/'$target_db'/g" \
                    -e "s/\"$original_db\"/\"$target_db\"/g" \
                    > "$temp_sql"
                
                echo -e "${BLUE}正在导入数据...${NC}"
                if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" < "$temp_sql" 2>/tmp/mysql_error.log; then
                    echo -e "${GREEN}✓ 还原成功！${NC}"
                    echo -e "  数据库: ${CYAN}$target_db${NC}"
                    
                    local table_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$target_db" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
                    echo -e "  表数量: ${CYAN}${table_count:-0}${NC}"
                    
                    read -p "是否切换到该数据库？(yes/no): " switch_db
                    if [ "$switch_db" == "yes" ]; then
                        DB_NAME="$target_db"
                        echo -e "${GREEN}✓ 已切换到数据库: $DB_NAME${NC}"
                    fi
                else
                    echo -e "${RED}✗ 还原失败${NC}"
                    show_error_log
                    return 1
                fi
            else
                echo -e "${BLUE}正在创建数据库: $target_db${NC}"
                if ! mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$target_db\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null; then
                    echo -e "${RED}✗ 创建数据库失败${NC}"
                    return 1
                fi
                
                echo -e "${BLUE}正在导入数据到 $target_db ...${NC}"
                if bzcat "$selected_file" | mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$target_db" 2>/tmp/mysql_error.log; then
                    echo -e "${GREEN}✓ 还原成功！${NC}"
                    echo -e "  数据库: ${CYAN}$target_db${NC}"
                    
                    local table_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$target_db" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
                    echo -e "  表数量: ${CYAN}${table_count:-0}${NC}"
                    
                    read -p "是否切换到该数据库？(yes/no): " switch_db
                    if [ "$switch_db" == "yes" ]; then
                        DB_NAME="$target_db"
                        echo -e "${GREEN}✓ 已切换到数据库: $DB_NAME${NC}"
                    fi
                else
                    echo -e "${RED}✗ 还原失败${NC}"
                    show_error_log
                    return 1
                fi
            fi
            ;;
        3)
            if [ -z "$DB_NAME" ]; then
                echo -e "${YELLOW}请先选择目标数据库${NC}"
                echo ""
                select_database
                
                if [ -z "$DB_NAME" ]; then
                    echo -e "${RED}未选择数据库，无法还原${NC}"
                    return 1
                fi
            fi
            
            echo ""
            echo -e "${RED}警告: 此操作会将数据还原到数据库 '$DB_NAME'${NC}"
            echo -e "${YELLOW}如果备份包含 DROP TABLE，会先删除同名表${NC}"
            echo ""
            read -p "确认还原到数据库 '$DB_NAME' 吗？输入数据库名确认: " confirm
            
            if [ "$confirm" != "$DB_NAME" ]; then
                echo -e "${YELLOW}取消还原操作${NC}"
                return 0
            fi
            
            if [ $has_create_db -eq 1 ]; then
                echo -e "${BLUE}正在处理备份文件（过滤 CREATE DATABASE 和 USE 语句）...${NC}"
                
                if [ -n "$original_db" ] && [ "$original_db" != "$DB_NAME" ]; then
                    local temp_sql=$(mktemp) || {
                        echo -e "${RED}创建临时文件失败${NC}"
                        return 1
                    }
                    trap "rm -f '$temp_sql'" RETURN
                    chmod 600 "$temp_sql"
                    
                    bzcat "$selected_file" | sed \
                        -e '/^\/\*!.*CREATE DATABASE/d' \
                        -e '/^CREATE DATABASE/d' \
                        -e '/^USE /d' \
                        -e 's/`'"$original_db"'`/`'"$DB_NAME"'`/g' \
                        > "$temp_sql"
                    
                    if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" < "$temp_sql" 2>/tmp/mysql_error.log; then
                        echo -e "${GREEN}✓ 还原成功！${NC}"
                        echo -e "  数据库: ${CYAN}$DB_NAME${NC}"
                        
                        local table_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
                        echo -e "  表数量: ${CYAN}${table_count:-0}${NC}"
                    else
                        echo -e "${RED}✗ 还原失败${NC}"
                        show_error_log
                        return 1
                    fi
                else
                    bzcat "$selected_file" | sed \
                        -e '/^\/\*!.*CREATE DATABASE/d' \
                        -e '/^CREATE DATABASE/d' \
                        -e '/^USE /d' \
                        | mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" 2>/tmp/mysql_error.log
                    
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}✓ 还原成功！${NC}"
                        echo -e "  数据库: ${CYAN}$DB_NAME${NC}"
                        
                        local table_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
                        echo -e "  表数量: ${CYAN}${table_count:-0}${NC}"
                    else
                        echo -e "${RED}✗ 还原失败${NC}"
                        show_error_log
                        return 1
                    fi
                fi
            else
                echo -e "${BLUE}正在导入数据到 $DB_NAME ...${NC}"
                if bzcat "$selected_file" | mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" 2>/tmp/mysql_error.log; then
                    echo -e "${GREEN}✓ 还原成功！${NC}"
                    echo -e "  数据库: ${CYAN}$DB_NAME${NC}"
                    
                    local table_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
                    echo -e "  表数量: ${CYAN}${table_count:-0}${NC}"
                else
                    echo -e "${RED}✗ 还原失败${NC}"
                    show_error_log
                    return 1
                fi
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return 1
            ;;
    esac
}

# 还原本地备份文件
restore_local_backup() {
    local backup_files=($(ls -1 *.sql.bz2 2>/dev/null))
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        echo -e "${YELLOW}当前目录没有找到备份文件（*.sql.bz2）${NC}"
        return 1
    fi
    
    echo -e "${CYAN}可用的备份文件：${NC}"
    for i in "${!backup_files[@]}"; do
        local file_size=$(ls -lh "${backup_files[$i]}" | awk '{print $5}')
        local file_date=$(ls -l "${backup_files[$i]}" | awk '{print $6, $7, $8}')
        echo "  $((i+1)). ${backup_files[$i]} (${file_size}, ${file_date})"
    done
    echo "  0. 返回"
    echo ""
    
    read -p "请选择要还原的备份文件 [0-${#backup_files[@]}]: " choice
    
    if [ "$choice" == "0" ]; then
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backup_files[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
    
    local selected_file="${backup_files[$((choice-1))]}"
    perform_restore "$selected_file"
}

# 通过 SCP/SFTP 下载
download_via_scp() {
    echo ""
    echo -e "${CYAN}======== SCP/SFTP 下载 ========${NC}"
    echo ""
    
    read -p "远程主机地址: " remote_host
    if [ -z "$remote_host" ]; then
        echo -e "${RED}主机地址不能为空${NC}"
        return 1
    fi
    
    read -p "SSH 端口 [22]: " ssh_port
    ssh_port=${ssh_port:-22}
    
    read -p "SSH 用户名: " ssh_user
    if [ -z "$ssh_user" ]; then
        echo -e "${RED}用户名不能为空${NC}"
        return 1
    fi
    
    read -p "远程备份文件目录 [/var/backups/mysql]: " remote_dir
    remote_dir=${remote_dir:-/var/backups/mysql}
    
    echo ""
    echo -e "${BLUE}测试 SSH 连接...${NC}"
    if ! ssh -p "$ssh_port" -o ConnectTimeout=5 -o BatchMode=yes "$ssh_user@$remote_host" "echo 'SSH连接成功'" 2>/dev/null; then
        echo -e "${YELLOW}无密钥连接，将需要输入密码${NC}"
    else
        echo -e "${GREEN}✓ SSH 连接正常${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}正在获取远程备份文件列表...${NC}"
    
    local remote_files=$(ssh -p "$ssh_port" "$ssh_user@$remote_host" "ls -lh $remote_dir/*.sql.bz2 2>/dev/null" 2>/dev/null)
    
    if [ -z "$remote_files" ]; then
        echo -e "${RED}未找到远程备份文件或连接失败${NC}"
        echo -e "${YELLOW}提示: 请确保远程目录存在且有备份文件${NC}"
        return 1
    fi
    
    local file_list=($(ssh -p "$ssh_port" "$ssh_user@$remote_host" "ls $remote_dir/*.sql.bz2 2>/dev/null" 2>/dev/null))
    
    if [ ${#file_list[@]} -eq 0 ]; then
        echo -e "${RED}未找到备份文件${NC}"
        return 1
    fi
    
    echo -e "${CYAN}远程备份文件列表：${NC}"
    echo ""
    
    local index=1
    for file in "${file_list[@]}"; do
        local basename=$(basename "$file")
        local file_info=$(ssh -p "$ssh_port" "$ssh_user@$remote_host" "ls -lh $file 2>/dev/null" 2>/dev/null | awk '{print $5, $6, $7, $8}')
        echo "  $index. $basename ($file_info)"
        ((index++))
    done
    echo "  0. 返回"
    echo ""
    
    read -p "请选择要下载的文件 [0-${#file_list[@]}]: " file_choice
    
    if [ "$file_choice" == "0" ]; then
        return 0
    fi
    
    if ! [[ "$file_choice" =~ ^[0-9]+$ ]] || [ "$file_choice" -lt 1 ] || [ "$file_choice" -gt ${#file_list[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
    
    local selected_remote_file="${file_list[$((file_choice-1))]}"
    local local_filename=$(basename "$selected_remote_file")
    
    if [ -f "$local_filename" ]; then
        echo ""
        echo -e "${YELLOW}本地已存在同名文件: $local_filename${NC}"
        read -p "是否覆盖？(yes/no): " overwrite
        if [ "$overwrite" != "yes" ]; then
            local_filename="${local_filename%.sql.bz2}_$(date +%s).sql.bz2"
            echo -e "${CYAN}将保存为: $local_filename${NC}"
        fi
    fi
    
    echo ""
    echo -e "${BLUE}正在下载备份文件...${NC}"
    echo -e "  远程: ${CYAN}$selected_remote_file${NC}"
    echo -e "  本地: ${CYAN}$local_filename${NC}"
    echo ""
    
    if scp -P "$ssh_port" "$ssh_user@$remote_host:$selected_remote_file" "$local_filename"; then
        echo ""
        echo -e "${GREEN}✓ 下载成功！${NC}"
        
        local file_size=$(ls -lh "$local_filename" | awk '{print $5}')
        echo -e "  文件: ${CYAN}$local_filename${NC}"
        echo -e "  大小: ${CYAN}$file_size${NC}"
        echo ""
        
        read -p "是否立即还原此备份？(yes/no): " restore_now
        if [ "$restore_now" == "yes" ]; then
            echo ""
            perform_restore "$local_filename"
        else
            echo -e "${GREEN}备份文件已保存，可稍后通过菜单还原${NC}"
        fi
    else
        echo ""
        echo -e "${RED}✗ 下载失败${NC}"
        return 1
    fi
}

# 通过 HTTP/HTTPS 下载
download_via_http() {
    echo ""
    echo -e "${CYAN}======== HTTP/HTTPS 下载 ========${NC}"
    echo ""
    
    read -p "备份文件 URL: " backup_url
    if [ -z "$backup_url" ]; then
        echo -e "${RED}URL 不能为空${NC}"
        return 1
    fi
    
    if ! [[ "$backup_url" =~ ^https?:// ]]; then
        echo -e "${RED}无效的 URL 格式（需要 http:// 或 https://）${NC}"
        return 1
    fi
    
    local local_filename=$(basename "$backup_url")
    
    if [ -z "$local_filename" ] || [[ "$local_filename" != *.sql.bz2 ]]; then
        local_filename="backup_$(date +%Y%m%d_%H%M%S).sql.bz2"
        echo -e "${YELLOW}自动命名为: $local_filename${NC}"
    fi
    
    if [ -f "$local_filename" ]; then
        echo ""
        echo -e "${YELLOW}本地已存在同名文件: $local_filename${NC}"
        read -p "是否覆盖？(yes/no): " overwrite
        if [ "$overwrite" != "yes" ]; then
            local_filename="${local_filename%.sql.bz2}_$(date +%s).sql.bz2"
            echo -e "${CYAN}将保存为: $local_filename${NC}"
        fi
    fi
    
    local curl_opts="-L"
    local http_user=""
    local http_pass=""
    local need_auth="no"
    
    if [ "$http_code" == "401" ]; then
        need_auth="yes"
        echo -e "${YELLOW}检测到需要 HTTP 认证（HTTP 401）${NC}"
        echo ""
    echo -e "${BLUE}配置 HTTP 认证...${NC}"
        
    # 1. 尝试读取保存的凭据
        local saved_user=""
        local saved_pass=""
        
        if [ -f "$HTTP_CREDS_FILE" ]; then
            source "$HTTP_CREDS_FILE" 2>/dev/null
            saved_user="$HTTP_USERNAME"
            saved_pass="$HTTP_PASSWORD"
        fi
        
        # 如果有保存的凭据，显示并让用户确认
        if [ -n "$saved_user" ]; then
            echo -e "${CYAN}检测到已保存的认证信息：${NC}"
            echo -e "  用户名: ${YELLOW}$saved_user${NC}"
            echo -e "  密码: ${YELLOW}********${NC}"
            echo ""
            echo -e "${YELLOW}提示: 直接回车使用默认值，输入新值则覆盖${NC}"
            echo ""
            
            read -p "用户名 [$saved_user]: " http_user
            http_user=${http_user:-$saved_user}
            
            read -sp "密码 [使用已保存]: " http_pass
            echo ""
            http_pass=${http_pass:-$saved_pass}
        else
            read -p "用户名: " http_user
            read -sp "密码: " http_pass
            echo ""
        fi
        
        curl_opts="$curl_opts -u \"$http_user:$http_pass\""
    else
        echo -e "${GREEN}✓ 无需 HTTP 认证（HTTP $http_code）${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}正在下载备份文件...${NC}"
    echo -e "  URL: ${CYAN}$backup_url${NC}"
    echo -e "  保存为: ${CYAN}$local_filename${NC}"
    echo ""
    
    # 调试输出：显示完整的 curl 命令
    echo -e "${YELLOW}[DEBUG] 执行的 curl 命令：${NC}"
    echo -e "${CYAN}curl $curl_opts -o \"$local_filename\" \"$backup_url\"${NC}"
    echo ""
    
    if curl $curl_opts -o "$local_filename" "$backup_url" 2>&1; then
        # 检查文件是否成功下载（文件存在且大小大于0）
        if [ -f "$local_filename" ] && [ -s "$local_filename" ]; then
            echo ""
            echo -e "${GREEN}✓ 下载成功！${NC}"
            
            # 如果使用了认证且下载成功，自动保存凭据
            if [ "$need_auth" == "yes" ] && [ -n "$http_user" ]; then
                cat > "$HTTP_CREDS_FILE" <<EOF
# MySQL Manager HTTP 认证凭据
# 此文件由脚本自动生成和管理
HTTP_USERNAME="$http_user"
HTTP_PASSWORD="$http_pass"
EOF
                chmod 600 "$HTTP_CREDS_FILE"
                echo -e "${GREEN}✓ 认证信息已自动保存到: $HTTP_CREDS_FILE${NC}"
            fi
            
            local file_size=$(ls -lh "$local_filename" | awk '{print $5}')
            echo -e "  文件: ${CYAN}$local_filename${NC}"
            echo -e "  大小: ${CYAN}$file_size${NC}"
            echo ""
            
            if bzcat "$local_filename" > /dev/null 2>&1; then
                echo -e "${GREEN}✓ 文件完整性验证通过${NC}"
            else
                echo -e "${RED}⚠ 警告：文件可能已损坏${NC}"
                read -p "是否继续还原？(yes/no): " continue_restore
                if [ "$continue_restore" != "yes" ]; then
                    rm -f "$local_filename"
                    echo -e "${YELLOW}已删除损坏的文件${NC}"
                    return 1
                fi
            fi
            
            echo ""
            read -p "是否立即还原此备份？(yes/no): " restore_now
            if [ "$restore_now" == "yes" ]; then
                echo ""
                perform_restore "$local_filename"
            else
                echo -e "${GREEN}备份文件已保存，可稍后通过菜单还原${NC}"
            fi
        else
            echo ""
            echo -e "${RED}✗ 下载失败（文件为空或不存在）${NC}"
            rm -f "$local_filename"
            return 1
        fi
    else
        echo ""
        echo -e "${RED}✗ 下载失败${NC}"
        rm -f "$local_filename"
        return 1
    fi
}

# 通过 FTP 下载
download_via_ftp() {
    echo ""
    echo -e "${CYAN}======== FTP 下载 ========${NC}"
    echo ""
    
    read -p "FTP 主机地址: " ftp_host
    if [ -z "$ftp_host" ]; then
        echo -e "${RED}主机地址不能为空${NC}"
        return 1
    fi
    
    read -p "FTP 端口 [21]: " ftp_port
    ftp_port=${ftp_port:-21}
    
    read -p "FTP 用户名: " ftp_user
    if [ -z "$ftp_user" ]; then
        echo -e "${RED}用户名不能为空${NC}"
        return 1
    fi
    
    read -sp "FTP 密码: " ftp_pass
    echo ""
    
    read -p "远程备份文件路径（如: /backups/db.sql.bz2）: " remote_file
    if [ -z "$remote_file" ]; then
        echo -e "${RED}文件路径不能为空${NC}"
        return 1
    fi
    
    local local_filename=$(basename "$remote_file")
    
    if [ -f "$local_filename" ]; then
        echo ""
        echo -e "${YELLOW}本地已存在同名文件: $local_filename${NC}"
        read -p "是否覆盖？(yes/no): " overwrite
        if [ "$overwrite" != "yes" ]; then
            local_filename="${local_filename%.sql.bz2}_$(date +%s).sql.bz2"
            echo -e "${CYAN}将保存为: $local_filename${NC}"
        fi
    fi
    
    echo ""
    echo -e "${BLUE}正在下载备份文件...${NC}"
    echo -e "  FTP: ${CYAN}ftp://$ftp_host:$ftp_port$remote_file${NC}"
    echo -e "  保存为: ${CYAN}$local_filename${NC}"
    echo ""
    
    if wget --ftp-user="$ftp_user" --ftp-password="$ftp_pass" -O "$local_filename" "ftp://$ftp_host:$ftp_port$remote_file" 2>&1 | grep -v "^$"; then
        echo ""
        echo -e "${GREEN}✓ 下载成功！${NC}"
        
        local file_size=$(ls -lh "$local_filename" | awk '{print $5}')
        echo -e "  文件: ${CYAN}$local_filename${NC}"
        echo -e "  大小: ${CYAN}$file_size${NC}"
        echo ""
        
        read -p "是否立即还原此备份？(yes/no): " restore_now
        if [ "$restore_now" == "yes" ]; then
            echo ""
            perform_restore "$local_filename"
        else
            echo -e "${GREEN}备份文件已保存，可稍后通过菜单还原${NC}"
        fi
    else
        echo ""
        echo -e "${RED}✗ 下载失败${NC}"
        rm -f "$local_filename"
        return 1
    fi
}

# 下载远程备份文件并还原
restore_remote_backup() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}    下载远程备份文件并还原${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo ""
    
    echo -e "${YELLOW}支持的传输协议：${NC}"
    echo "  1. SCP/SFTP (SSH)"
    echo "  2. HTTP/HTTPS (curl)"
    echo "  3. FTP"
    echo "  0. 返回"
    echo ""
    
    read -p "请选择传输协议 [0-3]: " protocol_choice
    
    case $protocol_choice in
        1)
            download_via_scp
            ;;
        2)
            download_via_http
            ;;
        3)
            download_via_ftp
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return 1
            ;;
    esac
}

# 还原备份文件主菜单
restore_backup_menu() {
    clear
    echo -e "${CYAN}======================================${NC}"
    echo -e "${CYAN}        还原备份文件${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo ""
    echo "  1. 还原本地备份文件"
    echo "  2. 下载远程备份文件并还原"
    echo "  0. 返回"
    echo ""
    
    read -p "请选择 [0-2]: " choice
    
    case $choice in
        1)
            restore_local_backup
            ;;
        2)
            restore_remote_backup
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
}

# 预览备份文件
preview_backup() {
    local backup_files=($(ls -1 *.sql.bz2 2>/dev/null))
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        echo -e "${YELLOW}当前目录没有找到备份文件（*.sql.bz2）${NC}"
        return 1
    fi
    
    echo -e "${CYAN}可用的备份文件：${NC}"
    for i in "${!backup_files[@]}"; do
        local file_size=$(ls -lh "${backup_files[$i]}" | awk '{print $5}')
        echo "  $((i+1)). ${backup_files[$i]} (${file_size})"
    done
    echo "  0. 返回"
    echo ""
    
    read -p "请选择要预览的备份文件 [0-${#backup_files[@]}]: " choice
    
    if [ "$choice" == "0" ]; then
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backup_files[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
    
    local selected_file="${backup_files[$((choice-1))]}"
    
    echo ""
    read -p "预览多少行？[100]: " preview_lines
    preview_lines=${preview_lines:-100}
    
    echo ""
    echo -e "${BLUE}======== ${selected_file} 内容预览（前${preview_lines}行）========${NC}"
    bzcat "${selected_file}" | head -n ${preview_lines}
    echo -e "${BLUE}========================================${NC}"
}

# 导入 SQL 文件
import_sql_file() {
    read -p "请输入 SQL 文件路径: " sql_file
    
    if [ ! -f "$sql_file" ]; then
        echo -e "${RED}文件不存在: $sql_file${NC}"
        return 1
    fi
    
    if [ -z "$DB_NAME" ]; then
        echo -e "${YELLOW}未选择数据库，是否先选择数据库？(yes/no): ${NC}"
        read -p "" need_select
        if [ "$need_select" == "yes" ]; then
            select_database
        fi
    fi
    
    echo -e "${BLUE}正在导入 SQL 文件...${NC}"
    
    if [[ "$sql_file" =~ \.bz2$ ]]; then
        echo -e "${CYAN}检测到 bzip2 压缩文件，正在解压导入...${NC}"
        if [ -n "$DB_NAME" ]; then
            bzcat "$sql_file" | mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME" 2>/dev/null
        else
            bzcat "$sql_file" | mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" 2>/dev/null
        fi
    else
        if [ -n "$DB_NAME" ]; then
            mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME" < "$sql_file" 2>/dev/null
        else
            mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" < "$sql_file" 2>/dev/null
        fi
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ SQL 文件导入成功${NC}"
    else
        echo -e "${RED}✗ SQL 文件导入失败${NC}"
    fi
}

# 创建数据库
create_database() {
    read -p "请输入新数据库名称: " new_db
    if [ -z "$new_db" ]; then
        echo -e "${RED}数据库名称不能为空${NC}"
        return 1
    fi
    
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "CREATE DATABASE \`$new_db\`;" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 数据库 $new_db 创建成功${NC}"
        read -p "是否切换到新创建的数据库？(yes/no): " switch_db
        if [ "$switch_db" == "yes" ]; then
            DB_NAME="$new_db"
            echo -e "${GREEN}✓ 已切换到数据库: $DB_NAME${NC}"
        fi
    else
        echo -e "${RED}✗ 数据库创建失败${NC}"
    fi
}

# 删除数据库
drop_database() {
    echo -e "${BLUE}获取数据库列表...${NC}"
    
    local databases=($(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -N -e "SHOW DATABASES;" 2>/dev/null | grep -v -E '^(information_schema|mysql|performance_schema|sys)$'))
    
    if [ ${#databases[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有可删除的数据库（或仅有系统数据库）${NC}"
        return 1
    fi
    
    clear
    echo -e "${RED}======================================${NC}"
    echo -e "${RED}        删除数据库 (危险操作)${NC}"
    echo -e "${RED}======================================${NC}"
    echo ""
    echo -e "${CYAN}可用的数据库列表：${NC}"
    
    for i in "${!databases[@]}"; do
        local db="${databases[$i]}"
        
        local table_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$db" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
        local db_size=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -N -e "SELECT ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db';" 2>/dev/null)
        
        if [ "$db" == "$DB_NAME" ]; then
            echo -e "  $((i+1)). ${YELLOW}$db${NC} ${GREEN}(当前)${NC} - ${table_count:-0} 张表, ${db_size:-0} MB"
        else
            echo "  $((i+1)). $db - ${table_count:-0} 张表, ${db_size:-0} MB"
        fi
    done
    echo "  0. 返回"
    echo ""
    
    read -p "请选择要删除的数据库 [0-${#databases[@]}]: " choice
    
    if [ "$choice" == "0" ]; then
        echo -e "${YELLOW}已取消操作${NC}"
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#databases[@]} ]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi
    
    local del_db="${databases[$((choice-1))]}"
    
    echo ""
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}           警告：即将删除数据库${NC}"
    echo -e "${RED}========================================${NC}"
    echo -e "数据库名: ${YELLOW}$del_db${NC}"
    
    local table_count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$del_db" -N -e "SHOW TABLES;" 2>/dev/null | wc -l)
    local db_size=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -N -e "SELECT ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$del_db';" 2>/dev/null)
    
    echo -e "表数量: ${CYAN}${table_count:-0}${NC}"
    echo -e "数据库大小: ${CYAN}${db_size:-0} MB${NC}"
    echo ""
    
    if [ "${table_count:-0}" -gt 0 ]; then
        echo -e "${CYAN}包含的表（前5个）：${NC}"
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$del_db" -N -e "SHOW TABLES;" 2>/dev/null | head -5 | while read table; do
            echo "  - $table"
        done
        if [ "${table_count:-0}" -gt 5 ]; then
            echo "  ..."
        fi
        echo ""
    fi
    
    echo -e "${RED}此操作将永久删除数据库及其所有数据！${NC}"
    echo -e "${YELLOW}建议先备份数据库！${NC}"
    echo ""
    read -p "确认删除数据库 '$del_db' 吗？(yes/no): " confirm1
    
    if [ "$confirm1" != "yes" ]; then
        echo -e "${GREEN}✓ 已取消删除操作${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${RED}最后确认：请输入要删除的数据库名称以确认操作${NC}"
    read -p "数据库名称: " confirm2
    
    if [ "$confirm2" != "$del_db" ]; then
        echo -e "${YELLOW}输入的数据库名称不匹配，取消删除操作${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${BLUE}正在删除数据库 '$del_db' ...${NC}"
    
    if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "DROP DATABASE \`$del_db\`;" 2>/tmp/mysql_error.log; then
        echo -e "${GREEN}✓ 数据库 '$del_db' 删除成功${NC}"
        
        if [ "$DB_NAME" == "$del_db" ]; then
            DB_NAME=""
            echo -e "${YELLOW}当前数据库已被删除，请重新选择数据库${NC}"
        fi
        
        echo ""
        echo -e "${CYAN}验证删除结果...${NC}"
        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "SHOW DATABASES LIKE '$del_db';" 2>/dev/null | grep -q "$del_db"; then
            echo -e "${RED}⚠ 警告：数据库可能未完全删除${NC}"
        else
            echo -e "${GREEN}✓ 确认：数据库已从系统中移除${NC}"
        fi
    else
        echo -e "${RED}✗ 数据库删除失败${NC}"
        show_error_log
        
        echo ""
        echo -e "${YELLOW}可能的失败原因：${NC}"
        echo "  1. 权限不足（需要 DROP 权限）"
        echo "  2. 数据库正在被其他连接使用"
        echo "  3. 数据库包含正在使用的表"
        echo "  4. 系统文件权限问题"
        
        return 1
    fi
}

# 清理备份文件
cleanup_backups() {
    clear
    echo -e "${YELLOW}======================================${NC}"
    echo -e "${YELLOW}        备份文件清理工具${NC}"
    echo -e "${YELLOW}======================================${NC}"
    echo ""
    
    local backup_files=($(ls -1 *.sql.bz2 2>/dev/null))
    local backup_count=${#backup_files[@]}
    
    if [ $backup_count -eq 0 ]; then
        echo -e "${YELLOW}当前目录没有找到备份文件（*.sql.bz2）${NC}"
        return 0
    fi
    
    local total_size=$(du -ch *.sql.bz2 2>/dev/null | grep total | awk '{print $1}')
    
    echo -e "${CYAN}当前备份文件统计：${NC}"
    echo -e "  文件数量: ${YELLOW}$backup_count${NC}"
    echo -e "  总大小: ${YELLOW}$total_size${NC}"
    echo ""
    
    local oldest=$(ls -t *.sql.bz2 2>/dev/null | tail -1)
    local newest=$(ls -t *.sql.bz2 2>/dev/null | head -1)
    if [ -n "$oldest" ]; then
        local oldest_date=$(stat -c %y "$oldest" 2>/dev/null | cut -d' ' -f1)
        local newest_date=$(stat -c %y "$newest" 2>/dev/null | cut -d' ' -f1)
        echo -e "  最旧备份: ${CYAN}$oldest${NC} (${oldest_date})"
        echo -e "  最新备份: ${CYAN}$newest${NC} (${newest_date})"
    fi
    echo ""
    
    echo -e "${YELLOW}清理选项：${NC}"
    echo "  1. 删除所有备份文件"
    echo "  2. 删除 N 天前的备份文件"
    echo "  3. 每个数据库只保留最新 N 个备份"
    echo "  4. 按数据库名清理"
    echo "  5. 查看所有备份文件（详细列表）"
    echo "  0. 返回"
    echo ""
    
    read -p "请选择清理方式 [0-5]: " cleanup_choice
    
    case $cleanup_choice in
        0)
            return 0
            ;;
        1)
            echo ""
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}        警告：删除所有备份文件${NC}"
            echo -e "${RED}========================================${NC}"
            echo -e "即将删除 ${YELLOW}$backup_count${NC} 个备份文件，总大小 ${YELLOW}$total_size${NC}"
            echo ""
            
            echo -e "${CYAN}备份文件列表（前10个）：${NC}"
            ls -lh *.sql.bz2 2>/dev/null | head -10 | awk '{print "  " $9 " - " $5}'
            if [ $backup_count -gt 10 ]; then
                echo "  ..."
            fi
            echo ""
            
            echo -e "${RED}此操作不可恢复！${NC}"
            read -p "确认删除所有备份文件吗？(yes/no): " confirm1
            
            if [ "$confirm1" != "yes" ]; then
                echo -e "${GREEN}✓ 已取消清理操作${NC}"
                return 0
            fi
            
            read -p "最后确认：输入 'DELETE ALL' 以确认删除: " confirm2
            
            if [ "$confirm2" != "DELETE ALL" ]; then
                echo -e "${YELLOW}确认失败，取消清理操作${NC}"
                return 0
            fi
            
            echo ""
            echo -e "${BLUE}正在删除备份文件...${NC}"
            local deleted_count=0
            for file in "${backup_files[@]}"; do
                if rm -f "$file" 2>/dev/null; then
                    deleted_count=$((deleted_count + 1))
                    echo -e "  ${GREEN}✓${NC} 已删除: $file"
                else
                    echo -e "  ${RED}✗${NC} 删除失败: $file"
                fi
            done
            
            echo ""
            echo -e "${GREEN}✓ 清理完成！${NC}"
            echo -e "  删除文件数: ${CYAN}$deleted_count${NC}/$backup_count"
            echo -e "  释放空间: ${CYAN}$total_size${NC}"
            ;;
        2)
            echo ""
            read -p "删除多少天前的备份文件？[默认: 30]: " days
            days=${days:-30}
            
            if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ]; then
                echo -e "${RED}无效的天数${NC}"
                return 1
            fi
            
            local old_files=($(find . -maxdepth 1 -name "*.sql.bz2" -type f -mtime +$days -printf "%f\n" 2>/dev/null))
            local old_count=${#old_files[@]}
            
            if [ $old_count -eq 0 ]; then
                echo -e "${YELLOW}没有找到 $days 天前的备份文件${NC}"
                return 0
            fi
            
            local old_size=$(find . -maxdepth 1 -name "*.sql.bz2" -type f -mtime +$days -exec du -ch {} + 2>/dev/null | grep total | awk '{print $1}')
            
            echo ""
            echo -e "${CYAN}找到 $old_count 个超过 $days 天的备份文件，总大小 $old_size${NC}"
            echo ""
            
            echo -e "${CYAN}文件列表（前10个）：${NC}"
            printf "%s\n" "${old_files[@]}" | head -10 | while read file; do
                local file_date=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1)
                local file_size=$(ls -lh "$file" 2>/dev/null | awk '{print $5}')
                echo "  $file - $file_size ($file_date)"
            done
            if [ $old_count -gt 10 ]; then
                echo "  ... 还有 $((old_count - 10)) 个文件"
            fi
            echo ""
            
            read -p "确认删除这些文件吗？(yes/no): " confirm
            
            if [ "$confirm" != "yes" ]; then
                echo -e "${GREEN}✓ 已取消清理操作${NC}"
                return 0
            fi
            
            echo ""
            echo -e "${BLUE}正在删除超过 $days 天的备份文件...${NC}"
            local deleted=0
            find . -maxdepth 1 -name "*.sql.bz2" -type f -mtime +$days -print0 2>/dev/null | while IFS= read -r -d '' file; do
                if rm -f "$file" 2>/dev/null; then
                    deleted=$((deleted + 1))
                    echo -e "  ${GREEN}✓${NC} 已删除: $(basename "$file")"
                fi
            done
            
            echo ""
            echo -e "${GREEN}✓ 清理完成！${NC}"
            echo -e "  删除文件数: ${CYAN}$old_count${NC}"
            echo -e "  释放空间: ${CYAN}$old_size${NC}"
            ;;
        3)
            echo ""
            read -p "每个数据库保留最新多少个备份？[默认: 5]: " keep_count
            keep_count=${keep_count:-5}
            
            if ! [[ "$keep_count" =~ ^[0-9]+$ ]] || [ "$keep_count" -lt 1 ]; then
                echo -e "${RED}无效的数量${NC}"
                return 1
            fi
            
            local db_names=($(ls *.sql.bz2 2>/dev/null | sed 's/_backup_.*\.sql\.bz2//' | sort -u))
            
            if [ ${#db_names[@]} -eq 0 ]; then
                echo -e "${YELLOW}无法识别数据库名称${NC}"
                return 1
            fi
            
            echo ""
            echo -e "${CYAN}发现 ${#db_names[@]} 个数据库的备份${NC}"
            echo -e "${YELLOW}将为每个数据库保留最新 $keep_count 个备份${NC}"
            echo ""
            
            local total_to_delete=0
            local total_to_keep=0
            declare -a files_to_delete_all
            
            for db in "${db_names[@]}"; do
                local db_files=($(ls -t ${db}_backup_*.sql.bz2 2>/dev/null))
                local db_file_count=${#db_files[@]}
                
                if [ $db_file_count -le $keep_count ]; then
                    echo -e "${GREEN}$db${NC}: $db_file_count 个备份 - 无需清理"
                    total_to_keep=$((total_to_keep + db_file_count))
                else
                    local to_delete=$((db_file_count - keep_count))
                    echo -e "${YELLOW}$db${NC}: $db_file_count 个备份 - 保留 $keep_count 个，删除 $to_delete 个"
                    total_to_delete=$((total_to_delete + to_delete))
                    total_to_keep=$((total_to_keep + keep_count))
                    
                    local db_files_to_delete=($(ls -t ${db}_backup_*.sql.bz2 2>/dev/null | tail -n +$((keep_count + 1))))
                    files_to_delete_all+=("${db_files_to_delete[@]}")
                fi
            done
            
            if [ $total_to_delete -eq 0 ]; then
                echo ""
                echo -e "${GREEN}✓ 所有数据库备份数量都不超过 $keep_count 个，无需清理${NC}"
                return 0
            fi
            
            local delete_size="0"
            if [ ${#files_to_delete_all[@]} -gt 0 ]; then
                delete_size=$(printf "%s\n" "${files_to_delete_all[@]}" | xargs du -ch 2>/dev/null | grep total | awk '{print $1}')
            fi
            
            echo ""
            echo -e "${CYAN}========================================${NC}"
            echo -e "${CYAN}           清理统计预览${NC}"
            echo -e "${CYAN}========================================${NC}"
            echo -e "  将删除: ${RED}$total_to_delete${NC} 个备份文件"
            echo -e "  将保留: ${GREEN}$total_to_keep${NC} 个备份文件"
            echo -e "  释放空间: ${YELLOW}$delete_size${NC}"
            echo ""
            
            read -p "确认执行清理操作吗？(yes/no): " confirm
            
            if [ "$confirm" != "yes" ]; then
                echo -e "${GREEN}✓ 已取消清理操作${NC}"
                return 0
            fi
            
            echo ""
            echo -e "${BLUE}正在清理旧备份...${NC}"
            local deleted=0
            local failed=0
            
            for file in "${files_to_delete_all[@]}"; do
                if rm -f "$file" 2>/dev/null; then
                    deleted=$((deleted + 1))
                    echo -e "  ${GREEN}✓${NC} 已删除: $file"
                else
                    failed=$((failed + 1))
                    echo -e "  ${RED}✗${NC} 删除失败: $file"
                fi
            done
            
            echo ""
            echo -e "${GREEN}✓ 清理完成！${NC}"
            echo -e "  成功删除: ${CYAN}$deleted${NC} 个文件"
            if [ $failed -gt 0 ]; then
                echo -e "  删除失败: ${RED}$failed${NC} 个文件"
            fi
            echo -e "  保留文件: ${CYAN}$total_to_keep${NC} 个"
            echo -e "  释放空间: ${CYAN}$delete_size${NC}"
            ;;
        4)
            echo ""
            echo -e "${CYAN}正在分析备份文件...${NC}"
            
            local db_names=($(ls *.sql.bz2 2>/dev/null | sed 's/_backup_.*\.sql\.bz2//' | sort -u))
            
            if [ ${#db_names[@]} -eq 0 ]; then
                echo -e "${YELLOW}无法识别数据库名称${NC}"
                return 1
            fi
            
            echo ""
            echo -e "${CYAN}发现以下数据库的备份：${NC}"
            for i in "${!db_names[@]}"; do
                local db="${db_names[$i]}"
                local db_backup_count=$(ls ${db}_backup_*.sql.bz2 2>/dev/null | wc -l)
                local db_backup_size=$(du -ch ${db}_backup_*.sql.bz2 2>/dev/null | grep total | awk '{print $1}')
                echo "  $((i+1)). $db - $db_backup_count 个备份, $db_backup_size"
            done
            echo "  0. 返回"
            echo ""
            
            read -p "选择要清理的数据库 [0-${#db_names[@]}]: " db_choice
            
            if [ "$db_choice" == "0" ]; then
                return 0
            fi
            
            if ! [[ "$db_choice" =~ ^[0-9]+$ ]] || [ "$db_choice" -lt 1 ] || [ "$db_choice" -gt ${#db_names[@]} ]; then
                echo -e "${RED}无效选择${NC}"
                return 1
            fi
            
            local selected_db="${db_names[$((db_choice-1))]}"
            local db_files=($(ls ${selected_db}_backup_*.sql.bz2 2>/dev/null))
            local db_file_count=${#db_files[@]}
            local db_total_size=$(du -ch ${selected_db}_backup_*.sql.bz2 2>/dev/null | grep total | awk '{print $1}')
            
            echo ""
            echo -e "${YELLOW}数据库: $selected_db${NC}"
            echo -e "  备份数量: $db_file_count"
            echo -e "  总大小: $db_total_size"
            echo ""
            
            echo -e "${CYAN}备份文件列表：${NC}"
            for file in "${db_files[@]}"; do
                local file_size=$(ls -lh "$file" | awk '{print $5}')
                local file_date=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1)
                echo "  $file - $file_size ($file_date)"
            done
            echo ""
            
            read -p "确认删除数据库 '$selected_db' 的所有备份吗？(yes/no): " confirm
            
            if [ "$confirm" != "yes" ]; then
                echo -e "${GREEN}✓ 已取消清理操作${NC}"
                return 0
            fi
            
            echo ""
            echo -e "${BLUE}正在删除 $selected_db 的备份文件...${NC}"
            local deleted=0
            for file in "${db_files[@]}"; do
                if rm -f "$file" 2>/dev/null; then
                    deleted=$((deleted + 1))
                    echo -e "  ${GREEN}✓${NC} 已删除: $file"
                fi
            done
            
            echo ""
            echo -e "${GREEN}✓ 清理完成！${NC}"
            echo -e "  删除文件数: ${CYAN}$deleted${NC}"
            echo -e "  释放空间: ${CYAN}$db_total_size${NC}"
            ;;
        5)
            echo ""
            echo -e "${CYAN}========================================${NC}"
            echo -e "${CYAN}        所有备份文件详细列表${NC}"
            echo -e "${CYAN}========================================${NC}"
            echo ""
            
            ls -lh *.sql.bz2 2>/dev/null | awk 'NR>0 {
                size=$5; 
                date=$6" "$7" "$8; 
                file=$9; 
                printf "  %-40s %8s  %s\n", file, size, date
            }'
            
            echo ""
            echo -e "${CYAN}总计: $backup_count 个文件, $total_size${NC}"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return 1
            ;;
    esac
}

# 交互式配置连接
config_connection() {
    clear
    echo -e "${CYAN}======== 配置数据库连接 ========${NC}"
    echo -e "${YELLOW}提示: 直接回车使用当前值${NC}"
    echo ""
    
    read -p "主机地址 [$DB_HOST]: " input_host
    DB_HOST=${input_host:-$DB_HOST}
    
    read -p "端口 [$DB_PORT]: " input_port
    DB_PORT=${input_port:-$DB_PORT}
    
    read -p "用户名 [$DB_USER]: " input_user
    DB_USER=${input_user:-$DB_USER}
    
    read -sp "密码 [${DB_PASSWORD:+********}]: " input_password
    echo ""
    if [ -n "$input_password" ]; then
        DB_PASSWORD="$input_password"
    fi
    
    read -p "默认数据库 [${DB_NAME:-无}]: " input_db
    if [ -n "$input_db" ]; then
        DB_NAME="$input_db"
    fi
    
    echo ""
    echo -e "${BLUE}正在测试连接...${NC}"
    if test_connection; then
        echo ""
        read -p "是否保存此配置？(yes/no): " save_choice
        if [ "$save_choice" == "yes" ]; then
            save_profile
        fi
    fi
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN}     MySQL 数据库管理器 v2.5${NC}"
        echo -e "${GREEN}======================================${NC}"
        if [ -n "$CURRENT_PROFILE" ]; then
            echo -e "配置: ${CYAN}$CURRENT_PROFILE${NC} | 连接: ${YELLOW}$DB_USER@$DB_HOST:$DB_PORT${NC}"
        else
            echo -e "当前连接: ${YELLOW}$DB_USER@$DB_HOST:$DB_PORT${NC}"
        fi
        [ -n "$DB_NAME" ] && echo -e "当前数据库: ${YELLOW}$DB_NAME${NC}"
        echo ""
        echo " 1. 配置连接"
        echo " 2. 加载历史连接"
        echo " 3. 删除历史配置"
        echo " 4. 显示数据库列表"
        echo " 5. 选择数据库"
        echo " 6. 显示表列表和数据"
        echo " 7. 进入 MySQL 控制台"
        echo " 8. 导入 SQL 文件"
        echo " 9. 备份数据库"
        echo "10. 还原备份文件"
        echo "11. 预览备份文件"
        echo "12. 创建数据库"
        echo "13. 删除数据库"
        echo "14. 清理备份文件"
        echo " 0. 退出"
        echo ""
        
        read -p "请选择 [0-14]: " choice
        
        case $choice in
            1)
                config_connection
                read -p "按回车继续..."
                ;;
            2)
                select_profile
                read -p "按回车继续..."
                ;;
            3)
                delete_profile
                read -p "按回车继续..."
                ;;
            4)
                show_databases
                read -p "按回车继续..."
                ;;
            5)
                select_database
                read -p "按回车继续..."
                ;;
            6)
                show_tables
                read -p "按回车继续..."
                ;;
            7)
                enter_mysql_console
                ;;
            8)
                import_sql_file
                read -p "按回车继续..."
                ;;
            9)
                backup_database
                read -p "按回车继续..."
                ;;
            10)
                restore_backup_menu
                read -p "按回车继续..."
                ;;
            11)
                preview_backup
                read -p "按回车继续..."
                ;;
            12)
                create_database
                read -p "按回车继续..."
                ;;
            13)
                drop_database
                read -p "按回车继续..."
                ;;
            14)
                cleanup_backups
                read -p "按回车继续..."
                ;;
            0)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 1
                ;;
        esac
    done
}

# 主程序入口
check_mysql_client
init_config

if [ -n "$1" ]; then
    load_profile "$1"
    sleep 1
fi

main_menu
