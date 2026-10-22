#!/bin/sh
# 构建 vnc-audio-rtc（纯 Go 静态链接；gopus/pulse 不需要 cgo）
set -eu
cd "$(dirname "$0")"

GO_BIN="${GO_BIN:-}"
if [ -z "${GO_BIN}" ]; then
    if command -v go >/dev/null 2>&1; then
        GO_BIN=go
    else
        GO_BIN=/usr/local/go/bin/go
    fi
fi

CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "${GO_BIN}" build -trimpath -ldflags "-s -w" -o vnc-audio-rtc .
ls -lh vnc-audio-rtc
