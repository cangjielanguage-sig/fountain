#!/bin/bash

# 默认目标目录取**脚本自身所在目录**（fdemo/）：在工作区根目录执行、或 cd 进 fdemo/ 之后再执行，
# 都不会建/跑出 fdemo/fdemo 这种嵌套产物（历史踩过：嵌套目录里那份库随后会跑不起来）。
target_path=$2
target_path=${target_path:-"./fdemo"}
echo "target-dir=$target_path"
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
    export logger_appender_console=FDemoConsole # 这是控制台日志记录器的名称，可以任意起名，名称得符合标识符规范
    export logger_appender_FDemoConsole_level=DEBUG
    export logger_appender_FDemoConsole_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
    export logger_appender_file=FDemoFile # 这是文件日志记录器的名称，可以任意起名
    export logger_appender_FDemoFile_level=INFO
    export logger_appender_FDemoFile_pattern='[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m'
    export logger_appender_FDemoFile_path=./log/fdemo.log
    export logger_appender_FDemoFile_rotateDuration=DAY
    export logger_asyncWaitTimeout=5ms # 异步日志缓冲区等待时间，默认是5毫秒，超过这个时间，本次日志被忽略
    export controllerPointcut='*::*..*Controller.*(**): *' # 这个不是mvc的配置，这是声明切面时指定的配置项，开发者可以任意起名
    export mvc_port=8080 # 这一行可以没有，默认就是8080
    export mvc_maxRequestBodySize=67108864
    export mvc_overallElapsedSwitch=true # 生产环境建议改为false，默认是false
    export mvc_internalServerErrorMessageKind=BEAN
    export mvc_internalServerErrorMessage=NameOf500Handler
    # 如果不使用fountain连接池，也不使用标准库连接池，就不要配置以下orm_*Pool*变量，只配置orm_noPool，只能用代码初始化第三方连接池
    export orm_useThirdPartyPool=false # 使用第三方连接池，不使用fountain.orm的连接池，也不使用标准库的连接池。
    # export opengauss_orm_useThirdPartyPool=flase # 可以为指定的数据库驱动配置是否使用第三方池
    # 此时使用ORM.register(datasource, default: false) # 开发者自己用代码初始化Driver和连接池、调用这个函数注册连接池
    export orm_noPool=false # 默认是false，true表示不用连接池
    export orm_useStdPool=false # 默认是true，表示使用标准库连接池，false是使用fountain连接池
    # export orm_drivers=mockdb,opengauss # 逗号分隔的驱动名称
    export orm_drivers=postgres
    # orm_databasePool开头的是fountain::f_orm.DatabasePool的配置项
    export orm_databasePoolInitSize=1 # 初始连接数
    export orm_databasePoolMinSize=1 # 最小连接数
    export orm_databasePoolMaxSize=1 # 最大连接数
    export orm_databasePoolCheckOnCreation=true # 创建连接时是否检查连接有效性，默认是false
    export orm_databasePoolCheckOnBorrowing=true # 获取连接时是否检查连接有效性，默认是true
    export orm_databasePoolCheckOnReturning=false # 归还连接时是否检查连接有效性，默认是true
    export orm_databasePoolIdleTimeout=0 # 连接闲置时间，默认是0，表示闲置不过期
    export orm_databasePoolConnectionLife=86400 # 连接存活时间，默认是3600，单位是秒
    export orm_databasePoolCheckInterval=300 # 连接有效性检查周期，默认是300，单位是秒
    export orm_databasePoolConnectTimeout=50 # 默认是50，单位是毫秒，从fountain.orm.DatabasePool获取连接的超时时间
    export orm_databasePoolMaxWaiting=30s # 默认是30s。池耗尽且调用方用无限等待（Duration.Max）取连接时的等待上限，格式同Duration.toString()（如30s、1m）；超过上限就记WARN并返回None，避免无日志挂死；配成0s表示真无限等待
    export orm_databasePoolCheckSql='select 1' # 检查连接有效性的SQL，默认是select 1
    # orm_stdPool开头的是std.datasource.sql.PooledDatasource的配置项
    export orm_stdPoolMaxSize=10 # 连接池最大连接数
    export orm_stdPoolMaxIdleSize=10 # 连接池最大空闲连接数
    export orm_stdPoolIdleTimeout=86400 # 连接闲置时间，默认是10分钟
    export orm_stdPoolMaxLifeTime=86400 # 连接存活时间，默认30分钟
    export orm_stdPoolConnectionTimeout=86400 # 连接获取超时时间，默认30分钟
    export orm_stdPoolKeepaliveTime=86400 # 连接保活检查周期，默认1分钟
    # orm_transactionalFuncExecution 和@Transactional注解只要有一个生效就会将事务切面织入到函数
    export orm_transactionalFuncExecution='*::*..*ServiceImpl.del*(**): *'
    export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.remove*(**): *"
    export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.insert*(**): *"
    export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.save*(**): *"
    export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.add*(**): *"
    export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.new*(**): *"
    export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.create*(**): *"
    export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.update*(**): *"
    export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.change*(**): *"
    export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*ServiceImpl.register*(**): *"
    export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*.userSession(**): *"
    # export orm_transactionalFuncExecution="$orm_transactionalFuncExecution|*::*..*.sayHello(**): *"
    # export postgres_orm_connectionUrl=$POSTGRES # 如果在build函数配置，就会把URL嵌入编译产物，在此配置则不会，详细见build函数
    # 注意：本工程自建的库目录必须放在 $LD_LIBRARY_PATH **前面**，否则会命中
    # /mnt/d/docs/work/cangjie/installed/libs/fboot 下的旧副本（该目录里的 .so 没有 SONAME，
    # 链接器按文件名先在 LD_LIBRARY_PATH 里找），表现为“新符号明明在自建库里有，却报 undefined symbol”。
    # fdemo 实测：libboot.error@fountain.so 加载期找不到 fountain/f_data.base:DataTypeRegistry.ti。
    #
    # 还要注意：从 registry 拉下来的驱动（如 postgres_driver）**不一定**在 release/* 一级目录下 ——
    # fboot 可能把产物建在 <target>/<名字>/release/ 这种嵌套目录里（`fboot run` 用的是哪份，就得去哪份里找库）。
    # 所以这里再按「目录里有 .so」扫一遍 $target_path 兜底，避免出现
    # `libpostgres_driver.so: cannot open shared object file`（实测：驱动只存在于嵌套产物里时就会这样）。
    extra_libs=`find $target_path/release -name 'lib*.so' -printf '%h\n' 2>/dev/null|sort -u|grep -a -v -P '\.build-logs'|tr '\n' ':'`
    export LD_LIBRARY_PATH=$extra_libs$LD_LIBRARY_PATH
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
}
run(){
    exports
    fboot run $target_path --dylibPattern='(boot|user\.util\.(auth|cron)|\.(controller|service\.impl))'
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
    # export CANGJIE_STDX_PATH=$CANGJIE_STDX_DYNAMIC_PATH

    # export orm_drivers=postgres
    # # 以下是数据库敏感信息，此处仅做演示，实际使用时最好不要暴露在项目代码中
    # # connectionUrl username password 这些配置如果在编译环境配置就会被嵌入编译产物。如果在运行环境配置就会在进程启动时加载
    # # 如果配置了密钥就会把敏感信息加密后的字节数组嵌入编译产物，否则会把这些字符串的UTF8字节数组嵌入编译产物
    # # 运行期的配置优先级高于编译期的
    # export postgres_orm_connectionUrl=$POSTGRES
    # export postgres_orm_option_username=$POSTGRES_USERNAME # 用户名密码可以放到connectionUrl中，POSTGRES是环境变量，已包含用户名和密码
    # export postgres_orm_option_password=$POSTGRES_PASSWORD
    # export sm4Key=$(fboot randhex 32) # 每次加密用不同的KEY，嵌入不同的加密产物
    # export sm4Iv=$(fboot randhex 32)
    # # 以上是敏感信息

    # fboot build $target_path
###############上面注释的跟下面的脚本功能是一样的，只是一个环境变量，一个命令行参数########################

    export CANGJIE_STDX_PATH=$CANGJIE_STDX_DYNAMIC_PATH

    args='--orm_drivers=postgres'
    # 以下是数据库敏感信息，此处仅做演示，实际使用时最好不要暴露在项目代码中
    # connectionUrl username password 这些配置如果在编译环境配置就会被嵌入编译产物。如果在运行环境配置就会在进程启动时加载
    # 如果配置了密钥就会把敏感信息加密后的字节数组嵌入编译产物，否则会把这些字符串的UTF8字节数组嵌入编译产物
    # 运行期的配置优先级高于编译期的
    args="$args --postgres_orm_connectionUrl=$POSTGRES"
    args="$args --postgres_orm_option_username=$POSTGRES_USERNAME" # 用户名密码可以放到connectionUrl中，POSTGRES是环境变量，已包含用户名和密码
    args="$args --postgres_orm_option_password=$POSTGRES_PASSWORD"
    args="$args --sm4Key=$(fboot randhex 32)" # 每次加密用不同的KEY，嵌入不同的加密产物
    args="$args --sm4Iv=$(fboot randhex 32)"
    # 以上是敏感信息
    
    fboot build $target_path $args
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
