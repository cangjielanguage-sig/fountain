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

import std.collection.*
import std.io.InputStream

import fountain::f_mvc.*
import fountain::f_mvc.macros.*

/**
 * SSE 端点的 HTTP 入口：`GET /rpc/stream?topic=…&taskId=…[&cursor=…]`。
 *
 * 返回一个**不会主动结束**的 `InputStream`；`f_mvc` 的 `respond(InputStream)` 负责
 * 边读边写（无 `Content-Length`，由 HTTP 层按 chunked 输出）。
 */
@Controller
public class SseController {
    public init() {
    }

    @SseMapping[path: '/rpc/stream']
    public func stream(): InputStream {
        let http = CurrentHttpContext.instance
        // `URL.rawQuery` 是 Option<String>（没有查询串时为 None）
        let raw = match (http.request.url.rawQuery) {
            case Some(value) => value
            case None => ''
        }
        let query = queryOf(raw)
        let topic = match (query.get('topic')) {
            case Some(value) => if (value.trimAscii().isEmpty()) {
                DEFAULT_TOPIC
            } else {
                value.trimAscii()
            }
            case None => DEFAULT_TOPIC
        }
        let taskId = textOf(query, 'taskId')
        // 断线重连时客户端带的是请求头，优先于查询参数
        let fromHeader = match (http.request.headers.getFirst('Last-Event-ID')) {
            case Some(text) => match (Int64.tryParse(text.trimAscii())) {
                case Some(value) => value
                case None => 0
            }
            case None => 0
        }
        let fromQuery = intOf(query, 'cursor')
        let cursor = if (fromHeader > 0) {
            fromHeader
        } else {
            fromQuery
        }
        // 中间代理（nginx 等）默认会缓冲响应体，这两个头让它直通
        let _ = http.responseBuilder.header('Cache-Control', 'no-cache')
        let _ = http.responseBuilder.header('X-Accel-Buffering', 'no')
        SseHub.subscribe(topic, taskId: taskId, lastEventId: cursor).stream
    }

    /** 解析查询串（`a=1&b=2`，不含前导 `?`）；同名参数取最后一个 */
    static func queryOf(raw: String): HashMap<String, String> {
        let result = HashMap<String, String>()
        let text = match (raw.indexOf('?')) {
            case Some(index) => raw[index + 1..]
            case None => raw
        }
        for (pair in text.split('&')) {
            let item = pair.trimAscii()
            if (item.isEmpty()) {
                continue
            }
            match (item.indexOf('=')) {
                case Some(at) =>
                    if (at > 0) {
                        result[item[..at].trimAscii()] = item[at + 1..].trimAscii()
                    }
                case None => ()
            }
        }
        result
    }

    /** 取字符串参数（缺省空串） */
    static func textOf(query: HashMap<String, String>, key: String): String {
        match (query.get(key)) {
            case Some(value) => value
            case None => ''
        }
    }

    /** 取整数参数（缺省/非法都按 0） */
    static func intOf(query: HashMap<String, String>, key: String): Int64 {
        match (Int64.tryParse(textOf(query, key))) {
            case Some(value) => value
            case None => 0
        }
    }

    static let DEFAULT_TOPIC = 'default'
}
