#!/usr/bin/env bash
#
# zram-setup.sh — 宿主机 zram 压缩交换一键部署（Debian/Ubuntu LXC 宿主适用）
#
#   sudo bash zram-setup.sh                 # 默认：部署 zram + 调参 + 持久化
#   sudo bash zram-setup.sh --dry-run       # 只打印将要做什么，不改任何东西
#   sudo bash zram-setup.sh --no-sysctl     # 不动全局 vm.* 参数
#   sudo bash zram-setup.sh --no-ksm        # 不开 KSM
#   sudo bash zram-setup.sh --ksm           # 额外开 KSM（默认关）
#   sudo bash zram-setup.sh --size 2G       # 手工指定 zram 容量
#   sudo bash zram-setup.sh --algo lz4      # zstd(默认) / lz4 / lzo-rle
#   sudo bash zram-setup.sh --status        # 只看当前状态
#   sudo bash zram-setup.sh --rollback      # 卸载：关 swap、删配置、恢复 sysctl
#
# 幂等：重复执行安全。会接管已有的手工 zram0。
# 回滚：任何时刻 `--rollback` 可恢复原状（不删已有的 /swapfile）。
#
# 注意：vm.swappiness 等是**整机**参数，共享宿主上会影响所有容器。

set -euo pipefail

# ─────────────── 默认值 ───────────────
ALGO="zstd"
ZRAM_SIZE=""          # 空 = 按内存自动
MEM_LIMIT=""          # 空 = 按内存自动
SWAPPINESS="150"
DO_SYSCTL=1
DO_KSM=0
MODE="install"

SYSCTL_FILE="/etc/sysctl.d/90-zram.conf"
KSM_FILE="/etc/sysctl.d/91-ksm.conf"
GEN_CONF="/etc/systemd/zram-generator.conf"
FB_UNIT="/etc/systemd/system/zram-swap.service"
FB_UP="/usr/local/sbin/zram-swap-up"
FB_DOWN="/usr/local/sbin/zram-swap-down"
BACKUP_DIR="/var/backups/zram-setup"

# ─────────────── 参数解析 ───────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   MODE="dry-run"; shift ;;
    --status)    MODE="status";  shift ;;
    --rollback)  MODE="rollback"; shift ;;
    --algo)      ALGO="$2"; shift 2 ;;
    --size)      ZRAM_SIZE="$2"; shift 2 ;;
    --mem-limit) MEM_LIMIT="$2"; shift 2 ;;
    --swappiness) SWAPPINESS="$2"; shift 2 ;;
    --no-sysctl) DO_SYSCTL=0; shift ;;
    --ksm)       DO_KSM=1; shift ;;
    --no-ksm)    DO_KSM=0; shift ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（--help 看用法）" >&2; exit 1 ;;
  esac
done

DRY=0
if [[ "$MODE" == "dry-run" ]]; then DRY=1; fi

log()  { printf '\033[1;34m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

# dry-run 感知的执行器
run() {
  if (( DRY )); then printf '   [dry-run] %s\n' "$*"; else "$@"; fi
}
# 写文件（dry-run 时只回显）
put() {
  local path="$1"
  if (( DRY )); then
    printf '   [dry-run] 写入 %s:\n' "$path"; sed 's/^/       | /'
  else
    mkdir -p "$(dirname "$path")"
    cat > "$path"; printf '   wrote %s\n' "$path"
  fi
}
putc() { # putc <path> <mode> ; 内容从 stdin（可执行脚本）
  local path="$1" m="${2:-0644}"
  if (( DRY )); then
    printf '   [dry-run] 写入 %s (mode %s):\n' "$path" "$m"; sed 's/^/       | /'
  else
    mkdir -p "$(dirname "$path")"
    cat > "$path"; chmod "$m" "$path"; printf '   wrote %s (mode %s)\n' "$path" "$m"
  fi
}

# ─────────────── 基础检查 ───────────────
[[ $EUID -eq 0 ]] || { err "需要 root 运行"; exit 1; }
command -v systemctl >/dev/null || { err "需要 systemd"; exit 1; }

RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
RAM_MB=$(( RAM_KB / 1024 ))
CORES=$(nproc)

# 自动选型：小内存给 1×RAM，中等 ½，大内存 ¼
if [[ -z "$ZRAM_SIZE" ]]; then
  if   (( RAM_MB <= 2048 )); then ZRAM_SIZE=$(( RAM_MB ))
  elif (( RAM_MB <= 8192 )); then ZRAM_SIZE=$(( RAM_MB / 2 ))
  else                            ZRAM_SIZE=$(( RAM_MB / 4 ))
  fi
fi
[[ "$ZRAM_SIZE" =~ [A-Za-z]$ ]] || ZRAM_SIZE="${ZRAM_SIZE}M"

if [[ -z "$MEM_LIMIT" ]]; then
  ML=$(( RAM_MB / 3 ))
  if (( ML < 256 )); then ML=256; fi
  MEM_LIMIT="${ML}M"
fi

# ─────────────── 状态 / 回滚 ───────────────
show_status() {
  echo "── zram ────────────────────────────────"
  if [[ -r /sys/block/zram0/disksize ]]; then
    printf '  disksize   %s bytes\n' "$(cat /sys/block/zram0/disksize)"
    printf '  algorithm  %s\n' "$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
    if [[ -e /sys/block/zram0/mem_limit ]]; then
      printf '  mem_limit  %s\n' "$(cat /sys/block/zram0/mem_limit 2>/dev/null || echo '不可读')"
    fi
    if [[ -r /sys/block/zram0/mm_stat ]]; then
      awk '{printf "  mm_stat    原始=%dMiB 压缩后=%dMiB 真实占用=%dMiB\n",$1/1048576,$2/1048576,$3/1048576}' /sys/block/zram0/mm_stat
    fi
  else
    echo "  (未启用)"
  fi
  echo "── swap ────────────────────────────────"
  swapon --show 2>/dev/null | sed 's/^/  /' || echo "  (无)"
  echo "── 内存 ────────────────────────────────"
  free -h | sed 's/^/  /'
  echo "── 持久化 ──────────────────────────────"
  [[ -f "$GEN_CONF" ]] && echo "  zram-generator : $GEN_CONF" || echo "  zram-generator : (无)"
  [[ -f "$FB_UNIT"  ]] && echo "  fallback unit  : $FB_UNIT"  || echo "  fallback unit  : (无)"
  systemctl is-enabled zram-swap.service >/dev/null 2>&1 && echo "  zram-swap.service: enabled" || true
  echo "── 调参 ────────────────────────────────"
  grep -Hs . "$SYSCTL_FILE" 2>/dev/null | sed 's/^/  /' || echo "  (无 $SYSCTL_FILE)"
  printf '  live swappiness=%s page-cluster=%s\n' \
    "$(cat /proc/sys/vm/swappiness)" "$(cat /proc/sys/vm/page-cluster)"
  printf '  KSM run=%s\n' "$(cat /sys/kernel/mm/ksm/run 2>/dev/null || echo n/a)"
}

do_rollback() {
  log "回滚：停用 zram 与相关配置"
  run systemctl disable --now zram-swap.service 2>/dev/null || true
  for d in /dev/zram0; do
    if grep -q "^$d " /proc/swaps 2>/dev/null; then
      run swapoff "$d" || true
    fi
  done
  run rm -f "$GEN_CONF" "$FB_UNIT" "$FB_UP" "$FB_DOWN" "$SYSCTL_FILE" "$KSM_FILE"
  run systemctl daemon-reload || true
  (( DRY )) || { sysctl --system >/dev/null 2>&1 || true; }
  ok "已回滚。（原有 /swapfile 未动）"
  echo "提示：/etc/systemd/zram-generator.conf.d/ 下的 drop-in 如有请手动清理"
}

case "$MODE" in
  status)   show_status; exit 0 ;;
  rollback) do_rollback; exit 0 ;;
esac

# ─────────────── 开始 ───────────────
if (( DRY )); then warn "DRY RUN：以下操作不会真正执行"; fi
log "宿主内存 ${RAM_MB} MiB / ${CORES} 核 / 内核 $(uname -r)"
log "zram 容量=${ZRAM_SIZE}  算法=${ALGO}  真实内存上限=${MEM_LIMIT}"
log "swappiness=${SWAPPINESS}$([[ $DO_SYSCTL == 1 ]] || echo ' (不改)')  KSM=$([[ $DO_KSM == 1 ]] && echo on || echo off)"
echo

# 1) 内核支持
log "[1/5] 检查 zram 支持"
if (( ! DRY )); then
  modprobe zram 2>/dev/null || true
  if [[ ! -e /sys/block/zram0 ]]; then
    err "内核没有 zram（/sys/block/zram0 不存在）。可能是容器内运行，或内核未编译该模块。"
    exit 1
  fi
  AVAIL=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "")
  if [[ -n "$AVAIL" ]] && ! grep -qE "\[$ALGO\]|(^| )$ALGO( |$)" <<<"$AVAIL"; then
    warn "算法 $ALGO 不可用，可选：$AVAIL —— 回退 lz4"
    ALGO="lz4"
  fi
  ok "zram 可用，算法 $ALGO"
else
  echo "   [dry-run] modprobe zram / 校验算法"
fi

# 2) 备份现有 sysctl 相关文件
log "[2/5] 备份"
run mkdir -p "$BACKUP_DIR"
(( DRY )) || cp -a /proc/swaps "$BACKUP_DIR/proc-swaps.before" 2>/dev/null || true
(( DRY )) || cp -a /etc/fstab "$BACKUP_DIR/fstab.before" 2>/dev/null || true

# 3) 清理可能存在的旧配置 & 接管正在运行的手工 zram0
log "[3/5] 清理旧配置 / 接管已有 zram0"
run rm -f "$FB_UNIT" "$FB_UP" "$FB_DOWN"
if (( ! DRY )); then
  if grep -q '^/dev/zram0 ' /proc/swaps 2>/dev/null; then
    echo "   检测到 /dev/zram0 已作为 swap 运行，先摘除以便重配"
    swapoff /dev/zram0 || true
  fi
  if [[ -e /sys/block/zram0/reset ]]; then
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true   # 释放已占内存并复位
  fi
else
  echo "   [dry-run] swapoff /dev/zram0; echo 1 > /sys/block/zram0/reset"
fi
run systemctl daemon-reload

# 4) 持久化：优先 zram-generator，否则回退 systemd unit
log "[4/5] 写入持久化配置"
GEN_OK=0
if (( ! DRY )); then
  if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-zram-setup@' \
     || [[ -e /usr/lib/systemd/system-generators/zram-generator ]]; then
    GEN_OK=1
  fi
fi

if (( GEN_OK )); then
  ok "使用 zram-generator（systemd 原生）"
  put "$GEN_CONF" <<EOF
# 由 zram-setup.sh 生成于 $(date -Is)
[zram0]
zram-size = ${ZRAM_SIZE}
compression-algorithm = ${ALGO}
swap-priority = 100
fs-type = swap
EOF
  # mem_limit 不是 zram-generator 的正式键，用 udev/unit 后置设置更稳：
  putc "/usr/local/sbin/zram-mem-limit" 0755 <<EOF
#!/bin/sh
# zram-setup.sh: 给 zram 设置真实内存上限（防止小内存宿主被压缩数据吃满）
if [ -e /sys/block/zram0/mem_limit ]; then echo ${MEM_LIMIT} > /sys/block/zram0/mem_limit; fi
EOF
  putc "/etc/systemd/system/zram-mem-limit.service" 0644 <<'EOF'
[Unit]
Description=Apply mem_limit to zram0
After=systemd-zram-setup@zram0.service
Wants=systemd-zram-setup@zram0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-mem-limit

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl restart systemd-zram-setup@zram0.service
  run systemctl enable --now zram-mem-limit.service
  run systemctl restart zram-mem-limit.service || true
else
  if (( DRY )); then ok "（dry-run 无法探测 zram-generator，按回退方案演示）"; fi
  warn "未检测到 zram-generator → 使用自带 systemd unit 回退方案"
  warn "（想用官方方案：apt install systemd-zram-generator，然后重跑本脚本）"
  putc "$FB_UP" 0755 <<EOF
#!/bin/sh
# zram-setup.sh: 启动 zram-backed swap
set -e
DEV=/dev/zram0
modprobe zram num_devices=1 2>/dev/null || modprobe zram
if grep -q "^\$DEV " /proc/swaps 2>/dev/null; then swapoff "\$DEV"; fi
if [ -e /sys/block/zram0/reset ]; then echo 1 > /sys/block/zram0/reset; fi
echo ${ALGO}  > /sys/block/zram0/comp_algorithm 2>/dev/null || true
echo ${ZRAM_SIZE} > /sys/block/zram0/disksize
if [ -e /sys/block/zram0/mem_limit ]; then echo ${MEM_LIMIT} > /sys/block/zram0/mem_limit; fi
mkswap "\$DEV" >/dev/null
swapon -p 100 "\$DEV"
EOF
  putc "$FB_DOWN" 0755 <<'EOF'
#!/bin/sh
# zram-setup.sh: 停止 zram-backed swap
DEV=/dev/zram0
grep -q "^$DEV " /proc/swaps 2>/dev/null && swapoff "$DEV" || true
if [ -e /sys/block/zram0/reset ]; then echo 1 > /sys/block/zram0/reset; fi
EOF
  putc "$FB_UNIT" 0644 <<'EOF'
[Unit]
Description=zram compressed swap
DefaultDependencies=no
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-swap-up
ExecStop=/usr/local/sbin/zram-swap-down

[Install]
WantedBy=swap.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now zram-swap.service
fi

# 5) sysctl + KSM
if (( DO_SYSCTL )); then
  log "[5/5] 内核内存调参（整机生效）"
  put "$SYSCTL_FILE" <<EOF
# 由 zram-setup.sh 生成于 $(date -Is)
# zram 是内存设备：积极换入更划算
vm.swappiness = ${SWAPPINESS}
# 压缩 swap 的访问是内存操作，关掉块设备的预读
vm.page-cluster = 0
vm.vfs_cache_pressure = 60
EOF
  run sysctl --system >/dev/null 2>&1 || run sysctl -p "$SYSCTL_FILE"
else
  log "[5/5] 跳过 sysctl（--no-sysctl）"
fi

if (( DO_KSM )); then
  log "开启 KSM（页面去重）"
  put "$KSM_FILE" <<EOF
kernel.mm.ksm.run = 1
kernel.mm.ksm.pages_to_scan = 1000
kernel.mm.ksm.sleep_millisecs = 20
EOF
  run sysctl --system >/dev/null 2>&1 || true
  (( DRY )) || echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
fi

# ─────────────── 验证 ───────────────
echo
log "完成，当前状态："
if (( DRY )); then
  echo "   (dry-run，跳过验证)"
else
  show_status
  echo
  ok "新换出的页会优先进入 /dev/zram0（prio 100），满了才落回 /swapfile（prio -2）。"
  echo "   压缩比可稍后回看：  cat /sys/block/zram0/mm_stat"
  echo "   回滚：              sudo bash $0 --rollback"
fi
