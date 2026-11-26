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
package fountain::f_a2a.client

import std.collection.*

import fountain::f_a2a.model.*
import fountain::f_a2a.server.A2aServer
import fountain::f_data.*
import fountain::f_jsonrpc.base.*
import fountain::f_jsonrpc.client.*

/**
 * A2A 客户端：`f_jsonrpc` 的薄封装。
 *
 * 只做「组参数 / 解任务 / 原样抛协议错误」三件事；重试、连接池、响应上限都由
 * `JsonRpcClient` 的 `ClientOptions` 决定，不在这里重复实现。
 */
public class A2aClient {
    private let call: (String, JsonValue) -> JsonValue
    private let closeable: ?JsonRpcClient

    public init(url: String, opts!: ClientOptions = ClientOptions()) {
        let client = JsonRpcClient(url, opts: opts)
        this.call = { method, params => client.call(method, params: params) }
        this.closeable = Some(client)
    }

    /** 测试用法：注入调用函数 */
    init(call: (String, JsonValue) -> JsonValue) {
        this.call = call
        this.closeable = None
    }

    /** `a2a.message.send`：同步执行，返回终态任务 */
    public func send(message: A2aMessage): A2aTask {
        let params = JsonObject()
        params.add('message', message.toJson())
        if (!message.contextId.isEmpty()) {
            params.add('contextId', message.contextId)
        }
        taskOf(call(A2aServer.METHOD_SEND, params), 'send')
    }

    /** `a2a.tasks.get` */
    public func get(id: String): A2aTask {
        taskOf(call(A2aServer.METHOD_GET, idParams(id)), 'get')
    }

    /** `a2a.tasks.cancel` */
    public func cancel(id: String): A2aTask {
        taskOf(call(A2aServer.METHOD_CANCEL, idParams(id)), 'cancel')
    }

    public func close(): Unit {
        match (closeable) {
            case Some(client) => client.close()
            case None => ()
        }
    }

    private static func idParams(id: String): JsonValue {
        let params = JsonObject()
        params.add('id', id)
        params
    }

    /** 响应不是任务对象时给一条能定位问题的错误，而不是空任务 */
    private static func taskOf(value: JsonValue, op: String): A2aTask {
        match (A2aJson.taskOf(value)) {
            case Some(task) => task
            case None => throw JsonRpcException(-32603, 'a2a ${op}: response is not a task object')
        }
    }
}
