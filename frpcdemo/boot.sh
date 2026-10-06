#!/bin/bash

if [[ "$path" == "" ]]; then
    path='./target'
fi
echo "target-dir=$path"
args=${@:3}

exports(){
    # export cjHeapSize=4GB
    # pattern可省略，有默认值
    # %level 记录当前日志级别
    # %name 记录当前日志名称
    # %d 记录当前日志时间，花括号内是时间格式
    # %m 记录当前日志消息文本
    # %tid 记录当前线程ID
    # %pid 记录当前进程ID
#    export loggerAsyncBufsize=2 # 异步日志缓存池的初始化大小，默认是1024
    export logger_appender_console=FRPCDemoConsole # 这是控制台日志记录器的名称，可以任意起名，名称得符合标识符规范
    export logger_appender_FRPCDemoConsole_level=DEBUG
    export logger_appender_FRPCDemoConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
    export logger_appender_file=FRPCDemoFile # 这是文件日志记录器的名称，可以任意起名
    export logger_appender_FRPCDemoFile_level=INFO
    export logger_appender_FRPCDemoFile_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
    export logger_appender_FRPCDemoFile_path=./log/$2.log
    export logger_appender_FRPCDemoFile_rotateDuration=DAY
    export logger_asyncWaitTimeout=5ms # 异步日志缓冲区等待时间，默认是5毫秒，超过这个时间，本次日志被忽略
    export rpcServer_baseAddresses=$3
    regexp="_stAtIc__|$1"
    # 注意：本工程自建的库目录必须放在 $LD_LIBRARY_PATH **前面**，否则会命中
    # /mnt/d/docs/work/cangjie/installed/libs/fboot 下的旧副本（该目录里的 .so 没有 SONAME，
    # 链接器按文件名先在 LD_LIBRARY_PATH 里找），表现为“新符号明明在自建库里有，却报 undefined symbol”。
    export LD_LIBRARY_PATH=`find ./target/release/* -type d|grep -a -v -P $regexp|tr '\n' ':'`$LD_LIBRARY_PATH
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
}
runServer(){
    # ./boot.sh runServer <主机:端口> [种子节点地址] [权重]
    #   rpcServer_port 只接受端口号（UInt16，见 f_rpc/README.md）⇒ 从“主机:端口”里取出端口，
    #   直接传 "127.0.0.1:1203" 会解析失败并回落到默认端口 1203（两个服务节点就会撞端口）。
    #   baseAddresses 除显式给的种子节点外还加上自己：服务节点自己也要出现在注册表里，
    #   否则注册表报不出它的权重，客户端只能按缺省 1.0 分配（见 .autocode/bugs/bug-archived-20261004-2.md）。
    local addr=${1:-127.0.0.1:1203}
    if [[ "$addr" != *:* ]]; then
        addr="127.0.0.1:$addr"
    fi
    local port=${addr##*:}
    local weight=${3:-1.0}
    local base="$2"
    # 种子节点参数写 "-" 表示没有种子（只是为了让权重参数能写在第三位：
    # ./boot.sh runServer 127.0.0.1:1203 - 2.0）
    if [[ "$base" == "-" ]]; then
        base=""
    fi
    if [[ -n "$base" ]]; then
        base="$base,$addr"
    else
        base="$addr"
    fi
    exports rpcserver "frpcdemoserver-$addr" "$base" # rpcserver是包名
    export rpc_currentSkeleton='^(fountain::rpcserver).+$'
    export rpcServer_port=$port
    export rpcServer_weight=$weight
    echo "rpcServer_port=$rpcServer_port rpcServer_baseAddresses=$rpcServer_baseAddresses rpcServer_weight=$rpcServer_weight"
    fboot run $path --dylibPattern='(rpcserver)'
}
runClient(){
    # ./boot.sh runClient <主机:端口>[,<主机:端口>...]
    #   多个服务节点用逗号分隔；rpcClient_serverAddress 的格式是「权重,地址」，多个地址用 | 分隔。
    #   本 demo 固定用轮询（rpcClient_loadbalance=roundrobin），各节点权重都写 1.0
    #   —— 真正决定调用分配的是**服务节点注册到注册表的权重**（rpcServer_weight）；
    #   注册表里查不到的节点才会退回这里配置的权重。
    # $1 缺省时不设置 rpcClient_serverAddress，由 f_rpc 客户端打印 ERROR 说明原因并结束进程
    exports rpcclient frpcdemoclient # rpcclient是包名
    local list="$1"
    if [[ -n "$list" ]]; then
        local spec=""
        local IFS=','
        for addr in $list; do
            spec="${spec}${spec:+|}1.0,${addr}"
        done
        export rpcClient_serverAddress="$spec"
        export rpcClient_loadbalance=roundrobin
        echo "rpcClient_serverAddress=$rpcClient_serverAddress rpcClient_loadbalance=$rpcClient_loadbalance"
    else
        echo "未指定服务节点地址，客户端将打印 ERROR 并结束进程。用法：./boot.sh runClient 127.0.0.1:1203"
    fi
    fboot run $path --dylibPattern='(rpcclient)'
}
build(){
    fboot build $path $args
    echo -e '\a'
}
cleanUpdate(){
    fboot cleanUpdate $path
    echo -e '\a'
}
case "$1" in 
runClient)
    runClient "$2" # $2 是服务节点地址（多个用逗号分隔），如 127.0.0.1:1203,127.0.0.1:1204
    ;;
runServer)
    runServer "$2" "$3" "$4" # $2 是主机:端口 $3 是种子服务节点地址 $4 是权重
    ;;
build)
    build 
    ;;
cleanUpdate)
    cleanUpdate $2 $3
    ;;
esac
