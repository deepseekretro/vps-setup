# Debian 12 系统配置工具

两级菜单系统的 Debian 12 服务器配置工具。

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/deepseekretro/vps-setup/main/main.sh)
```

## 使用方式

```bash
# 1. 直接执行主菜单
bash <(curl -fsSL https://raw.githubusercontent.com/deepseekretro/vps-setup/main/main.sh)

# 2. 直接执行某个子菜单（跳过主菜单）
bash <(curl -fsSL https://raw.githubusercontent.com/deepseekretro/vps-setup/main/scripts/security.sh)

# 3. 带环境变量执行
export SSH_PUBKEY="ssh-rsa AAAAB3..."
bash <(curl -fsSL https://raw.githubusercontent.com/deepseekretro/vps-setup/main/main.sh)
```

## 宿主机模块（LXC / 物理宿主）

`zram-setup.sh` 是**宿主机专用**的 zram 压缩交换一键部署脚本（自动调参、内存硬上限、
swapfile 管理、状态查看、回滚），已接入主菜单的 `d. 宿主机 ZRAM 压缩交换`。

```bash
# 在宿主机上直接使用（不要在容器内执行部署/回滚）
sudo bash zram-setup.sh --explain     # 只打印自动调参结果
sudo bash zram-setup.sh --dry-run     # 演练
sudo bash zram-setup.sh               # 部署 / 更新
sudo bash zram-setup.sh --status      # 状态
sudo bash zram-setup.sh --rollback    # 回滚
```

### Hysteria2 节点（`e. Hysteria2 节点`）

`scripts/hysteria2_setup.sh` 一键部署 Hysteria2 服务端：自动拉取官方最新版、生成自签
证书、写入 systemd 服务、放行 UDP 端口（并尝试持久化 iptables 规则），**密码每次随机
生成**，安装完成后打印密码、`hy2://` 导入链接**和终端二维码**（手机客户端扫码即可导入；
二维码依赖 `qrencode`，安装时按需自动补装，也可用 `--no-qr` 关闭）。

```bash
# 在宿主机上直接使用（不要在容器内安装/卸载）
sudo bash scripts/hysteria2_setup.sh              # 交互菜单
sudo bash scripts/hysteria2_setup.sh --install    # 安装/重装（随机密码）
sudo bash scripts/hysteria2_setup.sh --dry-run --install   # 演练，不写系统
sudo bash scripts/hysteria2_setup.sh --info       # 查看密码与导入链接
sudo bash scripts/hysteria2_setup.sh --status     # 运行状态
sudo bash scripts/hysteria2_setup.sh --uninstall  # 卸载

# 可选：--port 443 --domain bing.com --mask-url https://bing.com/ --no-qr（不显示二维码） \
#       --new-password（强制换随机密码） --keep-password（沿用旧密码）
```
