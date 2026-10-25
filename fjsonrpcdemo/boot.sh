#!/bin/bash
# f_jsonrpc demo：一个进程跑服务端，另一个进程跑客户端。
#
#   ./boot.sh build
#   ./boot.sh runServer [port]
#   ./boot.sh runClient [port]
#   ./boot.sh e2e [port]
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
TARGET=${TARGET:-"$ROOT/target"}
SERVER_PORT=${2:-18080}

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
    echo "SERVER port=$mvc_port target=$TARGET"
    exec fboot run "$TARGET" --dylibPattern='(jsonrpcserver)'
}

runClient() {
    exports
    export mvc_port=$((SERVER_PORT + 1))
    export rpc_demo_port=$SERVER_PORT
    echo "CLIENT server=$rpc_demo_port clientMvcPort=$mvc_port"
    fboot run "$TARGET" --dylibPattern='(jsonrpcclient)'
}

waitServer() {
    for _ in $(seq 1 120); do
        if curl -s -o /dev/null "http://127.0.0.1:${SERVER_PORT}/rpc"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

checkContains() {
    local expected=$1
    shift
    local body
    body=$(curl -s "$@")
    if [[ "$body" != *"$expected"* ]]; then
        echo "HTTP body check failed: expected '$expected', got '$body'" >&2
        return 1
    fi
}

checkStatus() {
    local expected=$1
    shift
    local actual
    actual=$(curl -s -o /dev/null -w '%{http_code}' "$@")
    if [[ "$actual" != "$expected" ]]; then
        echo "HTTP check failed: expected $expected, got $actual: $*" >&2
        return 1
    fi
}

httpChecks() {
    local base="http://127.0.0.1:${SERVER_PORT}"
    local payload='{"jsonrpc":"2.0","id":1,"method":"knowledge.search","params":["x"]}'
    checkContains '"result":"found:x"' -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' -d "$payload" "$base/rpc"
    checkStatus 415 -X POST -H 'Accept: application/json' -d "$payload" "$base/rpc"
    checkStatus 406 -X POST -H 'Content-Type: application/json' -H 'Accept: text/plain' -d "$payload" "$base/rpc"
    checkStatus 200 -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -d '{"jsonrpc":"2.0","method":"knowledge.touch","params":{}}' "$base/rpc"
    checkStatus 200 -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -d '{not-json' "$base/rpc"
    checkContains '"result":3' -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -d '{"jsonrpc":"2.0","id":7,"method":"knowledge.add","params":{"a":1,"b":2}}' "$base/rpc/knowledge"
    echo "JSONRPC_HTTP_CHECKS_OK 200/415/406/notification/parse-error/namespace"
}

e2e() {
    if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
        build
    fi
    exports
    export mvc_port=$SERVER_PORT
    fboot run "$TARGET" --dylibPattern='(jsonrpcserver)' >"$ROOT/server.log" 2>&1 &
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
