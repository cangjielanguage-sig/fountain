#!/bin/bash

path=$2
echo "target-dir=$path"

run(){
    # pattern可省略，有默认值
    export logger_appender_console=FDemoConsole
    export logger_appender_FDemoConsole_level=ERROR
    export logger_appender_FDemoConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%m'
    export logger_appender_file=FDemoFile
    export logger_appender_FDemoFile_level=INFO
    export logger_appender_FDemoFile_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%m'
    export logger_appender_FDemoFile_path=./log/fdemo.log
    export logger_appender_FDemoFile_rotateDuration=DAY
    export mvc_port=8888
    export LD_LIBRARY_PATH=./fdemo/release/boot:./fdemo/release/opengauss:./fdemo/release/user:$LD_LIBRARY_PATH
    export version=1.0.0
    fboot run $path --dylibPattern='(boot|\.(controller|service\.impl))'
}

build(){
    export CANGJIE_STDX=$CANGJIE_STDX_DYNAMIC_PATH
    fboot build $path
}

cleanUpdate(){
    fboot cleanUpdate $path
}

case "$1" in 
run)
    run
    ;;
cleanUpdate)
    cleanUpdate
    ;;
build)
    build
    ;;
esac

exit $?
