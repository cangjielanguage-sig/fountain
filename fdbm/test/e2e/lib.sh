#!/bin/bash
# fdbm e2e 共享工具（由 run.sh source；后端差异见 backends/*.sh）。
#
# 约定：调用方先设置 BACKEND / E2E / FDBM_ROOT / WORK，再调用这里的函数。

# 共享盘/多人同时编译时 LTO 很吃内存：默认 4 路，OOM 时调小（FDBM_E2E_BUILD_JOBS）。
BUILD_JOBS="${FDBM_E2E_BUILD_JOBS:-4}"

say() { printf '\n=== %s ===\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

pick_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_port() {
    local port="$1"; local tries=0
    while [ "$tries" -lt 100 ]; do
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            exec 3>&-
            return 0
        fi
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

# build_driver <bundle 目录> <期望的 .so 文件名>
build_driver() {
    local dir="$1"; local so="$2"
    cd "$dir"
    CANGJIE_STDX_PATH="$CANGJIE_STDX_DYNAMIC_PATH" cjpm build -j "$BUILD_JOBS" > "$WORK/driver-build.log" 2>&1 \
        || { tail -30 "$WORK/driver-build.log" >&2; fail "driver build failed in $dir"; }
    local found
    found="$(find target/release -name "$so" | head -1)"
    [ -n "$found" ] || fail "$so not found under $dir/target/release"
    cp "$found" "$WORK/driver/"
}

build_fdbm() {
    mkdir -p "$WORK/driver" "$WORK/custom" "$WORK/install"
    cd "$FDBM_ROOT"
    cjpm build -j "$BUILD_JOBS" > "$WORK/fdbm-build.log" 2>&1 \
        || { tail -30 "$WORK/fdbm-build.log" >&2; fail "fdbm build failed"; }
    rm -rf "$WORK/install"
    cjpm install -j "$BUILD_JOBS" --root "$WORK/install" > "$WORK/fdbm-install.log" 2>&1 \
        || { tail -30 "$WORK/fdbm-install.log" >&2; fail "fdbm install failed"; }
}

# start_server <port> <cache 目录> <export 脚本> <日志> [额外 env 文件]
# 公共环境 + backend_server_env（+ 额外 env）写入 env_<port>.sh，再以该环境启动 fdbm。
start_server() {
    local port="$1"; local cache="$2"; local export="$3"; local log="$4"; local extra="${5:-}"
    local envfile="$WORK/env_$port.sh"
    {
        echo "export fdbm_port=$port"
        echo "export fdbm_bootScript=$export"
        echo "export fdbm_driverDir=$WORK/driver"
        echo "export fdbm_customDir=$WORK/custom"
        echo "export fdbm_checkDuration=15s"
        echo "export fdbm_unavailableChecked=6"
        echo "export fdbm_sessionSweepInterval=2s"
        echo "export fdbm_shutdownTimeout=10s"
        echo "export fdbm_databasePoolInitSize=1"
        echo "export fdbm_databasePoolMinSize=1"
        echo "export fdbm_databasePoolMaxSize=4"
        echo "export fdbm_databasePoolCheckOnBorrowing=true"
        echo 'export fdbm_databasePoolCheckSql="select 1"'
        echo "export fdbm_databasePoolConnectTimeout=5000"
        echo "export fdbm_loadbalance=roundrobin"
        echo 'export fdbm_loadbalance_weight_name0="w,1;r,0"'
        echo 'export fdbm_loadbalance_weight_name1="w,0;r,1"'
        echo "export fdbm_partition_step=1000"
        echo 'export fdbm_partition__t_step="app,step,id"'
        echo 'export fdbm_partition__t_hash="app,hash,user_id"'
        echo 'export fdbm_partition__t_substr="app,substr,account_no"'
        echo 'export fdbm_partition__t_shard_probe="app,step,id"'
        echo 'export fdbm_partition_substr__t_substr="0,2,crc32"'
        echo 'export fdbm_global__dict="app"'
        echo 'export fdbm_global__t_global="app"'
        echo "export fdbm_idmaker=sequence"
        echo "export fdbm_sequenceDatabase=app"
        echo "export fdbm_cache=true"
        echo "export fdbm_cachePath=$cache"
        echo "export fdbm_cache_size=0"
        echo "export logger_appender_console=FdbmConsole"
        echo "export logger_appender_FdbmConsole_level=INFO"
        # 【必填】本机在集群内的唯一主机号：MessageID 拒绝 hostId=0
        echo "export protocol_hostId=1"
        backend_server_env
        if [ -n "$extra" ]; then
            cat "$extra"
        fi
    } > "$envfile"
    touch "$export"
    (
        set -a
        # shellcheck disable=SC1090
        . "$envfile"
        set +a
        export LD_LIBRARY_PATH="$WORK/install/libs/fdbm:$CANGJIE_STDX_DYNAMIC_PATH:$CANGJIE_HOME/runtime/lib/linux_aarch64_cjnative:${LD_LIBRARY_PATH:-}"
        exec "$WORK/install/bin/fdbm"
    ) > "$log" 2>&1 &
    local pid=$!
    echo "$pid" > "$WORK/fdbm_$port.pid"
    if ! wait_port "$port"; then
        tail -30 "$log" >&2
        fail "fdbm on port $port did not start"
    fi
    echo "fdbm started on $port (pid $pid)"
}

stop_server() {
    local port="$1"; local log="$2"
    local pidfile="$WORK/fdbm_$port.pid"
    [ -f "$pidfile" ] || return 0
    local pid; pid="$(cat "$pidfile")"
    kill -TERM "$pid" 2>/dev/null || true
    local tries=0
    while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 100 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        fail "fdbm on port $port did not stop"
    fi
    grep -q "fdbm is stopping" "$log" || fail "no graceful-stop marker in $log"
    echo "fdbm stopped on $port"
}

# check_client_log <日志> <标签>
check_client_log() {
    local log="$1"; local label="$2"
    grep -E "^(PASS|FAIL) " "$log" | tail -20 || true
    grep -q "^E2E_DONE$" "$log" || { tail -30 "$log" >&2; fail "$label aborted before finishing"; }
    grep -q "^checks=.*failures=0$" "$log" || { tail -30 "$log" >&2; fail "$label reported failures"; }
}
