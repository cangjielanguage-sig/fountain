#!/bin/bash
# PostgreSQL 后端：建角色/库、序列种子、逐库核对。
# 由 run.sh source；依赖 lib.sh 的 say/fail/db 工具。

PGHOST="${FDBM_E2E_PGHOST:-127.0.0.1}"
PGPORT="${FDBM_E2E_PGPORT:-5432}"
PGADMIN="${FDBM_E2E_PGADMIN:-postgres}"
DB_USER="${FDBM_E2E_DB_USER:-fdbm_rw}"
DB_READ_USER="${FDBM_E2E_DB_READ_USER:-fdbm_ro}"
DB_PASSWORD="${FDBM_E2E_DB_PASSWORD:-fdbm_pw}"
DATABASES=(db0 db1 db2 db3)
DB_LIST="$(IFS=,; echo "${DATABASES[*]}")"
DB_TABLES=(t_step t_hash t_substr t_global t_plain t_stream t_orm orm_item t_shard_probe)

admin_sql() {
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGADMIN" -v ON_ERROR_STOP=1 -tAc "$1"
}

db_sql() {
    local db="$1"; local sql="$2"
    PGPASSWORD="$DB_PASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$DB_USER" -d "$db" \
        -v ON_ERROR_STOP=1 -tAc "$sql"
}

# 管理员连通性；psql 必须在 PATH。
backend_admin_check() {
    command -v psql >/dev/null || fail "psql not found"
    admin_sql "select 1" >/dev/null || fail "cannot connect to PostgreSQL as $PGADMIN"
}

backend_prepare() {
    for role in "$DB_USER" "$DB_READ_USER"; do
        admin_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$role') THEN CREATE ROLE $role LOGIN SUPERUSER PASSWORD '$DB_PASSWORD'; ELSE ALTER ROLE $role PASSWORD '$DB_PASSWORD'; END IF; END \$\$;" >/dev/null
    done
    for db in "${DATABASES[@]}"; do
        if [ -z "$(admin_sql "select 1 from pg_database where datname = '$db'")" ]; then
            admin_sql "create database $db owner $DB_USER" >/dev/null
        fi
    done

    say "清理物理库并准备 sequence"
    local drops=""
    for table in "${DB_TABLES[@]}"; do
        drops="$drops drop table if exists $table;"
    done
    for db in "${DATABASES[@]}"; do
        db_sql "$db" "$drops" >/dev/null
    done
    db_sql db0 "create table if not exists fountain_sequence (table_name text primary key, current_value bigint not null, increment bigint not null);
delete from fountain_sequence where table_name = 'app.t_step';
insert into fountain_sequence (table_name, current_value, increment) values ('app.t_step', 500, 1);" >/dev/null

    say "准备分片探针表（每个物理库只放本分片的一行）"
    local index=0
    for db in "${DATABASES[@]}"; do
        local id=$((1 + 1000 * index))
        db_sql "$db" "create table t_shard_probe (id bigint primary key, tag varchar(64));
insert into t_shard_probe (id, tag) values ($id, '$db');" >/dev/null
        index=$((index + 1))
    done
}

backend_server_env() {
    echo "export fdbm_db=\"name0@$PGHOST:$PGPORT;name1@$PGHOST:$PGPORT\""
    echo "export fdbm_db_driver_name0=postgres"
    echo "export fdbm_db_database_name0=$DB_LIST"
    echo "export fdbm_db_username_name0=$DB_USER"
    echo "export fdbm_db_password_name0=$DB_PASSWORD"
    echo "export fdbm_db_driver_name1=postgres"
    echo "export fdbm_db_database_name1=$DB_LIST"
    echo "export fdbm_db_username_name1=$DB_READ_USER"
    echo "export fdbm_db_password_name1=$DB_PASSWORD"
    echo "export fdbm_db_logicalDatabase_app=$DB_LIST"
}

backend_driver_so() {
    echo "libpostgres_driver.so"
}

backend_verify() {
    for db in "${DATABASES[@]}"; do
        [ "$(db_sql "$db" "select to_regclass('t_step') is not null")" = "t" ] || fail "$db missing t_step"
    done
    [ "$(db_sql db0 "select count(*) from t_step where id in (1,2)")" = "2" ] || fail "db0 step rows"
    [ "$(db_sql db1 "select count(*) from t_step where id = 1001")" = "1" ] || fail "db1 step rows"
    [ "$(db_sql db2 "select count(*) from t_step where id = 2001")" = "0" ] || fail "db2 step row (should be deleted)"
    [ "$(db_sql db3 "select count(*) from t_step where id = 3001")" = "1" ] || fail "db3 step rows"
    local hash_total=0
    for db in "${DATABASES[@]}"; do
        hash_total=$((hash_total + $(db_sql "$db" "select count(*) from t_hash")))
    done
    [ "$hash_total" -eq 7 ] || fail "hash rows total=$hash_total (expect 7 after delete)"
    local substr_total=0
    for db in "${DATABASES[@]}"; do
        substr_total=$((substr_total + $(db_sql "$db" "select count(*) from t_substr")))
    done
    [ "$substr_total" -eq 2 ] || fail "substr rows total=$substr_total"
    for db in "${DATABASES[@]}"; do
        [ "$(db_sql "$db" "select count(*) from t_global where k = 1")" = "0" ] || fail "$db global k=1 should be deleted"
        [ "$(db_sql "$db" "select v from t_global where k = 2")" = "left2" ] || fail "$db global k=2 missing"
    done
    [ "$(db_sql db0 "select octet_length(data) from t_stream where id = 1")" = "200000" ] || fail "bytea not stored"
    [ "$(db_sql db0 "select name from t_orm where id = 1")" = "updated" ] || fail "orm row missing"
    # 分片探针：未限定名的读写必须落在路由算出的物理库（其余库不应出现这些行）
    [ "$(db_sql db0 "select tag from t_shard_probe where id = 1")" = "db0" ] || fail "db0 shard probe row"
    [ "$(db_sql db1 "select tag from t_shard_probe where id = 1001")" = "app-w" ] || fail "db1 shard probe write"
    [ "$(db_sql db2 "select tag from t_shard_probe where id = 2005")" = "app-i" ] || fail "db2 shard probe insert"
    [ "$(db_sql db2 "select count(*) from t_shard_probe")" = "2" ] || fail "db2 shard probe rows"
    [ "$(db_sql db3 "select count(*) from t_shard_probe")" = "0" ] || fail "db3 shard probe delete"
}
