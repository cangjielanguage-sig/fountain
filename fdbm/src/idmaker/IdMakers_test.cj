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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbm.IdGenerator
import fountain::f_mockdb.*
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
