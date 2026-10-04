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

/**
 * SocketParams.populate() 集成测试
 * 通过 f_net Server/Client 框架验证 populate 在已接受 socket 上不抛异常：
 * 若服务端 accept 后 populate 抛异常，连接建立不起来，下面的 PING/ACK 往返会失败。
 */
package fountain::f_net.test

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_net.client.*
import fountain::f_net.server.*
import fountain::f_protocol.default.{MessageID, Message, Command}

@Test
public class SocketParamsPopulateTest {
    private static let PORT: UInt16 = 20935

    private static func pingChecker(): ?Message {
        Message.ping()
    }

    @TestCase
    public func testPopulateOnAcceptedSocketDoesNotThrow(): Unit {
        let server = Server<Array<Int64>>.builder(
            bufferQueueSize: 64, checkDuration: Duration.second * 60, checker: pingChecker, bindAt: PORT)
            .reuseAddress(true).build()
        spawn {
            server.start({ _, msg => msg })
        }
        sleep(Duration.millisecond * 800)

        // 客户端带上非默认的 socket 参数，覆盖 populate 的实际配置路径
        let client = Client<Array<Int64>>.builder(
            queueSize: 64, socketCount: 1, host: "127.0.0.1", port: PORT,
            checkDuration: Duration.second * 60, checker: pingChecker
        ).noDelay(true).receiveBufferSize(4096).sendBufferSize(4096).build()

        let req = Message.ping()
        let resp = client.transfer(req, Duration.second * 5)
        @Assert(resp.isSome())
        if (let Some(r) <- resp) {
            @Assert(r.id == req.id)
            @Assert(match (r.command) { case Command.ACK => true case _ => false })
        }

        client.close()
        server.close()
        sleep(Duration.millisecond * 200)
    }
}
