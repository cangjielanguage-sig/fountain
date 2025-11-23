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
#    export orm_noPool=true # 默认是false，true表示不用连接池
    export orm_useStdPool=false # 默认是true
    export orm_drivers=opengauss
    export orm_databasePoolInitSize=10
    export orm_databasePoolMinSize=10
    export orm_databasePoolMaxSize=10
    export orm_databasePoolCheckOnCreation=true
    export orm_databasePoolCheckOnBorrowing=true
    export orm_databasePoolCheckOnReturning=false
    export orm_databasePoolConnectionLife=86400
    export orm_databasePoolCheckInterval=300 # 默认是300，单位是秒
    export orm_databasePoolCheckSql='select 1'
#    export orm_pooledDatasourceMaxSize=1
#    export orm_pooledDatasourceMaxIdleSize=1
#    export orm_pooledDatasourceIdleTimeout=86400
#    export orm_stdPoolMaxLifeTime=86400
#    export orm_pooledDatasourceConnectionTimeout=86400
#    export orm_pooledDatasourceKeepaliveTime=86400
    # orm_transactionalFuncExecution 和@Transactional注解只要有一个生效就会将事务切面织入到函数
#    export orm_transactionalFuncExecution='*..*.delete*(**): *|*..*.remove*(**): *|*..*.save*(**): *|*..*.add*(**): *|*..*.new*(**): *|*..*.create*(**): *|*..*.insert*(**): *|*..*.update*(**): *|*..*.change*(**): *|*..*.register*(**): *'
#    export orm_transactionalFuncExecution='*..*.notLikeDemo*(**): *'
    export opengauss_orm_connectionUrl=$POSTGRES
    if [[ "$path" == "" ]]; then
        path='./fdemo'
    fi
    export LD_LIBRARY_PATH=$path/release/boot:$path/release/opengauss:$path/release/user:$path/release/dbtest:$LD_LIBRARY_PATH
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
loop)
    for i in $(seq 1 $2); do 
        echo -e "\n================= 第 $i 次循环 =================\n";
        # curl -XPOST -H'Content-Type:application/json' -H'Accept:application/json' -d'{"username":"asdf","password":"bcbcbcbc"}' http://localhost:8080/api/user/session
        # curl -XGET -H'Accept:text/plain' http://localhost:8080/helloworld
         curl -XPOST http://localhost:8080/api/db/notLikeDemo1 \
         -H'Content-Type:application/json' \
         -H'Accept:application/json' \
         -d'{
         "username": "asdf"
         }'
	 sleep 1
#        ./curl.sh
    done
    ;;
ab)
#    apt install apache2-utils 执行前需安装apache2-utils
#    ab -c $2 -n $3 -T "application/json" -H "Accept: application/json" -p post_data.json http://127.0.0.1:8080/helloworld
     ab -c $2 -n $3 -T '' -H 'Accept:text/plain' -m GET http://localhost:8080/helloworld
    ;;
esac

exit $?
