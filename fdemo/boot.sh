#!/bin/bash

path=$2
echo "target-dir=$path"

run(){
    # pattern可省略，有默认值
    export logger_appender_console_level=ERROR
    export logger_appender_console_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%m'
    export logger_appender_file_level=INFO
    export logger_appender_file_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%m'
    export logger_appender_file_rotateDuration=DAY
    export LD_LIBRARY_PATH=./fdemo/release/boot:./fdemo/release/mysql:./fdemo/release/user:$LD_LIBRARY_PATH
    export version=1.0.0
    fboot run $path --dylibPattern='\.(boot|controller|service.impl)'
}

build(){
    export CANGJIE_STDX_PATH=$CANGJIE_STDX_DYNAMIC_PATH
    cjpm build --target-dir=$path
}

clean(){
    cjpm clean --target-dir=$path
    rm -f ./cjpm.lock
    cjpm update
}

case "$1" in 
run)
    run
    ;;
clean)
    clean
    ;;
build)
    build
    ;;
esac

exit $?
