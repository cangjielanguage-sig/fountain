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
package fountain::fdbm.idmaker

import std.collection.{ArrayList, HashMap, HashSet, Map}
import std.fs.{Directory, Path}
import std.sync.{AtomicInt64, Mutex}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbm.IdGenerator
import fountain::f_mockdb.*
import fountain::f_base.fromHex
import fountain::f_util.UUID
import fountain::fdbm.config.{DatabaseNodeConfig, IdMakerConfig, LoadBalanceConfig, PoolConfig}
import fountain::fdbm.resources.{DatabaseResources, NodeAccessor}
import fountain::fdbm.exception.FdbmException
import fountain::f_dbd.common.DbdErrorCode

/** 阶段 6：`Uuid` / `Snowflake` / `Sequence` 与 `IdMakers.forTable`。 */
@Test
public class IdMakersTest {

    @TestCase
    public func uuidIsUniquePerCall(): Unit {
        let generator = UuidIdGenerator(version: 4)
        let first = generator.nextStringId()
        let second = generator.nextStringId()
        @Assert(first.isEmpty(), false)
        @Assert(first == second, false)
        @Assert(generator.name, 'uuid')
    }

    /** D10：v1/v6 必须写入真实时间戳，且同进程内单调不减。 */
    @TestCase
    public func uuidV1AndV6CarryTimestamps(): Unit {
        for (version in [1, 6]) {
            let generator = UuidIdGenerator(version: version)
            var last: Int64 = 0
            var index: Int64 = 0
            while (index < 1000) {
                let value = UUID.parse(generator.nextStringId())
                @Assert(value.version, version)
                let stamp = hundredNanosOf(value)
                @Assert(stamp > 0, true)
                @Assert(stamp >= last, true)
                last = stamp
                index += 1
            }
        }
    }

    /** D10：创建生成器不产生临时目录/文件，并发取号不重复。 */
    @TestCase
    public func uuidV1IsUniqueUnderConcurrency(): Unit {
        // 旧实现为每个 ID 建临时目录/文件；这里断言 `/tmp` 下不再出现 17 位时间戳命名的文件
        let tempEntriesBefore = timestampNamedEntries()
        let generator = UuidIdGenerator(version: 1)
        let lock = Mutex()
        let ids = ArrayList<String>()
        let futures = ArrayList<Future<Unit>>()
        for (_ in 0..8) {
            let fut = spawn {
                for (_ in 0..200) {
                    let id = generator.nextStringId()
                    synchronized(lock) {
                        ids.add(id)
                    }
                }
            }
            futures.add(fut)
        }
        for (fut in futures) {
            fut.get()
        }
        @Assert(ids.size, 1600)
        let seen = HashSet<String>()
        for (id in ids) {
            @Assert(seen.add(id), true)
            @Assert(hundredNanosOf(UUID.parse(id)) > 0, true)
        }
        @Assert(timestampNamedEntries(), tempEntriesBefore)
    }

    @TestCase
    public func snowflakeIsMonotonic(): Unit {
        let generator = SnowflakeIdGenerator(7)
        let first = generator.nextIntId()
        let second = generator.nextIntId()
        @Assert(second > first, true)
    }

    @TestCase
    public func sequenceReadsAndIncrements(): Unit {
        MOCKDB.execution = {sql, args =>
            if (sql.startsWith('select')) {
                MOCKDB.addQueryResultColumnInfo(name: 'current_value', nullable: false, typeName: 'Int64')
                MOCKDB.addQueryResultColumnInfo(name: 'increment', nullable: false, typeName: 'Int64')
                MOCKDB.addQueryResultRow([5, 2])
            } else {
                MOCKDB.rowCount = 1
            }
        }
        let nodes = [DatabaseNodeConfig('name0', '127.0.0.1', 3306u16, 'mockdb', ['db0'], '', '')]
        let poolConfig = PoolConfig(initSize: 0, minSize: 0, maxSize: 1, checkOnBorrowing: false,
            checkOnReturning: false, connectTimeout: Duration.second, maxWaiting: Duration.second)
        let resources = DatabaseResources(nodes, poolConfig, LoadBalanceConfig())
        try {
            let generator = SequenceIdGenerator(resources, 'order', 'orders', 'db0')
            @Assert(generator.nextIntId(), 7)
        } finally {
            resources.close()
        }
    }

    /** 真实取号流程分别在 query/next/update 失败，叠加收尾失败仍保留 SQL 首错与回滚。 */
    @TestCase
    public func sequenceSqlFailureSurvivesCleanupFailures(): Unit {
        for (stage in ['query', 'next', 'update']) {
            let expectedSqlMessage = SqlException('sequence SQL failure at ${stage}', '23505', 0).message
            MOCKDB.clear()
            MOCKDB.execution = {sql, _ =>
                if (sql.startsWith('select')) {
                    MOCKDB.addQueryResultColumnInfo(name: 'current_value', nullable: false, typeName: 'Int64')
                    MOCKDB.addQueryResultColumnInfo(name: 'increment', nullable: false, typeName: 'Int64')
                    MOCKDB.addQueryResultRow([5, 2])
                }
            }
            let connection = SequenceFailureConnection(stage)
            let generator = SequenceIdGenerator(SequenceFailureAccessor(connection), 'order', 'orders', 'db0')
            var message = ''
            try {
                generator.nextIntId()
            } catch (e: FdbmException) {
                @Assert(e.code, DbdErrorCode.ID_GENERATOR)
                message = e.message
                let cause = e.causedBy.getOrThrow()
                @Assert(cause is SqlException, true)
                if (let sql: SqlException <- cause) {
                    @Assert(sql.sqlState, '23505')
                    @Assert(sql.message, expectedSqlMessage)
                }
            }
            @Assert(message, 'sequence \'order.orders\' failed: ${expectedSqlMessage}')
            @Assert(connection.isClosed(), true)
            // 未到 commit 的失败路径，事务已被 rollback 正常结束。
            var finished = false
            try {
                connection.transaction.commit()
            } catch (e: SqlException) {
                finished = e.message.contains('has been finished')
            }
            @Assert(finished, true)
        }
    }

    @TestCase
    public func forTableBuildsBuiltins(): Unit {
        let nodes = [DatabaseNodeConfig('name0', '127.0.0.1', 3306u16, 'mockdb', ['db0'], '', '')]
        let poolConfig = PoolConfig(initSize: 0, minSize: 0, maxSize: 1, checkOnBorrowing: false,
            checkOnReturning: false, connectTimeout: Duration.second, maxWaiting: Duration.second)
        let resources = DatabaseResources(nodes, poolConfig, LoadBalanceConfig())
        try {
            let custom = HashMap<String, IdGenerator>()
            let uuid = IdMakers.forTable(IdMakerConfig('uuid', arg: Some('4')), resources,
                'order', 'orders', custom, 'db0').getOrThrow()
            @Assert(uuid.name, 'uuid')
            let snowflake = IdMakers.forTable(IdMakerConfig('snowflake', arg: Some('3')), resources,
                'order', 'orders', custom, 'db0').getOrThrow()
            @Assert(snowflake.name, 'snowflake')
            let sequence = IdMakers.forTable(IdMakerConfig('sequence'), resources,
                'order', 'orders', custom, 'db0').getOrThrow()
            @Assert(sequence.name, 'sequence')
            @Assert(IdMakers.forTable(IdMakerConfig('bogus'), resources, 'order', 'orders',
                custom, 'db0').isNone(), true)
        } finally {
            resources.close()
        }
    }
}

/** UUID 的 RFC 4122 时间戳（100 ns 单位）；`timestampNanos` 对 1582 年起算会超出 Int64，故单测自行解码。 */
private func hundredNanosOf(value: UUID): Int64 {
    let hex = value.toHexString()
    let bytes = Array<Byte>(16, repeat: 0u8)
    var i: Int64 = 0
    while (i < 16) {
        bytes[i] = fromHex(hex[i * 2..i * 2 + 2])
        i += 1
    }
    if (value.version == 1) {
        (Int64(bytes[6] & 0xf) << 56) | (Int64(bytes[7]) << 48) | (Int64(bytes[4]) << 40) |
            (Int64(bytes[5]) << 32) | (Int64(bytes[0]) << 24) | (Int64(bytes[1]) << 16) |
            (Int64(bytes[2]) << 8) | Int64(bytes[3])
    } else {
        (Int64(bytes[0]) << 56) | (Int64(bytes[1]) << 48) | (Int64(bytes[2]) << 40) |
            (Int64(bytes[3]) << 32) | (Int64(bytes[4]) << 24) | (Int64(bytes[5]) << 16) |
            (Int64(bytes[6] & 0xf) << 8) | Int64(bytes[7])
    }
}


/** `/tmp` 下 17 位纯数字命名的文件数（旧 UUID 实现的时间戳文件名）。 */
private func timestampNamedEntries(): Int64 {
    let count = AtomicInt64(0)
    Directory.walk(Path('/tmp')) {info =>
        if (!info.isDirectory() && isTimestampName(info.path.fileName)) {
            count.fetchAdd(1)
        }
        true
    }
    count.load()
}

private func isTimestampName(name: String): Bool {
    if (name.size != 17) {
        return false
    }
    for (rune in name.toRuneArray()) {
        if (rune < r'0' || rune > r'9') {
            return false
        }
    }
    true
}

/** 委托现有 mock CDBC，仅在本例指定位置注入 SQL 与收尾双失败。 */
class SequenceFailureAccessor <: NodeAccessor {
    private let connection: Connection
    init(connection: Connection) {
        this.connection = connection
    }
    public func selectRead(_: String): Connection { connection }
    public func selectWrite(_: String): Connection { connection }
    public func selectAllWrite(_: String): Array<Connection> { [connection] }
    public func databases(): Array<String> { ['db0'] }
    public func contains(database: String): Bool { database == 'db0' }
    public func readNodes(_: String): Array<String> { ['mock'] }
    public func driver(_: String): String { 'mockdb' }
}

class SequenceFailureConnection <: Connection {
    private let inner = MockConnection()
    let transaction: Transaction = MockTransaction()
    private let stage: String
    init(stage: String) {
        this.stage = stage
    }
    public prop state: ConnectionState { get() { inner.state } }
    public func createTransaction(): Transaction { transaction }
    public func getMetaData(): Map<String, String> { inner.getMetaData() }
    public func prepareStatement(sql: String): Statement {
        SequenceFailureStatement(inner.prepareStatement(sql), stage, sql.startsWith('update'))
    }
    public func isClosed(): Bool { inner.isClosed() }
    public func close(): Unit {
        inner.close()
        throw Exception('connection cleanup failure')
    }
}

class SequenceFailureStatement <: Statement {
    private let inner: Statement
    private let stage: String
    private let isUpdate: Bool
    init(inner: Statement, stage: String, isUpdate: Bool) {
        this.inner = inner
        this.stage = stage
        this.isUpdate = isUpdate
    }
    public prop parameterColumnInfos: Array<ColumnInfo> { get() { inner.parameterColumnInfos } }
    public func setOption(key: String, value: String): Unit { inner.setOption(key, value) }
    public func set<T>(index: Int, value: T): Unit { inner.set<T>(index, value) }
    public func setNull(index: Int): Unit { inner.setNull(index) }
    public func query(params: Array<SqlDbType>): QueryResult { inner.query(params) }
    public func update(params: Array<SqlDbType>): UpdateResult { inner.update(params) }
    public func query(): QueryResult {
        if (stage == 'query') {
            throw SqlException('sequence SQL failure at query', '23505', 0)
        }
        SequenceFailureResult(inner.query(), stage)
    }
    public func update(): UpdateResult {
        throw SqlException('sequence SQL failure at update', '23505', 0)
    }
    public func isClosed(): Bool { inner.isClosed() }
    public func close(): Unit {
        inner.close()
        if (stage != 'update' || isUpdate) {
            throw Exception('statement cleanup failure')
        }
    }
}

class SequenceFailureResult <: QueryResult {
    private let inner: QueryResult
    private let stage: String
    init(inner: QueryResult, stage: String) {
        this.inner = inner
        this.stage = stage
    }
    public prop columnInfos: Array<ColumnInfo> { get() { inner.columnInfos } }
    public func next(values: Array<SqlDbType>): Bool { inner.next(values) }
    public func next(): Bool {
        if (stage == 'next') {
            throw SqlException('sequence SQL failure at next', '23505', 0)
        }
        inner.next()
    }
    public func get<T>(index: Int): T { inner.get<T>(index) }
    public func getOrNull<T>(index: Int): ?T { inner.getOrNull<T>(index) }
    public func isClosed(): Bool { inner.isClosed() }
    public func close(): Unit {
        inner.close()
        if (stage == 'next') {
            throw Exception('result cleanup failure')
        }
    }
}
