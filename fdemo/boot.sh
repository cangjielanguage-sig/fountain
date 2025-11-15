#!/bin/bash

path=$2
echo "target-dir=$path"

exports(){
    # pattern可省略，有默认值
    # %level 记录当前日志级别
    # %name 记录当前日志名称
    # %d 记录当前日志时间，花括号内是时间格式
    # %m 记录当前日志消息文本
    export logger_appender_console=FDemoConsole
    export logger_appender_FDemoConsole_level=DEBUG
    export logger_appender_FDemoConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
    export logger_appender_file=FDemoFile
    export logger_appender_FDemoFile_level=INFO
    export logger_appender_FDemoFile_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
    export logger_appender_FDemoFile_path=./log/fdemo.log
    export logger_appender_FDemoFile_rotateDuration=DAY
    export mvc_port=8080 # 这一行可以没有，默认就是8080                                                                         
    export mvc_overallElapsedSwitch=true
    export mvc_internalServerErrorMessageKind=BEAN
    export mvc_internalServerErrorMessage=NameOf500Handler
    export orm_pooledDatasourceMaxSize=1
    export orm_pooledDatasourceMaxIdleSize=1
    export orm_pooledDatasourceIdleTimeout=86400
    export orm_stdPoolMaxLifeTime=86400
    export orm_pooledDatasourceConnectionTimeout=86400
    export orm_pooledDatasourceKeepaliveTime=86400
    # orm_transactionalFuncExecution 和@Transactional注解只要有一个生效就会将事务切面织入到函数
    export orm_transactionalFuncExecution='*..*.delete*(**): *|*..*.remove*(**): *|*..*.save*(**): *|*..*.add*(**): *|*..*.new*(**): *|*..*.create*(**): *|*..*.insert*(**): *|*..*.update*(**): *|*..*.change*(**): *|*..*.register*(**): *'
    export opengauss_orm_connectionUrl=$POSTGRES
    if [[ "$path" == "" ]]; then
        path='./fdemo'
    fi
    export LD_LIBRARY_PATH=$path/release/boot:$path/release/opengauss:$path/release/user:$LD_LIBRARY_PATH
}
run(){
    exports
    fboot run $path --dylibPattern='(boot|user\.util\.auth|\.(controller|service\.impl))'
}
perfRecord(){
    exports
    cjprof record -f max -- $CJPM_INSTALL/bin/fboot run $path --dylibPattern='(boot|user\.util\.auth|\.(controller|service\.impl))'

}
perfReport(){
    exports
    cjprof report -F 
}
build(){
    export CANGJIE_STDX_PATH=$CANGJIE_STDX_DYNAMIC_PATH
    fboot build $path
    echo -e '\a'
}

cleanUpdate(){
    fboot cleanUpdate $path
    echo -e '\a'
}

case "$1" in 
run)
    run
    ;;
perfRecord)
    perfRecord
    ;;
perfReport)
    perfReport
    ;;
cleanUpdate)
    cleanUpdate $2 $3
    ;;
build)
    build
    ;;
launch)
    launch
    ;;
esac

exit $?
