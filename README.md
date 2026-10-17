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
