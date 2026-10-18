#!/bin/bash
# f_dbd ↔ fdbm ↔ PostgreSQL 真库联调。
#
# 前置：
#   - 融合侧已启动 PostgreSQL（默认 127.0.0.1:5432），且能以 postgres 超级用户免密登录；
#   - 中心仓可访问（postgres_driver 0.1.0）；
#   - 已 source 仓颉 envsetup（cjpm / cjc 在 PATH，CANGJIE_STDX_DYNAMIC_PATH 已设置）。
#
# 覆盖：
#   fdbm：DDL 广播、未分库表、step/hash/substr 路由、范围合并、全局表读写广播、
#         序列 ID、INSERT…SELECT、SHOW、EXPORT、事务/savepoint、DELETE 三步、
#         大字段、错误码、读写分离、缓存落盘与重启。
#   f_dbd：驱动/连接元数据、参数绑定、get/getOrNull、结果集独占、关闭握手、MultiD。
#
# 用法：bash fdbm/test/postgres_e2e/run.sh
set -euo pipefail

E2E="$(cd "$(dirname "$0")" && pwd)"
FDBM_ROOT="$(cd "$E2E/../.." && pwd)"
REPO_ROOT="$(cd "$FDBM_ROOT/.." && pwd)"
WORK="${FDBM_E2E_WORK:-/tmp/fdbm-postgres-e2e}"

PGHOST="${FDBM_E2E_PGHOST:-127.0.0.1}"
PGPORT="${FDBM_E2E_PGPORT:-5432}"
PGADMIN="${FDBM_E2E_PGADMIN:-postgres}"
DB_USER="${FDBM_E2E_DB_USER:-fdbm_rw}"
DB_READ_USER="${FDBM_E2E_DB_READ_USER:-fdbm_ro}"
DB_PASSWORD="${FDBM_E2E_DB_PASSWORD:-fdbm_pw}"
DATABASES=(db0 db1 db2 db3)
DB_LIST="$(IFS=,; echo "${DATABASES[*]}")"

say() { printf '\n=== %s ===\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v psql >/dev/null || fail "psql not found"
command -v cjpm >/dev/null || fail "cjpm not found (source envsetup first)"
: "${CANGJIE_STDX_DYNAMIC_PATH:?CANGJIE_STDX_DYNAMIC_PATH is not set}"

admin_sql() {
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGADMIN" -v ON_ERROR_STOP=1 -tAc "$1"
}

db_sql() {
    local db="$1"; local sql="$2"
    PGPASSWORD="$DB_PASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$DB_USER" -d "$db" \
        -v ON_ERROR_STOP=1 -tAc "$sql"
}

pick_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_port() {
    local port="$1"; local tries=0
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

start_server() {
    local port="$1"; local cache="$2"; local export="$3"; local log="$4"
    local envfile="$WORK/env_$port.sh"
    cat > "$envfile" <<EOF
export fdbm_port=$port
export fdbm_bootScript=$export
export fdbm_driverDir=$WORK/driver
export fdbm_customDir=$WORK/custom
export fdbm_checkDuration=15s
export fdbm_unavailableChecked=6
export fdbm_sessionSweepInterval=2s
export fdbm_shutdownTimeout=10s
export fdbm_db="name0@$PGHOST:$PGPORT;name1@$PGHOST:$PGPORT"
export fdbm_db_driver_name0=postgres
export fdbm_db_database_name0=$DB_LIST
export fdbm_db_username_name0=$DB_USER
export fdbm_db_password_name0=$DB_PASSWORD
export fdbm_db_driver_name1=postgres
export fdbm_db_database_name1=$DB_LIST
export fdbm_db_username_name1=$DB_READ_USER
export fdbm_db_password_name1=$DB_PASSWORD
export fdbm_db_logicalDatabase_db0=$DB_LIST
export fdbm_databasePoolInitSize=1
export fdbm_databasePoolMinSize=1
export fdbm_databasePoolMaxSize=4
export fdbm_databasePoolCheckOnBorrowing=true
export fdbm_databasePoolCheckSql="select 1"
export fdbm_databasePoolConnectTimeout=5000
export fdbm_loadbalance=roundrobin
export fdbm_loadbalance_weight_name0="w,1;r,0"
export fdbm_loadbalance_weight_name1="w,0;r,1"
export fdbm_partition_step=1000
export fdbm_partition__t_step="db0,step,id"
export fdbm_partition__t_hash="db0,hash,user_id"
export fdbm_partition__t_substr="db0,substr,account_no"
export fdbm_partition_substr__t_substr="0,2,crc32"
export fdbm_global__dict="db0"
export fdbm_global__t_global="db0"
export fdbm_idmaker=sequence
export fdbm_sequenceDatabase=db0
export fdbm_cache=true
export fdbm_cachePath=$cache
export fdbm_cache_size=0
export logger_appender_console=FdbmConsole
export logger_appender_FdbmConsole_level=INFO
EOF
    touch "$export"
    (
        set -a
        # shellcheck disable=SC1090
        . "$envfile"
        set +a
        export LD_LIBRARY_PATH="$WORK/install/libs/fdbm:$CANGJIE_STDX_DYNAMIC_PATH:$CANGJIE_HOME/runtime/lib/linux_aarch64_cjnative:${LD_LIBRARY_PATH:-}"
        exec "$WORK/install/bin/fdbm"
    ) > "$log" 2>&1 &
    local pid=$!
    echo "$pid" > "$WORK/fdbm_$port.pid"
    if ! wait_port "$port"; then
        tail -30 "$log" >&2
        fail "fdbm on port $port did not start"
    fi
    echo "fdbm started on $port (pid $pid)"
}

stop_server() {
    local port="$1"; local log="$2"
    local pidfile="$WORK/fdbm_$port.pid"
    [ -f "$pidfile" ] || return 0
    local pid; pid="$(cat "$pidfile")"
    kill -TERM "$pid" 2>/dev/null || true
    local tries=0
    while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 100 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        fail "fdbm on port $port did not stop"
    fi
    grep -q "fdbm is stopping" "$log" || fail "no graceful-stop marker in $log"
    echo "fdbm stopped on $port"
}

say "准备 PostgreSQL 与联调目录"
rm -rf "$WORK"
mkdir -p "$WORK/driver" "$WORK/custom" "$WORK/install"
admin_sql "select 1" >/dev/null || fail "cannot connect to PostgreSQL as $PGADMIN"

for role in "$DB_USER" "$DB_READ_USER"; do
    admin_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$role') THEN CREATE ROLE $role LOGIN SUPERUSER PASSWORD '$DB_PASSWORD'; ELSE ALTER ROLE $role PASSWORD '$DB_PASSWORD'; END IF; END \$\$;" >/dev/null
done
for db in "${DATABASES[@]}"; do
    if [ -z "$(admin_sql "select 1 from pg_database where datname = '$db'")" ]; then
        admin_sql "create database $db owner $DB_USER" >/dev/null
    fi
done

say "构建 postgres_driver 动态库"
cd "$E2E/driver_bundle"
CANGJIE_STDX_PATH="$CANGJIE_STDX_DYNAMIC_PATH" cjpm build > "$WORK/driver-build.log" 2>&1 \
    || { tail -30 "$WORK/driver-build.log" >&2; fail "driver build failed"; }
DRIVER_SO="$(find target/release -name 'libpostgres_driver.so' | head -1)"
[ -n "$DRIVER_SO" ] || fail "libpostgres_driver.so not found"
cp "$DRIVER_SO" "$WORK/driver/"

say "构建并安装 fdbm"
cd "$FDBM_ROOT"
cjpm build > "$WORK/fdbm-build.log" 2>&1 || { tail -30 "$WORK/fdbm-build.log" >&2; fail "fdbm build failed"; }
rm -rf "$WORK/install"
cjpm install --root "$WORK/install" > "$WORK/fdbm-install.log" 2>&1 \
    || { tail -30 "$WORK/fdbm-install.log" >&2; fail "fdbm install failed"; }

say "清理物理库并准备 sequence"
for db in "${DATABASES[@]}"; do
    db_sql "$db" "drop table if exists t_step; drop table if exists t_hash; drop table if exists t_substr; drop table if exists t_global; drop table if exists t_plain; drop table if exists t_stream;" >/dev/null
done
db_sql db0 "create table if not exists fountain_sequence (table_name text primary key, current_value bigint not null, increment bigint not null);
delete from fountain_sequence where table_name = 'db0.t_step';
insert into fountain_sequence (table_name, current_value, increment) values ('db0.t_step', 500, 1);" >/dev/null

PORT1="$(pick_port)"
PORT2="$(pick_port)"
say "启动两个 fdbm：$PORT1 / $PORT2"
start_server "$PORT1" "$WORK/cache_$PORT1" "$WORK/export_$PORT1.sh" "$WORK/fdbm_$PORT1.log"
start_server "$PORT2" "$WORK/cache_$PORT2" "$WORK/export_$PORT2.sh" "$WORK/fdbm_$PORT2.log"

say "运行联调客户端"
cd "$E2E/client"
set +e
dbd_driverName=fdbm FDBM_E2E_PORT="$PORT1" FDBM_E2E_PORT2="$PORT2" \
    cjpm run > "$WORK/client.log" 2>&1
CLIENT_EXIT=$?
set -e
grep -E "^(PASS|FAIL) " "$WORK/client.log" | tail -20
tail -2 "$WORK/client.log"
grep -q "^E2E_DONE$" "$WORK/client.log" || { echo "client aborted before finishing" >&2; exit 1; }
grep -q "^checks=.*failures=0$" "$WORK/client.log" || { echo "client reported failures" >&2; exit 1; }
[ "$CLIENT_EXIT" -eq 0 ] || { echo "client failed (exit $CLIENT_EXIT)" >&2; exit 1; }

say "运行 f_orm 客户端（f_orm 零改动，dbd_driverName=postgres）"
cd "$E2E/orm_client"
set +e
dbd_driverName=postgres orm_drivers=postgres FDBM_E2E_PORT="$PORT1" \
    cjpm run > "$WORK/orm.log" 2>&1
ORM_EXIT=$?
set -e
grep -E "^(PASS|FAIL) " "$WORK/orm.log" | tail -15
grep -q "^E2E_DONE$" "$WORK/orm.log" || { tail -20 "$WORK/orm.log" >&2; echo "orm client aborted" >&2; exit 1; }
grep -q "^checks=.*failures=0$" "$WORK/orm.log" || { echo "orm client reported failures" >&2; exit 1; }
[ "$ORM_EXIT" -eq 0 ] || { echo "orm client failed (exit $ORM_EXIT)" >&2; exit 1; }

say "逐库核对 DDL 广播 / 分片分布 / 全局表副本"
for db in "${DATABASES[@]}"; do
    [ "$(db_sql "$db" "select to_regclass('t_step') is not null")" = "t" ] || fail "$db missing t_step"
done
[ "$(db_sql db0 "select count(*) from t_step where id in (1,2)")" = "2" ] || fail "db0 step rows"
[ "$(db_sql db1 "select count(*) from t_step where id = 1001")" = "1" ] || fail "db1 step rows"
[ "$(db_sql db2 "select count(*) from t_step where id = 2001")" = "0" ] || fail "db2 step row (should be deleted)"
[ "$(db_sql db3 "select count(*) from t_step where id = 3001")" = "1" ] || fail "db3 step rows"
HASH_TOTAL=0
for db in "${DATABASES[@]}"; do
    HASH_TOTAL=$((HASH_TOTAL + $(db_sql "$db" "select count(*) from t_hash")))
done
[ "$HASH_TOTAL" -eq 7 ] || fail "hash rows total=$HASH_TOTAL (expect 7 after delete)"
SUBSTR_TOTAL=0
for db in "${DATABASES[@]}"; do
    SUBSTR_TOTAL=$((SUBSTR_TOTAL + $(db_sql "$db" "select count(*) from t_substr")))
done
[ "$SUBSTR_TOTAL" -eq 2 ] || fail "substr rows total=$SUBSTR_TOTAL"
for db in "${DATABASES[@]}"; do
    [ "$(db_sql "$db" "select count(*) from t_global where k = 1")" = "0" ] || fail "$db global k=1 should be deleted"
    [ "$(db_sql "$db" "select v from t_global where k = 2")" = "left2" ] || fail "$db global k=2 missing"
done
[ "$(db_sql db0 "select octet_length(data) from t_stream where id = 1")" = "200000" ] || fail "bytea not stored"
[ "$(db_sql db0 "select name from t_orm where id = 1")" = "updated" ] || fail "orm row missing"
[ -s "$WORK/export_$PORT1.sh" ] || fail "export script not written"
grep -q "fdbm_port='19999'" "$WORK/export_$PORT1.sh" || fail "export did not persist fdbm_port"

say "核对分库缓存落盘"
[ -d "$WORK/cache_$PORT1" ] || fail "cache directory missing"
[ "$(find "$WORK/cache_$PORT1" -type f | wc -l)" -gt 0 ] || fail "cache is empty"

say "优雅停止并重启（缓存/重启探针）"
stop_server "$PORT1" "$WORK/fdbm_$PORT1.log"
stop_server "$PORT2" "$WORK/fdbm_$PORT2.log"
start_server "$PORT1" "$WORK/cache_$PORT1" "$WORK/export_$PORT1.sh" "$WORK/fdbm_restart_$PORT1.log"
cd "$E2E/client"
dbd_driverName=fdbm FDBM_E2E_PROBE=1 FDBM_E2E_PORT="$PORT1" cjpm run > "$WORK/probe.log" 2>&1 \
    || { tail -20 "$WORK/probe.log" >&2; fail "restart probe failed"; }
grep -E "^(PASS|FAIL) " "$WORK/probe.log" | tail -5
grep -q "^E2E_DONE$" "$WORK/probe.log" || { echo "probe aborted" >&2; exit 1; }
stop_server "$PORT1" "$WORK/fdbm_restart_$PORT1.log"

say "通过：PostgreSQL 真库联调全部用例"
