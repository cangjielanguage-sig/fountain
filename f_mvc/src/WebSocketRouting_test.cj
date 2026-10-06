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

/**
 * 测试用空 WS 端点：**不加任何 `@OnWS*` 处理器** —— `WSMeta<T>.generate()` 对无注解函数
 * `continue`（`WSMeta.cj:406-408`）⇒ 得到一个空 meta，足够验证「握手能路由到 `WS` 键」。
 */
class SmokeWsEndpoint {}

/**
 * §3.2 / `MVC-13` 端到端：`GET + Upgrade: websocket` 必须被路由到 `WS` 键并完成协议升级
 * （响应 `HTTP/1.1 101`），而**无 `Upgrade` 头**的普通 GET 在同一路径上仍是 `405`
 * （证明本次修复的行为变化范围最小 —— 只影响真正的 WS 握手）。
 *
 * 为什么不用 fdemo 冒烟：fdemo 依赖 PostgreSQL（`fdemo/cjpm.toml` 的 `postgres_driver`、
 * `boot.sh` 的 `orm_drivers=postgres`，mockdb 那行是注释掉的），本机没有该服务 ⇒ 改为在
 * f_mvc 测试里起一个**真实 stdx 服务**（`ServerBuilder` + `HttpRequestDistributorImpl.instance`）
 * 并用**真实 TCP 客户端**发原始握手请求，做等价端到端。
 */
@Test
class WebSocketRouting_test {
    private static let PORT: UInt16 = 18099
    private static let PATH = '/ws/smoke'

    /** 注册 WS 端点 + 起服务（返回 server 供收尾） */
    private func startServer(): Server {
        let meta = MVCStarter.generateAndRegisterWSEndPoint<SmokeWsEndpoint>(PATH)
        // 与 macros/WSEndPoint.cj 生成的 `handle` 等价（此端点没有 converter / 没有处理器）
        meta.setHandle {endpoint, ctx, pattern =>
            let ws = meta.upgrade(ctx)
            meta.exec(endpoint, ctx, pattern, ws)
        }
        BeanFactory.instance.register {SmokeWsEndpoint()}
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
    public func testWsHandshakeIsRoutedToWsKey(): Unit {
        let server = startServer()
        try {
            // ① WS 握手（GET + Upgrade: websocket）⇒ 101（修前是 405）
            let upgraded = request('Upgrade: websocket\r\nConnection: Upgrade\r\n')
            let upLine = upgraded.split('\r\n')[0]
            println('MVC-13 e2e: WS 握手响应首行 = ${upLine}')
            // ② 同一路径的普通 GET（无 Upgrade 头）⇒ 仍是 405（行为范围最小）
            let plain = request('')
            let plainLine = plain.split('\r\n')[0]
            println('MVC-13 e2e: 普通 GET 响应首行 = ${plainLine}')
            @Assert(true, upLine.startsWith('HTTP/1.1 101'))
            @Assert(true, plainLine.startsWith('HTTP/1.1 405'))
        } finally {
            server.closeGracefully()
        }
    }
}
