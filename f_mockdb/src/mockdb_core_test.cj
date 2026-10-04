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
        MOCKDB.toThrowOnExecuting = true
        let meta = HashMap<String, String>()
        meta['k'] = 'v'
        MOCKDB.metadata = meta
        let conn = MockConnection()
        try {
            let _ = conn.prepareStatement('SELECT v FROM t').query()
            @Assert(false)
        } catch (e: MockDbException) {
            @Assert(true)
        }
        @Assert(1, MOCKDB.getQueryResultRows().size)
        //显式清夹具（提升为 public 后包外也能调）后一切回默认值
        MOCKDB.clear()
        @Assert(0, MOCKDB.getQueryResultRows().size)
        @Assert(0, MOCKDB.queryResultColumnInfos.size)
        @Assert(false, MOCKDB.toThrowOnExecuting)
        @Assert(0, MOCKDB.lastInsertId)
        @Assert(0, MOCKDB.rowCount)
        @Assert(true, MOCKDB.metadata.get('k').isNone())
    }
}
