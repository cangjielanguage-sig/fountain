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
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_a2a.model.*
import fountain::f_data.*
import fountain::f_jsonrpc.base.*

/** 固定返回一个结果的执行器 */
class FixedExecutor <: A2aExecutor {
    private let result: A2aExecutionResult

    FixedExecutor(result: A2aExecutionResult) {
        this.result = result
    }

    public func execute(task: A2aTask, message: A2aMessage): A2aExecutionResult {
        result
    }
}

/** 直接抛异常的执行器 */
class ExplodingExecutor <: A2aExecutor {
    public func execute(task: A2aTask, message: A2aMessage): A2aExecutionResult {
        throw Exception('upstream boom')
    }
}

private func card(): A2aAgentCard {
    A2aAgentCard(name: '测试代理', url: 'http://127.0.0.1:8080/rpc/a2a')
}

private func sendParams(kind: String, text: String): JsonValue {
    let part = JsonObject()
    part.add('kind', kind)
    part.add('text', text)
    let parts = ArrayList<JsonValue>()
    parts.add(part)
    let message = JsonObject()
    message.add('role', 'user')
    message.add('messageId', 'm-1')
    message.add('parts', JsonArray(list: parts))
    let params = JsonObject()
    params.add('message', message)
    params
}

private func idParams(id: String): JsonValue {
    let params = JsonObject()
    params.add('id', id)
    params
}

@Test
class A2aServer_test {
    /** 成功：状态 completed、带产物、历史两条 */
    @TestCase
    func testSendCompleted(): Unit {
        let server = A2aServer(card(), FixedExecutor(A2aExecutionResult.done('完成')))
        let task = server.send(sendParams('text', '帮我汇总'))
        let obj = task.asObject()
        @Expect(A2aJson.strOf(obj, 'status'), A2aStates.COMPLETED)
        @Expect(A2aJson.arrayOf(obj, 'artifacts').size, 1)
        @Expect(task.toString().contains('完成'), true)
        @Expect(A2aJson.arrayOf(obj, 'history').size, 2)
    }

    /** 需要澄清：input-required 不是终态，后续还能取到 */
    @TestCase
    func testSendNeedsInput(): Unit {
        let store = InMemoryA2aTaskStore()
        let server = A2aServer(card(), FixedExecutor(A2aExecutionResult.input('请给日期范围')), store: store)
        let task = server.send(sendParams('text', '汇总'))
        let id = A2aJson.strOf(task.asObject(), 'id')
        @Expect(A2aJson.strOf(task.asObject(), 'status'), A2aStates.INPUT_REQUIRED)
        // 再取一次：状态还在，没被当成终态丢掉
        let again = server.getTask(idParams(id))
        @Expect(A2aJson.strOf(again.asObject(), 'status'), A2aStates.INPUT_REQUIRED)
    }

    /** 执行器返回失败：状态 failed，原因写在 statusMessage */
    @TestCase
    func testSendFailed(): Unit {
        let server = A2aServer(card(), FixedExecutor(A2aExecutionResult.failed('上游超时')))
        let task = server.send(sendParams('text', '汇总'))
        @Expect(A2aJson.strOf(task.asObject(), 'status'), A2aStates.FAILED)
        @Expect(task.toString().contains('上游超时'), true)
    }

    /** 执行器抛异常 → 任务失败，而不是协议错误 */
    @TestCase
    func testExecutorExceptionBecomesFailed(): Unit {
        let server = A2aServer(card(), ExplodingExecutor())
        let task = server.send(sendParams('text', '汇总'))
        @Expect(A2aJson.strOf(task.asObject(), 'status'), A2aStates.FAILED)
        @Expect(task.toString().contains('executor failed'), true)
    }

    /** 非文本 part 之外的类型直接拒绝 */
    @TestCase
    func testUnsupportedPartKind(): Unit {
        let server = A2aServer(card(), FixedExecutor(A2aExecutionResult.done('x')))
        var code: Int64 = 0
        try {
            let _ = server.send(sendParams('video', 'x'))
        } catch (e: JsonRpcException) {
            code = e.code
        }
        @Expect(code, A2aError.CONTENT_TYPE_UNSUPPORTED)
    }

    /** 查询不存在的任务 */
    @TestCase
    func testGetUnknownTask(): Unit {
        let server = A2aServer(card(), FixedExecutor(A2aExecutionResult.done('x')))
        var code: Int64 = 0
        try {
            let _ = server.getTask(idParams('missing'))
        } catch (e: JsonRpcException) {
            code = e.code
        }
        @Expect(code, A2aError.TASK_NOT_FOUND)
    }

    /** 取消进行中的任务 */
    @TestCase
    func testCancelWorkingTask(): Unit {
        let store = InMemoryA2aTaskStore()
        // 先塞一个 working 任务进存储，模拟执行中的任务
        let task = A2aTask(id: 'task-1', contextId: 'ctx-1')
        task.status = A2aStates.WORKING
        store.save(task)

        let server = A2aServer(card(), FixedExecutor(A2aExecutionResult.done('x')), store: store)
        let canceled = server.cancelTask(idParams('task-1'))
        @Expect(A2aJson.strOf(canceled.asObject(), 'status'), A2aStates.CANCELED)
    }

    /** 终态任务不能再取消 */
    @TestCase
    func testCancelTerminalTask(): Unit {
        let store = InMemoryA2aTaskStore()
        let task = A2aTask(id: 'task-2', contextId: 'ctx-1')
        task.status = A2aStates.COMPLETED
        store.save(task)

        let server = A2aServer(card(), FixedExecutor(A2aExecutionResult.done('x')), store: store)
        var code: Int64 = 0
        try {
            let _ = server.cancelTask(idParams('task-2'))
        } catch (e: JsonRpcException) {
            code = e.code
        }
        @Expect(code, A2aError.TASK_NOT_CANCELABLE)
    }

    /** 连续注册两次不会翻倍 */
    @TestCase
    func testRegisterIsIdempotent(): Unit {
        let server = A2aServer(card(), FixedExecutor(A2aExecutionResult.done('x')))
        server.register()
        server.register()
        @Expect(server.registrationCount(), 3)
    }

    /** 存储返回副本：改返回值不影响库里的任务 */
    @TestCase
    func testStoreReturnsCopy(): Unit {
        let store = InMemoryA2aTaskStore()
        let task = A2aTask(id: 'task-3', contextId: 'ctx-1')
        task.status = A2aStates.WORKING
        store.save(task)

        let first = store.get('task-3').getOrThrow()
        first.status = A2aStates.CANCELED
        let second = store.get('task-3').getOrThrow()
        @Expect(second.status, A2aStates.WORKING)
    }
}
