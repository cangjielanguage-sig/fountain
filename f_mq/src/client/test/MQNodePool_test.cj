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
package fountain::f_mq.client.test

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.base.MQProtocol
import fountain::f_mq.base.payload.MQResult
import fountain::f_mq.client.MQNodePool
import fountain::f_mq.exception.MQConnectionException
import fountain::f_net.SocketBuffer
import fountain::f_protocol.default.Message

@Test
class MQNodePoolTest {
    private static func ok(buffer: SocketBuffer, request: Message): ?Message {
        Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
    }

    @TestCase
    public func lazilyBuildsAndCaches(): Unit {
        let stub = MQStubServer(ok).start()
        try {
            let pool = MQNodePool([stub.address()])
            @Assert(pool.aliveNodes() == [0])
            pool.clientOf(0)
            pool.clientOf(0)
            // 关闭后不可再用
            pool.close()
            pool.close()
            @Assert(pool.isClosed())
            @Assert(pool.aliveNodes().size == 0)
            var threw = false
            try {
                pool.clientOf(0)
            } catch (_: MQConnectionException) {
                threw = true
            }
            @Assert(threw)
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func deadNodeThrows(): Unit {
        let pool = MQNodePool(["127.0.0.1:1"])
        var threw = false
        try {
            pool.clientOf(0)
        } catch (_: MQConnectionException) {
            threw = true
        }
        @Assert(threw)
        pool.close()
    }

    @TestCase
    public func invalidHostRejectedAtConstruction(): Unit {
        var threw = false
        try {
            MQNodePool(["no-port"])
        } catch (_: MQConnectionException) {
            threw = true
        }
        @Assert(threw)

        threw = false
        try {
            MQNodePool([])
        } catch (_: MQConnectionException) {
            threw = true
        }
        @Assert(threw)
    }
}
