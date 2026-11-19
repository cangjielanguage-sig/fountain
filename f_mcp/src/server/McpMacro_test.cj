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
import std.reflect.TypeInfo
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_bean.lookup
import fountain::f_bean.BeanFactory
import fountain::f_mcp.base.*
import fountain::f_mcp.macros.*

@DataAssist[props fields]
public class MacroSearchRequest {
    @JsonStringSchema[minLength: 2]
    public var query: String = ''

    public init() {}
}

@DataAssist[props fields]
public class MacroAnswer {
    public var total: Int64 = 0
    public var message: String = ''

    public init() {}

    public init(total: Int64, message: String) {
        this.total = total
        this.message = message
    }
}

@Mcp['macro-server']
public class MacroMcpService {
    public init() {}

    @McpToolMeta[name: 'macro.search', description: 'macro tool']
    public func search(req: MacroSearchRequest): CallToolResult {
        CallToolResult.text('found:${req.query}')
    }

    @McpToolMeta[description: 'fallback name']
    public func fallbackTool(req: MacroSearchRequest): CallToolResult {
        CallToolResult.text(req.query)
    }

    /** 返回 `@DataAssist` 对象：文本块 + `structuredContent`。 */
    @McpToolMeta[name: 'macro.structured']
    public func structured(req: MacroSearchRequest): MacroAnswer {
        MacroAnswer(req.query.size, 'ok:${req.query}')
    }

    /** 返回 `String`：只有文本块。 */
    @McpToolMeta[name: 'macro.plain']
    public func plain(req: MacroSearchRequest): String {
        'plain:${req.query}'
    }

    /** 返回 `Unit`：空内容。 */
    @McpToolMeta[name: 'macro.void']
    public func quiet(req: MacroSearchRequest): Unit {}

    /** 注解配置的限流：每调用方×工具每分钟 2 次。 */
    @McpToolMeta[name: 'macro.limited', perCallerToolRpm: 2]
    public func limited(req: MacroSearchRequest): CallToolResult {
        CallToolResult.text('limited')
    }

    /** 没有被 MCP 注解修饰的公共函数应被忽略。 */
    public func helper(ctx: McpToolContext): String {
        ctx.callerId
    }

    @McpResourceMeta[uri: 'https://example.com/macro-doc', name: 'macro-doc', description: 'macro resource',
        mediaType: 'text/plain']
    public func doc(): ArrayList<ResourceContent> {
        let list = ArrayList<ResourceContent>()
        list.add(ResourceContent('https://example.com/macro-doc', Some('text/plain'), Some('doc body'), None))
        list
    }

    /** 返回 `String` 的资源，自动包成 `text/plain` 内容。 */
    @McpResourceMeta[uri: 'https://example.com/macro-plain', name: 'macro-plain', description: 'plain resource']
    public func plainDoc(): String {
        'plain body'
    }

    @McpPromptMeta[name: 'macro-greet', description: 'macro prompt']
    public func greet(name: String, @McpPromptArg[description: 'user name', required: true] title: String):
        ArrayList<PromptMessage> {
        let list = ArrayList<PromptMessage>()
        list.add(PromptMessage('user', ContentBlock.text('${title} ${name}')))
        list
    }

    /** 返回 `String` 的 prompt，自动包成一条 user 消息；`count` 用于验证入参转换。 */
    @McpPromptMeta[name: 'macro-typed', description: 'typed prompt']
    public func typed(name: String, @McpPromptArg[description: 'count', required: true] count: Int64): String {
        '${name}:${count}'
    }
}

/** 第二个 `@Mcp` 类：验证多次展开时后一次的 build 不会丢掉前一个类的注册项。 */
@Mcp['macro-server']
public class MacroSecondService {
    public init() {}

    @McpToolMeta[name: 'macro.second', description: 'second macro class']
    public func second(req: MacroSearchRequest): CallToolResult {
        CallToolResult.text('second:${req.query}')
    }
}

@Test
class McpMacro_test {
    static let META = '"${McpProtocol.META}":{"${McpProtocol.KEY_PROTOCOL_VERSION}":"${McpProtocol.VERSION}"}'

    static func call(method: String, extra: String): JsonObject {
        let params = if (extra.isEmpty()) {
            '{${META}}'
        } else {
            '{${META},${extra}}'
        }
        let result = McpRegistry.server().jsonRpcServer().invoke(method, params: JsonValue.fromStr(params))
        let obj = JsonObject()
        obj.add('result', result)
        obj
    }

    @TestCase
    public func testServerInfo(): Unit {
        let result = call('server/discover', '')['result'].asObject()
        let info = result['_meta'].asObject()[McpProtocol.KEY_SERVER_INFO].asObject()
        @Assert('macro-server', info['name'].asString().value)
        @Assert('1.0.0', info['version'].asString().value)
    }

    @TestCase
    public func testToolRegistered(): Unit {
        let list = call('tools/list', '')['result'].asObject()
        var found = false
        for (tool in list['tools'].asArray()) {
            let obj = tool.asObject()
            if (obj['name'].asString().value == 'macro.search') {
                found = true
                @Assert('macro tool', obj['description'].asString().value)
                let schema = obj['inputSchema'].asObject()
                @Assert(true, schema['properties'].asObject().contains('query'))
                @Assert(2, schema['properties'].asObject()['query'].asObject()['minLength'].asInt().toInt64())
            }
        }
        @Assert(true, found)

        var fallback = false
        for (tool in list['tools'].asArray()) {
            if (tool.asObject()['name'].asString().value == 'fallbackTool') {
                fallback = true
            }
        }
        @Assert(true, fallback)
    }

    /** 两个 @Mcp 类各自 build 一次，前一个类的工具不能丢。 */
    @TestCase
    public func testMultipleMcpClasses(): Unit {
        var first = false
        var second = false
        for (tool in call('tools/list', '')['result'].asObject()['tools'].asArray()) {
            let name = tool.asObject()['name'].asString().value
            if (name == 'macro.search') {
                first = true
            }
            if (name == 'macro.second') {
                second = true
            }
        }
        @Assert(true, first)
        @Assert(true, second)
    }

    @TestCase
    public func testToolCall(): Unit {
        let result = call('tools/call', '"name":"macro.search","arguments":{"query":"hello"}')['result'].asObject()
        let text = result['content'].asArray()[0].asObject()['text'].asString().value
        @Assert('found:hello', text)
    }

    @TestCase
    public func testToolStructuredResult(): Unit {
        let result = call('tools/call', '"name":"macro.structured","arguments":{"query":"hello"}')['result']
            .asObject()
        let structured = result['structuredContent'].asObject()
        @Assert(5, structured['total'].asInt().toInt64())
        @Assert('ok:hello', structured['message'].asString().value)
        let text = result['content'].asArray()[0].asObject()['text'].asString().value
        @Assert(true, text.contains('"total":5'))
        @Assert(true, text.contains('"message":"ok:hello"'))
    }

    @TestCase
    public func testToolStringAndUnitResult(): Unit {
        let plain = call('tools/call', '"name":"macro.plain","arguments":{"query":"hi"}')['result'].asObject()
        @Assert('plain:hi', plain['content'].asArray()[0].asObject()['text'].asString().value)
        @Assert(false, plain.contains('structuredContent'))

        let quiet = call('tools/call', '"name":"macro.void","arguments":{"query":"hi"}')['result'].asObject()
        @Assert(0, quiet['content'].asArray().size)
    }

    @TestCase
    public func testToolRateLimitFromMeta(): Unit {
        call('tools/call', '"name":"macro.limited","arguments":{"query":"hi"}')
        call('tools/call', '"name":"macro.limited","arguments":{"query":"hi"}')
        var failed = false
        try {
            call('tools/call', '"name":"macro.limited","arguments":{"query":"hi"}')
        } catch (e: McpException) {
            failed = true
            @Assert(McpProtocol.RATE_LIMITED, e.code)
        }
        @Assert(true, failed)
    }

    @TestCase
    public func testResourceStringResult(): Unit {
        let read = call('resources/read', '"uri":"https://example.com/macro-plain"')['result'].asObject()
        let content = read['contents'].asArray()[0].asObject()
        @Assert('https://example.com/macro-plain', content['uri'].asString().value)
        @Assert('plain body', content['text'].asString().value)
        @Assert('text/plain', content['mimeType'].asString().value)
    }

    @TestCase
    public func testPromptStringResultAndArgError(): Unit {
        let got = call('prompts/get', '"name":"macro-typed","arguments":{"name":"Ada","count":3}')['result']
            .asObject()
        @Assert('Ada:3', got['messages'].asArray()[0].asObject()['content'].asObject()['text'].asString().value)

        var failed = false
        try {
            call('prompts/get', '"name":"macro-typed","arguments":{"name":"Ada","count":"abc"}')
        } catch (e: McpException) {
            failed = true
            @Assert(McpProtocol.INVALID_PARAMS, e.code)
        }
        @Assert(true, failed)
    }

    @TestCase
    public func testResourceRegisteredAndRead(): Unit {
        let list = call('resources/list', '')['result'].asObject()
        let resource = list['resources'].asArray()[0].asObject()
        @Assert('https://example.com/macro-doc', resource['uri'].asString().value)
        @Assert('text/plain', resource['mimeType'].asString().value)

        let read = call('resources/read', '"uri":"https://example.com/macro-doc"')['result'].asObject()
        @Assert('doc body', read['contents'].asArray()[0].asObject()['text'].asString().value)
    }

    @TestCase
    public func testPromptRegisteredAndGet(): Unit {
        let list = call('prompts/list', '')['result'].asObject()
        let prompt = list['prompts'].asArray()[0].asObject()
        @Assert('macro-greet', prompt['name'].asString().value)
        let args = prompt['arguments'].asArray()
        @Assert(2, args.size)
        @Assert('name', args[0].asObject()['name'].asString().value)
        @Assert('user name', args[1].asObject()['description'].asString().value)

        let got = call('prompts/get', '"name":"macro-greet","arguments":{"name":"Ada","title":"Dr"}')['result']
            .asObject()
        @Assert('Dr Ada', got['messages'].asArray()[0].asObject()['content'].asObject()['text'].asString().value)
    }

    @TestCase
    public func testArgumentConvertsFromDataDirectly(): Unit {
        let args = JsonObject()
        args.add('query', 'hello')
        let payload = McpConvert.argument<MacroSearchRequest>(args)
        @Assert('hello', payload.query)
    }

    @TestCase
    public func testToolResultSerializesObjectOnce(): Unit {
        let payload = MacroAnswer(1, 'x')
        let result = McpConvert.toolResult(payload)
        @Assert(1, result.content.size)
        let text = result.content[0].toJson()['text'].asString().value
        @Assert(true, text.contains('"x"'))
        @Assert(true, result.structuredContent.isSome())
        @Assert('x', result.structuredContent.getOrThrow().asObject()['message'].asString().value)
    }
}
