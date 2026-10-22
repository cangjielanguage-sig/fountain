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
package fountain::fdbm.server

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.DataAny
import fountain::f_dbd.common.*
import fountain::f_protocol.default.*

/**
 * T05 优雅停止：顺序必须是「先关会话（游标 + pin）→ 再关连接池」。
 *
 * 会话不先释放游标与 pin 时，池里始终有未归还的连接，`closeAndAwait` 只能等到超时。
 */
@Test
public class GracefulShutdownTest {

    @TestCase
    public func closeAllReleasesCursorAndPinBeforePools(): Unit {
        let harness = Harness(rows: [1])
        let client = harness.client()
        try {
            client.transfer(Message.consume(once: true, qos: QoS.AtMostOnce,
                data: SqlPayload('begin')), Duration.second * 5)
            let buffer = harness.lastBuffer()
            let session = harness.sessions.of(buffer)
            @Assert(session.isPinned(), true)

            client.transfer(Message.consume(once: true, qos: QoS.AtMostOnce,
                data: SqlPayload('select * from t where id = 1')), Duration.second * 5)
            @Assert(session.currentCursor().isSome(), true)

            harness.sessions.closeAll()
            @Assert(session.isClosed(), true)
            @Assert(session.currentCursor().isNone(), true)
            @Assert(session.isPinned(), false)
            @Assert(harness.sessions.size(), 0)
            // 会话已经归还游标与 pin，池应当立即终止（不是靠超时兜底）
            @Assert(harness.resources.closeAndAwait(timeout: Duration.second * 2), true)
            @Assert(harness.resources.isClosed(), true)
        } finally {
            client.close()
            harness.close()
        }
    }
}
