#!/bin/bash
# §3.2 / MVC-13 端到端冒烟（fdemo 版）
#
# 用法（在 WSL Ubuntu-24.04 里、工作区根的 fdemo 目录下）：
#     bash ./ws_smoke.sh             # 默认先 build 再 launch，最后做握手断言
#     bash ./ws_smoke.sh --no-build  # 跳过 build（产物已存在时）
#
# 断言：
#   ① WS 握手（GET + Upgrade: websocket + Sec-WebSocket-*）⇒ 响应首行 HTTP/1.1 101 Switching Protocols
#      （修 MVC-13 之前是 415；`MVC-L12` 修之前是 405）
#   ② 同一路径的普通 GET（无 Upgrade 头）⇒ 响应首行 HTTP/1.1 405 Method Not Allowed
#      （证明修复的行为变化范围最小）
#
# 依赖：本机 PostgreSQL 凭据来自 ~/.bashrc 的 POSTGRES / POSTGRES_USERNAME / POSTGRES_PASSWORD
# （fdemo 的 ORM 用 `orm_drivers=postgres`，连不上库时 boot 会失败）。
set -u

PORT=${mvc_port:-8080}
HOST=127.0.0.1
LOG=./ws_smoke_fdemo.log
DO_BUILD=1
[ "${1:-}" = "--no-build" ] && DO_BUILD=0

cd "$(dirname "$0")" || exit 9

if [ "$DO_BUILD" = "1" ]; then
    echo "=== build fdemo（较慢，日志 build 段） ==="
    bash ./boot.sh build > "$LOG" 2>&1 || {
        echo "BUILD FAILED，尾部日志："
        tail -30 "$LOG"
        exit 1
    }
fi

echo "=== launch fdemo（后台，最多跑 180s） ==="
timeout 180 bash ./boot.sh launch >> "$LOG" 2>&1 &
APP_PID=$!

# 等服务端口就绪（最多 60s）
ready=0
for i in $(seq 1 60); do
    if (echo > /dev/tcp/$HOST/$PORT) 2>/dev/null; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" != "1" ]; then
    echo "服务未在 ${PORT} 就绪，尾部日志："
    tail -30 "$LOG"
    kill $APP_PID 2>/dev/null
    exit 1
fi
echo "服务已就绪：${HOST}:${PORT}"

# ① WS 握手
handshake() {
    local extra="$1"
    exec 3<>/dev/tcp/$HOST/$PORT || return 1
    printf 'GET /ws/smoke HTTP/1.1\r\nHost: %s:%s\r\n%sSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n' \
        "$HOST" "$PORT" "$extra" >&3
    head -1 <&3
    exec 3<&-
    exec 3>&-
}
ws_line=$(handshake 'Upgrade: websocket\r\nConnection: Upgrade\r\n')
plain_line=$(handshake '')
echo "WS 握手响应首行 = ${ws_line}"
echo "普通 GET 响应首行 = ${plain_line}"

kill $APP_PID 2>/dev/null
wait $APP_PID 2>/dev/null

case "$ws_line" in
    *"101"*)
        case "$plain_line" in
            *"405"*) echo "SMOKE PASS：握手 101 ✔、普通 GET 405 ✔"; exit 0 ;;
            *) echo "SMOKE FAIL：握手已是 101，但普通 GET 不是 405（实际：${plain_line}）"; exit 1 ;;
        esac ;;
    *) echo "SMOKE FAIL：握手不是 101（实际：${ws_line}）"; exit 1 ;;
esac
