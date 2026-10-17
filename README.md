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

### VNC 桌面环境（`f. VNC 桌面环境`）

`scripts/vnc_desktop_setup.sh` 一键搭建 Debian 12 的 VNC 远程桌面（Systemd 级联服务版）：
Xvfb + LXDE + x11vnc + websockify/noVNC + OpenResty(HTTPS)，可选 Wine / Edge / MT5
自愈守护 / Gost 隧道。各组件由独立 systemd 单元托管（`BindsTo` 强绑定、崩溃自动重启）。

**桌面运行用户不再在进入模块时询问**，改由 `[1] 初始化系统环境` 和 `[2] 安装 LXDE 桌面核心`
各自设置（两处都能改），并按需幂等创建该用户（补 sudo 组、家目录、`.vnc`/Desktop 目录、
`enable-linger`）；其余步骤（Wine/Edge/HTTPS/服务单元等）沿用最近一次设置的用户，
Xvfb / x11vnc / MT5 等单元都会以该用户身份运行。

```bash
# 可以在 LXC 容器内运行（推荐），也可以在物理机/独立 VPS 上运行
sudo bash scripts/vnc_desktop_setup.sh
```

**容器适配**：Linux 的 swap 不参与命名空间隔离，容器内 `swapon` 会直接改写**宿主内核**的
swap（LXC 里 `/swapfile` 还指向宿主磁盘上的文件）。因此脚本会先检测容器环境
（`systemd-detect-virt` / `/run/systemd/container` / `/proc/1/environ` 的 `container=` 等），
命中即**跳过 swapfile 的创建与启用**，交由宿主机统一管理；非容器环境才会创建 swap。
另外脚本会检查 `/proc/swaps`，绝不覆盖正在使用的 swap 文件。

**桌面加固（屏蔽注销/关机/屏幕锁）**：装完 LXDE 会自动执行（也可随时用菜单
`[10] 屏蔽桌面「注销/关机/屏幕锁」`，或 `bash scripts/vnc_desktop_setup.sh --harden` 补做），幂等：

- lxpanel 面板：移除右下角「屏幕锁 / 注销」按钮与主菜单里的注销项（写入**用户级**
  `~/.config/lxpanel/LXDE/panels/panel`，不改包自带文件，升级不会被覆盖）
- `lxde-logout` / `lxsession-logout` / `lxlock` / `light-locker` / `xscreensaver`
  经 `dpkg-divert` 备份为同名 `.real` 后替换为空操作 → **点击毫无反应**
- 用户级隐藏 `lxde-logout` / `lxde-screenlock` 桌面条目；`@xset s off -dpms s noblank` 防息屏
- 恢复注销功能：`dpkg-divert --remove /usr/bin/lxde-logout`（`.real` 是原程序），
  并删除用户级 panel 配置后重启 `vnc-desktop@1`

**精简安装**：所有 apt 安装均带 `--no-install-recommends`（避免推荐包带进
zenity / libwebkit2gtk / ghostscript / imagemagick / gstreamer / mesa-vulkan 等数百 MiB），
中文字体只装体积更小的 `fonts-wqy-microhei`；Wine / Edge / Gost 保持独立菜单可选项，按需安装。
另有少数被上游列为 Recommends 但本方案实际需要的 `xauth` / `x11-utils` / `fontconfig`
已显式列进依赖清单（合计约 1.4 MiB），不会因关闭推荐而缺件。
（本次改造前，`zenity` 作为 `im-config` / `fcitx-ui-classic` 的推荐包被装入，连带
`libwebkit2gtk`(90 MiB) / `libjavascriptcoregtk`(31 MiB) / `libflite1`(27 MiB) /
gstreamer 插件链 —— 同一批依赖在旧安装里实测约 300 MiB。）
