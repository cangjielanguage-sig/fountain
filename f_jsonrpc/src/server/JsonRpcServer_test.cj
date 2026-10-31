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
import std.time.MonoTime
import std.sync.AtomicBool
import fountain::f_config.Config
import fountain::f_data.*
import fountain::f_jsonrpc.base.*
import fountain::f_mvc.MVCConfig

@Test
class JsonRpcServer_test {
    static func arr(values: Array<JsonValue>): JsonArray {
        let list = ArrayList<JsonValue>()
        for (v in values) {
            list.add(v)
        }
        JsonArray(list: list)
    }

    static func text(s: String): Array<Byte> {
        s.unsafeBytes()
    }

    static func serverWith(meta: JsonRpcMethodMeta): JsonRpcServer {
        JsonRpcServer.builder().addMethod(meta).build()
    }

    static func pingServer(): JsonRpcServer {
        serverWith(JsonRpcMethodMeta(name: 'ping', handler: {_, _ => JsonString('pong')}))
    }

    /** `handle` 直接返回 `JsonValue`；保留这个接缝让用例读起来不变。 */
    static func parse(value: JsonValue): JsonValue {
        value
    }

    static func errorOf(value: JsonValue): JsonObject {
        value.asObject()['error'].asObject()
    }

    @TestCase
    public func testSingleRequest(): Unit {
        let result = pingServer().handle(text('{"jsonrpc":"2.0","id":1,"method":"ping"}'), ctx: JsonRpcContext())
        match (result) {
            case Some(bytes) =>
                let obj = parse(bytes).asObject()
                @Assert('2.0', obj['jsonrpc'].asString().value)
                @Assert('1', obj['id'].asInt().value.toString())
                @Assert('pong', obj['result'].asString().value)
                @Assert(false, obj.contains('error'))
            case _ => @Fail('expected a response')
        }
    }

    @TestCase
    public func testMethodNotFound(): Unit {
        let result = pingServer().handle(text('{"jsonrpc":"2.0","id":1,"method":"nope"}'), ctx: JsonRpcContext())
        @Assert(-32601, errorOf(result.getOrThrow())['code'].asInt().toInt64())
    }

    @TestCase
    public func testParseError(): Unit {
        let result = pingServer().handle(text('{not json'), ctx: JsonRpcContext())
        @Assert(-32700, errorOf(result.getOrThrow())['code'].asInt().toInt64())
    }

    @TestCase
    public func testEmptyBodyIsParseError(): Unit {
        let result = pingServer().handle(Array<Byte>(), ctx: JsonRpcContext())
        @Assert(-32700, errorOf(result.getOrThrow())['code'].asInt().toInt64())
    }

    @TestCase
    public func testMissingVersion(): Unit {
        let result = pingServer().handle(text('{"id":1,"method":"ping"}'), ctx: JsonRpcContext())
        @Assert(-32600, errorOf(result.getOrThrow())['code'].asInt().toInt64())
    }

    @TestCase
    public func testMethodNotString(): Unit {
        let result = pingServer().handle(text('{"jsonrpc":"2.0","id":1,"method":1}'), ctx: JsonRpcContext())
        @Assert(-32600, errorOf(result.getOrThrow())['code'].asInt().toInt64())
    }

    @TestCase
    public func testBigIntegerIdPreserved(): Unit {
        let id = '123456789012345678901234567890'
        let body = '{"jsonrpc":"2.0","id":${id},"method":"ping"}'
        let obj = parse(pingServer().handle(text(body), ctx: JsonRpcContext()).getOrThrow()).asObject()
        @Assert(id, obj['id'].asInt().value.toString())
    }

    @TestCase
    public func testStringIdPreserved(): Unit {
        let obj = parse(
            pingServer().handle(text('{"jsonrpc":"2.0","id":"abc","method":"ping"}'), ctx: JsonRpcContext())
                .getOrThrow()).asObject()
        @Assert('abc', obj['id'].asString().value)
    }

    @TestCase
    public func testNullIdIsNotNotification(): Unit {
        let result = pingServer().handle(text('{"jsonrpc":"2.0","id":null,"method":"ping"}'), ctx: JsonRpcContext())
        match (result) {
            case Some(bytes) =>
                let obj = parse(bytes).asObject()
                @Assert(true, obj.contains('id'))
                @Assert(JsonKind.JsonNull, obj['id'].kind)
            case _ => @Fail('null id must be answered')
        }
    }

    @TestCase
    public func testNotificationReturnsNone(): Unit {
        let called = AtomicBool(false)
        let server = serverWith(JsonRpcMethodMeta(name: 'ping', handler: {_, _ =>
            called.store(true)
            JsonString('pong')
        }))
        let result = server.handle(text('{"jsonrpc":"2.0","method":"ping"}'), ctx: JsonRpcContext())
        @Assert(true, called.load())
        @Assert(true, result.isNone())
    }

    @TestCase
    public func testBatchMixedNotifications(): Unit {
        let body = '[{"jsonrpc":"2.0","id":1,"method":"ping"},' +
            '{"jsonrpc":"2.0","method":"ping"},' +
            '{"jsonrpc":"2.0","id":3,"method":"ping"}]'
        let result = pingServer().handle(text(body), ctx: JsonRpcContext())
        let arr = parse(result.getOrThrow()).asArray()
        @Assert(2, arr.size)
        @Assert('1', arr[0].asObject()['id'].asInt().value.toString())
        @Assert('3', arr[1].asObject()['id'].asInt().value.toString())
    }

    @TestCase
    public func testAllNotificationsBatchReturnsNone(): Unit {
        let body = '[{"jsonrpc":"2.0","method":"ping"},{"jsonrpc":"2.0","method":"ping"}]'
        @Assert(true, pingServer().handle(text(body), ctx: JsonRpcContext()).isNone())
    }

    @TestCase
    public func testEmptyBatch(): Unit {
        let result = pingServer().handle(text('[]'), ctx: JsonRpcContext())
        let value = parse(result.getOrThrow())
        @Assert(JsonKind.JsonObject, value.kind)
        @Assert(-32600, value.asObject()['error'].asObject()['code'].asInt().toInt64())
    }

    @TestCase
    public func testBatchTooLarge(): Unit {
        let server = JsonRpcServer.builder()
            .maxBatchSize(2)
            .addMethod(JsonRpcMethodMeta(name: 'ping', handler: {_, _ => JsonString('pong')}))
            .build()
        let body = '[{"jsonrpc":"2.0","id":1,"method":"ping"},' +
            '{"jsonrpc":"2.0","id":2,"method":"ping"},' +
            '{"jsonrpc":"2.0","id":3,"method":"ping"}]'
        let value = parse(server.handle(text(body), ctx: JsonRpcContext()).getOrThrow())
        @Assert(-32003, value.asObject()['error'].asObject()['code'].asInt().toInt64())
    }

    @TestCase
    public func testBatchPartialInvalid(): Unit {
        let body = '[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":1}]'
        let arr = parse(pingServer().handle(text(body), ctx: JsonRpcContext()).getOrThrow()).asArray()
        @Assert(2, arr.size)
        @Assert(true, arr[0].asObject().contains('result'))
        @Assert(-32600, arr[1].asObject()['error'].asObject()['code'].asInt().toInt64())
    }

    @TestCase
    public func testTopicNamespaceMatch(): Unit {
        let server = serverWith(JsonRpcMethodMeta(name: 'kb.search', handler: {_, _ => JsonString('found')}))
        let ctx = JsonRpcContext(endpoint: '/rpc/kb', topic: 'kb')
        let value = parse(
            server.handle(text('{"jsonrpc":"2.0","id":1,"method":"kb.search"}'), ctx: ctx).getOrThrow())
        @Assert('found', value.asObject()['result'].asString().value)
    }

    @TestCase
    public func testTopicNamespaceCross(): Unit {
        let server = JsonRpcServer.builder()
            .addMethod(JsonRpcMethodMeta(name: 'kb.search', handler: {_, _ => JsonString('k')}))
            .addMethod(JsonRpcMethodMeta(name: 'crm.list', handler: {_, _ => JsonString('x')}))
            .build()
        let ctx = JsonRpcContext(endpoint: '/rpc/kb', topic: 'kb')
        let value = parse(
            server.handle(text('{"jsonrpc":"2.0","id":1,"method":"crm.list"}'), ctx: ctx).getOrThrow())
        @Assert(-32601, value.asObject()['error'].asObject()['code'].asInt().toInt64())
    }

    @TestCase
    public func testUnknownTopic(): Unit {
        let ctx = JsonRpcContext(endpoint: '/rpc/none', topic: 'none')
        let value = parse(
            pingServer().handle(text('{"jsonrpc":"2.0","id":1,"method":"ping"}'), ctx: ctx).getOrThrow())
        @Assert(-32004, value.asObject()['error'].asObject()['code'].asInt().toInt64())
    }

    @TestCase
    public func testTopicRejectsMethodsWithoutDot(): Unit {
        let ctx = JsonRpcContext(endpoint: '/rpc/kb', topic: 'kb')
        let server = JsonRpcServer.builder()
            .addMethod(JsonRpcMethodMeta(name: 'kb.search', handler: {_, _ => JsonString('k')}))
            .addMethod(JsonRpcMethodMeta(name: 'ping', handler: {_, _ => JsonString('pong')}))
            .build()
        let value = parse(
            server.handle(text('{"jsonrpc":"2.0","id":1,"method":"ping"}'), ctx: ctx).getOrThrow())
        @Assert(-32601, value.asObject()['error'].asObject()['code'].asInt().toInt64())
    }

    @TestCase
    public func testSchemaValidation(): Unit {
        let schema = JsonObject()
        schema.add('type', 'object')
        let props = JsonObject()
        let query = JsonObject()
        query.add('type', 'string')
        query.add('minLength', 2)
        props.add('query', query)
        schema.add('properties', props)
        schema.add('required', arr([JsonString('query')]))

        let called = AtomicBool(false)
        let server = serverWith(JsonRpcMethodMeta(
            name: 'search',
            handler: {_, _ =>
                called.store(true)
                JsonString('ok')
            },
            paramsSchema: schema))
        let value = parse(server.handle(
            text('{"jsonrpc":"2.0","id":1,"method":"search","params":{"query":"a"}}'),
            ctx: JsonRpcContext()).getOrThrow())
        let error = value.asObject()['error'].asObject()
        @Assert(-32602, error['code'].asInt().toInt64())
        @Assert(true, error.contains('data'))
        @Assert(true, error['data'].asArray().size > 0)
        @Assert(false, called.load())
    }

    @TestCase
    public func testSchemaValidationMissingParams(): Unit {
        let schema = JsonObject()
        schema.add('type', 'object')
        schema.add('required', arr([JsonString('query')]))
        let server = serverWith(JsonRpcMethodMeta(
            name: 'search', handler: {_, _ => JsonString('ok')}, paramsSchema: schema))
        let value = parse(
            server.handle(text('{"jsonrpc":"2.0","id":1,"method":"search"}'), ctx: JsonRpcContext()).getOrThrow())
        @Assert(-32602, value.asObject()['error'].asObject()['code'].asInt().toInt64())
    }

    @TestCase
    public func testNoSchemaSkipsValidation(): Unit {
        let server = serverWith(JsonRpcMethodMeta(name: 'ping', handler: {_, p => p ?? JsonString('pong')}))
        let value = parse(
            server.handle(text('{"jsonrpc":"2.0","id":1,"method":"ping","params":{"a":1}}'),
                ctx: JsonRpcContext()).getOrThrow())
        @Assert(true, value.asObject().contains('result'))
    }

    @TestCase
    public func testTimeout(): Unit {
        let server = serverWith(JsonRpcMethodMeta(
            name: 'slow',
            handler: {_, _ =>
                let start = MonoTime.now()
                while ((MonoTime.now() - start) < Duration.millisecond * 300) {}
                JsonString('done')
            },
            timeout: Duration.millisecond * 20))
        let begin = MonoTime.now()
        let value = parse(
            server.handle(text('{"jsonrpc":"2.0","id":1,"method":"slow"}'), ctx: JsonRpcContext()).getOrThrow())
        let elapsed = MonoTime.now() - begin
        @Assert(-32002, value.asObject()['error'].asObject()['code'].asInt().toInt64())
        @Assert(true, elapsed < Duration.millisecond * 250)
    }

    @TestCase
    public func testNoTimeoutWaitsForHandler(): Unit {
        let server = serverWith(JsonRpcMethodMeta(name: 'slow', handler: {_, _ =>
            let start = MonoTime.now()
            while ((MonoTime.now() - start) < Duration.millisecond * 30) {}
            JsonString('done')
        }))
        let value = parse(
            server.handle(text('{"jsonrpc":"2.0","id":1,"method":"slow"}'), ctx: JsonRpcContext()).getOrThrow())
        @Assert('done', value.asObject()['result'].asString().value)
    }

    @TestCase
    public func testInternalErrorIsGeneric(): Unit {
        let server = serverWith(JsonRpcMethodMeta(name: 'boom', handler: {_, _ =>
            throw IllegalArgumentException('/etc/passwd secret')
        }))
        let value = parse(
            server.handle(text('{"jsonrpc":"2.0","id":1,"method":"boom"}'), ctx: JsonRpcContext()).getOrThrow())
        let error = value.asObject()['error'].asObject()
        @Assert(-32603, error['code'].asInt().toInt64())
        @Assert('Internal error', error['message'].asString().value)
        @Assert(false, error['message'].asString().value.contains('passwd'))
    }

    @TestCase
    public func testBusinessErrorKeepsData(): Unit {
        let server = serverWith(JsonRpcMethodMeta(name: 'biz', handler: {_, _ =>
            throw JsonRpcException(-32020, 'knowledge base not found', data: JsonString('kb-1'))
        }))
        let error = errorOf(
            server.handle(text('{"jsonrpc":"2.0","id":1,"method":"biz"}'), ctx: JsonRpcContext()).getOrThrow())
        @Assert(-32020, error['code'].asInt().toInt64())
        @Assert('knowledge base not found', error['message'].asString().value)
        @Assert('kb-1', error['data'].asString().value)
    }

    @TestCase
    public func testBodyTooLarge(): Unit {
        let server = JsonRpcServer.builder()
            .maxBodyBytes(16)
            .addMethod(JsonRpcMethodMeta(name: 'ping', handler: {_, _ => JsonString('pong')}))
            .build()
        let value = parse(
            server.handle(text('{"jsonrpc":"2.0","id":1,"method":"ping"}'), ctx: JsonRpcContext()).getOrThrow())
        @Assert(-32600, value.asObject()['error'].asObject()['code'].asInt().toInt64())
    }

    @TestCase
    public func testInvalidUtf8IsParseError(): Unit {
        let bad: Array<Byte> = [0xff, 0xfe, 0x00]
        let value = parse(pingServer().handle(bad, ctx: JsonRpcContext()).getOrThrow())
        @Assert(-32700, value.asObject()['error'].asObject()['code'].asInt().toInt64())
    }

    @TestCase
    public func testInvokeWithoutHttp(): Unit {
        @Assert('pong', pingServer().invoke('ping').asString().value)
    }

    @TestCase
    public func testInvokeUnknownMethodThrows(): Unit {
        try {
            pingServer().invoke('nope')
            @Fail('expected JsonRpcException')
        } catch (e: JsonRpcException) {
            @Assert(-32601, e.code)
        }
    }

    @TestCase
    public func testSetResponseHeaderWithoutHttpIsNoop(): Unit {
        let ctx = JsonRpcContext()
        ctx.setResponseHeader('X-Test', '1')
        @Assert(true, true)
    }

    @TestCase
    public func testDuplicateMethodThrows(): Unit {
        let server = pingServer()
        try {
            server.addMethod(JsonRpcMethodMeta(name: 'ping', handler: {_, _ => JsonString('x')}))
            @Fail('expected JsonRpcException')
        } catch (e: JsonRpcException) {
            @Assert(-32603, e.code)
        }
    }

    @TestCase
    public func testMethodsSorted(): Unit {
        let server = JsonRpcServer.builder()
            .addMethod(JsonRpcMethodMeta(name: 'b', handler: {_, _ => JsonString('b')}))
            .addMethod(JsonRpcMethodMeta(name: 'a', handler: {_, _ => JsonString('a')}))
            .build()
        let methods = server.methods()
        @Assert('a', methods[0].name)
        @Assert('b', methods[1].name)
    }

    static func padded(size: Int64): String {
        let sb = StringBuilder()
        for (_ in 0..size) {
            sb.append('x')
        }
        sb.toString()
    }

    @TestCase
    public func testTopicIndexResolvesAmongManyMethods(): Unit {
        let builder = JsonRpcServer.builder()
        for (i in 0..1000) {
            builder.addMethod(JsonRpcMethodMeta(name: 'ns${i}.m', handler: {_, _ => JsonString('${i}')}))
        }
        let server = builder.build()
        let hit = server.handle(text('{"jsonrpc":"2.0","id":1,"method":"ns500.m"}'),
            ctx: JsonRpcContext(endpoint: '/rpc/ns500', topic: 'ns500')).getOrThrow()
        @Assert('500', hit.asObject()['result'].asString().value)
        let miss = server.handle(text('{"jsonrpc":"2.0","id":1,"method":"nope"}'),
            ctx: JsonRpcContext(endpoint: '/rpc/nope', topic: 'nope')).getOrThrow()
        @Assert(-32004, errorOf(miss)['code'].asInt().toInt64())
    }

    @TestCase
    public func testBodyLimitReadsConfigAtRequestTime(): Unit {
        Config.set([(MVCConfig.MAX_REQUEST_BODY_SIZE, Int64(4 * 1024 * 1024))])
        try {
            // server 先于配置构造：修复前会永久快照 2 MiB
            let server = pingServer()
            let body = '{"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":"' + padded(3 * 1024 * 1024) + '"}}'
            let response = server.handle(text(body), ctx: JsonRpcContext()).getOrThrow()
            @Assert('pong', response.asObject()['result'].asString().value)
        } finally {
            Config.remove(MVCConfig.MAX_REQUEST_BODY_SIZE)
        }
    }

    @TestCase
    public func testExplicitBodyLimitWinsOverConfig(): Unit {
        Config.set([(MVCConfig.MAX_REQUEST_BODY_SIZE, Int64(4 * 1024 * 1024))])
        try {
            let server = JsonRpcServer.builder()
                .maxBodyBytes(1024)
                .addMethod(JsonRpcMethodMeta(name: 'ping', handler: {_, _ => JsonString('pong')}))
                .build()
            let body = '{"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":"' + padded(2048) + '"}}'
            let value = server.handle(text(body), ctx: JsonRpcContext()).getOrThrow()
            let error = value.asObject()['error'].asObject()
            @Assert(-32600, error['code'].asInt().toInt64())
            @Assert(1024, error['data'].asObject()['limit'].asInt().toInt64())
        } finally {
            Config.remove(MVCConfig.MAX_REQUEST_BODY_SIZE)
        }
    }

    @TestCase
    public func testBatchLimitCarriesSizeAndLimit(): Unit {
        let server = JsonRpcServer.builder()
            .maxBatchSize(1)
            .addMethod(JsonRpcMethodMeta(name: 'ping', handler: {_, _ => JsonString('pong')}))
            .build()
        let body = '[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}]'
        let error = errorOf(server.handle(text(body), ctx: JsonRpcContext()).getOrThrow())
        @Assert(-32003, error['code'].asInt().toInt64())
        @Assert(1, error['data'].asObject()['limit'].asInt().toInt64())
        @Assert(2, error['data'].asObject()['size'].asInt().toInt64())
    }

    @TestCase
    public func testInvalidParamsSchemaFailsAtRegistration(): Unit {
        let schema = JsonObject()
        schema.add('type', 'object')
        schema.add('pattern', 1)
        try {
            let _ = JsonRpcMethodMeta(name: 'bad', handler: {_, _ => JsonNull.instance}, paramsSchema: schema)
            @Fail('expected IllegalArgumentException')
        } catch (_: IllegalArgumentException) {
            ()
        }
    }

    @TestCase
    public func testMethodMetaFields(): Unit {
        let schema = JsonObject()
        schema.add('type', 'object')
        let meta = JsonRpcMethodMeta(
            name: 'x.y',
            handler: {_, _ => JsonNull.instance},
            description: 'desc',
            timeout: Duration.second)
        @Assert('x', meta.namespace())
        @Assert('desc', meta.description)
        @Assert(true, meta.timeout.isSome())
    }
}
