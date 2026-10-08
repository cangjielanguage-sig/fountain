#!/bin/bash
# frpcdemo 在 macOS 下的启动脚本，能做的事与 ./boot.sh 完全一致（runServer / runClient / build / cleanUpdate），
# 用法也一样。与 Linux 版的差异只有动态库搜索路径这一处（照 fdemo/boot-macos.sh）：
#   * 用 DYLD_FALLBACK_LIBRARY_PATH，而不是 LD_LIBRARY_PATH —— macOS 上 DYLD_LIBRARY_PATH 容易被
#     SIP / 启动链剥掉，FALLBACK 才稳定生效；
#   * macOS 自带的是 BSD find/grep：find 没有 -printf，grep 没有 -P，所以这里只用 `find -type d` 列目录 + `grep -E`。
# 其余（配置项、参数、端口/权重拆解、dylibPattern）与 boot.sh 一致。

if [[ "$path" == "" ]]; then
    path='./target'
fi
echo "target-dir=$path"

# 搜索路径里用绝对路径：path 缺省是相对当前目录的（和 boot.sh 一样，请在 frpcdemo/ 下执行本脚本）
case "$path" in
    /* ) lib_base="$path" ;;
    *) lib_base="$(pwd)/${path#./}" ;;
esac

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
    # $1 是产物目录里要排除的名字（本 demo 自己的库目录：fboot run 用 --dylibPattern 按绝对路径加载它，
    # 不需要再出现在搜索路径里）。注意：本工程自建的库目录必须放在搜索路径**前面**，否则会命中别处的旧副本
    # （旧副本里没有新符号，表现为“新符号明明在自建库里有，却报 symbol not found”）。
    local dirs
    dirs=$(find "$lib_base/release"/* -type d 2>/dev/null | grep -a -v -E "_stAtIc__|\.build-logs|$1" | tr '\n' ':')
    export DYLD_FALLBACK_LIBRARY_PATH="$dirs$DYLD_FALLBACK_LIBRARY_PATH"
    echo "DYLD_FALLBACK_LIBRARY_PATH=$DYLD_FALLBACK_LIBRARY_PATH"
}
runServer(){
    # ./boot-macos.sh runServer <主机:端口> [种子节点地址] [权重]
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
    # ./boot-macos.sh runServer 127.0.0.1:1203 - 2.0）
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
    # ./boot-macos.sh runClient <主机:端口>[,<主机:端口>...]
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
        echo "未指定服务节点地址，客户端将打印 ERROR 并结束进程。用法：./boot-macos.sh runClient 127.0.0.1:1203"
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
