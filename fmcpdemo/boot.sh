#!/bin/bash
# f_mcp demo：一个进程跑服务端，另一个进程跑客户端（含 /mcp 与 /mcp/sse）。
#
#   ./boot.sh build
#   ./boot.sh runServer [port]
#   ./boot.sh runClient [port]
#   ./boot.sh e2e [port]
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
TARGET=${TARGET:-"$ROOT/target"}
SERVER_PORT=${2:-18082}

exports() {
    local dirs
    dirs=$(find "$TARGET" -name 'lib*.so' -printf '%h\n' 2>/dev/null | sort -u | tr '\n' ':')
    export LD_LIBRARY_PATH="${dirs}${HOME}/.cjpm/libs/fboot:${LD_LIBRARY_PATH}"
}

build() {
    (cd "$ROOT" && cjpm build)
}

runServer() {
    exports
    export mvc_port=$SERVER_PORT
    export mvc_maxRequestBodySize=67108864
    export mcp_publicBaseUrl=http://127.0.0.1:${SERVER_PORT}
    echo "SERVER port=$mvc_port target=$TARGET"
    exec fboot run "$TARGET" --dylibPattern='(mcpserver)'
}

runClient() {
    exports
    export mvc_port=$((SERVER_PORT + 1))
    export mcp_demo_port=$SERVER_PORT
    echo "CLIENT server=$mcp_demo_port clientMvcPort=$mvc_port"
    fboot run "$TARGET" --dylibPattern='(mcpclient)'
}

waitServer() {
    for _ in $(seq 1 120); do
        if curl -s -o /dev/null -X POST -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}' \
            "http://127.0.0.1:${SERVER_PORT}/mcp"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

httpChecks() {
    local base="http://127.0.0.1:${SERVER_PORT}"
    local discover='{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}'
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' -d "$discover" "$base/mcp")
    [[ "$code" == "200" ]] || { echo "MCP discover expected 200, got $code" >&2; return 1; }
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}' "$base/mcp")
    [[ "$code" == "200" ]] || { echo "MCP missing meta expected 200, got $code" >&2; return 1; }
    if ! timeout 3 curl -s -D - -o /dev/null -H 'Accept: text/event-stream' "$base/mcp/sse?topics=tools/list_changed" | grep -qi 'content-type: text/event-stream'; then
        echo "MCP SSE did not return text/event-stream" >&2
        return 1
    fi
    echo "MCP_HTTP_CHECKS_OK discover/missing-meta/sse"
}

e2e() {
    if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
        build
    fi
    exports
    export mvc_port=$SERVER_PORT
    export mcp_publicBaseUrl=http://127.0.0.1:${SERVER_PORT}
    fboot run "$TARGET" --dylibPattern='(mcpserver)' >"$ROOT/server.log" 2>&1 &
    local pid=$!
    if ! waitServer; then
        echo "server did not start; log:"
        cat "$ROOT/server.log"
        kill "$pid" 2>/dev/null || true
        return 1
    fi
    local code=0
    httpChecks || code=$?
    if [[ $code -eq 0 ]]; then
        "$ROOT/boot.sh" runClient "$SERVER_PORT" || code=$?
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if [[ $code -ne 0 ]]; then
        echo "server log:"
        cat "$ROOT/server.log"
    fi
    return $code
}

case "$1" in
build) build ;;
runServer) runServer ;;
runClient) runClient ;;
e2e) e2e ;;
*)
    echo "usage: $0 {build|runServer [port]|runClient [port]|e2e [port]}" >&2
    exit 2
    ;;
esac
