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
package fountain::fdbm.route

import std.collection.{ArrayList, HashMap}
import std.fs.*
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbm.PartitionAlgorithm
import fountain::f_dbd.common.DbdErrorCode
import fountain::fdbm.config.SubstringSpec
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.sql.SqlParser

/** Step 5.1 七种分库算法（设计 §6.1）。 */
@Test
public class PartitionAlgorithmTest {

    @TestCase
    public func stepPartitionBoundaries(): Unit {
        let step = StepPartition(['db0', 'db1'], 1000)
        @Assert(step.partition<Int64>(1), 'db0')
        @Assert(step.partition<Int64>(999), 'db0')
        @Assert(step.partition<Int64>(1000), 'db0')
        @Assert(step.partition<Int64>(1001), 'db1')
        @Assert(step.partition<Int64>(2000), 'db1')
        @Assert(partitionCode { step.partition<Int64>(0) } == DbdErrorCode.ROUTE_FAILED, true)
        @Assert(partitionCode { step.partition<Int64>(2001) } == DbdErrorCode.ROUTE_FAILED, true)
        @Assert(partitionCode { step.partition<String>('abc') } == DbdErrorCode.ROUTE_FAILED, true)
        // '1001' 与 1001 同库（键规范化由路由器完成，算法本身也接受字符串）
        @Assert(step.partition<String>('1001'), 'db1')
    }

    @TestCase
    public func stepRangeMapping(): Unit {
        let step = StepPartition(['db0', 'db1'], 1000)
        @Assert(step.partitionRange(None, true, None, true).size, 2)
        let upper = step.partitionRange(Some(1001), true, None, true)
        @Assert(upper.size, 1)
        @Assert(upper[0], 'db1')
        @Assert(step.partitionRange(Some(1000), true, None, true).size, 2)
        let lower = step.partitionRange(None, true, Some(999), true)
        @Assert(lower.size, 1)
        @Assert(lower[0], 'db0')
        @Assert(step.partitionRange(None, true, Some(1000), true).size, 1)
        @Assert(step.partitionRange(Some(1001), false, None, true), ['db1'])
        @Assert(step.partitionRange(Some(2000), false, None, true).size, 0)
        @Assert(step.partitionRange(None, true, Some(0), true).size, 0)
        @Assert(step.partitionRange(Some(100), true, Some(50), true).size, 0)
    }

    @TestCase
    public func hashAlgorithmsAreStable(): Unit {
        let databases = ['db0', 'db1', 'db2', 'db3']
        let hash = HashPartition(databases, hashAlgorithm: 'hash')
        @Assert(hash.partition<String>('abc'), hash.partition<String>('abc'))
        @Assert(hash.partition<Int64>(123), hash.partition<String>('123'))

        let crc = CrcPartition(databases, 'crc32')
        @Assert(crc.partition<String>('abc'), crc.partition<String>('abc'))
        let murmur = MurmurPartition(databases)
        @Assert(murmur.partition<String>('abc'), murmur.partition<String>('abc'))
    }

    @TestCase
    public func substringPartitionUsesRunes(): Unit {
        let databases = ['db0', 'db1', 'db2', 'db3']
        let spec = SubstringSpec(0, 2, 'crc32')
        let substr = SubstringPartition(databases, spec)
        @Assert(substr.partition<String>('ABCDEF'), substr.partition<String>('ABCDEF'))
        let shortSpec = SubstringPartition(databases, SubstringSpec(1, 2, 'crc32'))
        // 多字节字符按码点切，不会切出半个字符
        let runeSpec = SubstringPartition(databases, SubstringSpec(0, 1, 'crc32'))
        @Assert(runeSpec.partition<String>('中文').size > 0, true)
        // 短键（start 越界）→ ROUTE_FAILED
        @Assert(partitionCode { shortSpec.partition<String>('A') } == DbdErrorCode.ROUTE_FAILED, true)
        // 结束越界截到末尾
        let tail = SubstringPartition(databases, SubstringSpec(1, 100, 'crc32'))
        @Assert(tail.partition<String>('ABCD'), tail.partition<String>('ABCD'))
    }

    @TestCase
    public func factoryResolvesBuiltinsAndCustom(): Unit {
        let databases = ['db0', 'db1']
        @Assert(PartitionAlgorithmFactory.create('step', databases, 10, None,
            HashMap<String, PartitionAlgorithm>()).name, 'step')
        @Assert(PartitionAlgorithmFactory.create('std', databases, 10, None,
            HashMap<String, PartitionAlgorithm>()).name, 'std')
        @Assert(PartitionAlgorithmFactory.create('substr', databases, 10,
            Some(SubstringSpec(0, 1, 'crc16')), HashMap<String, PartitionAlgorithm>()).name, 'substr')
        @Assert(partitionCode {
            PartitionAlgorithmFactory.create('substr', databases, 10, None,
                HashMap<String, PartitionAlgorithm>())
        } == DbdErrorCode.PARTITION_CONFIG, true)
        @Assert(partitionCode {
            PartitionAlgorithmFactory.create('bogus', databases, 10, None,
                HashMap<String, PartitionAlgorithm>())
        } == DbdErrorCode.PARTITION_CONFIG, true)

        // 非冲突的自定义名正常生效；内置名仍解析为内置实现（与内置重名由启动自检拒绝，见
        // `FdbmConfig.validate` 的 `customAlgorithmCannotOverrideBuiltin`）
        let custom = HashMap<String, PartitionAlgorithm>()
        custom['myhash'] = FixedAlgorithm('db1')
        @Assert(PartitionAlgorithmFactory.create('myhash', databases, 10, None, custom)
            .partition<String>('x'), 'db1')
        @Assert(PartitionAlgorithmFactory.create('hash', databases, 10, None, custom).name, 'hash')
    }
}

/** Step 5.3 `PartitionCache`（设计 §6.3）：读写、删除、容量与计数。 */
@Test
public class PartitionCacheTest {

    @TestCase
    public func putGetRemoveCount(): Unit {
        let dir = Directory.createTemp('/tmp')
        try {
            let cache = PartitionCache(dir.toString(), None, 0)
            @Assert(cache.get('db0', 't', 'id', '1').isNone(), true)
            cache.put('db0', 't', 'id', '1', 'p0')
            @Assert(cache.get('db0', 't', 'id', '1').getOrThrow(), 'p0')
            @Assert(cache.count(), 1)
            cache.put('db0', 't', 'id', '1', 'p1') // 同键覆盖不增计数
            @Assert(cache.count(), 1)
            @Assert(cache.get('db0', 't', 'id', '1').getOrThrow(), 'p1')
            cache.remove('db0', 't', 'id', '1')
            @Assert(cache.count(), 0)
            @Assert(cache.get('db0', 't', 'id', '1').isNone(), true)
            cache.close()
            @Assert(cache.isClosed(), true)
            // G15：关闭后必须报 CACHE，不得静默当作未命中
            @Assert(cacheCodeOf { cache.get('db0', 't', 'id', '1') } == DbdErrorCode.CACHE, true)
            @Assert(cacheCodeOf { cache.put('db0', 't', 'id', '1', 'p0') } == DbdErrorCode.CACHE, true)
            @Assert(cacheCodeOf { cache.remove('db0', 't', 'id', '1') } == DbdErrorCode.CACHE, true)
        } finally {
            removeIfExists(dir, recursive: true)
        }
    }

    /** G15：并发 `put` 与 `close` 交错 1000 次，只有 `CACHE` 错误，落盘可重开。 */
    @TestCase
    public func concurrentPutsAndCloseStayConsistent(): Unit {
        let dir = Directory.createTemp('/tmp')
        try {
            let cache = PartitionCache(dir.toString(), None, 0)
            let unexpected = AtomicInt64(0)
            let futures = ArrayList<Future<Unit>>()
            for (worker in 0..4) {
                let fut = spawn {
                    for (i in 0..250) {
                        try {
                            cache.put('db0', 't', 'id', '${worker * 1000 + i}', 'p0')
                        } catch (e: FdbmException) {
                            if (e.code != DbdErrorCode.CACHE) {
                                unexpected.fetchAdd(1)
                            }
                        } catch (_: Exception) {
                            unexpected.fetchAdd(1)
                        }
                    }
                }
                futures.add(fut)
            }
            sleep(Duration.millisecond * 5)
            cache.close()
            for (fut in futures) {
                fut.get()
            }
            @Assert(unexpected.load(), 0)
            @Assert(cache.isClosed(), true)
            let reopened = PartitionCache(dir.toString(), None, 0)
            @Assert(reopened.count() <= 1000, true)
            reopened.close()
        } finally {
            removeIfExists(dir, recursive: true)
        }
    }

    /** T04：并发写入不同键后 count() 与落盘键数一致（重启后仍一致，不是只在内存里对）。 */
    @TestCase
    public func concurrentPutsKeepCountInSyncWithStore(): Unit {
        let dir = Directory.createTemp('/tmp')
        try {
            let cache = PartitionCache(dir.toString(), None, 0)
            let futures = ArrayList<Future<Unit>>()
            for (worker in 0..4) {
                let fut = spawn {
                    for (i in 0..25) {
                        cache.put('db0', 't', 'id', '${worker * 100 + i}', 'p0')
                    }
                }
                futures.add(fut)
            }
            for (fut in futures) {
                fut.get()
            }
            @Assert(cache.count(), 100)
            cache.close()

            let reopened = PartitionCache(dir.toString(), None, 0)
            @Assert(reopened.count(), 100)
            reopened.close()
        } finally {
            removeIfExists(dir, recursive: true)
        }
    }

    @TestCase
    public func capacityStopsNewWrites(): Unit {
        let dir = Directory.createTemp('/tmp')
        try {
            let cache = PartitionCache(dir.toString(), None, 1)
            cache.put('db0', 't', 'id', '1', 'p0')
            cache.put('db0', 't', 'id', '2', 'p1')
            @Assert(cache.count(), 1)
            @Assert(cache.get('db0', 't', 'id', '2').isNone(), true)
        } finally {
            removeIfExists(dir, recursive: true)
        }
    }
}

/** Step 5.2/5.4 路由与全局表（设计 §6.2/§6.4）。 */
@Test
public class PartitionRouterTest {

    private func router(cache!: ?PartitionCache = None): PartitionRouter {
        let rules = [
            PartitionRule('db0', 't', 'id', StepPartition(['p0', 'p1'], 1000)),
            PartitionRule('db0', 't2', 'id', StepPartition(['p0', 'p1'], 1000))
        ]
        PartitionRouter(rules, cache, HashMap<String, PartitionAlgorithm>(),
            knownDatabases: ['p0', 'p1'], globalTables: GlobalTableRouter([]))
    }

    @TestCase
    public func equalityRoutesToSingle(): Unit {
        let plan = router().route(SqlParser.parse('select * from t where id = 5', 'db0'), 'db0')
        @Assert(plan.kind == RouteKind.Single, true)
        @Assert(plan.databases.size, 1)
        @Assert(plan.databases[0], 'p0')
    }

    @TestCase
    public func inRoutesToMulti(): Unit {
        let plan = router().route(SqlParser.parse('select * from t where id in (5, 1500)', 'db0'), 'db0')
        @Assert(plan.kind == RouteKind.Multi, true)
        @Assert(plan.databases.size, 2)
    }

    @TestCase
    public func noConditionIsUnroutable(): Unit {
        @Assert(router().route(SqlParser.parse('select * from t', 'db0'), 'db0').kind ==
            RouteKind.Unroutable, true)
    }

    @TestCase
    public func stepRangeRoutesToMultipleDatabases(): Unit {
        let plan = router().route(SqlParser.parse('select * from t where id > 1000', 'db0'), 'db0')
        @Assert(plan.kind == RouteKind.Single, true)
        @Assert(plan.databases[0], 'p1')

        let multi = router().route(SqlParser.parse('select * from t where id between 500 and 1500', 'db0'),
            'db0')
        @Assert(multi.kind == RouteKind.Multi, true)
        @Assert(multi.databases.size, 2)
    }

    @TestCase
    public func emptyRangeIsEmpty(): Unit {
        let plan = router().route(SqlParser.parse('select * from t where id > 5000', 'db0'), 'db0')
        @Assert(plan.kind == RouteKind.Empty, true)
    }

    @TestCase
    public func equalityAndRangeIntersect(): Unit {
        // 等值 5 落在 p0；范围 >1000 给出 p1 → 交集为空
        let plan = router().route(
            SqlParser.parse('select * from t where id = 5 and id > 1000', 'db0'), 'db0')
        @Assert(plan.kind == RouteKind.Empty, true)
    }

    @TestCase
    public func sameDimensionJoinIntersects(): Unit {
        let plan = router().route(
            SqlParser.parse('select * from t, t2 where t.id = 5 and t2.id = 1500', 'db0'), 'db0')
        @Assert(plan.kind == RouteKind.Empty, true)

        let same = router().route(
            SqlParser.parse('select * from t, t2 where t.id = 5 and t2.id = 6', 'db0'), 'db0')
        @Assert(same.kind == RouteKind.Single, true)
    }

    @TestCase
    public func insertValuesConstrainRoute(): Unit {
        let plan = router().route(SqlParser.parse('insert into t (id, name) values (1500, \'a\')', 'db0'),
            'db0')
        @Assert(plan.kind == RouteKind.Single, true)
        @Assert(plan.databases[0], 'p1')
    }

    @TestCase
    public func cacheHitAndInvalidation(): Unit {
        let dir = Directory.createTemp('/tmp')
        try {
            let cache = PartitionCache(dir.toString(), None, 0)
            cache.put('db0', 't', 'id', '5', 'gone')
            let plan = router(cache: cache).route(SqlParser.parse('select * from t where id = 5', 'db0'),
                'db0')
            @Assert(plan.kind == RouteKind.Single, true)
            @Assert(plan.databases[0], 'p0') // 不存在的库被丢弃并重算
            @Assert(cache.get('db0', 't', 'id', '5').getOrThrow(), 'p0')
        } finally {
            removeIfExists(dir, recursive: true)
        }
    }

    @TestCase
    public func globalTablesDoNotConstrain(): Unit {
        let global = GlobalTableRouter([GlobalTableRule('db0', 'dict')])
        @Assert(global.isGlobal('db0', 'dict'), true)
        @Assert(global.tables('db0').size, 1)
        let rules = [PartitionRule('db0', 't', 'id', StepPartition(['p0', 'p1'], 1000))]
        let router = PartitionRouter(rules, None, HashMap<String, PartitionAlgorithm>(),
            knownDatabases: ['p0', 'p1'], globalTables: global)
        let plan = router.route(
            SqlParser.parse('select * from t, dict where t.id = 5 and dict.k = 1', 'db0'), 'db0')
        @Assert(plan.kind == RouteKind.Single, true)
    }

    // ==================== 派生表沿内层条件路由（设计 D5） ====================

    @TestCase
    public func derivedTableFollowsInnerEquality(): Unit {
        let plan = router().route(
            SqlParser.parse('select count(*) from (select 1 from t where id = 5) as c', 'db0'),
            'db0')
        @Assert(plan.kind == RouteKind.Single, true)
        @Assert(plan.databases[0], 'p0')
    }

    @TestCase
    public func derivedTableFollowsInnerInList(): Unit {
        let plan = router().route(
            SqlParser.parse('select * from (select id from t where id in (5, 1500)) as p', 'db0'),
            'db0')
        @Assert(plan.kind == RouteKind.Multi, true)
        @Assert(plan.databases.size, 2)
    }

    @TestCase
    public func derivedTableWithContradictoryRangeIsEmpty(): Unit {
        let plan = router().route(
            SqlParser.parse('select count(*) from (select 1 from t where id > 1500 and id < 500) as c',
                'db0'), 'db0')
        @Assert(plan.kind == RouteKind.Empty, true)
    }

    @TestCase
    public func derivedTableOverGlobalTableIsBroadcast(): Unit {
        let logicals = HashMap<String, Array<String>>()
        logicals['db0'] = ['p0', 'p1']
        let globals = GlobalTableRouter([GlobalTableRule('db0', 'dict')],
            logicalDatabases: logicals)
        let router = PartitionRouter([], None, HashMap<String, PartitionAlgorithm>(),
            knownDatabases: ['p0', 'p1'], globalTables: globals)
        let plan = router.route(
            SqlParser.parse('select count(*) from (select 1 from dict where k = 1) as c', 'db0'),
            'db0')
        @Assert(plan.kind == RouteKind.Broadcast, true)
        @Assert(plan.databases.size, 2)
    }

    @TestCase
    public func countOnDerivedTableHitsSingleShard(): Unit {
        let plan = router().route(
            SqlParser.parse('select count(*) from (select 1 from t where id = 1500) as c', 'db0'),
            'db0')
        @Assert(plan.kind == RouteKind.Single, true)
        @Assert(plan.databases[0], 'p1')
    }

    /** G19：分库列名与表名按 ASCII 大小写不敏感匹配。 */
    @TestCase
    public func identifiersAreCaseInsensitive(): Unit {
        let upper = router().route(SqlParser.parse("update t set name='x' where ID = 5", 'db0'), 'db0')
        @Assert(upper.kind, RouteKind.Single)
        @Assert(upper.databases[0], 'p0')
        let insert = router().route(SqlParser.parse("insert into t (ID) values (1500)", 'db0'), 'db0')
        @Assert(insert.kind, RouteKind.Single)
        @Assert(insert.databases[0], 'p1')
    }

    /** G20：别名限定的分库键也能抽取（`from users u where u.id = 5`）。 */
    @TestCase
    public func aliasQualifiedKeyIsExtracted(): Unit {
        let rules = [PartitionRule('db0', 'users', 'id', StepPartition(['db0', 'db1'], 1000))]
        let router = PartitionRouter(rules, None, HashMap<String, PartitionAlgorithm>(),
            knownDatabases: ['db0', 'db1'])
        let plan = router.route(
            SqlParser.parse('select * from users u where u.id = 1500', 'db0'), 'db0')
        @Assert(plan.kind, RouteKind.Single)
        @Assert(plan.databases[0], 'db1')
    }

    /** G27：列名/算法相同但分片空间不同的跨逻辑库 JOIN → Unroutable（不是 Empty）。 */
    @TestCase
    public func differentShardSpacesAreUnroutable(): Unit {
        let rules = [
            PartitionRule('app', 'a', 'id', StepPartition(['db0', 'db1'], 1000),
                databases: ['db0', 'db1']),
            PartitionRule('cfg', 'b', 'id', StepPartition(['db2', 'db3'], 1000),
                databases: ['db2', 'db3'])
        ]
        let router = PartitionRouter(rules, None, HashMap<String, PartitionAlgorithm>(),
            knownDatabases: ['db0', 'db1', 'db2', 'db3'])
        let plan = router.route(
            SqlParser.parse('select * from app.a x join cfg.b y on x.id = y.id where x.id = 5', 'app'),
            'app')
        @Assert(plan.kind, RouteKind.Unroutable)
        @Assert(plan.reason.contains('db0'), true)
        @Assert(plan.reason.contains('db2'), true)
    }
}

/** 固定返回某个库的算法（自定义覆盖用）。 */
class FixedAlgorithm <: PartitionAlgorithm {
    private let database: String

    init(database: String) {
        this.database = database
    }

    public prop name: String {
        get() {
            'fixed'
        }
    }

    public func partition<K>(key: K): String {
        database
    }
}

func partitionCode<T>(body: () -> T): DbdErrorCode {
    try {
        body()
    } catch (e: FdbmException) {
        return e.code
    } catch (_: Exception) {
        return DbdErrorCode.INTERNAL
    }
    DbdErrorCode.INTERNAL
}


/** 执行并取 `FdbmException.code`（路由用例共用）。 */
func cacheCodeOf<T>(body: () -> T): DbdErrorCode {
    try {
        body()
    } catch (e: FdbmException) {
        return e.code
    } catch (_: Exception) {
        return DbdErrorCode.INTERNAL
    }
    DbdErrorCode.INTERNAL
}
