#!/bin/sh
# 重新编译单进程 WebSocket 网关（产物 vnc-wsproxy，约 6MB，静态链接）
set -eu
cd "$(dirname "$0")"
GO="${GO:-/usr/local/go/bin/go}"
CGO_ENABLED=0 "$GO" build -trimpath -ldflags "-s -w" -o vnc-wsproxy .
echo "built: $(pwd)/vnc-wsproxy"
