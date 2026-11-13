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
package fountain::f_a2a.server

import std.collection.*

import fountain::f_data.*
import fountain::f_httpclient.*
import fountain::f_jsonrpc.server.*

/**
 * 事件与回调的默认实现。
 *
 * - 事件：走 `f_jsonrpc` 的 `SseHub`，一次任务一个 `taskId` 过滤，
 *   客户端用 `GET /rpc/stream?topic=a2a&taskId=…` 订阅；
 * - 回调：用 `f_httpclient` POST，异常一律吞掉并返回 false —— 回调失败不该影响任务终态。
 */
public class A2aEvents {
    /** SSE 事件 topic：所有 A2A 事件都在这里，靠 `taskId` 分流 */
    public static let TOPIC = 'a2a'

    public static let METHOD_STATUS = 'a2a.task.status'
    public static let METHOD_ARTIFACT = 'a2a.task.artifact'

    private init() {
    }

    /** 默认发布：写进 `SseHub`（发布失败不影响任务） */
    public static func publish(method: String, params: JsonValue, taskId: String): Unit {
        let _ = SseHub.publish(TOPIC, method, params: params, taskId: taskId)
    }

    /** 默认回调：POST 一段 JSON；失败返回 false（调用方记 warn） */
    public static func notify(url: String, body: String): Bool {
        try {
            let client = HttpClient(url)
            let _ = client.post(body)
            client.close()
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 状态事件参数 */
    public static func statusParams(taskId: String, status: String): JsonValue {
        let params = JsonObject()
        params.add('taskId', taskId)
        params.add('status', status)
        params
    }

    /** 推送体：JSON-RPC 通知，带 `token` 便于客户端校验来源 */
    public static func pushBody(taskId: String, status: String, token: String): String {
        let params = JsonObject()
        params.add('taskId', taskId)
        params.add('status', status)
        params.add('token', token)
        let body = JsonObject()
        body.add('jsonrpc', '2.0')
        body.add('method', METHOD_STATUS)
        body.add('params', params)
        body.toString()
    }
}
