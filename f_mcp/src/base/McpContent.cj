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
import stdx.encoding.base64.*
import fountain::f_data.*

/** MCP 内容块：text / image / audio / resource / resource_link。 */
public class ContentBlock {
    private let type_: String
    private let payload: JsonObject

    private ContentBlock(kind: String, payload: JsonObject) {
        this.type_ = kind
        this.payload = payload
    }

    public func kind(): String {
        type_
    }

    public func toJson(): JsonObject {
        payload
    }

    /**
     * 从服务端 JSON 还原。未知 `type` 原样保留（`kind()` 返回原文，`toJson()` 可还原），
     * 不因客户端不认识该类型而丢弃内容。
     */
    public static func fromJson(obj: JsonObject): ContentBlock {
        ContentBlock(stringOf(obj, 'type'), obj)
    }

    public static func text(text: String): ContentBlock {
        let obj = JsonObject()
        obj.add('type', 'text')
        obj.add('text', text)
        ContentBlock('text', obj)
    }

    public static func image(data: Array<Byte>, mimeType: String): ContentBlock {
        binary('image', data, mimeType)
    }

    public static func audio(data: Array<Byte>, mimeType: String): ContentBlock {
        binary('audio', data, mimeType)
    }

    private static func binary(kind: String, data: Array<Byte>, mimeType: String): ContentBlock {
        let obj = JsonObject()
        obj.add('type', kind)
        obj.add('data', toBase64String(data))
        obj.add('mimeType', mimeType)
        ContentBlock(kind, obj)
    }

    public static func resource(uri: String, mimeType: ?String, text!: ?String = None, blob!: ?Array<Byte> = None): ContentBlock {
        let resource = JsonObject()
        resource.add('uri', uri)
        match (mimeType) {
            case Some(m) => resource.add('mimeType', m)
            case _ => ()
        }
        match (text) {
            case Some(t) => resource.add('text', t)
            case _ => ()
        }
        match (blob) {
            case Some(b) => resource.add('blob', toBase64String(b))
            case _ => ()
        }
        let obj = JsonObject()
        obj.add('type', 'resource')
        obj.add('resource', resource)
        ContentBlock('resource', obj)
    }

    public static func resourceLink(uri: String, name: String, description!: ?String = None, mimeType!: ?String = None): ContentBlock {
        let obj = JsonObject()
        obj.add('type', 'resource_link')
        obj.add('uri', uri)
        obj.add('name', name)
        match (description) {
            case Some(d) => obj.add('description', d)
            case _ => ()
        }
        match (mimeType) {
            case Some(m) => obj.add('mimeType', m)
            case _ => ()
        }
        ContentBlock('resource_link', obj)
    }
}

/** `tools/call` 的结果。 */
public class CallToolResult {
    public let content: ArrayList<ContentBlock>
    public let structuredContent: ?JsonValue
    public let isError: Bool
    public let resultType: String
    public let inputRequired: ?JsonValue
    /** 多轮协商的游标：原样进入响应，下一轮由客户端带回。 */
    public let requestState: ?JsonValue
    /** 附加到顶层 `data` 的字段（如 `truncated` / `limit`）。 */
    public let extra: ?JsonObject

    public init(content!: ArrayList<ContentBlock>, structuredContent!: ?JsonValue = None, isError!: Bool = false,
        resultType!: String = 'complete', inputRequired!: ?JsonValue = None, requestState!: ?JsonValue = None,
        extra!: ?JsonObject = None) {
        this.content = content
        this.structuredContent = structuredContent
        this.isError = isError
        this.resultType = resultType
        this.inputRequired = inputRequired
        this.requestState = requestState
        this.extra = extra
    }

    public static func text(text: String): CallToolResult {
        let list = ArrayList<ContentBlock>()
        list.add(ContentBlock.text(text))
        CallToolResult(content: list)
    }

    public static func error(text: String): CallToolResult {
        let list = ArrayList<ContentBlock>()
        list.add(ContentBlock.text(text))
        CallToolResult(content: list, isError: true)
    }

    /** 从服务端 `tools/call` 结果还原；`requestState` 与 `data` 原样带回，供下一轮使用。 */
    public static func fromJson(obj: JsonObject): CallToolResult {
        let blocks = ArrayList<ContentBlock>()
        match (obj.get('content')) {
            case Some(array: JsonArray) => for (item in array) {
                if (let value: JsonObject <- item) {
                    blocks.add(ContentBlock.fromJson(value))
                }
            }
            case _ => ()
        }
        let kind = stringOf(obj, 'resultType')
        let resultType = if (kind.isEmpty()) {
            'complete'
        } else {
            kind
        }
        CallToolResult(content: blocks, structuredContent: obj.get('structuredContent'), isError: boolOf(obj, 'isError'),
            resultType: resultType, inputRequired: obj.get('inputRequired'), requestState: obj.get('requestState'),
            extra: objectOf(obj, 'data'))
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        let blocks = JsonArray()
        var hasStructuredText = false
        for (block in content) {
            blocks.add(block.toJson())
            if (block.kind() == 'text') {
                hasStructuredText = true
            }
        }
        if (let Some(structured) <- structuredContent) {
            if (!hasStructuredText) {
                blocks.add(ContentBlock.text(structured.toString()).toJson())
            }
            obj.add('structuredContent', structured)
        }
        obj.add('content', blocks)
        obj.add('isError', isError)
        obj.add('resultType', resultType)
        match (inputRequired) {
            case Some(value) => obj.add('inputRequired', value)
            case _ => ()
        }
        match (requestState) {
            case Some(value) => obj.add('requestState', value)
            case _ => ()
        }
        match (extra) {
            case Some(value) => obj.add('data', value)
            case _ => ()
        }
        obj
    }
}

/** `resources/read` 返回的一段内容。 */
public struct ResourceContent {
    public const ResourceContent(public let uri: String, public let mimeType: ?String, public let text: ?String,
        public let blob: ?Array<Byte>) {}

    public static func fromJson(obj: JsonObject): ResourceContent {
        let blob = match (obj.get('blob')) {
            case Some(value) => if (value is JsonString) {
                fromBase64String(value.asString().value)
            } else {
                None<Array<Byte>>
            }
            case _ => None<Array<Byte>>
        }
        ResourceContent(stringOf(obj, 'uri'), optionalStringOf(obj, 'mimeType'), optionalStringOf(obj, 'text'), blob)
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('uri', uri)
        match (mimeType) {
            case Some(m) => obj.add('mimeType', m)
            case _ => ()
        }
        match (text) {
            case Some(t) => obj.add('text', t)
            case _ => ()
        }
        match (blob) {
            case Some(b) => obj.add('blob', toBase64String(b))
            case _ => ()
        }
        obj
    }
}

/** `prompts/get` 的一条消息。 */
public struct PromptMessage {
    public const PromptMessage(public let role: String, public let content: ContentBlock) {}

    public static func fromJson(obj: JsonObject): PromptMessage {
        let block = match (obj.get('content')) {
            case Some(value) => if (let inner: JsonObject <- value) {
                ContentBlock.fromJson(inner)
            } else {
                ContentBlock.text(value.toString())
            }
            case _ => ContentBlock.text('')
        }
        PromptMessage(stringOf(obj, 'role'), block)
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('role', role)
        obj.add('content', content.toJson())
        obj
    }
}
