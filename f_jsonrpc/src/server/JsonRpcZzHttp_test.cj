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
package fountain::f_jsonrpc.server

import std.collection.ArrayList
import std.net.{IPSocketAddress, TcpServerSocket, TcpSocket}
import std.sync.Mutex
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::f_data.*
import fountain::f_jsonrpc.base.*
import fountain::f_mvc.{MVCConfig, MVCStarter}

/**
 * `/rpc` 的 HTTP 行为（Content-Type）只能在真实的 MVC 请求链上验证：
 * 这里按 `MVCInitializer` 的方式启动一次 `MVCStarter`，让 `@Controller`
 * 注册好的路由与 `respond(JsonValue)` 都参与进来。
 */
private class MvcProbe {
    static let lock = Mutex()
    static var port: UInt16 = 0

    static func ensure(): UInt16 {
        synchronized(lock) {
            if (port != 0) {
                return port
            }
            let chosen = freePort()
            Config.set([(MVCConfig.HOST, '127.0.0.1'), (MVCConfig.PORT, chosen.toString())])
            MVCStarter.initialize()
            spawn {
                MVCStarter.start()
            }
            for (_ in 0..50) {
                try {
                    let probe = TcpSocket('127.0.0.1', chosen)
                    probe.connect()
                    probe.close()
                    break
                } catch (_: Exception) {
                    sleep(Duration.millisecond * 100)
                }
            }
            port = chosen
            return chosen
        }
    }

    private static func freePort(): UInt16 {
        let probe = TcpServerSocket(bindAt: 0)
        probe.bind()
        var chosen: UInt16 = 0
        match (probe.localAddress) {
            case addr: IPSocketAddress => chosen = addr.port
            case _ => ()
        }
        probe.close()
        chosen
    }
}

private func rawPost(port: UInt16, headers: String, body: String): String {
    let socket = TcpSocket('127.0.0.1', port)
    socket.connect()
    let request = 'POST /rpc HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n' +
        'Content-Type: application/json\r\nContent-Length: ${body.unsafeBytes().size}\r\n' + headers +
        'Connection: close\r\n\r\n' + body
    socket.write(request.unsafeBytes())
    let out = ArrayList<Byte>()
    let buf = Array<Byte>(4096, repeat: 0)
    while (true) {
        let n = try {
            socket.read(buf)
        } catch (_: Exception) {
            0
        }
        if (n <= 0) {
            break
        }
        out.add(all: buf[0..n])
    }
    socket.close()
    String.fromUtf8(out.unsafeData())
}

private func bodyPart(response: String): String {
    match (response.indexOf('\r\n\r\n')) {
        case Some(index) => response[index + 4..]
        case _ => ''
    }
}

private const PROBE_METHOD = 'http.probe'

/** 两个用例共用同一个方法：重复注册（用例顺序不定）时忽略重名异常。 */
private func ensureProbeMethod(): Unit {
    try {
        JsonRpcRegistry.register(JsonRpcMethodMeta(name: PROBE_METHOD, handler: {_, _ => JsonString('pong')}))
    } catch (_: JsonRpcException) {
        ()
    }
}

/**
 * 套件名以 `Zz` 开头是刻意的：`MVCStarter.initialize()` 是进程级一次性操作，
 * 启动后再调 `MVCStarter.generateAndRegister`（`JsonRpcMapping_test` 要用）会抛错，
 * 因此本套件必须最后执行 —— 单元测试框架按套件名升序调度。
 */
@Test
class JsonRpcZzHttp_test {
    // 客户端不带 Accept 时，响应 Content-Type 必须是 application/json，而不是通配 Accept 原文
    @TestCase
    public func testContentTypeWithoutAccept(): Unit {
        ensureProbeMethod()
        let port = MvcProbe.ensure()
        let response = rawPost(port, '', '{"jsonrpc":"2.0","id":1,"method":"${PROBE_METHOD}"}')
        @Assert(true, response.toAsciiLower().contains('content-type: application/json'))
        @Assert(false, response.contains('*/*'))
        @Assert('pong', JsonValue.fromStr(bodyPart(response)).asObject()['result'].asString().value)
    }

    /** `Accept: application/json` 时响应体与 `handle` 返回值的序列化一致。 */
    @TestCase
    public func testContentTypeWithJsonAcceptMatchesHandle(): Unit {
        ensureProbeMethod()
        let port = MvcProbe.ensure()
        let requestBody = '{"jsonrpc":"2.0","id":1,"method":"${PROBE_METHOD}"}'
        let expected = JsonRpcRegistry.server().handle(requestBody.unsafeBytes(), ctx: JsonRpcContext())
            .getOrThrow().toString()
        let response = rawPost(port, 'Accept: application/json\r\n', requestBody)
        @Assert(true, response.toAsciiLower().contains('content-type: application/json'))
        @Assert(expected, bodyPart(response))
    }

    /**
     * 注册 5000 个方法后，解析仍应只做一次哈希查找：
     * 与「只有 2 个方法」的服务器相比，单次 `handle` 耗时不应随方法表规模放大。
     */
    @TestCase
    public func testTopicResolveDoesNotScanMethodTable(): Unit {
        let small = buildServer(0)
        let big = buildServer(5000)
        let body = '{"jsonrpc":"2.0","id":1,"method":"a.ping"}'.unsafeBytes()
        let ctx = JsonRpcContext(endpoint: '/rpc/a', topic: 'a')
        for (_ in 0..50) {
            let _ = small.handle(body, ctx: ctx)
            let _ = big.handle(body, ctx: ctx)
        }
        let smallCost = measure(small, body)
        let bigCost = measure(big, body)
        // 旧实现每请求遍历整张方法表：5000 个方法会放大 3 个数量级，这里给足余量
        @Assert(true, bigCost <= smallCost * 4 + Duration.millisecond * 200)
    }

    /** `namespace()` 在构造期算好：方法名再长，重复取用也不应随名字长度放大。 */
    @TestCase
    public func testNamespaceIsPrecomputed(): Unit {
        let shortMeta = JsonRpcMethodMeta(name: 'crm.list', handler: {_, _ => JsonNull.instance})
        @Assert('crm', shortMeta.namespace())
        @Assert('', JsonRpcMethodMeta(name: 'plain', handler: {_, _ => JsonNull.instance}).namespace())

        let sb = StringBuilder('crm.')
        for (_ in 0..16_384) {
            sb.append('x')
        }
        let longMeta = JsonRpcMethodMeta(name: sb.toString(), handler: {_, _ => JsonNull.instance})
        @Assert('crm', longMeta.namespace())
        for (_ in 0..100) {
            let _ = shortMeta.namespace()
            let _ = longMeta.namespace()
        }
        let shortCost = namespaceCost(shortMeta)
        let longCost = namespaceCost(longMeta)
        // 旧实现每次 `name[0..i]` 都复制一遍名字：16 KiB 的方法名会明显放大耗时
        @Assert(true, longCost <= shortCost * 3 + Duration.millisecond * 100)
    }

    private func buildServer(extra: Int64): JsonRpcServer {
        let builder = JsonRpcServer.builder()
        builder.addMethod(JsonRpcMethodMeta(name: 'a.ping', handler: {_, _ => JsonString('pong')}))
        for (i in 0..extra) {
            builder.addMethod(JsonRpcMethodMeta(name: 'a.m${i}', handler: {_, _ => JsonNull.instance}))
        }
        builder.build()
    }

    private func measure(server: JsonRpcServer, body: Array<Byte>): Duration {
        let ctx = JsonRpcContext(endpoint: '/rpc/a', topic: 'a')
        let start = MonoTime.now()
        for (_ in 0..1000) {
            let _ = server.handle(body, ctx: ctx)
        }
        MonoTime.now() - start
    }

    private func namespaceCost(meta: JsonRpcMethodMeta): Duration {
        let start = MonoTime.now()
        for (_ in 0..200_000) {
            let _ = meta.namespace()
        }
        MonoTime.now() - start
    }
}
