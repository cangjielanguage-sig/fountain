#!/bin/bash
# fdbm 启停脚本
#
# 用法：
#   ./fdbm.sh start      # 启动（按下面 export 的配置），等待端口就绪后返回
#   ./fdbm.sh stop       # 停止（只发 SIGTERM，走 fdbm 的优雅停止）
#   ./fdbm.sh restart    # 重启
#
# 配置约定：
#   - 只把**不配置就无法启动**的项写成有效 export（fdbm_db 与每个节点的 driver/database）；
#   - 能取默认值的项一律注释掉，注释里写明默认值与语义，需要时取消注释即可；
#   - 所有配置都经 f_config 读取，因此也可以改用环境变量或 `Config.set` 传入。
set -u

# ===========================================================================
# 一、服务与进程
# ===========================================================================
# 监听端口。默认 8112；取值 1..65535。
# export fdbm_port=8112
# 启动脚本路径。EXPORT 语句会把配置写回该脚本的 managed 区块。默认 ./boot.sh。
# export fdbm_bootScript='./boot.sh'
# 物理驱动目录。目录里必须**恰好一个**驱动动态库，其注册名要等于各节点的 fdbm_db_driver_<node>。
# 默认 ./driver。
# export fdbm_driverDir='./driver'
# 自定义扩展动态库目录（自定义分库算法 / ID 生成器）。默认 ./custom；目录不存在表示没有扩展。
# export fdbm_customDir='./custom'
# TCP 有效性检查周期。默认 30s。注意：单条语句执行期间读不到对端心跳，
# 执行时长超过约 3 倍该值会被判定死链断开（超长语句请调大）。
# export fdbm_checkDuration='30s'
# 连续检查失败次数阈值。默认 3。
# export fdbm_unavailableChecked=3
# 断连会话巡检周期。默认 30s（f_net 没有断连回调，靠巡检回收会话与游标）。
# export fdbm_sessionSweepInterval='30s'
# 优雅停止时等待在途请求的上限。默认 30s。
# export fdbm_shutdownTimeout='30s'

# ===========================================================================
# 二、物理节点与凭据（必填项在这一组）
# ===========================================================================
# 【必填】节点清单，格式 <节点名>@<主机>:<端口>，多个节点用 ; 分隔。
export fdbm_db='node0@127.0.0.1:5432'
# 【必填】节点 node0 的物理驱动**注册名**（不是库名），例如 postgres / mysql / mariadb。
export fdbm_db_driver_node0='postgres'
# 【必填】节点 node0 承载的物理库，逗号分隔（每库一个连接池）。
export fdbm_db_database_node0='db0,db1'
# 节点 node0 的用户名。默认空（不影响启动，连不上物理库时启动自检才报错）。
# export fdbm_db_username_node0='postgres'
# 节点 node0 的密码。默认空。
# export fdbm_db_password_node0='postgres'

# ===========================================================================
# 三、逻辑库映射
# ===========================================================================
# 逻辑库 → 物理库列表。只有这里显式声明的名字才是逻辑库（物理库名不会自动成为逻辑库）；
# 被 fdbm_partition__<表> 引用但未显式声明的逻辑库，隐式包含全部物理库；
# 一个都不声明时，排序首个物理库成为唯一逻辑库（会记 WARN）。
# export fdbm_db_logicalDatabase_order='db0,db1'

# ===========================================================================
# 四、连接池（每个物理库一个池）
# ===========================================================================
# 初始连接数。默认 1。
# export fdbm_databasePoolInitSize=1
# 最小连接数。默认 1。
# export fdbm_databasePoolMinSize=1
# 最大连接数。默认 1（并发长游标/长事务多时要调大）。
# export fdbm_databasePoolMaxSize=1
# 建池时是否检查连接有效性。默认 false。
# export fdbm_databasePoolCheckOnCreation=false
# 借出连接时是否检查有效性。默认 true。
# export fdbm_databasePoolCheckOnBorrowing=true
# 归还连接时是否检查有效性。默认 false。
# export fdbm_databasePoolCheckOnReturning=false
# 连接空闲超时（秒）。默认 0（不过期）。
# export fdbm_databasePoolIdleTimeout=0
# 连接最长存活时间（秒）。默认 86400。
# export fdbm_databasePoolConnectionLife=86400
# 有效性检查间隔（秒）。默认 300。
# export fdbm_databasePoolCheckInterval=300
# 取连接超时（毫秒）。默认 50。
# export fdbm_databasePoolConnectTimeout=50
# 池耗尽等待上限（毫秒）。默认 30000；0 表示无限等待。
# export fdbm_databasePoolMaxWaiting=30000
# 有效性检查 SQL。默认 'select 1'。
# export fdbm_databasePoolCheckSql='select 1'

# ===========================================================================
# 五、负载均衡与读写权重（读写分离就靠这一组）
# ===========================================================================
# 节点选择算法：random（默认）| roundrobin。
# export fdbm_loadbalance='random'
# 节点读写权重，格式 w,<写权重>;r,<读权重>（也可写成 w=<n>），0 表示不参与该方向；默认 w,1;r,1。
# 例：主库节点 w,1;r,0（只写）、从库节点 w,0;r,1（只读）。
# export fdbm_loadbalance_weight_node0='w,1;r,0'
# 库级权重优先于节点级（同一节点上不同物理库可以有不同权重）。
# export fdbm_loadbalance_weight_node0__db0='w,0;r,1'

# ===========================================================================
# 六、分库与全局表
# ===========================================================================
# step 算法的分片步长。默认 10000000；必须为正。
# export fdbm_partition_step=10000000
# 分库规则：<逻辑库>,<算法>,<分库列>。算法：step / hash / std / crc16 / crc32 / crc64 / murmur / substr。
# export fdbm_partition__orders='order,hash,id'
# substr 算法的参数：<起始位置>,<长度>,<哈希>（哈希：std / hash / crc16 / crc32 / crc64 / murmur）。
# export fdbm_partition_substr__accounts='0,4,crc32'
# 全局表：写入（INSERT/UPDATE/DELETE）广播到该逻辑库的全部物理库，读只取一份副本。
# 值必须是逻辑库名（可以是显式声明的，或由分库规则建立的）。
# export fdbm_global__dict='order'

# ===========================================================================
# 七、ID 生成
# ===========================================================================
# 生成器与参数：uuid[,1|4|6|7]（默认 uuid,1）| snowflake[,0..1023] | sequence | 自定义扩展名。
# export fdbm_idmaker='uuid,1'
# sequence 生成器的分配库，可写逻辑库名或物理库名。默认取默认逻辑库排序后的首个物理库。
# export fdbm_sequenceDatabase='db0'

# ===========================================================================
# 八、分库缓存
# ===========================================================================
# 是否开启分库缓存。默认 true。
# export fdbm_cache=true
# 缓存过期时间（如 30s、5m）。留空或注释掉表示永不过期。
# export fdbm_cache_expire=''
# 缓存容量上限（0 = 不限制；超限时不再写入新键，既有键照常命中）。
# export fdbm_cache_size=0
# 缓存落地目录。默认 ./cache。
# export fdbm_cachePath='./cache'

# ===========================================================================
# 九、日志（f_log 的配置，不属于 fdbm 的配置项）
# ===========================================================================
# 控制台日志器名称；脚本把标准输出重定向到 fdbm.log，所以日志就落在该文件里。
export logger_appender_console='FdbmConsole'
# 日志级别：DEBUG / INFO / WARN / ERROR。
export logger_appender_FdbmConsole_level='INFO'
# 日志格式：%level 级别、%name 记录器名、%d{...} 时间、%tid 线程、%pid 进程、%m 消息。
export logger_appender_FdbmConsole_pattern='[%level-%name]%m'

# ===========================================================================
# 十、协议（f_protocol 的配置，不属于 fdbm 的配置项）
# ===========================================================================
# 【必填】本机在集群内的唯一主机号。MessageID 拒绝 hostId=0：
# (pid, tid, 时间戳) 跨机器会重复，集群维度只能靠 hostId 区分。
export protocol_hostId="${protocol_hostId:-1}"

# ===========================================================================
# 进程管理（以下一般不需要修改）
# ===========================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

PID_FILE="$SCRIPT_DIR/fdbm.pid"
LOG_FILE="$SCRIPT_DIR/fdbm.log"
PORT="${fdbm_port:-8112}"

# 可执行文件：$FDBM_BIN > PATH > ~/.cjpm/bin/fdbm > 仓库内 cjpm 产物
FDBM_BIN="${FDBM_BIN:-$(command -v fdbm 2>/dev/null || true)}"
if [[ -z "$FDBM_BIN" && -x "$HOME/.cjpm/bin/fdbm" ]]; then
    FDBM_BIN="$HOME/.cjpm/bin/fdbm"
fi
if [[ -z "$FDBM_BIN" && -x "$SCRIPT_DIR/target/release/bin/main" ]]; then
    FDBM_BIN="$SCRIPT_DIR/target/release/bin/main"
fi
if [[ -z "$FDBM_BIN" ]]; then
    echo "找不到 fdbm 可执行文件：先 cjpm install（或 cjpm build），或 export FDBM_BIN=..." >&2
    exit 1
fi
FDBM_BIN="$(cd "$(dirname "$FDBM_BIN")" && pwd)/$(basename "$FDBM_BIN")"

# 动态库路径：安装目录的 libs/fdbm、仓库构建产物同级的 <pkg>@<org> 目录，
# 以及（非交互环境不会自动加载的）仓颉运行时/标准库与扩展库
LIBS="$HOME/.cjpm/libs/fdbm"
BIN_DIR="$(dirname "$FDBM_BIN")"
REPO_DEPS="$(find "$BIN_DIR/.." -maxdepth 1 -type d -name '*@*' 2>/dev/null | tr '\n' ':')"
RUNTIME_LIBS=""
if [[ -n "${CANGJIE_HOME:-}" ]]; then
    RUNTIME_LIBS="$(ls -d "$CANGJIE_HOME"/runtime/lib/*/ 2>/dev/null | tr '\n' ':')"
fi
export LD_LIBRARY_PATH="$BIN_DIR:${REPO_DEPS}${LIBS}:${RUNTIME_LIBS}${CANGJIE_STDX_DYNAMIC_PATH:-}:${LD_LIBRARY_PATH:-}"

is_running() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

port_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null
}

start() {
    if is_running; then
        echo "fdbm is already running (pid $(cat "$PID_FILE"))"
        return 0
    fi
    if port_open; then
        echo "端口 $PORT 已被其它进程占用，拒绝启动（fdbm_port 可改）" >&2
        return 1
    fi
    # setsid：脱离当前会话，避免脚本所在终端关闭时把 fdbm 一起带走；
    # pid 由内层 shell 自己写（setsid 在交互 shell 里可能 fork，$! 不可靠）
    (
        exec setsid bash -c "echo \$\$ > '$PID_FILE'; exec '$FDBM_BIN'"
    ) >> "$LOG_FILE" 2>&1 < /dev/null &
    local i=0
    while (( i < 300 )); do
        if port_open; then
            echo "fdbm started (pid $(cat "$PID_FILE" 2>/dev/null), port $PORT, log $LOG_FILE)"
            return 0
        fi
        # 前 2s 是宽限期：子进程还没写出 pid 文件，不能据此判死
        if (( i >= 20 )) && ! is_running; then
            echo "fdbm 启动失败，日志尾部：" >&2
            tail -20 "$LOG_FILE" >&2
            return 1
        fi
        sleep 0.1
        i=$((i + 1))
    done
    if is_running; then
        # 进程还活着（例如首次冷启动、/mnt 上的仓库构建产物加载较慢）：不误判为失败
        echo "fdbm 进程已在运行 (pid $(cat "$PID_FILE"))，但 30s 内尚未监听 $PORT；" \
             "启动可能仍在进行，稍后用 ss -ltn 或日志确认：$LOG_FILE" >&2
        return 0
    fi
    echo "fdbm 未在 30s 内监听 $PORT，见 $LOG_FILE" >&2
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
    # 只发 SIGTERM：f_base 的 ExitCallbacks 负责优雅停止（等在途、关会话与游标、关池、关缓存）
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
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "fdbm 未在 30s 内退出，已强制结束 (pid $pid)" >&2
    return 1
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    *)
        echo "usage: $0 {start|stop|restart}" >&2
        exit 2
        ;;
esac
