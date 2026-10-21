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

import std.collection.{ArrayList, HashMap, HashSet}
import std.sync.Mutex
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbm.IdGenerator
import fountain::f_mockdb.*
import fountain::f_base.fromHex
import fountain::f_util.UUID
import fountain::fdbm.config.{DatabaseNodeConfig, IdMakerConfig, LoadBalanceConfig, PoolConfig}
import fountain::fdbm.resources.DatabaseResources

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
