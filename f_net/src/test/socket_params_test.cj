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
 * 通过 f_net Server/Client 框架验证 populate 在已接受 socket 上不抛异常
 */
package fountain::f_net.test

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_net.client.*
import fountain::f_net.server.*
import fountain::f_protocol.default.{MessageID, EncodedMessage, Message, Command}

@Test
public class SocketParamsPopulateTest {
    private static let PORT: UInt16 = 20935

    @TestCase
    public func testPopulateOnAcceptedSocketDoesNotThrow(): Unit {
        // 使用简化的 echo server — populate 会在内部被调用
        let server = Server<Message, EncodedMessage, Message, String>(
            queueSize: 64, bindAt: PORT,
            checkDuration: Duration.second * 60,
            checker: { _ => true })
        spawn {
            server.start({ msg => msg })
        }
        sleep(Duration.millisecond * 800)

        // 验证客户端可以正常通信（说明服务器 accept 成功且 populate 未抛异常）
        let client = Client<Message, EncodedMessage, Message, String, MessageID>.builder(
            queueSize: 64, socketCount: 1,
            host: "127.0.0.1", port: PORT,
            idGetter: { m => m.id },
            checkDuration: Duration.second * 60,
            checker: { _ => true }
        ).noDelay(true).build()

        let req = Message(Command.PING(0), MessageID(), "test".toData())
        let resp = client.transfer(req.id, req, Duration.second * 5)
        @Assert(resp.isSome())

        client.close()
        server.close()
        sleep(Duration.millisecond * 200)
    }
}
