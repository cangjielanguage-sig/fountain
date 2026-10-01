#!/bin/bash

target_path=$2
target_path=${target_path:-"./target"}
echo "target-dir=$target_path"
args=${@:3}

args=''
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
    args="$args --logger_appender_console=FDemoConsole" # 这是控制台日志记录器的名称，可以任意起名，名称得符合标识符规范
    args="$args --logger_appender_FDemoConsole_level=DEBUG"
    args="$args --logger_appender_FDemoConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'"
    args="$args --logger_appender_file=FDemoFile" # 这是文件日志记录器的名称，可以任意起名
    args="$args --logger_appender_FDemoFile_level=INFO"
    args="$args --logger_appender_FDemoFile_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'"
    args="$args --logger_appender_FDemoFile_path=./log/fdemo.log"
    args="$args --logger_appender_FDemoFile_rotateDuration=DAY"
    args="$args --logger_asyncWaitTimeout=5ms" # 异步日志缓冲区等待时间，默认是5毫秒，超过这个时间，本次日志被忽略
    args="$args --controllerPointcut='*::*..*Controller.*(**): *'" # 这个不是mvc的配置，这是声明切面时指定的配置项，开发者可以任意起名
    args="$args --mvc_port=8080" # 这一行可以没有，默认就是8080
    args="$args --mvc_maxRequestBodySize=67108864"
    args="$args --mvc_overallElapsedSwitch=true" # 生产环境建议改为false，默认是false
    args="$args --mvc_internalServerErrorMessageKind=BEAN"
    args="$args --mvc_internalServerErrorMessage=NameOf500Handler"
    # 如果不使用fountain连接池，也不使用标准库连接池，就不要配置以下orm_*Pool*变量，只配置orm_noPool，只能用代码初始化第三方连接池
    args="$args --orm_useThirdPartyPool=false" # 使用第三方连接池，不使用fountain.orm的连接池，也不使用标准库的连接池。
    # args="$args --opengauss_orm_useThirdPartyPool=flase" # 可以为指定的数据库驱动配置是否使用第三方池
    # 此时使用ORM.register(datasource, default: false) # 开发者自己用代码初始化Driver和连接池、调用这个函数注册连接池
    args="$args --orm_noPool=false" # 默认是false，true表示不用连接池
    args="$args --orm_useStdPool=false" # 默认是true，表示使用标准库连接池，false是使用fountain连接池
    # args="$args --orm_drivers=mockdb,opengauss" # 逗号分隔的驱动名称
    args="$args --orm_drivers=postgres"
    # orm_databasePool开头的是fountain::f_orm.DatabasePool的配置项
    args="$args --orm_databasePoolInitSize=1" # 初始连接数
    args="$args --orm_databasePoolMinSize=1" # 最小连接数
    args="$args --orm_databasePoolMaxSize=1" # 最大连接数
    args="$args --orm_databasePoolCheckOnCreation=true" # 创建连接时是否检查连接有效性，默认是false
    args="$args --orm_databasePoolCheckOnBorrowing=true" # 获取连接时是否检查连接有效性，默认是true
    args="$args --orm_databasePoolCheckOnReturning=false" # 归还连接时是否检查连接有效性，默认是true
    args="$args --orm_databasePoolIdleTimeout=0" # 连接闲置时间，默认是0，表示闲置不过期
    args="$args --orm_databasePoolConnectionLife=86400" # 连接存活时间，默认是3600，单位是秒
    args="$args --orm_databasePoolCheckInterval=300" # 连接有效性检查周期，默认是300，单位是秒
    args="$args --orm_databasePoolConnectTimeout=50" # 默认是50，单位是毫秒，从fountain.orm.DatabasePool获取连接的超时时间
    args="$args --orm_databasePoolCheckSql='select 1'" # 检查连接有效性的SQL，默认是select 1
    # orm_stdPool开头的是std.datasource.sql.PooledDatasource的配置项
    args="$args --orm_stdPoolMaxSize=10" # 连接池最大连接数
    args="$args --orm_stdPoolMaxIdleSize=10" # 连接池最大空闲连接数
    args="$args --orm_stdPoolIdleTimeout=86400" # 连接闲置时间，默认是10分钟
    args="$args --orm_stdPoolMaxLifeTime=86400" # 连接存活时间，默认30分钟
    args="$args --orm_stdPoolConnectionTimeout=86400" # 连接获取超时时间，默认30分钟
    args="$args --orm_stdPoolKeepaliveTime=86400" # 连接保活检查周期，默认1分钟
    # orm_transactionalFuncExecution 和@Transactional注解只要有一个生效就会将事务切面织入到函数
    orm_transactionalFuncExecution='*::*..*ServiceImpl.del*(**): *'
    orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.remove*(**): *"
    orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.insert*(**): *"
    orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.save*(**): *"
    orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.add*(**): *"
    orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.new*(**): *"
    orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.create*(**): *"
    orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.update*(**): *"
    orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.change*(**): *"
    orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.register*(**): *"
    orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*.userSession(**): *"
    # orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*.sayHello(**): *"
    args="$args --orm_transactionalFuncExecution=$orm_transactionalFuncExecution"
    # args="$args --postgres_orm_connectionUrl=$POSTGRES" # 如果在build函数配置，就会把URL嵌入编译产物，在此配置则不会，详细见build函数
    
}
run(){
    exports
    fboot run $target_path --dylibPattern='(boot|user\.util\.(auth|cron)|\.(controller|service\.impl))' $args
}
perfRecord(){
    exports
    cjprof record -f max -- $CJPM_INSTALL/bin/fboot run $target_path --dylibPattern='(boot|user\.util\.(auth|cron)|\.(controller|service\.impl))'

}
perfReport(){
    exports
    cjprof report -F 
}
build(){
    export CANGJIE_STDX_DYNAMIC_PATH="$(cygpath -w "$CANGJIE_STDX_DYNAMIC_PATH")"
    export CANGJIE_STDX_PATH="$CANGJIE_STDX_DYNAMIC_PATH"
    mkdir -p "$target_path/release/libs/"
    export LIB_WIN="$(cygpath -wa "$target_path/release/libs")"
    powershell.exe -NoProfile -Command '
    $map = @{
        "CANGJIE_STDX_DYNAMIC_PATH"    = $env:CANGJIE_STDX_DYNAMIC_PATH
        "CANGJIE_STDX_PATH"            = $env:CANGJIE_STDX_PATH
    }
    foreach ($k in $map.Keys) {
        [Environment]::SetEnvironmentVariable($k, $map[$k], "User")
    }
    $lib = $env:LIB_WIN
    $p = [Environment]::GetEnvironmentVariable('Path','User')
    if ([string]::IsNullOrEmpty($p)) { $p = '' }
    if (-not $p.Contains($lib)) {
        [Environment]::SetEnvironmentVariable('Path', ($p.TrimEnd(";") + ";" + $lib), "User")
    }
    '
    # 以下是数据库敏感信息，此处仅做演示，实际使用时最好不要暴露在项目代码中
    # connectionUrl username password 这些配置如果在编译环境配置就会被嵌入编译产物。如果在运行环境配置就会在进程启动时加载
    # 如果配置了密钥就会把敏感信息加密后的字节数组嵌入编译产物，否则会把这些字符串的UTF8字节数组嵌入编译产物
    # 运行期的配置优先级高于编译期的
    args="--orm_sm4Key=$(fboot randhex 32)"
    args="$args --orm_sm4Iv=$(fboot randhex 32)"
    args="$args --orm_drivers=postgres"
    args="$args --postgres_orm_connectionUrl=$POSTGRES"
    args="$args --postgres_orm_option_username=$POSTGRES_USERNAME"
    args="$args --postgres_orm_option_password=$POSTGRES_PASSWORD"
    # 以上是敏感信息

    fboot build $target_path $args
    cp "$target_path"/release/*/*.dll "$target_path/release/libs/"
    echo -e '\a'
}

cleanUpdate(){
    fboot cleanUpdate $target_path
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
    start=$(date +%s.%N)
    for i in $(seq 1 $2); do 
        echo -e "\n================= 第 $i 次循环 =================\n";
#W         curl -XPOST -H'Content-Type:application/json' -H'Accept:application/json' -d'{"username":"asdf","password":"bcbcbcbc"}' http://localhost:8080/api/user/session
        curl -XGET -H'Accept:text/plain' http://localhost:8080/helloworld
	#  sleep 1
#        ./curl.sh
    done
    end=$(date +%s.%N)
    elapsed=$(echo "$end - $start" | bc)
    echo "耗时: $elapsed 秒"
    ;;
ab)
#    apt install apache2-utils 执行前需安装apache2-utils
#    ab -c $2 -n $3 -T "application/json" -H "Accept: application/json" -p post_data.json http://127.0.0.1:8080/helloworld
    ab -c $2 -n $3 -T '' -H 'Accept:text/plain' -H'Content-Type:application/x-www-form-urlencoded' -m GET http://localhost:8080/helloworld
    ;;
esac

exit $?
