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
package fountain::f_jsonrpc.client

import std.io.IOException
import fountain::f_data.*
import fountain::f_jsonrpc.base.*

class FakeTransport <: JsonRpcTransport {
    let request = Box<Array<Byte>>(Array<Byte>())
    private let reply: String
    var closed = false

    FakeTransport(reply: String) {
        this.reply = reply
    }

    public func send(body: Array<Byte>): Array<Byte> {
        request.value = body
        reply.unsafeBytes()
    }

    public func close(): Unit {
        closed = true
    }
}

/** 只在 `send` 阶段失败，用于验证重试边界。 */
class FailingTransport <: JsonRpcTransport {
    var calls = 0
    private let connectFailure: Bool

    FailingTransport(connectFailure: Bool) {
        this.connectFailure = connectFailure
    }

    public func send(body: Array<Byte>): Array<Byte> {
        calls++
        if (connectFailure) {
            throw JsonRpcConnectException('connect refused')
        }
        throw IOException('connection reset while reading response')
    }

    public func close(): Unit {}
}

@Test
class JsonRpcClient_test {
    static func requestOf(t: FakeTransport): JsonValue {
        JsonValue.fromBytes(t.request.value)
    }

    @TestCase
    public func testCallBuildsRequestAndReturnsResult(): Unit {
        let t = FakeTransport('{"jsonrpc":"2.0","id":1,"result":"ok"}')
        let client = JsonRpcClient(t)
        let result = client.call('ping')
        @Assert('ok', result.asString().value)
        let req = requestOf(t).asObject()
        @Assert('2.0', req['jsonrpc'].asString().value)
        @Assert('ping', req['method'].asString().value)
        @Assert('1', req['id'].asInt().value.toString())
    }

    @TestCase
    public func testCallSendsParams(): Unit {
        let t = FakeTransport('{"jsonrpc":"2.0","id":1,"result":1}')
        let client = JsonRpcClient(t)
        let params = JsonObject()
        params.add('a', 1)
        client.call('x', params: params)
        let req = requestOf(t).asObject()
        @Assert(1, req['params'].asObject()['a'].asInt().toInt64())
    }

    @TestCase
    public func testServerErrorThrows(): Unit {
        let t = FakeTransport(
            '{"jsonrpc":"2.0","id":1,"error":{"code":-32020,"message":"nope","data":"d"}}')
        let client = JsonRpcClient(t)
        try {
            client.call('x')
            @Fail('expected JsonRpcException')
        } catch (e: JsonRpcException) {
            @Assert(-32020, e.code)
            @Assert('nope', e.message)
            @Assert('d', e.data.getOrThrow().asString().value)
        }
    }

    @TestCase
    public func testNotifyHasNoId(): Unit {
        let t = FakeTransport('')
        let client = JsonRpcClient(t)
        client.notify('ping')
        let req = requestOf(t).asObject()
        @Assert(false, req.contains('id'))
        @Assert('ping', req['method'].asString().value)
    }

    @TestCase
    public func testBatchKeepsInputOrder(): Unit {
        let t = FakeTransport('[{"jsonrpc":"2.0","id":2,"result":"b"},{"jsonrpc":"2.0","id":1,"result":"a"}]')
        let client = JsonRpcClient(t)
        let responses = client.batch([JsonRpcCall('a'), JsonRpcCall('b')])
        @Assert(2, responses.size)
        @Assert('1', responses[0].id.getOrThrow().asInt().value.toString())
        @Assert('a', responses[0].result.getOrThrow().asString().value)
        @Assert('2', responses[1].id.getOrThrow().asInt().value.toString())
        @Assert('b', responses[1].result.getOrThrow().asString().value)
        let req = requestOf(t)
        @Assert(JsonKind.JsonArray, req.kind)
        @Assert(2, req.asArray().size)
    }

    @TestCase
    public func testCloseClosesTransport(): Unit {
        let t = FakeTransport('')
        JsonRpcClient(t).close()
        @Assert(true, t.closed)
    }

    // —— T2 重试边界 ——

    @TestCase
    public func testPlainIOExceptionIsNotRetried(): Unit {
        let t = FailingTransport(false)
        let client = JsonRpcClient(t, opts: ClientOptions(retryOnConnectFailure: 3))
        var failed = false
        try {
            client.call('x')
        } catch (_: IOException) {
            failed = true
        }
        @Assert(true, failed)
        @Assert(1, t.calls)
    }

    @TestCase
    public func testConnectFailureIsRetried(): Unit {
        let t = FailingTransport(true)
        let client = JsonRpcClient(t, opts: ClientOptions(retryOnConnectFailure: 3))
        var failed = false
        try {
            client.call('x')
        } catch (_: JsonRpcConnectException) {
            failed = true
        }
        @Assert(true, failed)
        @Assert(4, t.calls)
    }

    @TestCase
    public func testZeroRetryAttemptsOnce(): Unit {
        let t = FailingTransport(true)
        let client = JsonRpcClient(t, opts: ClientOptions(retryOnConnectFailure: 0))
        try {
            client.call('x')
        } catch (_: IOException) {
            ()
        }
        @Assert(1, t.calls)
    }

    // —— T3 批量单对象错误 ——

    @TestCase
    public func testBatchSingleErrorObjectThrowsWithCode(): Unit {
        let t = FakeTransport(
            '{"jsonrpc":"2.0","id":null,"error":{"code":-32003,"message":"too many","data":{"limit":2,"size":5}}}')
        let client = JsonRpcClient(t)
        try {
            client.batch([JsonRpcCall('a')])
            @Fail('expected JsonRpcException')
        } catch (e: JsonRpcException) {
            @Assert(-32003, e.code)
            @Assert(2, e.data.getOrThrow().asObject()['limit'].asInt().toInt64())
        }
    }

    @TestCase
    public func testBatchSingleNonErrorObjectThrowsInternalError(): Unit {
        let t = FakeTransport('{"jsonrpc":"2.0","id":1,"result":1}')
        let client = JsonRpcClient(t)
        try {
            client.batch([JsonRpcCall('a')])
            @Fail('expected JsonRpcException')
        } catch (e: JsonRpcException) {
            @Assert(JsonRpcProtocol.INTERNAL_ERROR, e.code)
            @Assert(true, e.message.contains('expected an array'))
        }
    }

    @TestCase
    public func testBatchEmptyInputReturnsEmpty(): Unit {
        let t = FakeTransport('[]')
        let client = JsonRpcClient(t)
        @Assert(0, client.batch([]).size)
    }

    // —— T4 客户端异常封闭 ——

    @TestCase
    public func testNonNumericCodeIsWrapped(): Unit {
        let t = FakeTransport('{"jsonrpc":"2.0","id":1,"error":{"code":"-32020","message":"nope"}}')
        let client = JsonRpcClient(t)
        try {
            client.call('x')
            @Fail('expected JsonRpcException')
        } catch (e: JsonRpcException) {
            @Assert(JsonRpcProtocol.INTERNAL_ERROR, e.code)
            @Assert('nope', e.message)
        }
    }

    @TestCase
    public func testMalformedBodyIsWrapped(): Unit {
        let t = FakeTransport('{not json')
        let client = JsonRpcClient(t)
        try {
            client.call('x')
            @Fail('expected JsonRpcException')
        } catch (e: JsonRpcException) {
            @Assert(JsonRpcProtocol.INTERNAL_ERROR, e.code)
            @Assert(true, e.message.contains('malformed'))
        } catch (_: Exception) {
            @Fail('JsonException leaked out of the client')
        }
    }

    @TestCase
    public func testErrorNullIsMalformed(): Unit {
        let t = FakeTransport('{"jsonrpc":"2.0","id":1,"error":null}')
        let client = JsonRpcClient(t)
        try {
            client.call('x')
            @Fail('expected JsonRpcException')
        } catch (e: JsonRpcException) {
            @Assert(JsonRpcProtocol.INTERNAL_ERROR, e.code)
            @Assert('malformed error object', e.message)
        }
    }

    @TestCase
    public func testErrorArrayIsMalformed(): Unit {
        let t = FakeTransport('{"jsonrpc":"2.0","id":1,"error":[1,2]}')
        let client = JsonRpcClient(t)
        try {
            client.call('x')
            @Fail('expected JsonRpcException')
        } catch (e: JsonRpcException) {
            @Assert('malformed error object', e.message)
        }
    }

    @TestCase
    public func testDecimalCodeStillWorks(): Unit {
        let t = FakeTransport('{"jsonrpc":"2.0","id":1,"error":{"code":-32603.0,"message":"x"}}')
        let client = JsonRpcClient(t)
        try {
            client.call('x')
            @Fail('expected JsonRpcException')
        } catch (e: JsonRpcException) {
            @Assert(-32603, e.code)
        }
    }

    // —— T5 客户端选项 / 异步 ——

    @TestCase
    public func testCallAsyncReturnsResult(): Unit {
        let t = FakeTransport('{"jsonrpc":"2.0","id":1,"result":"later"}')
        let client = JsonRpcClient(t)
        let future = client.callAsync('x')
        @Assert('later', future.get().asString().value)
    }
}
