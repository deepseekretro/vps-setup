#!/usr/bin/env bash
#
# zram-setup.sh — 宿主机 zram 压缩交换一键部署（按内存自动调参）
#
#   sudo bash zram-setup.sh                # 自动调参并部署
#   sudo bash zram-setup.sh --explain      # 只打印自动调参结果，不做任何改动
#   sudo bash zram-setup.sh --dry-run      # 打印将要执行的操作
#   sudo bash zram-setup.sh --status       # 查看当前状态
#   sudo bash zram-setup.sh --rollback     # 卸载并恢复
#
# 覆盖自动值（一般不需要）：
#   --size 2G                  zram 容量
#   --mem-limit 512M           zram 真实内存硬上限
#   --algo zstd|lz4            压缩算法（默认按 CPU 核数 + 内存自动）
#   --swappiness N             （默认自动）
#   --swapfile auto|off|SIZE   磁盘 swapfile（默认 auto）
#   --resize-swapfile          允许调整已存在的 swapfile 大小（需内存预检）
#   --ratio 3.0                zram 压缩比估算值，仅用于打印有效内存
#   --no-sysctl                不改全局 vm.*
#   --ksm / --no-ksm           页面去重（默认关）
#
# 幂等；--rollback 可恢复。注意 vm.* 为整机参数，共享宿主上会影响所有容器。

set -euo pipefail

# ─────────────── 默认值 ───────────────
ALGO=""                 # 空 = 自动
ZRAM_SIZE=""            # 空 = 自动
MEM_LIMIT=""            # 空 = 自动
SWAPPINESS=""           # 空 = 自动
SWAPFILE="auto"         # auto | off | <SIZE>
RESIZE_SWAPFILE=0
RATIO="3.0"
DO_SYSCTL=1
DO_KSM=0
MODE="install"

SWAPFILE_PATH="/swapfile"
SWAPFILE_PRIO=10
ZRAM_PRIO=100

SYSCTL_FILE="/etc/sysctl.d/90-zram.conf"
KSM_FILE="/etc/sysctl.d/91-ksm.conf"
GEN_CONF="/etc/systemd/zram-generator.conf"
FB_UNIT="/etc/systemd/system/zram-swap.service"
FB_UP="/usr/local/sbin/zram-swap-up"
FB_DOWN="/usr/local/sbin/zram-swap-down"
ML_SCRIPT="/usr/local/sbin/zram-mem-limit"
ML_UNIT="/etc/systemd/system/zram-mem-limit.service"
STATE_DIR="/var/lib/zram-setup"
BACKUP_DIR="/var/backups/zram-setup"

# ─────────────── 参数解析 ───────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         MODE="dry-run"; shift ;;
    --explain)         MODE="explain"; shift ;;
    --status)          MODE="status";  shift ;;
    --rollback)        MODE="rollback"; shift ;;
    --algo)            ALGO="$2"; shift 2 ;;
    --size)            ZRAM_SIZE="$2"; shift 2 ;;
    --mem-limit)       MEM_LIMIT="$2"; shift 2 ;;
    --swappiness)      SWAPPINESS="$2"; shift 2 ;;
    --swapfile)        SWAPFILE="$2"; shift 2 ;;
    --resize-swapfile) RESIZE_SWAPFILE=1; shift ;;
    --ratio)           RATIO="$2"; shift 2 ;;
    --no-sysctl)       DO_SYSCTL=0; shift ;;
    --ksm)             DO_KSM=1; shift ;;
    --no-ksm)          DO_KSM=0; shift ;;
    -h|--help)         sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（--help 看用法）" >&2; exit 1 ;;
  esac
done

DRY=0
if [[ "$MODE" == "dry-run" ]]; then DRY=1; fi

log()  { printf '\033[1;34m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

run() {
  if (( DRY )); then printf '   [dry-run] %s\n' "$*"; else "$@"; fi
}
put() { # 内容从 stdin 写文件
  local path="$1"
  if (( DRY )); then
    printf '   [dry-run] 写入 %s:\n' "$path"; sed 's/^/       | /'
  else
    mkdir -p "$(dirname "$path")"; cat > "$path"; printf '   wrote %s\n' "$path"
  fi
}
putc() { # putc <path> <mode> ; 内容从 stdin（可执行脚本）
  local path="$1" m="${2:-0644}"
  if (( DRY )); then
    printf '   [dry-run] 写入 %s (mode %s):\n' "$path" "$m"; sed 's/^/       | /'
  else
    mkdir -p "$(dirname "$path")"; cat > "$path"; chmod "$m" "$path"
    printf '   wrote %s (mode %s)\n' "$path" "$m"
  fi
}
to_mib() { # "2G" -> 2048 ; "512M" -> 512 ; "1500" -> 1500
  local v="$1"
  case "$v" in
    *[Gg]) echo $(( ${v%[Gg]} * 1024 ));;
    *[Mm]) echo $(( ${v%[Mm]} ));;
    *)     echo $(( v ));;
  esac
}

swapfile_create() { # swapfile_create <MiB>
  local mb="$1"
  if (( DRY )); then
    printf '   [dry-run] fallocate %sM %s ; mkswap ; swapon -p %s\n' "$mb" "$SWAPFILE_PATH" "$SWAPFILE_PRIO"
    return 0
  fi
  fallocate -l "${mb}M" "$SWAPFILE_PATH" 2>/dev/null \
    || dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count="$mb" status=none
  chmod 600 "$SWAPFILE_PATH"
  mkswap "$SWAPFILE_PATH" >/dev/null
  swapon -p "$SWAPFILE_PRIO" "$SWAPFILE_PATH"
}

[[ $EUID -eq 0 ]] || { err "需要 root 运行"; exit 1; }
command -v systemctl >/dev/null || { err "需要 systemd"; exit 1; }

# ═══════════════ 自动调参模型 ═══════════════
RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
RAM_MB=$(( RAM_KB / 1024 ))
CORES=$(nproc)
DISK_FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')

# 档位表：ZM=zram 容量倍数(千分比)，SF=swapfile(MiB)，SW=swappiness，VP=vfs_cache_pressure
# 原则：内存越小 → zram 相对越大、swappiness 越高；内存越大 → 越保守
if   (( RAM_MB <= 512 ));   then ZM=2000; SF=1024; SW=180; VP=100
elif (( RAM_MB <= 1024 ));  then ZM=2000; SF=1024; SW=180; VP=100
elif (( RAM_MB <= 2048 ));  then ZM=1500; SF=2048; SW=150; VP=80
elif (( RAM_MB <= 4096 ));  then ZM=1000; SF=2048; SW=120; VP=60
elif (( RAM_MB <= 8192 ));  then ZM=500;  SF=4096; SW=80;  VP=50
elif (( RAM_MB <= 16384 )); then ZM=250;  SF=4096; SW=60;  VP=50
else                             ZM=250;  SF=0;    SW=30;  VP=50
fi

# zram 容量
AUTO_ZRAM_MB=$(( RAM_MB * ZM / 1000 ))
if (( AUTO_ZRAM_MB < 64 )); then AUTO_ZRAM_MB=64; fi

# zram 真实内存硬上限：默认 RAM/3（下限 64M，极小内存不超过 RAM/2）
AUTO_ML_MB=$(( RAM_MB / 3 ))
if (( AUTO_ML_MB < 64 )); then AUTO_ML_MB=64; fi
if (( RAM_MB < 512 && AUTO_ML_MB > RAM_MB / 2 )); then AUTO_ML_MB=$(( RAM_MB / 2 )); fi

# 压缩算法：CPU 少但内存充足 → lz4（省 CPU）；否则 → zstd（省内存）
AUTO_ALGO="zstd"
if (( CORES <= 2 && RAM_MB >= 4096 )); then AUTO_ALGO="lz4"; fi

# swapfile 受磁盘剩余空间约束（最多占一半剩余空间，不足 256M 就不建）
if (( SF > 0 )); then
  MAX_SF=$(( DISK_FREE_MB / 2 ))
  if (( SF > MAX_SF )); then SF=$MAX_SF; fi
  if (( SF < 256 )); then SF=0; fi
fi

# KSM 扫描参数按核数
KSM_SCAN=$(( CORES * 500 ))
if (( KSM_SCAN < 1000 )); then KSM_SCAN=1000; fi

# 应用用户覆盖
FINAL_ZRAM_MB=${ZRAM_SIZE:+$(to_mib "$ZRAM_SIZE")}; FINAL_ZRAM_MB=${FINAL_ZRAM_MB:-$AUTO_ZRAM_MB}
FINAL_ML_MB=${MEM_LIMIT:+$(to_mib "$MEM_LIMIT")};   FINAL_ML_MB=${FINAL_ML_MB:-$AUTO_ML_MB}
FINAL_ALGO=${ALGO:-$AUTO_ALGO}
FINAL_SW=${SWAPPINESS:-$SW}
case "$SWAPFILE" in
  off|none|no) FINAL_SF=0 ;;
  auto)        FINAL_SF=$SF ;;
  *)           FINAL_SF=$(to_mib "$SWAPFILE") ;;
esac

print_plan() {
  local eff=$(( RAM_MB + FINAL_ZRAM_MB / ${RATIO%.*} ))
  cat <<EOF
────────────────── 自动调参结果 ──────────────────
  硬件        内存 ${RAM_MB} MiB · CPU ${CORES} 核 · 根分区剩余 ${DISK_FREE_MB} MiB

  zram 容量      ${FINAL_ZRAM_MB} MiB   (${ZM}‰ × RAM)
  zram 算法      ${FINAL_ALGO}
  zram 内存上限   ${FINAL_ML_MB} MiB   (压缩数据最多占这么多真实内存)
  zram 优先级     ${ZRAM_PRIO}

  swapfile       ${FINAL_SF} MiB   (${SWAPFILE_PATH}, 优先级 ${SWAPFILE_PRIO})
  swappiness     ${FINAL_SW}
  vfs_cache_pressure ${VP}
  page-cluster   0
  KSM            $([[ $DO_KSM == 1 ]] && echo "开 (pages_to_scan=${KSM_SCAN}, sleep=20ms)" || echo "关")

  总虚拟内存     ≈ $(( RAM_MB + FINAL_ZRAM_MB + FINAL_SF )) MiB
  估算有效可用   ≈ ${eff} MiB   (RAM + zram ÷ ${RATIO})
──────────────────────────────────────────────────
EOF
}

# ═══════════════ 状态 / 回滚 ═══════════════
show_status() {
  echo "── zram ────────────────────────────────"
  if [[ -e /sys/block/zram0/disksize ]]; then
    printf '  disksize   %s MiB\n' "$(($(cat /sys/block/zram0/disksize)/1048576))"
    printf '  algorithm  %s\n' "$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
    if [[ -e /sys/block/zram0/mem_limit ]]; then
      printf '  mem_limit  %s MiB\n' "$(($(cat /sys/block/zram0/mem_limit 2>/dev/null || echo 0)/1048576))"
    fi
    if [[ -r /sys/block/zram0/mm_stat ]]; then
      awk '{printf "  mm_stat    原始=%dMiB 压缩后=%dMiB 真实占用=%dMiB 压缩比≈%.2f\n",$1/1048576,$2/1048576,$3/1048576,($2>0?$1/$2:0)}' /sys/block/zram0/mm_stat
    fi
  else
    echo "  (未启用)"
  fi
  echo "── swap ────────────────────────────────"
  swapon --show 2>/dev/null | sed 's/^/  /' || echo "  (无)"
  echo "── 内存 ────────────────────────────────"
  free -h | sed 's/^/  /'
  echo "── 持久化 ──────────────────────────────"
  [[ -f "$GEN_CONF" ]] && echo "  zram-generator  : $GEN_CONF" || echo "  zram-generator  : (无)"
  [[ -f "$FB_UNIT"  ]] && echo "  fallback unit   : $FB_UNIT"  || echo "  fallback unit   : (无)"
  [[ -f "$ML_UNIT"  ]] && echo "  mem-limit unit  : $ML_UNIT"  || echo "  mem-limit unit  : (无)"
  grep -q "$SWAPFILE_PATH" /etc/fstab 2>/dev/null && echo "  fstab           : $(grep "$SWAPFILE_PATH" /etc/fstab)" || echo "  fstab           : (无 $SWAPFILE_PATH)"
  echo "── 调参 ────────────────────────────────"
  grep -Hs . "$SYSCTL_FILE" 2>/dev/null | sed 's/^/  /' || echo "  (无 $SYSCTL_FILE)"
  printf '  live  swappiness=%s page-cluster=%s vfs_cache_pressure=%s\n' \
    "$(cat /proc/sys/vm/swappiness)" "$(cat /proc/sys/vm/page-cluster)" "$(cat /proc/sys/vm/vfs_cache_pressure)"
  printf '  KSM   run=%s\n' "$(cat /sys/kernel/mm/ksm/run 2>/dev/null || echo n/a)"
}

do_rollback() {
  log "回滚"
  run systemctl disable --now zram-swap.service 2>/dev/null || true
  run systemctl disable --now zram-mem-limit.service 2>/dev/null || true
  if grep -q '^/dev/zram0 ' /proc/swaps 2>/dev/null; then run swapoff /dev/zram0 || true; fi

  # 只清理我们自己创建的 swapfile
  if [[ -f "$STATE_DIR/created-swapfile" ]]; then
    warn "移除本脚本创建的 swapfile: $SWAPFILE_PATH"
    if grep -q '^'"$SWAPFILE_PATH"' ' /proc/swaps 2>/dev/null; then run swapoff "$SWAPFILE_PATH" || true; fi
    run rm -f "$SWAPFILE_PATH"
    if (( ! DRY )); then sed -i "\|^${SWAPFILE_PATH} |d" /etc/fstab; fi
    run rm -f "$STATE_DIR/created-swapfile"
  fi

  run rm -f "$GEN_CONF" "$FB_UNIT" "$FB_UP" "$FB_DOWN" "$ML_SCRIPT" "$ML_UNIT" "$SYSCTL_FILE" "$KSM_FILE"
  run systemctl daemon-reload || true
  (( DRY )) || { sysctl --system >/dev/null 2>&1 || true; }
  ok "已回滚（原有 swap 设备未动）"
}

case "$MODE" in
  status)   show_status; exit 0 ;;
  rollback) do_rollback; exit 0 ;;
  explain)  print_plan; exit 0 ;;
esac

# ═══════════════ 开始 ═══════════════
if (( DRY )); then warn "DRY RUN：以下操作不会真正执行"; fi
print_plan
echo

# 1) 内核支持
log "[1/6] 检查 zram 支持"
if (( ! DRY )); then
  modprobe zram 2>/dev/null || true
  if [[ ! -e /sys/block/zram0 ]]; then
    err "内核无 zram（/sys/block/zram0 不存在）—— 是否在容器内运行？"
    exit 1
  fi
  AVAIL=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "")
  if [[ -n "$AVAIL" ]] && ! grep -qE "\[$FINAL_ALGO\]|(^| )$FINAL_ALGO( |$)" <<<"$AVAIL"; then
    warn "算法 $FINAL_ALGO 不可用（可选：$AVAIL），回退 lz4"
    FINAL_ALGO="lz4"
  fi
  ok "zram 可用，算法 $FINAL_ALGO"
else
  echo "   [dry-run] modprobe zram / 校验算法"
fi

# 2) 备份
log "[2/6] 备份"
run mkdir -p "$BACKUP_DIR" "$STATE_DIR"
(( DRY )) || { cp -a /proc/swaps "$BACKUP_DIR/proc-swaps.before" 2>/dev/null || true
               cp -a /etc/fstab   "$BACKUP_DIR/fstab.before"      2>/dev/null || true; }

# 3) 磁盘 swapfile
log "[3/6] 磁盘 swapfile"
NONZRAM_SWAP=$(swapon --show=NAME,TYPE --noheadings 2>/dev/null | awk '$1 !~ /^\/dev\/zram/{print $1}' || true)

# 3a) 已有非 zram swap（分区或别的文件）
if [[ -n "$NONZRAM_SWAP" ]]; then
  ok "已存在非 zram swap：$(echo "$NONZRAM_SWAP" | tr '\n' ' ')"
  if [[ "$SWAPFILE" == "auto" ]]; then
    echo "   策略=auto：保持现状，不新建、不改大小"
  fi
  if (( RESIZE_SWAPFILE )) && (( FINAL_SF > 0 )) && [[ "$NONZRAM_SWAP" == "$SWAPFILE_PATH" ]]; then
    CUR_MB=$(( $(stat -c %s "$SWAPFILE_PATH" 2>/dev/null || echo 0) / 1048576 ))
    if (( CUR_MB == FINAL_SF )); then
      ok "已是目标大小 ${FINAL_SF} MiB，跳过"
    else
      USED_MB=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{printf "%d",(t-f)/1024}' /proc/meminfo)
      AVAIL_MB=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
      warn "调整 ${SWAPFILE_PATH}: ${CUR_MB} MiB → ${FINAL_SF} MiB（swap 中已有 ${USED_MB} MiB）"
      if (( AVAIL_MB < USED_MB + 256 )); then
        err "内存不足以安全 swapoff（需 ≈$((USED_MB+256)) MiB 可用，实际 ${AVAIL_MB} MiB），放弃 resize"
      else
        run swapoff "$SWAPFILE_PATH"
        run rm -f "$SWAPFILE_PATH"
        swapfile_create "$FINAL_SF"
        ok "resize 完成"
      fi
    fi
  fi
fi

# 3b) 没有任何非 zram swap
if [[ -z "$NONZRAM_SWAP" ]]; then
  if (( FINAL_SF == 0 )); then
    warn "无 swap 设备，且按当前内存/磁盘不新建（FINAL_SF=0）"
  else
    ALREADY=0   # 0=需创建  1=已存在且大小正确  -1=已存在但大小不符且未允许 resize
    if [[ -f "$SWAPFILE_PATH" ]]; then
      CUR_MB=$(( $(stat -c %s "$SWAPFILE_PATH") / 1048576 ))
      if (( CUR_MB == FINAL_SF )); then
        ALREADY=1; ok "$SWAPFILE_PATH 已存在且大小正确（${FINAL_SF} MiB）"
      elif (( RESIZE_SWAPFILE )); then
        warn "已存在 $SWAPFILE_PATH (${CUR_MB} MiB)，--resize-swapfile → ${FINAL_SF} MiB"
        run rm -f "$SWAPFILE_PATH"; ALREADY=0
      else
        warn "已存在 $SWAPFILE_PATH (${CUR_MB} MiB ≠ ${FINAL_SF} MiB)，未加 --resize-swapfile，保持原样"
        ALREADY=-1
      fi
    fi
    if (( ALREADY >= 0 )); then
      if (( ALREADY == 0 )); then
        warn "创建 $SWAPFILE_PATH（${FINAL_SF} MiB，占用磁盘）"
        run touch "$STATE_DIR/created-swapfile"   # 先登记，rollback 才会清理
      fi
      swapfile_create "$FINAL_SF"
      if ! grep -q "^${SWAPFILE_PATH} " /etc/fstab 2>/dev/null; then
        if (( DRY )); then
          echo "   [dry-run] 追加 fstab: ${SWAPFILE_PATH} none swap sw,pri=${SWAPFILE_PRIO} 0 0"
        else
          echo "${SWAPFILE_PATH} none swap sw,pri=${SWAPFILE_PRIO} 0 0" >> /etc/fstab
        fi
      fi
      ok "swapfile 就绪（${FINAL_SF} MiB, prio ${SWAPFILE_PRIO}）"
    fi
  fi
fi

# 4) zram
log "[4/6] 配置 zram"
run rm -f "$FB_UNIT" "$FB_UP" "$FB_DOWN"
if (( ! DRY )); then
  if grep -q '^/dev/zram0 ' /proc/swaps 2>/dev/null; then
    echo "   接管已在运行的 /dev/zram0"; swapoff /dev/zram0 || true
  fi
  if [[ -e /sys/block/zram0/reset ]]; then echo 1 > /sys/block/zram0/reset 2>/dev/null || true; fi
else
  echo "   [dry-run] swapoff /dev/zram0; reset"
fi
run systemctl daemon-reload

GEN_OK=0
if (( ! DRY )); then
  if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-zram-setup@' \
     || [[ -e /usr/lib/systemd/system-generators/zram-generator ]]; then GEN_OK=1; fi
fi

if (( GEN_OK )); then
  ok "使用 zram-generator"
  put "$GEN_CONF" <<EOF
# 由 zram-setup.sh 生成于 $(date -Is)
[zram0]
zram-size = ${FINAL_ZRAM_MB}M
compression-algorithm = ${FINAL_ALGO}
swap-priority = ${ZRAM_PRIO}
fs-type = swap
EOF
  putc "$ML_SCRIPT" 0755 <<EOF
#!/bin/sh
# zram-setup.sh: zram0 真实内存硬上限（自动调参值）
if [ -e /sys/block/zram0/mem_limit ]; then echo ${FINAL_ML_MB}M > /sys/block/zram0/mem_limit; fi
EOF
  putc "$ML_UNIT" 0644 <<'EOF'
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
else
  if (( DRY )); then ok "（dry-run 探测不到 generator，按回退方案演示）"; fi
  warn "未检测到 zram-generator → 回退自带 unit（可 apt install systemd-zram-generator 后用官方方案）"
  putc "$FB_UP" 0755 <<EOF
#!/bin/sh
# zram-setup.sh 生成：启动 zram swap
set -e
DEV=/dev/zram0
modprobe zram num_devices=1 2>/dev/null || modprobe zram
if grep -q "^\$DEV " /proc/swaps 2>/dev/null; then swapoff "\$DEV"; fi
if [ -e /sys/block/zram0/reset ]; then echo 1 > /sys/block/zram0/reset; fi
echo ${FINAL_ALGO} > /sys/block/zram0/comp_algorithm 2>/dev/null || true
echo ${FINAL_ZRAM_MB}M > /sys/block/zram0/disksize
if [ -e /sys/block/zram0/mem_limit ]; then echo ${FINAL_ML_MB}M > /sys/block/zram0/mem_limit; fi
mkswap "\$DEV" >/dev/null
swapon -p ${ZRAM_PRIO} "\$DEV"
EOF
  putc "$FB_DOWN" 0755 <<'EOF'
#!/bin/sh
# zram-setup.sh 生成：停止 zram swap
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

# 5) sysctl
if (( DO_SYSCTL )); then
  log "[5/6] 内核调参（整机生效）"
  put "$SYSCTL_FILE" <<EOF
# 由 zram-setup.sh 生成于 $(date -Is)
# zram 是内存设备：积极换入更划算
vm.swappiness = ${FINAL_SW}
# 压缩 swap 是内存访问，关掉块设备预读
vm.page-cluster = 0
vm.vfs_cache_pressure = ${VP}
EOF
  run sysctl --system >/dev/null 2>&1 || run sysctl -p "$SYSCTL_FILE"
else
  log "[5/6] 跳过 sysctl（--no-sysctl）"
fi

# 6) KSM
if (( DO_KSM )); then
  log "[6/6] 开启 KSM"
  put "$KSM_FILE" <<EOF
kernel.mm.ksm.run = 1
kernel.mm.ksm.pages_to_scan = ${KSM_SCAN}
kernel.mm.ksm.sleep_millisecs = 20
EOF
  run sysctl --system >/dev/null 2>&1 || true
  (( DRY )) || echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
else
  log "[6/6] 跳过 KSM（默认关，--ksm 开启）"
fi

# ─────────────── 验证 ───────────────
echo
log "完成："
if (( DRY )); then
  echo "   (dry-run，跳过验证)"
else
  show_status
  echo
  ok "新换出的页优先进入 /dev/zram0（prio ${ZRAM_PRIO}），满了才落 ${SWAPFILE_PATH}（prio ${SWAPFILE_PRIO}）"
  echo "   压缩比回看： cat /sys/block/zram0/mm_stat"
  echo "   回滚：       sudo bash $0 --rollback"
fi
