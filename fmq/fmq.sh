#!/bin/bash
# fmq 启停脚本：start | stop | restart
#
#   bash fmq.sh start     后台启动 fmq server（pid 写 fmq.pid，输出追加到 fmq.log）
#   bash fmq.sh stop      SIGTERM 优雅停止（走 f_base 的退出钩子：关服务、刷队列、落位点）
#   bash fmq.sh restart   先 stop 再 start
#
# 配置方式：直接在本脚本下方「配置项」区取消注释并改值（等价于 export 环境变量）。
# 约定：不配置就不能启动的项保持 export；有默认值的项一律注释掉，取消注释即覆盖默认值。
# 注意：fmq 的 metas/ 目录由「可执行文件所在目录」推导 —— 用 $FMQ_BIN 指向别处 = 换了一套元数据。
set -u

# ---------------------------------------------------------------------------
# 配置项（fmq 服务端）
# ---------------------------------------------------------------------------

# 集群节点表（**必填**，无默认值）：逗号分隔的 host:port。
# 它既是客户端节点表，也是服务端集群节点表；本机端口（mqServer_port）必须在表中出现且只出现一次，
# 否则启动直接报错退出。单节点写一个即可；多节点写全部节点（各节点顺序必须一致）。
export mqClient_hosts='127.0.0.1:2350'

# 本机监听端口（默认 2350）。服务端用它在上面的节点表里定位自己的下标。
#export mqServer_port='2350'

# 消息确认超时（默认 10s）。投递后超过该时长仍未 ack 的消息会被重新投递（at-least-once）。
#export mqServer_ackTimeout='10s'

# 死信阈值（默认 3）。一条消息被重投超过该次数后进入死信队列，不再投递。
#export mqServer_deadMsgThreshold='3'

# 死信保留时长（默认 72h）。死信段文件超过该时长会被清理。
#export mqServer_deadMsgTTL='72h'

# 消息段日志目录（默认 /var/log/fmq/segmentedLogs；默认值需要写权限）。
# 每个主题的每个队列在该目录下有一份独立的段日志子目录。
#export mqServer_segmentedLogDir='/var/log/fmq/segmentedLogs'

# 死信目录（默认 /var/log/fmq/deadMsgs；默认值需要写权限）。
#export mqServer_deadMsgDir='/var/log/fmq/deadMsgs'

# 单个段文件大小上限（默认 1G）。写入达到上限时自动轮转到新段。
#export mqServer_segmentedLogMaxSize='1G'

# 段文件保留时长（默认 72h）。超过该时长且没有被任何订阅组位点引用的段才会删除；
# 注意「从不消费的订阅组」会把回收边界钉在最早的段上。
#export mqServer_segmentedLogTTL='72h'

# 备份副本数（默认 0 = 不复制）。每条消息异步推送给环形后续的 N 个节点（不含自己，最多 节点数-1）；
# 副本只落盘、不参与投递，也不自动接管。
#export mqServer_backup='0'

# 删除墓碑保留时长（默认 7d）。离线时间超过该时长的节点无法靠增量收敛，
# 需要清空它的 metas/ 后重启以拉取全量快照。
#export mqServer_tombstoneTTL='7d'

# 反熵同步间隔（默认 30s）。节点间元数据增量收敛的周期。
#export mqServer_antiEntropyInterval='30s'

# ---------------------------------------------------------------------------
# 以下不是 fmq 的配置项，是 f_log / f_protocol 的配置，按需保留
# ---------------------------------------------------------------------------

# 控制台日志（不配则服务端基本没有输出）：名称可任意取，符合标识符规范即可。
export logger_appender_console='FmqConsole'
export logger_appender_FmqConsole_level='INFO'
export logger_appender_FmqConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'

# 文件日志（需要落盘时取消注释；路径建议改成绝对路径）。
#export logger_appender_file='FmqFile'
#export logger_appender_FmqFile_level='INFO'
#export logger_appender_FmqFile_path='./fmq.log'
#export logger_appender_FmqFile_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
#export logger_appender_FmqFile_rotateDuration='DAY'

# 【必填】本机在集群内的唯一主机号（f_protocol 的配置，必须非 0）：
# MessageID 拒绝 hostId=0，(pid, tid, 时间戳) 跨机器会重复，集群维度只能靠它区分。
# 多节点部署时每台机器改成不同的值（外部已设置则沿用）
export protocol_hostId="${protocol_hostId:-1}"

# ---------------------------------------------------------------------------
# 进程管理（以下内容不需要按部署修改）
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

PID_FILE="${FMQ_PID_FILE:-$SCRIPT_DIR/fmq.pid}"
LOG_FILE="${FMQ_LOG_FILE:-$SCRIPT_DIR/fmq.log}"
# 脚本用到的端口：与上面的 mqServer_port 保持一致（注释掉时取默认 2350）
PORT="${mqServer_port:-2350}"

# 可执行文件查找顺序：$FMQ_BIN > PATH 里的 fmq（cjpm install 装的）> 本仓库构建产物
FMQ_BIN="${FMQ_BIN:-$(command -v fmq 2>/dev/null || true)}"
if [[ -z "$FMQ_BIN" && -x "$SCRIPT_DIR/target/release/bin/main" ]]; then
    FMQ_BIN="$SCRIPT_DIR/target/release/bin/main"
    # 仓库内构建产物依赖同目录下的各模块动态库
    libs="$(find "$SCRIPT_DIR/target/release" -maxdepth 2 -type d -name '*@*' 2>/dev/null | tr '\n' ':')"
    export LD_LIBRARY_PATH="${libs}${LD_LIBRARY_PATH:-}"
fi

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
        echo "fmq is already running (pid $(cat "$PID_FILE"), port $PORT)"
        return 0
    fi
    if [[ -z "$FMQ_BIN" || ! -x "$FMQ_BIN" ]]; then
        echo "fmq executable not found (set FMQ_BIN, or run 'cjpm build' / 'cjpm install' first)" >&2
        return 1
    fi
    echo "starting fmq ($FMQ_BIN, port $PORT, nodes $mqClient_hosts)"
    nohup "$FMQ_BIN" server >>"$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" >"$PID_FILE"
    local i=0
    while (( i < 300 )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "fmq exited during startup; last lines of $LOG_FILE:" >&2
            tail -5 "$LOG_FILE" >&2 2>/dev/null || true
            echo "提示：默认的 mqServer_segmentedLogDir / mqServer_deadMsgDir 在 /var/log/fmq 下，" >&2
            echo "      普通用户无写权限时请在脚本里取消注释并改成可写目录。" >&2
            rm -f "$PID_FILE"
            return 1
        fi
        if port_open; then
            echo "fmq started (pid $pid, port $PORT, log $LOG_FILE)"
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    echo "fmq did not open port $PORT within 30s; see $LOG_FILE" >&2
    return 1
}

stop() {
    if ! is_running; then
        echo "fmq is not running"
        rm -f "$PID_FILE"
        return 0
    fi
    local pid
    pid="$(cat "$PID_FILE")"
    # 只用 SIGTERM：f_base 的退出钩子保证优雅关闭（服务 → 定时器 → 备份 → 队列 sync → 元数据）
    kill -15 "$pid" 2>/dev/null || true
    local i=0
    while (( i < 300 )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            echo "fmq stopped (pid $pid)"
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    echo "fmq did not stop within 30s (pid $pid)" >&2
    return 1
}

restart() {
    stop || return 1
    start
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) restart ;;
    *)
        echo "usage: $0 {start|stop|restart}" >&2
        exit 2
        ;;
esac
