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
 * f_net TCP 集成测试。
 *
 * 覆盖（对应 .autocode/bugs/bug-archived-on-20261004.md 7.9：f_net 的读取/发送路径必须有可执行用例）：
 *   1. Server bind + 裸 socket connect；
 *   2. Client.transfer() PING → 服务端内置 ACK（心跳路径）；
 *   3. SUBSCRIBE → 服务端 executor 回 RESP（业务请求/响应路径，含载荷往返）。
 *
 * 说明：`Server<T>` / `Client<T>` 的 T 是**服务端解码载荷用的类型**（约束 `T <: DataFields<T>`），
 * 这里用 `Array<Int64>`：f_data 已为集合实现 DataFields，且集合走独立的 dataType，
 * 不需要对象类型创建者注册（也就不会让用例依赖 DefaultCodec 的注册表状态）。
 */
package fountain::f_net.test

import std.net.TcpSocket
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_net.client.*
import fountain::f_net.server.*
import fountain::f_protocol.default.{MessageID, Message, Command}

private func pingChecker(): ?Message {
    Message.ping()
}

@Test
public class FNetTcpTest {
    private static let PORT: UInt16 = 20901
    private static let PORT2: UInt16 = 20902
    private static let PORT3: UInt16 = 20903
    private static let HOST = "127.0.0.1"

    // ================================================================
    // 测试 1：服务端启动 + 裸 socket connect
    // ================================================================

    @TestCase
    public func testServerBindAndClientConnect(): Unit {
        let server = Server<Array<Int64>>.builder(
            bufferQueueSize: 64, checkDuration: Duration.second * 60, checker: pingChecker, bindAt: PORT)
            .reuseAddress(true).build()

        spawn {
            server.start({ _, msg => msg })
        }
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
    // 测试 2：Client.transfer() PING → 服务端内置 ACK
    // ================================================================

    @TestCase
    public func testClientTransferPingAck(): Unit {
        let server = Server<Array<Int64>>.builder(
            bufferQueueSize: 64, checkDuration: Duration.second * 60, checker: pingChecker, bindAt: PORT2)
            .reuseAddress(true).build()
        spawn {
            // PING/ACK 由 Server.start 的内置逻辑处理，不会走到 executor
            server.start({ _, req => req })
        }
        sleep(Duration.millisecond * 800)

        let client = Client<Array<Int64>>.builder(
            queueSize: 64, socketCount: 1, host: HOST, port: PORT2,
            checkDuration: Duration.second * 60, checker: pingChecker
        ).noDelay(true).build()

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

    // ================================================================
    // 测试 3：executor 请求/响应 + 载荷往返
    // ================================================================

    @TestCase
    public func testExecutorRespondsWithPayload(): Unit {
        let server = Server<Array<Int64>>.builder(
            bufferQueueSize: 64, checkDuration: Duration.second * 60, checker: pingChecker, bindAt: PORT3)
            .reuseAddress(true).build()
        spawn {
            // 收到非 PING 的请求：把载荷原样带回，用 RESP 响应（覆盖 executor 与响应写回路径）
            server.start({ _, req => Message(Command.RESP(0u8), req.id, req.data) })
        }
        sleep(Duration.millisecond * 800)

        let client = Client<Array<Int64>>.builder(
            queueSize: 64, socketCount: 1, host: HOST, port: PORT3,
            checkDuration: Duration.second * 60, checker: pingChecker
        ).noDelay(true).build()

        let payload: Array<Int64> = [7, 8, 9]
        let req = Message.subscribe(data: payload)
        let resp = client.transfer(req, Duration.second * 5)
        @Assert(resp.isSome())
        if (let Some(r) <- resp) {
            @Assert(r.id == req.id)
            @Assert(match (r.command) { case Command.RESP(_) => true case _ => false })
            // 载荷必须逐字节往返：这是帧 + 编解码合起来的行为
            let echoed = convert<Array<Int64>>(r.data)
            @Assert(echoed.isSome())
            if (let Some(a) <- echoed) {
                @Assert(a.size == 3)
                @Assert(a[0] == 7 && a[1] == 8 && a[2] == 9)
            }
        }

        client.close()
        server.close()
        sleep(Duration.millisecond * 200)
    }
}
