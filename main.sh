#!/bin/bash
set -euo pipefail


# ============================================
# Debian 12 系统配置工具 - 主菜单
# ============================================


# GitHub 配置
GITHUB_USER="wyrover"
GITHUB_REPO="vps-setup"
GITHUB_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# 版本信息
VERSION="1.4.0"
LAST_UPDATE="2026-01-22"


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


# 直接执行在线子脚本（改进版）
run_subscript() {
    local script_name=$1
    local script_url="${BASE_URL}/scripts/${script_name}.sh"
    local cache_bust="t=$(date +%s)"

    echo ""
    print_info "正在加载模块: ${script_name}..."

    bash <(curl -fsSL \
      -H 'Cache-Control: no-cache' \
      -H 'Pragma: no-cache' \
      "${script_url}?${cache_bust}") || {

        echo ""
        print_error "模块加载失败"
        print_warning "可能的原因："
        echo "  1. 脚本文件不存在: ${script_name}.sh"
        echo "  2. 网络连接中断"
        echo "  3. 脚本执行出错"
        echo ""
        read -p "按 Enter 键继续..."
        return 1
    }

    return 0
}


# 融合怪综合测试
run_fusion_benchmark() {
    clear
    echo "=========================================="
    echo "   🎯 融合怪综合测试"
    echo "=========================================="
    echo ""
    
    print_info "融合怪 (ECS) 综合性能测试工具"
    echo ""
    print_warning "此测试将进行以下项目："
    echo "  1. 系统基础信息检测"
    echo "  2. CPU 性能测试"
    echo "  3. 内存性能测试"
    echo "  4. 磁盘 I/O 测试"
    echo "  5. 网络性能测试（多节点）"
    echo "  6. 流媒体解锁测试"
    echo "  7. IP 质量检测"
    echo "  8. 三网路由追踪"
    echo ""
    print_info "测试时间: 约 15-30 分钟"
    print_warning "测试会产生较大网络流量"
    echo ""
    
    read -p "是否开始测试？(y/n): " confirm
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        print_info "已取消测试"
        read -p "按 Enter 键继续..."
        return
    fi
    
    echo ""
    print_info "正在启动融合怪测试..."
    echo ""
    echo "=========================================="
    echo ""
    
    # 直接执行融合怪脚本（不写入文件）
    bash <(curl -L https://github.com/spiritLHLS/ecs/raw/main/ecs.sh)
    
    echo ""
    echo "=========================================="
    print_success "测试完成"
    echo "=========================================="
    echo ""
    
    read -p "按 Enter 键继续..."
}


# YABS 性能测试子菜单
yabs_benchmark_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   🚀 YABS 性能测试"
        echo "=========================================="
        echo ""
        print_info "YABS (Yet Another Bench Script) 性能测试工具"
        echo ""
        
        echo -e "${CYAN}[完整测试]${NC}"
        echo "1. 完整测试 (全部项目)"
        echo "2. 完整测试 + Geekbench 4"
        echo "3. 完整测试 + Geekbench 5"
        echo "4. 完整测试 + GB4 + GB5"
        echo ""
        
        echo -e "${CYAN}[跳过特定测试]${NC}"
        echo "5. 跳过磁盘测试 (-f)"
        echo "6. 跳过网络测试 (-i)"
        echo "7. 跳过 Geekbench (-g)"
        echo "8. 仅网络测试 (-fd)"
        echo "9. 仅磁盘测试 (-ig)"
        echo ""
        
        echo -e "${CYAN}[减少网络测试]${NC}"
        echo "10. 减少网络节点 (-r)"
        echo "11. 完整测试 + 减少节点"
        echo ""
        
        echo -e "${CYAN}[输出选项]${NC}"
        echo "12. 输出 JSON 格式 (-j)"
        echo "13. 保存 JSON 到文件 (-w)"
        echo ""
        
        echo -e "${YELLOW}[说明]${NC}"
        echo "h. 查看详细说明"
        echo ""
        
        echo "0. 返回上级菜单"
        echo ""
        echo "=========================================="
        read -p "请选择 [0-13/h]: " choice
        
        case $choice in
            1)
                run_yabs_test ""
                ;;
            2)
                run_yabs_test "-4"
                ;;
            3)
                run_yabs_test "-5"
                ;;
            4)
                run_yabs_test "-9"
                ;;
            5)
                run_yabs_test "-f"
                ;;
            6)
                run_yabs_test "-i"
                ;;
            7)
                run_yabs_test "-g"
                ;;
            8)
                run_yabs_test "-fg"
                ;;
            9)
                run_yabs_test "-ig"
                ;;
            10)
                run_yabs_test "-r"
                ;;
            11)
                run_yabs_test "-r"
                ;;
            12)
                run_yabs_test "-j"
                ;;
            13)
                run_yabs_test_with_file
                ;;
            h|H)
                show_yabs_help
                ;;
            0)
                return
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}


# 执行 YABS 测试
run_yabs_test() {
    local flags=$1
    local test_name="YABS 性能测试"
    
    clear
    echo "=========================================="
    echo "   ${test_name}"
    echo "=========================================="
    echo ""
    
    if [ -n "$flags" ]; then
        print_info "测试参数: $flags"
        echo ""
    fi
    
    print_warning "注意事项："
    echo "  • 测试时间: 5-15 分钟（取决于配置）"
    echo "  • 网络测试会占用大量带宽"
    echo "  • Geekbench 测试需要下载约 300MB"
    echo ""
    
    read -p "是否开始测试？(y/n): " confirm
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        print_info "已取消测试"
        read -p "按 Enter 键继续..."
        return
    fi
    
    echo ""
    print_info "正在启动测试..."
    echo ""
    echo "=========================================="
    echo ""
    
    # 执行 YABS 测试
    if [ -n "$flags" ]; then
        curl -sL https://yabs.sh | bash -s -- $flags
    else
        curl -sL https://yabs.sh | bash
    fi
    
    echo ""
    echo "=========================================="
    print_success "测试完成"
    echo "=========================================="
    echo ""
    
    read -p "按 Enter 键继续..."
}


# 执行 YABS 测试并保存到文件
run_yabs_test_with_file() {
    clear
    echo "=========================================="
    echo "   保存 YABS 结果到文件"
    echo "=========================================="
    echo ""
    
    local default_file="yabs_result_$(date +%Y%m%d_%H%M%S).json"
    
    read -p "输入文件名 (默认: $default_file): " filename
    filename=${filename:-$default_file}
    
    # 确保文件名以 .json 结尾
    if [[ ! "$filename" =~ \.json$ ]]; then
        filename="${filename}.json"
    fi
    
    echo ""
    print_info "结果将保存到: $filename"
    echo ""
    
    read -p "是否开始测试？(y/n): " confirm
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        print_info "已取消测试"
        read -p "按 Enter 键继续..."
        return
    fi
    
    echo ""
    print_info "正在启动测试..."
    echo ""
    echo "=========================================="
    echo ""
    
    # 执行 YABS 测试并保存
    curl -sL https://yabs.sh | bash -s -- -w "$filename"
    
    echo ""
    echo "=========================================="
    print_success "测试完成"
    echo ""
    
    if [ -f "$filename" ]; then
        print_success "结果已保存到: $filename"
        echo "文件大小: $(du -h $filename | awk '{print $1}')"
    else
        print_error "文件保存失败"
    fi
    
    echo "=========================================="
    echo ""
    
    read -p "按 Enter 键继续..."
}


# 显示 YABS 帮助信息
show_yabs_help() {
    clear
    echo "=========================================="
    echo "   YABS 测试说明"
    echo "=========================================="
    echo ""
    
    echo -e "${CYAN}测试项目：${NC}"
    echo ""
    echo "1. 磁盘性能测试 (fio)"
    echo "   • 4K、64K、512K、1M 块大小"
    echo "   • 随机读写混合测试 (50/50)"
    echo "   • 评估磁盘 IOPS 和吞吐量"
    echo ""
    
    echo "2. 网络性能测试 (iperf3)"
    echo "   • 多个全球节点测试"
    echo "   • 8 个并行线程"
    echo "   • 测试上传和下载速度"
    echo "   • 支持 IPv4 和 IPv6"
    echo ""
    
    echo "3. 系统性能测试 (Geekbench)"
    echo "   • 默认: Geekbench 6"
    echo "   • 可选: Geekbench 4 或 5"
    echo "   • 单核和多核性能评分"
    echo "   • 提供在线结果链接"
    echo ""
    
    echo -e "${CYAN}常用参数：${NC}"
    echo ""
    echo "  -f/-d  跳过磁盘测试"
    echo "  -i     跳过网络测试"
    echo "  -g     跳过 Geekbench 测试"
    echo "  -n     跳过网络信息查询"
    echo "  -r     减少网络测试节点（节省带宽）"
    echo "  -4     运行 Geekbench 4 (替代 GB6)"
    echo "  -5     运行 Geekbench 5 (替代 GB6)"
    echo "  -9     同时运行 GB4 和 GB5 (替代 GB6)"
    echo "  -j     输出 JSON 格式"
    echo "  -w     保存 JSON 结果到文件"
    echo ""
    
    echo -e "${CYAN}组合使用：${NC}"
    echo ""
    echo "  -fg    仅测试网络性能"
    echo "  -ig    仅测试磁盘性能"
    echo "  -fgi   仅显示系统信息"
    echo ""
    
    echo -e "${YELLOW}注意事项：${NC}"
    echo ""
    echo "  • 完整测试需要 5-15 分钟"
    echo "  • 网络测试会产生大量流量 (~10GB)"
    echo "  • 低带宽服务器建议使用 -r 或 -i"
    echo "  • Geekbench 需要下载 ~300MB"
    echo "  • 测试期间可能影响服务器性能"
    echo ""
    
    echo -e "${CYAN}官方文档：${NC}"
    echo "  https://github.com/masonr/yet-another-bench-script"
    echo ""
    
    read -p "按 Enter 键继续..."
}


# 测试连接
test_connection() {
    clear
    echo "=========================================="
    echo "   🔧 测试 GitHub 连接"
    echo "=========================================="
    echo ""
    print_info "正在测试连接..."
    echo ""
    
    # 测试主脚本
    local test_url="${BASE_URL}/main.sh"
    echo "测试 1/3: 主脚本"
    if curl -fsSL --head "$test_url" &> /dev/null; then
        print_success "主脚本可访问"
    else
        print_error "主脚本不可访问"
    fi
    
    # 测试子脚本目录
    test_url="${BASE_URL}/scripts/system.sh"
    echo "测试 2/3: 系统配置脚本"
    if curl -fsSL --head "$test_url" &> /dev/null; then
        print_success "系统配置脚本可访问"
    else
        print_warning "系统配置脚本不可访问"
    fi
    
    # 测试 GitHub 连接
    echo "测试 3/3: GitHub 服务器"
    if ping -c 1 raw.githubusercontent.com &> /dev/null; then
        print_success "GitHub 服务器连接正常"
    else
        print_error "无法连接到 GitHub 服务器"
    fi
    
    echo ""
    echo "当前配置："
    echo "  仓库: ${GITHUB_USER}/${GITHUB_REPO}"
    echo "  分支: ${GITHUB_BRANCH}"
    echo "  基础URL: ${BASE_URL}"
    echo ""
    
    read -p "按 Enter 键继续..."
}


# 显示系统信息
show_system_info() {
    clear
    echo "=========================================="
    echo "   📊 系统信息"
    echo "=========================================="
    echo ""
    
    echo -e "${CYAN}操作系统信息:${NC}"
    echo "  系统: $(lsb_release -ds 2>/dev/null || echo 'Unknown')"
    echo "  内核: $(uname -r)"
    echo "  架构: $(uname -m)"
    echo "  主机名: $(hostname)"
    echo ""
    
    echo -e "${CYAN}硬件信息:${NC}"
    echo "  CPU: $(nproc) 核心"
    echo "  内存: $(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
    echo "  磁盘 (/): $(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')"
    echo ""
    
    echo -e "${CYAN}运行时间:${NC}"
    echo "  在线时间: $(uptime -p)"
    echo "  启动时间: $(who -b | awk '{print $3, $4}')"
    echo ""
    
    echo -e "${CYAN}网络信息:${NC}"
    echo "  公网IP: $(curl -s ifconfig.me || echo '获取失败')"
    local_ip=$(hostname -I | awk '{print $1}')
    echo "  本地IP: ${local_ip}"
    echo ""
    
    echo -e "${CYAN}脚本信息:${NC}"
    echo "  版本: v${VERSION}"
    echo "  更新: ${LAST_UPDATE}"
    echo "  仓库: https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
    echo ""
    
    read -p "按 Enter 键继续..."
}


# 更新脚本
update_script() {
    clear
    echo "=========================================="
    echo "   🔄 更新脚本"
    echo "=========================================="
    echo ""
    
    print_info "正在从 GitHub 获取最新版本..."
    echo ""
    
    local temp_file="/tmp/main_update.sh"
    local script_path="$0"
    
    if curl -fsSL "${BASE_URL}/main.sh" -o "$temp_file"; then
        print_success "下载成功"
        
        # 比较版本
        local current_version="${VERSION}"
        local new_version=$(grep "^VERSION=" "$temp_file" | cut -d'"' -f2 || echo "未知")
        
        echo ""
        echo "当前版本: v${current_version}"
        echo "最新版本: v${new_version}"
        echo ""
        
        if [ "$current_version" = "$new_version" ]; then
            print_info "已是最新版本"
            rm -f "$temp_file"
        else
            read -p "是否更新到最新版本？(y/n): " confirm
            
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                # 备份当前脚本
                if [ -f "$script_path" ]; then
                    local backup_file="${script_path}.bak.$(date +%Y%m%d_%H%M%S)"
                    cp "$script_path" "$backup_file"
                    print_success "已备份到: ${backup_file}"
                fi
                
                # 替换脚本
                cat "$temp_file" > "$script_path"
                chmod +x "$script_path"
                rm -f "$temp_file"
                
                print_success "脚本已更新到 v${new_version}"
                echo ""
                print_info "即将重新启动..."
                sleep 2
                exec "$script_path"
            else
                print_info "已取消更新"
                rm -f "$temp_file"
            fi
        fi
    else
        print_error "下载失败"
        echo ""
        print_warning "请检查："
        echo "  1. 网络连接"
        echo "  2. GitHub 仓库是否可访问"
        echo "  3. 文件路径是否正确"
    fi
    
    echo ""
    read -p "按 Enter 键继续..."
}


# 显示帮助信息
show_help() {
    clear
    echo "=========================================="
    echo "   📖 使用帮助"
    echo "=========================================="
    echo ""
    
    echo -e "${CYAN}关于本工具:${NC}"
    echo "  Debian 12 系统配置工具集，通过远程脚本"
    echo "  实现模块化系统管理和配置。"
    echo ""
    
    echo -e "${CYAN}功能模块:${NC}"
    echo "  1. 安全配置  - SSH密钥、防火墙、Fail2ban"
    echo "  2. 系统配置  - 主机名、时区、软件包管理"
    echo "  3. 监控查看  - 系统状态、日志查看"
    echo "  4. 网络配置  - 网络接口、DNS、路由"
    echo "  5. 日志管理  - 日志轮转（3天保留策略）"
    echo "  6. 数据库管理 - PostgreSQL、MySQL/MariaDB"
    echo "  7. Web服务器 - OpenResty、Nginx、Caddy"
    echo "  8. 容器管理  - Docker、Supervisor"
    echo "  9. LXC容器   - LXC/LXD 容器管理"
    echo ""
    
    echo -e "${CYAN}快捷使用:${NC}"
    echo "  # 直接运行（不需要下载）"
    echo "  bash <(curl -fsSL ${BASE_URL}/main.sh)"
    echo ""
    echo "  # 创建快捷命令"
    echo "  echo 'alias sysmenu=\"bash <(curl -fsSL ${BASE_URL}/main.sh)\"' >> ~/.bashrc"
    echo "  source ~/.bashrc"
    echo "  sysmenu"
    echo ""
    
    echo -e "${CYAN}技术支持:${NC}"
    echo "  GitHub: https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
    echo "  Issues: https://github.com/${GITHUB_USER}/${GITHUB_REPO}/issues"
    echo ""
    
    read -p "按 Enter 键继续..."
}


# ============================================
# 主菜单
# ============================================


show_main_menu() {
    clear
    echo "=========================================="
    echo "   Debian 12 系统配置工具 v${VERSION}"
    echo "=========================================="
    echo ""
    echo "【系统管理】"
    echo ""
    echo "1. 🔒 安全与监控"
    echo "   (SSH密钥、Fail2ban、防火墙、状态查看等)"
    echo ""
    echo "2. ⚙️  系统配置"
    echo "   (Hostname、时区、软件包等)"
    echo ""
    echo "3. 🌐 网络配置"
    echo "   (网络接口、路由、DNS等)"
    echo ""
    echo "【应用管理】"
    echo ""
    echo "4. 📝 日志管理"
    echo "   (日志轮转、查看、清理 - 3天保留)"
    echo ""
    echo "5. 🗄️  数据库管理"
    echo "   (PostgreSQL、MySQL/MariaDB)"
    echo ""
    echo "6. 🌍 Web服务管理"
    echo "   (OpenResty、Nginx、Caddy、PHP8.5、NVM(node)、Supervisor)"
    echo ""
    echo "7. 🌐 Web应用安装"
    echo "   (Tiny Tiny RSS、WordPress、phpMyAdmin 等)"
    echo ""
    echo "8. 📦 Docker容器管理"
    echo "   (Docker 容器创建、管理)"
    echo ""
    echo "9. 🔲 LXC容器管理"
    echo "   (LXC/LXD 容器创建、管理)"
    echo ""
    echo "a. ☁️  Rclone 配置"
    echo "   (云存储挂载、配置管理)"
    echo ""
    echo "【测试工具】"
    echo ""
    echo "b. 🚀 YABS 性能测试 (多种模式)"
    echo "c. 🎯 融合怪综合测试 (全面评估)"
    echo ""
    echo "【系统工具】"
    echo ""
    echo "i. 📊 系统信息"
    echo "t. 🔧 测试连接"
    echo "u. 🔄 更新脚本"
    echo "h. 📖 帮助信息"
    echo ""
    echo "0. 退出"
    echo ""
    echo "=========================================="
    echo "仓库: github.com/${GITHUB_USER}/${GITHUB_REPO}"
    echo "=========================================="
}

main_menu() {
    while true; do
        show_main_menu
        read -p "请选择 [0-9/a-c/i/t/u/h]: " choice
        
        case $choice in
            1)
                run_subscript "security_monitoring"
                ;;
            2)
                run_subscript "system"
                ;;
            3)
                run_subscript "network"
                ;;
            4)
                run_subscript "logrotate_setup"
                ;;
            5)
                run_subscript "database_management"
                ;;
            6)
                run_subscript "web_server"
                ;;
            7)
                run_subscript "web_apps"
                ;;
            8)
                run_subscript "container_management"
                ;;
            9)
                run_subscript "lxc_management"
                ;;
            a|A)
                run_subscript "rclone_setup"
                ;;
            b|B)
                yabs_benchmark_menu
                ;;
            c|C)
                run_fusion_benchmark
                ;;
            i|I)
                show_system_info
                ;;
            t|T)
                test_connection
                ;;
            u|U)
                update_script
                ;;
            h|H)
                show_help
                ;;
            0)
                echo ""
                print_success "感谢使用，再见！"
                exit 0
                ;;
            *)
                print_error "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}


# ============================================
# 脚本入口
# ============================================


# 检查依赖
check_dependencies() {
    local missing_deps=()
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "缺少必要的依赖: ${missing_deps[*]}"
        echo ""
        print_info "请先安装依赖："
        echo "  sudo apt update"
        echo "  sudo apt install -y ${missing_deps[*]}"
        exit 1
    fi
}


# 显示欢迎信息
show_welcome() {
    clear
    echo "=========================================="
    echo "   欢迎使用 Debian 12 系统配置工具"
    echo "=========================================="
    echo ""
    print_info "正在初始化..."
    
    # 检查系统
    if [ ! -f /etc/debian_version ]; then
        print_warning "警告: 这不是 Debian 系统"
    else
        local debian_version=$(cat /etc/debian_version)
        print_success "检测到 Debian ${debian_version}"
    fi
    
    # 检查权限
    if [ "$EUID" -eq 0 ]; then
        print_warning "当前以 root 用户运行"
    else
        print_info "当前用户: $(whoami)"
    fi
    
    sleep 1.5
}


# 捕获退出信号
cleanup() {
    echo ""
    print_info "程序已中断，正在清理..."
    exit 0
}

trap cleanup INT TERM


# 主程序
main() {
    check_dependencies
    show_welcome
    main_menu
}


# 启动
main
