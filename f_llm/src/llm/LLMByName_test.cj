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

import fountain::f_llm.exception.*
import fountain::f_llm.model.po.*
import fountain::f_llm.service.*

let BY_NAME_OK = '{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'

class StaticSource <: LLMConfSource {
    StaticSource(private let confs: ArrayList<LLMConf>){}
    public prop name: String {
        get() {
            'static'
        }
    }
    public func load(): ArrayList<LLMConf> {
        confs
    }
}

class FixedTransport <: LLMTransport {
    FixedTransport(private let statuses: ArrayList<Int64>){}
    var calls: Int64 = 0
    public func post(url: String, headers: HashMap<String, String>, body: String): LLMHttpResponse {
        let index = calls
        calls++
        let status = if(index < statuses.size){ statuses[index] }else{ statuses[statuses.size - 1] }
        LLMHttpResponse(status, BY_NAME_OK)
    }
}

func byNameConf(id: Int64, llmName: String, weight: Int64): LLMConf {
    let conf = LLMConf()
    conf.id = id
    conf.provider = 'deepseek'
    conf.llmName = llmName
    conf.actualLlmName = 'deepseek-flash'
    conf.url = 'https://api.deepseek.com'
    conf.auth = 'sk-test'
    conf.temperature = -1.0f64
    conf.weight = weight
    conf
}

func byNameHolder(confs: ArrayList<LLMConf>): LLMConfsHolder {
    LLMConfsHolder(source: StaticSource(confs), refreshInterval: Duration.second * 3600)
}

@Test
public class LLMByNameTest {

    @TestCase
    func testChatByNamePicksCandidateAndRecordsSuccess(): Unit {
        let holder = byNameHolder(ArrayList<LLMConf>([byNameConf(101, 'chat-pro', 1)]))
        LLMConfs.setHolder(holder)
        let transport = FixedTransport(ArrayList<Int64>([200]))
        LLM.setTransport(transport)
        let params = LLMParams(model: 'chat-pro', messages: ArrayList<ChatMessage>([UserMessage('hi')]))
        let response = LLM.chatByName('chat-pro', params)
        @Expect(response.messages[0].content, 'ok')
        @Expect(response.usage.llmId, 101)
        @Expect(holder.isCircuitOpen(101), false)
    }

    @TestCase
    func testChatByNameFailsOverAndCountsFailure(): Unit {
        let holder = byNameHolder(ArrayList<LLMConf>([
            byNameConf(201, 'chat-failover', 1),
            byNameConf(202, 'chat-failover', 1)
        ]))
        LLMConfs.setHolder(holder)
        let transport = FixedTransport(ArrayList<Int64>([500, 200]))
        LLM.setTransport(transport)
        let params = LLMParams(model: 'chat-failover', messages: ArrayList<ChatMessage>([UserMessage('hi')]))
        let response = LLM.chatByName('chat-failover', params)
        // 两次请求：第一次 500 转移，第二次成功
        @Expect(transport.calls, 2)
        @Expect(response.messages[0].content, 'ok')
        // 失败计数记在第一个候选上（阈值默认 5，未熔断）
        @Expect(holder.isCircuitOpen(201), false)
    }

    @TestCase
    func testZeroWeightConfIsNotACandidate(): Unit {
        // weight <= 0 与停用等价：不得进入任何候选列表
        let holder = byNameHolder(ArrayList<LLMConf>([byNameConf(701, 'zero-weight', 0)]))
        LLMConfs.setHolder(holder)
        @Expect(holder.candidates('zero-weight').size, 0)
        @Expect(holder.all().size, 0)
        var message = ''
        try{
            LLM.chatByName('zero-weight', facadeParams(0.5f64))
        }catch(e: LLMException){
            message = e.message
        }
        @Expect(message.contains('no available llm conf'), true)
        @Expect(message.contains('available:'), true)
    }

    @TestCase
    func testChatByNameUnknownNameThrows(): Unit {
        let holder = byNameHolder(ArrayList<LLMConf>([byNameConf(301, 'only-name', 1)]))
        LLMConfs.setHolder(holder)
        var message = ''
        try{
            LLM.chatByName('no-such-name', LLMParams(model: 'x', messages: ArrayList<ChatMessage>()))
        }catch(e: LLMException){
            message = e.message
        }
        @Expect(message.contains('no available llm conf'), true)
        @Expect(message.contains('available:'), true)
    }

    @TestCase
    func testSaturatedUsesConfThreshold(): Unit {
        let holder = byNameHolder(ArrayList<LLMConf>())
        let conf = byNameConf(401, 'chat-pro', 1)
        let messages = ArrayList<ChatMessage>([UserMessage('一段足够长的中文内容，用来超过阈值')])
        @Expect(holder.saturated(conf, messages), false)
        conf.setConf(HashMap<String, String>([('tokenThreshold', '10')]))
        @Expect(holder.saturated(conf, messages), true)
        @Expect(holder.getTokenThreshold(conf), 10)
    }
}
