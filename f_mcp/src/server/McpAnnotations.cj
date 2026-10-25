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

/**
 * 把一个公共实例函数注册为 MCP tool。
 *
 * `name` / `description` 为空时分别回退到函数名与空描述；
 * `inputSchema` 由函数唯一参数的类型生成（参数应为 `@DataAssist[props fields]` 类）。
 * 限流字段：`-1`（默认）沿用服务级配置，`0` 表示不限制，`>0` 表示限额。
 */
@Annotation[target: [MemberFunction]]
public class McpToolMeta {
    public const McpToolMeta(public let name!: String = '', public let description!: String = '',
        public let perCallerRpm!: Int64 = -1, public let perCallerToolRpm!: Int64 = -1,
        public let perToolRpm!: Int64 = -1, public let maxConcurrency!: Int64 = -1,
        public let perCallerConcurrency!: Int64 = -1) {}
}

/**
 * 把一个公共实例函数注册为 MCP resource。
 *
 * `uri` 为空时注册失败；`name` 为空时回退到函数名。
 * `mediaType` 对应 `McpResource.mimeType`，为空表示不声明。
 */
@Annotation[target: [MemberFunction]]
public class McpResourceMeta {
    public const McpResourceMeta(public let uri!: String = '', public let name!: String = '',
        public let description!: String = '', public let mediaType!: String = '') {}
}

/**
 * 把一个公共实例函数注册为 MCP prompt。
 *
 * `name` 为空时回退到函数名；函数的每个参数对应一个 `PromptArgument`。
 */
@Annotation[target: [MemberFunction]]
public class McpPromptMeta {
    public const McpPromptMeta(public let name!: String = '', public let description!: String = '') {}
}

/** 描述 prompt 函数参数的 `PromptArgument` 元数据。 */
@Annotation[target: [Parameter]]
public class McpPromptArg {
    public const McpPromptArg(public let description!: String = '', public let required!: Bool = true) {}
}
