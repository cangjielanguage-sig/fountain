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
package fountain::f_mcp

import std.collection.ArrayList
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_jsonrpc.*

@Test
class McpServer_test {
    static let META = '"${McpProtocol.META}":{"${McpProtocol.KEY_PROTOCOL_VERSION}":"${McpProtocol.VERSION}"}'

    static func bigText(size: Int64): String {
        var text = ''
        for (_ in 0..size) {
            text += 'x'
        }
        text
    }

    static func textSchema(): JsonObject {
        let schema = JsonObject()
        schema.add('type', 'object')
        let props = JsonObject()
        let text = JsonObject()
        text.add('type', 'string')
        props.add('text', text)
        schema.add('properties', props)
        let required = JsonArray()
        required.add('text')
        schema.add('required', required)
        schema
    }

    static func echoTool(): McpTool {
        McpTool.builder('echo').description('echo text').inputSchema(textSchema())
            .handler({_, args =>
                let text = args.asObject()['text'].asString().value
                CallToolResult.text(text)
            }).build()
    }

    static func server(): McpServer {
        let resource = McpResource.builder('https://example.com/a.txt', 'a')
            .description('a resource').mimeType('text/plain')
            .handler({ctx =>
                let list = ArrayList<ResourceContent>()
                list.add(ResourceContent(ctx.uri, Some('text/plain'), Some('hello'), None))
                list
            }).build()
        let prompt = McpPrompt.builder('greet').description('greeting')
            .argument('name', required: true)
            .handler({args =>
                let list = ArrayList<PromptMessage>()
                list.add(PromptMessage('user',
                    ContentBlock.text('hi ' + args['name'].asString().value)))
                list
            }).build()
        McpServer.builder().tool(echoTool()).resource(resource).prompt(prompt).build()
    }

    static func call(srv: McpServer, method: String, params: String): JsonObject {
        let body = '{"jsonrpc":"2.0","id":1,"method":"${method}","params":${params}}'
        let bytes = srv.jsonRpcServer().handle(body.unsafeBytes(), ctx: JsonRpcContext()).getOrThrow()
        JsonValue.fromBytes(bytes).asObject()
    }

    static func metaParams(extra: String): String {
        if (extra.isEmpty()) {
            '{${META}}'
        } else {
            '{${META},${extra}}'
        }
    }

    static func errorOf(obj: JsonObject): JsonObject {
        obj['error'].asObject()
    }

    @TestCase
    public func testDiscover(): Unit {
        let obj = call(server(), 'server/discover', metaParams(''))
        let result = obj['result'].asObject()
        @Assert('complete', result['resultType'].asString().value)
        @Assert(1, result['supportedVersions'].asArray().size)
        let caps = result['capabilities'].asObject()
        @Assert(true, caps.contains('tools'))
        @Assert(true, caps.contains('resources'))
        @Assert(true, caps.contains('prompts'))
        @Assert(true, result['_meta'].asObject().contains(McpProtocol.KEY_SERVER_INFO))
    }

    @TestCase
    public func testUnsupportedVersion(): Unit {
        let params = '{"_meta":{"${McpProtocol.KEY_PROTOCOL_VERSION}":"1900-01-01"}}'
        let error = errorOf(call(server(), 'tools/list', params))
        @Assert(McpProtocol.UNSUPPORTED_VERSION, error['code'].asInt().toInt64())
        @Assert(1, error['data'].asObject()['supported'].asArray().size)
    }

    @TestCase
    public func testMissingMeta(): Unit {
        let error = errorOf(call(server(), 'tools/list', '{}'))
        @Assert(McpProtocol.INVALID_PARAMS, error['code'].asInt().toInt64())
    }

    @TestCase
    public func testLegacyInitialize(): Unit {
        let error = errorOf(call(server(), 'initialize', metaParams('')))
        @Assert(-32601, error['code'].asInt().toInt64())
        @Assert('initialize', error['data'].asObject()['legacyMethod'].asString().value)
    }

    @TestCase
    public func testToolsListPagination(): Unit {
        let srv = McpServer.builder()
            .pageSize(1)
            .tool(McpTool.builder('b').handler({_, _ => CallToolResult.text('b')}).build())
            .tool(McpTool.builder('a').handler({_, _ => CallToolResult.text('a')}).build())
            .build()
        let first = call(srv, 'tools/list', metaParams(''))['result'].asObject()
        @Assert('a', first['tools'].asArray()[0].asObject()['name'].asString().value)
        let cursor = first['nextCursor'].asString().value
        let second = call(srv, 'tools/list', metaParams('"cursor":"${cursor}"'))['result'].asObject()
        @Assert('b', second['tools'].asArray()[0].asObject()['name'].asString().value)
        @Assert(false, second.contains('nextCursor'))
    }

    @TestCase
    public func testToolsCall(): Unit {
        let obj = call(server(), 'tools/call', metaParams('"name":"echo","arguments":{"text":"hi"}'))
        let result = obj['result'].asObject()
        @Assert('hi', result['content'].asArray()[0].asObject()['text'].asString().value)
        @Assert(false, result['isError'].asBool().value)
    }

    @TestCase
    public func testToolsCallInvalidParams(): Unit {
        let error = errorOf(call(server(), 'tools/call', metaParams('"name":"echo","arguments":{}')))
        @Assert(McpProtocol.INVALID_PARAMS, error['code'].asInt().toInt64())
    }

    @TestCase
    public func testToolsCallIsError(): Unit {
        let srv = McpServer.builder()
            .tool(McpTool.builder('fail').handler({_, _ => CallToolResult.error('boom')}).build())
            .build()
        let result = call(srv, 'tools/call', metaParams('"name":"fail","arguments":{}'))['result'].asObject()
        @Assert(true, result['isError'].asBool().value)
    }

    @TestCase
    public func testStructuredContentDualWrite(): Unit {
        let srv = McpServer.builder()
            .tool(McpTool.builder('obj').handler({_, _ =>
                let structured = JsonObject()
                structured.add('x', 1)
                CallToolResult(content: ArrayList<ContentBlock>(), structuredContent: structured)
            }).build())
            .build()
        let result = call(srv, 'tools/call', metaParams('"name":"obj","arguments":{}'))['result'].asObject()
        @Assert(true, result.contains('structuredContent'))
        @Assert(true, result['content'].asArray().size > 0)
        @Assert('text', result['content'].asArray()[0].asObject()['type'].asString().value)
    }

    @TestCase
    public func testResourcesListAndRead(): Unit {
        let srv = server()
        let list = call(srv, 'resources/list', metaParams(''))['result'].asObject()
        @Assert('https://example.com/a.txt',
            list['resources'].asArray()[0].asObject()['uri'].asString().value)
        let read = call(srv, 'resources/read',
            metaParams('"uri":"https://example.com/a.txt"'))['result'].asObject()
        @Assert('hello', read['contents'].asArray()[0].asObject()['text'].asString().value)
    }

    @TestCase
    public func testResourceNotFound(): Unit {
        let error = errorOf(call(server(), 'resources/read', metaParams('"uri":"https://example.com/none"')))
        @Assert(McpProtocol.RESOURCE_NOT_FOUND, error['code'].asInt().toInt64())
    }

    @TestCase
    public func testResourceUriValidation(): Unit {
        try {
            McpResource.builder('file:///etc/passwd', 'x').handler({_ =>
                ArrayList<ResourceContent>()
            }).build()
            @Fail('expected McpException')
        } catch (e: McpException) {
            @Assert(McpProtocol.INVALID_PARAMS, e.code)
        }
    }

    @TestCase
    public func testPromptsListAndGet(): Unit {
        let srv = server()
        let list = call(srv, 'prompts/list', metaParams(''))['result'].asObject()
        @Assert('greet', list['prompts'].asArray()[0].asObject()['name'].asString().value)
        let got = call(srv, 'prompts/get',
            metaParams('"name":"greet","arguments":{"name":"mcp"}'))['result'].asObject()
        @Assert('hi mcp', got['messages'].asArray()[0].asObject()['content']
            .asObject()['text'].asString().value)
    }

    @TestCase
    public func testPromptMissingRequiredArgument(): Unit {
        let error = errorOf(call(server(), 'prompts/get', metaParams('"name":"greet","arguments":{}')))
        @Assert(McpProtocol.INVALID_PARAMS, error['code'].asInt().toInt64())
    }

    @TestCase
    public func testRateLimitCaller(): Unit {
        let srv = McpServer.builder()
            .rateLimit(RateLimitPolicy(perCallerRpm: 2))
            .tool(echoTool())
            .build()
        @Assert(true, call(srv, 'tools/call', metaParams('"name":"echo","arguments":{"text":"1"}'))
            .contains('result'))
        @Assert(true, call(srv, 'tools/call', metaParams('"name":"echo","arguments":{"text":"1"}'))
            .contains('result'))
        let error = errorOf(call(srv, 'tools/call', metaParams('"name":"echo","arguments":{"text":"1"}')))
        @Assert(McpProtocol.RATE_LIMITED, error['code'].asInt().toInt64())
        @Assert('caller', error['data'].asObject()['scope'].asString().value)
    }

    @TestCase
    public func testLargeResultBecomesResourceLink(): Unit {
        let srv = McpServer.builder()
            .publicBaseUrl('https://mcp.example.com')
            .tool(McpTool.builder('big').maxResultBytes(64).handler({_, _ =>
                CallToolResult.text(bigText(1024))
            }).build())
            .build()
        let result = call(srv, 'tools/call', metaParams('"name":"big","arguments":{}'))['result'].asObject()
        let block = result['content'].asArray()[0].asObject()
        @Assert('resource_link', block['type'].asString().value)
        let link = block['uri'].asString().value
        @Assert(true, link.startsWith('https://mcp.example.com${McpProtocol.TOOL_RESULT_PREFIX}'))
        let read = call(srv, 'resources/read', metaParams('"uri":"${link}"'))['result'].asObject()
        @Assert(true, read['contents'].asArray()[0].asObject()['text'].asString().value.size >= 1024)
    }

    @TestCase
    public func testLargeResultTruncatedWithoutBaseUrl(): Unit {
        let srv = McpServer.builder()
            .tool(McpTool.builder('big').maxResultBytes(64).handler({_, _ =>
                CallToolResult.text(bigText(1024))
            }).build())
            .build()
        let result = call(srv, 'tools/call', metaParams('"name":"big","arguments":{}'))['result'].asObject()
        @Assert(true, result['data'].asObject()['truncated'].asBool().value)
    }

    @TestCase
    public func testSubscriptionsListenAndPublish(): Unit {
        let srv = server()
        let listen = call(srv, 'subscriptions/listen', metaParams('"topics":["tools/list_changed"]'))['result'].asObject()
        @Assert(true, listen.contains('subscriptionId'))
        let params = JsonObject()
        params.add('reason', 'test')
        srv.hub().publish('tools/list_changed', params)
        // 订阅者由 hub 持有；这里直接再订阅一个用于断言
        let topics = ArrayList<String>()
        topics.add('tools/list_changed')
        let subscriber = srv.hub().subscribe(topics)
        srv.hub().publish('tools/list_changed', params)
        @Assert(1, subscriber.drain().size)
    }
}
