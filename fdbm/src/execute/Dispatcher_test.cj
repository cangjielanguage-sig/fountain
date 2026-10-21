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
import std.fs.*
import std.sync.{AtomicBool, AtomicInt64}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbm.{IdGenerator, IdGeneratorException, PartitionAlgorithm}
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_mockdb.*
import fountain::fdbm.config.{BootScriptWriter, DatabaseNodeConfig, IdMakerConfig, LoadBalanceConfig,
    LogicalCatalog, MapConfigSource, PoolConfig}
import fountain::fdbm.exception.FdbmException
import fountain::fdbm.resources.{DatabaseResources, NodeAccessor}
import fountain::fdbm.route.{GlobalTableRouter, GlobalTableRule, PartitionCache, PartitionRouter,
    PartitionRule, StepPartition}
import fountain::fdbm.sql.*

/** 阶段 7：分发器与执行器的核心路径（mockdb 真实连接）。 */
@Test
public class DispatcherTest {

    private func dispatcher(): (ExecutorDispatcher, DatabaseResources) {
        MOCKDB.execution = {sql, _ =>
            if (sql.startsWith('select') || sql.startsWith('show')) {
                MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
                MOCKDB.addQueryResultRow([1])
            } else {
                MOCKDB.rowCount = 1
            }
        }
        let nodes = [DatabaseNodeConfig('name0', '127.0.0.1', 3306u16, 'mockdb', ['db0', 'db1'], '', '')]
        let poolConfig = PoolConfig(initSize: 0, minSize: 0, maxSize: 2, checkOnBorrowing: false,
            checkOnReturning: false, connectTimeout: Duration.second, maxWaiting: Duration.second)
        let resources = DatabaseResources(nodes, poolConfig, LoadBalanceConfig())
        let rules = [PartitionRule('db0', 't', 'id', StepPartition(['db0', 'db1'], 1000))]
        let router = PartitionRouter(rules, None, HashMap<String, PartitionAlgorithm>(),
            knownDatabases: ['db0', 'db1'], globalTables: GlobalTableRouter([]))
        let dispatcher = ExecutorDispatcher(router, GlobalTableRouter([]), resources,
            IdMakerConfig('uuid', arg: Some('4')), 'db0', HashMap<String, IdGenerator>(), None)
        (dispatcher, resources)
    }

    @TestCase
    public func selectSingleDatabase(): Unit {
        let (executor, resources) = dispatcher()
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = executor.execute(session, 'select * from t where id = 5', [])
            let cursor = outcome.cursor.getOrThrow()
            @Assert(outcome.columns.size, 1)
            @Assert(outcome.columns[0].typeName, 'Int64')
            @Assert(cursor.next(), true)
            @Assert(cursor.cell(0, 0).toString(), '1')
            cursor.close()
        } finally {
            session.close()
            resources.close()
        }
    }

    @TestCase
    public func selectMultiDatabaseMergesSegments(): Unit {
        let (executor, resources) = dispatcher()
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = executor.execute(session, 'select * from t where id in (5, 1500)', [])
            let cursor = outcome.cursor.getOrThrow()
            @Assert(outcome.columns.size, 1)
            @Assert(cursor.next(), true)
            @Assert(cursor.next(), true)
            @Assert(cursor.next(), false)
            cursor.close()
        } finally {
            session.close()
            resources.close()
        }
    }

    @TestCase
    public func updateSumsRowCounts(): Unit {
        let (executor, resources) = dispatcher()
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = executor.execute(session, 'update t set name = 1 where id in (5, 1500)', [])
            @Assert(outcome.update.getOrThrow().rowCount, 2)
        } finally {
            session.close()
            resources.close()
        }
    }

    @TestCase
    public func updateWithoutKeyIsRouteFailed(): Unit {
        let (executor, resources) = dispatcher()
        let session = DbdSession('s', None, 'db0')
        try {
            @Assert(codeOf { executor.execute(session, 'update t set name = 1', []) },
                DbdErrorCode.ROUTE_FAILED)
        } finally {
            session.close()
            resources.close()
        }
    }

    @TestCase
    public func showDatabasesUsesMemoryCursor(): Unit {
        let (executor, resources) = dispatcher()
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = executor.execute(session, 'show databases', [])
            let cursor = outcome.cursor.getOrThrow()
            @Assert(cursor.next(), true)
            @Assert(cursor.next(), true)
            @Assert(cursor.next(), false)
            cursor.close()
        } finally {
            session.close()
            resources.close()
        }
    }

    /** G16：会话关闭后不再接受新游标（立即关闭），close 幂等。 */
    @TestCase
    public func closedSessionRejectsNewCursor(): Unit {
        let session = DbdSession('s', None, 'db0')
        session.close()
        @Assert(session.installCursor(QueryCursor([], [])), false)
        @Assert(session.currentCursor().isNone(), true)
        session.close()
        @Assert(session.isClosed(), true)
    }

    @TestCase
    public func sessionControlPinsConnection(): Unit {
        let (executor, resources) = dispatcher()
        let session = DbdSession('s', None, 'db0')
        try {
            executor.execute(session, 'begin', [])
            @Assert(session.isPinned(), true)
            executor.execute(session, 'commit', [])
            @Assert((!session.isPinned()), true)
            @Assert(codeOf { executor.execute(session, 'commit', []) }, DbdErrorCode.TX_STATE)
        } finally {
            session.close()
            resources.close()
        }
    }

    // ==================== Step 7.3 InsertExecutor ====================

    @TestCase
    public func insertMultipleRowsRoutePerRow(): Unit {
        let fixture = recordingDispatcher(idmaker: IdMakerConfig('uuid', arg: Some('4')))
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                "insert into t (id, name) values (5, 'a'), (1500, 'b')", [])
            @Assert(outcome.update.getOrThrow().rowCount, 2)
            @Assert(fixture.accessor.writes.toArray(), ['db0', 'db1'])
            // 每个目标库一个事务：begin / insert / commit（G24）
            let inserts = ArrayList<String>()
            for (sql in fixture.sqls) {
                if (sql.startsWith('insert')) {
                    inserts.add(sql)
                }
            }
            @Assert(inserts.size, 2)
            @Assert(inserts[0].contains('(5'), true)
            @Assert(inserts[1].contains('(1500'), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func insertFillsPartitionColumnBeforeRouting(): Unit {
        let custom = HashMap<String, IdGenerator>()
        custom['fixed'] = FixedIdGenerator(500)
        let fixture = recordingDispatcher(idmaker: IdMakerConfig('fixed'), custom: custom)
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                "insert into t (name) values ('a')", [])
            @Assert(outcome.update.getOrThrow().rowCount, 1)
            let sql = singleInsertOf(fixture.sqls)
            @Assert(sql.startsWith('insert into t (name, id)'), true)
            // 回填值必须就是路由用的值：把 SQL 里的 id 字面量喂回算法，结果应与实际下推的库一致
            let literal = literalOfId(sql)
            let rule = PartitionRule('db0', 't', 'id', StepPartition(['db0', 'db1'], 1000))
            let expected = fixture.router.routeByValue(rule, literal)
            @Assert(fixture.accessor.writes.toArray(), [expected])
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    /** D11：生成器只实现 `nextStringId` 时，step 表回退到字符串 ID（不再回 INTERNAL）。 */
    @TestCase
    public func stringOnlyGeneratorFallsBackIntCapability(): Unit {
        let custom = HashMap<String, IdGenerator>()
        custom['stringonly'] = StringOnlyIdGenerator()
        let fixture = recordingDispatcher(idmaker: IdMakerConfig('stringonly'), custom: custom)
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = fixture.executor.execute(session,
                "insert into t (name) values ('a')", [])
            @Assert(outcome.update.getOrThrow().rowCount, 1)
            @Assert(singleInsertOf(fixture.sqls).contains("'1500'"), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    /** D11：两种能力都抛 `IdGeneratorException` → `ID_GENERATOR`。 */
    @TestCase
    public func generatorWithoutCapabilitiesIsIdGeneratorError(): Unit {
        let custom = HashMap<String, IdGenerator>()
        custom['broken'] = BrokenIdGenerator()
        let fixture = recordingDispatcher(idmaker: IdMakerConfig('broken'), custom: custom)
        let session = DbdSession('s', None, 'db0')
        try {
            @Assert(codeOf { fixture.executor.execute(session,
                "insert into t (name) values ('a')", []) }, DbdErrorCode.ID_GENERATOR)
            @Assert(fixture.sqls.isEmpty(), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func insertWithoutPartitionValueAndGeneratorIsRouteFailed(): Unit {
        let fixture = recordingDispatcher(idmaker: IdMakerConfig('no-such-generator'))
        let session = DbdSession('s', None, 'db0')
        try {
            @Assert(codeOf { fixture.executor.execute(session, "insert into t (name) values ('a')", []) },
                DbdErrorCode.ROUTE_FAILED)
            @Assert(fixture.sqls.isEmpty(), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func insertFromSelectMaterializesThenInserts(): Unit {
        let sqls = ArrayList<String>()
        MOCKDB.clear()
        MOCKDB.execution = {sql, _ =>
            sqls.add(sql)
            if (sql.startsWith('select')) {
                MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
                MOCKDB.addQueryResultColumnInfo(name: 'name', nullable: true, typeName: 'String')
                MOCKDB.addQueryResultRow([7, 'x'])
                MOCKDB.addQueryResultRow([1507, 'y'])
            } else {
                MOCKDB.rowCount = 1
            }
        }
        let resources = resourcesOf()
        let accessor = RecordingAccessor(resources)
        let router = routerOf()
        let select = SelectExecutor(accessor, router, GlobalTableRouter([]))
        let insert = InsertExecutor(accessor, router, GlobalTableRouter([]), select,
            IdMakerConfig('uuid'), 'db0', HashMap<String, IdGenerator>())
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = insert.execute(session,
                // 目标表与源表同名，但插入目标列由 insert 语句给出
                parseInsert("insert into t (id, name) select id, name from t where id = 5"))
            @Assert(outcome.update.getOrThrow().rowCount, 2)
            @Assert(sqls[0].startsWith('select'), true)
            var inserts = 0
            for (sql in sqls) {
                if (sql.startsWith('insert into t (id, name)')) {
                    inserts += 1
                }
            }
            @Assert(inserts, 2)
            @Assert(accessor.writes.toArray(), ['db0', 'db1'])
        } finally {
            session.close()
            resources.close()
        }
    }

    /** G24：同库多行 INSERT 的第三行失败 → 前两行回滚（同一事务）。 */
    @TestCase
    public func multiRowInsertRollsBackOnFailure(): Unit {
        let sqls = ArrayList<String>()
        let inserts = ArrayList<Int64>()
        MOCKDB.clear()
        MOCKDB.execution = {sql, _ =>
            sqls.add(sql)
            if (sql.startsWith('insert')) {
                inserts.add(1)
                if (inserts.size == 3) {
                    throw Exception('third row failed')
                }
                MOCKDB.rowCount = 1
            }
        }
        let resources = resourcesOf()
        let accessor = RecordingAccessor(resources)
        let router = routerOf()
        let select = SelectExecutor(accessor, router, GlobalTableRouter([]))
        let insert = InsertExecutor(accessor, router, GlobalTableRouter([]), select,
            IdMakerConfig('uuid'), 'db0', HashMap<String, IdGenerator>())
        let session = DbdSession('s', None, 'db0')
        try {
            @Assert(codeOf {
                insert.execute(session,
                    parseInsert("insert into t (id, name) values (1, 'a'), (2, 'b'), (3, 'c')"))
            }, DbdErrorCode.DB_ERROR)
            @Assert(sqls.contains('begin'), true)
            @Assert(sqls.contains('rollback'), true)
            @Assert(sqls.contains('commit'), false)
        } finally {
            session.close()
            resources.close()
        }
    }

    // ==================== Step 7.3 ShowExecutor / ExportExecutor ====================

    @TestCase
    public func showTablesUsesMysqlDialect(): Unit {
        let fixture = showFixture('mysql')
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = ShowExecutor(fixture.accessor).execute(session,
                ShowStatement(ShowKind.Tables, None, None))
            @Assert(fixture.sqls.toArray(), ['show tables'])
            @Assert(outcome.columns[0].name, 'table_name')
            let cursor = outcome.cursor.getOrThrow()
            @Assert(cursor.next(), true)
            @Assert(cursor.cell(0, 0).toString(), 't')
            cursor.close()
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func showTablesLikeUsesMysqlDialect(): Unit {
        let fixture = showFixture('mysql')
        let session = DbdSession('s', None, 'db0')
        try {
            ShowExecutor(fixture.accessor).execute(session,
                ShowStatement(ShowKind.Tables, None, Some('user%'))).cursor.getOrThrow().close()
            @Assert(fixture.sqls.toArray(), ["show tables like 'user%'"])
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func showTablesUsesPostgresDialect(): Unit {
        let fixture = showFixture('postgres')
        let session = DbdSession('s', None, 'db0')
        try {
            ShowExecutor(fixture.accessor).execute(session,
                ShowStatement(ShowKind.Tables, None, Some('u%'))).cursor.getOrThrow().close()
            @Assert(fixture.sqls.size, 1)
            @Assert(fixture.sqls[0].contains('information_schema.tables'), true)
            @Assert(fixture.sqls[0].contains("table_name like 'u%'"), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func showTablesTreatsMariadbAsMysql(): Unit {
        let fixture = showFixture('mariadb')
        let session = DbdSession('s', None, 'db0')
        try {
            ShowExecutor(fixture.accessor).execute(session,
                ShowStatement(ShowKind.Tables, None, None)).cursor.getOrThrow().close()
            @Assert(fixture.sqls.toArray(), ['show tables'])
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func showTablesTreatsOpengaussAsPostgres(): Unit {
        let fixture = showFixture('opengauss')
        let session = DbdSession('s', None, 'db0')
        try {
            ShowExecutor(fixture.accessor).execute(session,
                ShowStatement(ShowKind.Tables, None, None)).cursor.getOrThrow().close()
            @Assert(fixture.sqls.size, 1)
            @Assert(fixture.sqls[0].contains('information_schema.tables'), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func showTablesRejectsUnknownDriver(): Unit {
        let fixture = showFixture('oracle')
        let session = DbdSession('s', None, 'db0')
        try {
            @Assert(codeOf {
                ShowExecutor(fixture.accessor).execute(session,
                    ShowStatement(ShowKind.Tables, None, None))
            }, DbdErrorCode.UNSUPPORTED_SQL)
            @Assert(fixture.sqls.isEmpty(), true)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    @TestCase
    public func showDatabasesReturnsSortedNames(): Unit {
        let resources = resourcesOf(databases: ['db1', 'db0'])
        let accessor = RecordingAccessor(resources)
        let session = DbdSession('s', None, 'db0')
        try {
            @Assert(resources.databases(), ['db1', 'db0'])
            @Assert(ShowExecutor.sortedNames(['db1', 'db0']), ['db0', 'db1'])
            let outcome = ShowExecutor(accessor).execute(session,
                ShowStatement(ShowKind.Databases, None, None))
            let cursor = outcome.cursor.getOrThrow()
            let names = ArrayList<String>()
            while (cursor.next()) {
                names.add(cursor.cell(0, 0).toString())
            }
            @Assert(names.toArray(), ['db0', 'db1'])
            cursor.close()
        } finally {
            session.close()
            resources.close()
        }
    }

    /** D03：`SHOW DATABASES` 返回逻辑库集合（不含物理库名）。 */
    @TestCase
    public func showDatabasesUsesLogicalCatalog(): Unit {
        let resources = resourcesOf(databases: ['db0', 'db1', 'db2', 'db3'])
        let accessor = RecordingAccessor(resources)
        let catalog = logicalCatalogOf()
        let session = DbdSession('s', None, 'app')
        try {
            let outcome = ShowExecutor(accessor, catalog: catalog).execute(session,
                ShowStatement(ShowKind.Databases, None, None))
            let cursor = outcome.cursor.getOrThrow()
            let names = ArrayList<String>()
            while (cursor.next()) {
                names.add(cursor.cell(0, 0).toString())
            }
            @Assert(names.toArray(), ['app', 'cfg'])
            cursor.close()
        } finally {
            session.close()
            resources.close()
        }
    }

    /** D03：`SHOW TABLES <logical>` 按逻辑库解析物理库；未知逻辑库 → ROUTE_FAILED。 */
    @TestCase
    public func showTablesResolvesLogicalDatabase(): Unit {
        let fixture = showFixture('mysql')
        let catalog = logicalCatalogOf()
        let session = DbdSession('s', None, 'app')
        try {
            ShowExecutor(fixture.accessor, catalog: catalog).execute(session,
                ShowStatement(ShowKind.Tables, Some('app'), None)).cursor.getOrThrow().close()
            @Assert(fixture.accessor.reads.toArray(), ['db0'])
            @Assert(codeOf {
                ShowExecutor(fixture.accessor, catalog: catalog).execute(session,
                    ShowStatement(ShowKind.Tables, Some('nope'), None))
            }, DbdErrorCode.ROUTE_FAILED)
        } finally {
            session.close()
            fixture.resources.close()
        }
    }

    /** D04：事务 pin 下多目标语句必须拒绝（不得在同一 pin 连接上重复执行）。 */
    @TestCase
    public func pinnedTransactionRejectsMultiTargetStatements(): Unit {
        let (executor, resources) = dispatcher()
        let session = DbdSession('s', None, 'db0')
        try {
            executor.execute(session, 'begin', [])
            @Assert(codeOf {
                executor.execute(session, 'update t set name = 1 where id in (5, 1500)', [])
            }, DbdErrorCode.ROUTE_FAILED)
            @Assert(codeOf {
                executor.execute(session, 'delete from t where id in (5, 1500)', [])
            }, DbdErrorCode.ROUTE_FAILED)
            @Assert(codeOf {
                executor.execute(session, 'select * from t where id in (5, 1500)', [])
            }, DbdErrorCode.ROUTE_FAILED)
            @Assert(codeOf { executor.execute(session, 'create table x (id int64)', []) },
                DbdErrorCode.ROUTE_FAILED)
            // 单目标语句照常走 pin 连接
            let outcome = executor.execute(session, 'update t set name = 1 where id = 5', [])
            @Assert(outcome.update.getOrThrow().rowCount, 1)
            executor.execute(session, 'commit', [])
            @Assert((!session.isPinned()), true)
        } finally {
            session.close()
            resources.close()
        }
    }

    /** D03：事务 pin 的目标是逻辑库解析出的物理库，不是逻辑名本身。 */
    @TestCase
    public func beginPinsFirstPhysicalDatabase(): Unit {
        let (executor, accessor, resources) = logicalDispatcher()
        let session = DbdSession('s', None, 'app')
        try {
            executor.execute(session, 'begin', [])
            @Assert(accessor.writes.toArray(), ['db0'])
            @Assert(session.isPinned(), true)
            executor.execute(session, 'commit', [])
            @Assert((!session.isPinned()), true)
        } finally {
            session.close()
            resources.close()
        }
    }

    /** D03：会话逻辑库不在 catalog 中时 `begin` 直接拒绝，不借出任何连接。 */
    @TestCase
    public func beginWithUnknownLogicalDatabaseIsRejected(): Unit {
        let (executor, accessor, resources) = logicalDispatcher()
        let session = DbdSession('s', None, 'ghost')
        try {
            @Assert(codeOf { executor.execute(session, 'begin', []) }, DbdErrorCode.ROUTE_FAILED)
            @Assert(accessor.writes.isEmpty(), true)
            @Assert(session.isPinned(), false)
        } finally {
            session.close()
            resources.close()
        }
    }

    /**
     * T04：两个请求同时执行互不阻塞。
     *
     * 用「两个执行必须在物理层同时到达」作判据：任何全局串行化都会让先到的那个等满超时，
     * 于是 overlapped 保持 false（不依赖计时阈值，只依赖"有没有真的重叠"）。
     */
    @TestCase
    public func concurrentRequestsDoNotSerialize(): Unit {
        let resources = resourcesOf(databases: ['db0', 'db1'])
        let router = routerOf()
        let dispatcher = ExecutorDispatcher(router, GlobalTableRouter([]), resources,
            IdMakerConfig('uuid', arg: Some('4')), 'db0', HashMap<String, IdGenerator>(), None)
        let arrived = AtomicInt64(0)
        let overlapped = AtomicBool(false)
        MOCKDB.clear()
        MOCKDB.execution = {_, _ =>
            let seq = arrived.fetchAdd(1) + 1
            var waited = 0
            while (arrived.load() < 2 && waited < 2000) {
                sleep(Duration.millisecond * 5)
                waited += 5
            }
            if (seq == 1 && arrived.load() >= 2) {
                overlapped.store(true)
            }
            MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
            MOCKDB.addQueryResultRow([1])
        }
        let futures = ArrayList<Future<Unit>>()
        for (index in 0..2) {
            let session = DbdSession('c${index}', None, 'db0')
            let fut = spawn {
                let outcome = dispatcher.execute(session, 'select * from t where id = 5', [])
                outcome.cursor.getOrThrow().close()
                session.close()
            }
            futures.add(fut)
        }
        try {
            for (fut in futures) {
                fut.get()
            }
            @Assert(overlapped.load(), true)
        } finally {
            resources.close()
        }
    }

    /** D05：`Unroutable` SELECT 只广播到所属逻辑库的物理库。 */
    @TestCase
    public func unroutableSelectStaysInsideLogicalDatabase(): Unit {
        let (executor, accessor, resources) = logicalDispatcher()
        let session = DbdSession('s', None, 'app')
        try {
            let outcome = executor.execute(session, 'select * from t', [])
            outcome.cursor.getOrThrow().close()
            @Assert(accessor.reads.toArray(), ['db0', 'db1'])
        } finally {
            session.close()
            resources.close()
        }
    }

    /** D05：`count(*)` 与 DDL 的范围同样限定在逻辑库内。 */
    @TestCase
    public func broadcastCountAndDdlStayInsideLogicalDatabase(): Unit {
        let (executor, accessor, resources) = logicalDispatcher()
        let session = DbdSession('s', None, 'app')
        try {
            let outcome = executor.execute(session, 'select count(*) from t', [])
            let cursor = outcome.cursor.getOrThrow()
            @Assert(cursor.next(), true)
            @Assert(cursor.cell(0, 0).toString(), '2')
            cursor.close()
            @Assert(accessor.reads.toArray(), ['db0', 'db1'])

            executor.execute(session, 'create table x (id int64)', [])
            @Assert(accessor.writes.toArray(), ['db0', 'db1'])
        } finally {
            session.close()
            resources.close()
        }
    }

    /** D05：未知逻辑库限定 → ROUTE_FAILED（不再"广播成功"）。 */
    @TestCase
    public func unknownLogicalDatabaseBroadcastIsRejected(): Unit {
        let (executor, accessor, resources) = logicalDispatcher()
        let session = DbdSession('s', None, 'app')
        try {
            @Assert(codeOf { executor.execute(session, 'select * from ghost.t', []) },
                DbdErrorCode.ROUTE_FAILED)
            @Assert(accessor.reads.isEmpty(), true)
        } finally {
            session.close()
            resources.close()
        }
    }

    @TestCase
    public func exportWritesBootScriptAndReturnsZero(): Unit {
        let script = tempScript()
        try {
            let writer = BootScriptWriter(script.toString())
            let outcome = ExportExecutor(writer).execute(ExportStatement('fdbm_port', '9000'))
            @Assert(outcome.update.getOrThrow().rowCount, 0)
            @Assert(String.fromUtf8(File.readFrom(script)).contains("export fdbm_port='9000'"), true)
        } finally {
            removeScript(script)
        }
    }

    @TestCase
    public func exportRejectsNonWhitelistedKey(): Unit {
        let script = tempScript()
        try {
            let writer = BootScriptWriter(script.toString())
            @Assert(codeOf { ExportExecutor(writer).execute(ExportStatement('evil_key', '1')) },
                DbdErrorCode.CONFIG)
            @Assert(String.fromUtf8(File.readFrom(script)).contains('evil_key'), false)
        } finally {
            removeScript(script)
        }
    }

    @TestCase
    public func exportWithoutBootScriptIsConfigError(): Unit {
        @Assert(codeOf { ExportExecutor(None).execute(ExportStatement('fdbm_port', '9000')) },
            DbdErrorCode.CONFIG)
    }

    // ==================== 全局表写广播 / 未分库表 / DELETE 三步 ====================

    @TestCase
    public func unpartitionedTableInsertUsesSingleDatabase(): Unit {
        let (executor, resources, accessor) = plainFixture()
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = executor.execute(session, "insert into plain (id, name) values (1, 'a')", [])
            @Assert(outcome.update.getOrThrow().rowCount, 1)
            @Assert(accessor.writes.toArray(), ['db0'])
        } finally {
            session.close()
            resources.close()
        }
    }

    @TestCase
    public func globalTableInsertBroadcastsToEveryPhysicalDatabase(): Unit {
        let logicals = HashMap<String, Array<String>>()
        logicals['db0'] = ['db0', 'db1']
        let globals = GlobalTableRouter([GlobalTableRule('db0', 'dict')],
            logicalDatabases: logicals)
        let (executor, resources, accessor) = globalFixture(globals)
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = executor.execute(session, "insert into dict (k, v) values (1, 'a')", [])
            @Assert(outcome.update.getOrThrow().rowCount, 2)
            @Assert(accessor.writes.toArray(), ['db0', 'db1'])
        } finally {
            session.close()
            resources.close()
        }
    }

    @TestCase
    public func globalTableReadUsesOneReplica(): Unit {
        let logicals = HashMap<String, Array<String>>()
        logicals['db0'] = ['db0', 'db1']
        let globals = GlobalTableRouter([GlobalTableRule('db0', 'dict')],
            logicalDatabases: logicals)
        let (executor, resources, accessor) = globalFixture(globals)
        let session = DbdSession('s', None, 'db0')
        try {
            let outcome = executor.execute(session, 'select * from dict', [])
            let cursor = outcome.cursor.getOrThrow()
            @Assert(cursor.next(), true)
            @Assert(cursor.next(), false) // 只有一个副本，不重复返回
            cursor.close()
            @Assert(accessor.reads.toArray(), ['db0'])
        } finally {
            session.close()
            resources.close()
        }
    }

    /** G25（记录不修）：事务内的全局表写走独立连接、各自提交，`rollback` 不会撤销。 */
    @TestCase
    public func globalWriteInsideTransactionUsesIndependentConnections(): Unit {
        let logicals = HashMap<String, Array<String>>()
        logicals['db0'] = ['db0', 'db1']
        let globals = GlobalTableRouter([GlobalTableRule('db0', 'dict')],
            logicalDatabases: logicals)
        let (executor, resources, accessor) = globalFixture(globals)
        let session = DbdSession('s', None, 'db0')
        try {
            executor.execute(session, 'begin', [])
            @Assert(accessor.writes.toArray(), ['db0']) // pin 自身占一个写连接
            let outcome = executor.execute(session, "insert into dict (k, v) values (1, 'a')", [])
            @Assert(outcome.update.getOrThrow().rowCount, 2)
            // 广播不复用 pin 连接：又向 db0 / db1 各借了独立写连接
            @Assert(accessor.writes.toArray(), ['db0', 'db0', 'db1'])
            executor.execute(session, 'rollback', [])
            @Assert(session.isPinned(), false)
            // rollback 只作用于 pin 连接；广播写已各自提交，故不会被撤销（无 2PC）
            @Assert(accessor.writes.size, 3)
        } finally {
            session.close()
            resources.close()
        }
    }

    @TestCase
    public func globalTableWriteReportsPartialFailure(): Unit {
        let logicals = HashMap<String, Array<String>>()
        logicals['db0'] = ['db0', 'db1']
        let globals = GlobalTableRouter([GlobalTableRule('db0', 'dict')],
            logicalDatabases: logicals)
        let resources = resourcesOf()
        let accessor = FailingAccessor(resources, 'db1')
        let router = PartitionRouter([], None, HashMap<String, PartitionAlgorithm>(),
            knownDatabases: ['db0', 'db1'], globalTables: globals)
        let executor = ExecutorDispatcher(router, globals, accessor, IdMakerConfig('uuid'), 'db0',
            HashMap<String, IdGenerator>(), None)
        let session = DbdSession('s', None, 'db0')
        try {
            var message = ''
            try {
                executor.execute(session, "insert into dict (k, v) values (1, 'a')", [])
            } catch (e: FdbmException) {
                message = e.message
                @Assert(e.code, DbdErrorCode.DB_ERROR)
            }
            @Assert(message.contains('db1'), true)
            @Assert(message.contains('db0'), true)
        } finally {
            session.close()
            resources.close()
        }
    }

    @TestCase
    public func deleteQueriesKeysDeletesThenInvalidatesCache(): Unit {
        let dir = Directory.createTemp('/tmp')
        try {
            let cache = PartitionCache(dir.toString(), None, 0)
            cache.put('db0', 't', 'id', '5', 'db0')
            let sqls = ArrayList<String>()
            MOCKDB.clear()
            MOCKDB.execution = {sql, _ =>
                sqls.add(sql)
                if (sql.startsWith('select')) {
                    MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
                    MOCKDB.addQueryResultRow([5])
                } else {
                    MOCKDB.rowCount = 1
                }
            }
            let resources = resourcesOf()
            let accessor = RecordingAccessor(resources)
            let rules = [PartitionRule('db0', 't', 'id', StepPartition(['db0', 'db1'], 1000))]
            let router = PartitionRouter(rules, Some(cache), HashMap<String, PartitionAlgorithm>(),
                knownDatabases: ['db0', 'db1'], globalTables: GlobalTableRouter([]))
            let executor = ExecutorDispatcher(router, GlobalTableRouter([]), accessor,
                IdMakerConfig('uuid'), 'db0', HashMap<String, IdGenerator>(), None)
            let session = DbdSession('s', None, 'db0')
            try {
                let outcome = executor.execute(session, 'delete from t where id = 5', [])
                @Assert(outcome.update.getOrThrow().rowCount, 1)
                @Assert(sqls.toArray(), ['select id from t where (id = 5)', 'delete from t where (id = 5)'])
                @Assert(cache.get('db0', 't', 'id', '5').isNone(), true)
            } finally {
                session.close()
                resources.close()
            }
        } finally {
            remove(dir, recursive: true)
        }
    }

    @TestCase
    public func ddlPartialFailureListsDatabases(): Unit {
        let logicals = HashMap<String, Array<String>>()
        logicals['db0'] = ['db0', 'db1']
        let globals = GlobalTableRouter([], logicalDatabases: logicals)
        let resources = resourcesOf()
        let accessor = FailingAccessor(resources, 'db1')
        MOCKDB.clear()
        MOCKDB.execution = {_, _ => MOCKDB.rowCount = 0}
        let executor = DdlExecutor(accessor, globals)
        let session = DbdSession('s', None, 'db0')
        try {
            var message = ''
            try {
                executor.execute(session, parseDdl('create table x (id int)'))
            } catch (e: FdbmException) {
                message = e.message
                @Assert(e.code, DbdErrorCode.DB_ERROR)
            }
            @Assert(message.contains('db0'), true)
            @Assert(message.contains('db1'), true)
        } finally {
            session.close()
            resources.close()
        }
    }

    /** 无分库规则、只配置逻辑库映射的执行器。 */
    private func plainFixture(): (ExecutorDispatcher, DatabaseResources, RecordingAccessor) {
        let logicals = HashMap<String, Array<String>>()
        logicals['db0'] = ['db0', 'db1']
        let globals = GlobalTableRouter([], logicalDatabases: logicals)
        globalFixture(globals, rules: [])
    }

    private func globalFixture(globals: GlobalTableRouter,
        rules!: Array<PartitionRule> = [PartitionRule('db0', 't', 'id',
            StepPartition(['db0', 'db1'], 1000))]):
        (ExecutorDispatcher, DatabaseResources, RecordingAccessor) {
        MOCKDB.clear()
        MOCKDB.execution = {sql, _ =>
            if (sql.startsWith('select')) {
                MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
                MOCKDB.addQueryResultRow([1])
            } else {
                MOCKDB.rowCount = 1
            }
        }
        let resources = resourcesOf()
        let accessor = RecordingAccessor(resources)
        let router = PartitionRouter(rules, None, HashMap<String, PartitionAlgorithm>(),
            knownDatabases: ['db0', 'db1'], globalTables: globals)
        let executor = ExecutorDispatcher(router, globals, accessor, IdMakerConfig('uuid'), 'db0',
            HashMap<String, IdGenerator>(), None)
        (executor, resources, accessor)
    }
}

// ==================== 测试替身与工具 ====================

/** 记录借出方向的资源包装：执行器实际路由到哪个物理库一目了然。 */
class RecordingAccessor <: NodeAccessor {
    let inner: DatabaseResources
    let reads = ArrayList<String>()
    let writes = ArrayList<String>()
    var driverName: String = 'mockdb'

    init(inner: DatabaseResources) {
        this.inner = inner
    }

    public func selectRead(database: String): Connection {
        reads.add(database)
        inner.selectRead(database)
    }

    public func selectWrite(database: String): Connection {
        writes.add(database)
        inner.selectWrite(database)
    }

    public func selectAllWrite(database: String): Array<Connection> {
        writes.add(database)
        inner.selectAllWrite(database)
    }

    public func databases(): Array<String> {
        inner.databases()
    }

    public func contains(database: String): Bool {
        inner.contains(database)
    }

    public func readNodes(database: String): Array<String> {
        inner.readNodes(database)
    }

    public func driver(_: String): String {
        driverName
    }
}

/** 指定物理库的写入口直接失败（验证全局表广播的部分失败报错）。 */
class FailingAccessor <: NodeAccessor {
    private let inner: NodeAccessor
    private let failing: String

    init(inner: NodeAccessor, failing: String) {
        this.inner = inner
        this.failing = failing
    }

    public func selectRead(database: String): Connection {
        inner.selectRead(database)
    }

    public func selectWrite(database: String): Connection {
        if (database == failing) {
            throw FdbmException(DbdErrorCode.DB_ERROR, 'simulated failure on ${database}')
        }
        inner.selectWrite(database)
    }

    public func selectAllWrite(database: String): Array<Connection> {
        if (database == failing) {
            throw FdbmException(DbdErrorCode.DB_ERROR, 'simulated failure on ${database}')
        }
        inner.selectAllWrite(database)
    }

    public func databases(): Array<String> {
        inner.databases()
    }

    public func contains(database: String): Bool {
        inner.contains(database)
    }

    public func readNodes(database: String): Array<String> {
        inner.readNodes(database)
    }

    public func driver(database: String): String {
        inner.driver(database)
    }
}

class ExecutorFixture {
    let executor: ExecutorDispatcher
    let resources: DatabaseResources
    let accessor: RecordingAccessor
    let router: PartitionRouter
    let sqls: ArrayList<String>

    init(executor: ExecutorDispatcher, resources: DatabaseResources, accessor: RecordingAccessor,
        router: PartitionRouter, sqls: ArrayList<String>) {
        this.executor = executor
        this.resources = resources
        this.accessor = accessor
        this.router = router
        this.sqls = sqls
    }
}

class ShowFixture {
    let resources: DatabaseResources
    let accessor: RecordingAccessor
    let sqls: ArrayList<String>

    init(resources: DatabaseResources, accessor: RecordingAccessor, sqls: ArrayList<String>) {
        this.resources = resources
        this.accessor = accessor
        this.sqls = sqls
    }
}

/** 固定整型 ID：让 step 分片落在有效域内，用例可精确断言"回填值就是路由值"。 */
class FixedIdGenerator <: IdGenerator {
    private let value: Int64

    init(value: Int64) {
        this.value = value
    }

    public prop name: String {
        get() {
            'fixed'
        }
    }

    public func nextIntId(): Int64 {
        value
    }
}

/** 只实现字符串 ID 的生成器（step 表需要整型时调用方必须回退）。 */
class StringOnlyIdGenerator <: IdGenerator {
    public prop name: String {
        get() {
            'stringonly'
        }
    }

    public func nextStringId(): String {
        '1500'
    }
}

/** 两种 ID 能力都不可用：默认实现抛 `IdGeneratorException`。 */
class BrokenIdGenerator <: IdGenerator {
    public prop name: String {
        get() {
            'broken'
        }
    }

    public func nextIntId(): Int64 {
        throw IdGeneratorException('broken generator does not support int id')
    }

    public func nextStringId(): String {
        throw IdGeneratorException('broken generator does not support string id')
    }
}

func resourcesOf(databases!: Array<String> = ['db0', 'db1']): DatabaseResources {
    let nodes = [DatabaseNodeConfig('name0', '127.0.0.1', 3306u16, 'mockdb', databases, '', '')]
    let poolConfig = PoolConfig(initSize: 0, minSize: 0, maxSize: 2, checkOnBorrowing: false,
        checkOnReturning: false, connectTimeout: Duration.second, maxWaiting: Duration.second)
    DatabaseResources(nodes, poolConfig, LoadBalanceConfig())
}

/** 两个逻辑库的部署：`app(db0,db1)`、`cfg(db2,db3)`（逻辑名 ≠ 物理名）。 */
func logicalCatalogOf(): LogicalCatalog {
    let nodes = [DatabaseNodeConfig('name0', '127.0.0.1', 3306u16, 'mockdb',
        ['db0', 'db1', 'db2', 'db3'], '', '')]
    let values = HashMap<String, String>()
    values['fdbm_db_logicalDatabase_app'] = 'db0,db1'
    values['fdbm_db_logicalDatabase_cfg'] = 'db2,db3'
    LogicalCatalog.of(nodes, [], MapConfigSource(values))
}

/** 逻辑库 `app` 上的分片表 + 注入 catalog 的分发器。 */
func logicalDispatcher(): (ExecutorDispatcher, RecordingAccessor, DatabaseResources) {
    MOCKDB.clear()
    MOCKDB.execution = {sql, _ =>
        if (sql.startsWith('select') || sql.startsWith('show')) {
            MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
            MOCKDB.addQueryResultRow([1])
        } else {
            MOCKDB.rowCount = 1
        }
    }
    let resources = resourcesOf(databases: ['db0', 'db1', 'db2', 'db3'])
    let accessor = RecordingAccessor(resources)
    let rules = [PartitionRule('app', 't', 'id', StepPartition(['db0', 'db1'], 1000))]
    let router = PartitionRouter(rules, None, HashMap<String, PartitionAlgorithm>(),
        knownDatabases: ['db0', 'db1', 'db2', 'db3'], globalTables: GlobalTableRouter([]))
    let dispatcher = ExecutorDispatcher(router, GlobalTableRouter([]), accessor,
        IdMakerConfig('uuid', arg: Some('4')), 'db0', HashMap<String, IdGenerator>(), None,
        catalog: logicalCatalogOf())
    (dispatcher, accessor, resources)
}

func routerOf(): PartitionRouter {
    let rules = [PartitionRule('db0', 't', 'id', StepPartition(['db0', 'db1'], 1000))]
    PartitionRouter(rules, None, HashMap<String, PartitionAlgorithm>(),
        knownDatabases: ['db0', 'db1'], globalTables: GlobalTableRouter([]))
}

func recordingDispatcher(idmaker!: IdMakerConfig,
    custom!: HashMap<String, IdGenerator> = HashMap<String, IdGenerator>()): ExecutorFixture {
    let sqls = ArrayList<String>()
    MOCKDB.clear()
    MOCKDB.execution = {sql, _ =>
        sqls.add(sql)
        MOCKDB.rowCount = 1
    }
    let resources = resourcesOf()
    let accessor = RecordingAccessor(resources)
    let router = routerOf()
    let globals = GlobalTableRouter([])
    let executor = ExecutorDispatcher(router, globals, accessor, idmaker, 'db0',
        custom, None)
    ExecutorFixture(executor, resources, accessor, router, sqls)
}

func showFixture(driver: String): ShowFixture {
    let sqls = ArrayList<String>()
    MOCKDB.clear()
    MOCKDB.execution = {sql, _ =>
        sqls.add(sql)
        MOCKDB.addQueryResultColumnInfo(name: 'Tables_in_db0', nullable: false, typeName: 'String')
        MOCKDB.addQueryResultRow(['t'])
    }
    let resources = resourcesOf()
    let accessor = RecordingAccessor(resources)
    accessor.driverName = driver
    ShowFixture(resources, accessor, sqls)
}

/** 取唯一一条 INSERT 下推（忽略 G24 引入的 begin/commit）。 */
func singleInsertOf(sqls: ArrayList<String>): String {
    var found = ''
    for (sql in sqls) {
        if (sql.startsWith('insert')) {
            found = sql
        }
    }
    found
}

func parseInsert(sql: String): InsertStatement {
    match (SqlParser.parse(sql, 'db0')) {
        case statement: InsertStatement => statement
        case _ => throw FdbmException(DbdErrorCode.INTERNAL, 'not an insert statement')
    }
}

func parseDdl(sql: String): DdlStatement {
    match (SqlParser.parse(sql, 'db0')) {
        case statement: DdlStatement => statement
        case _ => throw FdbmException(DbdErrorCode.INTERNAL, 'not a ddl statement')
    }
}

/** 从 `insert into t(name, id) values('a', 123)` 里取出 id 字面量。 */
func literalOfId(sql: String): String {
    let close = match (sql.lastIndexOf(')')) {
        case Some(index) => index
        case None => sql.size
    }
    let body = sql[0..close]
    let comma = match (body.lastIndexOf(',')) {
        case Some(index) => index
        case None => 0
    }
    body[comma + 1..body.size].trimAscii()
}

func tempScript(): Path {
    let dir = Directory.createTemp('/tmp')
    let script = dir.join('boot.sh')
    File.writeTo(script, '#!/bin/bash\n'.toArray())
    script
}

func removeScript(script: Path): Unit {
    try {
        remove(Path(script.toString().replace('/boot.sh', '')), recursive: true)
    } catch (_: Exception) {
        ()
    }
}

func codeOf<T>(body: () -> T): DbdErrorCode {
    try {
        body()
    } catch (e: FdbmException) {
        return e.code
    } catch (_: Exception) {
        return DbdErrorCode.INTERNAL
    }
    DbdErrorCode.INTERNAL
}
