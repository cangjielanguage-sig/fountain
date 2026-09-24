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
    public func testGetOrNullReturnsNone(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'val', nullable: true, typeName: 'SqlVarchar')
            MOCKDB.addQueryResultRow(['hello'])
        }
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT val FROM t')
        let rs = stmt.query()
        @Assert(true, rs.next())
        // getOrNull with wrong index returns None
        let r = rs.getOrNull<String>(99)
        @Assert(true, r.isNone())
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
}
