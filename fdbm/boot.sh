#!/bin/bash
# fdbm 启动脚本：配置 + start / stop / status / restart
# 配置区由 fdbm 自动生成；请勿手工编辑 managed 区块

# ==== fdbm managed exports (auto-generated; do not edit) ====

# ---- 1. 服务与进程 ----
# 监听端口、启动脚本、驱动/自定义扩展目录、心跳与优雅停止
# 监听端口
export fdbm_port='8112'
# 启动脚本路径
export fdbm_bootScript='./boot.sh'
# 物理驱动目录
export fdbm_driverDir='./driver'
# 自定义扩展动态库目录
export fdbm_customDir='./custom'
# 心跳检查周期
export fdbm_checkDuration='30s'
# 连续检查失败阈值
export fdbm_unavailableChecked='3'
# 断连会话巡检周期
export fdbm_sessionSweepInterval='30s'
# 优雅停止等待上限
export fdbm_shutdownTimeout='30s'

# ---- 2. 物理节点与凭据 ----
# 节点清单，以及每节点的驱动、物理库与凭据
# 物理节点清单
export fdbm_db='name0@127.0.0.1:3306;name1@127.0.0.1:3307'
# 节点 name0：物理驱动名
export fdbm_db_driver_name0='mysql'
# 节点 name0：承载的物理库（逗号分隔）
export fdbm_db_database_name0='db_0,db_1'
# 节点 name0：用户名
export fdbm_db_username_name0='root'
# 节点 name0：密码（敏感，勿提交仓库）
export fdbm_db_password_name0=''
# 节点 name1：物理驱动名
export fdbm_db_driver_name1='mysql'
# 节点 name1：承载的物理库（逗号分隔）
export fdbm_db_database_name1='db_2,db_3'
# 节点 name1：用户名
export fdbm_db_username_name1='root'
# 节点 name1：密码（敏感，勿提交仓库）
export fdbm_db_password_name1=''

# ---- 3. 逻辑库映射 ----
# 逻辑库 → 物理库列表；未配置的逻辑库包含全部物理库
# 逻辑库 order → 物理库列表
export fdbm_db_logicalDatabase_order='db_0,db_1,db_2,db_3'

# ---- 4. 连接池 ----
# 每物理库一个池；未出现的键取默认值（见 §3.4）
# 连接池：初始连接数
export fdbm_databasePoolInitSize='1'
# 连接池：最小连接数
export fdbm_databasePoolMinSize='1'
# 连接池：最大连接数
export fdbm_databasePoolMaxSize='1'
# 连接池：获取连接时是否检查连接有效性
export fdbm_databasePoolCheckOnBorrowing='true'
# 连接池：检查连接有效性的 SQL
export fdbm_databasePoolCheckSql='select 1'

# ---- 5. 负载均衡与读写权重 ----
# 节点选择算法与读写权重；库级优先于节点级
# 节点选择算法：random | roundrobin
export fdbm_loadbalance='random'

# ---- 6. 分库与全局表 ----
# 分库规则、子串参数与全局表；表名写在 __ 后
# step 分库的步长
export fdbm_partition_step='10000000'

# ---- 7. ID 生成 ----
# 生成器类型/参数与 sequence 分配库
# ID 生成器与参数
export fdbm_idmaker='uuid,4'
# sequence 分配库
export fdbm_sequenceDatabase='db_0'

# ---- 8. 分库缓存 ----
# 开关、过期、容量与 f_store 落地目录
# 是否开启分库缓存
export fdbm_cache='true'
# 缓存过期时间（空=永久）
export fdbm_cache_expire=''
# 缓存容量上限（0=不限制）
export fdbm_cache_size='0'
# f_store 落地目录
export fdbm_cachePath='./cache'

# ==== fdbm managed exports end ====

# ---------------------------------------------------------------------------
# 日志（不属于 fdbm 配置项，不会被 managed 区块整理）
# ---------------------------------------------------------------------------
export logger_appender_console='FdbmConsole'
export logger_appender_FdbmConsole_level='INFO'
# %level 日志级别 / %name 日志名称 / %d{...} 时间 / %m 消息
export logger_appender_FdbmConsole_pattern='[%level-%name]%m'

# ---------------------------------------------------------------------------
# 协议（f_protocol 的配置，不属于 fdbm，不会被 managed 区块整理）
# ---------------------------------------------------------------------------
# 【必填】本机在集群内的唯一主机号。MessageID 拒绝 hostId=0：
# (pid, tid, 时间戳) 跨机器会重复，集群维度只能靠 hostId 区分。
export protocol_hostId="${protocol_hostId:-1}"

# ---------------------------------------------------------------------------
# 进程管理（以下内容不会被 fdbm 改写）
# ---------------------------------------------------------------------------
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

PID_FILE="$SCRIPT_DIR/fdbm.pid"
LOG_FILE="$SCRIPT_DIR/fdbm.log"

# 非交互环境（systemd / 容器）不会加载 envsetup：显式给出可执行文件与动态库路径
FDBM_BIN="${FDBM_BIN:-$(command -v fdbm 2>/dev/null || true)}"
if [[ -z "$FDBM_BIN" ]]; then
    FDBM_BIN="$HOME/.cjpm/bin/fdbm"
fi
if [[ -d "$HOME/.cjpm/libs/fdbm" ]]; then
    export LD_LIBRARY_PATH="$HOME/.cjpm/libs/fdbm${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

is_running() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

port_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/$fdbm_port") 2>/dev/null
}

start() {
    if is_running; then
        echo "fdbm is already running (pid $(cat "$PID_FILE"))"
        return 0
    fi
    if [[ ! -x "$FDBM_BIN" ]]; then
        echo "fdbm executable not found: $FDBM_BIN" >&2
        return 1
    fi
    nohup "$FDBM_BIN" >>"$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" >"$PID_FILE"
    local i=0
    while (( i < 100 )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "fdbm exited during startup; see $LOG_FILE" >&2
            rm -f "$PID_FILE"
            return 1
        fi
        if port_open; then
            echo "fdbm started (pid $pid, port $fdbm_port)"
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    echo "fdbm did not open port $fdbm_port in time; see $LOG_FILE" >&2
    return 1
}

stop() {
    if ! is_running; then
        echo "fdbm is not running"
        rm -f "$PID_FILE"
        return 0
    fi
    local pid
    pid="$(cat "$PID_FILE")"
    # 只用 SIGTERM：f_base 的 ExitCallbacks 保证走优雅停止（等在途、关会话、关池、关缓存）
    kill -15 "$pid" 2>/dev/null || true
    local i=0
    while (( i < 300 )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            echo "fdbm stopped (pid $pid)"
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    echo "fdbm did not stop within 30s (pid $pid)" >&2
    return 1
}

status() {
    if is_running; then
        local pid
        pid="$(cat "$PID_FILE")"
        if port_open; then
            echo "fdbm is running (pid $pid, port $fdbm_port)"
        else
            echo "fdbm process is alive but port $fdbm_port is not open (pid $pid)"
        fi
        return 0
    fi
    echo "fdbm is stopped"
    return 3
}

restart() {
    stop
    start
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    status) status ;;
    restart) restart ;;
    *)
        echo "usage: $0 {start|stop|status|restart}" >&2
        exit 2
        ;;
esac
