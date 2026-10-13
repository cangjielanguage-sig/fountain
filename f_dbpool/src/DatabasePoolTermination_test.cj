// SPDX-License-Identifier: Apache-2.0
package fountain::f_dbpool

import std.database.sql.*
import std.sync.{AtomicBool, AtomicInt64}
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mockdb.MockConnection

private class BlockingTestDatasource <: Datasource {
    let entered = AtomicBool(false)
    let release = AtomicBool(false)
    let closeCount = AtomicInt64(0)
    let connection = MockConnection()

    public func setOption(key: String, value: String): Unit {}
    public func isClosed(): Bool { closeCount.load() > 0 }
    public func close(): Unit {
        if (!connection.isClosed()) {
            throw Exception('datasource closed before the late connection was disposed')
        }
        closeCount.fetchAdd(1)
    }
    public func connect(): Connection {
        entered.store(true)
        let start = MonoTime.now()
        while (!release.load() && MonoTime.now() - start < Duration.second * 3) {
            sleep(Duration.millisecond)
        }
        if (!release.load()) {
            throw Exception('datasource test callback was not released')
        }
        if (isClosed()) {
            throw Exception('datasource closed during connection creation')
        }
        connection
    }
}

@Test
public class DatabasePoolTerminationTest {
    @TestCase
    public func testCloseAndAwaitPreservesDatasourceUntilCreatorFinishes(): Unit {
        let ds = BlockingTestDatasource()
        let pool = DatabasePool(ds, initSize: 1, maxSize: 1,
            checkOnBorrowing: false, checkOnReturning: false, checkInterval: Duration.hour,
            checker: {_ => true})
        try {
            let start = MonoTime.now()
            while (!ds.entered.load() && MonoTime.now() - start < Duration.second * 2) {
                sleep(Duration.millisecond)
            }
            @Assert(ds.entered.load())
            @Assert(false, pool.closeAndAwait(timeout: Duration.millisecond * 30))
            @Assert(pool.isClosed())
            @Assert(false, ds.isClosed())
            @Assert(false, ds.connection.isClosed())
        } finally {
            ds.release.store(true)
            @Assert(pool.closeAndAwait(timeout: Duration.second * 2))
        }
        @Assert(ds.connection.isClosed())
        @Assert(1, ds.closeCount.load())
        @Assert(pool.closeAndAwait(timeout: Duration.second))
        @Assert(1, ds.closeCount.load())
    }
}
