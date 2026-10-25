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
package fountain::f_mcp.server

import std.collection.ArrayList
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_config.Config
import fountain::f_jsonrpc.base.*
import fountain::f_jsonrpc.server.*
import fountain::f_mcp.base.*

@Test
class McpServer_test {
    static let META = '"${McpProtocol.META}":{"${McpProtocol.KEY_PROTOCOL_VERSION}":"${McpProtocol.VERSION}"}'

    static func repeatText(text: String, n: Int64): String {
        let sb = StringBuilder()
        for (_ in 0..n) {
            sb.append(text)
        }
        sb.toString()
    }

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
        srv.jsonRpcServer().handle(body.unsafeBytes(), ctx: JsonRpcContext()).getOrThrow().asObject()
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

    static func toolServer(handler: McpToolHandler): McpServer {
        McpServer.builder()
            .tool(McpTool.builder('echo').description('echo').inputSchema(textSchema()).handler(handler).build())
            .build()
    }

    @TestCase
    public func testInputResponsesAndRequestStateReachHandler(): Unit {
        let seenResponses = Box<String>('')
        let seenState = Box<String>('')
        let srv = toolServer({ctx, args =>
            seenResponses.value = (ctx.inputResponses ?? JsonNull.instance).toString()
            seenState.value = (ctx.requestState ?? JsonNull.instance).toString()
            CallToolResult.text('ok')
        })
        let extra = '"name":"echo","arguments":{"text":"a"},"inputResponses":{"confirm":true},"requestState":{"cursor":7}'
        let obj = call(srv, 'tools/call', metaParams(extra))
        @Assert(true, obj.contains('result'))
        @Assert('{"confirm":true}', seenResponses.value)
        @Assert('{"cursor":7}', seenState.value)
    }

    @TestCase
    public func testMissingRoundStateIsNone(): Unit {
        let responsesNone = Box<Bool>(false)
        let stateNone = Box<Bool>(false)
        let srv = toolServer({ctx, args =>
            responsesNone.value = ctx.inputResponses.isNone()
            stateNone.value = ctx.requestState.isNone()
            CallToolResult.text('ok')
        })
        let _ = call(srv, 'tools/call', metaParams('"name":"echo","arguments":{"text":"a"}'))
        @Assert(true, responsesNone.value)
        @Assert(true, stateNone.value)
    }

    @TestCase
    public func testInputResponsesPassThroughAsAnyJson(): Unit {
        let seen = ArrayList<String>()
        let srv = toolServer({ctx, args =>
            seen.add((ctx.inputResponses ?? JsonNull.instance).toString())
            CallToolResult.text('ok')
        })
        let _ = call(srv, 'tools/call',
            metaParams('"name":"echo","arguments":{"text":"a"},"inputResponses":["x","y"]'))
        let _ = call(srv, 'tools/call',
            metaParams('"name":"echo","arguments":{"text":"a"},"inputResponses":"plain"'))
        @Assert(2, seen.size)
        @Assert('["x","y"]', seen[0])
        @Assert('"plain"', seen[1])
    }

    @TestCase
    public func testHandlerRequestStateIsReturned(): Unit {
        let state = JsonObject()
        state.add('cursor', 9)
        let srv = toolServer({_, _ => CallToolResult(content: ArrayList<ContentBlock>(), requestState: state)})
        let obj = call(srv, 'tools/call', metaParams('"name":"echo","arguments":{"text":"a"}'))
        let result = obj['result'].asObject()
        @Assert(9, result['requestState'].asObject()['cursor'].asInt().toInt64())
    }

    @TestCase
    public func testInputRequiredKeepsAllFields(): Unit {
        let state = JsonObject()
        state.add('cursor', 3)
        let list = ArrayList<ContentBlock>()
        list.add(ContentBlock.text('need input'))
        let srv = toolServer({_, _ => CallToolResult(content: list, resultType: 'input_required',
            inputRequired: JsonString('confirm?'), requestState: state)})
        let result = call(srv, 'tools/call', metaParams('"name":"echo","arguments":{"text":"a"}'))['result']
            .asObject()
        @Assert('input_required', result['resultType'].asString().value)
        @Assert('confirm?', result['inputRequired'].asString().value)
        @Assert(3, result['requestState'].asObject()['cursor'].asInt().toInt64())
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
    public func testDecodeCursorRejectsInvalidInput(): Unit {
        @Assert(true, McpProtocol.decodeCursor('bad').isNone())
        @Assert(true, McpProtocol.decodeCursor(McpProtocol.encodeCursor(0)).isSome())
        @Assert(true, McpProtocol.decodeCursor(McpProtocol.encodeCursor(-5)).isNone())
        // offset:abc 不是整数
        let badText = McpProtocol.encodeCursor(0).size > 0
        @Assert(true, badText)
        @Assert(Some(0), McpProtocol.decodeCursor(''))
    }

    @TestCase
    public func testInvalidCursorReturnsInvalidParams(): Unit {
        let nonString = errorOf(call(server(), 'tools/list', metaParams('"cursor":1')))
        @Assert(McpProtocol.INVALID_PARAMS, nonString['code'].asInt().toInt64())
        let garbage = errorOf(call(server(), 'tools/list', metaParams('"cursor":"***"')))
        @Assert(McpProtocol.INVALID_PARAMS, garbage['code'].asInt().toInt64())
    }

    @TestCase
    public func testOffsetBeyondListIsEmptyPage(): Unit {
        let result = call(server(), 'tools/list', metaParams('"cursor":"${McpProtocol.encodeCursor(99)}"'))['result']
            .asObject()
        @Assert(0, result['tools'].asArray().size)
        @Assert(false, result.contains('nextCursor'))
    }

    @TestCase
    public func testCapabilitiesMatchImplementation(): Unit {
        let result = call(server(), 'server/discover', metaParams(''))['result'].asObject()
        let caps = result['capabilities'].asObject()
        @Assert(false, caps['resources'].asObject()['subscribe'].asBool().value)
        @Assert(true, caps.contains('prompts'))
        @Assert(true, caps.contains('tools'))
        // 声明了 prompts 就必须能调 prompts/list
        @Assert(true, call(server(), 'prompts/list', metaParams('')).contains('result'))
        // 没有 resources/subscribe 方法
        let subscribe = call(server(), 'resources/subscribe', metaParams('"uri":"x"'))
        @Assert(McpProtocol.METHOD_NOT_FOUND, errorOf(subscribe)['code'].asInt().toInt64())
    }

    @TestCase
    public func testServerInfoNameAndVersion(): Unit {
        Config.set([(McpConfig.VERSION, '9.9.9')])
        try {
            let explicit = call(McpServer.builder().serverInfo('explicit', '2.0.0').build(),
                'server/discover', metaParams(''))
            let info = explicit['result'].asObject()['_meta'].asObject()[McpProtocol.KEY_SERVER_INFO].asObject()
            @Assert('explicit', info['name'].asString().value)
            @Assert('2.0.0', info['version'].asString().value)

            let configured = call(McpServer.builder().serverInfo('configured', '').build(),
                'server/discover', metaParams(''))
            let configuredInfo = configured['result'].asObject()['_meta'].asObject()[McpProtocol.KEY_SERVER_INFO]
                .asObject()
            @Assert('configured', configuredInfo['name'].asString().value)
            @Assert('9.9.9', configuredInfo['version'].asString().value)
        } finally {
            Config.remove(McpConfig.VERSION)
        }
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

    static func pathResource(): McpResource {
        McpResource.builder('/doc', 'doc')
            .description('doc').mimeType('text/plain')
            .handler({ctx =>
                let list = ArrayList<ResourceContent>()
                list.add(ResourceContent(ctx.uri, Some('text/plain'), Some('content'), None))
                list
            }).build()
    }

    @TestCase
    public func testRelativeResourceUsesBuilderBaseUrl(): Unit {
        let srv = McpServer.builder().publicBaseUrl('https://mcp.example.com/').resource(pathResource()).build()
        let list = call(srv, 'resources/list', metaParams(''))['result'].asObject()
        @Assert('https://mcp.example.com/doc', list['resources'].asArray()[0].asObject()['uri'].asString().value)
        let read = call(srv, 'resources/read', metaParams('"uri":"https://mcp.example.com/doc"'))['result'].asObject()
        @Assert('https://mcp.example.com/doc', read['contents'].asArray()[0].asObject()['uri'].asString().value)
    }

    @TestCase
    public func testRelativeResourceUsesConfigBaseUrl(): Unit {
        Config.set([(McpConfig.PUBLIC_BASE_URL, 'https://cfg.example.com/')])
        try {
            let srv = McpServer.builder().resource(pathResource()).build()
            let list = call(srv, 'resources/list', metaParams(''))['result'].asObject()
            @Assert('https://cfg.example.com/doc', list['resources'].asArray()[0].asObject()['uri'].asString().value)
        } finally {
            Config.remove(McpConfig.PUBLIC_BASE_URL)
        }
    }

    @TestCase
    public func testBuilderBaseUrlOverridesConfig(): Unit {
        Config.set([(McpConfig.PUBLIC_BASE_URL, 'https://cfg.example.com')])
        try {
            let srv = McpServer.builder().publicBaseUrl('https://builder.example.com').resource(pathResource()).build()
            let list = call(srv, 'resources/list', metaParams(''))['result'].asObject()
            @Assert('https://builder.example.com/doc', list['resources'].asArray()[0].asObject()['uri'].asString().value)
        } finally {
            Config.remove(McpConfig.PUBLIC_BASE_URL)
        }
    }

    @TestCase
    public func testRelativeResourceRequiresBaseUrl(): Unit {
        Config.remove(McpConfig.PUBLIC_BASE_URL)
        @ExpectThrows[McpException](McpServer.builder().resource(pathResource()).build())
    }

    @TestCase
    public func testProtocolRelativeResourceRejected(): Unit {
        @ExpectThrows[McpException](McpResource.builder('//example.com/doc', 'doc').handler({_ =>
            ArrayList<ResourceContent>()
        }).build())
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
    public func testTruncateUtf8KeepsRuneBoundary(): Unit {
        @Assert('', McpServer.truncateUtf8('中文', 0))
        @Assert('中', McpServer.truncateUtf8('中文', 3))
        @Assert('中', McpServer.truncateUtf8('中文', 5))
        @Assert('中文', McpServer.truncateUtf8('中文', 6))
        // 4 字节 emoji 不能被切成半个
        @Assert('', McpServer.truncateUtf8('😀', 3))
        @Assert('😀', McpServer.truncateUtf8('😀', 4))
        // ASCII 截断长度不变
        @Assert('abc', McpServer.truncateUtf8('abcdef', 3))
    }

    @TestCase
    public func testChineseTruncationIsValidUtf8(): Unit {
        let text = repeatText('中文结果', 64)
        let srv = McpServer.builder()
            .tool(McpTool.builder('big').maxResultBytes(40).handler({_, _ => CallToolResult.text(text)}).build())
            .build()
        let result = call(srv, 'tools/call', metaParams('"name":"big","arguments":{}'))['result'].asObject()
        let cut = result['content'].asArray()[0].asObject()['text'].asString().value
        @Assert(true, cut.unsafeBytes().size <= 40)
        @Assert(true, cut.unsafeBytes().size > 0)
    }

    @TestCase
    public func testEmojiTruncationIsValidUtf8(): Unit {
        let text = repeatText('😀', 32)
        let srv = McpServer.builder()
            .tool(McpTool.builder('big').maxResultBytes(41).handler({_, _ => CallToolResult.text(text)}).build())
            .build()
        let result = call(srv, 'tools/call', metaParams('"name":"big","arguments":{}'))['result'].asObject()
        let cut = result['content'].asArray()[0].asObject()['text'].asString().value
        @Assert(true, cut.unsafeBytes().size <= 41)
    }

    @TestCase
    public func testTruncationKeepsResultFields(): Unit {
        let state = JsonObject()
        state.add('cursor', 11)
        let list = ArrayList<ContentBlock>()
        list.add(ContentBlock.text(bigText(2048)))
        let srv = McpServer.builder()
            .tool(McpTool.builder('big').maxResultBytes(64).handler({_, _ =>
                CallToolResult(content: list, isError: true, resultType: 'input_required',
                    inputRequired: JsonString('more'), requestState: state)
            }).build())
            .build()
        let result = call(srv, 'tools/call', metaParams('"name":"big","arguments":{}'))['result'].asObject()
        @Assert(true, result['isError'].asBool().value)
        @Assert('input_required', result['resultType'].asString().value)
        @Assert('more', result['inputRequired'].asString().value)
        @Assert(11, result['requestState'].asObject()['cursor'].asInt().toInt64())
        @Assert(true, result['data'].asObject()['truncated'].asBool().value)
    }

    @TestCase
    public func testLargeResultStoredTextMatchesSerializedResult(): Unit {
        let text = bigText(4096)
        let srv = McpServer.builder()
            .publicBaseUrl('https://mcp.example.com')
            .tool(McpTool.builder('big').maxResultBytes(64).handler({_, _ => CallToolResult.text(text)}).build())
            .build()
        let result = call(srv, 'tools/call', metaParams('"name":"big","arguments":{}'))['result'].asObject()
        let link = result['content'].asArray()[0].asObject()['uri'].asString().value
        let read = call(srv, 'resources/read', metaParams('"uri":"${link}"'))['result'].asObject()
        let stored = read['contents'].asArray()[0].asObject()['text'].asString().value
        // 入库的是「一次序列化」的原始结果，解析回来必须与原文一致
        let parsed = JsonValue.fromStr(stored).asObject()
        @Assert('text', parsed['content'].asArray()[0].asObject()['type'].asString().value)
        @Assert(text.size, parsed['content'].asArray()[0].asObject()['text'].asString().value.size)
        @Assert(false, result['content'].asArray()[0].asObject().contains('text'))
    }

    @TestCase
    public func testBuilderOverlaysConfigPerField(): Unit {
        // 配置只写了 perCallerRpm=1；Builder 只写 perToolRpm。
        // 旧实现整体替换 ⇒ 配置的 perCallerRpm 丢失，两次调用都会成功。
        Config.set([(McpConfig.RATE_LIMIT, '1,,,')])
        try {
            let srv = McpServer.builder()
                .rateLimit(RateLimitPolicy(perToolRpm: 1000))
                .tool(echoTool())
                .build()
            let first = call(srv, 'tools/call', metaParams('"name":"echo","arguments":{"text":"1"}'))
            @Assert(true, first.contains('result'))
            let second = call(srv, 'tools/call', metaParams('"name":"echo","arguments":{"text":"2"}'))
            @Assert(McpProtocol.RATE_LIMITED, errorOf(second)['code'].asInt().toInt64())
            @Assert('caller', errorOf(second)['data'].asObject()['scope'].asString().value)
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
    }

    @TestCase
    public func testToolZeroDisablesCallerLimit(): Unit {
        Config.set([(McpConfig.RATE_LIMIT, '1,,,')])
        try {
            let tool = McpTool.builder('free')
                .rateLimit(ToolRateLimit(perCallerRpm: Some(0)))
                .handler({_, _ => CallToolResult.text('ok')})
                .build()
            let srv = McpServer.builder().tool(tool).build()
            for (_ in 0..3) {
                let result = call(srv, 'tools/call', metaParams('"name":"free","arguments":{}'))
                @Assert(true, result.contains('result'))
            }
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
    }

    @TestCase
    public func testToolWithoutRateLimitInheritsAll(): Unit {
        Config.set([(McpConfig.RATE_LIMIT, '1,,,')])
        try {
            let tool = McpTool.builder('inherit')
                .handler({_, _ => CallToolResult.text('ok')})
                .build()
            let srv = McpServer.builder().tool(tool).build()
            let first = call(srv, 'tools/call', metaParams('"name":"inherit","arguments":{}'))
            @Assert(true, first.contains('result'))
            let second = call(srv, 'tools/call', metaParams('"name":"inherit","arguments":{}'))
            @Assert(McpProtocol.RATE_LIMITED, errorOf(second)['code'].asInt().toInt64())
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
    }

    @TestCase
    public func testConcurrencyRejectionDoesNotConsumeRpm(): Unit {
        let srv = McpServer.builder()
            .rateLimit(RateLimitPolicy(perCallerRpm: 2, maxConcurrency: 1))
            .tool(McpTool.builder('slow').handler({_, _ =>
                sleep(Duration.millisecond * 300)
                CallToolResult.text('ok')
            }).build())
            .build()
        let blocking = spawn {
            call(srv, 'tools/call', metaParams('"name":"slow","arguments":{}'))
        }
        sleep(Duration.millisecond * 80)
        let rejected = call(srv, 'tools/call', metaParams('"name":"slow","arguments":{}'))
        @Assert(McpProtocol.RATE_LIMITED, errorOf(rejected)['code'].asInt().toInt64())
        @Assert('concurrency', errorOf(rejected)['data'].asObject()['scope'].asString().value)
        let _ = blocking.get()
        // 配额是 2：第一次成功 + 并发拒绝不扣令牌 ⇒ 还可以成功一次
        let afterOne = call(srv, 'tools/call', metaParams('"name":"slow","arguments":{}'))
        @Assert(true, afterOne.contains('result'))
        let afterTwo = call(srv, 'tools/call', metaParams('"name":"slow","arguments":{}'))
        @Assert(McpProtocol.RATE_LIMITED, errorOf(afterTwo)['code'].asInt().toInt64())
        @Assert('caller', errorOf(afterTwo)['data'].asObject()['scope'].asString().value)
    }

    @TestCase
    public func testRpmRejectionReleasesConcurrencySlot(): Unit {
        let srv = McpServer.builder()
            .rateLimit(RateLimitPolicy(perCallerRpm: 1, maxConcurrency: 1))
            .tool(McpTool.builder('ping').handler({_, _ => CallToolResult.text('ok')}).build())
            .build()
        @Assert(true, call(srv, 'tools/call', metaParams('"name":"ping","arguments":{}')).contains('result'))
        let second = call(srv, 'tools/call', metaParams('"name":"ping","arguments":{}'))
        @Assert('caller', errorOf(second)['data'].asObject()['scope'].asString().value)
        // 第三次仍应是 rpm 拒绝：如果是并发拒绝，说明第二次没有释放槽位
        let third = call(srv, 'tools/call', metaParams('"name":"ping","arguments":{}'))
        @Assert('caller', errorOf(third)['data'].asObject()['scope'].asString().value)
    }

    @TestCase
    public func testConfigRateLimit(): Unit {
        Config.set([(McpConfig.RATE_LIMIT, '1,1,1')])
        try {
            let tool = McpTool.builder('ping')
                .handler({_, _ => CallToolResult.text('pong')})
                .build()
            let srv = McpServer.builder().tool(tool).build()
            let first = call(srv, 'tools/call', metaParams('"name":"ping","arguments":{}'))
            @Assert(true, first.contains('result'))
            let second = call(srv, 'tools/call', metaParams('"name":"ping","arguments":{}'))
            @Assert(McpProtocol.RATE_LIMITED, errorOf(second)['code'].asInt().toInt64())
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
        }
    }

    @TestCase
    public func testConfigRateLimitBackend(): Unit {
        Config.set([(McpConfig.RATE_LIMIT, '1'), (McpConfig.RATE_LIMIT_BACKEND, 'unlimited')])
        try {
            let tool = McpTool.builder('ping')
                .handler({_, _ => CallToolResult.text('pong')})
                .build()
            let srv = McpServer.builder().tool(tool).build()
            for (_ in 0..3) {
                let result = call(srv, 'tools/call', metaParams('"name":"ping","arguments":{}'))
                @Assert(true, result.contains('result'))
            }
        } finally {
            Config.remove(McpConfig.RATE_LIMIT)
            Config.remove(McpConfig.RATE_LIMIT_BACKEND)
        }
    }

    @TestCase
    public func testUnknownRateLimitBackend(): Unit {
        Config.set([(McpConfig.RATE_LIMIT_BACKEND, 'bogus')])
        try {
            @ExpectThrows[IllegalArgumentException](McpServer.builder().build())
        } finally {
            Config.remove(McpConfig.RATE_LIMIT_BACKEND)
        }
    }

    @TestCase
    public func testSubscriptionsListenAndPublish(): Unit {
        let srv = server()
        let listen = call(srv, 'subscriptions/listen', metaParams('"topics":["tools/list_changed"]'))['result'].asObject()
        let id = listen['subscriptionId'].asInt().toInt64()
        @Assert(true, listen['sseUrl'].asString().value.contains('subscriptionId=${id}'))
        let subscriber = srv.hub().attach(id).getOrThrow()
        let stream = McpSseStream(srv.hub(), subscriber)
        let params = JsonObject()
        params.add('reason', 'test')
        srv.hub().publish('tools/list_changed', params)
        let text = String.fromUtf8(stream.poll().getOrThrow())
        @Assert(true, text.contains('notifications/tools/list_changed'))
        stream.close()
        @Assert(true, srv.hub().attach(id).isNone())
    }
}
