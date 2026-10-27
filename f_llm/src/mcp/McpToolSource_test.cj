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
package fountain::f_llm.mcp

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*
import fountain::f_mcp.*

import fountain::f_llm.exception.*
import fountain::f_llm.tool.*

class FakeMcpClient <: McpToolClient {
    FakeMcpClient(private let tools: Array<McpToolDescriptor>, private let error: Bool){}
    var calls: Int64 = 0

    public func listAllTools(): Array<McpToolDescriptor> {
        tools
    }

    public func callTool(name: String, arguments: JsonObject): CallToolResult {
        calls++
        if(error){
            CallToolResult.error('tool blew up')
        }else{
            CallToolResult.text('result of ${name}')
        }
    }
}

func schemaWithNoise(): JsonObject {
    let parameters = JsonValue.fromStr('''
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "path": {"type": "string", "$ref": "#/$defs/path"}
      },
      "required": ["path"]
    }''').asObject()
    parameters
}

func descriptor(name: String): McpToolDescriptor {
    McpToolDescriptor(name, 'read a file', schemaWithNoise(), JsonObject())
}

@Test
public class McpToolSourceTest {

    @TestCase
    func testLoadCleansSchema(): Unit {
        let client = FakeMcpClient([descriptor('read_file')], false)
        let count = McpToolSource('fs', client).load()
        @Expect(count, 1)
        let definition = FunctionMediator.definition('mcp__fs__read_file')
        let parameters = definition.get('function')?.asObject().get('parameters')?.asObject() ?? JsonObject()
        @Expect(parameters.get('type')?.asString().value ?? '', 'object')
        @Expect(parameters.get('additionalProperties').isNone(), true)
        // 顶层 `$schema` 已剥掉；嵌套的 `$ref` 也不在
        var hasDollar = false
        for((key, _) in parameters){
            if(key.size > 0 && key[0] == b'$'){
                hasDollar = true
            }
        }
        @Expect(hasDollar, false)
        let properties = parameters.get('properties')?.asObject().get('path')?.asObject() ?? JsonObject()
        @Expect(properties.get('type')?.asString().value ?? '', 'string')
    }

    @TestCase
    func testCallForwardsToClient(): Unit {
        let client = FakeMcpClient([descriptor('read_file')], false)
        try{
            McpToolSource('fs2', client).load()
        }catch(_: Exception){}
        let result = FunctionMediator.call('mcp__fs2__read_file', JsonObject())
        @Expect(client.calls, 1)
        let text = match(result.result){
            case json: JsonString => json.value
            case _ => ''
        }
        @Expect(text.contains('result of read_file'), true)
    }

    @TestCase
    func testErrorBecomesText(): Unit {
        let client = FakeMcpClient([descriptor('read_file')], true)
        try{
            McpToolSource('fs3', client).load()
        }catch(_: Exception){}
        let result = FunctionMediator.call('mcp__fs3__read_file', JsonObject())
        let text = match(result.result){
            case json: JsonString => json.value
            case _ => ''
        }
        @Expect(text.startsWith('[MCP 错误]'), true)
    }

    @TestCase
    func testLongToolNameFails(): Unit {
        let longName = 'a-very-long-tool-name-that-definitely-exceeds-the-limit-of-sixty-four'
        let client = FakeMcpClient([descriptor(longName)], false)
        var thrown = false
        try{
            McpToolSource('fs4', client).load()
        }catch(_: FunctionCallingException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testDuplicateAliasFails(): Unit {
        let first = FakeMcpClient([descriptor('read_file')], false)
        McpToolSource('dup', first).load()
        let second = FakeMcpClient([descriptor('read_file')], false)
        var thrown = false
        try{
            McpToolSource('dup', second).load()
        }catch(_: FunctionCallingException){
            thrown = true
        }
        @Expect(thrown, true)
    }
}
