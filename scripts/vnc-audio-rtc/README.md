# vnc-audio-rtc：桌面声音直发 WebRTC

把 noVNC 页面的「桌面声音」从原来的

```
PulseAudio → ffmpeg → RTSP/TCP → MediaMTX → WHEP → 浏览器
```

改成和 Selkies 同构的一条直线。现在有两种后端，由
`/etc/default/vnc-audio-rtc` 的 `AUDIO_BACKEND` 选择，默认 `go`：

```
# go（默认，单进程、无 cgo、无 8195）
PulseAudio monitor → gopus（10ms Opus，进程内）→ pion → SRTP/UDP 8193 → 浏览器

# ffmpeg（回退）
PulseAudio monitor → ffmpeg(libopus, 10ms) → RTP/UDP 127.0.0.1:8195
                                                    ↓
                          vnc-audio-rtc（pion）→ SRTP/UDP 8193 → 浏览器
```

两条都没有 RTSP/TCP 中转，没有 MediaMTX 二次转发，也就没有 TCP 合包造成的
成串投递。

## 端口

| 端口 | 用途 | 暴露 |
|---|---|---|
| `127.0.0.1:6092` | WHEP 信令（nginx `/whep` 反代） | 仅本机 |
| `udp/8193` | WebRTC 媒体（ICE UDP mux，多听众共用） | 宿主机 DNAT |
| `127.0.0.1:8195` | **仅 ffmpeg 后端**：ffmpeg → 本进程的 RTP | 仅本机 |

`go` 后端不监听 8195，也没有外部 ffmpeg 进程。

`8193` 原来属于 RTC 视频桥的 `8190-8193` 段。启用本服务后，视频桥必须限在
`8190-8192`（`/etc/default/vnc-rtc` 的 `ICE_PORT_MAX=8192`），把 `8193` 让出来。
宿主机的 DNAT 规则不用改，仍然是 `8190:8193`。

## 为什么要直发，还要 10ms 分片

实测（都是真实 RTP 包，不是估算）：

1. **原来的爆音起点**：PulseAudio 包时间戳会抖/倒退，libopus 因此丢帧。
   `asetpts=N/SR/TB` 修好后，5 秒 250/250 包、间隔稳定 20ms，`Queue input is
   backward in time` 消失。
2. **仍然残留的“成串”**：即使改成 UDP 直发，ffmpeg 的 PulseAudio 输入默认约
   50ms 一块，编码器一次吐出 2~3 帧——本机回环实测 320 个包里，**204 个到达
   间隔 <2ms，最大间隔 100ms**。这跟 RTSP/TCP 无关，是采集分片造成的。
3. **20ms 分片阶段**：`-fragment_size 3840` 后 320 包 / 6.4s = 50.0 包/秒，
   序号 0 缺口、时间戳 0 处非 960 步进，最大到达间隔 40ms。
4. **最终对齐 Selkies（192k / 10ms / application=audio）**：
   `-fragment_size 1920 -frame_duration 10`，走公网候选
   `45.12.52.180:8193` 实测 399 包 / 3.99s = **100.0 包/秒**，序号 0 缺口，
   时间戳 **0 处非 480**（10.0ms），最大到达间隔 **24ms**，负载 257~273 字节。
   对应 Selkies 的 `--audio-bitrate=192000 --audio-frame-duration-ms=10`。
5. **真实浏览器**（headless Edge，WHEP + ICE + DTLS + SRTP 全走通）：
   `connectionState=connected`，收到 245 包 / 165893 字节、1 条音轨
   （浏览器路径已验证；最终参数已改为 10ms，路径不变）。
6. **go 后端（当前默认）**：同一台 1 vCPU 容器里，gopus stereo 48k/10ms/192k、
   complexity 10，1000 帧 = 10 秒音频编码耗时 **216 ms（2.16% 单核）**，
   平均 241 字节/包（**192.9 kbps**）；用 `jfreymuth/pulse` 实采
   `virtual_speaker.monitor` 2 秒，**199 帧 / 100.0 包/秒 / 192.9 kbps**。
   没有 ffmpeg，也没有 8195 回环。

## 构建

```sh
./build.sh
```

产物 `vnc-audio-rtc`（约 13MB，静态）。`gopus` 和 `jfreymuth/pulse` 都是纯 Go，
构建不需要 cgo/libopus 头文件。`gopus` 当前是 v0.2.2（pre-1.0，BSD-3），
按 libopus 1.6.1 / RFC 8251 向量校验；保留 ffmpeg 后端就是为了随时回退。
主安装脚本 `vnc_desktop_setup.sh` 会检测
这个文件：存在就安装本服务并把 nginx `/whep` 指到 `127.0.0.1:6092/whep`；
不存在就保持原来的 MediaMTX 路径。

## 安装（主安装脚本会自动做）

```sh
install -m0755 vnc-audio-rtc /usr/local/bin/vnc-audio-rtc
install -m0755 desktop-audio-rtc-publish /usr/local/bin/desktop-audio-rtc-publish
# 音频后端：go（默认）或 ffmpeg
cat > /etc/default/vnc-audio-rtc <<'EOF'
AUDIO_BACKEND=go
EOF
# 单元文件由安装脚本生成（公网 IP / bind IP 从 /etc/default/vnc-rtc 取）
systemctl daemon-reload
systemctl enable --now vnc-audio-rtc
```

切换后端不用重装：

```sh
sed -i 's/^AUDIO_BACKEND=.*/AUDIO_BACKEND=ffmpeg/' /etc/default/vnc-audio-rtc
systemctl restart vnc-audio-rtc
# 看当前后端
curl -s http://127.0.0.1:6092/health
```

nginx 的 `/whep` 需要指向本服务：

```nginx
location = /whep {
    proxy_pass http://127.0.0.1:6092/whep;
    ...
}
```

`/whep-av`（`/live` 页面的音视频）保持指向 MediaMTX，不受影响。

## 行为

- **后端**：`AUDIO_BACKEND=go`（默认）走进程内 PulseAudio + gopus；
  `AUDIO_BACKEND=ffmpeg` 走原来的 `desktop-audio-rtc-publish` + 8195 RTP。
- **按需编码**：第一个听众接入才启动采集；最后一个离开 5 秒后停掉。
  没有听众时 0 CPU。
- **多听众**：所有 PeerConnection 共享同一条音轨（go：
  `TrackLocalStaticSample`；ffmpeg：`TrackLocalStaticRTP`），一份编码扇出，
  不重复编码。
- **ICE**：所有连接复用一个 UDP mux 端口（8193），不会几个听众就把端口占满。
- **码率/帧长**：两种后端都读 `/etc/default/desktop-audio` 的
  `DESKTOP_AUDIO_BITRATE`（默认 192k），帧长固定 10ms。go 后端用 gopus
  `ApplicationAudio`，ffmpeg 后端用 `libopus -application audio -frame_duration 10`。
  安装时只会把 192k 作为默认值，仍保留用户已有选择。
- **采集源**：`DESKTOP_AUDIO_SRC`（默认 `virtual_speaker.monitor`）。
  码率和采集源在每次按需启动时重读 `/etc/default/desktop-audio`，改完下一个听众
  生效；切换后端因为音轨类型不同，需要 restart。
- **健康检查**：`curl http://127.0.0.1:6092/health` 会返回 `backend`、
  `publisher`、`opus_packets`、`opus_bytes` 等；ffmpeg 后端另有 `rtp_packets`。

## 回退

只切回 ffmpeg 后端（服务、`/whep`、8193 都不变）：

```sh
sed -i 's/^AUDIO_BACKEND=.*/AUDIO_BACKEND=ffmpeg/' /etc/default/vnc-audio-rtc
systemctl restart vnc-audio-rtc
```

完全回退到 MediaMTX：

```sh
systemctl disable --now vnc-audio-rtc
# /whep 改回 http://127.0.0.1:8889/desktop/whep
openresty -t && systemctl reload openresty
```

MediaMTX 的 `desktop` 路径和 `desktop-audio-publish` 都还在，回退不需要重装。
