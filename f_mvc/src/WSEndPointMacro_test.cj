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
package fountain::f_mvc

import std.unittest.*
import std.unittest.testmacro.*
import std.net.*
import fountain::f_mvc.macros.*

/**
 * `@WSEndPoint` 宏生成物的回归端点，与 fdemo 的 `SmokeWSEndPoint` 同形（无 `@OnWS*` 处理器）：
 * 让**宏生成的端点级 `handle` 与注册代码**进入 f_mvc 自己的测试构建。
 *
 * 2025-12-04 的「移除 WebSocket 处理函数中的冗余参数」只改了宏的函数级一半，端点级一直多传一个
 * `converter`，而全仓当时没有 `@WSEndPoint` 使用者 ⇒ 十个月没暴露；2026-10-08 fdemo 的
 * `SmokeWSEndPoint` 一入库就撞上。本用例把这条链路钉在 f_mvc 自测里：宏与 `WSMeta` 再漂移，
 * 这里是第一个红的地方。
 *
 * 未覆盖：带 `@OnWS*` 处理器的端点（宏的函数级生成路径）——那需要在测试构建里跑
 * `ClassTypeInfo.getInstanceFunction` 反射并做帧级往返，另开用例时再补。
 */
@WSEndPoint['/ws/macro-smoke']
public class MacroSmokeWsEndpoint {}

/**
 * §3.2 / `MVC-13` 的宏版等价：**由宏注册**的端点同样要能被真实握手路由到 `WS` 键并升到
 * `HTTP/1.1 101`，而同路径的普通 `GET` 仍是 `405`。
 *
 * 与服务端骨架、判据同 `WebSocketRouting_test.cj`（那边是手写 `meta.setHandle` 的等价形状，
 * 这条走宏生成物）。端点实例由宏自带的 `@Bean` 注册，路由在模块初始化期注册，测试只负责
 * 起服务与发原始握手请求。
 */
@Test
class WSEndPointMacro_test {
    private static let PORT: UInt16 = 18100
    private static let PATH = '/ws/macro-smoke'

    /** 起一个真实 stdx 服务（返回 server 供收尾）；路由已由宏在模块初始化期注册 */
    private func startServer(): Server {
        let server = ServerBuilder()
            .addr('127.0.0.1')
            .port(PORT)
            .distributor(HttpRequestDistributorImpl.instance)
            .build()
        spawn {server.serve()}
        // 等端口就绪（最多 5 秒）
        for (_ in 0..50) {
            try {
                let probe = TcpSocket('127.0.0.1', PORT)
                probe.connect()
                probe.close()
                return server
            } catch (_: Exception) {
                sleep(Duration.millisecond * 100)
            }
        }
        server
    }

    /** 发一个原始请求（`extraHeaders` 用于 WS 握手头），返回响应首 256 字节文本（读不到返回 ''） */
    private func request(extraHeaders: String): String {
        let sock = TcpSocket('127.0.0.1', PORT)
        sock.connect()
        let req = 'GET ${PATH} HTTP/1.1\r\nHost: 127.0.0.1:${PORT}\r\n' + extraHeaders +
            'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'
        sock.write(req.unsafeBytes())
        let buf = Array<Byte>(256, repeat: 0)
        let n = try {
            sock.read(buf)
        } catch (_: Exception) {
            0
        }
        sock.close()
        if (n > 0) {
            String.fromUtf8(buf[0..n])
        } else {
            ''
        }
    }

    @TestCase
    public func testMacroGeneratedEndpointUpgrades(): Unit {
        let server = startServer()
        try {
            let upgraded = request('Upgrade: websocket\r\nConnection: Upgrade\r\n')
            let upLine = upgraded.split('\r\n')[0]
            println('WSEndPoint 宏 e2e: WS 握手响应首行 = ${upLine}')
            let plain = request('')
            let plainLine = plain.split('\r\n')[0]
            println('WSEndPoint 宏 e2e: 普通 GET 响应首行 = ${plainLine}')
            @Assert(true, upLine.startsWith('HTTP/1.1 101'))
            @Assert(true, plainLine.startsWith('HTTP/1.1 405'))
        } finally {
            server.closeGracefully()
        }
    }
}
