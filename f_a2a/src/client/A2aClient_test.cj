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
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_a2a.model.*
import fountain::f_a2a.server.A2aServer
import fountain::f_data.*
import fountain::f_jsonrpc.base.*

/** 记录调用并返回预置响应的假 RPC */
class FakeRpc {
    public var methods = ArrayList<String>()
    public var lastParams: String = ''
    public var response: String = ''
    public var errorCode: Int64 = 0

    public func call(method: String, params: JsonValue): JsonValue {
        methods.add(method)
        lastParams = params.toString()
        if (errorCode != 0) {
            throw JsonRpcException(errorCode, 'fake error')
        }
        JsonValue.fromStr(response)
    }
}

private func taskJson(id: String, status: String): String {
    '{"id":"${id}","contextId":"ctx","status":"${status}","artifacts":[],"history":[],"createdAt":1,"updatedAt":2}'
}

private func oneMessage(text: String): A2aMessage {
    let parts = ArrayList<A2aPart>()
    parts.add(A2aPart(text: text))
    A2aMessage(parts: parts, messageId: 'm-1', contextId: 'ctx-1')
}

@Test
class A2aClient_test {
    /** send：方法名正确、message 进了 params、响应解析回任务 */
    @TestCase
    func testSendBuildsParamsAndParsesTask(): Unit {
        let rpc = FakeRpc()
        rpc.response = taskJson('task-1', A2aStates.COMPLETED)
        let client = A2aClient({ method, params => rpc.call(method, params) })

        let task = client.send(oneMessage('汇总今天'))
        @Expect(rpc.methods[0], A2aServer.METHOD_SEND)
        @Expect(rpc.lastParams.contains('汇总今天'), true)
        @Expect(rpc.lastParams.contains('ctx-1'), true)
        @Expect(task.id, 'task-1')
        @Expect(task.status, A2aStates.COMPLETED)
    }

    /** get：只带 id */
    @TestCase
    func testGetPassesId(): Unit {
        let rpc = FakeRpc()
        rpc.response = taskJson('task-2', A2aStates.WORKING)
        let client = A2aClient({ method, params => rpc.call(method, params) })

        let task = client.get('task-2')
        @Expect(rpc.methods[0], A2aServer.METHOD_GET)
        @Expect(rpc.lastParams.contains('task-2'), true)
        @Expect(task.status, A2aStates.WORKING)
    }

    /** cancel：方法名正确、状态回 canceled */
    @TestCase
    func testCancelPassesId(): Unit {
        let rpc = FakeRpc()
        rpc.response = taskJson('task-3', A2aStates.CANCELED)
        let client = A2aClient({ method, params => rpc.call(method, params) })

        let task = client.cancel('task-3')
        @Expect(rpc.methods[0], A2aServer.METHOD_CANCEL)
        @Expect(task.status, A2aStates.CANCELED)
    }

    /** 协议错误原样上抛：码与消息都不改写 */
    @TestCase
    func testErrorIsPropagated(): Unit {
        let rpc = FakeRpc()
        rpc.errorCode = A2aError.TASK_NOT_FOUND
        let client = A2aClient({ method, params => rpc.call(method, params) })

        var code: Int64 = 0
        try {
            let _ = client.get('missing')
        } catch (e: JsonRpcException) {
            code = e.code
        }
        @Expect(code, A2aError.TASK_NOT_FOUND)
    }

    /** 响应不是任务对象：给 -32603 并说明是哪个方法，而不是返回空任务 */
    @TestCase
    func testNonTaskResponseIsRejected(): Unit {
        let rpc = FakeRpc()
        rpc.response = '"just a string"'
        let client = A2aClient({ method, params => rpc.call(method, params) })

        var message = ''
        try {
            let _ = client.get('task-9')
        } catch (e: JsonRpcException) {
            message = e.message
        }
        @Expect(message.contains('get'), true)
        @Expect(message.contains('not a task'), true)
    }
}
