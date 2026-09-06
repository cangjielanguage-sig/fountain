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
    export logger_appender_FRPCDemoFile_path=./log/fdemo.log
    export logger_appender_FRPCDemoFile_rotateDuration=DAY
    export logger_asyncWaitTimeout=5ms # 异步日志缓冲区等待时间，默认是5毫秒，超过这个时间，本次日志被忽略
    arg=$1
    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:`find ./target/release/* -type d|grep -a -v -P "_stAtIc__|$(arg)"|tr '\n' ':'`
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
}
runServer(){
    exports rpcserver
    fboot run $path --dylibPattern='(rpcserver)'
}
runClient(){
    exports rpcclient
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
    runClient
    ;;
runServer)
    runServer
    ;;
build)
    build 
    ;;
cleanUpdate)
    cleanUpdate $2 $3
    ;;
esac