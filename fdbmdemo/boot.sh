#!/bin/bash
# fdbmdemo：fdbm 双实例启动脚本 —— 负载均衡 / 读写分离 / 数据分片 演示的服务端一侧。
#
# 拓扑（两个 fdbm 实例，业务配置一致；只有第二个实例多挂了一个逻辑库 spare 作探针）：
#   fdbm-1 :8112  ┐
#   fdbm-2 :8113  ┴─> 节点 n1(postgres, 账号 fdbm_w 可写, 权重 w,1;r,0)
#                    节点 n2(postgres, 账号 fdbm_r 只读, 权重 w,0;r,1)
#   逻辑库 demo = 物理库 demo_0, demo_1（t_order 按 hash(id) 分片；t_dict 全局表广播）
#   逻辑库 spare = 物理库 spare_0（只配在 fdbm-2 上 ⇒ `show databases` 可区分落点）
#
# 主场景：WSL Ubuntu 24.04（postgres 与 fdbm 都在 WSL 内），在 WSL 里执行本脚本。
# 前置：
#   - WSL 内：sudo apt install postgresql && sudo service postgresql start
#   - postgres 超级用户可达（本机免密或设置 FDBM_PG_ADMIN_PASSWORD）
#   - 已 source 仓颉 envsetup（cjpm / cjc / CANGJIE_STDX_DYNAMIC_PATH）
#   - fdbm 可执行文件：cd ../fdbm && cjpm build（或 cjpm install 后在 PATH）
#   - fboot 可执行文件：cjpm install "fountain::fboot"=<版本> --root <dir> 后加入 PATH
#     （或 cd ../fboot && cjpm build，脚本会自动找 ../fboot/target/release/fboot）
#
# 客户端形态：`client/` 是**动态链接库**模块（output-type = "dynamic"），
# 演示逻辑写在 f_app 的 Initializer.start 里，由 fboot 加载并启动（参考 frpcdemo）。
#
# 用法：
#   ./boot.sh driver      # 构建 postgres_driver 动态库并放入 ./driver/（恰好一个）
#   ./boot.sh init-db     # 初始化 WSL postgres：建角色（可写/只读）、建物理库、授权
#   ./boot.sh start       # 启动两个 fdbm 实例（8112 / 8113）
#   ./boot.sh stop        # 优雅停止（SIGTERM → f_base ExitCallbacks）
#   ./boot.sh status      # 查看两实例状态
#   ./boot.sh check       # psql 核对分片分布、全局表副本与只读权限
#   ./boot.sh build       # 编译客户端动态库（fboot build ./target）
#   ./boot.sh demo        # fboot 启动客户端（--dylibPattern='(fdbmdemo_client)'）
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# ---------------------------------------------------------------------------
# 可覆盖配置（环境变量）
# ---------------------------------------------------------------------------
PGHOST="${FDBM_PG_HOST:-127.0.0.1}"            # postgres 地址（WSL 内 127.0.0.1 即可）
PGPORT="${FDBM_PG_PORT:-5432}"
PGADMIN="${FDBM_PG_ADMIN:-postgres}"
PGADMIN_PASSWORD="${FDBM_PG_ADMIN_PASSWORD:-}"
APP_PASSWORD="${FDBM_PG_PASSWORD:-fdbm_pw}"    # 演示角色 fdbm_w / fdbm_r 的密码
WRITE_USER=fdbm_w                              # 写节点账号（可写）
READ_USER=fdbm_r                               # 读节点账号（只读 —— 读写分离的硬证据）
DATABASES="demo_0 demo_1 spare_0"              # 物理库（= postgres database）
SHARD_DBS="demo_0 demo_1"                      # 逻辑库 demo 的物理库
FDBM_PORT1="${FDBM_PORT1:-8112}"
FDBM_PORT2="${FDBM_PORT2:-8113}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

wait_port() {
    local port="$1" tries=0
    while [ "$tries" -lt 100 ]; do
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            exec 3>&-
            return 0
        fi
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------
# psql 封装：本机有 psql 用本机；否则回落到 WSL（Windows git-bash 场景）
# ---------------------------------------------------------------------------
psql_admin() {
    if command -v psql >/dev/null 2>&1; then
        PGPASSWORD="$PGADMIN_PASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGADMIN" \
            -v ON_ERROR_STOP=1 -tAc "$1"
    elif command -v wsl.exe >/dev/null 2>&1; then
        wsl.exe -e bash -c "PGPASSWORD='$PGADMIN_PASSWORD' psql -h '$PGHOST' -p '$PGPORT' -U '$PGADMIN' -v ON_ERROR_STOP=1 -tAc \"$1\""
    else
        die "需要 psql：在 WSL Ubuntu 24.04 里运行本脚本，或本机安装 postgresql-client"
    fi
}

# psql_app <db> <sql> [role]：以演示角色连接物理库（默认可写账号）
psql_app() {
    local db="$1" sql="$2" role="${3:-$WRITE_USER}"
    if command -v psql >/dev/null 2>&1; then
        PGPASSWORD="$APP_PASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$role" -d "$db" \
            -v ON_ERROR_STOP=1 -tAc "$sql"
    elif command -v wsl.exe >/dev/null 2>&1; then
        wsl.exe -e bash -c "PGPASSWORD='$APP_PASSWORD' psql -h '$PGHOST' -p '$PGPORT' -U '$role' -d '$db' -v ON_ERROR_STOP=1 -tAc \"$sql\""
    else
        die "需要 psql：在 WSL Ubuntu 24.04 里运行本脚本"
    fi
}

# ---------------------------------------------------------------------------
# 动作：driver / init-db
# ---------------------------------------------------------------------------
build_driver() {
    command -v cjpm >/dev/null 2>&1 || die "cjpm 不在 PATH（先 source envsetup）"
    : "${CANGJIE_STDX_DYNAMIC_PATH:?CANGJIE_STDX_DYNAMIC_PATH 未设置（source envsetup）}"
    say "构建 postgres_driver 动态库"
    ( cd driver_bundle && CANGJIE_STDX_PATH="$CANGJIE_STDX_DYNAMIC_PATH" cjpm build ) \
        || die "驱动构建失败（见 driver_bundle 的构建输出）"
    local so
    so="$(find driver_bundle/target -name 'libpostgres_driver.so' | head -1)"
    [ -n "$so" ] || die "未找到 libpostgres_driver.so"
    mkdir -p driver
    rm -f driver/*.so
    cp "$so" driver/
    echo "已放置物理驱动：driver/$(basename "$so")（fdbm 的 driver/ 目录要求恰好一个）"
}

init_db() {
    say "检查 PostgreSQL（$PGHOST:$PGPORT，管理员 $PGADMIN）"
    psql_admin "select 1" >/dev/null || die "无法连接 PostgreSQL；WSL 里先：sudo service postgresql start"
    for role in "$WRITE_USER" "$READ_USER"; do
        psql_admin "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$role') \
THEN CREATE ROLE $role LOGIN PASSWORD '$APP_PASSWORD'; \
ELSE ALTER ROLE $role PASSWORD '$APP_PASSWORD'; END IF; END \$\$;" >/dev/null \
            || die "创建角色 $role 失败"
    done
    for db in $DATABASES; do
        if [ -z "$(psql_admin "select 1 from pg_database where datname = '$db'")" ]; then
            psql_admin "create database $db owner $WRITE_USER" >/dev/null \
                || die "创建物理库 $db 失败"
        fi
    done
    # 只读账号只授 SELECT：写语句若被错误路由到读节点，postgres 直接 permission denied
    # （ALTER DEFAULT PRIVILEGES 让 demo 之后 DDL 广播建出的新表自动对 fdbm_r 可读）
    for db in $DATABASES; do
        psql_app "$db" "GRANT USAGE ON SCHEMA public TO $READ_USER; \
GRANT SELECT ON ALL TABLES IN SCHEMA public TO $READ_USER; \
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO $READ_USER;" >/dev/null \
            || die "授权失败（$db）"
    done
    say "init-db 完成：角色 $WRITE_USER(可写)/$READ_USER(只读)；物理库 $DATABASES"
    echo "表（t_order / t_dict）由演示客户端经 DDL 广播创建。"
}

# ---------------------------------------------------------------------------
# fdbm 配置与进程管理
# ---------------------------------------------------------------------------
fdbm_bin() {
    if [ -n "${FDBM_BIN:-}" ] && [ -x "$FDBM_BIN" ]; then echo "$FDBM_BIN"; return 0; fi
    if command -v fdbm >/dev/null 2>&1; then command -v fdbm; return 0; fi
    if [ -x "$HOME/.cjpm/bin/fdbm" ]; then echo "$HOME/.cjpm/bin/fdbm"; return 0; fi
    # cjpm 的产物名取自源码入口：fdbm 的 main.cj → target/release/bin/main
    for candidate in \
        "$SCRIPT_DIR/../fdbm/target/release/bin/main" \
        "$SCRIPT_DIR/../fdbm/target/release/bin/fdbm" \
        "$SCRIPT_DIR/../fdbm/target/release/fdbm"; do
        if [ -x "$candidate" ]; then echo "$candidate"; return 0; fi
    done
    echo "找不到 fdbm 可执行文件：cd ../fdbm && cjpm build，或 export FDBM_BIN=..." >&2
    return 1
}

# config_env <port> <cache 目录> <输出文件> <是否多挂 spare 库 0|1>
#   spare 库（逻辑库 spare = 物理库 spare_0）只配在第二个实例上，
#   于是 `show databases` 的返回就成了"这次连接落在哪个实例"的探针。
config_env() {
    local port="$1" cache="$2" out="$3" with_spare="${4:-0}"
    local node_dbs='demo_0,demo_1'
    if [ "$with_spare" = "1" ]; then
        node_dbs='demo_0,demo_1,spare_0'
    fi
    {
        # ---- 服务与进程 ----
        echo "export fdbm_port=$port"
        echo "export fdbm_bootScript=$SCRIPT_DIR/boot.sh"
        echo "export fdbm_driverDir=$SCRIPT_DIR/driver"
        echo "export fdbm_customDir=$SCRIPT_DIR/custom"
        echo "export fdbm_checkDuration=15s"
        echo "export fdbm_unavailableChecked=6"
        echo "export fdbm_sessionSweepInterval=2s"
        echo "export fdbm_shutdownTimeout=10s"
        # ---- 物理节点与凭据（n1=写角色，n2=读角色；host:port 是 WSL postgres）----
        echo "export fdbm_db=\"n1@$PGHOST:$PGPORT;n2@$PGHOST:$PGPORT\""
        echo "export fdbm_db_driver_n1=postgres"
        echo "export fdbm_db_database_n1=$node_dbs"
        echo "export fdbm_db_username_n1=$WRITE_USER"
        echo "export fdbm_db_password_n1=$APP_PASSWORD"
        echo "export fdbm_db_driver_n2=postgres"
        echo "export fdbm_db_database_n2=$node_dbs"
        echo "export fdbm_db_username_n2=$READ_USER"
        echo "export fdbm_db_password_n2=$APP_PASSWORD"
        # ---- 逻辑库映射 ----
        echo "export fdbm_db_logicalDatabase_demo=demo_0,demo_1"
        if [ "$with_spare" = "1" ]; then
            echo "export fdbm_db_logicalDatabase_spare=spare_0"
        fi
        # ---- 连接池 ----
        echo "export fdbm_databasePoolInitSize=1"
        echo "export fdbm_databasePoolMinSize=1"
        echo "export fdbm_databasePoolMaxSize=4"
        echo "export fdbm_databasePoolCheckOnBorrowing=true"
        echo 'export fdbm_databasePoolCheckSql="select 1"'
        echo "export fdbm_databasePoolConnectTimeout=5000"
        # ---- 负载均衡与读写权重：n1 只写、n2 只读 ----
        echo "export fdbm_loadbalance=roundrobin"
        echo 'export fdbm_loadbalance_weight_n1="w,1;r,0"'
        echo 'export fdbm_loadbalance_weight_n2="w,0;r,1"'
        # ---- 分库与全局表 ----
        echo "export fdbm_partition__t_order=demo,hash,id"
        echo "export fdbm_global__t_dict=demo"
        # ---- ID 生成 ----
        echo "export fdbm_idmaker=uuid"
        # ---- 分库缓存 ----
        echo "export fdbm_cache=true"
        echo "export fdbm_cachePath=$cache"
        # ---- 日志 ----
        # 【必填】本机在集群内的唯一主机号（MessageID 拒绝 hostId=0）
        echo "export protocol_hostId=1"
        echo "export logger_appender_console=FdbmConsole"
        echo "export logger_appender_FdbmConsole_level=INFO"
        echo "export logger_appender_FdbmConsole_pattern='[%level-%name]%m'"
    } > "$out"
}

# 仓颉运行时与标准库（stdx）动态库目录；envsetup 已设置 CANGJIE_HOME/CANGJIE_STDX_DYNAMIC_PATH
cangjie_runtime_libs() {
    local dirs=''
    if [ -n "${CANGJIE_HOME:-}" ]; then
        dirs="$(ls -d "$CANGJIE_HOME"/runtime/lib/*/ 2>/dev/null | tr '\n' ':')"
    fi
    printf '%s' "${dirs}${CANGJIE_STDX_DYNAMIC_PATH:-}"
}

start_fdbm() {
    local port="$1" with_spare="${2:-0}"
    local cache="$SCRIPT_DIR/cache_$port"
    local log="$SCRIPT_DIR/fdbm_$port.log"
    local envfile="$SCRIPT_DIR/.fdbm_env_$port.sh"
    # 端口已有人在听：说明该实例已在运行（或别的进程占用了端口），不要盲目再起一个
    if wait_port "$port"; then
        echo "fdbm($port) 端口已被占用：若为本 demo 实例见 ./boot.sh status" >&2
        return 0
    fi
    mkdir -p "$SCRIPT_DIR/driver" "$SCRIPT_DIR/custom" "$cache"
    if [ -z "$(find "$SCRIPT_DIR/driver" -name '*.so' 2>/dev/null | head -1)" ]; then
        die "driver/ 目录没有驱动库：先执行 ./boot.sh driver"
    fi
    config_env "$port" "$cache" "$envfile" "$with_spare"
    local bin
    bin="$(fdbm_bin)" || exit 1
    # cjpm 把 fdbm 的 path 依赖各自编译到 target/release/<pkg>@<org>/，运行时必须都在 LD_LIBRARY_PATH 里
    local bin_dir dep_libs pidfile
    bin_dir="$(dirname "$bin")"
    dep_libs="$(find "$bin_dir/.." -maxdepth 1 -type d -name '*@*' 2>/dev/null | tr '\n' ':')"
    pidfile="$SCRIPT_DIR/fdbm_$port.pid"
    # setsid：脱离当前会话，避免启动脚本所在会话结束时把 fdbm 一起带走；
    # pid 由内层 bash 自己写（setsid 在交互 shell 里可能 fork，$! 不一定是 fdbm 的 pid）
    (
        set -a
        # shellcheck disable=SC1090
        . "$envfile"
        set +a
        export LD_LIBRARY_PATH="${bin_dir}:${dep_libs}$(cangjie_runtime_libs):${LD_LIBRARY_PATH:-}"
        exec setsid bash -c "echo \$\$ > '${pidfile}'; exec '${bin}'"
    ) > "$log" 2>&1 < /dev/null &
    if ! wait_port "$port"; then
        tail -30 "$log" >&2
        die "fdbm($port) 启动失败"
    fi
    echo "fdbm 已启动：port=$port pid=$(cat "$pidfile" 2>/dev/null) log=fdbm_$port.log"
}

start_all() {
    start_fdbm "$FDBM_PORT1" 0
    start_fdbm "$FDBM_PORT2" 1      # 第二个实例多挂逻辑库 spare ⇒ 客户端可据此判断落点
    echo
    echo "两个 fdbm 已就绪。运行演示：./boot.sh demo"
}

stop_fdbm() {
    local port="$1"
    local pidfile="$SCRIPT_DIR/fdbm_$port.pid"
    [ -f "$pidfile" ] || { echo "fdbm($port) 未在运行"; return 0; }
    local pid
    pid="$(cat "$pidfile")"
    kill -15 "$pid" 2>/dev/null || true
    local tries=0
    while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 100 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        echo "fdbm($port) 未在 10s 内退出，已强制结束" >&2
    fi
    rm -f "$pidfile"
    echo "fdbm($port) 已停止（优雅停止标记见 fdbm_$port.log 的 'fdbm is stopping'）"
}

stop_all() {
    stop_fdbm "$FDBM_PORT1"
    stop_fdbm "$FDBM_PORT2"
}

status_all() {
    for port in "$FDBM_PORT1" "$FDBM_PORT2"; do
        local pidfile="$SCRIPT_DIR/fdbm_$port.pid"
        if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
            if wait_port "$port"; then
                echo "fdbm($port): 运行中 (pid $(cat "$pidfile"))"
            else
                echo "fdbm($port): 进程存活但端口未监听 (pid $(cat "$pidfile"))"
            fi
        else
            echo "fdbm($port): 已停止"
        fi
    done
}

# check：用 psql 直接核对物理库 —— 分片分布 / 全局表副本 / 只读权限
check_db() {
    say "分片分布（t_order 按 hash(id) 落 demo_0 / demo_1）"
    for db in $SHARD_DBS; do
        echo "$db: t_order=$(psql_app "$db" "select count(*) from t_order") t_dict=$(psql_app "$db" "select count(*) from t_dict")"
    done
    say "全局表副本（t_dict 在 demo 的每个物理库都应有一份）"
    for db in $SHARD_DBS; do
        echo "$db: $(psql_app "$db" "select code || '=' || label from t_dict order by code" | tr '\n' ' ')"
    done
    say "读写分离权限（$READ_USER 只读：CREATE 权限应为 f）"
    for db in $SHARD_DBS; do
        echo "$db: $READ_USER 可建表=$(psql_app "$db" "select has_database_privilege('$READ_USER', current_database(), 'CREATE')")"
    done
    say "spare 物理库（仅用于区分两个 fdbm 实例，不含业务表）"
    echo "spare_0: t_order 存在=$(psql_app spare_0 "select to_regclass('t_order') is not null")"
}

fboot_bin() {
    if [ -n "${FBOOT_BIN:-}" ] && [ -x "$FBOOT_BIN" ]; then echo "$FBOOT_BIN"; return 0; fi
    if command -v fboot >/dev/null 2>&1; then command -v fboot; return 0; fi
    if [ -x "$HOME/.cjpm/bin/fboot" ]; then echo "$HOME/.cjpm/bin/fboot"; return 0; fi
    if [ -x "$SCRIPT_DIR/../fboot/target/release/fboot" ]; then
        echo "$SCRIPT_DIR/../fboot/target/release/fboot"; return 0
    fi
    echo "找不到 fboot：cjpm install fountain::fboot --root <dir> 后加入 PATH，或 cd ../fboot && cjpm build" >&2
    return 1
}

build_demo() {
    command -v cjpm >/dev/null 2>&1 || die "cjpm 不在 PATH（先 source envsetup）"
    local fboot
    fboot="$(fboot_bin)" || exit 1
    say "编译客户端（workspace 成员一律编译为动态库）"
    ( cd "$SCRIPT_DIR" && "$fboot" build ./target ) || die "客户端构建失败"
    echo "产物：$(find "$SCRIPT_DIR/target/release" -name '*fdbmdemo_client*' -type f 2>/dev/null | head -3 | tr '\n' ' ')"
}

run_demo() {
    for port in "$FDBM_PORT1" "$FDBM_PORT2"; do
        wait_port "$port" || die "fdbm($port) 未启动：先 ./boot.sh start"
    done
    local fboot
    fboot="$(fboot_bin)" || exit 1
    build_demo
    # 自建库目录必须排在 LD_LIBRARY_PATH 前面，否则可能命中安装目录里的旧副本
    # （旧 .so 无 SONAME，链接器按文件名先命中它 → undefined symbol）；规则同 frpcdemo/boot.sh
    local libs
    libs="$(find "$SCRIPT_DIR/target/release" -type d 2>/dev/null | grep -a -v -P '_stAtIc__' | tr '\n' ':')"
    local fboot_dir
    fboot_dir="$(dirname "$fboot")"
    say "fboot 启动客户端（动态库 + Initializer.start）"
    ( cd "$SCRIPT_DIR" \
        && export LD_LIBRARY_PATH="${libs}${fboot_dir}/../libs/fboot:$(cangjie_runtime_libs):${LD_LIBRARY_PATH:-}" \
        && export logger_appender_console=FdbmDemoConsole \
        && export logger_appender_FdbmDemoConsole_level=INFO \
        && export logger_appender_FdbmDemoConsole_pattern='[%level-%name]%m' \
        && "$fboot" run ./target --dylibPattern='(fdbmdemo_client)' )
}

case "${1:-}" in
    driver)  build_driver ;;
    init-db) init_db ;;
    start)   start_all ;;
    stop)    stop_all ;;
    status)  status_all ;;
    restart) stop_all; start_all ;;
    check)   check_db ;;
    build)   build_demo ;;
    demo)    run_demo ;;
    *)
        echo "usage: $0 {driver|init-db|start|stop|status|restart|check|build|demo}" >&2
        exit 2
        ;;
esac
