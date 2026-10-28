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
package fountain::f_llm.llm

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.model.po.*

func prunerMessages(): ArrayList<ChatMessage> {
    let list = ArrayList<ChatMessage>()
    list.add(SystemMessage('sys'))
    list.add(UserMessage('u1'))
    list.add(AssistantMessage('a1'))
    list.add(UserMessage('u2'))
    list.add(AssistantMessage('a2'))
    list.add(UserMessage('u3'))
    list
}

func confWithThreshold(threshold: String): LLMConf {
    let conf = LLMConf()
    conf.id = 7
    conf.provider = 'deepseek'
    conf.llmName = 'chat-pro'
    conf.actualLlmName = 'deepseek-chat'
    conf.url = 'https://api.deepseek.com'
    conf.auth = 'sk-1234567890abcdef'
    conf.setConf(HashMap<String, String>([('tokenThreshold', threshold)]))
    conf
}

/** 只覆盖 respond：验证「摘要/关键词输出一条 user 消息」这一语义，不连库 */
class FakeSummaryPruner <: ContextSummaryPruner {
    public init() {
        super()
    }
    protected override func respond(agentId: Int64, session: String, params: LLMParams): LLMResp {
        let response = LLMResp()
        response.messages.add(AssistantMessage('摘要结果'))
        response
    }
}

class FakeKeywordsPruner <: ContextKeywordsPruner {
    public init() {
        super()
    }
    protected override func respond(agentId: Int64, session: String, params: LLMParams): LLMResp {
        let response = LLMResp()
        response.messages.add(AssistantMessage('关键词A,关键词B'))
        response
    }
}

@Test
public class ContextPrunerTest {

    @TestCase
    func testRetainKeepsAll(): Unit {
        let messages = prunerMessages()
        @Expect(RetainContextPruner().prune(0, '', messages).size, 6)
    }

    @TestCase
    func testLastNKeepsTail(): Unit {
        // 6 条里保留最近 2 轮 = 最后 4 条：[a1, u2, a2, u3]
        let pruned = LastNContextPruner(n: 2).prune(0, '', prunerMessages())
        @Expect(pruned.size, 4)
        @Expect(pruned[0].content, 'a1')
        @Expect(pruned[3].content, 'u3')
    }

    @TestCase
    func testDrcSplitsSystemAndOthers(): Unit {
        let pruner = DRCContextPruner(systemPruner: RetainContextPruner(), othersPruner: LastNContextPruner(n: 1))
        let pruned = pruner.prune(0, '', prunerMessages())
        @Expect(pruned.size, 3)
        @Expect(pruned[0].role, 'system')
        @Expect(pruned[1].content, 'a2')
        @Expect(pruned[2].content, 'u3')
    }

    @TestCase
    func testRetainLastUserAppendsDroppedUser(): Unit {
        let pruner = RetainLastUserPruner(pruner: LastNContextPruner(n: 0))
        let pruned = pruner.prune(0, '', prunerMessages())
        @Expect(pruned.size, 1)
        @Expect(pruned[0].content, 'u3')
    }

    @TestCase
    func testRetainLastRoundAppendsTail(): Unit {
        let pruner = RetainLastNRoundPruner(pruner: LastNContextPruner(n: 0), n: 1)
        let pruned = pruner.prune(0, '', prunerMessages())
        @Expect(pruned.size, 2)
        @Expect(pruned[0].content, 'a2')
        @Expect(pruned[1].content, 'u3')
    }

    @TestCase
    func testSummaryReturnsSingleUserMessage(): Unit {
        let pruned = FakeSummaryPruner().prune(0, '', prunerMessages())
        @Expect(pruned.size, 1)
        @Expect(pruned[0].role, 'user')
        @Expect(pruned[0].content, '摘要结果')
    }

    @TestCase
    func testKeywordsReturnsSingleUserMessage(): Unit {
        let pruned = FakeKeywordsPruner().prune(0, '', prunerMessages())
        @Expect(pruned.size, 1)
        @Expect(pruned[0].role, 'user')
        @Expect(pruned[0].content, '关键词A,关键词B')
    }

    @TestCase
    func testSaturationOnlyWhenOverThreshold(): Unit {
        let inner = LastNContextPruner(n: 1)
        let tight = SaturationContextPruner(pruner: inner, confSelector: {=> Some(confWithThreshold('10'))})
        @Expect(tight.prune(0, '', prunerMessages()).size, 2)

        let unlimited = SaturationContextPruner(pruner: inner, confSelector: {=> Some(confWithThreshold('0'))})
        @Expect(unlimited.prune(0, '', prunerMessages()).size, 6)

        let noConf = SaturationContextPruner(pruner: inner, confSelector: {=> None<LLMConf>})
        @Expect(noConf.prune(0, '', prunerMessages()).size, 6)
    }

    @TestCase
    func testTokenBudgetKeepsTailInOrder(): Unit {
        let pruner = TokenBudgetContextPruner(budget: 12)
        let pruned = pruner.prune(0, '', prunerMessages())
        @Expect(pruned.size < 6, true)
        @Expect(pruned.size > 0, true)
        @Expect(pruned[pruned.size - 1].content, 'u3')
    }

    @TestCase
    func testUnknownPrunerNameListsAvailable(): Unit {
        var message = ''
        try{
            ContextPrunerMediator.instance.prune('NoSuchPruner', agentId: 0, session: '', messages: prunerMessages())
        }catch(e: IllegalArgumentException){
            message = e.message
        }
        @Expect(message.contains('unknown context pruner'), true)
        @Expect(message.contains('Retain'), true)
    }

    @TestCase
    func testDuplicateRegisterFails(): Unit {
        let pruner = TokenBudgetContextPruner(budget: 999)
        ContextPrunerMediator.instance.register(pruner)
        var thrown = false
        try{
            ContextPrunerMediator.instance.register(TokenBudgetContextPruner(budget: 999))
        }catch(_: IllegalArgumentException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testSummaryPrunerGoesThroughFacade(): Unit {
        // 迁移验证：Summary 裁剪走 LLM.chatByName，而不是已删除的 LLMContextMediator
        LLMConfs.setHolder(byNameHolder(ArrayList<LLMConf>([byNameConf(501, 'pruner-chat', 1)])))
        let transport = FixedTransport(ArrayList<Int64>([200]))
        LLM.setTransport(transport)
        let pruner = ContextSummaryPruner(llmName: 'pruner-chat')
        let pruned = pruner.prune(0, '', prunerMessages())
        @Expect(transport.calls, 1)
        @Expect(pruned.size, 1)
        @Expect(pruned[0].role, 'user')
        @Expect(pruned[0].content, 'ok')
    }

    @TestCase
    func testHeuristicTokenCounter(): Unit {
        let counter = HeuristicTokenCounter()
        @Expect(counter.count(confWithThreshold('0'), prunerMessages()) > 0, true)
    }

    @TestCase
    func testRemoteTokenCounterWithoutUrl(): Unit {
        @Expect(RemoteTokenCounter().count(confWithThreshold('0'), prunerMessages()), -1)
    }

    @TestCase
    func testCallLogMasksAuth(): Unit {
        let conf = confWithThreshold('0')
        let response = LLMResp()
        response.finishReason = 'stop'
        response.usage.prompt = 10
        response.usage.completion = 5
        response.usage.total = 15
        let line = CallLog.summary(conf, response, 123, ttftMs: 45)
        @Expect(line.contains('provider: deepseek'), true)
        @Expect(line.contains('total: 15'), true)
        @Expect(line.contains('ttftMs: 45'), true)
        @Expect(line.contains('sk-1****cdef'), true)
        @Expect(line.contains('sk-1234567890abcdef'), false)
    }
}
