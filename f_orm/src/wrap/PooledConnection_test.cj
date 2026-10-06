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
package fountain::f_orm.wrap

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import fountain::f_mockdb.*
import fountain::f_orm.exception.*

/**
 * bug-orm.md §3.2 `ORM-L8`：同一条池化连接被归还两次必须被拦下。
 *
 * `PooledConnection.close()` 用 `AtomicBool` CAS 做幂等；池侧没有身份去重（`SyncDeque` 只对
 * 「重复归还」告警、不拦），所以重复归还必须在归还这一步挡住——否则池里会出现两个指向同一连接
 * 的节点，两个借用者可能同时拿到同一条连接。
 *
 * 这里直接压 `activate()`（借出）+ `close()`（归还）这对动作，不经过 `DatabasePool`：
 * 一是这两步就是缺陷所在，二是建池会连带读一批全局 ORM 配置（其它用例会写这些键），
 * 用例只想钉住归还语义。
 */
@Test
public class PooledConnectionReturn_test {
    @TestCase
    public func testSecondCloseThrowsAndBorrowResetsFlag(): Unit {
        let returns = ArrayList<Int64>()
        let conn = PooledConnection(MockConnection())
        // 借出：等价于 DatabasePool.getConnection 里的 activate
        conn.activate({_ => returns.add(1)})
        conn.close()
        var thrownMessage = ''
        try {
            conn.close()
        } catch (e: ConnectionException) {
            thrownMessage = e.message
        }
        let returnsAfterDoubleClose = returns.size
        // 再次借出：标记复位，归还是合法的（幂等保护不能把连接变成一次性的）
        conn.activate({_ => returns.add(1)})
        conn.close()
        @Assert(true, thrownMessage.contains('returned multiple times'))
        @Assert(1, returnsAfterDoubleClose)
        @Assert(2, returns.size)
    }
}
