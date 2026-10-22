#!/bin/bash
# =======================================================
# noVNC 官方最新正式版 → 第二套部署（虚拟目录 /new_vnc）
#
# 为什么要有它：
#   Debian 12 自带的 novnc 是 1.3.0（2021 年），它的 core/decoders/ 里没有 ZRLE，
#   也不在 SetEncodings 里发 encoding 16 —— 而 ZRLE 是协议层面保证无损的编码，
#   x11vnc(libvncserver) 原生支持（实测整屏 205,887 字节 / 0 个 JPEG 块）。
#   官方从 1.4.0 起加入 ZRLE 解码器（PR #1589），1.6.0 又加了 Zlib / H.264。
#   本脚本把官方最新正式版**单独**部署到 /usr/share/novnc-new，
#   用 nginx 的 /new_vnc 虚拟目录对外提供，**完全不动** /usr/share/novnc（1.3.0）
#   及其补丁，两套可以并用、也可以单独卸载。
#
# 它做什么：
#   1. 备份现有 noVNC（打包 + 版本/哈希 + 当前 nginx 配置 + 原始 deb）
#   2. 从 GitHub 官方仓库取指定 tag 的 tarball，解包后校验关键文件哈希（tag 内容不可变）
#   3. 部署到 /usr/share/novnc-new（裁掉开发用目录 tests/snap/po/.github 等，规范权限）
#   4. 打补丁（与 1.3.0 那套保持同等功能）：
#        · defaults.json：ws 路径 /websockify/1、自动连接、断线重连
#        · 中文剪贴板双向无乱码（出站 TextEncoder / 进站 TextDecoder）
#        · 剪贴板输入实时同步（input 事件）
#        · 编码列表只发无损（逼服务端用 ZRLE，而不是 Tight+JPEG）
#        · HiDPI：Scaling mode=无 时按 1/devicePixelRatio 缩放（1 帧像素 = 1 物理像素）
#        · 桌面音频条（复用 /root/novnc-audio/apply.sh）
#        · 页面声明 UTF-8（官方 1.7.0 的 vnc.html 没有 <meta charset>，中文会乱码）
#        · 左下角状态角标（编码/无损性、缩放比、帧率、带宽；纯只读，?badge=0 可隐藏）
#   5. 调主脚本刷新 nginx（/new_vnc 的 location 由 vnc_desktop_setup.sh 统一生成，
#      单写者；它会先 nginx -t，不通过就回滚，绝不让线上站点起不来）
#   6. 自检：页面/资源/默认配置/WebSocket 握手/旧站点未受影响
#
# 用法:
#   bash /root/vps-setup/scripts/novnc_new_deploy.sh                 # 部署/刷新
#   NOVNC_NEW_VERSION=v1.7.0 bash .../novnc_new_deploy.sh            # 指定版本
#   bash /root/vps-setup/scripts/novnc_new_deploy.sh --remove        # 卸载 /new_vnc
# =======================================================
set -euo pipefail

# ---------- 可调参数 ----------
NOVNC_NEW_VERSION="${NOVNC_NEW_VERSION:-v1.7.0}"
NOVNC_NEW_WEB_ROOT="${NOVNC_NEW_WEB_ROOT:-/usr/share/novnc-new}"
NOVNC_CUR_WEB_ROOT="${NOVNC_CUR_WEB_ROOT:-/usr/share/novnc}"
BACKUP_DIR="${BACKUP_DIR:-/root/novnc-backup}"
AUDIO_PATCH_DIR="${AUDIO_PATCH_DIR:-/root/novnc-audio}"
NOVNC_BADGE_JS="${NOVNC_BADGE_JS:-/root/vps-setup/scripts/novnc-badge.js}"
NOVNC_ENCODER_JS="${NOVNC_ENCODER_JS:-/root/vps-setup/scripts/novnc-encoder.js}"
SETUP_SCRIPT="${SETUP_SCRIPT:-/root/vps-setup/scripts/vnc_desktop_setup.sh}"
OR_PREFIX="${OR_PREFIX:-/usr/local/openresty/nginx}"
OR_NGINX_BIN="${OR_NGINX_BIN:-${OR_PREFIX}/sbin/nginx}"
URL_PATH="/new_vnc"
TS="$(date +%F_%H%M%S)"
TARBALL_URL="https://codeload.github.com/novnc/noVNC/tar.gz/refs/tags/${NOVNC_NEW_VERSION}"

say()  { printf '%s\n' "$*"; }
ok()   { printf '✅ %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*"; }
die()  { printf '❌ %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行"; }

# 官方 tag 解包后关键文件哈希（git tag 的内容不可变；tarball 每次压缩可能不同，
# 所以校验解包后的文件内容，而不是 tarball 自身）
official_hash() {
    case "$1:${NOVNC_NEW_VERSION}" in
        vnc.html:v1.7.0)    echo "df7dbd37428667773afe5ddc7cee916e200ef27dcc748186c48ce13e8cd32242" ;;
        core/rfb.js:v1.7.0) echo "c46dfefbf869eda0c6d06c5dd86c42e96fc8a77c125e91599a2cdf3841261564" ;;
        app/ui.js:v1.7.0)   echo "40686a5f9511d6fa3e45be422ae25350eaeb10b18aaad30a9bd07f878e3f6bf0" ;;
        *) echo "" ;;
    esac
}

# -------------------------------------------------------
# 1) 备份
# -------------------------------------------------------
backup_current() {
    mkdir -p "${BACKUP_DIR}"
    if [ -d "${NOVNC_CUR_WEB_ROOT}" ]; then
        local pkg="${BACKUP_DIR}/novnc-1.3.0-debian-patched-${TS}.tar.gz"
        tar -czf "${pkg}" -C "$(dirname "${NOVNC_CUR_WEB_ROOT}")" "$(basename "${NOVNC_CUR_WEB_ROOT}")"
        ok "已备份现有 noVNC 整棵目录：${pkg}（$(du -h "${pkg}" | cut -f1)）"
        dpkg-query -W -f='${Package} ${Version}\n' novnc > "${BACKUP_DIR}/novnc-package-${TS}.txt" 2>/dev/null || true
        ( cd "${BACKUP_DIR}" && sha256sum \
            "${NOVNC_CUR_WEB_ROOT}/vnc.html" \
            "${NOVNC_CUR_WEB_ROOT}/core/rfb.js" \
            "${NOVNC_CUR_WEB_ROOT}/app/ui.js" > "sha256-patched-1.3.0-${TS}.txt" ) 2>/dev/null || true
    else
        warn "找不到 ${NOVNC_CUR_WEB_ROOT}，跳过目录备份"
    fi
    # 线上 nginx 配置也留一份（主脚本自己也会备份一份）
    if [ -f "${OR_PREFIX}/conf/conf.d/50-novnc.conf" ]; then
        cp -a "${OR_PREFIX}/conf/conf.d/50-novnc.conf" "${BACKUP_DIR}/50-novnc.conf.${TS}"
        ok "已备份 nginx 配置：${BACKUP_DIR}/50-novnc.conf.${TS}"
    fi
    # 顺手留一份未打补丁的原始 deb（可选；apt 索引被清过时会失败，不影响后续）
    if command -v apt-get >/dev/null 2>&1; then
        if ( cd "${BACKUP_DIR}" && apt-get download novnc >/dev/null 2>&1 ); then
            ok "已保存原始 deb：$(ls -1 "${BACKUP_DIR}"/novnc_*.deb 2>/dev/null | tail -1)"
        else
            warn "原始 deb 下载失败（apt 索引可能被 housekeeping 清过），跳过（不影响后续）"
        fi
    fi
    # 如果 /new_vnc 之前已经存在，也留一份旧版
    if [ -d "${NOVNC_NEW_WEB_ROOT}" ]; then
        tar -czf "${BACKUP_DIR}/novnc-new-before-${TS}.tar.gz" \
            -C "$(dirname "${NOVNC_NEW_WEB_ROOT}")" "$(basename "${NOVNC_NEW_WEB_ROOT}")"
        ok "已备份旧版 ${NOVNC_NEW_WEB_ROOT}：${BACKUP_DIR}/novnc-new-before-${TS}.tar.gz"
    fi
}

# -------------------------------------------------------
# 2) 下载 + 校验
# -------------------------------------------------------
SRC_DIR=""
fetch_release() {
    local tmp ver_got f got exp
    tmp="$(mktemp -d)"
    say "ℹ️ 下载 noVNC ${NOVNC_NEW_VERSION} …"
    say "   ${TARBALL_URL}"
    curl -fsSL --max-time 240 -o "${tmp}/novnc.tar.gz" "${TARBALL_URL}" \
        || die "下载失败（检查网络/代理）：${TARBALL_URL}"
    say "   tarball sha256: $(sha256sum "${tmp}/novnc.tar.gz" | awk '{print $1}')"
    tar -xzf "${tmp}/novnc.tar.gz" -C "${tmp}" || die "解包失败"
    SRC_DIR="$(find "${tmp}" -maxdepth 1 -mindepth 1 -type d -name 'noVNC-*' | head -1)"
    [ -n "${SRC_DIR}" ] || die "解包后找不到 noVNC-* 目录"

    ver_got="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
               "${SRC_DIR}/package.json" 2>/dev/null || echo '')"
    [ "${ver_got}" = "${NOVNC_NEW_VERSION#v}" ] \
        || die "版本不符：package.json 说 '${ver_got}'，期望 '${NOVNC_NEW_VERSION#v}'"
    ok "版本自述一致：${ver_got}"

    local checked=0 skipped=0
    for f in vnc.html core/rfb.js app/ui.js; do
        exp="$(official_hash "${f}")"
        got="$(sha256sum "${SRC_DIR}/${f}" | awk '{print $1}')"
        if [ -z "${exp}" ]; then
            skipped=$((skipped + 1)); continue
        fi
        [ "${got}" = "${exp}" ] \
            || die "${f} 哈希与官方 ${NOVNC_NEW_VERSION} 不一致，拒绝部署（got ${got}）"
        checked=$((checked + 1))
    done
    if [ "${skipped}" -gt 0 ]; then
        warn "${NOVNC_NEW_VERSION} 未登记全部官方哈希，仅校验了 ${checked} 个文件"
    else
        ok "关键文件哈希校验通过（官方 ${NOVNC_NEW_VERSION}，${checked} 个文件）"
    fi
}

# -------------------------------------------------------
# 3) 部署
# -------------------------------------------------------
deploy_tree() {
    [ -n "${SRC_DIR}" ] || die "内部错误：源代码目录为空"
    # 裁掉开发/测试用目录，只留运行需要的
    rm -rf "${SRC_DIR}/.github" "${SRC_DIR}/tests" "${SRC_DIR}/snap" \
           "${SRC_DIR}/utils" "${SRC_DIR}/po" \
           "${SRC_DIR}/.gitignore" "${SRC_DIR}/.gitmodules" \
           "${SRC_DIR}/eslint.config.mjs" "${SRC_DIR}/karma.conf.cjs"
    rm -rf "${NOVNC_NEW_WEB_ROOT}"
    install -d -m 0755 "${NOVNC_NEW_WEB_ROOT}"
    cp -a "${SRC_DIR}/." "${NOVNC_NEW_WEB_ROOT}/"
    find "${NOVNC_NEW_WEB_ROOT}" -type d -exec chmod 0755 {} +
    find "${NOVNC_NEW_WEB_ROOT}" -type f -exec chmod 0644 {} +
    chown -R root:root "${NOVNC_NEW_WEB_ROOT}"
    printf '%s\n' "${NOVNC_NEW_VERSION#v}" > "${NOVNC_NEW_WEB_ROOT}/VERSION"
    ok "已部署到 ${NOVNC_NEW_WEB_ROOT}（$(du -sh "${NOVNC_NEW_WEB_ROOT}" | cut -f1)）"
}

# -------------------------------------------------------
# 4) 打补丁
# -------------------------------------------------------
write_defaults() {
    cat > "${NOVNC_NEW_WEB_ROOT}/defaults.json" <<'EOF'
{
    "path": "/websockify/1",
    "autoconnect": true,
    "reconnect": true
}
EOF
    ok "已写默认设置 defaults.json（ws 路径 /websockify/1、自动连接、断线重连）"
}

patch_page() {
    python3 - "${NOVNC_NEW_WEB_ROOT}" <<'PY'
import os, re, sys

root = sys.argv[1]
rfb = os.path.join(root, "core", "rfb.js")
ui = os.path.join(root, "app", "ui.js")

def read(p):
    with open(p, encoding="utf-8") as fh:
        return fh.read()

def write(p, s):
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(s)

done = []

# ---- 1) 剪贴板 出站（浏览器 -> Linux）----
# 原版只支持 ISO 8859-1，>0xff 的字符一律变成 '?'（中文全丢）。改成 TextEncoder。
s = read(rfb)
if "new TextEncoder().encode(text)" in s:
    done.append("出站编码：已是 UTF-8（跳过）")
else:
    pat = re.compile(r"([ \t]*)let length, i;[\s\S]{0,900}?RFB\.messages\.clientCutText\(this\._sock, data\);")
    repl = (r"\1const data = new TextEncoder().encode(text);"
            "\n\n"
            r"\1RFB.messages.clientCutText(this._sock, data);")
    s2, n = pat.subn(repl, s, count=1)
    if n == 1:
        write(rfb, s2)
        done.append("出站编码：已改为 UTF-8（TextEncoder）")
    else:
        done.append("出站编码：⚠️ 未找到匹配片段，未改动")

# ---- 2) 剪贴板 进站（Linux -> 浏览器）----
# rQshiftStr() 是 Latin-1 解码，中文会乱码。改成 TextDecoder('utf-8')。
s = read(rfb)
if 'new TextDecoder("utf-8").decode(bytes)' in s:
    done.append("进站解码：已是 UTF-8（跳过）")
else:
    tgt = "const text = this._sock.rQshiftStr(length);"
    if s.count(tgt) == 1:
        repl = ('const bytes = new Uint8Array(this._sock.rQshiftBytes(length));\n'
                '            let text;\n'
                '            try { text = new TextDecoder("utf-8").decode(bytes); }\n'
                '            catch (e) { text = String.fromCharCode.apply(null, bytes); }')
        write(rfb, s.replace(tgt, repl, 1))
        done.append("进站解码：已改为 UTF-8（TextDecoder）")
    else:
        done.append("进站解码：⚠️ 匹配数≠1，未改动")

# ---- 3) 剪贴板输入实时同步 ----
# 原版只在 change（失焦/回车）时同步，粘完不点别处不会发过去。加 input 事件。
s = read(ui)
if "addEventListener('input', UI.clipboardSend)" in s:
    done.append("输入实时同步：已存在（跳过）")
else:
    tgt = ("document.getElementById(\"noVNC_clipboard_text\")\n"
           "            .addEventListener('change', UI.clipboardSend);")
    if tgt in s:
        add = ("\n        document.getElementById(\"noVNC_clipboard_text\")\n"
               "            .addEventListener('input', UI.clipboardSend);")
        write(ui, s.replace(tgt, tgt + add, 1))
        done.append("输入实时同步：已加入 input 事件")
    else:
        done.append("输入实时同步：⚠️ 未找到匹配片段，未改动")

# ---- 4) 编码列表：由页面「编码」下拉框决定（默认 ZRLE 无损）----
# 背景：只要广告列表里出现 Tight/TightPNG，x11vnc(libvncserver) 就优先 Tight+JPEG
# （有损：整屏 42 个 JPEG 块 / 227KB），去掉后走 ZRLE 这类无损编码（实测 0 个 JPEG 块）。
# 现在把这个决定权交给页面上的下拉框：广告列表由 app/novnc-encoder.js 的
# window.__vpsEncodings() 给出（一次只广告选中的那一个），没加载时退回默认的 ZRLE 优先列表。
# 注意：只动「广告什么」，解码器全都保留 —— 选 Tight 时照样能解。
s = read(rfb)
ENC_MARK = "            // vps-setup: 编码由页面下拉框决定（默认 ZRLE 无损）"
new_block = (ENC_MARK + "\n"
             "            //   列表来自 app/novnc-encoder.js 的 window.__vpsEncodings()（一次只广告选中的那个）；\n"
             "            //   背景：列表里只要有 Tight/TightPNG，x11vnc 就优先 Tight+JPEG（有损但省 CPU）。\n"
             "            const vpsEncs = (typeof window.__vpsEncodings === \"function\")\n"
             "                ? window.__vpsEncodings() : null;\n"
             "            for (const enc of (vpsEncs || [encodings.encodingZRLE, encodings.encodingHextile,\n"
             "                                          encodings.encodingRRE, encodings.encodingZlib])) {\n"
             "                encs.push(enc);\n"
             "            }\n")
if ENC_MARK in s:
    done.append("编码列表：已由页面下拉框决定（跳过）")
else:
    # 上一版补丁的形态（写死只发无损；注意它只替换了 Tight 那几行，后面的
    # Hextile/RRE/Zlib 三行是原版残留，必须一起吃掉，否则「选什么就发什么」不成立）
    oldpatch = ("            // vps-setup: 不发 Tight/TightPNG/JPEG/H.264\n"
                "            //   只要 Tight/TightPNG 在列表里，x11vnc 就优先 Tight+JPEG（有损）；\n"
                "            //   去掉后它只能用 ZRLE 这类无损编码（实测整屏 205KB、0 个 JPEG 块）。\n"
                "            encs.push(encodings.encodingZRLE);\n"
                "            encs.push(encodings.encodingHextile);\n"
                "            encs.push(encodings.encodingRRE);\n"
                "            encs.push(encodings.encodingZlib);\n")
    # 官方原版（1.7.0）的形态：整个 if (fbDepth==24) 内部一并替换
    origblock = ("            if (supportsWebCodecsH264Decode) {\n"
                 "                encs.push(encodings.encodingH264);\n"
                 "            }\n"
                 "            encs.push(encodings.encodingTight);\n"
                 "            encs.push(encodings.encodingTightPNG);\n"
                 "            encs.push(encodings.encodingZRLE);\n"
                 "            encs.push(encodings.encodingJPEG);\n"
                 "            encs.push(encodings.encodingHextile);\n"
                 "            encs.push(encodings.encodingRRE);\n"
                 "            encs.push(encodings.encodingZlib);\n")
    if oldpatch in s:
        write(rfb, s.replace(oldpatch, new_block, 1))
        done.append("编码列表：已从「写死只发无损」改为「由页面下拉框决定」")
    elif origblock in s:
        write(rfb, s.replace(origblock, new_block, 1))
        done.append("编码列表：已改为「由页面下拉框决定」（默认 ZRLE 无损）")
    else:
        done.append("编码列表：⚠️ 未找到期望片段，未改动")

# ---- 5) HiDPI：Scaling mode=无 时按 1/devicePixelRatio 缩放 ----
# 原版 _updateScale() 在「Scaling mode = None」时硬编码 display.scale = 1.0，
# 于是画布 CSS 尺寸 = 帧尺寸。在 devicePixelRatio≠1 的屏上（例如 Windows 系统显示缩放
# 125%），浏览器还要把画布再放大 1.25 倍 → 重采样发虚（实测角标读数
# ×1.25(布局1.00·DPR1.25·发虚)）。改成 1/DPR：画布 CSS 尺寸 = 帧尺寸/DPR，
# 物理尺寸恰好等于帧尺寸，浏览器不再重采样。
# 必须走 display.scale（即 _rescale()），它会同时更新 _scale —— 鼠标坐标就是靠
# absX/absY 除以 _scale 换算的（rfb.js: pointerEvent(this._display.absX(x), ...)），
# 所以改了缩放比例，鼠标位置依然准确。
s = read(rfb)
HIDPI_MARK = "            // vps-setup: HiDPI —— Mode=无 时按 1/devicePixelRatio 缩放"
if HIDPI_MARK in s:
    done.append("HiDPI：已是「1 帧像素 = 1 物理像素」（跳过）")
else:
    tgt = ("        if (!this._scaleViewport) {\n"
           "            this._display.scale = 1.0;\n")
    repl = (tgt
            + HIDPI_MARK + "\n"
            "            //   画布 CSS 尺寸 = 帧尺寸/DPR，物理尺寸 = 帧尺寸，不再被浏览器放大重采样。\n"
            "            //   display.scale 会走 _rescale() 并同步更新 _scale，鼠标坐标换算不受影响。\n"
            "            this._display.scale = 1.0 / (window.devicePixelRatio || 1);\n")
    if s.count(tgt) == 1:
        write(rfb, s.replace(tgt, repl, 1))
        done.append("HiDPI：Mode=无 时按 1/DPR 缩放（1 帧像素 = 1 物理像素）")
    else:
        done.append("HiDPI：⚠️ _updateScale() 里的期望片段匹配数≠1，未改动")

print("   补丁结果：")
for d in done:
    print("     · " + d)
PY

    if command -v node >/dev/null 2>&1; then
        node --check "${NOVNC_NEW_WEB_ROOT}/core/rfb.js" \
            && node --check "${NOVNC_NEW_WEB_ROOT}/app/ui.js" \
            && ok "core/rfb.js、app/ui.js 语法检查通过"
    else
        warn "没有 node，跳过 JS 语法检查"
    fi

    # 桌面音频条（复用现成补丁：拷 app/desktop-audio.js + 往 vnc.html 插片段，幂等）
    if [ -f "${AUDIO_PATCH_DIR}/apply.sh" ]; then
        NOVNC_DIR="${NOVNC_NEW_WEB_ROOT}" bash "${AUDIO_PATCH_DIR}/apply.sh"
        ok "桌面音频补丁已应用（apply.sh NOVNC_DIR=${NOVNC_NEW_WEB_ROOT}）"
    else
        warn "找不到 ${AUDIO_PATCH_DIR}/apply.sh，跳过桌面音频补丁"
    fi

    # 状态角标 + 页面字符集（拷 app/novnc-badge.js + 改 vnc.html，幂等）
    if [ -f "${NOVNC_BADGE_JS}" ]; then
        install -m 0644 "${NOVNC_BADGE_JS}" "${NOVNC_NEW_WEB_ROOT}/app/novnc-badge.js"
        python3 - "${NOVNC_NEW_WEB_ROOT}/vnc.html" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
orig = s

# 1) 字符集：官方 1.7.0 的 vnc.html 没有 <meta charset>，浏览器会按 windows-1252 解码，
#    于是「经典脚本」里的中文（状态角标）和注入 HTML 里的中文（音频条标签）全变乱码。
#    注意：ES module 永远按 UTF-8 解码，所以只有经典脚本 / HTML 文本会中招。
if 'charset="utf-8"' in s.lower():
    print("     · 字符集：vnc.html 已有声明（跳过）")
else:
    for anchor in ("<head>", "<HEAD>"):
        if anchor in s:
            s = s.replace(anchor, anchor + '\n    <meta charset="utf-8">', 1)
            print('     · 字符集：已插入 <meta charset="utf-8">')
            break
    else:
        print("     · 字符集：⚠️ 未找到 <head>，未插入")

# 2) 状态角标 script 标签
MARK = "<!-- vps-setup: 状态角标 -->"
if MARK in s:
    print("     · 状态角标：vnc.html 已注入（跳过）")
elif "</body>" in s:
    s = s.replace("</body>", MARK + '\n    <script src="app/novnc-badge.js"></script>\n</body>', 1)
    print("     · 状态角标：已注入 vnc.html")
else:
    print("     · 状态角标：⚠️ 未找到 </body>，未注入")

if s != orig:
    open(p, "w", encoding="utf-8").write(s)
PY
        if command -v node >/dev/null 2>&1; then
            if node --check "${NOVNC_NEW_WEB_ROOT}/app/novnc-badge.js"; then
                ok "状态角标已安装（app/novnc-badge.js，语法检查通过）"
            else
                warn "状态角标已拷贝，但 node 语法检查未通过"
            fi
        else
            ok "状态角标已安装（app/novnc-badge.js）"
        fi
    else
        warn "找不到 ${NOVNC_BADGE_JS}，跳过状态角标"
    fi

    # 编码下拉框（拷 app/novnc-encoder.js + 往 vnc.html 插 script 标签，幂等）
    # 下拉框本身的 DOM（「高级」面板里、品质上方）由该脚本在页面里自己插入，不用改 vnc.html 标记。
    if [ -f "${NOVNC_ENCODER_JS}" ]; then
        install -m 0644 "${NOVNC_ENCODER_JS}" "${NOVNC_NEW_WEB_ROOT}/app/novnc-encoder.js"
        python3 - "${NOVNC_NEW_WEB_ROOT}/vnc.html" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
MARK = "<!-- vps-setup: 编码下拉框 -->"
if MARK in s:
    print("     · 编码下拉框：vnc.html 已注入（跳过）")
elif "</body>" in s:
    s = s.replace("</body>", MARK + '\n    <script src="app/novnc-encoder.js"></script>\n</body>', 1)
    open(p, "w", encoding="utf-8").write(s)
    print("     · 编码下拉框：已注入 vnc.html")
else:
    print("     · 编码下拉框：⚠️ 未找到 </body>，未注入")
PY
        if command -v node >/dev/null 2>&1; then
            if node --check "${NOVNC_NEW_WEB_ROOT}/app/novnc-encoder.js"; then
                ok "编码下拉框已安装（app/novnc-encoder.js，语法检查通过；默认 ZRLE）"
            else
                warn "编码下拉框已拷贝，但 node 语法检查未通过"
            fi
        else
            ok "编码下拉框已安装（app/novnc-encoder.js，默认 ZRLE）"
        fi
    else
        warn "找不到 ${NOVNC_ENCODER_JS}，跳过编码下拉框"
    fi
}

refresh_nginx() {
    [ -f "${SETUP_SCRIPT}" ] || { warn "找不到 ${SETUP_SCRIPT}，请手动刷新 nginx"; return 0; }
    say "ℹ️ 调主脚本刷新 nginx（/new_vnc 的 location 由它统一生成）…"
    bash "${SETUP_SCRIPT}" --novnc-web
}

# -------------------------------------------------------
# 5) 自检
# -------------------------------------------------------
FAILED=0
chk() { # chk <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then
        say "   ✅ $1（$3）"
    else
        say "   ❌ $1（期望 $2，实际 $3）"; FAILED=$((FAILED + 1))
    fi
}

# 注意：`nginx -s reload` 是异步的，返回后旧 worker 还会继续服务一小会儿。
# 所以自检前先等新配置真正生效，否则会误报 404。
wait_ready() {
    local i code
    for i in $(seq 1 30); do
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1${URL_PATH}/vnc.html" 2>/dev/null || echo 000)
        [ "${code}" = "200" ] && return 0
        sleep 0.3
    done
    warn "等了 9 秒 ${URL_PATH}/vnc.html 还不是 200（实际 ${code}）"
    return 0
}

http_code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$1" 2>/dev/null || echo "000"; }

# 注意：不要写成 `curl ... | grep -q`。脚本开了 pipefail，
# grep -q 命中即退出会让上游 printf/curl 吃到 SIGPIPE（大文件尤其明显，
# >64KB 的一律误报失败）。这里用 bash 自身的前缀/子串匹配，无管道、无副作用。
has() { # has <正文> <子串>  → yes/no
    case "$1" in
        *"$2"*) echo yes ;;
        *)      echo no ;;
    esac
}

fetch_body() { curl -sk --compressed --max-time 10 "$1" 2>/dev/null || true; }

ws_code() { # WebSocket 握手：期望 101
    local out
    out=$(curl -skN -o /dev/null -w '%{http_code}' --max-time 4 \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' \
        "$1" 2>/dev/null || true)
    [ -n "${out}" ] || out="000"
    printf '%s' "${out:0:3}"
}

selfcheck() {
    local host="https://127.0.0.1" body
    say ""
    say "== 自检 =="

    chk "新页面 ${URL_PATH}/vnc.html" 200 "$(http_code "${host}${URL_PATH}/vnc.html")"
    chk "目录入口 ${URL_PATH}/" 200 "$(http_code "${host}${URL_PATH}/")"
    chk "短地址 ${URL_PATH} 重定向" 302 "$(http_code "${host}${URL_PATH}")"
    chk "ZRLE 解码器（1.4+ 才有）" 200 "$(http_code "${host}${URL_PATH}/core/decoders/zrle.js")"
    chk "默认配置 defaults.json" 200 "$(http_code "${host}${URL_PATH}/defaults.json")"

    body=$(fetch_body "${host}${URL_PATH}/vnc.html")
    chk "新页面含桌面音频条" yes "$(has "${body}" desktopAudioBar)"
    chk "新页面含音频脚本" yes "$(has "${body}" 'app/desktop-audio.js')"
    chk "新页面含状态角标" yes "$(has "${body}" 'app/novnc-badge.js')"
    chk "新页面含编码下拉框脚本" yes "$(has "${body}" 'app/novnc-encoder.js')"
    chk "新页面声明 UTF-8（否则中文乱码）" yes "$(has "${body}" 'charset="utf-8"')"
    chk "状态角标脚本" 200 "$(http_code "${host}${URL_PATH}/app/novnc-badge.js")"
    body=$(fetch_body "${host}${URL_PATH}/app/novnc-badge.js")
    chk "状态角标脚本内容" yes "$(has "${body}" 'vpsBadge')"

    body=$(fetch_body "${host}${URL_PATH}/app/novnc-encoder.js")
    chk "编码下拉框脚本" 200 "$(http_code "${host}${URL_PATH}/app/novnc-encoder.js")"
    chk "编码下拉框脚本内容" yes "$(has "${body}" '__vpsEncodings')"
    chk "编码下拉框默认 ZRLE" yes "$(has "${body}" "DEFAULT_KEY = 'zrle'")"

    body=$(fetch_body "${host}${URL_PATH}/defaults.json")
    chk "defaults.json 指向 /websockify/1" yes "$(has "${body}" '/websockify/1')"

    body=$(fetch_body "${host}${URL_PATH}/core/rfb.js")
    chk "rfb.js 剪贴板出站已 UTF-8" yes "$(has "${body}" 'new TextEncoder().encode(text)')"
    chk "rfb.js 剪贴板进站已 UTF-8" yes "$(has "${body}" 'new TextDecoder("utf-8").decode(bytes)')"
    chk "编码列表：由页面下拉框决定" yes "$(has "${body}" '__vpsEncodings')"
    chk "编码列表：不再写死 Tight" no "$(has "${body}" 'encs.push(encodings.encodingTight);')"
    chk "编码列表：不再广告 JPEG/H.264" no "$(has "${body}" 'encs.push(encodings.encodingH264);')"
    chk "编码列表：默认仍以 ZRLE 为先" yes "$(has "${body}" 'vpsEncs || [encodings.encodingZRLE')"
    chk "编码列表：无残留写死 Hextile" no "$(has "${body}" 'encs.push(encodings.encodingHextile);')"
    chk "编码列表：无残留写死 RRE" no "$(has "${body}" 'encs.push(encodings.encodingRRE);')"
    chk "编码列表：无残留写死 Zlib" no "$(has "${body}" 'encs.push(encodings.encodingZlib);')"
    chk "rfb.js HiDPI：Mode=无 时 1 帧像素 = 1 物理像素" yes "$(has "${body}" 'vps-setup: HiDPI')"

    # WebSocket 握手（新路径 + 老路径都要能 101）
    chk "WS 握手 ${URL_PATH}/websockify/1" 101 "$(ws_code "${host}${URL_PATH}/websockify/1")"
    chk "WS 握手 /websockify/1（1.3.0 老站点）" 101 "$(ws_code "${host}/websockify/1")"

    # 旧站点未受影响
    chk "老站点 /vnc.html 未受影响" 200 "$(http_code "${host}/vnc.html")"
    body=$(fetch_body "${host}/vnc.html")
    chk "老站点仍有桌面音频条" yes "$(has "${body}" desktopAudioBar)"
}

remove_mode() {
    need_root
    if [ -d "${NOVNC_NEW_WEB_ROOT}" ]; then
        mkdir -p "${BACKUP_DIR}"
        tar -czf "${BACKUP_DIR}/novnc-new-removed-${TS}.tar.gz" \
            -C "$(dirname "${NOVNC_NEW_WEB_ROOT}")" "$(basename "${NOVNC_NEW_WEB_ROOT}")"
        ok "已备份待删除的目录：${BACKUP_DIR}/novnc-new-removed-${TS}.tar.gz"
        rm -rf "${NOVNC_NEW_WEB_ROOT}"
        ok "已删除 ${NOVNC_NEW_WEB_ROOT}"
    else
        warn "${NOVNC_NEW_WEB_ROOT} 本来就不存在"
    fi
    refresh_nginx
    ok "已卸载 ${URL_PATH}（老站点不受影响）"
    exit 0
}

# -------------------------------------------------------
main() {
    need_root
    say "=============================================="
    say " noVNC 官方最新版 → ${URL_PATH}"
    say " 版本：${NOVNC_NEW_VERSION}"
    say " 目录：${NOVNC_NEW_WEB_ROOT}"
    say "=============================================="
    backup_current
    fetch_release
    deploy_tree
    write_defaults
    patch_page
    refresh_nginx
    wait_ready
    selfcheck
    say ""
    if [ "${FAILED}" -eq 0 ]; then
        ok "全部自检通过"
    else
        warn "有 ${FAILED} 项自检未通过，请把上面的 ❌ 行发我"
    fi
    say ""
    say "入口： https://<你的域名或IP>${URL_PATH}/"
    say "      https://<你的域名或IP>${URL_PATH}/vnc.html?path=/websockify/1&autoconnect=true&reconnect=true"
    say "备份： ${BACKUP_DIR}/"
    say "回滚： 删掉 ${NOVNC_NEW_WEB_ROOT} 后跑 bash ${SETUP_SCRIPT} --novnc-web"
    [ "${FAILED}" -eq 0 ]
}

if [ "${1:-}" = "--check" ]; then
    need_root
    wait_ready
    selfcheck
    say ""
    [ "${FAILED}" -eq 0 ] && ok "全部自检通过" || { warn "有 ${FAILED} 项未通过"; exit 1; }
    exit 0
fi

if [ "${1:-}" = "--remove" ]; then
    remove_mode
fi

main
