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
import fountain::f_data.exception.DataException
import fountain::f_mcp.base.*

/**
 * `@Mcp` 展开出来的参数与返回值转换。
 *
 * - 入参：按 f_data 的 `fromJson` 把 JSON 转成函数参数类型
 * - 返回值：按 f_data 的 `toJson` 把函数返回值转成 MCP 结果
 *
 * 返回值是 `CallToolResult` / `ArrayList<ResourceContent>` / `ArrayList<PromptMessage>`
 * 时原样使用；`String` 作为文本；其它可转 JSON 的类型序列化后放入文本内容。
 */
public class McpConvert {
    /**
     * 把单个 JSON 参数转换成函数声明的参数类型。
     *
     * 走 `JsonValue → Data → T`，不再 `toString()` 后重新解析（每参数多一次序列化 + 解析）。
     */
    public static func argument<T>(value: JsonValue): T where T <: DataFields<T> {
        match (convert<T>(value.toData())) {
            case Some(v) => v
            case _ => throw McpException(McpProtocol.INVALID_PARAMS, 'invalid argument: ${value.toString()}')
        }
    }

    /** tool 返回 `CallToolResult`：原样使用。 */
    public static func toolResult(value: CallToolResult): CallToolResult {
        value
    }

    /** tool 返回 `String`：作为文本内容。 */
    public static func toolResult(value: String): CallToolResult {
        let content = ArrayList<ContentBlock>()
        content.add(ContentBlock.text(value))
        CallToolResult(content: content)
    }

    /** tool 返回 `Unit`：空内容。 */
    public static func toolResult(value: Unit): CallToolResult {
        CallToolResult(content: ArrayList<ContentBlock>())
    }

    /** tool 返回其它可转 JSON 的值：只序列化一次，文本与 `structuredContent` 共用。 */
    public static func toolResult<T>(value: T): CallToolResult where T <: ToData {
        let json = JsonValue.from(value.toData())
        let content = ArrayList<ContentBlock>()
        content.add(ContentBlock.text(json.toString()))
        CallToolResult(content: content, structuredContent: structuredOf(json))
    }

    /** resource 返回 `ArrayList<ResourceContent>`：原样使用。 */
    public static func resourceContents(value: ArrayList<ResourceContent>): ArrayList<ResourceContent> {
        value
    }

    /** resource 返回 `String`：一段 `text/plain` 内容。 */
    public static func resourceContents(value: String): ArrayList<ResourceContent> {
        let list = ArrayList<ResourceContent>()
        list.add(ResourceContent('', Some('text/plain'), Some(value), None))
        list
    }

    /** resource 返回 `Unit`：一段空文本内容。 */
    public static func resourceContents(value: Unit): ArrayList<ResourceContent> {
        let list = ArrayList<ResourceContent>()
        list.add(ResourceContent('', Some('text/plain'), Some(''), None))
        list
    }

    /** resource 返回其它可转 JSON 的值：一段 `application/json` 内容。 */
    public static func resourceContents<T>(value: T): ArrayList<ResourceContent> where T <: ToData {
        let list = ArrayList<ResourceContent>()
        list.add(ResourceContent('', Some('application/json'), Some(toJson(value)), None))
        list
    }

    /** prompt 返回 `ArrayList<PromptMessage>`：原样使用。 */
    public static func promptMessages(value: ArrayList<PromptMessage>): ArrayList<PromptMessage> {
        value
    }

    /** prompt 返回 `String`：一条 user 消息。 */
    public static func promptMessages(value: String): ArrayList<PromptMessage> {
        messagesOf(value)
    }

    /** prompt 返回 `Unit`：没有消息。 */
    public static func promptMessages(value: Unit): ArrayList<PromptMessage> {
        ArrayList<PromptMessage>()
    }

    /** prompt 返回其它可转 JSON 的值：一条 user 消息。 */
    public static func promptMessages<T>(value: T): ArrayList<PromptMessage> where T <: ToData {
        messagesOf(toJson(value))
    }

    private static func structuredOf(json: JsonValue): ?JsonValue {
        match (json) {
            case obj: JsonObject => Some(obj)
            case _ => None<JsonValue>
        }
    }

    private static func messagesOf(text: String): ArrayList<PromptMessage> {
        let list = ArrayList<PromptMessage>()
        list.add(PromptMessage('user', ContentBlock.text(text)))
        list
    }
}
