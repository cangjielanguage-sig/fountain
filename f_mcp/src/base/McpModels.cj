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
package fountain::f_mcp.base

import std.collection.ArrayList
import fountain::f_data.*

/**
 * 服务端 / 客户端共用的强类型模型。
 *
 * 全部提供 `fromJson` / `toJson`；除 `McpCapabilities` 外，未知字段按模型定义丢弃
 * （协议允许客户端忽略未知字段）。
 */

/** `_meta.io.modelcontextprotocol/serverInfo`。 */
public class McpServerInfo {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        this.name = name
        this.version = version
    }

    public static func fromJson(obj: JsonObject): McpServerInfo {
        McpServerInfo(stringOf(obj, 'name'), stringOf(obj, 'version'))
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('name', name)
        obj.add('version', version)
        obj
    }
}

/**
 * `server/discover` 的能力声明。
 *
 * `raw` 持有服务端原文：`toJson()` 原样返回，因此后续版本新增的能力字段不会丢。
 */
public class McpCapabilities {
    public let raw: JsonObject

    public init(raw!: JsonObject = JsonObject()) {
        this.raw = raw
    }

    public static func fromJson(obj: JsonObject): McpCapabilities {
        McpCapabilities(raw: obj)
    }

    public func toJson(): JsonObject {
        raw
    }

    public prop toolsListChanged: Bool {
        get() {
            nestedBool(raw, 'tools', 'listChanged')
        }
    }

    public prop resourcesSubscribe: Bool {
        get() {
            nestedBool(raw, 'resources', 'subscribe')
        }
    }

    public prop resourcesListChanged: Bool {
        get() {
            nestedBool(raw, 'resources', 'listChanged')
        }
    }

    public prop promptsListChanged: Bool {
        get() {
            nestedBool(raw, 'prompts', 'listChanged')
        }
    }
}

/** `server/discover` 的结果。 */
public class DiscoverResult {
    public let supportedVersions: Array<String>
    public let capabilities: McpCapabilities
    public let serverInfo: ?McpServerInfo
    public let raw: JsonObject

    public init(supportedVersions: Array<String>, capabilities: McpCapabilities, serverInfo: ?McpServerInfo,
        raw: JsonObject) {
        this.supportedVersions = supportedVersions
        this.capabilities = capabilities
        this.serverInfo = serverInfo
        this.raw = raw
    }

    public static func fromJson(obj: JsonObject): DiscoverResult {
        let versions = ArrayList<String>()
        match (obj.get('supportedVersions')) {
            case Some(array: JsonArray) => for (item in array) {
                if (item is JsonString) {
                    versions.add(item.asString().value)
                }
            }
            case _ => ()
        }
        let capabilities = match (objectOf(obj, 'capabilities')) {
            case Some(caps) => McpCapabilities.fromJson(caps)
            case _ => McpCapabilities()
        }
        let info = match (objectOf(obj, McpProtocol.META)) {
            case Some(meta) => match (objectOf(meta, McpProtocol.KEY_SERVER_INFO)) {
                case Some(value) => Some(McpServerInfo.fromJson(value))
                case _ => None<McpServerInfo>
            }
            case _ => None<McpServerInfo>
        }
        DiscoverResult(versions.toArray(), capabilities, info, obj)
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        let versions = JsonArray()
        for (version in supportedVersions) {
            versions.add(version)
        }
        obj.add('supportedVersions', versions)
        obj.add('capabilities', capabilities.toJson())
        match (serverInfo) {
            case Some(info) =>
                let meta = JsonObject()
                meta.add(McpProtocol.KEY_SERVER_INFO, info.toJson())
                obj.add(McpProtocol.META, meta)
            case _ => ()
        }
        obj
    }
}

/** `prompts/list` 条目里的一个参数。 */
public class PromptArgument {
    public let name: String
    public let description: String
    public let required: Bool

    public init(name: String, description!: String = '', required!: Bool = false) {
        this.name = name
        this.description = description
        this.required = required
    }

    public static func fromJson(obj: JsonObject): PromptArgument {
        PromptArgument(stringOf(obj, 'name'), description: stringOf(obj, 'description'),
            required: boolOf(obj, 'required'))
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('name', name)
        if (!description.isEmpty()) {
            obj.add('description', description)
        }
        obj.add('required', required)
        obj
    }
}

/** `tools/list` 的一个条目。`raw` 保留服务端原文，便于读取未来新增字段。 */
public class McpToolDescriptor {
    public let name: String
    public let description: String
    public let inputSchema: JsonObject
    public let raw: JsonObject

    public init(name: String, description: String, inputSchema: JsonObject, raw: JsonObject) {
        this.name = name
        this.description = description
        this.inputSchema = inputSchema
        this.raw = raw
    }

    public static func fromJson(obj: JsonObject): McpToolDescriptor {
        let schema = objectOf(obj, 'inputSchema') ?? JsonObject()
        McpToolDescriptor(stringOf(obj, 'name'), stringOf(obj, 'description'), schema, obj)
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('name', name)
        obj.add('description', description)
        obj.add('inputSchema', inputSchema)
        obj
    }
}

/** `resources/list` 的一个条目。 */
public class ResourceDescriptor {
    public let uri: String
    public let name: String
    public let description: String
    public let mimeType: ?String

    public init(uri: String, name: String, description: String, mimeType: ?String) {
        this.uri = uri
        this.name = name
        this.description = description
        this.mimeType = mimeType
    }

    public static func fromJson(obj: JsonObject): ResourceDescriptor {
        ResourceDescriptor(stringOf(obj, 'uri'), stringOf(obj, 'name'), stringOf(obj, 'description'),
            optionalStringOf(obj, 'mimeType'))
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('uri', uri)
        obj.add('name', name)
        if (!description.isEmpty()) {
            obj.add('description', description)
        }
        match (mimeType) {
            case Some(value) => obj.add('mimeType', value)
            case _ => ()
        }
        obj
    }
}

/** `prompts/list` 的一个条目。 */
public class PromptDescriptor {
    public let name: String
    public let description: String
    public let arguments: Array<PromptArgument>

    public init(name: String, description: String, arguments: Array<PromptArgument>) {
        this.name = name
        this.description = description
        this.arguments = arguments
    }

    public static func fromJson(obj: JsonObject): PromptDescriptor {
        let args = ArrayList<PromptArgument>()
        match (obj.get('arguments')) {
            case Some(array: JsonArray) => for (item in array) {
                if (let arg: JsonObject <- item) {
                    args.add(PromptArgument.fromJson(arg))
                }
            }
            case _ => ()
        }
        PromptDescriptor(stringOf(obj, 'name'), stringOf(obj, 'description'), args.toArray())
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('name', name)
        obj.add('description', description)
        let args = JsonArray()
        for (arg in arguments) {
            args.add(arg.toJson())
        }
        obj.add('arguments', args)
        obj
    }
}

/** `tools/list` 的一页。 */
public class ToolPage {
    public let tools: Array<McpToolDescriptor>
    public let nextCursor: ?String

    public init(tools: Array<McpToolDescriptor>, nextCursor: ?String) {
        this.tools = tools
        this.nextCursor = nextCursor
    }

    public static func fromJson(obj: JsonObject): ToolPage {
        let tools = ArrayList<McpToolDescriptor>()
        match (obj.get('tools')) {
            case Some(array: JsonArray) => for (item in array) {
                if (let value: JsonObject <- item) {
                    tools.add(McpToolDescriptor.fromJson(value))
                }
            }
            case _ => ()
        }
        ToolPage(tools.toArray(), optionalStringOf(obj, 'nextCursor'))
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        let items = JsonArray()
        for (tool in tools) {
            items.add(tool.toJson())
        }
        obj.add('tools', items)
        match (nextCursor) {
            case Some(value) => obj.add('nextCursor', value)
            case _ => ()
        }
        obj
    }
}

/** `resources/list` 的一页。 */
public class ResourcePage {
    public let resources: Array<ResourceDescriptor>
    public let nextCursor: ?String

    public init(resources: Array<ResourceDescriptor>, nextCursor: ?String) {
        this.resources = resources
        this.nextCursor = nextCursor
    }

    public static func fromJson(obj: JsonObject): ResourcePage {
        let resources = ArrayList<ResourceDescriptor>()
        match (obj.get('resources')) {
            case Some(array: JsonArray) => for (item in array) {
                if (let value: JsonObject <- item) {
                    resources.add(ResourceDescriptor.fromJson(value))
                }
            }
            case _ => ()
        }
        ResourcePage(resources.toArray(), optionalStringOf(obj, 'nextCursor'))
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        let items = JsonArray()
        for (resource in resources) {
            items.add(resource.toJson())
        }
        obj.add('resources', items)
        match (nextCursor) {
            case Some(value) => obj.add('nextCursor', value)
            case _ => ()
        }
        obj
    }
}

/** `prompts/list` 的一页。 */
public class PromptPage {
    public let prompts: Array<PromptDescriptor>
    public let nextCursor: ?String

    public init(prompts: Array<PromptDescriptor>, nextCursor: ?String) {
        this.prompts = prompts
        this.nextCursor = nextCursor
    }

    public static func fromJson(obj: JsonObject): PromptPage {
        let prompts = ArrayList<PromptDescriptor>()
        match (obj.get('prompts')) {
            case Some(array: JsonArray) => for (item in array) {
                if (let value: JsonObject <- item) {
                    prompts.add(PromptDescriptor.fromJson(value))
                }
            }
            case _ => ()
        }
        PromptPage(prompts.toArray(), optionalStringOf(obj, 'nextCursor'))
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        let items = JsonArray()
        for (prompt in prompts) {
            items.add(prompt.toJson())
        }
        obj.add('prompts', items)
        match (nextCursor) {
            case Some(value) => obj.add('nextCursor', value)
            case _ => ()
        }
        obj
    }
}

/** `resources/read` 的结果。 */
public class ReadResourceResult {
    public let contents: Array<ResourceContent>

    public init(contents: Array<ResourceContent>) {
        this.contents = contents
    }

    public static func fromJson(obj: JsonObject): ReadResourceResult {
        let contents = ArrayList<ResourceContent>()
        match (obj.get('contents')) {
            case Some(array: JsonArray) => for (item in array) {
                if (let value: JsonObject <- item) {
                    contents.add(ResourceContent.fromJson(value))
                }
            }
            case _ => ()
        }
        ReadResourceResult(contents.toArray())
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        let items = JsonArray()
        for (content in contents) {
            items.add(content.toJson())
        }
        obj.add('contents', items)
        obj
    }
}

/** `prompts/get` 的结果。 */
public class GetPromptResult {
    public let description: String
    public let messages: Array<PromptMessage>

    public init(description: String, messages: Array<PromptMessage>) {
        this.description = description
        this.messages = messages
    }

    public static func fromJson(obj: JsonObject): GetPromptResult {
        let messages = ArrayList<PromptMessage>()
        match (obj.get('messages')) {
            case Some(array: JsonArray) => for (item in array) {
                if (let value: JsonObject <- item) {
                    messages.add(PromptMessage.fromJson(value))
                }
            }
            case _ => ()
        }
        GetPromptResult(stringOf(obj, 'description'), messages.toArray())
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('description', description)
        let items = JsonArray()
        for (message in messages) {
            items.add(message.toJson())
        }
        obj.add('messages', items)
        obj
    }
}

/** `subscriptions/listen` 的结果。 */
public class ListenResult {
    public let subscriptionId: Int64
    public let subscribedTopics: Array<String>
    public let sseUrl: String

    public init(subscriptionId: Int64, subscribedTopics: Array<String>, sseUrl: String) {
        this.subscriptionId = subscriptionId
        this.subscribedTopics = subscribedTopics
        this.sseUrl = sseUrl
    }

    public static func fromJson(obj: JsonObject): ListenResult {
        let topics = ArrayList<String>()
        match (obj.get('subscribedTopics')) {
            case Some(array: JsonArray) => for (item in array) {
                if (item is JsonString) {
                    topics.add(item.asString().value)
                }
            }
            case _ => ()
        }
        ListenResult(intOf(obj, 'subscriptionId'), topics.toArray(), stringOf(obj, 'sseUrl'))
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('subscriptionId', subscriptionId)
        let topics = JsonArray()
        for (topic in subscribedTopics) {
            topics.add(topic)
        }
        obj.add('subscribedTopics', topics)
        obj.add('sseUrl', sseUrl)
        obj
    }
}

// —— JSON 读取辅助 ——

func stringOf(obj: JsonObject, name: String): String {
    match (obj.get(name)) {
        case Some(value) => if (value is JsonString) {
            value.asString().value
        } else {
            ''
        }
        case _ => ''
    }
}

func optionalStringOf(obj: JsonObject, name: String): ?String {
    match (obj.get(name)) {
        case Some(value) => if (value is JsonString) {
            Some(value.asString().value)
        } else {
            None<String>
        }
        case _ => None<String>
    }
}

func boolOf(obj: JsonObject, name: String): Bool {
    match (obj.get(name)) {
        case Some(value) => if (value is JsonBool) {
            value.asBool().value
        } else {
            false
        }
        case _ => false
    }
}

func intOf(obj: JsonObject, name: String): Int64 {
    match (obj.get(name)) {
        case Some(value) => match (value) {
                case i: JsonInt => i.toInt64()
                case d: JsonDecimal => d.toInt64()
                case _ => 0
            }
        case _ => 0
    }
}

func objectOf(obj: JsonObject, name: String): ?JsonObject {
    match (obj.get(name)) {
        case Some(value) => if (let inner: JsonObject <- value) {
            Some(inner)
        } else {
            None<JsonObject>
        }
        case _ => None<JsonObject>
    }
}

func nestedBool(obj: JsonObject, section: String, name: String): Bool {
    match (objectOf(obj, section)) {
        case Some(inner) => boolOf(inner, name)
        case _ => false
    }
}
