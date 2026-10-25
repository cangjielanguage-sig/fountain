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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_mcp.macros.*

@DataAssist[props fields]
public class MacroSearchRequest {
    @JsonStringSchema[minLength: 2]
    public var query: String = ''

    public init() {}
}

@Mcp
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

    @McpPromptMeta[name: 'macro-greet', description: 'macro prompt']
    public func greet(name: String, @McpPromptArg[description: 'user name', required: true] title: String):
        ArrayList<PromptMessage> {
        let list = ArrayList<PromptMessage>()
        list.add(PromptMessage('user', ContentBlock.text('${title} ${name}')))
        list
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

    @TestCase
    public func testToolCall(): Unit {
        let result = call('tools/call', '"name":"macro.search","arguments":{"query":"hello"}')['result'].asObject()
        let text = result['content'].asArray()[0].asObject()['text'].asString().value
        @Assert('found:hello', text)
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
}
