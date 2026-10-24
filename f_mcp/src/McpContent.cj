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
package fountain::f_mcp

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

    public init(content!: ArrayList<ContentBlock>, structuredContent!: ?JsonValue = None, isError!: Bool = false,
        resultType!: String = 'complete', inputRequired!: ?JsonValue = None) {
        this.content = content
        this.structuredContent = structuredContent
        this.isError = isError
        this.resultType = resultType
        this.inputRequired = inputRequired
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
        obj
    }
}

/** `resources/read` 返回的一段内容。 */
public struct ResourceContent {
    public const ResourceContent(public let uri: String, public let mimeType: ?String, public let text: ?String,
        public let blob: ?Array<Byte>) {}

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

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('role', role)
        obj.add('content', content.toJson())
        obj
    }
}
