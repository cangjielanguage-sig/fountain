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

import fountain::f_data.*

/** 方法处理函数：入参是 `params`（可能为 None），返回 `result`。 */
public type JsonRpcHandler = (JsonRpcContext, ?JsonValue) -> JsonValue

/**
 * 方法元数据。
 *
 * `description` / `inputSchema` / `outputSchema` 在纯 JSON-RPC 场景用不上，
 * 但 MCP 的 `tools/list` 直接取它们，避免上层再维护第二张表。
 */
public class JsonRpcMethodMeta {
    public let name: String
    public let handler: JsonRpcHandler
    public let description: String
    public let inputSchema: ?JsonValue
    public let outputSchema: ?JsonValue
    public let timeout: ?Duration
    public let paramsSchema: ?JsonObject

    public init(name!: String, handler!: JsonRpcHandler, description!: String = '', inputSchema!: ?JsonValue = None,
        outputSchema!: ?JsonValue = None, timeout!: ?Duration = None, paramsSchema!: ?JsonObject = None) {
        this.name = name
        this.handler = handler
        this.description = description
        this.inputSchema = inputSchema
        this.outputSchema = outputSchema
        this.timeout = timeout
        this.paramsSchema = paramsSchema
    }

    /** 方法名的命名空间：第一个 `.` 之前的部分；不含 `.` 时为空串。 */
    public func namespace(): String {
        match (name.indexOf('.')) {
            case Some(i) =>
                if (i > 0) {
                    name[0..i]
                } else {
                    ''
                }
            case _ => ''
        }
    }
}
