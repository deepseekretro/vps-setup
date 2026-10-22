# vnc-wsproxy

一个进程把多个 WebSocket 监听端口映射到多个 VNC TCP 端口。只做字节搬运，
RFB / 剪贴板 / 共享连接都由 noVNC 和 VNC 服务端自己处理，TLS 由前面的 nginx 终止。

```sh
vnc-wsproxy \
  -map 127.0.0.1:6081=127.0.0.1:5901 \
  -map 127.0.0.1:6082=127.0.0.1:5902 \
  -map 127.0.0.1:6083=127.0.0.1:5903
```

- `-map` 可重复；`6081=5901` 会补成 `127.0.0.1:6081=127.0.0.1:5901`。
- 只接受 WebSocket 升级请求（noVNC 的 `binary` 子协议），普通 HTTP 返回 426。
- 目标 VNC 端口没起来时，握手前返回 502，noVNC 会显示失败而不是闪断。
- 25s 一次 WS ping，90s 无 pong/数据就收连接（浏览器会自动回 pong）。

重新编译：`./build.sh`（需要 Go 1.21+，依赖只有一个 gorilla/websocket）。
