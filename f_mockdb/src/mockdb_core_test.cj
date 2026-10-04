package fountain::f_mockdb

import std.unittest.*
import std.unittest.testmacro.*

/**
 * Tests for MOCKDB core functionality:
 * Driver, Datasource, Connection, Statement query/update, parameter binding, column info
 */
@Test
public class MockDBCoreTest {
    @TestCase
    public func testDriverDatasourceConnection(): Unit {
        let ds = MockDatasource()
        @Assert(false, ds.isClosed())
        let conn = ds.connect()
        @Assert(false, conn.isClosed())
        @Assert(Connected, conn.state)
        conn.close()
    }

    @TestCase
    public func testQuerySingleRowSingleColumn(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'name', nullable: false, typeName: 'SqlVarchar')
            MOCKDB.addQueryResultRow(['Alice'])
        }
        MOCKDB.toThrowOnExecuting = false
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT name FROM users')
        let rs = stmt.query()
        @Assert(true, rs.next())
        @Assert('Alice', rs.get<String>(0))
        @Assert(false, rs.next())
    }

    @TestCase
    public func testQueryMultipleRows(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultColumnInfo(name: 'name', nullable: false, typeName: 'SqlVarchar')
            MOCKDB.addQueryResultRow([1, 'Alice'])
            MOCKDB.addQueryResultRow([2, 'Bob'])
            MOCKDB.addQueryResultRow([3, 'Charlie'])
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT id, name FROM users')
        let rs = stmt.query()
        let names = ArrayList<String>()
        while(rs.next()){
            names.add(rs.get<String>(1))
        }
        @Assert(3, names.size)
        @Assert('Alice', names[0])
        @Assert('Bob', names[1])
        @Assert('Charlie', names[2])
    }

    @TestCase
    public func testUpdateResult(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.lastInsertId = 100
            MOCKDB.rowCount = 1
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('INSERT INTO users(name) VALUES(?)')
        stmt.set<String>(0, 'Alice')
        let ur = stmt.update()
        @Assert(100, ur.lastInsertId)
        @Assert(1, ur.rowCount)
    }

    @TestCase
    public func testDeleteUpdateResult(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {sql: String, _: ArrayList<Any> =>
            @Assert(true, sql.startsWith('DELETE'))
            MOCKDB.rowCount = 5
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('DELETE FROM users WHERE id < ?')
        stmt.set<Int64>(0, 10)
        let ur = stmt.update()
        @Assert(5, ur.rowCount)
    }

    @TestCase
    public func testSetNull(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'name', nullable: true, typeName: 'SqlVarchar')
            MOCKDB.addQueryResultRow(['Bob'])
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT name FROM users WHERE name = ?')
        stmt.setNull(0)
        let rs = stmt.query()
        @Assert(true, rs.next())
        @Assert('Bob', rs.get<String>(0))
    }

    @TestCase
    public func testSetNullOverwritesExistingValue(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'name', nullable: true, typeName: 'SqlVarchar')
            MOCKDB.addQueryResultRow(['Charlie'])
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT name FROM users WHERE name = ?')
        stmt.set<String>(0, 'Alice')
        stmt.setNull(0)
        let rs = stmt.query()
        @Assert(true, rs.next())
        @Assert('Charlie', rs.get<String>(0))
    }

    @TestCase
    public func testGetOrNullOutOfRangeThrows(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'val', nullable: true, typeName: 'SqlVarchar')
            MOCKDB.addQueryResultRow(['hello'])
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT val FROM t')
        let rs = stmt.query()
        @Assert(true, rs.next())
        //按 std 契约：索引超出列范围抛 SqlException（修复前返回 None）
        try {
            let _ = rs.getOrNull<String>(99)
            @Assert(false)
        } catch (e: SqlException) {
            @Assert(true)
        }
        try {
            let _ = rs.getOrNull<String>(-1)
            @Assert(false)
        } catch (e: SqlException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testGetOrNullBeforeNextThrows(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'val', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultRow([1])
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT val FROM t')
        let rs = stmt.query()
        //还没调用 next()：行数据未准备好 ⇒ 按 std 契约抛 SqlException（修复前返回 None）
        try {
            let _ = rs.getOrNull<Int64>(0)
            @Assert(false)
        } catch (e: SqlException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testGetOrNullTypeMismatchThrows(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'val', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultRow([1])
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT val FROM t')
        let rs = stmt.query()
        @Assert(true, rs.next())
        //列值是 Int64，却按 String 取：这不是 SQL NULL，应抛异常而不是静默 None（修复前返回 None）
        try {
            let _ = rs.getOrNull<String>(0)
            @Assert(false)
        } catch (e: SqlException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testGetOrNullNullValueReturnsNone(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'val', nullable: true, typeName: 'SqlInteger')
            let nullRow = ArrayList<Any>()
            nullRow.add(None<Any>)
            MOCKDB.addQueryResultRow(nullRow.toArray())
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT val FROM t')
        let rs = stmt.query()
        @Assert(true, rs.next())
        //真正的 SQL NULL 仍返回 None —— None 的唯一含义
        @Assert(true, rs.getOrNull<Int64>(0).isNone())
    }

    @TestCase
    public func testParameterBindingOrder(): Unit {
        MOCKDB.clear()
        let capturedArgs = ArrayList<Any>()
        MOCKDB.execution = {_: String, args: ArrayList<Any> =>
            for(a in args){ capturedArgs.add(a) }
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('INSERT INTO t(a, b, c) VALUES(?, ?, ?)')
        stmt.set<Int64>(0, 1)
        stmt.set<String>(1, 'hello')
        stmt.set<Int64>(2, 42)
        let _ = stmt.update()
        @Assert(3, capturedArgs.size)
        let a0 = capturedArgs[0]
        let a1 = capturedArgs[1]
        let a2 = capturedArgs[2]
        if (let x: Int64 <- a0) { @Assert(1, x) } else { @Assert(false) }
        if (let x: String <- a1) { @Assert('hello', x) } else { @Assert(false) }
        if (let x: Int64 <- a2) { @Assert(42, x) } else { @Assert(false) }
    }

    @TestCase
    public func testQueryResultColumnInfos(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultColumnInfo(name: 'name', nullable: true, typeName: 'SqlVarchar')
            MOCKDB.addQueryResultRow([1, 'Alice'])
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT id, name FROM users')
        let rs = stmt.query()
        let infos = rs.columnInfos
        @Assert(2, infos.size)
        @Assert('id', infos[0].name)
        @Assert(false, infos[0].nullable)
        @Assert('SqlInteger', infos[0].typeName)
        @Assert('name', infos[1].name)
        @Assert(true, infos[1].nullable)
        @Assert('SqlVarchar', infos[1].typeName)
    }

    @TestCase
    public func testEmptyResultSet(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'SqlInteger')
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT id FROM empty')
        let rs = stmt.query()
        @Assert(false, rs.next())
    }

    @TestCase
    public func testConnectionMetadata(): Unit {
        MOCKDB.clear()
        MOCKDB.metadata = HashMap<String, String>(
            ('version', '1.0'),
            ('database', 'mockdb')
        )
        let conn = MockConnection()
        let meta = conn.getMetaData()
        @Assert('1.0', meta.get('version').getOrThrow())
        @Assert('mockdb', meta.get('database').getOrThrow())
    }

    @TestCase
    public func testExecutionContext(): Unit {
        MOCKDB.clear()
        let capturedSql = ArrayList<String>()
        MOCKDB.execution = {s: String, a: ArrayList<Any> =>
            capturedSql.add(s)
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT 1')
        let _ = stmt.query()
        @Assert('SELECT 1', capturedSql[0])
    }

    @TestCase
    public func testQueryResultRowsIsolatedPerExecution(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {sql: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlInteger')
            if (sql == 'SELECT 1') {
                MOCKDB.addQueryResultRow([1])
            } else {
                MOCKDB.addQueryResultRow([2])
            }
        }
        let conn = MockConnection()
        let rs1 = conn.prepareStatement('SELECT 1').query()
        @Assert(true, rs1.next())
        @Assert(1, rs1.get<Int64>(0))
        @Assert(false, rs1.next())
        let rs2 = conn.prepareStatement('SELECT 2').query()
        @Assert(true, rs2.next())
        @Assert(2, rs2.get<Int64>(0))
        @Assert(false, rs2.next())
    }

    @TestCase
    public func testClearQueryResultKeepsFlagsAndExecution(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultRow([1])
        }
        let conn = MockConnection()
        let _ = conn.prepareStatement('SELECT 1').query()
        @Assert(1, MOCKDB.getQueryResultRows().size)
        @Assert(1, MOCKDB.queryResultColumnInfos.size)
        MOCKDB.toThrowOnExecuting = true
        MOCKDB.clearQueryResult()
        @Assert(0, MOCKDB.getQueryResultRows().size)
        @Assert(0, MOCKDB.queryResultColumnInfos.size)
        @Assert(true, MOCKDB.toThrowOnExecuting)
        MOCKDB.toThrowOnExecuting = false
        let rs = conn.prepareStatement('SELECT 2').query()
        @Assert(true, rs.next())
        @Assert(1, rs.get<Int64>(0))
    }

    @TestCase
    public func testQueryResultRowIsSnapshot(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {sql: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlInteger')
            if (sql == 'SELECT 1') {
                MOCKDB.addQueryResultRow([1])
            } else {
                MOCKDB.addQueryResultRow([2])
            }
        }
        let conn = MockConnection()
        let rs1 = conn.prepareStatement('SELECT 1').query()
        let _ = conn.prepareStatement('SELECT 2').query()
        @Assert(true, rs1.next())
        @Assert(1, rs1.get<Int64>(0))
        @Assert(false, rs1.next())
    }

    @TestCase
    public func testUpdateResultIsSnapshot(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {sql: String, _: ArrayList<Any> =>
            if (sql == 'INSERT 1') {
                MOCKDB.lastInsertId = 11
                MOCKDB.rowCount = 1
            } else {
                MOCKDB.lastInsertId = 22
                MOCKDB.rowCount = 2
            }
        }
        let conn = MockConnection()
        let ur1 = conn.prepareStatement('INSERT 1').update()
        let ur2 = conn.prepareStatement('INSERT 2').update()
        @Assert(11, ur1.lastInsertId)
        @Assert(1, ur1.rowCount)
        @Assert(22, ur2.lastInsertId)
        @Assert(2, ur2.rowCount)
    }

    @TestCase
    public func testUpdateResultSurvivesLaterReset(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.lastInsertId = 11
            MOCKDB.rowCount = 1
        }
        let conn = MockConnection()
        let ur = conn.prepareStatement('INSERT 1').update()
        MOCKDB.clear()
        @Assert(11, ur.lastInsertId)
        @Assert(1, ur.rowCount)
    }

    @TestCase
    public func testConnectionCloseState(): Unit {
        MOCKDB.clear()
        let conn = MockConnection()
        @Assert(false, conn.isClosed())
        @Assert(Connected, conn.state)
        conn.close()
        //关闭后必须能看出来（修复前 isClosed 恒 false、state 恒 Connected）
        @Assert(true, conn.isClosed())
        @Assert(Closed, conn.state)
        //重复关闭幂等
        conn.close()
        @Assert(true, conn.isClosed())
        @Assert(Closed, conn.state)
    }

    @TestCase
    public func testStatementAndQueryResultCloseState(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultRow([1])
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT v FROM t')
        @Assert(false, stmt.isClosed())
        let rs = stmt.query()
        @Assert(false, rs.isClosed())
        rs.close()
        @Assert(true, rs.isClosed())
        stmt.close()
        @Assert(true, stmt.isClosed())
    }

    @TestCase
    public func testDatasourceCloseState(): Unit {
        let ds = MockDatasource()
        @Assert(false, ds.isClosed())
        ds.close()
        @Assert(true, ds.isClosed())
        ds.close()
        @Assert(true, ds.isClosed())
    }

    @TestCase
    public func testCloseKeepsFixture(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultRow([1])
        }
        MOCKDB.toThrowOnExecuting = false
        let meta = HashMap<String, String>()
        meta['version'] = '1.0'
        MOCKDB.metadata = meta
        let conn = MockConnection()
        let _ = conn.prepareStatement('SELECT v FROM t').query()
        @Assert(1, MOCKDB.getQueryResultRows().size)
        conn.close()
        //关连接只应改变连接自身状态，不应动夹具（修复前 close() 会 MOCKDB.clear()）
        @Assert(1, MOCKDB.getQueryResultRows().size)
        @Assert(1, MOCKDB.queryResultColumnInfos.size)
        @Assert(false, MOCKDB.toThrowOnExecuting)
        @Assert('1.0', conn.getMetaData().get('version').getOrThrow())
        @Assert(true, conn.isClosed())
    }

    @TestCase
    public func testClearResetsFixture(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultRow([1])
            MOCKDB.lastInsertId = 7
            MOCKDB.rowCount = 3
        }
        let meta = HashMap<String, String>()
        meta['k'] = 'v'
        MOCKDB.metadata = meta
        let conn = MockConnection()
        let _ = conn.prepareStatement('SELECT v FROM t').query()
        MOCKDB.toThrowOnExecuting = true
        @Assert(1, MOCKDB.getQueryResultRows().size)
        @Assert(3, MOCKDB.rowCount)
        //显式清夹具（提升为 public 后包外也能调）后一切回默认值
        MOCKDB.clear()
        @Assert(0, MOCKDB.getQueryResultRows().size)
        @Assert(0, MOCKDB.queryResultColumnInfos.size)
        @Assert(false, MOCKDB.toThrowOnExecuting)
        @Assert(0, MOCKDB.lastInsertId)
        @Assert(0, MOCKDB.rowCount)
        @Assert(true, MOCKDB.metadata.get('k').isNone())
    }

    @TestCase
    public func testColumnInfoContractValues(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultRow([1])
        }
        let conn = MockConnection()
        let rs = conn.prepareStatement('SELECT v FROM t').query()
        let info = rs.columnInfos[0]
        //按 std 契约：无限制返回 Int64.Max、列大小不适用返回 0、无小数部分返回 0（修复前三个都抛 MockDbException）
        @Assert(Int64.Max, info.displaySize)
        @Assert(0, info.length)
        @Assert(0, info.scale)
    }

    @TestCase
    public func testStatementReuseDoesNotKeepArgs(): Unit {
        MOCKDB.clear()
        let argSizes = ArrayList<Int64>()
        MOCKDB.execution = {_: String, args: ArrayList<Any> =>
            argSizes.add(args.size)
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('UPDATE t SET a = ?, b = ?')
        stmt.set<String>(0, 'a')
        stmt.set<String>(1, 'b')
        let _ = stmt.update()
        stmt.set<String>(0, 'c')
        let _ = stmt.update()
        @Assert(2, argSizes.size)
        @Assert(2, argSizes[0])
        //第二次只绑定了 0 号参数：不应再带上第一次的 1 号参数（修复前这里读到 2）
        @Assert(1, argSizes[1])
    }

    @TestCase
    public func testSetNegativeIndexThrows(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> => ()}
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT v FROM t WHERE v = ?')
        //按 std 契约：参数索引越界抛 SqlException（修复前抛 IndexOutOfBoundsException）
        try {
            stmt.set<String>(-1, 'x')
            @Assert(false)
        } catch (e: SqlException) {
            @Assert(true)
        }
        try {
            stmt.setNull(-1)
            @Assert(false)
        } catch (e: SqlException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testThrowOnExecutingSkipsFixture(): Unit {
        MOCKDB.clear()
        let executed = ArrayList<Bool>()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            executed.add(true)
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultRow([1])
        }
        MOCKDB.toThrowOnExecuting = true
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT v FROM t')
        try {
            let _ = stmt.query()
            @Assert(false)
        } catch (e: MockDbException) {
            @Assert(true)
        }
        //声明抛异常的语句不应执行夹具、不应留下结果（修复前夹具已执行且行已写入结果集）
        @Assert(0, executed.size)
        @Assert(0, MOCKDB.getQueryResultRows().size)
    }

    @TestCase
    public func testMetadataReturnsCopy(): Unit {
        MOCKDB.clear()
        let meta = HashMap<String, String>()
        meta['version'] = '1.0'
        MOCKDB.metadata = meta
        let conn = MockConnection()
        let first = (conn.getMetaData() as HashMap<String, String>).getOrThrow()
        //改动拿到的元数据不应影响夹具与后续读取（修复前返回的是夹具本体，改一下就串了）
        first['version'] = 'changed'
        @Assert('1.0', conn.getMetaData().get('version').getOrThrow())
        @Assert('1.0', MOCKDB.metadata.get('version').getOrThrow())
    }

    @TestCase
    public func testVerboseSwitch(): Unit {
        //默认关闭（静默本身无法在进程内断言，用例覆盖开关语义与两种取值下的功能等价）
        @Assert(false, MOCKDB.verbose)
        MOCKDB.verbose = true
        @Assert(true, MOCKDB.verbose)
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultRow([1])
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT v FROM t')
        //verbose=true 时 mock 内部动作会输出（测试日志里可看到这一条 'Statement option'）
        stmt.setOption('k', 'v')
        let _ = stmt.query()
        MOCKDB.verbose = false
        let rs = conn.prepareStatement('SELECT v FROM t').query()
        @Assert(true, rs.next())
        @Assert(1, rs.get<Int64>(0))
    }

    @TestCase
    public func testDriverOpenRecordsArguments(): Unit {
        MOCKDB.clear()
        let driver: Driver = DriverManager.getDriver('mockdb').getOrThrow()
        let ds = driver.open('mockdb://localhost', [('cachePrepStmts', 'true'), ('prepStmtCacheSize', '250')])
        let mock = (ds as MockDatasource).getOrThrow()
        //open 的连接串与选项都应能从 mock 数据源读回（修复前只打印、不记录）
        @Assert('mockdb://localhost', mock.connectionString)
        @Assert('true', mock.options.get('cachePrepStmts').getOrThrow())
        @Assert('250', mock.options.get('prepStmtCacheSize').getOrThrow())
        //读到的选项是副本：改它不影响 mock
        let opts = (mock.options as HashMap<String, String>).getOrThrow()
        opts['cachePrepStmts'] = 'false'
        @Assert('true', mock.options.get('cachePrepStmts').getOrThrow())
    }

    @TestCase
    public func testSetIndexBeyondSqlParametersThrows(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'v', nullable: false, typeName: 'SqlVarchar')
            MOCKDB.addQueryResultRow(['ok'])
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT v FROM t WHERE v = ?')
        //SQL 只有 1 个占位符：大索引必须在 set 阶段就失败，不能真的补出上百万个占位符（修复前会分配）
        try {
            stmt.set<String>(1000000, 'x')
            @Assert(false)
        } catch (e: SqlException) {
            @Assert(true)
        }
        try {
            stmt.setNull(5)
            @Assert(false)
        } catch (e: SqlException) {
            @Assert(true)
        }
        //合法索引照常
        stmt.set<String>(0, 'ok')
        let rs = stmt.query()
        @Assert(true, rs.next())
        @Assert('ok', rs.get<String>(0))
    }
}
