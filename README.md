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

**HTTPS / noVNC 是增量配置，不会覆盖你已有的 nginx**（菜单 `[5]`）：
旧实现是 `cat > /etc/openresty/nginx.conf` 整份覆盖，会把你自己配的 server / upstream /
其它站点（例如 web terminal、反代、basic auth）一起抹掉。现在只做三件事：

- **站点本体单独放**：`/usr/local/openresty/nginx/conf/conf.d/50-novnc.conf`
  （脚本自有的 `server {}` 块，可反复覆盖）。想卸载 noVNC：删掉这个文件 + 重载即可。
- **你的 `nginx.conf` 能不动就不动**：只有它内部没有任何会加载到该目录的 `include` 时，
  才补插 2 行（一行带标记的注释 + 一行 `include <conf.d>/*.conf;`），插前自动备份到
  `nginx.conf.vps-setup.bak`。
- **端口自动避让**：优先 `443`；若该端口已被你别的 `server` 块占用（例如已有 443 站点），
  noVNC 自动改用 `8443`，之后再跑会一直沿用（不会每次跳）。用了非 443 端口时，
  记得在防火墙 / 端口转发里放行，例如 `https://IP:8443/vnc1`。
- **老版本留下的「内联」配置会自动搬家**：早期版本把 noVNC 的 `server {}` 写在
  `nginx.conf` 里，重跑时会按花括号把它整块摘出来放进 `conf.d`（只动含 noVNC 签名那一块，
  你在同一个文件里另加的 `server` 块原样保留），因此访问地址不变。
- **改完先校验再加载**：先 `nginx -t`，通过后用 `-s reload` 平滑加载（不中断现有连接）；
  校验失败会自动把本次写入回滚（恢复主配置备份、删掉新写的 drop-in），**绝不会让你的站点起不来**。
- 小知识：nginx 的**相对** `include` 是按「配置文件所在目录」解析的（不是 `--prefix`），
  所以 `include conf.d/*.conf;` 指的就是 `nginx.conf` 旁边的 `conf.d/`。
- 想让 noVNC 和现有站点共用 **443**（不额外开端口）：在你已有的 443 `server {}` 里加一行
  `include <conf.d>/novnc-proxy.inc;`，文件内容见下文附录。

**把 noVNC 挂到已有站点的 443 下（可选，附录）**：先让 `[5]` 把 noVNC 装到 `8443`
（它会自动这么做），再新建 `/usr/local/openresty/nginx/conf/conf.d/novnc-proxy.inc`，
并在你已有 443 `server {}` 里加一行 `include …/conf.d/novnc-proxy.inc;`：

```nginx
# 由 vps-setup 生成：把 noVNC（本机 8443）挂到现有 443 站点的 /novnc/ 下
location = /vnc1 { return 302 /novnc/vnc.html?path=novnc/websockify/1&autoconnect=true&reconnect=true; }
location = /vnc2 { return 302 /novnc/vnc.html?path=novnc/websockify/2&autoconnect=true&reconnect=true; }
location = /vnc3 { return 302 /novnc/vnc.html?path=novnc/websockify/3&autoconnect=true&reconnect=true; }
location = /view { return 302 /novnc/vnc.html?path=novnc/websockify/3&view_only=true&autoconnect=true; }
location ^~ /novnc/websockify/1 { proxy_pass http://127.0.0.1:6081/; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "Upgrade"; proxy_buffering off; proxy_read_timeout 86400s; auth_basic off; }
location ^~ /novnc/websockify/2 { proxy_pass http://127.0.0.1:6082/; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "Upgrade"; proxy_buffering off; proxy_read_timeout 86400s; auth_basic off; }
location ^~ /novnc/websockify/3 { proxy_pass http://127.0.0.1:6083/; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "Upgrade"; proxy_buffering off; proxy_read_timeout 86400s; auth_basic off; }
location ^~ /novnc/ { proxy_pass https://127.0.0.1:8443/; proxy_ssl_verify off; proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header X-Forwarded-Proto $scheme; auth_basic off; }
```

之后访问 `https://IP/vnc1` 即可（`auth_basic off;` 表示只由 VNC 自己的密码把关；
想去掉这些行就变成「站点密码 + VNC 密码」双重保护）。两个坑已踩过：
文件名故意用 `.inc` 而不是 `.conf`（否则会被 `include conf.d/*.conf;` 在 `http` 层重复加载而报错）；
`path=` 必须写成 **`novnc/websockify/N`** 而不是 `websockify/N` —— noVNC 的 path 是从根拼起的
（`app/ui.js: url += '/' + path`），而 WebSocket 通道挂在 `/novnc/` 子路径下。
实测：443 上 `/vnc1` → 302、页面与静态资源 200、`Sec-WebSocket` 握手返回 **101**。

**精简安装**：所有 apt 安装均带 `--no-install-recommends`（避免推荐包带进
zenity / libwebkit2gtk / ghostscript / imagemagick / gstreamer / mesa-vulkan 等数百 MiB），
中文字体只装体积更小的 `fonts-wqy-microhei`；Wine / Edge / Gost 保持独立菜单可选项，按需安装。
另有少数被上游列为 Recommends 但本方案实际需要的 `xauth` / `x11-utils` / `fontconfig`
已显式列进依赖清单（合计约 1.4 MiB），不会因关闭推荐而缺件。
（本次改造前，`zenity` 作为 `im-config` / `fcitx-ui-classic` 的推荐包被装入，连带
`libwebkit2gtk`(90 MiB) / `libjavascriptcoregtk`(31 MiB) / `libflite1`(27 MiB) /
gstreamer 插件链 —— 同一批依赖在旧安装里实测约 300 MiB。）

**省磁盘：`[12] 清理安装缓存与日志`**（`[6]` 安装激活流水线的收尾也会自动跑一次）：

- 清空 `/var/lib/apt/lists` —— 装完实测 85 MiB（下次 `apt update` 会自动重下）。
  脚本内的补装逻辑（`ensure_pkgs`）会先看索引是否还在，被清掉时会自动补一次
  `apt update`，所以不会出现"清完缓存就装不上包"。
- 给 journald 设上限 `SystemMaxUse=64M`（写 `/etc/systemd/journald.conf.d/99-vps-setup.conf`），
  避免默认的"最多可吃磁盘 10%"（9.8G 盘 ≈ 近 1 GiB）被日志占掉；并顺手 vacuum 一次。
  两个动作都是幂等的，重复执行只会提示"已是 64M / 释放约 0 MiB"。

**同样的功能，更少的重复**（本轮去重）：

- `lxde-core` 的硬依赖已包含 `lxpanel` / `pcmanfm` / `openbox`（连带 `lxde-common` /
  `lxsession` / `openbox-lxde-session`），故安装列表收敛为
  `lxde-core lxterminal lxappearance lxde-icon-theme`，不再重复列依赖名。
- 删掉已无调用者的 `verify_user_password()`；`[6]` 路径里 `install_res_watch_units`
  只调用一次（原来 `install_systemd_pipeline_units` 和 `activate_pipeline_services` 各调一遍，
  等于把同一批单元文件写两遍再 reload 两次）。
- `dbus-x11`、`haveged gnupg2 ca-certificates lsb-release`、`wmctrl xdotool` 不再重复
  apt 安装：改用 `ensure_pkgs` 只补"确实缺失"的包，因此 `[7]` 里那次纯等待的
  `apt update` 也一并去掉（1 核机器上能省十几秒）。
- 会话自启动那 6 行（面板 / 桌面图标 / 剪贴板×2 / 输入法 / 防息屏）统一由
  `ensure_session_autostart` 幂等维护，不再在加固步骤和流水线步骤里各写一遍；
  noVNC 补丁函数也不再顺手去调 `silence_desktop_bins`（职责错位）。

## Web Terminal 网页终端（`g. Web Terminal 网页终端`）

`scripts/webterm_setup.sh` 把「浏览器里的多标签终端」做成一键模块：后端是一个
Python `asyncio` 的 PTY ⇄ WebSocket 桥（`/var/www/web-terminal/app.py`，只监听
`127.0.0.1:9000`），前端是 xterm.js 多标签界面，外面套一层 OpenResty/Nginx
反向代理 + 整站 basic auth。**可以在 LXC 容器内运行**（VPS 上很常见）。

```bash
sudo bash scripts/webterm_setup.sh                 # 交互菜单
sudo bash scripts/webterm_setup.sh --install       # 安装 / 更新
sudo bash scripts/webterm_setup.sh --status        # 状态（只读，不改配置）
sudo bash scripts/webterm_setup.sh --reset-password
```

安装内容与落盘位置：

| 位置 | 说明 |
| --- | --- |
| `/var/www/web-terminal/app.py`、`static/` | 后端 + 前端（来自仓库 `assets/web-terminal/`） |
| `/etc/systemd/system/webterminal.service` | 后端服务（`Restart=on-failure`，`TERM_PORT` 记在单元里） |
| `<conf>/conf.d/10-webterm.conf` | **脚本自有**的站点（http + https 两个 `server`，可反复覆盖） |
| `<conf>/webterm-server.inc` | 站点本体，被上面两个 `server` 一起 `include` |
| `<conf>/htpasswd` | basic auth 用户文件（已存在则沿用你的） |
| `/root/.webterm-credentials` | 明文访问密码记录（`600`，**绝不进仓库**），菜单 `[2]/[3]` 读写 |

**和 noVNC 模块同一套「增量」原则，绝不覆盖你已有的 nginx**：

- **只写自己的两个文件**：`conf.d/10-webterm.conf` 与 `webterm-server.inc`；
  你的 `nginx.conf` 只在「内部完全没有会加载到 `conf.d` 的 `include`」时才补插 1 行
  带标记的 `include <conf.d>/*.conf;`（插前备份到 `nginx.conf.vps-setup-webterm.bak`）。
- **检测到你已经手写过 Web Terminal 站点就不动 nginx**：判据是「某个配置文件里同时有
  `proxy_pass …127.0.0.1:<后端端口>` 和 `/ws`（或 webterm 字样）」。此时只更新
  应用 / 服务 / 密码，配置一个字都不改，并打印命中的文件。
- **靠标记区分「谁的文件」，不靠文件名**：脚本生成的文件都带
  `# Managed by vps-setup (webterm_setup.sh)` 注释；你手写的站点即使**恰好也叫
  `webterm-server.inc`** 也不会被当成脚本的文件，更不会被覆盖 —— 真有同名且非脚本生成
  的文件时，脚本会自动改用 `webterm-server.vps-setup.inc`。
- **端口自动避让**：http 优先 `80`（被占则 `8080/8000/8888/9080`），https 优先 `443`
  （被占则 `8443/9443/10443/12443`）；已装过就沿用 drop-in 里的端口，不会每次跳。
- **先 `nginx -t` 再加载**：通过后 `-s reload` 平滑加载；失败自动回滚（删/恢复 drop-in、
  恢复主配置备份），**绝不会让你的站点起不来**。
- **不改你已有的密码**：`htpasswd` 里已有同名用户、而脚本记录里没有明文密码时，保持原样
  并提示「明文未记录，可到 `[3]` 重设」；只有真的没有才随机生成 14 位密码并打印。
  重跑本模块也不会改密码（会按 salt 重新哈希核对一遍）。

访问：装完打印 `https://IP/`（自签证书需点一次「继续访问」）。后端以 **root** 身份
开 shell，所以整站强制 basic auth + HTTPS；容器里要外部访问请自行在宿主做端口转发。

前端资源 xterm.js / xterm-addon-fit 为 MIT 许可（随仓库 `assets/web-terminal/static/vendor/`
一起分发，无需联网 CDN）。卸载用菜单 `[4]`：停用并删除服务单元、删掉两个脚本自有配置文件、
删掉应用目录与密码记录 —— **不碰你的 `nginx.conf` 和其它站点**。
