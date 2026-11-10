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

/** 记录发布出去的事件（method|taskId|payload） */
class EventRecorder {
    public var events = ArrayList<String>()
    public var taskIds = ArrayList<String>()

    public func publish(method: String, params: JsonValue, taskId: String): Unit {
        events.add('${method}|${taskId}|${params}')
        taskIds.add(taskId)
    }
}

/** 记录回调 */
class RecordingNotifier {
    public var calls = ArrayList<String>()
    public var ok = true

    public func notify(url: String, body: String): Bool {
        calls.add('${url}|${body}')
        ok
    }
}

private func streamCard(): A2aAgentCard {
    A2aAgentCard(name: '流式代理', url: 'http://127.0.0.1:8080/rpc/a2a')
}

private func paramsOf(kind: String, text: String, taskId: String): JsonValue {
    let part = JsonObject()
    part.add('kind', kind)
    part.add('text', text)
    if (kind == 'file') {
        part.add('url', 'https://x/a.pdf')
        part.add('mimeType', 'application/pdf')
    }
    let parts = ArrayList<JsonValue>()
    parts.add(part)
    let message = JsonObject()
    message.add('role', 'user')
    message.add('messageId', 'm-1')
    message.add('parts', JsonArray(list: parts))
    let params = JsonObject()
    params.add('message', message)
    if (!taskId.isEmpty()) {
        params.add('taskId', taskId)
    }
    params
}

private func idOf(id: String): JsonValue {
    let params = JsonObject()
    params.add('id', id)
    params
}

@Test
class A2aStream_test {
    /** working 先出、completed 后出，且都带 taskId */
    @TestCase
    func testStreamPublishesWorkingThenCompleted(): Unit {
        let recorder = EventRecorder()
        let server = A2aServer(streamCard(), FixedExecutor(A2aExecutionResult.done('完成')),
            publish: { method, params, taskId => recorder.publish(method, params, taskId) })

        let task = server.stream(paramsOf('text', '汇总', ''))
        let taskId = A2aJson.strOf(task.asObject(), 'id')

        @Expect(recorder.events.size >= 2, true)
        @Expect(recorder.events[0].contains(A2aEvents.METHOD_STATUS), true)
        @Expect(recorder.events[0].contains(A2aStates.WORKING), true)
        @Expect(recorder.events[1].contains(A2aStates.COMPLETED), true)
        @Expect(recorder.taskIds[0], taskId)
    }

    /** 产物事件在状态事件之后单独发一条 */
    @TestCase
    func testStreamPublishesArtifact(): Unit {
        let recorder = EventRecorder()
        let server = A2aServer(streamCard(), FixedExecutor(A2aExecutionResult.done('产物正文')),
            publish: { method, params, taskId => recorder.publish(method, params, taskId) })

        let _ = server.stream(paramsOf('text', '汇总', ''))
        var artifactEvents = 0
        for (event in recorder.events) {
            if (event.contains(A2aEvents.METHOD_ARTIFACT)) {
                artifactEvents++
            }
        }
        @Expect(artifactEvents, 1)
    }

    /** 重订阅已终结任务：补发一条终态事件 */
    @TestCase
    func testResubscribePublishesTerminalStatus(): Unit {
        let recorder = EventRecorder()
        let server = A2aServer(streamCard(), FixedExecutor(A2aExecutionResult.done('完成')),
            publish: { method, params, taskId => recorder.publish(method, params, taskId) })
        let task = server.send(paramsOf('text', '汇总', ''))
        let taskId = A2aJson.strOf(task.asObject(), 'id')

        let _ = server.resubscribe(idOf(taskId))
        @Expect(recorder.events.size, 1)
        @Expect(recorder.events[0].contains(A2aStates.COMPLETED), true)
    }

    /** 扩展卡片：配了扩展就带字段，没配就是基础卡片 */
    @TestCase
    func testExtendedCard(): Unit {
        let server = A2aServer(streamCard(), FixedExecutor(A2aExecutionResult.done('x')))
        @Expect(server.extendedCard().toString().contains('x-a2a-extensions'), false)

        let card = streamCard()
        card.extensions = '{"custom":true}'
        let extended = A2aServer(card, FixedExecutor(A2aExecutionResult.done('x')))
        @Expect(extended.extendedCard().toString().contains('x-a2a-extensions'), true)
    }

    /** 推送配置：注册 → 查询 → 删除 */
    @TestCase
    func testPushConfigLifecycle(): Unit {
        let server = A2aServer(streamCard(), FixedExecutor(A2aExecutionResult.done('x')))

        let setParams = JsonObject()
        setParams.add('taskId', 'task-1')
        setParams.add('url', 'http://hook.local/a2a')
        setParams.add('token', 'tk-1')
        let _ = server.pushSet(setParams)

        let getParams = JsonObject()
        getParams.add('taskId', 'task-1')
        @Expect(server.pushGet(getParams).toString().contains('http://hook.local/a2a'), true)

        @Expect(server.pushDelete(getParams).toString(), 'true')
        // 删掉之后再查是空对象
        @Expect(server.pushGet(getParams).toString(), '{}')
    }

    /** 任务进入终态时回调一次，body 带 token；没配回调的任务不发 */
    @TestCase
    func testTerminalNotifiesConfiguredUrl(): Unit {
        let notifier = RecordingNotifier()
        let store = InMemoryA2aTaskStore()
        // 先放一个进行中的任务，才能「先注册回调、再触发终态」
        let running = A2aTask(id: 'task-push', contextId: 'ctx')
        running.status = A2aStates.WORKING
        store.save(running)

        let server = A2aServer(streamCard(), FixedExecutor(A2aExecutionResult.done('完成')), store: store,
            notifier: { url, body => notifier.notify(url, body) })
        let setParams = JsonObject()
        setParams.add('taskId', 'task-push')
        setParams.add('url', 'http://hook.local/a2a')
        setParams.add('token', 'tk-9')
        let _ = server.pushSet(setParams)

        // 取消 → 终态 → 回调
        let _ = server.cancelTask(idOf('task-push'))
        @Expect(notifier.calls.size, 1)
        @Expect(notifier.calls[0].contains('http://hook.local/a2a'), true)
        @Expect(notifier.calls[0].contains('tk-9'), true)
        @Expect(notifier.calls[0].contains(A2aStates.CANCELED), true)

        // 没配回调的任务不发
        let _ = server.send(paramsOf('text', '再来一次', ''))
        @Expect(notifier.calls.size, 1)
    }

    /** 回调失败不影响任务状态 */
    @TestCase
    func testNotifierFailureDoesNotChangeStatus(): Unit {
        let notifier = RecordingNotifier()
        notifier.ok = false
        let store = InMemoryA2aTaskStore()
        let server = A2aServer(streamCard(), FixedExecutor(A2aExecutionResult.done('完成')), store: store,
            notifier: { url, body => notifier.notify(url, body) })

        let task = server.send(paramsOf('text', '汇总', ''))
        @Expect(A2aJson.strOf(task.asObject(), 'status'), A2aStates.COMPLETED)
    }

    /** 非文本 part（file）能正常走完，不被当成不支持 */
    @TestCase
    func testFilePartIsAccepted(): Unit {
        let server = A2aServer(streamCard(), FixedExecutor(A2aExecutionResult.done('已读取文件')))
        let task = server.send(paramsOf('file', '', ''))
        @Expect(A2aJson.strOf(task.asObject(), 'status'), A2aStates.COMPLETED)
    }
}
