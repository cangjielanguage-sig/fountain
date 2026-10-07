#!/bin/bash
# frpcdemo 在 Windows git-bash 下的启动脚本，能做的事与 ./boot.sh 完全一致（runServer / runClient / build / cleanUpdate），
# 用法也一样：
#   ./boot-win-gitbash.sh runServer 127.0.0.1:1203 - 2.0
#   ./boot-win-gitbash.sh runClient 127.0.0.1:1203,127.0.0.1:1204
#   ./boot-win-gitbash.sh build
#   ./boot-win-gitbash.sh cleanUpdate
# 与 Linux 版（boot.sh）只有三处平台差异，都是照 fdemo/boot-win-gitbash.sh 的做法改的：
#   1) 配置项不用 export，而是拼成 --key=value 命令行参数交给 fboot —— f_config 读命令行参数与环境变量等价；
#      ⚠️ 值里不要再套引号：f_config 只对 dylibPattern 去掉首尾引号，其它配置项里的引号会原样进配置。
#   2) 动态库搜索路径用 PATH（Windows 上没有 LD_LIBRARY_PATH 这种东西），同样必须**前置**：
#      installed/libs/fboot 那样的目录里若是旧副本，排在前面就会命中旧副本（表现为找不到新符号）。
#   3) 日志文件名里的 ':' 在 Windows 上非法（git-bash 会把它偷换成私用区字符 U+F03A，Cangjie 进程按字面名字打不开），
#      所以服务端的日志名把 ':' 换成 '-'；Linux/macOS 版仍是 log/frpcdemoserver-<主机:端口>.log。

if [[ "$path" == "" ]]; then
    path='./target'
fi
echo "target-dir=$path"

# 搜索路径里要用绝对路径：path 缺省是相对当前目录的（和 boot.sh 一样，请在 frpcdemo/ 下执行本脚本）
case "$path" in
    /* | [A-Za-z]:[/\\]*) lib_base="$path" ;;
    *) lib_base="$(pwd)/${path#./}" ;;
esac

extra_args=("${@:3}")
run_args=()

exports(){
    # $1 是产物目录里要排除的名字（本 demo 自己的库目录），与 boot.sh 里那个参数同一个意思：fboot run 会用
    #    --dylibPattern 按绝对路径加载它，再让它出现在搜索路径里，同一份库就有被按两个路径各加载一次的风险
    #    （Initializer 跑两遍：服务端会二次绑定端口）。
    # $2 是日志文件基名；$3 是 rpcServer_baseAddresses
    run_args=()
    run_args+=("--logger_appender_console=FRPCDemoConsole") # 这是控制台日志记录器的名称，可以任意起名，名称得符合标识符规范
    run_args+=("--logger_appender_FRPCDemoConsole_level=DEBUG")
    run_args+=("--logger_appender_FRPCDemoConsole_pattern=[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m")
    run_args+=("--logger_appender_file=FRPCDemoFile") # 这是文件日志记录器的名称，可以任意起名
    run_args+=("--logger_appender_FRPCDemoFile_level=INFO")
    run_args+=("--logger_appender_FRPCDemoFile_pattern=[%level-%name]%d{yyyy/MM/dd,HH:mm:ss.SSS}|%tid;%m")
    run_args+=("--logger_appender_FRPCDemoFile_path=./log/$2.log")
    run_args+=("--logger_appender_FRPCDemoFile_rotateDuration=DAY")
    run_args+=("--logger_asyncWaitTimeout=5ms") # 异步日志缓冲区等待时间，默认是5毫秒，超过这个时间，本次日志被忽略
    run_args+=("--rpcServer_baseAddresses=$3")
    # 把自建库目录前置进 PATH（boot.sh 里对应的是把自建库目录前置进 LD_LIBRARY_PATH）；
    # stdx 的动态库不在产物目录里，得靠 CANGJIE_STDX_DYNAMIC_PATH 指过去
    # （git-bash 里它可能是 /d/... 形式，转成 MSYS 形式后 MSYS 会再转成 Windows 形式交给子进程）。
    local dirs="" stdx="" d
    dirs=$(find "$lib_base/release"/* -type d 2>/dev/null | grep -a -v -E "_stAtIc__|\.build-logs|$1" | tr '\n' ':')
    d="${CANGJIE_STDX_DYNAMIC_PATH:-$CANGJIE_STDX_PATH}"
    if [[ -n "$d" ]]; then
        stdx="$(cygpath -u "$d"):"
    fi
    export PATH="$dirs$stdx$PATH"
    echo "PATH(前置)=$dirs$stdx"
}
runServer(){
    # ./boot-win-gitbash.sh runServer <主机:端口> [种子节点地址] [权重]
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
    # ./boot-win-gitbash.sh runServer 127.0.0.1:1203 - 2.0）
    if [[ "$base" == "-" ]]; then
        base=""
    fi
    if [[ -n "$base" ]]; then
        base="$base,$addr"
    else
        base="$addr"
    fi
    exports rpcserver "frpcdemoserver-${addr//:/-}" "$base" # rpcserver是包名；日志名里的 ':' 换成 '-'（Windows 文件名不允许 ':'）
    run_args+=("--rpc_currentSkeleton=^(fountain::rpcserver).+$")
    run_args+=("--rpcServer_port=$port")
    run_args+=("--rpcServer_weight=$weight")
    echo "rpcServer_port=$port rpcServer_baseAddresses=$base rpcServer_weight=$weight"
    fboot run "$path" --dylibPattern='(rpcserver)' "${run_args[@]}"
}
runClient(){
    # ./boot-win-gitbash.sh runClient <主机:端口>[,<主机:端口>...]
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
        local addr
        for addr in $list; do
            spec="${spec}${spec:+|}1.0,${addr}"
        done
        run_args+=("--rpcClient_serverAddress=$spec")
        run_args+=("--rpcClient_loadbalance=roundrobin")
        echo "rpcClient_serverAddress=$spec rpcClient_loadbalance=roundrobin"
    else
        echo "未指定服务节点地址，客户端将打印 ERROR 并结束进程。用法：./boot-win-gitbash.sh runClient 127.0.0.1:1203"
    fi
    fboot run "$path" --dylibPattern='(rpcclient)' "${run_args[@]}"
}
build(){
    # cjpm 按 CANGJIE_STDX_DYNAMIC_PATH / CANGJIE_STDX_PATH 找 stdx 的动态库。这两个变量在 git-bash 里可能是
    # /d/... 形式，而 cjpm 是原生进程，只认 Windows 形式；转换后的值同时写进用户级环境变量，
    # 好让新开的终端直接跑 fboot 也能编译（照 fdemo/boot-win-gitbash.sh）。
    export CANGJIE_STDX_DYNAMIC_PATH="$(cygpath -w "$CANGJIE_STDX_DYNAMIC_PATH")"
    export CANGJIE_STDX_PATH="$CANGJIE_STDX_DYNAMIC_PATH"
    powershell.exe -NoProfile -Command '
    $map = @{
        "CANGJIE_STDX_DYNAMIC_PATH" = $env:CANGJIE_STDX_DYNAMIC_PATH
        "CANGJIE_STDX_PATH"         = $env:CANGJIE_STDX_PATH
    }
    foreach ($k in $map.Keys) {
        [Environment]::SetEnvironmentVariable($k, $map[$k], "User")
    }
    '

    fboot build "$path" "${extra_args[@]}"
    echo -e '\a'
}
cleanUpdate(){
    fboot cleanUpdate "$path"
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
    cleanUpdate
    ;;
esac
