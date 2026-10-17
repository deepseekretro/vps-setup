#!/bin/bash

# =================================================================================
# MySQL 管理脚本 - 备份与还原
# =================================================================================

# =================配置区域=================

# 脚本所在目录
# 处理通过 curl | bash 或 bash <(curl ...) 远程执行的情况
if [[ "${BASH_SOURCE[0]}" == /dev/fd/* ]] || [[ "${BASH_SOURCE[0]}" == /proc/self/fd/* ]]; then
    # 通过 curl 或进程替换执行，使用当前目录
    SCRIPT_DIR="$(pwd)"
else
    # 本地执行，使用脚本实际路径
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# MySQL 连接信息（将在脚本启动时交互式设置）
DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASS=""

# 备份目录 (本地临时存储)
BACKUP_DIR="/backup/sql"
LOG_FILE="/var/log/mysql_backup/backup_sql.log"

# 还原临时目录
RESTORE_TEMP_DIR="${SCRIPT_DIR}/restore_temp"

# 日期后缀
DATE_SUFFIX=$(date +%Y%m%d_%H%M%S)

# 云端保留天数
REMOTE_RETENTION_DAYS="7d"

# VPS 实例名称（用于备份路径）
VPS_INSTANCE_NAME=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# =================函数定义=================

log_msg() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" | tee -a "${LOG_FILE}"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }
log_ask() { echo -e "${CYAN}[?]${NC} $1"; }

# 生成随机密码
generate_password() {
    < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-16}
}

# 创建 MySQL 配置文件（用于安全传递密码）
create_mysql_config() {
    local config_file="$1"
    local host="$2"
    local port="$3"
    local user="$4"
    local pass="$5"
    
    cat > "$config_file" <<EOF
[client]
host=${host}
port=${port}
user=${user}
password=${pass}
EOF
    chmod 600 "$config_file"
}

# 交互式选择 rclone 远程配置
select_rclone_remote() {
    # 所有交互界面输出到 stderr，只有最终结果返回到 stdout
    echo "=== Available rclone remotes ===" >&2
    echo "" >&2
    
    # 获取所有远程配置（兼容旧版本 bash）
    local remotes=()
    while IFS= read -r line; do
        # 移除末尾的冒号
        line="${line%:}"
        if [ -n "$line" ]; then
            remotes+=("$line")
        fi
    done < <(rclone listremotes)
    
    # 检查是否有远程配置
    if [ ${#remotes[@]} -eq 0 ]; then
        echo "Error: No rclone remotes configured." >&2
        echo "Please run 'rclone config' to add a remote first." >&2
        exit 1
    fi
    
    # 显示所有选项
    local i=1
    for remote in "${remotes[@]}"; do
        echo "  [$i] $remote" >&2
        ((i++))
    done
    
    # 提示用户选择
    echo "" >&2
    read -p "Please select a remote [1-${#remotes[@]}]: " selection
    
    # 验证输入
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#remotes[@]} ]; then
        echo "Error: Invalid selection." >&2
        exit 1
    fi
    
    # 返回选中的远程名称（只有这个输出到 stdout）
    local selected_remote="${remotes[$((selection-1))]}"
    echo "Selected: $selected_remote" >&2
    echo "$selected_remote"
}

# 检查并安装 rclone
check_and_install_rclone() {
    # 检查 rclone 是否已安装
    if ! command -v rclone &> /dev/null; then
        echo ""
        log_warn "rclone is not installed."
        log_info "Installing rclone..."
        
        # 安装 rclone
        curl https://rclone.org/install.sh | bash
        
        if [ $? -ne 0 ]; then
            log_err "Failed to install rclone."
            log_err "Please install rclone manually: https://rclone.org/install/"
            exit 1
        fi
        
        log_info "✓ rclone installed successfully!"
    else
        log_info "✓ rclone is already installed."
    fi
    
    # 检查 rclone 是否已配置
    if ! rclone listremotes &> /dev/null || [ -z "$(rclone listremotes)" ]; then
        echo ""
        log_err "rclone is not configured yet."
        log_err "Please run 'rclone config' to add at least one remote."
        echo ""
        log_info "Example configuration steps:"
        echo "  1. Run: rclone config"
        echo "  2. Choose 'n' for new remote"
        echo "  3. Follow the prompts to configure your cloud storage"
        echo "  4. Run this script again after configuration"
        echo ""
        exit 1
    fi
    
    log_info "✓ rclone is configured with the following remotes:"
    rclone listremotes | sed 's/:$//' | while read remote; do
        echo "    - $remote"
    done
    echo ""
}

# 检查 MySQL 连接配置是否已完成
mysql_configured=false

# 持久化配置文件路径
MYSQL_CONFIG="$HOME/.mysql_backup.cnf"
VPS_CONFIG="$HOME/.vps_instance.conf"

# 配置 VPS 实例名
setup_vps_instance() {
    # 如果已经设置,跳过
    if [ -n "$VPS_INSTANCE_NAME" ]; then
        return
    fi
    
    # 尝试从持久化配置文件读取，但仍会要求用户确认或输入
    local saved_vps_name=""
    if [ -f "$VPS_CONFIG" ]; then
        saved_vps_name=$(cat "$VPS_CONFIG" 2>/dev/null)
    fi
    
    echo ""
    log_info "Configure VPS instance name (used in backup path)"
    
    # 如果有保存的名称，提供给用户参考
    if [ -n "$saved_vps_name" ]; then
        log_info "Found saved instance name: ${CYAN}${saved_vps_name}${NC}"
        read -p "Use saved name? (yes/no) [default: yes]: " use_saved
        use_saved=${use_saved:-yes}
        if [ "$use_saved" = "yes" ]; then
            VPS_INSTANCE_NAME="$saved_vps_name"
        fi
    fi

    # 如果用户选择不使用保存的名称，或者没有保存的名称，则要求输入
    while [ -z "$VPS_INSTANCE_NAME" ]; do
        read -p "Enter VPS instance name: " input_instance
        if [ -n "$input_instance" ]; then
            VPS_INSTANCE_NAME="$input_instance"
        else
            log_warn "Instance name cannot be empty. Please enter a name."
        fi
    done
    
    # 保存到配置文件
    echo "$VPS_INSTANCE_NAME" > "$VPS_CONFIG"
    chmod 600 "$VPS_CONFIG"
    log_info "VPS instance name saved: ${CYAN}${VPS_INSTANCE_NAME}${NC}"
}


# 交互式配置 MySQL 连接信息
setup_mysql_connection() {
    # 如果已经配置过，跳过
    if [ "$mysql_configured" = true ]; then
        return
    fi
    
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     MySQL Connection Configuration     ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    # 尝试从持久化配置文件读取现有配置
    local saved_host=""
    local saved_port=""
    local saved_user=""
    local saved_pass=""
    
    if [ -f "$MYSQL_CONFIG" ]; then
        log_info "Found existing configuration: ${CYAN}${MYSQL_CONFIG}${NC}"
        saved_host=$(grep "^host=" "$MYSQL_CONFIG" 2>/dev/null | cut -d'=' -f2)
        saved_port=$(grep "^port=" "$MYSQL_CONFIG" 2>/dev/null | cut -d'=' -f2)
        saved_user=$(grep "^user=" "$MYSQL_CONFIG" 2>/dev/null | cut -d'=' -f2)
        saved_pass=$(grep "^password=" "$MYSQL_CONFIG" 2>/dev/null | cut -d'=' -f2)
        
        if [ -n "$saved_host" ] && [ -n "$saved_user" ]; then
            echo ""
            log_info "Saved configuration:"
            echo "  Host: ${CYAN}${saved_host}${NC}"
            echo "  Port: ${CYAN}${saved_port}${NC}"
            echo "  User: ${CYAN}${saved_user}${NC}"
            echo ""
            read -p "Use saved configuration? (yes/no) [default: yes]: " use_saved
            use_saved=${use_saved:-yes}
            
            if [ "$use_saved" = "yes" ]; then
                DB_HOST="$saved_host"
                DB_PORT="$saved_port"
                DB_USER="$saved_user"
                DB_PASS="$saved_pass"
                
                # 验证保存的配置
                echo ""
                log_info "Testing saved MySQL connection..."
                if mysql --defaults-file="$MYSQL_CONFIG" -e "STATUS" >/dev/null 2>&1; then
                    log_info "${GREEN}✓ MySQL connection successful!${NC}"
                    mysql_configured=true
                    return 0
                else
                    log_warn "Saved configuration failed to connect. Please re-enter credentials."
                    echo ""
                fi
            fi
        fi
    fi
    
    # 设置默认值（使用保存的值或标准默认值）
    local default_host="${saved_host:-127.0.0.1}"
    local default_port="${saved_port:-3306}"
    local default_user="${saved_user:-root}"
    
    # MySQL Host
    read -p "MySQL Host [default: ${default_host}]: " input_host
    DB_HOST=${input_host:-"$default_host"}
    
    # MySQL Port
    read -p "MySQL Port [default: ${default_port}]: " input_port
    DB_PORT=${input_port:-"$default_port"}
    
    # MySQL User
    read -p "MySQL User [default: ${default_user}]: " input_user
    DB_USER=${input_user:-"$default_user"}
    
    # MySQL Password
    if [ -n "$saved_pass" ] && [ "$use_saved" != "yes" ]; then
        read -s -p "MySQL Password [press Enter to use saved password]: " DB_PASS
        echo ""
        if [ -z "$DB_PASS" ]; then
            DB_PASS="$saved_pass"
            log_info "Using saved password."
        fi
    else
        read -s -p "MySQL Password: " DB_PASS
        echo ""
    fi
    
    # 验证连接并保存配置
    echo ""
    log_info "Testing MySQL connection..."
    
    # 创建临时配置文件用于测试
    local temp_config="/tmp/.mysql_test_$$.cnf"
    cat > "$temp_config" <<EOF_CONFIG
[client]
host=$DB_HOST
port=$DB_PORT
user=$DB_USER
password=$DB_PASS
EOF_CONFIG
    chmod 600 "$temp_config"
    
    if mysql --defaults-file="$temp_config" -e "STATUS" >/dev/null 2>&1; then
        log_info "${GREEN}✓ MySQL connection successful!${NC}"
        
        # 保存配置到持久化文件
        cp "$temp_config" "$MYSQL_CONFIG"
        chmod 600 "$MYSQL_CONFIG"
        log_info "Configuration saved to: ${CYAN}${MYSQL_CONFIG}${NC}"
        
        mysql_configured=true
        rm -f "$temp_config"
        return 0
    else
        log_err "Failed to connect to MySQL server."
        log_err "Please check your credentials and try again."
        rm -f "$temp_config"
        return 1
    fi
    
    echo ""
}


# =================备份脚本生成（公共函数）=================

# 生成 MySQL 备份脚本
# 参数: $1 = rclone远程名称
# 返回: 生成的脚本路径
generate_mysql_backup_script() {
    local rclone_remote="$1"
    local backup_script="${SCRIPT_DIR}/auto_backup_mysql.sh"
    
    log_info "Generating backup script..." >&2
    
    cat > "${backup_script}" <<'SCRIPT_EOF'
#!/bin/bash

# Auto-generated MySQL backup script
# Generated by mysql_manager.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="/backup/sql"
LOG_FILE="/var/log/mysql_backup/backup_sql.log"
DATE_SUFFIX=$(date +%Y%m%d_%H%M%S)
REMOTE_RETENTION_DAYS="7d"

# MySQL connection
SCRIPT_EOF

    # 添加变量替换部分
    cat >> "${backup_script}" <<SCRIPT_VARS
DB_HOST="${DB_HOST}"
DB_PORT="${DB_PORT}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"

# rclone remote configuration
RCLONE_REMOTE_NAME="${rclone_remote}"
REMOTE_BACKUP="${RCLONE_REMOTE_NAME}:/vps_backup/${VPS_INSTANCE_NAME}/sql"

# MySQL config file (stored in user home for persistence)
MYSQL_CONFIG="$HOME/.mysql_backup.cnf"
SCRIPT_VARS

    # 添加脚本逻辑
    cat >> "${backup_script}" <<'SCRIPT_LOGIC'

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# Create MySQL config file
create_mysql_config() {
    cat > "${MYSQL_CONFIG}" <<EOF_CONFIG
[client]
host=${DB_HOST}
port=${DB_PORT}
user=${DB_USER}
password=${DB_PASS}
EOF_CONFIG
    chmod 600 "${MYSQL_CONFIG}"
}

# Note: MySQL config file is persistent in $HOME/.mysql_backup.cnf
# It will be reused across backup runs

mkdir -p "${BACKUP_DIR}"
mkdir -p /var/log/mysql_backup
if [ ! -f "${LOG_FILE}" ]; then touch "${LOG_FILE}"; fi

log_msg "=== MySQL Backup Started ==="
log_msg "Using rclone remote: ${RCLONE_REMOTE_NAME}"
log_msg "Remote backup path: ${REMOTE_BACKUP}"

# Check bzip2
if ! command -v bzip2 &> /dev/null; then
    log_msg "Warning: bzip2 is not installed. Attempting to install..."
    apt-get update -qq && apt-get install -y bzip2 >> "${LOG_FILE}" 2>&1
    if ! command -v bzip2 &> /dev/null; then
        log_msg "Critical Error: Failed to install bzip2."
        exit 1
    fi
fi

# Create MySQL config
create_mysql_config

# Check MySQL connection
if ! mysql --defaults-file="${MYSQL_CONFIG}" -e "STATUS" >/dev/null 2>&1; then
    log_msg "Error: Cannot connect to MySQL server."
    exit 1
fi

# Get database list
databases=$(mysql --defaults-file="${MYSQL_CONFIG}" -e "SHOW DATABASES;" | grep -E -v "Database|information_schema|mysql|test|performance_schema|sys")

for db in $databases; do
    log_msg "Processing database: ${db}"
    
    filename="${db}_${DATE_SUFFIX}.sql.bz2"
    filepath="${BACKUP_DIR}/${filename}"

    # Backup
    mysqldump --defaults-file="${MYSQL_CONFIG}" \
        --databases "${db}" \
        --add-drop-database \
        --single-transaction --quick --routines --triggers --events --hex-blob \
        --default-character-set=utf8mb4 \
        | bzip2 > "${filepath}"

    # Verify and upload
    if [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "${filepath}" ]; then
        log_msg "Success: Local backup created at ${filepath}"

        rclone copy "${filepath}" "${REMOTE_BACKUP}" >> "${LOG_FILE}" 2>&1

        if [ $? -eq 0 ]; then
            log_msg "Upload: ${db} uploaded successfully."
            rm -f "${filepath}"

            remote_pattern="${db}_*.sql.bz2"
            remote_count=$(rclone lsf "${REMOTE_BACKUP}" --include "${remote_pattern}" | wc -l)
            
            log_msg "Check: Found ${remote_count} backups for ${db} on remote."

            if [ "$remote_count" -gt 1 ]; then
                log_msg "Cleanup: Removing backups for ${db} older than ${REMOTE_RETENTION_DAYS}..."
                
                # Protect the absolute newest file regardless of age
                # Use | delimiter to safely separate timestamp and filename
                newest_backup=$(rclone lsf "${REMOTE_BACKUP}" --include "${remote_pattern}" --files-only --format "tp" --separator "|" | sort -r | head -n 1 | cut -d'|' -f2)
                
                if [ -n "$newest_backup" ]; then
                    log_msg "Protection: Keeping active backup '${newest_backup}'"
                    
                    rclone delete "${REMOTE_BACKUP}" \
                        --include "${remote_pattern}" \
                        --min-age "${REMOTE_RETENTION_DAYS}" \
                        --exclude "${newest_backup}" \
                        >> "${LOG_FILE}" 2>&1
                else
                    # Fallback if detection fails
                    rclone delete "${REMOTE_BACKUP}" \
                        --include "${remote_pattern}" \
                        --min-age "${REMOTE_RETENTION_DAYS}" \
                        >> "${LOG_FILE}" 2>&1
                fi
            else
                log_msg "Skip Cleanup: Only ${remote_count} copy exists for ${db}. Keeping it regardless of age."
            fi

        else
            log_msg "Error: Failed to upload ${db}. Skipping cleanup to ensure safety."
        fi
    else
        log_msg "Error: mysqldump failed for ${db}"
        rm -f "${filepath}"
    fi
done

log_msg "=== MySQL Backup Finished ==="
exit 0
SCRIPT_LOGIC

    chmod +x "${backup_script}"
    log_info "Backup script created: ${CYAN}${backup_script}${NC}" >&2
    
    # 返回脚本路径
    echo "${backup_script}"
}


# =================备份功能=================

# 为脚本设置 crontab
# 参数: $1 = 脚本路径, $2 = cron表达式, $3 = 描述
setup_crontab_for_script() {
    local script_path="$1"
    local cron_expr="$2"
    local schedule_desc="$3"
    
    echo ""
    log_info "Adding to crontab..."
    
    # 检查是否已存在相同的任务
    if crontab -l 2>/dev/null | grep -q "${script_path}"; then
        log_warn "A cron job for this script already exists."
        read -p "Do you want to replace it? (yes/no) [default: no]: " replace_choice
        replace_choice=${replace_choice:-no}
        
        if [ "$replace_choice" != "yes" ]; then
            log_info "Keeping existing cron job. Setup cancelled."
            return
        fi
        
        # 删除旧的任务
        crontab -l 2>/dev/null | grep -v "${script_path}" | crontab -
        log_info "Removed existing cron job."
    fi
    
    # 添加新任务
    (crontab -l 2>/dev/null; echo "${cron_expr} ${script_path} >> /var/log/mysql_backup/backup_sql.log 2>&1") | crontab -
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "============================================="
        echo -e "        ${GREEN}✓ Setup Completed Successfully${NC}"
        echo "============================================="
        echo -e "Remote        : ${CYAN}${RCLONE_REMOTE_NAME}${NC}"
        echo -e "Schedule      : ${CYAN}${schedule_desc}${NC}"
        echo -e "Cron Expr     : ${YELLOW}${cron_expr}${NC}"
        echo -e "Backup Script : ${YELLOW}${script_path}${NC}"
        echo -e "Log File      : ${YELLOW}/var/log/mysql_backup/backup_sql.log${NC}"
        echo "============================================="
        echo ""
        echo "Current crontab entries:"
        crontab -l | grep -v "^#" | grep -v "^$"
        echo ""
    else
        log_err "Failed to add cron job."
    fi
}


# =================备份功能=================

backup_mysql() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        MySQL Database Backup           ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    # 首先配置 MySQL 连接（如果还未配置）
    setup_mysql_connection
    if [ $? -ne 0 ]; then
        return
    fi
    
    # 配置 VPS 实例名
    setup_vps_instance
    
    # Step 1: 选择远程网盘
    log_info "Step 1: Select rclone remote for backups"
    RCLONE_REMOTE_NAME=$(select_rclone_remote)
    
    echo ""
    log_info "Selected remote: ${CYAN}${RCLONE_REMOTE_NAME}${NC}"
    
    # Step 2: 生成备份脚本（使用共享函数）
    echo ""
    BACKUP_SCRIPT=$(generate_mysql_backup_script "${RCLONE_REMOTE_NAME}")
    
    # Step 3: 选择执行方式
    echo ""
    log_info "Step 3: Choose execution method"
    echo ""
    echo "  1) Run backup now"
    echo "  2) Setup scheduled backup (crontab)"
    echo "  3) Cancel"
    echo ""
    
    read -p "Please select [1-3]: " exec_choice
    
    case $exec_choice in
        1)
            # 立即执行
            echo ""
            log_info "Executing backup now..."
            echo ""
            
            "${BACKUP_SCRIPT}"
            
            echo ""
            echo -e "${GREEN}✓ MySQL backup completed!${NC}"
            echo -e "Log file: ${YELLOW}/var/log/mysql_backup/backup_sql.log${NC}"
            echo ""
            ;;
        2)
            # 设置定时任务
            echo ""
            log_info "Configure backup schedule"
            echo ""
            echo "Common schedules:"
            echo "  1) Daily at 2:00 AM"
            echo "  2) Daily at 3:00 AM"
            echo "  3) Every 6 hours"
            echo "  4) Every 12 hours"
            echo "  5) Custom cron expression"
            echo ""
            
            read -p "Select schedule [1-5]: " schedule_choice
            
            case $schedule_choice in
                1)
                    CRON_EXPR="0 2 * * *"
                    SCHEDULE_DESC="Daily at 2:00 AM"
                    ;;
                2)
                    CRON_EXPR="0 3 * * *"
                    SCHEDULE_DESC="Daily at 3:00 AM"
                    ;;
                3)
                    CRON_EXPR="0 */6 * * *"
                    SCHEDULE_DESC="Every 6 hours"
                    ;;
                4)
                    CRON_EXPR="0 */12 * * *"
                    SCHEDULE_DESC="Every 12 hours"
                    ;;
                5)
                    echo ""
                    echo "Cron format: minute hour day month weekday"
                    echo "Example: 0 2 * * * (Daily at 2:00 AM)"
                    read -p "Enter custom cron expression: " CRON_EXPR
                    SCHEDULE_DESC="Custom: ${CRON_EXPR}"
                    ;;
                *)
                    log_err "Invalid selection."
                    return
                    ;;
            esac
            
            # 使用共享函数添加到 crontab
            setup_crontab_for_script "${BACKUP_SCRIPT}" "${CRON_EXPR}" "${SCHEDULE_DESC}"
            ;;
        3)
            log_info "Cancelled."
            return
            ;;
        *)
            log_err "Invalid selection."
            return
            ;;
    esac
}


# =================还原功能=================

restore_mysql() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       MySQL Database Restore           ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    # 首先配置 MySQL 连接（如果还未配置）
    setup_mysql_connection
    if [ $? -ne 0 ]; then
        return
    fi
    
    # 配置 VPS 实例名
    setup_vps_instance
    
    # 确定 rclone 远程网盘名称
    if [ -t 0 ]; then
        RCLONE_REMOTE_NAME=$(select_rclone_remote)
    else
        RCLONE_REMOTE_NAME="wyrover"
    fi
    
    # rclone 远程目标路径
    REMOTE_BACKUP="${RCLONE_REMOTE_NAME}:/vps_backup/${VPS_INSTANCE_NAME}/sql"
    
    # 依赖检查
    for cmd in rclone mysql bzip2 grep; do
        if ! command -v "$cmd" &> /dev/null; then
            log_err "$cmd is missing."
            exit 1
        fi
    done
    
    mkdir -p "${RESTORE_TEMP_DIR}"
    
    # 列出并选择远程文件
    log_info "Fetching backup list from ${RCLONE_REMOTE_NAME}..."
    mapfile -t REMOTE_FILES < <(rclone lsf "${REMOTE_BACKUP}" --files-only | grep ".bz2" | sort -r)
    
    if [ ${#REMOTE_FILES[@]} -eq 0 ]; then
        log_err "No backup files found."
        exit 1
    fi
    
    echo "------------------------------------------------"
    i=1
    for file in "${REMOTE_FILES[@]}"; do
        echo -e "${GREEN}$i${NC}) $file"
        ((i++))
    done
    echo "------------------------------------------------"
    
    read -p "Select file number: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#REMOTE_FILES[@]} ]; then
        echo ""
        log_err "Invalid selection. Returning to main menu..."
        sleep 2
        return
    fi
    
    SELECTED_FILE="${REMOTE_FILES[$((choice-1))]}"
    LOCAL_FILE="${RESTORE_TEMP_DIR}/${SELECTED_FILE}"
    
    # 下载文件
    if [ ! -f "${LOCAL_FILE}" ]; then
        log_info "Downloading ${SELECTED_FILE}..."
        rclone copyto "${REMOTE_BACKUP}/${SELECTED_FILE}" "${LOCAL_FILE}" -P
    else
        log_info "File already exists locally, using cached version."
    fi
    
    # 智能嗅探文件内容
    log_info "Inspecting backup file structure..."
    
    HEADER_CONTENT=$(bzcat "${LOCAL_FILE}" | head -n 100)
    DB_IN_FILE=""
    
    if echo "$HEADER_CONTENT" | grep -qi "Current Database:"; then
        DB_IN_FILE=$(echo "$HEADER_CONTENT" | grep -i "Current Database:" | awk -F '`' '{print $2}')
    elif echo "$HEADER_CONTENT" | grep -qi "^USE "; then
        DB_IN_FILE=$(echo "$HEADER_CONTENT" | grep -i "^USE " | head -n 1 | awk -F '`' '{print $2}')
    fi
    
    TARGET_DB=""
    
    if [ -n "$DB_IN_FILE" ]; then
        log_info "Detected target database in file: ${CYAN}${DB_IN_FILE}${NC}"
        TARGET_DB="${DB_IN_FILE}"
        CONTAINS_CREATE_STMTS=true
    else
        log_warn "Could NOT detect target database in file header."
        echo ""
        while [ -z "$TARGET_DB" ]; do
            read -p "Please enter the target DATABASE NAME for restoration: " TARGET_DB
        done
        CONTAINS_CREATE_STMTS=false
    fi
    
    # 交互式：清洗现有数据库
    echo ""
    log_ask "Do you want to DROP the existing database '${TARGET_DB}' before restoring?"
    log_warn "WARNING: This will DELETE ALL DATA in '${TARGET_DB}'."
    read -p "Type 'yes' to overwrite. Press Enter for 'no' (Cancel operation): " CLEAN_DB_CHOICE
    CLEAN_DB_CHOICE=${CLEAN_DB_CHOICE:-no}
    
    if [ "$CLEAN_DB_CHOICE" != "yes" ]; then
        log_info "User chose not to drop database. Operation Cancelled."
        rm -f "${LOCAL_FILE}"
        exit 0
    fi
    
    # 交互式：创建专用用户
    echo ""
    log_ask "Do you want to create a NEW MySQL user for '${TARGET_DB}'?"
    read -p "(yes/no) [default: yes]: " CREATE_USER_CHOICE
    CREATE_USER_CHOICE=${CREATE_USER_CHOICE:-yes}
    
    NEW_DB_USER=""
    NEW_DB_PASS=""
    USER_HOST="%"
    
    if [ "$CREATE_USER_CHOICE" == "yes" ]; then
        read -p "Enter new username (default: ${TARGET_DB}_user): " input_user
        NEW_DB_USER=${input_user:-"${TARGET_DB}_user"}
        
        read -p "Enter password (leave empty to auto-generate): " input_pass
        if [ -z "$input_pass" ]; then
            NEW_DB_PASS=$(generate_password)
            echo -e "Generated Password: ${CYAN}${NEW_DB_PASS}${NC}"
        else
            NEW_DB_PASS="$input_pass"
        fi
    
        log_ask "Allow REMOTE access for this user? (Host='%')"
        read -p "(yes/no) [default: yes]: " REMOTE_ACCESS_CHOICE
        REMOTE_ACCESS_CHOICE=${REMOTE_ACCESS_CHOICE:-yes}
        
        if [ "$REMOTE_ACCESS_CHOICE" == "yes" ]; then
            USER_HOST="%"
            log_info "User will be created with Host='%' (Remote Allowed)"
        else
            USER_HOST="localhost"
            log_info "User will be created with Host='localhost' (Local Only)"
        fi
    fi
    
    # 最终确认
    echo ""
    echo "=============================================="
    echo -e "               ${RED}FINAL WARNING${NC}"
    echo "=============================================="
    echo -e "Source File : ${YELLOW}${SELECTED_FILE}${NC}"
    echo -e "Target DB   : ${YELLOW}${TARGET_DB}${NC}"
    echo -e "Action      : ${RED}DROP & RESTORE${NC}"
    if [ -n "$NEW_DB_USER" ]; then
        echo -e "Create User : ${YELLOW}${NEW_DB_USER}@${USER_HOST}${NC}"
    fi
    echo "=============================================="
    read -p "Type 'confirm' to execute restoration: " FINAL_CONFIRM
    
    if [ "$FINAL_CONFIRM" != "confirm" ]; then
        log_info "Operation cancelled by user."
        rm -f "${LOCAL_FILE}"
        exit 0
    fi
    
    
    # 执行操作
    # 创建临时配置文件
    local mysql_config="/tmp/.mysql_restore_$$.cnf"
    create_mysql_config "$mysql_config" "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS"
    
    MYSQL_CMD="mysql --defaults-file=$mysql_config"
    
    # Drop 数据库
    log_info "Dropping database ${TARGET_DB}..."
    $MYSQL_CMD -e "DROP DATABASE IF EXISTS \`${TARGET_DB}\`;"
    
    # 创建数据库
    log_info "Creating database ${TARGET_DB}..."
    $MYSQL_CMD -e "CREATE DATABASE IF NOT EXISTS \`${TARGET_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    
    # 恢复数据
    log_info "Restoring data from file..."
    
    if [ "$CONTAINS_CREATE_STMTS" = true ]; then
        bunzip2 < "${LOCAL_FILE}" | $MYSQL_CMD
    else
        bunzip2 < "${LOCAL_FILE}" | $MYSQL_CMD "${TARGET_DB}"
    fi
    
    if [ ${PIPESTATUS[1]} -eq 0 ]; then
        log_info "Data restore complete."
    else
        log_err "Data restore encountered errors."
    fi
    
    # 创建用户并授权
    if [ "$NEW_DB_USER" != "" ]; then
        log_info "Creating user and granting privileges..."
        
        SQL_USER_OP="
        CREATE USER IF NOT EXISTS '${NEW_DB_USER}'@'${USER_HOST}' IDENTIFIED BY '${NEW_DB_PASS}';
        GRANT ALL PRIVILEGES ON \`${TARGET_DB}\`.* TO '${NEW_DB_USER}'@'${USER_HOST}';
        FLUSH PRIVILEGES;"
        
        $MYSQL_CMD -e "$SQL_USER_OP"
        
        if [ $? -eq 0 ]; then
            echo ""
            log_info "User Created Successfully."
        else
            log_err "Failed to create user."
        fi
    fi
    
    # 验证与信息打印
    echo ""
    echo "=============================================="
    echo -e "            ${GREEN}RESTORATION SUMMARY${NC}"
    echo "=============================================="
    
    echo -e "${CYAN}Existing Tables in '${TARGET_DB}':${NC}"
    $MYSQL_CMD -e "SHOW TABLES FROM \`${TARGET_DB}\`;"
    
    echo ""
    echo -e "${CYAN}User Access for '${TARGET_DB}':${NC}"
    if [ -n "$NEW_DB_USER" ]; then
        $MYSQL_CMD -N -e "SELECT user, host FROM mysql.user WHERE user='${NEW_DB_USER}';" 
    else
        echo "No new user created. Using existing root or other users."
    fi
    
    if [ -n "$NEW_DB_USER" ]; then
        echo "----------------------------------------------"
        echo -e "Credentials:"
        echo -e "DB Name  : ${GREEN}${TARGET_DB}${NC}"
        echo -e "User     : ${GREEN}${NEW_DB_USER}${NC}"
        echo -e "Host     : ${GREEN}${USER_HOST}${NC}"
        echo -e "Password : ${GREEN}${NEW_DB_PASS}${NC}"
        echo "----------------------------------------------"
    fi
    
    # 清理
    rm -f "$mysql_config"
    rm -f "${LOCAL_FILE}"
    rmdir "${RESTORE_TEMP_DIR}" 2>/dev/null
    
    log_info "Done."
}

# =================定时备份设置=================

setup_cron_backup() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║      Setup Scheduled Backup Task       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    # 首先配置 MySQL 连接（如果还未配置）
    setup_mysql_connection
    if [ $? -ne 0 ]; then
        return
    fi
    
    # 配置 VPS 实例名
    setup_vps_instance
    
    # 选择远程网盘
    log_info "Step 1: Select rclone remote for scheduled backups"
    RCLONE_REMOTE_NAME=$(select_rclone_remote)
    
    echo ""
    log_info "Selected remote: ${CYAN}${RCLONE_REMOTE_NAME}${NC}"
    
    # 设置定时任务时间
    echo ""
    log_info "Step 2: Configure backup schedule"
    echo ""
    echo "Common schedules:"
    echo "  1) Daily at 2:00 AM"
    echo "  2) Daily at 3:00 AM"
    echo "  3) Every 6 hours"
    echo "  4) Every 12 hours"
    echo "  5) Custom cron expression"
    echo ""
    
    read -p "Select schedule [1-5]: " schedule_choice
    
    case $schedule_choice in
        1)
            CRON_EXPR="0 2 * * *"
            SCHEDULE_DESC="Daily at 2:00 AM"
            ;;
        2)
            CRON_EXPR="0 3 * * *"
            SCHEDULE_DESC="Daily at 3:00 AM"
            ;;
        3)
            CRON_EXPR="0 */6 * * *"
            SCHEDULE_DESC="Every 6 hours"
            ;;
        4)
            CRON_EXPR="0 */12 * * *"
            SCHEDULE_DESC="Every 12 hours"
            ;;
        5)
            echo ""
            echo "Cron format: minute hour day month weekday"
            echo "Example: 0 2 * * * (Daily at 2:00 AM)"
            read -p "Enter custom cron expression: " CRON_EXPR
            SCHEDULE_DESC="Custom: ${CRON_EXPR}"
            ;;
        *)
            log_err "Invalid selection. Returning to main menu..."
            sleep 2
            return
            ;;
    esac
    
    # Step 3: 生成备份脚本（使用共享函数）
    echo ""
    BACKUP_SCRIPT=$(generate_mysql_backup_script "${RCLONE_REMOTE_NAME}")
    
    # Step 4: 添加到 crontab（使用共享函数）
    setup_crontab_for_script "${BACKUP_SCRIPT}" "${CRON_EXPR}" "${SCHEDULE_DESC}"
}

# =================系统配置备份=================

# 系统配置备份菜单
backup_system_config() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║      System Configuration Backup       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    # 配置 VPS 实例名
    setup_vps_instance
    
    # Step 1: 选择远程网盘
    log_info "Step 1: Select rclone remote for backups"
    RCLONE_REMOTE_NAME=$(select_rclone_remote)
    
    echo ""
    log_info "Selected remote: ${CYAN}${RCLONE_REMOTE_NAME}${NC}"
    
    # Step 2: 生成备份脚本
    BACKUP_SCRIPT="${SCRIPT_DIR}/auto_backup_system.sh"
    
    echo ""
    log_info "Step 2: Generating backup script..."
    
    cat > "${BACKUP_SCRIPT}" << 'SCRIPT_HEADER'
#!/bin/bash

# Auto-generated System backup script
# Generated by mysql_manager.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HEADER

    # 添加远程配置
    cat >> "${BACKUP_SCRIPT}" << SCRIPT_CONFIG
RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME}"
VPS_INSTANCE_NAME="${VPS_INSTANCE_NAME}"

SCRIPT_CONFIG

    # 添加备份逻辑
    cat >> "${BACKUP_SCRIPT}" << 'SCRIPT_BODY'
# 配置参数
SRC_DIR="/opt"
BACKUP_DIR="/backup"
LOG_DIR="/var/log/system_backup"
SYSTEM_LOG_FILE="/var/log/system_backup/backup_system.log"
EXCLUDE_FILE="${SCRIPT_DIR}/rclone-sync-exclude.txt"

REMOTE_PATH="/vps_backup/${VPS_INSTANCE_NAME}"
REMOTE_FULL="${RCLONE_REMOTE_NAME}:${REMOTE_PATH}"

LOG_RETENTION_DAYS=7

# 定义需要同步的系统配置目录
SYNC_DIRS=(
    "/root"
    "/var/spool/cron/crontabs"
    "/usr/local/openresty"
    "/etc/supervisor"
    "/etc/letsencrypt"
    "/etc/mysql"
    "/etc/nps"
    "/etc/php"
    "/etc/ansible"
    "/etc/systemd"
    "/etc/ssh"
    "/etc/default"
    "/etc/sysconfig"
    "/etc/redis"
    "/etc/postgresql"
    "/etc/netplan"
)

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${SYSTEM_LOG_FILE}"
}

mkdir -p "${BACKUP_DIR}"
mkdir -p "${LOG_DIR}"
: > "${SYSTEM_LOG_FILE}"

log_msg "=== System Backup Started ==="
log_msg "Using rclone remote: ${RCLONE_REMOTE_NAME}"
log_msg "Remote backup path: ${REMOTE_FULL}"

# 1. 生成 rclone 排除文件
log_msg "Generating exclude file: ${EXCLUDE_FILE}"
cat > "${EXCLUDE_FILE}" <<EOF
node_modules/**
.cache/**
.nvm/**
.npm/**
.bun/**
.local/**
temp/**
logs/**
EOF

# 2. 生成资产清单
log_msg "Generating system asset lists..."
systemctl list-units --type=service --state=running > "${BACKUP_DIR}/services_list.txt" 2>/dev/null
dpkg -l > "${BACKUP_DIR}/packages_list.txt" 2>/dev/null

log_msg "Uploading system info..."
rclone copy "${BACKUP_DIR}/services_list.txt" "${REMOTE_FULL}/sys_info" -P >> "${SYSTEM_LOG_FILE}" 2>&1
rclone copy "${BACKUP_DIR}/packages_list.txt" "${REMOTE_FULL}/sys_info" -P >> "${SYSTEM_LOG_FILE}" 2>&1

# 清理清单文件
rm "${BACKUP_DIR}/services_list.txt" "${BACKUP_DIR}/packages_list.txt"


# 3. 同步配置目录
log_msg "Starting Rclone Sync for configuration directories..."

for local_path in "${SYNC_DIRS[@]}"; do
    if [ -d "${local_path}" ]; then
        rel_path="${local_path#/}"
        log_msg "Syncing: ${local_path} -> ${REMOTE_FULL}/${rel_path}"
        
        rclone sync "${local_path}" "${REMOTE_FULL}/${rel_path}" \
            -P \
            --exclude-from "${EXCLUDE_FILE}" \
            >> "${SYSTEM_LOG_FILE}" 2>&1
    else
        log_msg "Warning: Directory not found, skipping: ${local_path}"
    fi
done

# 4. 处理应用目录 (/opt 和 /var/www)
TAR_EXCLUDES=(
    --exclude='*/node_modules'
    --exclude='*/.cache'
    --exclude='*/.nvm'
    --exclude='*/temp'
    --exclude='*/logs'
    --exclude='*/dokuwiki/data/cache'
    --exclude='*/dokuwiki/data/index'
    --exclude='*/dokuwiki/data/tmp'
)

process_directory() {
    local src_dir="$1"
    local remote_sub="$2"
    
    log_msg "Processing ${src_dir}..."
    
    if [ -d "${src_dir}" ]; then
        for item in "${src_dir}"/*; do
            [ -e "$item" ] || continue
            
            item_name=$(basename "${item}")
            
            if [ -f "${item}" ]; then
                log_msg "Copying file: ${item}"
                rclone copy "${item}" "${REMOTE_FULL}/${remote_sub}" -P >> "${SYSTEM_LOG_FILE}" 2>&1
            
            elif [ -d "${item}" ]; then
                archive_file="${BACKUP_DIR}/${item_name}.tar.gz"
                
                log_msg "Archiving directory: ${item} -> ${archive_file}"
                
                # 使用 tar 打包，排除指定目录
                tar "${TAR_EXCLUDES[@]}" -czf "${archive_file}" -C "${src_dir}" "${item_name}" >> "${SYSTEM_LOG_FILE}" 2>&1
                
                if [ $? -eq 0 ] && [ -f "${archive_file}" ]; then
                    log_msg "Uploading archive: ${archive_file}"
                    rclone copy "${archive_file}" "${REMOTE_FULL}/${remote_sub}" -P >> "${SYSTEM_LOG_FILE}" 2>&1
                    rm "${archive_file}"
                else
                    log_msg "Error: Failed to create archive for ${item_name}"
                fi
            fi
        done
    else
        log_msg "Warning: ${src_dir} not found, skipping."
    fi
}

# 处理 /opt
process_directory "/opt" "opt"

# 处理 /var/www
process_directory "/var/www" "var/www"


# 5. 日志归档
log_msg "=== System Backup Finished ==="

ARCHIVE_LOG_NAME="backup_system_$(date +%Y%m%d_%H%M%S).tar.gz"
ARCHIVE_LOG_PATH="${LOG_DIR}/${ARCHIVE_LOG_NAME}"

tar -czf "${ARCHIVE_LOG_PATH}" -C "${SCRIPT_DIR}" "$(basename "${SYSTEM_LOG_FILE}")"
rclone copy "${ARCHIVE_LOG_PATH}" "${REMOTE_FULL}/logs" -P >/dev/null 2>&1

# 6. 清理旧日志
log_msg "Cleaning up old logs..."
find "${LOG_DIR}" -name "backup_system_*.tar.gz" -type f -mtime +${LOG_RETENTION_DAYS} -exec rm {} \;
log_msg "Cleanup complete."

exit 0
SCRIPT_BODY

    chmod +x "${BACKUP_SCRIPT}"
    log_info "Backup script created: ${CYAN}${BACKUP_SCRIPT}${NC}"
    
    # Step 3: 选择执行方式
    echo ""
    log_info "Step 3: Choose execution method"
    echo ""
    echo "  1) Run backup now"
    echo "  2) Setup scheduled backup (crontab)"
    echo "  3) Cancel"
    echo ""
    
    read -p "Please select [1-3]: " exec_choice
    
    case $exec_choice in
        1)
            # 立即执行
            echo ""
            log_info "Executing backup now..."
            echo ""
            
            "${BACKUP_SCRIPT}"
            
            echo ""
            echo -e "${GREEN}✓ System backup completed!${NC}"
            echo -e "Log file: ${YELLOW}/var/log/system_backup/backup_system.log${NC}"
            echo ""
            ;;
        2)
            # 设置定时任务
            echo ""
            log_info "Configure backup schedule"
            echo ""
            echo "Common schedules:"
            echo "  1) Daily at 1:00 AM"
            echo "  2) Daily at 4:00 AM"
            echo "  3) Weekly (Sunday at 2:00 AM)"
            echo "  4) Custom cron expression"
            echo ""
            
            read -p "Select schedule [1-4]: " schedule_choice
            
            case $schedule_choice in
                1)
                    CRON_EXPR="0 1 * * *"
                    SCHEDULE_DESC="Daily at 1:00 AM"
                    ;;
                2)
                    CRON_EXPR="0 4 * * *"
                    SCHEDULE_DESC="Daily at 4:00 AM"
                    ;;
                3)
                    CRON_EXPR="0 2 * * 0"
                    SCHEDULE_DESC="Weekly (Sunday at 2:00 AM)"
                    ;;
                4)
                    echo ""
                    echo "Cron format: minute hour day month weekday"
                    echo "Example: 0 1 * * * (Daily at 1:00 AM)"
                    read -p "Enter custom cron expression: " CRON_EXPR
                    SCHEDULE_DESC="Custom: ${CRON_EXPR}"
                    ;;
                *)
                    log_err "Invalid selection."
                    return
                    ;;
            esac
            
            # 添加到 crontab
            echo ""
            log_info "Adding to crontab..."
            
            # 检查是否已存在相同的任务
            if crontab -l 2>/dev/null | grep -q "${BACKUP_SCRIPT}"; then
                log_warn "A cron job for this script already exists."
                read -p "Do you want to replace it? (yes/no) [default: no]: " replace_choice
                replace_choice=${replace_choice:-no}
                
                if [ "$replace_choice" != "yes" ]; then
                    log_info "Keeping existing cron job. Setup cancelled."
                    return
                fi
                
                # 删除旧的任务
                crontab -l 2>/dev/null | grep -v "${BACKUP_SCRIPT}" | crontab -
                log_info "Removed existing cron job."
            fi
            
            # 添加新任务
            (crontab -l 2>/dev/null; echo "${CRON_EXPR} ${BACKUP_SCRIPT} >> /var/log/system_backup/backup_system.log 2>&1") | crontab -
            
            if [ $? -eq 0 ]; then
                echo ""
                echo "============================================="
                echo -e "        ${GREEN}✓ Setup Completed Successfully${NC}"
                echo "============================================="
                echo -e "Remote        : ${CYAN}${RCLONE_REMOTE_NAME}${NC}"
                echo -e "Schedule      : ${CYAN}${SCHEDULE_DESC}${NC}"
                echo -e "Cron Expr     : ${YELLOW}${CRON_EXPR}${NC}"
                echo -e "Backup Script : ${YELLOW}${BACKUP_SCRIPT}${NC}"
                echo -e "Log File      : ${YELLOW}/var/log/system_backup/backup_system.log${NC}"
                echo "============================================="
                echo ""
                echo "Current crontab entries:"
                crontab -l | grep -v "^#" | grep -v "^$"
                echo ""
            else
                log_err "Failed to add cron job."
            fi
            ;;
        3)
            log_info "Cancelled."
            return
            ;;
        *)
            log_err "Invalid selection."
            return
            ;;
    esac
}


# =================还原 /opt 目录=================

restore_opt_directory() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║      Restore /opt Directory            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    # Step 1: 选择远程网盘
    log_info "Step 1: Select rclone remote for restore"
    RCLONE_REMOTE_NAME=$(select_rclone_remote)
    
    echo ""
    log_info "Selected remote: ${CYAN}${RCLONE_REMOTE_NAME}${NC}"
    
    # Step 2: 生成还原脚本
    RESTORE_SCRIPT="${SCRIPT_DIR}/restore_opt.sh"
    
    echo ""
    log_info "Step 2: Generating restore script..."
    
    cat > "${RESTORE_SCRIPT}" << 'SCRIPT_HEADER'
#!/bin/bash

# Auto-generated /opt restore script
# Generated by mysql_manager.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="${SCRIPT_DIR}/restore_files_temp"

# 基础路径
BASE_DIR="/opt"

# 还原后的文件所有者
OWNER_USER="www-data"
OWNER_GROUP="www-data"

SCRIPT_HEADER

    # 添加远程配置
    cat >> "${RESTORE_SCRIPT}" << SCRIPT_CONFIG
# rclone 远程目标
REMOTE_SOURCE="${RCLONE_REMOTE_NAME}:/vps_backup/${SERVER_NAME}/opt"

SCRIPT_CONFIG

    # 添加还原逻辑
    cat >> "${RESTORE_SCRIPT}" << 'SCRIPT_BODY'
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }
log_ask() { echo -e "${CYAN}[?]${NC} $1"; }

# Root 检查
if [ "$EUID" -ne 0 ]; then
    log_err "Please run as root."
    exit 1
fi

mkdir -p "${TEMP_DIR}"

# 列出远程文件
log_info "Fetching file list from remote..."
mapfile -t REMOTE_FILES < <(rclone lsf "${REMOTE_SOURCE}" --files-only | grep ".tar.gz" | sort)

if [ ${#REMOTE_FILES[@]} -eq 0 ]; then
    log_err "No backups found."
    exit 1
fi

echo "------------------------------------------------"
i=1
for file in "${REMOTE_FILES[@]}"; do
    echo -e "${GREEN}$i${NC}) $file"
    ((i++))
done
echo "------------------------------------------------"

read -p "Select file number: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#REMOTE_FILES[@]} ]; then
    log_err "Invalid selection."
    exit 1
fi

SELECTED_FILE="${REMOTE_FILES[$((choice-1))]}"
LOCAL_FILE="${TEMP_DIR}/${SELECTED_FILE}"

# 下载文件
if [ ! -f "${LOCAL_FILE}" ]; then
    log_info "Downloading ${SELECTED_FILE}..."
    rclone copyto "${REMOTE_SOURCE}/${SELECTED_FILE}" "${LOCAL_FILE}" -P
else
    log_info "Using cached file."
fi

# 智能分析压缩包结构
log_info "Analyzing archive structure..."

TOP_LEVEL_ITEMS=$(tar -tf "${LOCAL_FILE}" | sed -E 's/^\.\///g' | awk -F/ '{print $1}' | sort -u)
ITEM_COUNT=$(echo "$TOP_LEVEL_ITEMS" | wc -l)
FIRST_ITEM=$(echo "$TOP_LEVEL_ITEMS" | head -n 1)

STRIP_OPTION=""
DETECT_MSG=""

if [ "$ITEM_COUNT" -eq 1 ]; then
    STRIP_OPTION="--strip-components=1"
    DETECT_MSG="Structure: Single folder '${FIRST_ITEM}/'. Will STRIP this folder."
else
    STRIP_OPTION=""
    DETECT_MSG="Structure: Multiple items found. Will extract NORMALLY."
fi

log_info "${DETECT_MSG}"

# 确定目标目录
DEFAULT_DIR_NAME=$(echo "${SELECTED_FILE}" | sed 's/\.tar\.gz//')

echo ""
log_ask "Where should files be extracted to?"
echo "   Base directory is: ${BASE_DIR}"
echo "   Recommended subdirectory: ${DEFAULT_DIR_NAME}"
read -p "Enter subdirectory name (Press ENTER to use '${DEFAULT_DIR_NAME}'): " USER_SUB_DIR

if [ -z "$USER_SUB_DIR" ]; then
    SUB_DIR="${DEFAULT_DIR_NAME}"
else
    SUB_DIR="${USER_SUB_DIR}"
fi

FINAL_TARGET="${BASE_DIR}/${SUB_DIR}"

if [ -d "${FINAL_TARGET}" ]; then
    log_warn "Target directory already exists: ${FINAL_TARGET}"
    log_warn "Existing files will be overwritten/merged."
else
    log_info "Target directory will be created: ${FINAL_TARGET}"
fi

# 最终确认
echo ""
echo "=============================================="
echo -e "               ${RED}FINAL CHECK${NC}"
echo "=============================================="
echo -e "Archive    : ${YELLOW}${SELECTED_FILE}${NC}"
echo -e "Structure  : ${CYAN}${DETECT_MSG}${NC}"
echo -e "Extract To : ${YELLOW}${FINAL_TARGET}${NC}"
echo -e "Strip Comp : ${YELLOW}${STRIP_OPTION:-None}${NC}"
echo -e "Set Owner  : ${YELLOW}${OWNER_USER}:${OWNER_GROUP}${NC}"
echo "=============================================="
read -p "Type 'confirm' to execute: " FINAL_CONFIRM

if [ "$FINAL_CONFIRM" != "confirm" ]; then
    log_info "Cancelled."
    rm -f "${LOCAL_FILE}"
    exit 0
fi

# 执行解压与赋权
mkdir -p "${FINAL_TARGET}"

log_info "Extracting files..."
tar -xzvf "${LOCAL_FILE}" -C "${FINAL_TARGET}" ${STRIP_OPTION}

if [ $? -eq 0 ]; then
    log_info "Extraction successful."
    
    log_info "Setting permissions recursively for ${FINAL_TARGET}..."
    chown -R "${OWNER_USER}:${OWNER_GROUP}" "${FINAL_TARGET}"
    
    echo ""
    log_info "SUCCESS: Restore completed."
    echo "Files are located in: ${FINAL_TARGET}"
    ls -ld "${FINAL_TARGET}"
else
    log_err "Extraction failed."
fi

# 清理
rm -f "${LOCAL_FILE}"
rmdir "${TEMP_DIR}" 2>/dev/null

exit 0
SCRIPT_BODY

    chmod +x "${RESTORE_SCRIPT}"
    log_info "Restore script created: ${CYAN}${RESTORE_SCRIPT}${NC}"
    
    # Step 3: 选择执行方式
    echo ""
    log_info "Step 3: Choose action"
    echo ""
    echo "  1) Run restore now"
    echo "  2) Save script only (run manually later)"
    echo "  3) Cancel"
    echo ""
    
    read -p "Please select [1-3]: " exec_choice
    
    case $exec_choice in
        1)
            # 立即执行
            echo ""
            log_info "Executing restore now..."
            echo ""
            
            "${RESTORE_SCRIPT}"
            
            echo ""
            echo -e "${GREEN}✓ Restore script executed!${NC}"
            echo ""
            ;;
        2)
            # 仅保存脚本
            echo ""
            log_info "Script saved. You can run it manually:"
            echo -e "  ${YELLOW}${RESTORE_SCRIPT}${NC}"
            echo ""
            ;;
        3)
            log_info "Cancelled."
            return
            ;;
        *)
            log_err "Invalid selection."
            return
            ;;
    esac
}




# =================主菜单=================

show_menu() {
    clear
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║      MySQL Backup & Restore Tool      ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) Backup MySQL Databases"
    echo -e "  ${BLUE}2${NC}) Backup System Configuration"
    echo -e "  ${CYAN}3${NC}) Restore MySQL Database"
    echo -e "  ${YELLOW}4${NC}) Restore /opt Directory"
    echo -e "  ${RED}5${NC}) Exit"
    echo ""
    echo -e "${BLUE}────────────────────────────────────────${NC}"
    echo ""
}

main() {
    # 检查并安装 rclone
    check_and_install_rclone
    
    # 创建日志目录
    mkdir -p /var/log/mysql_backup
    mkdir -p /var/log/system_backup
    
    while true; do
        show_menu
        read -p "Please select an option [1-5]: " choice
        
        case $choice in
            1)
                backup_mysql
                read -p "Press Enter to continue..."
                ;;
            2)
                backup_system_config
                read -p "Press Enter to continue..."
                ;;
            3)
                restore_mysql
                read -p "Press Enter to continue..."
                ;;
            4)
                restore_opt_directory
                read -p "Press Enter to continue..."
                ;;
            5)
                echo ""
                echo -e "${GREEN}Goodbye!${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo ""
                echo -e "${RED}Invalid option. Please select 1, 2, 3, 4, or 5.${NC}"
                sleep 2
                ;;
        esac
    done
}

# =================脚本入口=================

main
