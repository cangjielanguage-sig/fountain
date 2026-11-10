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
package fountain::f_a2a.model

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*

@Test
class A2aJson_test {
    /** 任务双向往返：状态、说明、产物、历史、时间戳一个不少 */
    @TestCase
    func testTaskRoundTrip(): Unit {
        let task = A2aTask(id: 'task-1', contextId: 'ctx-1')
        task.status = A2aStates.INPUT_REQUIRED
        let parts = ArrayList<A2aPart>()
        parts.add(A2aPart(text: '请给日期范围'))
        task.statusMessage = A2aMessage(role: 'agent', parts: parts, messageId: 'm-2')
        task.artifacts.add(A2aArtifact.textOf('a-1', '初稿'))
        let historyParts = ArrayList<A2aPart>()
        historyParts.add(A2aPart(text: '汇总一下'))
        task.history.add(A2aMessage(role: 'user', parts: historyParts, messageId: 'm-1'))
        task.createdAt = 100
        task.updatedAt = 200

        let back = A2aJson.taskOf(task.toJson()).getOrThrow()
        @Expect(back.id, 'task-1')
        @Expect(back.status, A2aStates.INPUT_REQUIRED)
        @Expect(back.statusMessage.getOrThrow().text(), '请给日期范围')
        @Expect(back.artifacts.size, 1)
        @Expect(back.artifacts[0].parts[0].text, '初稿')
        @Expect(back.history.size, 1)
        @Expect(back.history[0].role, 'user')
        @Expect(back.createdAt, 100)
        @Expect(back.updatedAt, 200)
    }

    /** file part 往返保留 url 与 mimeType，不丢成 text */
    @TestCase
    func testFilePartRoundTrip(): Unit {
        let part = A2aPart(kind: 'file', url: 'https://x/a.pdf', mimeType: 'application/pdf')
        let back = A2aJson.partOf(part.toJson()).getOrThrow()
        @Expect(back.kind, 'file')
        @Expect(back.url, 'https://x/a.pdf')
        @Expect(back.mimeType, 'application/pdf')
        @Expect(back.text, '')
    }

    /** 结构不对时返回 None，而不是抛异常给上层 */
    @TestCase
    func testBadJsonReturnsNone(): Unit {
        @Expect(A2aJson.taskOf('[1,2,3]').isNone(), true)
        @Expect(A2aJson.taskOf('not json').isNone(), true)
    }

    /** 副本独立：改副本不影响原任务 */
    @TestCase
    func testCopyIsIndependent(): Unit {
        let task = A2aTask(id: 'task-9', contextId: 'ctx')
        task.status = A2aStates.WORKING
        let copy = A2aJson.copyOf(task)
        copy.status = A2aStates.COMPLETED
        @Expect(task.status, A2aStates.WORKING)
    }
}
