/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package postgres_e2e_client

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.database.sql.*
import std.env.getVariable
import std.env.getVariable
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.driver.*
import fountain::f_dbd.exception.DbdException
import fountain::f_dbd.multid.MultiD

var checks: Int64 = 0
var failures: Int64 = 0

func check(name: String, ok: Bool): Unit {
    checks += 1
    if (ok) {
        println('PASS ${name}')
    } else {
        failures += 1
        println('FAIL ${name}')
    }
}

func checkInt(name: String, actual: Int64, expected: Int64): Unit {
    check('${name} (${actual} == ${expected})', actual == expected)
}

func checkText(name: String, actual: String, expected: String): Unit {
    check('${name} (${actual} == ${expected})', actual == expected)
}

func codeOf(body: () -> Unit): DbdErrorCode {
    try {
        body()
    } catch (e: DbdException) {
        return e.code
    } catch (_: Exception) {
        return DbdErrorCode.INTERNAL
    }
    DbdErrorCode.INTERNAL
}

func execUpdate(connection: Connection, sql: String): Int64 {
    let statement = connection.prepareStatement(sql)
    try {
        statement.update().rowCount
    } finally {
        statement.close()
    }
}

/** 单行结果：返回首行首列（字符串）；无行返回 None。 */
func firstText(connection: Connection, sql: String): ?String {
    let statement = connection.prepareStatement(sql)
    try {
        let result = statement.query()
        try {
            if (result.next()) {
                Some(result.get<String>(0))
            } else {
                None<String>
            }
        } finally {
            result.close()
        }
    } finally {
        statement.close()
    }
}

func rowCount(connection: Connection, sql: String): Int64 {
    let statement = connection.prepareStatement(sql)
    try {
        let result = statement.query()
        try {
            var count: Int64 = 0
            while (result.next()) {
                count += 1
            }
            count
        } finally {
            result.close()
        }
    } finally {
        statement.close()
    }
}

func port(): UInt16 {
    match (getVariable('FDBM_E2E_PORT')) {
        case Some(value) => UInt16.parse(value)
        case None => 18112u16
    }
}

func backend(): String {
    match (getVariable('FDBM_E2E_BACKEND')) {
        case Some(value) => value
        case None => 'postgres'
    }
}

func isMySql(): Bool {
    backend() == 'mysql'
}

/**
 * 部署的逻辑库名（`fdbm_db_logicalDatabase_<name>`）。
 *
 * e2e 故意让逻辑库名 ≠ 物理库名（`app` vs `db0..db3`），未限定读写必须按路由落到物理库，
 * 只连接逻辑库名才能暴露「默认库落到物理库名」这类缺陷。
 */
func logicalDatabase(): String {
    'app'
}

/** 两个后端都接受的文本类型（MySQL 的 `text` 不能做分库键主键）。 */
func textType(): String {
    'varchar(64)'
}

func blobType(): String {
    if (isMySql()) { 'longblob' } else { 'bytea' }
}

func firstInt(connection: Connection, sql: String): Int64 {
    let statement = connection.prepareStatement(sql)
    try {
        let result = statement.query()
        try {
            if (result.next()) {
                result.get<Int64>(0)
            } else {
                0
            }
        } finally {
            result.close()
        }
    } finally {
        statement.close()
    }
}

func secondPort(): UInt16 {
    match (getVariable('FDBM_E2E_PORT2')) {
        case Some(value) => UInt16.parse(value)
        case None => 18113u16
    }
}

/**
 * 真库联调客户端（设计 §13 的 `fdemo + 真实 postgres` 替代夹具）。
 *
 * 覆盖 fdbm：DDL 广播、未分库表、step/hash/substr 路由、范围合并、全局表写广播、
 * 序列 ID、INSERT…SELECT、SHOW、EXPORT、事务/savepoint、DELETE 三步、大字段、错误码。
 * 覆盖 f_dbd：连接元数据、参数绑定、get/getOrNull、结果集独占与关闭握手、MultiD。
 */
main(): Int64 {
    if (isProbe()) {
        return probe()
    }
    let base = 'fdbm://fdbm@127.0.0.1:${port()}/${logicalDatabase()}'
    let datasource = dbdDriver().open(base, [])
    datasource.setOption('query_timeout', '30000')
    datasource.setOption('update_timeout', '30000')
    datasource.setOption('fetch_rows', '8192')
    let connection = datasource.connect()
    try {
        driverAndMetadata(connection)
        ddlAndUnpartitioned(connection)
        shardProbe(connection)
        stepRouting(connection)
        hashAndSubstring(connection)
        globalTable(connection)
        sequenceIds(connection)
        insertSelect(connection)
        showAndExport(connection)
        transactions(connection)
        deleteFlow(connection)
        largeValues(connection)
        cursorSemantics(connection)
        errorMapping(connection)
        sqlExtensions(connection)
    } finally {
        connection.close()
        datasource.close()
    }
    multiD()
    println('----')
    println('checks=${checks}, failures=${failures}')
    println('E2E_DONE')
    if (failures == 0) {
        0
    } else {
        1
    }
}

func isProbe(): Bool {
    match (getVariable('FDBM_E2E_PROBE')) {
        case Some(value) => value == '1'
        case None => false
    }
}

/** 重启后的最小探针：只证明新进程仍能服务（不重建数据）。 */
func probe(): Int64 {
    let datasource = dbdDriver().open(
        'fdbm://fdbm@127.0.0.1:${port()}/${logicalDatabase()}', [])
    let connection = datasource.connect()
    try {
        // 逻辑库口径：e2e 部署显式声明逻辑库 app，物理库不单独出现
        checkInt('probe show databases', rowCount(connection, 'show databases'), 1)
        checkText('probe step select', firstText(connection,
            'select name from t_step where id = 2') ?? '', 'src1')
    } finally {
        connection.close()
        datasource.close()
    }
    println('probe checks=${checks}, failures=${failures}')
    println('E2E_DONE')
    if (failures == 0) { 0 } else { 1 }
}

func driverAndMetadata(connection: Connection): Unit {
    let driver = dbdDriver()
    // 注册名 = dbd_driverName（后端方言名），fdbm 只作兼容别名
    checkText('driver.name', driver.name, getVariable('dbd_driverName') ?? '')
    check('driver.preferredPooling', driver.preferredPooling)
    check('driver.version', !driver.version.isEmpty())
    let meta = connection.getMetaData()
    checkText('metadata.database', meta.get('database') ?? '', logicalDatabase())
    checkText('metadata.user', meta.get('user') ?? '', 'fdbm')
    check('metadata.no-password', meta.get('password').isNone())
}

func ddlAndUnpartitioned(connection: Connection): Unit {
    for (sql in [
        'drop table if exists t_step',
        'drop table if exists t_hash',
        'drop table if exists t_substr',
        'drop table if exists t_global',
        'drop table if exists t_plain',
        'drop table if exists t_stream'
    ]) {
        checkInt('ddl ${sql}', execUpdate(connection, sql), 0)
    }
    checkInt('ddl create t_step', execUpdate(connection,
        'create table t_step (id bigint primary key, name ${textType()})'), 0)
    checkInt('ddl create t_hash', execUpdate(connection,
        'create table t_hash (id bigint primary key, user_id bigint, name ${textType()})'), 0)
    checkInt('ddl create t_substr', execUpdate(connection,
        'create table t_substr (account_no ${textType()} primary key, name ${textType()})'), 0)
    checkInt('ddl create t_global', execUpdate(connection,
        'create table t_global (k bigint primary key, v ${textType()})'), 0)
    checkInt('ddl create t_plain', execUpdate(connection,
        'create table t_plain (id bigint primary key, name ${textType()})'), 0)
    checkInt('ddl create t_stream', execUpdate(connection,
        'create table t_stream (id bigint primary key, data ${blobType()})'), 0)

    // 未分库表：INSERT/UPDATE/DELETE/SELECT 都按 Single 走
    let insert = connection.prepareStatement('insert into t_plain (id, name) values (?, ?)')
    try {
        insert.set<Int64>(0, 10)
        insert.set<String>(1, 'p')
        checkInt('plain insert', insert.update().rowCount, 1)
    } finally {
        insert.close()
    }
    checkText('plain select', firstText(connection,
        'select name from t_plain where id = 10') ?? '', 'p')
    checkInt('plain update', execUpdate(connection,
        "update t_plain set name = 'p2' where id = 10"), 1)
    checkText('plain select after update', firstText(connection,
        'select name from t_plain where id = 10') ?? '', 'p2')

    let nullInsert = connection.prepareStatement('insert into t_plain (id, name) values (?, ?)')
    try {
        nullInsert.set<Int64>(0, 11)
        nullInsert.setNull(1)
        checkInt('plain insert null', nullInsert.update().rowCount, 1)
    } finally {
        nullInsert.close()
    }
    let nullQuery = connection.prepareStatement('select name from t_plain where id = 11')
    try {
        let result = nullQuery.query()
        try {
            check('null row exists', result.next())
            check('null getOrNull is None', result.getOrNull<String>(0).isNone())
        } finally {
            result.close()
        }
    } finally {
        nullQuery.close()
    }

    checkInt('plain multi-row insert', execUpdate(connection,
        "insert into t_plain (id, name) values (12, 'a'), (13, 'b')"), 2)
    checkInt('plain delete', execUpdate(connection,
        'delete from t_plain where id = 10'), 1)
    checkInt('plain select after delete', rowCount(connection,
        'select id from t_plain where id = 10'), 0)
}

/**
 * 逻辑库 ≠ 物理库时的路由证据（D03 / 任务 1.15）。
 *
 * `t_shard_probe` 由 `backends` 下的脚本直接建在物理库里，**每个物理库只放本分片的那一行**
 * （db0→id=1、db1→id=1001、db2→id=2001、db3→id=3001），因此客户端用未限定名读写时
 * 命中的物理库由返回值/行数直接暴露：路由错了就查不到行，写错了就读不回新值。
 */
func shardProbe(connection: Connection): Unit {
    checkText('shard probe read db0', firstText(connection,
        'select tag from t_shard_probe where id = 1') ?? '', 'db0')
    checkText('shard probe read db1', firstText(connection,
        'select tag from t_shard_probe where id = 1001') ?? '', 'db1')
    checkText('shard probe read db2', firstText(connection,
        'select tag from t_shard_probe where id = 2001') ?? '', 'db2')
    checkText('shard probe read db3', firstText(connection,
        'select tag from t_shard_probe where id = 3001') ?? '', 'db3')
    checkInt('shard probe range spans shards', rowCount(connection,
        'select tag from t_shard_probe where id between 1 and 3001'), 4)

    // 写：未限定名必须在 db1 上更新（其它库没有 id=1001，写错就回读不到新值）
    checkInt('shard probe update db1', execUpdate(connection,
        "update t_shard_probe set tag = 'app-w' where id = 1001"), 1)
    checkText('shard probe update visible', firstText(connection,
        'select tag from t_shard_probe where id = 1001') ?? '', 'app-w')
    checkInt('shard probe insert db2', execUpdate(connection,
        "insert into t_shard_probe (id, tag) values (2005, 'app-i')"), 1)
    checkText('shard probe insert visible', firstText(connection,
        'select tag from t_shard_probe where id = 2005') ?? '', 'app-i')
    checkInt('shard probe delete db3', execUpdate(connection,
        'delete from t_shard_probe where id = 3001'), 1)
    checkInt('shard probe delete verified', rowCount(connection,
        'select tag from t_shard_probe where id = 3001'), 0)
}

func stepRouting(connection: Connection): Unit {
    for (id in [1, 1001, 2001, 3001]) {
        checkInt('step insert ${id}', execUpdate(connection,
            "insert into t_step (id, name) values (${id}, 's${id}')"), 1)
    }
    checkText('step point select', firstText(connection,
        'select name from t_step where id = 1001') ?? '', 's1001')
    checkInt('step multi range', rowCount(connection,
        'select id from t_step where id between 1 and 3001'), 4)
    checkInt('step one-sided range', rowCount(connection,
        'select id from t_step where id > 2000'), 2)
    checkInt('step empty range', rowCount(connection,
        'select id from t_step where id > 5000'), 0)
    checkInt('step update multi', execUpdate(connection,
        "update t_step set name = 'm' where id in (1, 1001)"), 2)
    checkInt('step delete one', execUpdate(connection,
        'delete from t_step where id = 2001'), 1)
    checkInt('step delete verified', rowCount(connection,
        'select id from t_step where id = 2001'), 0)
}

func hashAndSubstring(connection: Connection): Unit {
    var user: Int64 = 1
    while (user <= 8) {
        checkInt('hash insert ${user}', execUpdate(connection,
            "insert into t_hash (id, user_id, name) values (${user}, ${user}, 'u${user}')"), 1)
        checkText('hash select ${user}', firstText(connection,
            "select name from t_hash where user_id = ${user}") ?? '', 'u${user}')
        user += 1
    }
    checkInt('substr insert', execUpdate(connection,
        "insert into t_substr (account_no, name) values ('AB001', 'a')"), 1)
    checkInt('substr insert 2', execUpdate(connection,
        "insert into t_substr (account_no, name) values ('CD002', 'c')"), 1)
    checkText('substr select', firstText(connection,
        "select name from t_substr where account_no = 'AB001'") ?? '', 'a')
}

func globalTable(connection: Connection): Unit {
    // 4 个物理库各一副副本 → INSERT 影响 4 行
    checkInt('global insert broadcast', execUpdate(connection,
        "insert into t_global (k, v) values (1, 'g')"), 4)
    checkInt('global update broadcast', execUpdate(connection,
        "update t_global set v = 'g2' where k = 1"), 4)
    checkInt('global read one replica', rowCount(connection,
        'select v from t_global where k = 1'), 1)
    checkText('global read value', firstText(connection,
        'select v from t_global where k = 1') ?? '', 'g2')
    checkInt('global delete broadcast', execUpdate(connection,
        'delete from t_global where k = 1'), 4)
    checkInt('global delete verified', rowCount(connection,
        'select v from t_global where k = 1'), 0)
    // 留一份 k=2 供 run.sh 逐库核对"每个物理库都有副本"
    checkInt('global insert marker', execUpdate(connection,
        "insert into t_global (k, v) values (2, 'left')"), 4)
    checkInt('global marker update', execUpdate(connection,
        "update t_global set v = 'left2' where k = 2"), 4)
}

func sequenceIds(connection: Connection): Unit {
    checkInt('sequence insert without id', execUpdate(connection,
        "insert into t_step (name) values ('seq')"), 1)
    checkInt('sequence insert second', execUpdate(connection,
        "insert into t_step (name) values ('seq2')"), 1)
    // SequenceIdGenerator 返回 current_value + increment（首值 501、次值 502）
    checkInt('sequence generated rows', rowCount(connection,
        'select id from t_step where id in (501, 502)'), 2)
}

func insertSelect(connection: Connection): Unit {
    checkInt('insert-select source', execUpdate(connection,
        "insert into t_step (id, name) values (2, 'src1')"), 1)
    checkInt('insert select', execUpdate(connection,
        'insert into t_plain (id, name) select id, name from t_step where id = 2'), 1)
    checkText('insert select value', firstText(connection,
        'select name from t_plain where id = 2') ?? '', 'src1')
}

func showAndExport(connection: Connection): Unit {
    let st = connection.prepareStatement('show databases')
    try {
        let rs = st.query()
        let names = ArrayList<String>()
        try {
            while (rs.next()) {
                names.add(rs.get<String>(0))
            }
        } finally {
            rs.close()
        }
        checkInt('show databases count', names.size, 1)
        check('show databases content', names.contains(logicalDatabase()))
    } finally {
        st.close()
    }

    let defaultTables = tableNames(connection, 'show tables')
    check('show tables contains t_step', defaultTables.contains('t_step'))
    check('show tables contains t_plain', defaultTables.contains('t_plain'))
    check('show tables column name', rsInfoName(connection) == 'table_name')
    // 显式逻辑库与默认库（会话默认库 = 唯一逻辑库）给出同一份内省结果
    let appTables = tableNames(connection, 'show tables ${logicalDatabase()}')
    check('show tables app contains t_step', appTables.contains('t_step'))
    checkInt('show tables app equals default', appTables.size, defaultTables.size)
    // 未知逻辑库 → ROUTE_FAILED
    check('show tables unknown database', codeOf {
        rowCount(connection, 'show tables nope')
    } == DbdErrorCode.ROUTE_FAILED)
    // 物理库名不是逻辑库命名空间：限定到物理名必须被拒绝，不再静默落到 db0
    check('physical name is not a logical database', codeOf {
        rowCount(connection, 'select id from db0.t_step where id = 1')
    } == DbdErrorCode.ROUTE_FAILED)

    checkInt('export write', execUpdate(connection,
        "export fdbm_port='19999'"), 0)
    check('export rejects unknown key',
        codeOf { execUpdate(connection, "export evil_key='1'") } == DbdErrorCode.CONFIG)
}

func tableNames(connection: Connection, sql: String): ArrayList<String> {
    let statement = connection.prepareStatement(sql)
    try {
        let rs = statement.query()
        let names = ArrayList<String>()
        try {
            while (rs.next()) {
                names.add(rs.get<String>(0))
            }
        } finally {
            rs.close()
        }
        names
    } finally {
        statement.close()
    }
}

func rsInfoName(connection: Connection): String {
    let st = connection.prepareStatement("show tables like 't_%'")
    try {
        let rs = st.query()
        try {
            rs.columnInfos[0].name
        } finally {
            rs.close()
        }
    } finally {
        st.close()
    }
}

func transactions(connection: Connection): Unit {
    let transaction = connection.createTransaction()
    transaction.begin()
    execUpdate(connection, "insert into t_plain (id, name) values (20, 'rollback')")
    transaction.rollback()
    checkInt('transaction rollback', rowCount(connection,
        'select id from t_plain where id = 20'), 0)

    transaction.begin()
    execUpdate(connection, "insert into t_plain (id, name) values (21, 'commit')")
    transaction.commit()
    checkInt('transaction commit', rowCount(connection,
        'select id from t_plain where id = 21'), 1)

    transaction.begin()
    execUpdate(connection, "insert into t_plain (id, name) values (22, 'before-sp')")
    transaction.save('sp1')
    execUpdate(connection, "insert into t_plain (id, name) values (23, 'after-sp')")
    transaction.rollback('sp1')
    transaction.commit()
    checkInt('savepoint rollback inner', rowCount(connection,
        'select id from t_plain where id = 23'), 0)
    checkInt('savepoint keeps outer', rowCount(connection,
        'select id from t_plain where id = 22'), 1)

    check('commit without begin', codeOf { transaction.commit() } == DbdErrorCode.TX_STATE)
}

func deleteFlow(connection: Connection): Unit {
    checkInt('delete sharded by key', execUpdate(connection,
        'delete from t_hash where user_id = 3'), 1)
    checkInt('delete sharded verified', rowCount(connection,
        'select id from t_hash where user_id = 3'), 0)
}

func largeValues(connection: Connection): Unit {
    let payload = Array<Byte>(200_000, repeat: 0x41)
    // 二进制参数在 DataAny 线缆编解码中不支持（DataCollection 会退化成 `_`），
    // 这里用服务端 decode() 写入；f_dbd 的二进制结果读取仍走真实链路。
    let digits = '0123456789abcdef'
    let hex = StringBuilder()
    for (byte in payload) {
        let value = Int64(byte)
        let high = (value >> 4) & 0x0F
        let low = value & 0x0F
        hex.append(digits[high..high + 1])
        hex.append(digits[low..low + 1])
    }
    // PostgreSQL 的未知类型字面量按目标列（bytea）解释 `\x...`；MySQL 用 X'...' 十六进制字面量
    let literal = if (isMySql()) { "X'${hex}'" } else { "'\\x${hex}'" }
    checkInt('blob insert', execUpdate(connection,
        "insert into t_stream (id, data) values (1, ${literal})"), 1)
    // 二进制结果无法跨 DataAny 线缆（DataCollection 会退化成 `_`），
    // 由 run.sh 用 psql 校验 octet_length；此处只验证大字段写入成功。

}

func cursorSemantics(connection: Connection): Unit {
    let first = connection.prepareStatement('select id from t_step where id = 1')
    let result = first.query()
    check('cursor has row', result.next())
    check('second query while result open',
        codeOf {
            let other = connection.prepareStatement('select id from t_step where id = 1001')
            try {
                other.query()
            } finally {
                other.close()
            }
        } == DbdErrorCode.CURSOR_STATE)
    result.close()
    result.close()
    checkText('query after early close', firstText(connection,
        'select id from t_step where id = 1') ?? '', '1')
    first.close()
}

func errorMapping(connection: Connection): Unit {
    // 解析器自身拒绝的语句（不完整 WHERE）→ SQL_SYNTAX
    check('syntax error', codeOf { firstText(connection, 'select * from t_step where') } ==
        DbdErrorCode.SQL_SYNTAX)
    check('missing table', codeOf {
        firstText(connection, 'select id from no_such_table where id = 1')
    } == DbdErrorCode.DB_ERROR)
    check('update without partition key', codeOf {
        execUpdate(connection, "update t_step set name = 'x'")
    } == DbdErrorCode.ROUTE_FAILED)
}

/**
 * f_orm 分页/实体插入依赖的最小 SQL 子集：`returning`、`count(*)`、派生表分页。
 *
 * 这些用例在全部数据操作之后执行，计数基于本函数之前的最终分布。
 */
func sqlExtensions(connection: Connection): Unit {
    if (isMySql()) {
        check('returning rejected on mysql', codeOf {
            execUpdate(connection, "insert into t_plain (id, name) values (100, 'ret') returning id")
        } == DbdErrorCode.UNSUPPORTED_SQL)
        checkInt('returning rejected leaves no row', rowCount(connection,
            'select id from t_plain where id = 100'), 0)
    } else {
        let insert = connection.prepareStatement(
            "insert into t_plain (id, name) values (100, 'ret') returning id")
        try {
            let result = insert.update()
            checkInt('returning row count', result.rowCount, 1)
            checkInt('returning lastInsertId', result.lastInsertId, 100)
        } finally {
            insert.close()
        }
        checkText('returning row visible', firstText(connection,
            'select name from t_plain where id = 100') ?? '', 'ret')
        checkInt('returning cleanup', execUpdate(connection,
            'delete from t_plain where id = 100'), 1)
    }

    checkInt('count single shard', firstInt(connection,
        'select count(*) from t_step where id = 1'), 1)
    checkInt('count derived multi shard', firstInt(connection,
        'select count(*) from (select 1 from t_step where id between 1 and 3001) as c'), 6)
    checkInt('count empty route', firstInt(connection,
        'select count(*) from t_step where id > 5000 and id < 1000'), 0)
    checkInt('count global table one replica', firstInt(connection,
        'select count(*) from t_global'), 1)

    checkInt('paging single shard rows', rowCount(connection,
        'select * from (select id from t_step where id >= 1 and id < 1000 order by id) as p ' +
        'limit 2 offset 1'), 2)
    checkText('paging single shard first id', firstText(connection,
        'select id from (select id from t_step where id >= 1 and id < 1000 order by id) as p ' +
        'limit 2 offset 1') ?? '', '2')
    check('paging multi shard rejected', codeOf {
        rowCount(connection,
            'select * from (select id from t_step where id in (1, 1001)) as p limit 1 offset 0')
    } == DbdErrorCode.ROUTE_FAILED)
    checkInt('derived broadcast without paging', rowCount(connection,
        'select * from (select id from t_step where id in (1, 1001)) as p'), 2)
}

func multiD(): Unit {
    let url = 'multidbd://fdbm@127.0.0.1:${port()},fdbm@127.0.0.1:${secondPort()}/' +
        logicalDatabase()
    let driver = match (DriverManager.getDriver('multidbd')) {
        case Some(value) => value
        case None =>
            check('multidbd registered', false)
            return
    }
    check('multidbd registered', true)
    let datasource = driver.open(url, [])
    let connection = datasource.connect()
    try {
        checkInt('multidb show databases', rowCount(connection, 'show databases'), 1)
        checkText('multidb select', firstText(connection,
            'select name from t_step where id = 2') ?? '', 'src1')
    } finally {
        connection.close()
        datasource.close()
    }
}
