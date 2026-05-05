package fountain::f_mockdb

import std.unittest.*
import std.unittest.testmacro.*

/**
 * Tests for MOCKDB exception simulation:
 * toThrowOnExecuting, unsupported method calls
 */
@Test
public class MockDBExceptionTest {
    @TestCase
    public func testThrowOnExecutingQuery(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultRow([1])
        }
        MOCKDB.toThrowOnExecuting = true
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT 1')
        try {
            let _ = stmt.query()
            @Assert(false)  // should not reach here
        } catch (e: MockDbException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testThrowOnExecutingUpdate(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> => () }
        MOCKDB.toThrowOnExecuting = true
        let conn = MockConnection()
        let stmt = conn.prepareStatement('UPDATE t SET x=1')
        try {
            let _ = stmt.update()
            @Assert(false)  // should not reach here
        } catch (e: MockDbException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testNoThrowWhenFlagFalse(): Unit {
        MOCKDB.clear()
        MOCKDB.execution = {_: String, _: ArrayList<Any> =>
            MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'SqlInteger')
            MOCKDB.addQueryResultRow([42])
        }
        MOCKDB.toThrowOnExecuting = false
        let conn = MockConnection()
        let stmt = conn.prepareStatement('SELECT 1')
        let rs = stmt.query()
        @Assert(true, rs.next())
        @Assert(42, rs.get<Int64>(0))
    }

    @TestCase
    public func testExceptionMessage(): Unit {
        try {
            throw MockDbException('test error')
        } catch (e: MockDbException) {
            @Assert('test error', e.message)
        }
    }
}
