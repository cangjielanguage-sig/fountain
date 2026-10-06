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
package fountain::f_orm.base

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.HashMap
import std.database.sql.*
import std.time.MonoTime
import fountain::f_config.Config
import fountain::f_orm.exception.*
import fountain::f_orm.wrap.*

/** 状态永远停在 `Connecting` 的连接：模拟「驱动异步建连且永不成功」 */
private class StuckConnection <: Connection {
    private var closed_ = false
    public prop state: ConnectionState {
        get() {
            if (closed_) {
                Closed
            } else {
                Connecting
            }
        }
    }
    public func isClosed(): Bool {
        closed_
    }
    public func close(): Unit {
        closed_ = true
    }
    public func createTransaction(): Transaction {
        throw ConnectionException('stuck connection: createTransaction is not supported')
    }
    public func getMetaData(): Map<String, String> {
        HashMap<String, String>()
    }
    public func prepareStatement(sql: String): Statement {
        throw ConnectionException('stuck connection: prepareStatement is not supported')
    }
}

private class StuckDatasource <: Datasource {
    private var closed_ = false
    public func connect(): Connection {
        StuckConnection()
    }
    public func isClosed(): Bool {
        closed_
    }
    public func close(): Unit {
        closed_ = true
    }
    public func setOption(key: String, value: String): Unit {}
}

private class StuckDriver <: Driver {
    public prop name: String {
        get() {
            'stuck'
        }
    }
    public prop version: String {
        get() {
            '0.0.1'
        }
    }
    public prop preferredPooling: Bool {
        get() {
            false
        }
    }
    public func open(connectionString: String, opts: Array<(String, String)>): Datasource {
        StuckDatasource()
    }
}

/**
 * bug-orm.md §3.2 `ORM-L9`：`Connecting` 态的等待必须有上限。
 *
 * 原来 `case Connecting => continue` 是无 sleep、无超时的死转——驱动永不推进就永远烧一核。
 * 现在超过 `ORMConfig.getConnectingTimeout()`（默认 5 秒，可按键 `<driver>_orm_connectingTimeout` 覆盖）
 * 抛 `ConnectionException`。这里用一个永远停在 `Connecting` 的假驱动把超时路径钉住。
 */
@Test
public class SqlExecutorConnectingTimeout_test {
    @TestCase
    public func testConnectingWaitTimesOut(): Unit {
        Config.set([('stuck_orm_connectingTimeout', '50')])
        ORM.register(StuckDriver(), 'stuck://', default: false)
        let ex = ORM.executor('stuck')
        let start = MonoTime.now()
        var message = ''
        try {
            ex.setSql('select 1 as t_stuck').first<Int64>()
        } catch (e: ConnectionException) {
            message = e.message
        }
        let elapsed = MonoTime.now() - start
        ex.close()
        @Assert(true, message.contains('connecting is timeout'))
        @Assert(true, elapsed >= Duration.millisecond * 40)
    }
}
