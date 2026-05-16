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
 * f_net TCP 集成测试（放在 fmq 模块避免 f_net 子包循环依赖）。
 *
 * 测试覆盖：
 *   1. Server bind + Client connect
 *   2. Client.transfer() PING → Server reply PONG
 */
package fountain::f_net.test

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_net.client.*
import fountain::f_net.server.*
import fountain::f_protocol.default.{MessageID, EncodedMessage, Message, Command}

@Test
public class FNetTcpTest {
    private static let PORT: UInt16 = 20901
    private static let PORT2: UInt16 = 20902
    private static let HOST = "127.0.0.1"

    // ================================================================
    // 测试 1：服务端启动 + 客户端 connect
    // ================================================================

    @TestCase
    public func testServerBindAndClientConnect(): Unit {
        let server = Server<Message, EncodedMessage, Message, String>(
            queueSize: 64, bindAt: PORT,
            checkDuration: Duration.second * 60,
            checker: { _ => true })

        server.start({ msg => msg })
        sleep(Duration.millisecond * 800)

        // 验证端口可达
        try {
            let sock = TcpSocket(HOST, PORT)
            sock.close()
            @Assert(true)
        } catch (e: Exception) {
            println("connect failed: ${e.message}")
            @Assert(false)
        }

        server.close()
        sleep(Duration.millisecond * 200)  // 等待关闭完成
    }

    // ================================================================
    // 测试 2：Client.transfer() PING → PONG
    // ================================================================

    @TestCase
    public func testClientTransferPingPong(): Unit {
        // 服务端：收到任何消息均回复 PING(1)
        let server = Server<Message, EncodedMessage, Message, String>(
            queueSize: 64, bindAt: PORT2,
            checkDuration: Duration.second * 60,
            checker: { _ => true })
        server.start({ req => Message(Command.PING(1), req.id, "pong".toData()) })

        sleep(Duration.millisecond * 800)

        let client = Client<Message, EncodedMessage, Message, String, MessageID>.builder(
            queueSize: 64, socketCount: 1,
            host: HOST, port: PORT2,
            idGetter: { m => m.id },
            checkDuration: Duration.second * 60,
            checker: { _ => true }
        ).noDelay(true).build()

        let req = Message(Command.PING(0), MessageID(), "hello".toData())
        let resp = client.transfer(req.id, req, Duration.second * 5)
        @Assert(resp.isSome())
        if (let Some(r) <- resp) {
            @Assert(match (r.command) { case PING(1) => true case _ => false })
        }

        client.close()
        server.close()
        sleep(Duration.millisecond * 200)
    }
}
