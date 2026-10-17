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

**桌面用户 + 密码：全程只设置一次**，记录在 root 私有的 `/root/.vnc-desktop-credentials`
（`600`，不进仓库）：

- 首次运行 `[1] 初始化系统环境` 或 `[2] 安装 LXDE 桌面核心`：询问一次用户名
  （默认 `vncuser1`）→ 建账户 → 设一次密码 → 写入凭据文件
- 之后再跑任何步骤：只要凭据文件里的用户存在且密码可用，就**直接跳过、不再询问**
- 历史安装（账户已存在、明文没记录过）不会被强迫改密码，只提示「未记录」；
  需要展示时到菜单 `[11]` 重设一次即可

**两个密码不是一回事**（很容易搞混）：

| 密码 | 何时设置 | 存放 | 用途 |
|---|---|---|---|
| Linux 账户密码（桌面用户） | 首次配置时设一次（`chpasswd`） | `/etc/shadow`（明文另记于凭据文件） | `sudo`、`su` 认证 |
| VNC 连接密码 | 首次执行 `[6]` 时设一次（`x11vnc -storepasswd`） | `~/.vnc/passwd`（明文另记于凭据文件） | noVNC 网页里输入，**上限 8 位** |

**查看 / 重设账号密码**：菜单 `[11] 查看 / 重设 桌面与 VNC 账号密码`，或
`bash scripts/vnc_desktop_setup.sh --show-credentials`。会打印桌面运行用户 + 密码、
VNC 连接用户 + 密码，并实时核对（`passwd -S` 密码是否真的可用、`~/.vnc/passwd`
是否存在），可当场重设两者。注意 x11vnc 只认证密码、**没有独立的 VNC 用户名**，
所以「VNC 连接用户」就是跑桌面的那个账号。

`adduser --disabled-password` 建出来的账户在 `/etc/shadow` 里是 `!`（锁定、无密码），
此时**该用户永远无法使用 sudo**（输 VNC 连接密码也没用）。因此脚本会回读校验
（`passwd -S` 第二列须为 `P`），发现没有可用密码才提示补设一次（不会像以前那样
"已存在就整段跳过"而把坑静默掉）。事后也可用菜单 `[11]` 或 `passwd <用户名>` 修改。

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
- 关闭 polkit 认证代理 `lxpolkit`（用户级 `~/.config/lxsession/LXDE/desktop.conf` 里
  `polkit/command=` 置空）。原因：本桌面跑在 systemd 系统服务 `vnc-desktop@N.service` 里、
  不是 logind 登录会话，而 lxpolkit 启动时会查「自己属于哪个会话」，必然失败并把
  `No session for pid <PID>` 这个错误**弹成一个标题为「错误」的对话框**（每次切分辨率 /
  重启桌面都会弹一次，PID 每次都不同）。本桌面没有任何需要 polkit 授权的操作，
  直接关掉最干净；也不建议改成给服务加 `PAMName=login` 去"真修"——那会让桌面被 polkit
  视为本地活动会话，logind 的关机/重启等 `allow_active` 动作会变成**免密**执行。
- 恢复注销功能：`dpkg-divert --remove /usr/bin/lxde-logout`（`.real` 是原程序），
  并删除用户级 panel 配置后重启 `vnc-desktop@1`

**分辨率热切换（免 root）**：桌面上的 `切换分辨率(Systemd版).sh` 只改写用户自己的
`~/.vnc/display-1.conf`，再由 systemd 路径单元 `vnc-res-watch.path` 监听到变化后触发
`vnc-res-apply@1.service`（root）重启 `xvfb@1`；**普通桌面用户双击即可生效，无需 sudo/密码**
（旧实现是 `sudo bash "$0"`，在无密码桌面用户、或 setuid 位丢失的容器里会直接失败，
表现就是"双击/在终端里跑都没反应"）。双击选择「执行」（无终端）时脚本会自动用 `lxterminal`
重新拉起自己来显示菜单；`[6] 安装并激活流水线` 会自动安装并启用该 path 单元，
也可用 `bash scripts/vnc_desktop_setup.sh --res-tool [用户名]` 单独刷新。
注意：切换分辨率本质是重启 Xvfb，桌面会话会短暂重启，刷新 noVNC 网页即可。

**精简安装**：所有 apt 安装均带 `--no-install-recommends`（避免推荐包带进
zenity / libwebkit2gtk / ghostscript / imagemagick / gstreamer / mesa-vulkan 等数百 MiB），
中文字体只装体积更小的 `fonts-wqy-microhei`；Wine / Edge / Gost 保持独立菜单可选项，按需安装。
另有少数被上游列为 Recommends 但本方案实际需要的 `xauth` / `x11-utils` / `fontconfig`
已显式列进依赖清单（合计约 1.4 MiB），不会因关闭推荐而缺件。
（本次改造前，`zenity` 作为 `im-config` / `fcitx-ui-classic` 的推荐包被装入，连带
`libwebkit2gtk`(90 MiB) / `libjavascriptcoregtk`(31 MiB) / `libflite1`(27 MiB) /
gstreamer 插件链 —— 同一批依赖在旧安装里实测约 300 MiB。）
