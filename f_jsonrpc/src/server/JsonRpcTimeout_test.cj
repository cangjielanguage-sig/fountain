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
import std.sync.AtomicInt64
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import stdx.net.http.*
import fountain::f_data.*
import fountain::f_jsonrpc.base.*
import fountain::f_jsonrpc.client.*
import fountain::f_mvc.CurrentHttpContext

/** 把 `(HttpContext) -> Unit` 包成 `HttpRequestHandler`，用于最小化真实 HTTP 面。 */
private class LambdaHandler <: HttpRequestHandler {
    private let body: (HttpContext) -> Unit

    LambdaHandler(body: (HttpContext) -> Unit) {
        this.body = body
    }

    public func handle(ctx: HttpContext): Unit {
        body(ctx)
    }
}

/** 所有路径都交给同一个 handler：测试只需要一个端点。 */
private class SingleDistributor <: HttpRequestDistributor {
    private let handler: HttpRequestHandler

    SingleDistributor(handler: HttpRequestHandler) {
        this.handler = handler
    }

    public func register(path: String, handler: HttpRequestHandler): Unit {}

    public func register(path: String, handler: (HttpContext) -> Unit): Unit {}

    public func distribute(path: String): HttpRequestHandler {
        handler
    }
}

private func readBody(ctx: HttpContext): Array<Byte> {
    let out = ArrayList<Byte>()
    let buf = Array<Byte>(4096, repeat: 0)
    while (true) {
        let n = try {
            ctx.request.body.read(buf)
        } catch (_: Exception) {
            -1
        }
        if (n <= 0) {
            break
        }
        out.add(all: buf[0..n])
    }
    out.unsafeData()
}

private func freePort(): UInt16 {
    let probe = TcpServerSocket(bindAt: 0)
    probe.bind()
    var port: UInt16 = 0
    match (probe.localAddress) {
        case addr: IPSocketAddress => port = addr.port
        case _ => ()
    }
    probe.close()
    port
}

/**
 * 起一个最小 HTTP server：请求体交给 `JsonRpcServer`，`handler` 决定外层如何建立上下文。
 * 返回 `(port, server)`。
 */
private func startRpcServer(rpc: JsonRpcServer, wrap: (HttpContext, () -> Unit) -> Unit): (UInt16, Server) {
    let port = freePort()
    let handler = LambdaHandler({ctx =>
        let body = readBody(ctx)
        wrap(ctx, {=>
            match (rpc.handle(body, ctx: JsonRpcContext(http: Some(ctx)))) {
                case Some(value) => ctx.responseBuilder.body(value.toString())
                case _ => ()
            }
        })
    })
    let server = ServerBuilder()
        .addr('127.0.0.1')
        .port(port)
        .distributor(SingleDistributor(handler))
        .build()
    spawn {
        server.serve()
    }
    for (_ in 0..50) {
        try {
            let probe = TcpSocket('127.0.0.1', port)
            probe.connect()
            probe.close()
            break
        } catch (_: Exception) {
            sleep(Duration.millisecond * 100)
        }
    }
    (port, server)
}

@Test
class JsonRpcTimeout_test {
    @TestCase
    public func testDefaultMethodRunsInlineOnRequestThread(): Unit {
        let rpc = JsonRpcServer.builder()
            .addMethod(JsonRpcMethodMeta(name: 'whoami', handler: {_, _ => JsonString('${Thread.currentThread.id}')}))
            .build()
        let workerTid = AtomicInt64(0)
        let (port, server) = startRpcServer(rpc, {_, body =>
            workerTid.store(Thread.currentThread.id)
            body()
        })
        let client = JsonRpcClient('http://127.0.0.1:${port}/rpc')
        let answer = Int64.parse(client.call('whoami').asString().value)
        client.close()
        server.close()
        // 默认无超时：handler 必须就在处理请求的那个线程执行（ThreadLocal 才可用）
        @Assert(workerTid.load(), answer)
    }

    @TestCase
    public func testDefaultMethodSeesCurrentHttpContext(): Unit {
        let rpc = JsonRpcServer.builder()
            .addMethod(JsonRpcMethodMeta(name: 'ctx', handler: {_, _ =>
                JsonString('ok:${CurrentHttpContext.instance.request.url}')
            }))
            .build()
        let (port, server) = startRpcServer(rpc, {ctx, body => CurrentHttpContext.scoped(Some(ctx), body)})
        let client = JsonRpcClient('http://127.0.0.1:${port}/rpc')
        let answer = client.call('ctx')
        client.close()
        server.close()
        @Assert('ok:/rpc', answer.asString().value)
    }

    @TestCase
    public func testExplicitTimeoutRestoresContextInChildThread(): Unit {
        let rpc = JsonRpcServer.builder()
            .addMethod(JsonRpcMethodMeta(
                name: 'ctx',
                handler: {_, _ => JsonString('ok:${CurrentHttpContext.instance.request.url}')},
                timeout: Duration.second * 5))
            .build()
        let (port, server) = startRpcServer(rpc, {ctx, body => CurrentHttpContext.scoped(Some(ctx), body)})
        let client = JsonRpcClient('http://127.0.0.1:${port}/rpc')
        let answer = client.call('ctx')
        client.close()
        server.close()
        @Assert('ok:/rpc', answer.asString().value)
    }

    @TestCase
    public func testExplicitTimeoutUsesCurrentRequestContext(): Unit {
        let rpc = JsonRpcServer.builder()
            .addMethod(JsonRpcMethodMeta(
                name: 'ctx',
                handler: {_, _ => JsonString(CurrentHttpContext.instance.request.url.toString())},
                timeout: Duration.second * 5))
            .build()
        let (port, server) = startRpcServer(rpc, {ctx, body => CurrentHttpContext.scoped(Some(ctx), body)})
        let client = JsonRpcClient('http://127.0.0.1:${port}/rpc')
        let first = client.call('ctx').asString().value
        let second = client.call('ctx').asString().value
        client.close()
        server.close()
        @Assert('/rpc', first)
        @Assert('/rpc', second)
    }

    @TestCase
    public func testExplicitTimeoutWithoutHttpRunsWithEmptyContext(): Unit {
        let seen = Box<String>('')
        let rpc = JsonRpcServer.builder()
            .addMethod(JsonRpcMethodMeta(
                name: 'probe',
                handler: {_, _ =>
                    try {
                        seen.value = CurrentHttpContext.instance.request.url.toString()
                    } catch (_: Exception) {
                        seen.value = 'absent'
                    }
                    JsonString(seen.value)
                },
                timeout: Duration.second * 5))
            .build()
        let answer = rpc.invoke('probe')
        @Assert('absent', answer.asString().value)
    }

    @TestCase
    public func testTimeoutStillReturnsTimeoutError(): Unit {
        let rpc = JsonRpcServer.builder()
            .addMethod(JsonRpcMethodMeta(
                name: 'slow',
                handler: {_, _ =>
                    let start = MonoTime.now()
                    while ((MonoTime.now() - start) < Duration.millisecond * 500) {}
                    JsonString('done')
                },
                timeout: Duration.millisecond * 100))
            .build()
        let (port, server) = startRpcServer(rpc, {_, body => body()})
        let client = JsonRpcClient('http://127.0.0.1:${port}/rpc')
        let begin = MonoTime.now()
        var code: Int64 = 0
        try {
            client.call('slow')
        } catch (e: JsonRpcException) {
            code = e.code
        }
        let elapsed = (MonoTime.now() - begin).toMilliseconds()
        client.close()
        server.close()
        @Assert(-32002, code)
        @Assert(true, elapsed < 400)
    }
}
