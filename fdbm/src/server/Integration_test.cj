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
package fountain::fdbm.server

import std.collection.{ArrayList, HashMap}
import std.database.sql.*
import std.fs.*
import std.io.InputStream
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.driver.dbdDriver
import fountain::f_mockdb.*
import fountain::fdbm.config.{ConfigSource, FdbmSettings, MapConfigSource}
import fountain::fdbm.exception.FdbmException

/**
 * 阶段 9 集成：真实 f_dbd 驱动 ↔ 真实 fdbm 服务 ↔ f_mockdb 物理驱动。
 *
 * 覆盖建表/插入/查询/更新/删除/事务/游标关闭/show/export 的完整链路；
 * 物理库不会真执行 SQL，用例断言的是**下推序列与线上结果**。
 */
@Test
public class IntegrationTest {

    @TestCase
    public func crudRoundTripThroughFdbm(): Unit {
        let fixture = integrationFixture()
        let connection = fixture.connect('db0')
        try {
            connection.prepareStatement('create table t (id bigint, name varchar(64))').update()
            @Assert(countOf(fixture.sqls, {sql => sql.startsWith('create table t')}), 2) // 广播到 db0 / db1

            let insert = connection.prepareStatement("insert into t (id, name) values (5, 'a')")
            @Assert(insert.update().rowCount, 1)

            let query = connection.prepareStatement('select * from t where id = 5').query()
            try {
                @Assert(query.columnInfos[0].typeName, 'Int64')
                @Assert(query.next(), true)
                @Assert(query.get<Int64>(0), 1)
            } finally {
                query.close()
            }

            let update = connection.prepareStatement("update t set name = 'b' where id = 5").update()
            @Assert(update.rowCount, 1)
            let delete = connection.prepareStatement('delete from t where id = 5').update()
            @Assert(delete.rowCount, 1)

            let databases = connection.prepareStatement('show databases').query()
            try {
                let names = ArrayList<String>()
                while (databases.next()) {
                    names.add(databases.get<String>(0))
                }
                // 逻辑库命名空间：分区规则引用 db0，隐式展开为全部物理库（D03）
                @Assert(names.toArray(), ['db0'])
            } finally {
                databases.close()
            }

            // mockdb 不是 mysql/postgres：show tables 必须明确报 UNSUPPORTED_SQL
            let unsupported = DbdErrorCode.UNSUPPORTED_SQL.value
            try {
                connection.prepareStatement('show tables').query()
                @Assert(true, false)
            } catch (e: SqlException) {
                @Assert(e.errorCode, unsupported)
            }
        } finally {
            connection.close()
            fixture.close()
        }
    }

    /** T06：物理 `typeName`（int4 / TINYINT(1) / bytea）必须归一成仓颉类型名再发给客户端。 */
    @TestCase
    public func columnTypesAreCanonicalizedBeforeSending(): Unit {
        let fixture = integrationFixture(columnTypes: ['int4', 'TINYINT(1)', 'bytea'])
        let connection = fixture.connect('db0')
        try {
            let query = connection.prepareStatement('select * from t').query()
            try {
                @Assert(query.columnInfos[0].typeName, 'Int32')
                @Assert(query.columnInfos[1].typeName, 'Bool')
                @Assert(query.columnInfos[2].typeName, 'Array<Byte>')
            } finally {
                query.close()
            }
        } finally {
            connection.close()
            fixture.close()
        }
    }

    /** G23：`show tables` 失败（未知方言）后连接必须归还，`maxSize=1` 下后续查询仍可用。 */
    @TestCase
    public func showFailureReturnsConnectionUnderSingleSlotPool(): Unit {
        let fixture = integrationFixture(maxSize: 1)
        let connection = fixture.connect('db0')
        try {
            var failed = false
            try {
                connection.prepareStatement('show tables').query()
            } catch (_: Exception) {
                failed = true
            }
            @Assert(failed, true)
            let after = connection.prepareStatement('select * from t where id = 5').query()
            @Assert(after.next(), true)
            after.close()
        } finally {
            connection.close()
            fixture.close()
        }
    }

    /** T09：`maxSize=1` 下关游标、DDL 失败后连接都必须归还，否则下一次查询会超时。 */
    @TestCase
    public func connectionsAreReturnedUnderSingleSlotPool(): Unit {
        let fixture = integrationFixture(maxSize: 1)
        let connection = fixture.connect('db0')
        try {
            let first = connection.prepareStatement('select * from t where id = 5').query()
            @Assert(first.next(), true)
            first.close()

            let second = connection.prepareStatement('select * from t where id = 5').query()
            @Assert(second.next(), true)
            second.close()

            var failed = false
            try {
                connection.prepareStatement('create table bad (id bigint)').update()
            } catch (_: Exception) {
                failed = true
            }
            @Assert(failed, true)

            let third = connection.prepareStatement('select * from t where id = 5').query()
            @Assert(third.next(), true)
            third.close()
        } finally {
            connection.close()
            fixture.close()
        }
    }

    @TestCase
    public func closeSendsUnsubscribeAndReleasesCursor(): Unit {
        let fixture = integrationFixture()
        let connection = fixture.connect('db0')
        try {
            let query = connection.prepareStatement('select * from t where id = 5').query()
            @Assert(query.next(), true)
            @Assert(query.get<Int64>(0), 1)
            query.close()
            // 关闭后同一连接可继续执行语句（结果集独占已释放）
            let next = connection.prepareStatement('select * from t where id = 5').query()
            @Assert(next.next(), true)
            next.close()
        } finally {
            connection.close()
            fixture.close()
        }
    }

    @TestCase
    public func transactionPinsOneConnection(): Unit {
        let fixture = integrationFixture()
        let connection = fixture.connect('db0')
        try {
            let transaction = connection.createTransaction()
            transaction.begin()
            let first = connection.prepareStatement("insert into t (id, name) values (5, 'a')")
            @Assert(first.update().rowCount, 1)
            let second = connection.prepareStatement('select * from t where id = 5').query()
            @Assert(second.next(), true)
            second.close()
            transaction.commit()
            @Assert(countOf(fixture.sqls, {sql => sql == 'begin'}), 1)
            @Assert(countOf(fixture.sqls, {sql => sql == 'commit'}), 1)
        } finally {
            connection.close()
            fixture.close()
        }
    }

    @TestCase
    public func streamColumnIsChunkedOnce(): Unit {
        let bytes: Array<Byte> = [1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let fixture = integrationFixture(stream: Some(bytes))
        let connection = fixture.connect('db0')
        try {
            let statement = connection.prepareStatement('select payload from t where id = 5')
            statement.setOption('fetch_rows', '3')
            let query = statement.query()
            try {
                @Assert(query.next(), true)
                let stream = query.get<InputStream>(0)
                let received = ArrayList<Byte>()
                while (true) {
                    let buffer = Array<Byte>(4, repeat: 0u8)
                    let n = stream.read(buffer)
                    if (n <= 0) {
                        break
                    }
                    for (i in 0..n) {
                        received.add(buffer[i])
                    }
                }
                @Assert(received.toArray(), bytes)
            } finally {
                query.close()
            }
        } finally {
            connection.close()
            fixture.close()
        }
    }

    @TestCase
    public func exportWritesBootScriptThroughFdbm(): Unit {
        let dir = Directory.createTemp('/tmp')
        let script = dir.join('boot.sh')
        File.writeTo(script, '#!/bin/bash\n'.toArray())
        let fixture = integrationFixture(bootScript: script.toString())
        let connection = fixture.connect('db0')
        try {
            let result = connection.prepareStatement("export fdbm_port='9000'").update()
            @Assert(result.rowCount, 0)
            @Assert(String.fromUtf8(File.readFrom(script)).contains("export fdbm_port='9000'"), true)
        } finally {
            connection.close()
            fixture.close()
            try {
                remove(dir, recursive: true)
            } catch (_: Exception) {
                ()
            }
        }
    }

    // ==================== 夹具 ====================

    private func integrationFixture(stream!: ?Array<Byte> = None,
        bootScript!: String = '/tmp/definitely-missing-boot.sh',
        maxSize!: Int64 = 4, columnTypes!: ?Array<String> = None): IntegrationFixture {
        let sqls = ArrayList<String>()
        MOCKDB.clear()
        MOCKDB.execution = {sql, _ =>
            sqls.add(sql)
            if (sql.startsWith('create table bad')) {
                throw FdbmException(DbdErrorCode.SQL_SYNTAX, 'injected DDL failure')
            }
            if (sql.startsWith('select') || sql.startsWith('show')) {
                if (let Some(types) <- columnTypes) {
                    var index: Int64 = 0
                    for (typeName in types) {
                        MOCKDB.addQueryResultColumnInfo(name: 'c${index}', nullable: false,
                            typeName: typeName)
                        index += 1
                    }
                    MOCKDB.addQueryResultRow([1, true, Array<Byte>(2, repeat: 7u8)])
                } else if (stream.isSome()) {
                    MOCKDB.addQueryResultColumnInfo(name: 'payload', nullable: false,
                        typeName: 'InputStream')
                    MOCKDB.addQueryResultRow([BytesStream(stream.getOrThrow())])
                } else {
                    MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
                    MOCKDB.addQueryResultRow([1])
                }
            } else {
                MOCKDB.rowCount = 1
            }
        }
        let port = uniquePort()
        let source = mapSource(port, bootScript: bootScript, maxSize: maxSize)
        let settings = FdbmSettings.load(source: source)
        let server = FdbmServer(settings, source: source,
            driver: DriverManager.getDriver('mockdb').getOrThrow())
        let started = server
        spawn {
            try {
                started.start()
            } catch (_: Exception) {
                ()
            }
        }
        waitForPort(port)
        IntegrationFixture(server, port, sqls)
    }

    private func mapSource(port: UInt16,
        bootScript!: String = '/tmp/definitely-missing-boot.sh',
        maxSize!: Int64 = 4): ConfigSource {
        let values = HashMap<String, String>()
        values['fdbm_port'] = port.toString()
        values['fdbm_db'] = 'name0@127.0.0.1:3306'
        values['fdbm_db_driver_name0'] = 'mockdb'
        values['fdbm_db_database_name0'] = 'db0,db1'
        values['fdbm_idmaker'] = 'uuid,4'
        values['fdbm_cache'] = 'false'
        values['fdbm_driverDir'] = '/tmp/definitely-missing-driver'
        values['fdbm_customDir'] = '/tmp/definitely-missing-custom'
        values['fdbm_bootScript'] = bootScript
        values['fdbm_sessionSweepInterval'] = '50ms'
        values['fdbm_shutdownTimeout'] = '2s'
        values['fdbm_checkDuration'] = '1s'
        values['fdbm_databasePoolInitSize'] = '0'
        values['fdbm_databasePoolMaxSize'] = maxSize.toString()
        values['fdbm_databasePoolCheckOnBorrowing'] = 'false'
        values['fdbm_partition__t'] = 'db0,step,id'
        values['fdbm_partition_step'] = '1000'
        MapConfigSource(values)
    }
}

class IntegrationFixture {
    let server: FdbmServer
    let port: UInt16
    let sqls: ArrayList<String>

    init(server: FdbmServer, port: UInt16, sqls: ArrayList<String>) {
        this.server = server
        this.port = port
        this.sqls = sqls
    }

    func connect(database: String): Connection {
        let driver = dbdDriver()
        let datasource = driver.open('fdbm://u:p@127.0.0.1:${port}/${database}', [])
        datasource.connect()
    }

    func close(): Unit {
        server.stop()
    }
}

/** 统计满足条件的下推条数。 */
func countOf(sqls: ArrayList<String>, predicate: (String) -> Bool): Int64 {
    var count = 0
    for (sql in sqls) {
        if (predicate(sql)) {
            count += 1
        }
    }
    count
}

/** 测试用字节流（服务端流列的物理实现）。 */
class BytesStream <: InputStream {
    private let bytes: Array<Byte>
    private var pos: Int64 = 0

    init(bytes: Array<Byte>) {
        this.bytes = bytes
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (pos >= bytes.size || buffer.isEmpty()) {
            return 0
        }
        let n = if (bytes.size - pos < buffer.size) { bytes.size - pos } else { buffer.size }
        var i: Int64 = 0
        while (i < n) {
            buffer[i] = bytes[pos + i]
            i += 1
        }
        pos += n
        n
    }
}
