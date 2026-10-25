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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_mcp.base.*

@Test
class McpRegistry_test {
    static let META = '"${McpProtocol.META}":{"${McpProtocol.KEY_PROTOCOL_VERSION}":"${McpProtocol.VERSION}"}'

    static func toolNames(): ArrayList<String> {
        let result = McpRegistry.server().jsonRpcServer().invoke('tools/list', params: JsonValue.fromStr('{${META}}'))
        let names = ArrayList<String>()
        for (tool in result.asObject()['tools'].asArray()) {
            names.add(tool.asObject()['name'].asString().value)
        }
        names
    }

    static func countOf(names: ArrayList<String>, target: String): Int64 {
        var count = 0
        for (name in names) {
            if (name == target) {
                count++
            }
        }
        count
    }

    /** `build()` 可重复调用，且不会把同一注册项累计成多份。 */
    @TestCase
    public func testBuildCanBeCalledRepeatedly(): Unit {
        McpRegistry.configure(
            {b => b.tool(McpTool.builder('registry.repeat').handler({_, _ => CallToolResult.text('ok')}).build())})
        McpRegistry.build()
        McpRegistry.build()
        @Assert(1, countOf(toolNames(), 'registry.repeat'))
    }

    /** build 之后再注册，下一次 build 必须让新 tool 生效。 */
    @TestCase
    public func testLateToolTakesEffectOnNextBuild(): Unit {
        McpRegistry.build()
        @Assert(false, toolNames().contains('registry.late'))
        McpRegistry.configure(
            {b => b.tool(McpTool.builder('registry.late').handler({_, _ => CallToolResult.text('late')}).build())})
        McpRegistry.build()
        @Assert(true, toolNames().contains('registry.late'))
    }
}
