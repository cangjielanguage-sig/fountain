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
}
