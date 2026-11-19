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

import fountain::f_mvc.*
import fountain::f_mvc.macros.*
import fountain::f_jsonrpc.base.*

/**
 * JSON-RPC 默认端点的 HTTP 入口。
 *
 * 两条路由各对应一个 `RequestMeta`：`/rpc` 与 `/rpc/{topic}`。
 * `method` 在请求体内分发，路由只负责把原始字节交给 `JsonRpcServer`。
 */
@Controller
public class JsonRpcController {
    private let server = JsonRpcRegistry.server()

    @JsonRpcMapping[path: '/rpc']
    public func handleRoot(@RequestBody raw: Array<Byte>): Any {
        dispatch(raw, '')
    }

    @JsonRpcMapping[path: '/rpc/{topic}']
    public func handleTopic(
        @PathVariable topic: String,
        @RequestBody raw: Array<Byte>
    ): Any {
        dispatch(raw, topic)
    }

    private func dispatch(raw: Array<Byte>, topic: String): Any {
        let http = CurrentHttpContext.instance
        let endpoint = if (topic.isEmpty()) {
            JsonRpcProtocol.PATH
        } else {
            '${JsonRpcProtocol.PATH}/${topic}'
        }
        let ctx = JsonRpcContext(http: Some(http), endpoint: endpoint, topic: topic)
        match (server.handle(raw, ctx: ctx)) {
            case Some(value) => value
            case None => ()
        }
    }
}
