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

import std.collection.{ArrayList, HashMap}
import std.io.InputStream
import fountain::f_jsonrpc.server.{JsonRpcContext, JsonRpcMapping}
import fountain::f_mvc.*
import fountain::f_mvc.macros.*
import fountain::f_mcp.base.*

/** MCP 的 HTTP 入口：`/mcp`。SSE 推送由单独的端点承担（见 README）。 */
@Controller
public class McpController {
    private let server = McpRegistry.server()

    @GetMapping[path: '/mcp/sse', produces: 'text/event-stream']
    public func sse(): InputStream {
        let http = CurrentHttpContext.instance
        let query = queryOf(http.request.url.toString())
        // 先校验、后写 chunked：错误路径不能留下半个流式响应（400 且无 Transfer-Encoding）
        let stream = try {
            match (query.get('subscriptionId')) {
                case Some(text) =>
                    let id = parseSubscriptionId(text)
                    match (server.hub().attach(id)) {
                        case Some(subscriber) => McpSseStream(server.hub(), subscriber)
                        case _ => throw McpException(McpProtocol.INVALID_PARAMS,
                                "unknown or already attached subscriptionId '${id}'")
                    }
                case _ => McpSseStream(server.hub(), parseTopics(query.get('topics')))
            }
        } catch (e: McpException) {
            http.responseBuilder.status(400)
            throw e
        }
        http.responseBuilder.header('Transfer-Encoding', 'chunked')
        stream
    }

    @JsonRpcMapping[path: '/mcp']
    public func handle(@RequestBody raw: Array<Byte>): Any {
        let http = CurrentHttpContext.instance
        let ctx = JsonRpcContext(http: Some(http), endpoint: McpProtocol.PATH)
        match (server.jsonRpcServer().handle(raw, ctx: ctx)) {
            case Some(value) => value
            case None => ()
        }
    }
}

/** `subscriptionId` 必须是非负整数；否则 400（由调用方设置状态码）。 */
func parseSubscriptionId(text: String): Int64 {
    match (Int64.tryParse(text)) {
        case Some(value) =>
            if (value < 0) {
                throw McpException(McpProtocol.INVALID_PARAMS, "invalid subscriptionId '${text}'")
            }
            value
        case _ => throw McpException(McpProtocol.INVALID_PARAMS, "invalid subscriptionId '${text}'")
    }
}

/**
 * `topics` 语义：缺省 = 订阅全部；显式空串 = 400（不能反转成「订阅全部」）；
 * 其余按 `,` 拆分、trim、丢弃空项。
 */
func parseTopics(value: ?String): ArrayList<String> {
    let topics = ArrayList<String>()
    match (value) {
        case Some(raw) =>
            if (raw.isEmpty()) {
                throw McpException(McpProtocol.INVALID_PARAMS, 'topics must not be empty')
            }
            for (topic in raw.split(',')) {
                let trimmed = topic.trimAscii()
                if (!trimmed.isEmpty()) {
                    topics.add(trimmed)
                }
            }
        case _ => ()
    }
    topics
}

/** 解析查询串：`key=value` 列表，值做百分号解码（`+` → 空格）并 trim。 */
func queryOf(url: String): HashMap<String, String> {
    let query = HashMap<String, String>()
    match (url.indexOf('?')) {
        case Some(index) =>
            for (pair in url[index + 1..].split('&')) {
                if (pair.isEmpty()) {
                    continue
                }
                match (pair.indexOf('=')) {
                    case Some(eq) =>
                        query.add(decodeComponent(pair[0..eq]).trimAscii(), decodeComponent(pair[eq + 1..]).trimAscii())
                    case _ => query.add(decodeComponent(pair).trimAscii(), '')
                }
            }
        case _ => ()
    }
    query
}

private func decodeComponent(text: String): String {
    let builder = StringBuilder()
    let runes = text.toRuneArray()
    var i = 0
    while (i < runes.size) {
        let c = runes[i]
        if (c == r'%' && i + 2 < runes.size && let Some(hi) <- hexValue(runes[i + 1]) &&
            let Some(lo) <- hexValue(runes[i + 2])) {
            builder.append(Rune(UInt32(hi * 16 + lo)))
            i += 3
        } else if (c == r'+') {
            builder.append(r' ')
            i++
        } else {
            builder.append(c)
            i++
        }
    }
    builder.toString()
}

private func hexValue(c: Rune): ?Int64 {
    if (c >= r'0' && c <= r'9') {
        return Some(Int64(UInt32(c) - UInt32(r'0')))
    }
    if (c >= r'a' && c <= r'f') {
        return Some(Int64(UInt32(c) - UInt32(r'a')) + 10)
    }
    if (c >= r'A' && c <= r'F') {
        return Some(Int64(UInt32(c) - UInt32(r'A')) + 10)
    }
    None<Int64>
}
