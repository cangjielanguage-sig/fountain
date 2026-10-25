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
import fountain::f_data.*
import fountain::f_mcp.base.*

public type McpPromptHandler = (JsonObject) -> ArrayList<PromptMessage>

public class McpPrompt {
    /** `listPrompts` 条目 JSON 的构建期缓存。 */
    var listJson: ?JsonObject = None

    public let name: String
    public let description: String
    public let arguments: ArrayList<PromptArgument>
    public let handler: McpPromptHandler

    init(name!: String, description!: String, arguments!: ArrayList<PromptArgument>, handler!: McpPromptHandler) {
        this.name = name
        this.description = description
        this.arguments = arguments
        this.handler = handler
    }

    public static func builder(name: String): McpPromptBuilder {
        McpPromptBuilder(name)
    }
}

public class McpPromptBuilder {
    private let name: String
    private var description_ = ''
    private let arguments_ = ArrayList<PromptArgument>()
    private var handler_: ?McpPromptHandler = None

    init(name: String) {
        this.name = name
    }

    public func description(text: String): McpPromptBuilder {
        description_ = text
        this
    }

    public func argument(name: String, description!: String = '', required!: Bool = false): McpPromptBuilder {
        arguments_.add(PromptArgument(name, description: description, required: required))
        this
    }

    public func handler(handler: McpPromptHandler): McpPromptBuilder {
        handler_ = Some(handler)
        this
    }

    public func build(): McpPrompt {
        if (!McpProtocol.isToolName(name)) {
            throw McpException(McpProtocol.INTERNAL_ERROR,
                "invalid prompt name '${name}': 1~128 chars of A-Z a-z 0-9 _ - .")
        }
        match (handler_) {
            case Some(h) => McpPrompt(name: name, description: description_, arguments: arguments_, handler: h)
            case _ => throw McpException(McpProtocol.INTERNAL_ERROR, "prompt '${name}' has no handler")
        }
    }
}
