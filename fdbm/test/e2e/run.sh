#!/bin/bash
# f_dbd ↔ fdbm ↔ 真库联调（后端矩阵：postgres / mysql）。
#
# 前置：
#   - 对应后端已启动（默认 PostgreSQL 127.0.0.1:5432、MySQL 127.0.0.1:3306）；
#   - PostgreSQL 要求 `postgres` 超级用户免密；MySQL 要求 `root`（默认空密码）；
#   - 中心仓可访问（postgres_driver / mysql_driver 0.1.0）；
#   - 已 source 仓颉 envsetup（cjpm / cjc 在 PATH，CANGJIE_STDX_DYNAMIC_PATH 已设置）。
#
# 用法：bash fdbm/test/e2e/run.sh [postgres|mysql]
set -euo pipefail

BACKEND="${1:-postgres}"
case "$BACKEND" in
    postgres|mysql) ;;
    *) echo "usage: $0 [postgres|mysql]" >&2; exit 2 ;;
esac

E2E="$(cd "$(dirname "$0")" && pwd)"
FDBM_ROOT="$(cd "$E2E/../.." && pwd)"
REPO_ROOT="$(cd "$FDBM_ROOT/.." && pwd)"
# /tmp 在融合侧可能是小容量 tmpfs；默认跟随 TMPDIR，避免编译产物把 /tmp 撑满。
: "${TMPDIR:=/var/tmp}"
export TMPDIR
WORK="${FDBM_E2E_WORK:-$TMPDIR/fdbm-$BACKEND-e2e}"

# shellcheck source=lib.sh
source "$E2E/lib.sh"
# shellcheck source=backends/$BACKEND.sh
source "$E2E/backends/$BACKEND.sh"

command -v cjpm >/dev/null || fail "cjpm not found (source envsetup first)"
: "${CANGJIE_STDX_DYNAMIC_PATH:?CANGJIE_STDX_DYNAMIC_PATH is not set}"

say "准备 $BACKEND 与联调目录"
if [ "${FDBM_E2E_SKIP_BUILD:-0}" = "1" ]; then
    # 编译耗时较长时先把构建拆成独立调用；这里复用已有安装产物，只清运行期产物。
    [ -x "$WORK/install/bin/fdbm" ] || fail "FDBM_E2E_SKIP_BUILD=1 but $WORK/install/bin/fdbm is missing"
    rm -rf "$WORK"/cache_* "$WORK"/export_*.sh "$WORK"/fdbm_*.log "$WORK"/*.pid 2>/dev/null || true
else
    rm -rf "$WORK"
    mkdir -p "$WORK/driver" "$WORK/custom" "$WORK/install"
fi
backend_admin_check
backend_prepare

if [ "${FDBM_E2E_SKIP_BUILD:-0}" != "1" ]; then
    BUNDLE="$E2E/driver_bundle_postgres"
    if [ "$BACKEND" = "mysql" ]; then
        BUNDLE="$E2E/driver_bundle_mysql"
    fi
    say "构建 $BACKEND 驱动动态库"
    build_driver "$BUNDLE" "$(backend_driver_so)"

    say "构建并安装 fdbm"
    build_fdbm
fi

PORT1="$(pick_port)"
PORT2="$(pick_port)"
say "启动两个 fdbm：$PORT1 / $PORT2"
start_server "$PORT1" "$WORK/cache_$PORT1" "$WORK/export_$PORT1.sh" "$WORK/fdbm_$PORT1.log"
start_server "$PORT2" "$WORK/cache_$PORT2" "$WORK/export_$PORT2.sh" "$WORK/fdbm_$PORT2.log"

say "运行联调客户端（backend=$BACKEND）"
cd "$E2E/client"
set +e
FDBM_E2E_BACKEND="$BACKEND" dbd_driverName=fdbm \
    FDBM_E2E_PORT="$PORT1" FDBM_E2E_PORT2="$PORT2" \
    cjpm run > "$WORK/client.log" 2>&1
CLIENT_EXIT=$?
set -e
check_client_log "$WORK/client.log" "client"
[ "$CLIENT_EXIT" -eq 0 ] || { echo "client failed (exit $CLIENT_EXIT)" >&2; exit 1; }

say "运行 f_orm 客户端（f_orm 零改动，dbd_driverName=$BACKEND）"
cd "$E2E/orm_client"
set +e
FDBM_E2E_BACKEND="$BACKEND" dbd_driverName="$BACKEND" orm_drivers="$BACKEND" \
    FDBM_E2E_PORT="$PORT1" \
    cjpm run > "$WORK/orm.log" 2>&1
ORM_EXIT=$?
set -e
check_client_log "$WORK/orm.log" "orm client"
[ "$ORM_EXIT" -eq 0 ] || { echo "orm client failed (exit $ORM_EXIT)" >&2; exit 1; }

say "逐库核对 DDL 广播 / 分片分布 / 全局表副本"
backend_verify
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
FDBM_E2E_BACKEND="$BACKEND" dbd_driverName=fdbm FDBM_E2E_PROBE=1 FDBM_E2E_PORT="$PORT1" \
    cjpm run > "$WORK/probe.log" 2>&1 \
    || { tail -20 "$WORK/probe.log" >&2; fail "restart probe failed"; }
grep -E "^(PASS|FAIL) " "$WORK/probe.log" | tail -5
grep -q "^E2E_DONE$" "$WORK/probe.log" || { echo "probe aborted" >&2; exit 1; }
stop_server "$PORT1" "$WORK/fdbm_restart_$PORT1.log"

say "T07 自定义扩展：构建真实 .so 并验证分区/ID 生成"
cd "$E2E/custom_ext"
CANGJIE_STDX_PATH="$CANGJIE_STDX_DYNAMIC_PATH" cjpm build -j "$BUILD_JOBS" > "$WORK/custom-build.log" 2>&1 \
    || { tail -30 "$WORK/custom-build.log" >&2; fail "custom extension build failed"; }
CUSTOM_SO="$(find target/release -name 'libfdbm_custom_ext.so' | head -1)"
[ -n "$CUSTOM_SO" ] || fail "libfdbm_custom_ext.so not found"
cp "$CUSTOM_SO" "$WORK/custom/"

PORT3="$(pick_port)"
cat > "$WORK/custom_env.sh" <<CUSTOM_ENV
export CUSTOM_EXT_ALGORITHM=marker
export CUSTOM_EXT_IDGEN=markergen
export fdbm_partition__t_custom="app,marker,id"
export fdbm_idmaker=markergen
export fdbm_databasePoolMaxSize=1
export fdbm_databasePoolMinSize=1
export fdbm_databasePoolInitSize=1
CUSTOM_ENV
start_server "$PORT3" "$WORK/cache_$PORT3" "$WORK/export_$PORT3.sh" "$WORK/fdbm_custom.log" "$WORK/custom_env.sh"
grep -q "custom partition algorithm" "$WORK/fdbm_custom.log" || fail "custom extension not loaded"

cd "$E2E/client"
set +e
FDBM_E2E_CUSTOM=1 FDBM_E2E_BACKEND="$BACKEND" dbd_driverName=fdbm FDBM_E2E_PORT="$PORT3" cjpm run > "$WORK/custom_client.log" 2>&1
CUSTOM_EXIT=$?
set -e
check_client_log "$WORK/custom_client.log" "custom client"
[ "$CUSTOM_EXIT" -eq 0 ] || { echo "custom client failed (exit $CUSTOM_EXIT)" >&2; exit 1; }

custom_total=0
custom_nonempty=0
for db in "${DATABASES[@]}"; do
    n="$(db_sql "$db" "select count(*) from t_custom")"
    custom_total=$((custom_total + n))
    if [ "$n" -gt 0 ]; then
        custom_nonempty=$((custom_nonempty + 1))
    fi
done
custom_want=5
if [ "$BACKEND" = "postgres" ]; then custom_want=6; fi
[ "$custom_total" -eq "$custom_want" ] || fail "custom partition rows = $custom_total (want $custom_want)"
[ "$custom_nonempty" -ge 2 ] || fail "custom algorithm kept all rows on one database"
stop_server "$PORT3" "$WORK/fdbm_custom.log"

say "T07 自定义扩展与内置算法同名 → 启动失败（PARTITION_CONFIG）"
PORT4="$(pick_port)"
cat > "$WORK/custom_conflict_env.sh" <<CUSTOM_CONFLICT
export CUSTOM_EXT_ALGORITHM=hash
CUSTOM_CONFLICT
(
    set -a
    # shellcheck disable=SC1090
    . "$WORK/env_$PORT3.sh"
    . "$WORK/custom_conflict_env.sh"
    set +a
    export fdbm_port=$PORT4
    export LD_LIBRARY_PATH="$WORK/install/libs/fdbm:$CANGJIE_STDX_DYNAMIC_PATH:$CANGJIE_HOME/runtime/lib/linux_aarch64_cjnative:${LD_LIBRARY_PATH:-}"
    exec "$WORK/install/bin/fdbm"
) > "$WORK/fdbm_conflict.log" 2>&1 &
CONFLICT_PID=$!
set +e
wait "$CONFLICT_PID"
CONFLICT_EXIT=$?
set -e
[ "$CONFLICT_EXIT" -eq 1 ] || fail "conflicting custom name must exit 1 (got $CONFLICT_EXIT)"
(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":$PORT4 " && fail "conflicting fdbm must not listen"
rm -f "$WORK/custom/"libfdbm_custom_ext.so

say "T08 进程级：坏配置启动 → 退出码 1 且端口未监听"
PORT5="$(pick_port)"
(
    set -a
    # shellcheck disable=SC1090
    . "$WORK/env_$PORT3.sh"
    set +a
    export fdbm_port=$PORT5
    export fdbm_shutdownTimeout=0
    export LD_LIBRARY_PATH="$WORK/install/libs/fdbm:$CANGJIE_STDX_DYNAMIC_PATH:$CANGJIE_HOME/runtime/lib/linux_aarch64_cjnative:${LD_LIBRARY_PATH:-}"
    exec "$WORK/install/bin/fdbm"
) > "$WORK/fdbm_bad_config.log" 2>&1 &
BAD_PID=$!
set +e
wait "$BAD_PID"
BAD_EXIT=$?
set -e
[ "$BAD_EXIT" -eq 1 ] || fail "bad config must exit 1 (got $BAD_EXIT)"
(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":$PORT5 " && fail "bad-config fdbm must not listen"

say "通过：$BACKEND 真库联调全部用例"
