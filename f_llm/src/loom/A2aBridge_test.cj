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
package fountain::f_llm.loom

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_a2a.*
import fountain::f_config.Config
import fountain::f_data.*
import fountain::f_llm.config.LLMConfig

private func outcome(kind: String, message: String): SupervisorOutcome {
    SupervisorOutcome(kind, message: message)
}

private func prompt(): A2aMessage {
    let parts = ArrayList<A2aPart>()
    parts.add(A2aPart(text: '把今天的提交汇总一下'))
    A2aMessage(parts: parts, messageId: 'm-1')
}

@Test
class A2aBridge_test {
    /** 开关：未设 → false；设 true → true */
    @TestCase
    func testA2aDisabledByDefault(): Unit {
        Config.remove(LLMConfig.LLM + '_a2aEnabled')
        @Expect(LLMConfig.a2aEnabled(), false)
        Config.set([(LLMConfig.LLM + '_a2aEnabled', 'true')])
        @Expect(LLMConfig.a2aEnabled(), true)
        Config.remove(LLMConfig.LLM + '_a2aEnabled')
    }

    /** 关闭时启动不注册任何东西 */
    @TestCase
    func testStartSkippedWhenDisabled(): Unit {
        Config.remove(LLMConfig.LLM + '_a2aEnabled')
        LoomA2a.reset()
        @Expect(LoomA2a.startIfEnabled(), false)
        @Expect(LoomA2a.server().isNone(), true)
    }

    /** 开启时注册一次；重复调用不重建 */
    @TestCase
    func testStartIsIdempotent(): Unit {
        Config.set([(LLMConfig.LLM + '_a2aEnabled', 'true')])
        LoomA2a.reset()
        try {
            @Expect(LoomA2a.startIfEnabled(), true)
            let first = LoomA2a.server().getOrThrow()
            @Expect(LoomA2a.startIfEnabled(), true)
            let second = LoomA2a.server().getOrThrow()
            // 同一个实例：任务存储不会被换掉
            @Expect(first.registrationCount(), A2aServer.METHOD_COUNT)
            @Expect(second.registrationCount(), A2aServer.METHOD_COUNT)
        } finally {
            Config.remove(LLMConfig.LLM + '_a2aEnabled')
            LoomA2a.reset()
        }
    }

    /** dispatched → completed，正文取 outcome.message */
    @TestCase
    func testDispatchedMapsToCompleted(): Unit {
        let agent = SupervisorAgent({ _ => outcome(SupervisorOutcome.DISPATCHED, '已派发到日报流程') })
        let result = agent.execute(A2aTask(id: 't1'), prompt())
        @Expect(result.completed, true)
        @Expect(result.text, '已派发到日报流程')
    }

    /** clarifying → input-required（非终态） */
    @TestCase
    func testClarifyingMapsToInput(): Unit {
        let agent = SupervisorAgent({ _ => outcome(SupervisorOutcome.CLARIFYING, '请给出日期范围') })
        let result = agent.execute(A2aTask(id: 't1'), prompt())
        @Expect(result.needsInput, true)
        @Expect(result.completed, false)
    }

    /** 没流程可用 → failed，正文带说明 */
    @TestCase
    func testNoUsableFlowMapsToFailed(): Unit {
        let agent = SupervisorAgent({ _ => outcome(SupervisorOutcome.NO_USABLE, '没有可完成此工作的流程') })
        let result = agent.execute(A2aTask(id: 't1'), prompt())
        @Expect(result.completed, false)
        @Expect(result.needsInput, false)
        @Expect(result.text.contains('没有可完成'), true)
    }

    /** message 为空时退回 flow 名，避免空正文 */
    @TestCase
    func testEmptyMessageFallsBackToFlow(): Unit {
        let result = SupervisorAgent.map(outcome(SupervisorOutcome.DISPATCHED, ''))
        @Expect(result.completed, true)
    }

    /** 客户端取第一个文本产物 */
    @TestCase
    func testAskReturnsFirstTextArtifact(): Unit {
        let parts = ArrayList<A2aPart>()
        parts.add(A2aPart(text: '对方的结果'))
        let task = A2aTask(id: 't1')
        task.status = A2aStates.COMPLETED
        task.artifacts.add(A2aArtifact(artifactId: 'a1', parts: parts))
        let client = LoomA2aClient({ _, _ => task })
        @Expect(client.ask('http://x/rpc', '你好'), '对方的结果')
    }

    /** 没有产物时抛错，而不是返回空串 */
    @TestCase
    func testAskWithoutArtifactThrows(): Unit {
        let task = A2aTask(id: 't1')
        task.status = A2aStates.COMPLETED
        let client = LoomA2aClient({ _, _ => task })
        var message = ''
        try {
            let _ = client.ask('http://x/rpc', '你好')
        } catch (e: LoomException) {
            message = e.message
        }
        @Expect(message.contains('no text'), true)
    }

    /** 工具：url 缺失给可读错误，不抛异常 */
    @TestCase
    func testA2aCallRequiresUrl(): Unit {
        let function = A2aCallFunction({ _, _ => 'ok' })
        let params = A2aCallParam()
        params.nextEvent = 'next'
        let result = function.call(params)
        @Expect((result.result as JsonString).getOrThrow().value.contains('requires url'), true)
    }

    /** 工具：成功时返回对方正文 */
    @TestCase
    func testA2aCallReturnsText(): Unit {
        let function = A2aCallFunction({ url, text => '来自 ${url}: ${text}' })
        let params = A2aCallParam()
        params.nextEvent = 'next'
        params.url = 'http://x/rpc'
        params.text = '你好'
        let result = function.call(params)
        @Expect((result.result as JsonString).getOrThrow().value, '来自 http://x/rpc: 你好')
    }

    /** 工具：调用失败转文本，流程不中断 */
    @TestCase
    func testA2aCallFailureBecomesText(): Unit {
        let function = A2aCallFunction({ _, _ => throw LoomException('connect refused') })
        let params = A2aCallParam()
        params.nextEvent = 'next'
        params.url = 'http://x/rpc'
        params.text = '你好'
        let result = function.call(params)
        @Expect((result.result as JsonString).getOrThrow().value.contains('a2aCall failed'), true)
    }
}
