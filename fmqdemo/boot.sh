#!/bin/bash
# fmqdemo 的 fboot 启动脚本：发布端 / 消费端都是**动态库**，由 fboot 加载运行（没有 main 函数）。
#
#   ./boot.sh build     构建 workspace（产物在 ./target，含 fmqpub / fmqsub 两个动态库）
#   ./boot.sh runPub    加载 fmqpub：启动即发布（环境变量见下）
#   ./boot.sh runSub    加载 fmqsub：启动即订阅并消费
#
# 环境变量：
#   mqClient_hosts        节点表（默认 127.0.0.1:23700）
#   FMQDEMO_TOPIC         主题（默认 /fmqdemo）
#   FMQDEMO_GROUP         订阅组（默认 demoGroup）
#   FMQDEMO_COUNT         条数（默认 10）
#   FMQDEMO_TAGS          tags，逗号分隔（默认 demo）
#   FMQDEMO_INTERVAL_MS   发布间隔毫秒（默认 50）
#   FMQDEMO_AUTO_ACK      true 时消费端用 autoAck（默认 false）
HERE=$(cd "$(dirname "$0")" && pwd)
cd "${HERE}" || exit 1
# shellcheck disable=SC1091
source "${HERE}/env.sh" || exit 1

path=${FMQDEMO_TARGET:-./target}

exports(){
    export mqClient_hosts=${mqClient_hosts:-127.0.0.1:23700}
    # 【必填】本机在集群内的唯一主机号：MessageID 拒绝 hostId=0，
    # (pid, tid, 时间戳) 跨机器会重复，集群维度只能靠它区分。
    export protocol_hostId="${protocol_hostId:-1}"
    # 日志：控制台 appender（服务端/客户端自己的日志都走 f_log）
    export logger_appender_console=FMQDemoConsole
    export logger_appender_FMQDemoConsole_level=INFO
    export logger_appender_FMQDemoConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
    # 注意：本工程自建的库目录必须排在 $LD_LIBRARY_PATH **前面**，否则会命中安装目录
    # （如 <install>/libs/fboot）下的旧副本（那些 .so 没有 SONAME），表现为「符号明明在新库里有，
    # 却报 undefined symbol」。
    export LD_LIBRARY_PATH=$(find ./target/release -maxdepth 2 -type d 2>/dev/null \
        | grep -a -v '_stAtIc__' | tr '\n' ':')${LD_LIBRARY_PATH:-}
    echo "mqClient_hosts=$mqClient_hosts"
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
}

runPub(){
    exports
    fboot run ${path} --dylibPattern='(fmqpub)'
}

runSub(){
    exports
    fboot run ${path} --dylibPattern='(fmqsub)'
}

build(){
    fboot build ${path} "${@:2}"
    echo -e '\a'
}

case "$1" in
  build)
    build "$@"
    ;;
  runPub)
    runPub
    ;;
  runSub)
    runSub
    ;;
  *)
    echo "用法：./boot.sh <build|runPub|runSub>"
    exit 2
    ;;
esac
