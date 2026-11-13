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
class A2aModels_test {
    /** `input-required` 不是终态：客户端还要接着发 */
    @TestCase
    func testTerminalStates(): Unit {
        @Expect(A2aStates.isTerminal(A2aStates.INPUT_REQUIRED), false)
        @Expect(A2aStates.isTerminal(A2aStates.WORKING), false)
        @Expect(A2aStates.isTerminal(A2aStates.SUBMITTED), false)
        @Expect(A2aStates.isTerminal(A2aStates.COMPLETED), true)
        @Expect(A2aStates.isTerminal(A2aStates.FAILED), true)
        @Expect(A2aStates.isTerminal(A2aStates.CANCELED), true)
    }

    /** 任务的 JSON 结构：状态、产物、历史、时间戳都在 */
    @TestCase
    func testTaskJsonShape(): Unit {
        let task = A2aTask(id: 'task-1', contextId: 'ctx-1')
        task.status = A2aStates.COMPLETED
        let parts = ArrayList<A2aPart>()
        parts.add(A2aPart(text: '完成'))
        task.artifacts.add(A2aArtifact(artifactId: 'a-1', parts: parts))
        let history = ArrayList<A2aPart>()
        history.add(A2aPart(text: '帮我汇总'))
        task.history.add(A2aMessage(role: 'user', parts: history, messageId: 'm-1'))
        task.createdAt = 100
        task.updatedAt = 200

        let json = task.toJson().toString()
        let parsed = JsonValue.fromStr(json).asObject()
        @Expect(parsed['id'].asString().value, 'task-1')
        @Expect(parsed['status'].asString().value, 'completed')
        @Expect(parsed['artifacts'].asArray().size, 1)
        @Expect(parsed['history'].asArray().size, 1)
        @Expect(json.contains('"createdAt":100'), true)
        @Expect(json.contains('"updatedAt":200'), true)
    }

    /** 三种 Part 的字段各自落到正确的位置 */
    @TestCase
    func testPartJsonShape(): Unit {
        let text = A2aPart(text: 'hi').toJson().toString()
        @Expect(text.contains('"kind":"text"'), true)
        @Expect(text.contains('"text":"hi"'), true)

        let file = A2aPart(kind: 'file', url: 'https://x/a.pdf', mimeType: 'application/pdf')
            .toJson()
            .toString()
        @Expect(file.contains('"kind":"file"'), true)
        @Expect(file.contains('"url":"https://x/a.pdf"'), true)
        @Expect(file.contains('"mimeType":"application/pdf"'), true)
        // 文件用 URL 引用，不内联字节
        @Expect(file.contains('"text"'), false)

        @Expect(A2aPart.isSupported('data'), true)
        @Expect(A2aPart.isSupported('video'), false)
    }

    /** 卡片：streaming 能力为真、默认输入输出都是纯文本、扩展字段可选 */
    @TestCase
    func testAgentCardJson(): Unit {
        let card = A2aAgentCard(name: '日报代理', description: '汇总', url: 'http://127.0.0.1:8080/rpc/a2a')
        let json = card.json()
        let parsed = JsonValue.fromStr(json).asObject()
        @Expect(parsed['name'].asString().value, '日报代理')
        @Expect(json.contains('"streaming":true'), true)
        @Expect(json.contains('"pushNotifications":false'), true)
        @Expect(parsed['defaultInputModes'].asArray()[0].asString().value, 'text/plain')
        @Expect(json.contains('x-a2a-extensions'), false)

        card.extensions = '{"custom":true}'
        @Expect(card.json().contains('x-a2a-extensions'), true)
    }

    /** 错误码落在 f_jsonrpc 的业务码段里 */
    @TestCase
    func testErrorCodes(): Unit {
        @Expect(A2aError.TASK_NOT_FOUND, -32020)
        @Expect(A2aError.TASK_NOT_CANCELABLE, -32021)
        @Expect(A2aError.CONTENT_TYPE_UNSUPPORTED, -32023)
        @Expect(A2aError.TASK_REJECTED, -32024)
    }
}
