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

import std.collection.{ArrayList, HashMap}
import std.io.InputStream
import fountain::f_jsonrpc.{JsonRpcContext, JsonRpcMapping}
import fountain::f_mvc.*
import fountain::f_mvc.macros.*

/** MCP 的 HTTP 入口：`/mcp`。SSE 推送由单独的端点承担（见 README）。 */
@Controller
public class McpController {
    private let server = McpRegistry.server()

    @GetMapping[path: '/mcp/sse', produces: 'text/event-stream']
    public func sse(): InputStream {
        let http = CurrentHttpContext.instance
        // 流式响应长度未知，必须显式声明 chunked，否则 stdx http server 会报
        // "Unknown body size for Content-Length header"。
        http.responseBuilder.header('Transfer-Encoding', 'chunked')
        return McpSseStream(server.hub(), topicsOf(http.request.url.toString()))
    }

    @JsonRpcMapping[path: '/mcp']
    public func handle(@RequestBody raw: Array<Byte>): Any {
        let http = CurrentHttpContext.instance
        let meta = HashMap<String, String>()
        for ((key, _) in http.request.headers) {
            if (let Some(value) <- http.request.headers.getFirst(key)) {
                meta.add(key, value)
            }
        }
        let ctx = JsonRpcContext(http: Some(http), endpoint: McpProtocol.PATH, meta: meta)
        match (server.jsonRpcServer().handle(raw, ctx: ctx)) {
            case Some(bytes) => bytes
            case None => ()
        }
    }
}

private func topicsOf(url: String): ArrayList<String> {
    let topics = ArrayList<String>()
    match (url.indexOf('?')) {
        case Some(index) => for (pair in url[index + 1..].split('&')) {
            if (pair.startsWith('topics=')) {
                let value = pair[7..]
                if (!value.isEmpty()) {
                    for (topic in value.split(',')) {
                        if (!topic.isEmpty()) {
                            topics.add(topic)
                        }
                    }
                }
            }
        }
        case _ => ()
    }
    topics
}
