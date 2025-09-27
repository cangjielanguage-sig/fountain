#!/bin/bash

path=$2
echo "target-dir=$path"

run(){
    # pattern可省略，有默认值
    export logger_console_level=ERROR
    export logger_console_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%m'
    export logger_file_level=INFO
    export logger_file_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%m'
    export logger_file_path=./log/fdemo.log
    export logger_file_rotateDuration=DAY
    export LD_LIBRARY_PATH=./fdemo/release/boot:./fdemo/release/opengauss:./fdemo/release/user:$LD_LIBRARY_PATH
    export version=1.0.0
    export opengauss_orm_indexStartsWithZero=false
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
