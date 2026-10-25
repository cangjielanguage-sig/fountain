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
 * 只保留运行时真正需要的字段（方法名、handler、描述、超时、参数 schema）；
 * 输入/输出 schema 属于工具层语义，由 `f_mcp.McpTool` 自己持有。
 */
public class JsonRpcMethodMeta {
    public let name: String
    public let handler: JsonRpcHandler
    public let description: String
    public let timeout: ?Duration
    public let paramsSchema: ?JsonObject
    /** 注册期编译好的参数 schema：结构错误当场暴露，正则不再每请求编译。 */
    private let compiledParams: ?CompiledSchema
    /** 命名空间在构造期算好，请求期不再切片方法名。 */
    private let ns: String

    public init(name!: String, handler!: JsonRpcHandler, description!: String = '', timeout!: ?Duration = None,
        paramsSchema!: ?JsonObject = None) {
        this.name = name
        this.handler = handler
        this.description = description
        this.timeout = timeout
        this.paramsSchema = paramsSchema
        this.compiledParams = match (paramsSchema) {
            case Some(schema) => Some(CompiledSchema.compile(schema))
            case _ => None<CompiledSchema>
        }
        this.ns = JsonRpcMethodMeta.namespaceOf(name)
    }

    func compiledSchema(): ?CompiledSchema {
        compiledParams
    }

    /** 方法名的命名空间：第一个 `.` 之前的部分；不含 `.` 时为空串。 */
    public func namespace(): String {
        ns
    }

    private static func namespaceOf(name: String): String {
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
