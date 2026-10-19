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
package fountain::fdbm.execute

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbm.{IdGenerator, PartitionAlgorithm}
import fountain::f_data.{DataAny, DataReal}
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_mockdb.*
import fountain::fdbm.config.{DatabaseNodeConfig, IdMakerConfig, LoadBalanceConfig, PoolConfig}
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.resources.{DatabaseResources, NodeAccessor}
import fountain::fdbm.route.{GlobalTableRouter, GlobalTableRule, PartitionRouter, PartitionRule,
    StepPartition}

/** 执行器新增能力：RETURNING / count(*) / 派生表分页 / 方言渲染（设计 D1/D6）。 */
@Test
public class ExecutorFeatureTest {

    // ==================== INSERT ... RETURNING ====================

    @TestCase
    public func postgresReturningUsesReturnedColumn(): Unit {
        let fixture = insertFixture('postgres')
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                "insert into t (id, name) values (5, 'a') returning id", [])
            @Assert(outcome.update.getOrThrow().rowCount, 1)
            @Assert(outcome.update.getOrThrow().lastInsertId, 42)
            @Assert(fixture.sqls.size, 1)
            @Assert(fixture.sqls[0].endsWith('returning id'), true)
            @Assert(fixture.accessor.writes.toArray(), ['db0'])
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func multiRowReturningTakesLastRow(): Unit {
        let fixture = insertFixture('postgres')
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                "insert into t (id, name) values (5, 'a'), (1500, 'b') returning id", [])
            @Assert(outcome.update.getOrThrow().rowCount, 2)
            // 每行一条语句，lastInsertId 取最后一行
            @Assert(outcome.update.getOrThrow().lastInsertId, 43)
            @Assert(fixture.sqls.size, 2)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func mysqlRejectsReturningBeforeSendingSql(): Unit {
        let fixture = insertFixture('mysql')
        let session = DbdSession('s', None, 'db0')
        try {
            @Assert(codeOf {
                fixture.executor.execute(session,
                    "insert into t (id, name) values (5, 'a') returning id", [])
            }, DbdErrorCode.UNSUPPORTED_SQL)
            @Assert(fixture.sqls.isEmpty(), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func unknownDriverReturningReportsDriverName(): Unit {
        let fixture = insertFixture('oracle')
        let session = DbdSession('s', None, 'db0')
        try {
            var message = ''
            try {
                fixture.executor.execute(session,
                    "insert into t (id, name) values (5, 'a') returning id", [])
            } catch (e: FdbmException) {
                @Assert(e.code, DbdErrorCode.UNSUPPORTED_SQL)
                message = e.message
            }
            @Assert(message.contains('oracle'), true)
            @Assert(fixture.sqls.isEmpty(), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func globalTableReturningIsRouteFailed(): Unit {
        let fixture = globalFixture('postgres')
        let session = DbdSession('s', None, 'db0')
        try {
            @Assert(codeOf {
                fixture.executor.execute(session,
                    "insert into dict (k, v) values (1, 'a') returning k", [])
            }, DbdErrorCode.ROUTE_FAILED)
            @Assert(fixture.sqls.isEmpty(), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func mysqlPlainInsertKeepsDriverLastInsertId(): Unit {
        let fixture = insertFixture('mysql')
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                "insert into t (id, name) values (5, 'a')", [])
            @Assert(outcome.update.getOrThrow().lastInsertId, 42)
            @Assert(fixture.sqls[0].contains('returning'), false)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    // ==================== COUNT(*) ====================

    @TestCase
    public func countSingleShardPushesDown(): Unit {
        let fixture = countFixture { sql, _ =>
            MOCKDB.addQueryResultColumnInfo(name: 'count', nullable: false, typeName: 'Int64')
            MOCKDB.addQueryResultRow([7])
        }
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                'select count(*) from t where id = 5', [])
            let cursor = outcome.cursor.getOrThrow()
            @Assert(outcome.columns[0].typeName, 'Int64')
            @Assert(cursor.next(), true)
            @Assert(cursor.cell(0, 0).toString(), '7')
            @Assert(cursor.next(), false)
            cursor.close()
            @Assert(fixture.accessor.reads.toArray(), ['db0'])
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func countSumsAcrossShardsIntoOneRow(): Unit {
        let fixture = countFixture { sql, _ =>
            MOCKDB.addQueryResultColumnInfo(name: 'count', nullable: false, typeName: 'Int64')
            MOCKDB.addQueryResultRow([1])
        }
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                'select count(*) from t where id in (5, 1500)', [])
            let cursor = outcome.cursor.getOrThrow()
            @Assert(cursor.next(), true)
            @Assert(cursor.cell(0, 0).toString(), '2')
            @Assert(cursor.next(), false)
            cursor.close()
            @Assert(fixture.accessor.reads.toArray(), ['db0', 'db1'])
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func countEmptyRouteReturnsZeroWithoutBorrowing(): Unit {
        let fixture = countFixture { _, _ => () }
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                'select count(*) from t where id > 5000 and id < 1000', [])
            let cursor = outcome.cursor.getOrThrow()
            @Assert(cursor.next(), true)
            @Assert(cursor.cell(0, 0).toString(), '0')
            @Assert(fixture.accessor.reads.isEmpty(), true)
            cursor.close()
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func countOnGlobalTableReadsOneReplica(): Unit {
        let fixture = globalFixture('postgres')
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session, 'select count(*) from dict', [])
            let cursor = outcome.cursor.getOrThrow()
            @Assert(cursor.next(), true)
            @Assert(cursor.cell(0, 0).toString(), '1')
            cursor.close()
            @Assert(fixture.accessor.reads.toArray(), ['db0'])
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func countMultiShardInsideTransactionIsRejected(): Unit {
        let fixture = countFixture { _, _ => () }
        let session = DbdSession('s', None, 'db0')
        try {
            fixture.executor.execute(session, 'begin', [])
            @Assert(codeOf {
                fixture.executor.execute(session, 'select count(*) from t where id in (5, 1500)', [])
            }, DbdErrorCode.ROUTE_FAILED)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    // ==================== 派生表分页 ====================

    @TestCase
    public func derivedTablePagingPushesDownOnSingleShard(): Unit {
        let fixture = queryFixture('postgres')
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                'select * from (select id from t where id = ?) as p limit ? offset ?',
                [paramOf(5), paramOf(10), paramOf(0)])
            let cursor = outcome.cursor.getOrThrow()
            @Assert(cursor.next(), true)
            cursor.close()
            @Assert(fixture.accessor.reads.toArray(), ['db0'])
            @Assert(fixture.sqls[0].contains('limit 10 offset 0'), true)
            @Assert(fixture.sqls[0].contains('id = 5'), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func derivedTablePagingOnMultipleShardsIsRejected(): Unit {
        let fixture = queryFixture('postgres')
        let session = DbdSession('s', None, 'db0')
        try {
            @Assert(codeOf {
                fixture.executor.execute(session,
                    'select * from (select id from t where id in (5, 1500)) as p limit ? offset ?',
                    [paramOf(10), paramOf(0)])
            }, DbdErrorCode.ROUTE_FAILED)
            @Assert(fixture.sqls.isEmpty(), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func derivedTableWithoutPagingBroadcastsOnMultipleShards(): Unit {
        let fixture = queryFixture('postgres')
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                'select * from (select id from t where id in (5, 1500)) as p', [])
            let cursor = outcome.cursor.getOrThrow()
            @Assert(cursor.next(), true)
            @Assert(cursor.next(), true)
            @Assert(cursor.next(), false)
            cursor.close()
            @Assert(fixture.accessor.reads.toArray(), ['db0', 'db1'])
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    // ==================== UPDATE / DELETE 方言 ====================

    @TestCase
    public func updateRendersQuotedIdentifiersForTargetDialect(): Unit {
        let fixture = recordingFixture('mysql') { sql, _ => MOCKDB.rowCount = 1 }
        let session = DbdSession('s', None, 'db0')
        try {
            fixture.executor.execute(session,
                'update "t" set "name" = 1 where "id" = 5', [])
            @Assert(fixture.sqls.toArray(),
                ['update `t` set `name` = 1 where (`id` = 5)'])
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func deleteRendersQuotedIdentifiersForTargetDialect(): Unit {
        let fixture = recordingFixture('mysql') { sql, _ =>
            if (sql.startsWith('select')) {
                MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
                MOCKDB.addQueryResultRow([5])
            } else {
                MOCKDB.rowCount = 1
            }
        }
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                'delete from "t" where "id" = 5', [])
            @Assert(outcome.update.getOrThrow().rowCount, 1)
            @Assert(fixture.sqls.toArray(), [
                'select id from `t` where (`id` = 5)',
                'delete from `t` where (`id` = 5)'
            ])
        } finally {
            session.close()
            fixture.resources.close()
        }
    }
}

// ==================== 夹具 ====================

class FeatureFixture {
    let executor: ExecutorDispatcher
    let resources: DatabaseResources
    let accessor: RecordingAccessor
    let sqls: ArrayList<String>

    init(executor: ExecutorDispatcher, resources: DatabaseResources, accessor: RecordingAccessor,
        sqls: ArrayList<String>) {
        this.executor = executor
        this.resources = resources
        this.accessor = accessor
        this.sqls = sqls
    }
}

/** `insert ... returning` 用例：每次执行递增 lastInsertId，便于验证「取最后一行」。 */
func insertFixture(driver: String): FeatureFixture {
    let sqls = ArrayList<String>()
    let calls = ArrayList<Int64>()
    MOCKDB.clear()
    MOCKDB.execution = {sql, _ =>
        sqls.add(sql)
        calls.add(0)
        let sequence = 41 + calls.size
        MOCKDB.rowCount = 1
        MOCKDB.lastInsertId = sequence
        MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
        MOCKDB.addQueryResultRow([sequence])
    }
    fixtureOf(driver, sqls)
}

/** 全局表 `dict` 广播到 db0 / db1。 */
func globalFixture(driver: String): FeatureFixture {
    let sqls = ArrayList<String>()
    MOCKDB.clear()
    MOCKDB.execution = {sql, _ =>
        sqls.add(sql)
        if (sql.startsWith('select') || sql.startsWith('show')) {
            MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
            MOCKDB.addQueryResultRow([1])
        } else {
            MOCKDB.rowCount = 1
        }
    }
    let logicals = HashMap<String, Array<String>>()
    logicals['db0'] = ['db0', 'db1']
    let globals = GlobalTableRouter([GlobalTableRule('db0', 'dict')], logicalDatabases: logicals)
    let resources = resourcesOf()
    let accessor = RecordingAccessor(resources)
    accessor.driverName = driver
    let router = PartitionRouter([], None, HashMap<String, PartitionAlgorithm>(),
        knownDatabases: ['db0', 'db1'], globalTables: globals)
    let executor = ExecutorDispatcher(router, globals, accessor, IdMakerConfig('uuid'), 'db0',
        HashMap<String, IdGenerator>(), None)
    FeatureFixture(executor, resources, accessor, sqls)
}

func countFixture(body: (String, ArrayList<Any>) -> Unit): FeatureFixture {
    let sqls = ArrayList<String>()
    MOCKDB.clear()
    MOCKDB.execution = {sql, args =>
        sqls.add(sql)
        body(sql, args)
    }
    fixtureOf('postgres', sqls)
}

func queryFixture(driver: String): FeatureFixture {
    let sqls = ArrayList<String>()
    MOCKDB.clear()
    MOCKDB.execution = {sql, _ =>
        sqls.add(sql)
        MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
        MOCKDB.addQueryResultRow([1])
    }
    fixtureOf(driver, sqls)
}

func recordingFixture(driver: String, body: (String, ArrayList<Any>) -> Unit): FeatureFixture {
    let sqls = ArrayList<String>()
    MOCKDB.clear()
    MOCKDB.execution = {sql, args =>
        sqls.add(sql)
        body(sql, args)
    }
    fixtureOf(driver, sqls)
}

func fixtureOf(driver: String, sqls: ArrayList<String>): FeatureFixture {
    let resources = resourcesOf()
    let accessor = RecordingAccessor(resources)
    accessor.driverName = driver
    let router = routerOf()
    let globals = GlobalTableRouter([])
    let executor = ExecutorDispatcher(router, globals, accessor, IdMakerConfig('uuid'), 'db0',
        HashMap<String, IdGenerator>(), None)
    FeatureFixture(executor, resources, accessor, sqls)
}

func paramOf(value: Int64): DataAny {
    DataAny(DataReal(value))
}
