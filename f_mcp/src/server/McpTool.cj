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

import std.fs.File
import fountain::f_data.*
import fountain::f_mcp.base.*

/** 工具执行上下文。 */
public class McpToolContext {
    public let callerId: String
    public let requestId: ?JsonValue
    /** 上一轮 `input_required` 的响应，原样透传（服务端不解释）。 */
    public let inputResponses: ?JsonValue
    /** 上一轮返回的 `requestState`，原样透传（服务端不解释）。 */
    public let requestState: ?JsonValue

    public init(callerId: String, requestId!: ?JsonValue = None, inputResponses!: ?JsonValue = None,
        requestState!: ?JsonValue = None) {
        this.callerId = callerId
        this.requestId = requestId
        this.inputResponses = inputResponses
        this.requestState = requestState
    }
}

public type McpToolHandler = (McpToolContext, JsonValue) -> CallToolResult

/** 一个 MCP 工具。 */
public class McpTool {
    public let name: String
    public let description: String
    public let inputSchema: JsonObject
    public let handler: McpToolHandler
    public let rateLimit: ?ToolRateLimit
    public let maxResultBytes: ?Int64
    /** `listTools` 条目 JSON 的构建期缓存（请求期只做切片）。 */
    var listJson: ?JsonObject = None

    init(name!: String, description!: String, inputSchema!: JsonObject, handler!: McpToolHandler,
        rateLimit!: ?ToolRateLimit = None, maxResultBytes!: ?Int64 = None) {
        this.name = name
        this.description = description
        this.inputSchema = inputSchema
        this.handler = handler
        this.rateLimit = rateLimit
        this.maxResultBytes = maxResultBytes
    }

    public static func builder(name: String): McpToolBuilder {
        McpToolBuilder(name)
    }

    /** 用 `@DataAssist` 对象的字段生成 `inputSchema`。 */
    public static func of<T>(name: String): McpToolBuilder where T <: ObjectData<T> {
        McpToolBuilder(name).inputSchema(JsonObject.toJsonSchema<T>())
    }
}

public class McpToolBuilder {
    private let name: String
    private var description_ = ''
    private var inputSchema_: JsonObject = emptyObjectSchema()
    private var handler_: ?McpToolHandler = None
    private var rateLimit_: ?ToolRateLimit = None
    private var maxResultBytes_: ?Int64 = None

    init(name: String) {
        this.name = name
    }

    public func description(text: String): McpToolBuilder {
        description_ = text
        this
    }

    public func inputSchema(schema: JsonObject): McpToolBuilder {
        inputSchema_ = schema
        this
    }

    public func inputSchemaFromFile(path: String): McpToolBuilder {
        let text = String.fromUtf8(File.readFrom(path))
        match (JsonValue.fromStr(text)) {
            case obj: JsonObject => inputSchema_ = obj
            case _ => throw McpException(McpProtocol.INTERNAL_ERROR,
                "tool '${name}' inputSchema file '${path}' is not a JSON object")
        }
        this
    }

    public func handler(handler: McpToolHandler): McpToolBuilder {
        handler_ = Some(handler)
        this
    }

    public func rateLimit(policy: ToolRateLimit): McpToolBuilder {
        rateLimit_ = Some(policy)
        this
    }

    public func maxResultBytes(bytes: Int64): McpToolBuilder {
        maxResultBytes_ = Some(bytes)
        this
    }

    public func build(): McpTool {
        if (!McpProtocol.isToolName(name)) {
            throw McpException(McpProtocol.INTERNAL_ERROR,
                "invalid tool name '${name}': 1~128 chars of A-Z a-z 0-9 _ - .")
        }
        checkSchema(inputSchema_, '')
        match (handler_) {
            case Some(h) => McpTool(name: name, description: description_, inputSchema: inputSchema_, handler: h,
                rateLimit: rateLimit_, maxResultBytes: maxResultBytes_)
            case _ => throw McpException(McpProtocol.INTERNAL_ERROR, "tool '${name}' has no handler")
        }
    }

    private static func emptyObjectSchema(): JsonObject {
        let schema = JsonObject()
        schema.add('type', 'object')
        schema.add('additionalProperties', false)
        schema
    }

    /** `$ref` / `$defs` 一律在构建期拒绝（设计 5.3）。 */
    private static func checkSchema(value: JsonValue, path: String): Unit {
        match (value) {
            case obj: JsonObject =>
                if (obj.contains('$ref')) {
                    throw McpException(McpProtocol.INTERNAL_ERROR, "inputSchema contains unsupported $ref (fail-closed)")
                }
                if (obj.contains('$defs')) {
                    throw McpException(McpProtocol.INTERNAL_ERROR,
                        "inputSchema contains unsupported $defs (fail-closed)")
                }
                for ((key, child) in obj) {
                    checkSchema(child, '${path}/${key}')
                }
            case array: JsonArray =>
                var i = 0
                for (child in array) {
                    checkSchema(child, '${path}/${i}')
                    i++
                }
            case _ => ()
        }
    }
}
