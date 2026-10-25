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

import std.time.MonoTime
import fountain::f_data.*
import fountain::f_mvc.HttpContext
import fountain::f_jsonrpc.base.*

/**
 * 一次调用的上下文。
 *
 * `http` 为 `None` 表示 stdio / 本地直调（`invoke`）：此时 `setResponseHeader` 是 no-op。
 * `deadline` 由超时配置推导，handler 可在长循环里自查（`isExpired`）。
 */
public class JsonRpcContext {
    public let http: ?HttpContext
    public let id: ?JsonValue
    public let endpoint: String
    public let topic: String
    public let deadline: ?MonoTime

    public init(http!: ?HttpContext = None, id!: ?JsonValue = None, endpoint!: String = JsonRpcProtocol.PATH,
        topic!: String = '', deadline!: ?MonoTime = None) {
        this.http = http
        this.id = id
        this.endpoint = endpoint
        this.topic = topic
        this.deadline = deadline
    }

    /** 设置响应头。仅在 handler 执行期间有效；非 HTTP 场景静默忽略。 */
    public func setResponseHeader(name: String, value: String): Unit {
        match (http) {
            case Some(ctx) => ctx.responseBuilder.header(name, value)
            case _ => ()
        }
    }

    /** 是否已到 deadline。没有 deadline 时始终为 false。 */
    public func isExpired(): Bool {
        match (deadline) {
            case Some(d) => MonoTime.now() >= d
            case _ => false
        }
    }

    func derive(id: ?JsonValue, deadline: ?MonoTime): JsonRpcContext {
        JsonRpcContext(http: http, id: id, endpoint: endpoint, topic: topic, deadline: deadline)
    }
}
