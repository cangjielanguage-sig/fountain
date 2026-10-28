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

import fountain::f_data.*
import fountain::f_mcp.*

import fountain::f_llm.tool.*

/**
 * MCP 客户端的最小面：只用到「列工具」和「调工具」，测试可以注入假实现。
 */
public interface McpToolClient {
    func listAllTools(): Array<McpToolDescriptor>
    func callTool(name: String, arguments: JsonObject): CallToolResult
}

/** 把 f_mcp 的 `McpClient` 适配成上面那个最小面（生产用） */
public class McpClientAdapter <: McpToolClient {
    public McpClientAdapter(private let client: McpClient){}

    public func listAllTools(): Array<McpToolDescriptor> {
        client.listAllTools()
    }

    public func callTool(name: String, arguments: JsonObject): CallToolResult {
        client.callTool(name, arguments: arguments)
    }
}

/**
 * 一台 MCP server 的工具来源。
 *
 * 命名规则 `mcp__{alias}__{tool}`（不截断）：
 * - 别名或工具名超 64 字符 ⇒ 注册失败；
 * - 别名重复 ⇒ 工具名撞车 ⇒ 注册失败；
 * - `inputSchema` 里的 `$schema` / `$ref` / `$defs` / `additionalProperties` 一律剥掉——
 *   模型供应商对这些字段的支持参差，留着只会换来 400。
 */
public class McpToolSource {
    private let alias: String
    private let client: McpToolClient

    public init(alias: String, client: McpToolClient) {
        this.alias = alias
        this.client = client
    }

    /** 加载并注册全部工具，返回注册数量 */
    public func load(): Int64 {
        var count = 0
        for(tool in client.listAllTools()){
            let name = ToolName.mcp(alias, tool.name)
            FunctionMediator.register(McpFunctionCalling(name, tool, client))
            count++
        }
        count
    }
}

/** 单个 MCP 工具的函数定义与调用转发 */
public class McpFunctionCalling <: CommonFunctionCalling {
    private let name_: String
    private let tool: McpToolDescriptor
    private let client: McpToolClient

    public init(name: String, tool: McpToolDescriptor, client: McpToolClient) {
        this.name_ = name
        this.tool = tool
        this.client = client
    }

    public prop name: String {
        get() {
            name_
        }
    }

    public prop description: String {
        get() {
            tool.description
        }
    }

    public prop definition: JsonObject {
        get() {
            let definition = JsonObject()
            definition.add('type', 'function')
            let function = JsonObject()
            function.add('name', name_)
            function.add('description', tool.description)
            function.add('parameters', sanitizeSchema(tool.inputSchema))
            definition.add('function', function)
            definition
        }
    }

    public func call(json: JsonObject): FunctionResult {
        let result = client.callTool(tool.name, json)
        let text = textOf(result)
        if(result.isError){
            FunctionResult(event: 'mcp_result', result: '[MCP 错误] ${text}')
        }else{
            FunctionResult(event: 'mcp_result', result: text)
        }
    }
}

/**
 * 递归清洗 JSON Schema。
 *
 * 规则只有两条：
 * 1. 剥掉以 `$` 开头的元信息键（`$schema` / `$ref` / `$defs` …）；`additionalProperties`
 *    **保留**（模型侧能接受，且它表达了 MCP server 的额外字段约束）；
 * 2. `type` 是数组（联合类型）时取第一个非空字符串，例如 `['null','string']` → `string`。
 */
public func sanitizeSchema(value: JsonValue): JsonValue {
    match(value){
        case obj: JsonObject =>
            let cleaned = JsonObject()
            for((key, item) in obj){
                if(key.size > 0 && key[0] == b'$'){
                    continue
                }
                if(key == 'type'){
                    cleaned.add(key, firstTypeOf(item))
                }else{
                    cleaned.add(key, sanitizeSchema(item))
                }
            }
            cleaned
        case array: JsonArray =>
            let list = ArrayList<JsonValue>()
            for(item in array){
                list.add(sanitizeSchema(item))
            }
            JsonArray(list: list)
        case other => other
    }
}

/** 联合类型取第一个非空字符串；不是数组就原样返回 */
func firstTypeOf(value: JsonValue): JsonValue {
    match(value){
        case array: JsonArray =>
            for(item in array){
                match(item){
                    case text: JsonString =>
                        // `null` 也是字符串，但它不是可用类型，跳过
                        if(!text.value.isEmpty() && text.value != 'null'){
                            return text
                        }
                    case _ => ()
                }
            }
            value
        case other => other
    }
}

func textOf(result: CallToolResult): String {
    let builder = StringBuilder()
    for(block in result.content){
        let json = block.toJson()
        if(let Some(text) <- json.get('text')){
            if(builder.size > 0){
                builder.append('\n')
            }
            builder.append(text.asString().value)
        }
    }
    builder.toString()
}
