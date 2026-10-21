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

import std.collection.HashMap
import std.convert.*
import std.database.sql.{Connection, SqlException}
import std.sync.Mutex
import fountain::f_config.Config
import fountain::f_dbm.IdGenerator
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_util.{IdMaker, TimeBasedUUIDBuilder, UUID}
import fountain::fdbm.config.IdMakerConfig
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.resources.NodeAccessor

/**
 * `'uuid'`：按版本生成 UUID 字符串（v1/v4/v6/v7）。
 *
 * v1/v6 使用**进程级复用**的 `TimeBasedUUIDBuilder`：构造时注册一次内存序列生成器，
 * 每次取号先 `serialSeq`（真正写入时间戳与序列）再 `randomNode()`。builder 的
 * `timestamp`/`seq` 字段非线程安全，`nextStringId()` 必须持锁（D10）。
 */
protected class UuidIdGenerator <: IdGenerator {
    private let version: Int64
    private let lock = Mutex()
    private let builder: ?TimeBasedUUIDBuilder

    public init(version!: Int64 = 1) {
        if (version != 1 && version != 4 && version != 6 && version != 7) {
            throw FdbmException(DbdErrorCode.CONFIG, 'uuid version must be 1, 4, 6 or 7')
        }
        this.version = version
        this.builder = if (version == 1) {
            Some(UUID.timeBased(timeLowFirst: true).registerSequenceGenerator())
        } else if (version == 6) {
            Some(UUID.timeBased().registerSequenceGenerator())
        } else {
            None<TimeBasedUUIDBuilder>
        }
    }

    public prop name: String {
        get() {
            'uuid'
        }
    }

    public func nextStringId(): String {
        match (version) {
            case 4 => UUID.random().toString()
            case 7 => UUID.unixTimeBased().toString()
            case _ =>
                match (builder) {
                    case Some(value) =>
                        synchronized(lock) {
                            value.serialSeq.randomNode().toString()
                        }
                    case None => UUID.random().toString()
                }
        }
    }
}

/** `'snowflake'`：`f_util.IdMaker` 的单调递增 64 位整数。 */
protected class SnowflakeIdGenerator <: IdGenerator {
    private let maker: IdMaker

    public init(serial: Int64) {
        if (serial < 0 || serial > 1023) {
            throw FdbmException(DbdErrorCode.CONFIG, 'snowflake node serial must be in 0..1023')
        }
        this.maker = IdMaker(hostSerial: serial)
    }

    public prop name: String {
        get() {
            'snowflake'
        }
    }

    public func nextIntId(): Int64 {
        maker.nextInt64()
    }
}

/**
 * `'sequence'`：在唯一分配库的 `fountain_sequence` 表上用事务 + 行锁取号。
 *
 * 首次返回 `current_value + increment`（需求"从 1 开始"要求初始化行时 `current_value=0`）。
 */
protected class SequenceIdGenerator <: IdGenerator {
    private let resources: NodeAccessor
    private let logical: String
    private let table: String
    private let database: String

    public init(resources: NodeAccessor, logical: String, table: String, database: String) {
        this.resources = resources
        this.logical = logical
        this.table = table
        this.database = database
    }

    public prop name: String {
        get() {
            'sequence'
        }
    }

    public func nextIntId(): Int64 {
        let key = '${logical}.${table}'
        let connection = try {
            resources.selectWrite(database)
        } catch (e: FdbmException) {
            throw e
        } catch (e: Exception) {
            throw FdbmException(DbdErrorCode.ID_GENERATOR,
                'cannot borrow a connection for sequence \'${key}\': ${e.message}', e)
        }
        try {
            let transaction = connection.createTransaction()
            transaction.begin()
            try {
                let current = readSequence(connection, key)
                let next = current[0] + current[1]
                updateSequence(connection, key, current[1])
                transaction.commit()
                return next
            } catch (e: Exception) {
                try {
                    transaction.rollback()
                } catch (_: Exception) {
                    ()
                }
                throw e
            }
        } catch (e: FdbmException) {
            throw e
        } catch (e: SqlException) {
            throw FdbmException(DbdErrorCode.ID_GENERATOR,
                'sequence \'${key}\' failed: ${e.message}', e)
        } catch (e: Exception) {
            throw FdbmException(DbdErrorCode.ID_GENERATOR,
                'sequence \'${key}\' failed: ${e.message}', e)
        } finally {
            try {
                connection.close()
            } catch (_: Exception) {
                ()
            }
        }
    }

    private static func readSequence(connection: Connection, key: String): (Int64, Int64) {
        let statement = connection.prepareStatement(
            'select current_value, increment from fountain_sequence where table_name = ? for update')
        try {
            statement.set<String>(0, key)
            let result = statement.query()
            try {
                if (!result.next()) {
                    throw FdbmException(DbdErrorCode.ID_GENERATOR,
                        'sequence row for \'${key}\' does not exist in fountain_sequence')
                }
                (result.get<Int64>(0), result.get<Int64>(1))
            } finally {
                result.close()
            }
        } finally {
            statement.close()
        }
    }

    private static func updateSequence(connection: Connection, key: String, increment: Int64): Unit {
        let statement = connection.prepareStatement(
            'update fountain_sequence set current_value = current_value + ? where table_name = ?')
        try {
            statement.set<Int64>(0, increment)
            statement.set<String>(1, key)
            statement.update()
        } finally {
            statement.close()
        }
    }
}

/** ID 生成器工厂（设计 §7）：uuid/snowflake 与表无关，sequence 按 `(logical, table)` 构造。 */
protected struct IdMakers {
    public static func forTable(config: IdMakerConfig, resources: NodeAccessor,
        logical: String, table: String, custom: HashMap<String, IdGenerator>,
        sequenceDatabase: String): ?IdGenerator {
        if (let Some(generator) <- custom.get(config.kind)) {
            return Some(generator)
        }
        if (config.kind == 'uuid') {
            let version = match (config.arg) {
                case Some(text) =>
                    match (Int64.tryParse(text)) {
                        case Some(value) => value
                        case None => throw FdbmException(DbdErrorCode.CONFIG,
                            'uuid version \'${text}\' is not a number')
                    }
                case None => 1
            }
            return Some(UuidIdGenerator(version: version))
        }
        if (config.kind == 'snowflake') {
            let serial = match (config.arg) {
                case Some(text) =>
                    match (Int64.tryParse(text)) {
                        case Some(value) => value
                        case None => throw FdbmException(DbdErrorCode.CONFIG,
                            'snowflake serial \'${text}\' is not a number')
                    }
                case None =>
                    match (Config.getValue<Int64>(IdMaker.HOST_SERIAL)) {
                        case Some(value) => value
                        case None => throw FdbmException(DbdErrorCode.CONFIG,
                            'snowflake requires a node serial')
                    }
            }
            return Some(SnowflakeIdGenerator(serial))
        }
        if (config.kind == 'sequence') {
            return Some(SequenceIdGenerator(resources, logical, table, sequenceDatabase))
        }
        None<IdGenerator>
    }
}
