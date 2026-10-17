#!/bin/bash

# ============================================
# 容器和进程管理脚本
# 支持 Docker 和 Supervisor
# ============================================

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

# ============================================
# Docker 管理函数
# ============================================

# 检查 Docker 是否安装
check_docker() {
    if command -v docker &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 安装 Docker
install_docker() {
    clear
    echo "=========================================="
    echo "   安装 Docker"
    echo "=========================================="
    echo ""
    
    if check_docker; then
        print_warning "Docker 已安装"
        docker --version
        press_enter
        return
    fi
    
    print_info "正在安装 Docker..."
    echo ""
    
    # 安装依赖
    sudo apt update
    sudo apt install -y ca-certificates curl gnupg lsb-release
    
    # 添加 Docker 官方 GPG key
    print_info "添加 Docker GPG 密钥..."
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    # 添加 Docker 仓库
    print_info "添加 Docker 仓库..."
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # 安装 Docker Engine
    print_info "安装 Docker Engine..."
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    if [ $? -eq 0 ]; then
        print_success "Docker 安装成功"
        echo ""
        docker --version
        docker compose version
        
        # 启动 Docker 服务
        sudo systemctl start docker
        sudo systemctl enable docker
        
        print_success "Docker 服务已启动并设置为开机自启"
        
        # 添加当前用户到 docker 组
        echo ""
        read -p "是否将当前用户添加到 docker 组？(y/n): " add_user
        if [ "$add_user" = "y" ] || [ "$add_user" = "Y" ]; then
            sudo usermod -aG docker $USER
            print_success "用户已添加到 docker 组"
            print_warning "请注销并重新登录以使更改生效"
        fi
    else
        print_error "Docker 安装失败"
    fi
    
    press_enter
}

# 列出 Docker 容器
list_docker_containers() {
    clear
    echo "=========================================="
    echo "   Docker 容器列表"
    echo "=========================================="
    echo ""
    
    if ! check_docker; then
        print_error "Docker 未安装"
        press_enter
        return
    fi
    
    echo "1. 运行中的容器"
    echo "2. 所有容器（包括停止的）"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-2]: " choice
    
    case $choice in
        1)
            echo ""
            print_info "运行中的容器："
            echo ""
            sudo docker ps
            ;;
        2)
            echo ""
            print_info "所有容器："
            echo ""
            sudo docker ps -a
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# 管理 Docker 容器
manage_docker_container() {
    clear
    echo "=========================================="
    echo "   管理 Docker 容器"
    echo "=========================================="
    echo ""
    
    # 显示容器列表
    print_info "当前容器："
    sudo docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    
    echo "1. 启动容器"
    echo "2. 停止容器"
    echo "3. 重启容器"
    echo "4. 删除容器"
    echo "5. 查看容器日志"
    echo "6. 进入容器终端"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-6]: " choice
    
    case $choice in
        1)
            echo ""
            read -p "输入容器名称或ID: " container
            sudo docker start "$container"
            if [ $? -eq 0 ]; then
                print_success "容器已启动"
            else
                print_error "启动失败"
            fi
            ;;
        2)
            echo ""
            read -p "输入容器名称或ID: " container
            sudo docker stop "$container"
            if [ $? -eq 0 ]; then
                print_success "容器已停止"
            else
                print_error "停止失败"
            fi
            ;;
        3)
            echo ""
            read -p "输入容器名称或ID: " container
            sudo docker restart "$container"
            if [ $? -eq 0 ]; then
                print_success "容器已重启"
            else
                print_error "重启失败"
            fi
            ;;
        4)
            echo ""
            read -p "输入容器名称或ID: " container
            print_warning "警告：此操作将删除容器"
            read -p "确认删除？(yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                sudo docker rm -f "$container"
                if [ $? -eq 0 ]; then
                    print_success "容器已删除"
                else
                    print_error "删除失败"
                fi
            else
                print_info "已取消"
            fi
            ;;
        5)
            echo ""
            read -p "输入容器名称或ID: " container
            read -p "显示行数 (默认100): " lines
            lines=${lines:-100}
            echo ""
            sudo docker logs --tail "$lines" "$container"
            ;;
        6)
            echo ""
            read -p "输入容器名称或ID: " container
            print_info "进入容器终端（输入 exit 退出）"
            echo ""
            sudo docker exec -it "$container" /bin/bash || sudo docker exec -it "$container" /bin/sh
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# Docker 镜像管理
manage_docker_images() {
    clear
    echo "=========================================="
    echo "   Docker 镜像管理"
    echo "=========================================="
    echo ""
    
    echo "1. 列出镜像"
    echo "2. 拉取镜像"
    echo "3. 删除镜像"
    echo "4. 清理未使用的镜像"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-4]: " choice
    
    case $choice in
        1)
            echo ""
            print_info "本地镜像列表："
            echo ""
            sudo docker images
            ;;
        2)
            echo ""
            read -p "输入镜像名称 (例如: nginx:latest): " image
            print_info "正在拉取镜像..."
            sudo docker pull "$image"
            if [ $? -eq 0 ]; then
                print_success "镜像拉取成功"
            else
                print_error "拉取失败"
            fi
            ;;
        3)
            echo ""
            print_info "本地镜像："
            sudo docker images --format "{{.Repository}}:{{.Tag}}"
            echo ""
            read -p "输入镜像名称: " image
            print_warning "警告：此操作将删除镜像"
            read -p "确认删除？(yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                sudo docker rmi "$image"
                if [ $? -eq 0 ]; then
                    print_success "镜像已删除"
                else
                    print_error "删除失败"
                fi
            else
                print_info "已取消"
            fi
            ;;
        4)
            echo ""
            print_warning "清理未使用的镜像"
            read -p "确认清理？(yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                sudo docker image prune -a
                print_success "清理完成"
            else
                print_info "已取消"
            fi
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# Docker Compose 管理
manage_docker_compose() {
    clear
    echo "=========================================="
    echo "   Docker Compose 管理"
    echo "=========================================="
    echo ""
    
    read -p "输入 docker-compose.yml 所在目录 (默认当前目录): " compose_dir
    compose_dir=${compose_dir:-.}
    
    if [ ! -f "$compose_dir/docker-compose.yml" ] && [ ! -f "$compose_dir/compose.yaml" ]; then
        print_error "未找到 docker-compose.yml 文件"
        press_enter
        return
    fi
    
    echo ""
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    echo "4. 查看服务状态"
    echo "5. 查看服务日志"
    echo "6. 删除服务"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-6]: " choice
    
    cd "$compose_dir"
    
    case $choice in
        1)
            echo ""
            print_info "启动服务..."
            sudo docker compose up -d
            if [ $? -eq 0 ]; then
                print_success "服务已启动"
            else
                print_error "启动失败"
            fi
            ;;
        2)
            echo ""
            print_info "停止服务..."
            sudo docker compose stop
            if [ $? -eq 0 ]; then
                print_success "服务已停止"
            else
                print_error "停止失败"
            fi
            ;;
        3)
            echo ""
            print_info "重启服务..."
            sudo docker compose restart
            if [ $? -eq 0 ]; then
                print_success "服务已重启"
            else
                print_error "重启失败"
            fi
            ;;
        4)
            echo ""
            print_info "服务状态："
            echo ""
            sudo docker compose ps
            ;;
        5)
            echo ""
            read -p "显示行数 (默认100): " lines
            lines=${lines:-100}
            echo ""
            sudo docker compose logs --tail "$lines"
            ;;
        6)
            echo ""
            print_warning "警告：此操作将删除所有容器和网络"
            read -p "确认删除？(yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                sudo docker compose down
                if [ $? -eq 0 ]; then
                    print_success "服务已删除"
                else
                    print_error "删除失败"
                fi
            else
                print_info "已取消"
            fi
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# Docker 系统信息
docker_system_info() {
    clear
    echo "=========================================="
    echo "   Docker 系统信息"
    echo "=========================================="
    echo ""
    
    echo "1. Docker 版本信息"
    echo "2. 系统资源使用"
    echo "3. 磁盘使用情况"
    echo "4. 清理系统"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-4]: " choice
    
    case $choice in
        1)
            echo ""
            print_info "Docker 版本："
            sudo docker version
            echo ""
            print_info "Docker 信息："
            sudo docker info
            ;;
        2)
            echo ""
            print_info "容器资源使用："
            sudo docker stats --no-stream
            ;;
        3)
            echo ""
            print_info "磁盘使用情况："
            sudo docker system df
            ;;
        4)
            echo ""
            print_warning "清理未使用的容器、网络、镜像和构建缓存"
            read -p "确认清理？(yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                sudo docker system prune -a --volumes
                print_success "清理完成"
            else
                print_info "已取消"
            fi
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# Docker 服务管理
manage_docker_service() {
    clear
    echo "=========================================="
    echo "   Docker 服务管理"
    echo "=========================================="
    echo ""
    
    echo "1. 查看服务状态"
    echo "2. 启动服务"
    echo "3. 停止服务"
    echo "4. 重启服务"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-4]: " choice
    
    case $choice in
        1)
            sudo systemctl status docker --no-pager -l
            ;;
        2)
            sudo systemctl start docker
            print_success "Docker 服务已启动"
            ;;
        3)
            sudo systemctl stop docker
            print_success "Docker 服务已停止"
            ;;
        4)
            sudo systemctl restart docker
            print_success "Docker 服务已重启"
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# Docker 子菜单
docker_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   Docker 管理"
        echo "=========================================="
        echo ""
        
        if check_docker; then
            print_success "Docker 已安装"
            docker_version=$(docker --version | awk '{print $3}' | tr -d ',')
            echo "  版本: ${docker_version}"
            
            # 显示服务状态
            if systemctl is-active --quiet docker; then
                print_success "服务状态: 运行中"
            else
                print_error "服务状态: 已停止"
            fi
            
            # 显示容器统计
            running_containers=$(sudo docker ps -q | wc -l)
            total_containers=$(sudo docker ps -a -q | wc -l)
            echo "  容器: ${running_containers} 运行中 / ${total_containers} 总计"
        else
            print_warning "Docker 未安装"
        fi
        
        echo ""
        echo "1. 安装 Docker"
        echo "2. 列出容器"
        echo "3. 管理容器"
        echo "4. 镜像管理"
        echo "5. Docker Compose"
        echo "6. 系统信息"
        echo "7. 服务管理"
        echo "0. 返回上级菜单"
        echo ""
        
        read -p "请选择 [0-7]: " choice
        
        case $choice in
            1) install_docker ;;
            2) list_docker_containers ;;
            3) manage_docker_container ;;
            4) manage_docker_images ;;
            5) manage_docker_compose ;;
            6) docker_system_info ;;
            7) manage_docker_service ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# ============================================
# Supervisor 管理函数
# ============================================

# 检查 Supervisor 是否安装
check_supervisor() {
    if command -v supervisorctl &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 安装 Supervisor
install_supervisor() {
    clear
    echo "=========================================="
    echo "   安装 Supervisor"
    echo "=========================================="
    echo ""
    
    if check_supervisor; then
        print_warning "Supervisor 已安装"
        supervisorctl version
        press_enter
        return
    fi
    
    print_info "正在安装 Supervisor..."
    echo ""
    
    sudo apt update
    sudo apt install -y supervisor
    
    if [ $? -eq 0 ]; then
        print_success "Supervisor 安装成功"
        echo ""
        supervisorctl version
        
        # 启动服务
        sudo systemctl start supervisor
        sudo systemctl enable supervisor
        
        print_success "Supervisor 服务已启动并设置为开机自启"
        
        # 创建配置目录
        sudo mkdir -p /etc/supervisor/conf.d
        
        print_success "配置目录已创建: /etc/supervisor/conf.d"
    else
        print_error "Supervisor 安装失败"
    fi
    
    press_enter
}

# 列出 Supervisor 程序
list_supervisor_programs() {
    clear
    echo "=========================================="
    echo "   Supervisor 程序列表"
    echo "=========================================="
    echo ""
    
    if ! check_supervisor; then
        print_error "Supervisor 未安装"
        press_enter
        return
    fi
    
    print_info "程序状态："
    echo ""
    sudo supervisorctl status
    
    press_enter
}

# 管理 Supervisor 程序
manage_supervisor_program() {
    clear
    echo "=========================================="
    echo "   管理 Supervisor 程序"
    echo "=========================================="
    echo ""
    
    # 显示程序列表
    print_info "当前程序："
    sudo supervisorctl status
    echo ""
    
    echo "1. 启动程序"
    echo "2. 停止程序"
    echo "3. 重启程序"
    echo "4. 查看程序日志"
    echo "5. 清空程序日志"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-5]: " choice
    
    case $choice in
        1)
            echo ""
            read -p "输入程序名称 (all 表示所有): " program
            sudo supervisorctl start "$program"
            if [ $? -eq 0 ]; then
                print_success "程序已启动"
            else
                print_error "启动失败"
            fi
            ;;
        2)
            echo ""
            read -p "输入程序名称 (all 表示所有): " program
            sudo supervisorctl stop "$program"
            if [ $? -eq 0 ]; then
                print_success "程序已停止"
            else
                print_error "停止失败"
            fi
            ;;
        3)
            echo ""
            read -p "输入程序名称 (all 表示所有): " program
            sudo supervisorctl restart "$program"
            if [ $? -eq 0 ]; then
                print_success "程序已重启"
            else
                print_error "重启失败"
            fi
            ;;
        4)
            echo ""
            read -p "输入程序名称: " program
            read -p "显示行数 (默认100): " lines
            lines=${lines:-100}
            echo ""
            sudo supervisorctl tail -"$lines" "$program"
            ;;
        5)
            echo ""
            read -p "输入程序名称: " program
            print_warning "警告：此操作将清空日志文件"
            read -p "确认清空？(yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                sudo supervisorctl clear "$program"
                if [ $? -eq 0 ]; then
                    print_success "日志已清空"
                else
                    print_error "清空失败"
                fi
            else
                print_info "已取消"
            fi
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# 创建 Supervisor 程序配置
create_supervisor_program() {
    clear
    echo "=========================================="
    echo "   创建 Supervisor 程序"
    echo "=========================================="
    echo ""
    
    read -p "程序名称: " program_name
    if [ -z "$program_name" ]; then
        print_error "程序名称不能为空"
        press_enter
        return
    fi
    
    read -p "启动命令: " command
    if [ -z "$command" ]; then
        print_error "启动命令不能为空"
        press_enter
        return
    fi
    
    read -p "工作目录 (可选): " directory
    read -p "运行用户 (默认: root): " user
    user=${user:-root}
    
    read -p "自动启动 (y/n，默认: y): " autostart
    autostart=${autostart:-y}
    [ "$autostart" = "y" ] && autostart="true" || autostart="false"
    
    read -p "自动重启 (y/n，默认: y): " autorestart
    autorestart=${autorestart:-y}
    [ "$autorestart" = "y" ] && autorestart="true" || autorestart="false"
    
    # 创建配置文件
    local config_file="/etc/supervisor/conf.d/${program_name}.conf"
    
    sudo tee "$config_file" > /dev/null << EOF
[program:${program_name}]
command=${command}
autostart=${autostart}
autorestart=${autorestart}
startsecs=3
startretries=3
user=${user}
redirect_stderr=true
stdout_logfile=/var/log/supervisor/%(program_name)s.log
stdout_logfile_maxbytes=0
stdout_logfile_backups=0
stderr_logfile=/var/log/supervisor/%(program_name)s_error.log
stderr_logfile_maxbytes=0
stderr_logfile_backups=0
EOF
    
    # 添加工作目录（如果指定）
    if [ -n "$directory" ]; then
        echo "directory=${directory}" | sudo tee -a "$config_file" > /dev/null
    fi
    
    print_success "配置文件已创建: ${config_file}"
    echo ""
    
    # 重新加载配置
    print_info "重新加载配置..."
    sudo supervisorctl reread
    sudo supervisorctl update
    
    if [ $? -eq 0 ]; then
        print_success "程序已添加"
        echo ""
        read -p "是否立即启动程序？(y/n): " start_now
        if [ "$start_now" = "y" ]; then
            sudo supervisorctl start "$program_name"
            print_success "程序已启动"
        fi
    else
        print_error "配置重载失败"
    fi
    
    press_enter
}

# 删除 Supervisor 程序
delete_supervisor_program() {
    clear
    echo "=========================================="
    echo "   删除 Supervisor 程序"
    echo "=========================================="
    echo ""
    
    # 列出程序
    print_info "已配置的程序："
    echo ""
    
    local i=1
    declare -A program_map
    
    for conf in /etc/supervisor/conf.d/*.conf; do
        if [ -f "$conf" ]; then
            local program=$(basename "$conf" .conf)
            echo "${i}. ${program}"
            program_map[$i]="$program"
            ((i++))
        fi
    done
    
    echo ""
    read -p "选择要删除的程序编号: " choice
    
    local selected_program="${program_map[$choice]}"
    
    if [ -z "$selected_program" ]; then
        print_error "无效选择"
        press_enter
        return
    fi
    
    print_warning "警告：此操作将删除程序配置"
    read -p "确认删除 ${selected_program}？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 停止程序
    print_info "停止程序..."
    sudo supervisorctl stop "$selected_program"
    
    # 删除配置文件
    sudo rm -f "/etc/supervisor/conf.d/${selected_program}.conf"
    
    # 重新加载配置
    sudo supervisorctl reread
    sudo supervisorctl update
    
    print_success "程序已删除"
    
    echo ""
    read -p "是否同时删除日志文件？(yes/no): " delete_logs
    if [ "$delete_logs" = "yes" ]; then
        sudo rm -f "/var/log/supervisor/${selected_program}.log"
        sudo rm -f "/var/log/supervisor/${selected_program}_error.log"
        print_success "日志文件已删除"
    fi
    
    press_enter
}

# 编辑 Supervisor 程序配置
edit_supervisor_program() {
    clear
    echo "=========================================="
    echo "   编辑 Supervisor 程序配置"
    echo "=========================================="
    echo ""
    
    # 列出程序
    print_info "已配置的程序："
    echo ""
    
    local i=1
    declare -A program_map
    
    for conf in /etc/supervisor/conf.d/*.conf; do
        if [ -f "$conf" ]; then
            local program=$(basename "$conf" .conf)
            echo "${i}. ${program}"
            program_map[$i]="$program"
            ((i++))
        fi
    done
    
    echo ""
    read -p "选择要编辑的程序编号: " choice
    
    local selected_program="${program_map[$choice]}"
    
    if [ -z "$selected_program" ]; then
        print_error "无效选择"
        press_enter
        return
    fi
    
    local config_file="/etc/supervisor/conf.d/${selected_program}.conf"
    
    # 使用默认编辑器编辑
    sudo ${EDITOR:-nano} "$config_file"
    
    echo ""
    print_info "重新加载配置..."
    sudo supervisorctl reread
    sudo supervisorctl update
    
    if [ $? -eq 0 ]; then
        print_success "配置已更新"
        echo ""
        read -p "是否重启程序？(y/n): " restart_now
        if [ "$restart_now" = "y" ]; then
            sudo supervisorctl restart "$selected_program"
            print_success "程序已重启"
        fi
    else
        print_error "配置重载失败"
    fi
    
    press_enter
}

# Supervisor 服务管理
manage_supervisor_service() {
    clear
    echo "=========================================="
    echo "   Supervisor 服务管理"
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
            sudo systemctl status supervisor --no-pager -l
            ;;
        2)
            sudo systemctl start supervisor
            print_success "Supervisor 服务已启动"
            ;;
        3)
            sudo systemctl stop supervisor
            print_success "Supervisor 服务已停止"
            ;;
        4)
            sudo systemctl restart supervisor
            print_success "Supervisor 服务已重启"
            ;;
        5)
            print_info "重新加载配置..."
            sudo supervisorctl reread
            sudo supervisorctl update
            print_success "配置已重新加载"
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# Supervisor 子菜单
supervisor_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   Supervisor 管理"
        echo "=========================================="
        echo ""
        
        if check_supervisor; then
            print_success "Supervisor 已安装"
            supervisor_version=$(supervisorctl version 2>/dev/null)
            echo "  版本: ${supervisor_version}"
            
            # 显示服务状态
            if systemctl is-active --quiet supervisor; then
                print_success "服务状态: 运行中"
            else
                print_error "服务状态: 已停止"
            fi
            
            # 显示程序统计
            if systemctl is-active --quiet supervisor; then
                total_programs=$(sudo supervisorctl status 2>/dev/null | wc -l)
                running_programs=$(sudo supervisorctl status 2>/dev/null | grep RUNNING | wc -l)
                echo "  程序: ${running_programs} 运行中 / ${total_programs} 总计"
            fi
        else
            print_warning "Supervisor 未安装"
        fi
        
        echo ""
        echo "1. 安装 Supervisor"
        echo "2. 列出程序"
        echo "3. 管理程序"
        echo "4. 创建程序"
        echo "5. 编辑程序"
        echo "6. 删除程序"
        echo "7. 服务管理"
        echo "0. 返回上级菜单"
        echo ""
        
        read -p "请选择 [0-7]: " choice
        
        case $choice in
            1) install_supervisor ;;
            2) list_supervisor_programs ;;
            3) manage_supervisor_program ;;
            4) create_supervisor_program ;;
            5) edit_supervisor_program ;;
            6) delete_supervisor_program ;;
            7) manage_supervisor_service ;;
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
        echo "   容器和进程管理"
        echo "=========================================="
        echo ""
        
        # 显示安装状态
        if check_docker; then
            print_success "Docker: 已安装"
            if systemctl is-active --quiet docker; then
                running_containers=$(sudo docker ps -q 2>/dev/null | wc -l)
                echo "  运行容器: ${running_containers}"
            fi
        else
            echo -e "${YELLOW}○${NC} Docker: 未安装"
        fi
        
        if check_supervisor; then
            print_success "Supervisor: 已安装"
            if systemctl is-active --quiet supervisor; then
                running_programs=$(sudo supervisorctl status 2>/dev/null | grep RUNNING | wc -l)
                echo "  运行程序: ${running_programs}"
            fi
        else
            echo -e "${YELLOW}○${NC} Supervisor: 未安装"
        fi
        
        echo ""
        echo "1. Docker 管理"
        echo "2. Supervisor 管理"
        echo ""
        echo "0. 返回主菜单"
        echo ""
        
        read -p "请选择 [0-2]: " choice
        
        case $choice in
            1) docker_menu ;;
            2) supervisor_menu ;;
            0) exit 0 ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# 启动主菜单
main_menu
