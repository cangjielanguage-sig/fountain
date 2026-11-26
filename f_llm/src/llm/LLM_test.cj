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

let CHAT_OK = '''
{
  "choices": [
    {"finish_reason": "stop", "message": {"role": "assistant", "content": "ok from provider"}}
  ],
  "usage": {"prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5}
}'''

let RESPONSES_OK = '''
{
  "status": "completed",
  "output": [
    {"type": "message", "content": [{"type": "output_text", "text": "responses ok"}]}
  ],
  "usage": {"input_tokens": 4, "output_tokens": 6, "total_tokens": 10}
}'''

class FakeTransport <: LLMTransport {
    FakeTransport(private let statuses: ArrayList<Int64>, private let bodies: ArrayList<String>){}
    var calls: ArrayList<String> = ArrayList<String>()
    public func post(url: String, headers: HashMap<String, String>, body: String): LLMHttpResponse {
        let index = calls.size
        calls.add(url)
        let status = if(index < statuses.size){ statuses[index] }else{ statuses[statuses.size - 1] }
        let responseBody = if(index < bodies.size){ bodies[index] }else{ bodies[bodies.size - 1] }
        LLMHttpResponse(status, responseBody)
    }
}

func facadeParams(temperature: Float64): LLMParams {
    let params = LLMParams(model: 'chat-pro', messages: ArrayList<ChatMessage>())
    params.temperature = temperature
    params
}

func facadeConf(id: Int64, provider: String, model: String): LLMConf {
    let c = LLMConf()
    c.id = id
    c.provider = provider
    c.llmName = 'chat-pro'
    c.actualLlmName = model
    c.url = 'https://api.${provider}.com'
    c.auth = 'sk-${id}'
    c.temperature = -1.0f64
    c
}

@Test
public class LLMTest {

    @TestCase
    func testChatSuccess(): Unit {
        let transport = FakeTransport(ArrayList<Int64>([200]), ArrayList<String>([CHAT_OK]))
        LLM.setTransport(transport)
        let conf = facadeConf(11, 'deepseek', 'deepseek-chat')
        let resp = LLM.chat(ArrayList<LLMConf>([conf]), facadeParams(0.5f64))
        @Expect(resp.messages[0].content, 'ok from provider')
        @Expect(resp.usage.total, 5)
        @Expect(resp.usage.llmId, 11)
        @Expect(transport.calls.size, 1)
        @Expect(transport.calls[0], 'https://api.deepseek.com/chat/completions')
    }

    @TestCase
    func testRetryableFailover(): Unit {
        let transport = FakeTransport(ArrayList<Int64>([429, 200]), ArrayList<String>([CHAT_OK, CHAT_OK]))
        LLM.setTransport(transport)
        let first = facadeConf(21, 'zhipu', 'glm-5')
        let second = facadeConf(22, 'deepseek', 'deepseek-chat')
        let resp = LLM.chat(ArrayList<LLMConf>([first, second]), facadeParams(0.5f64))
        @Expect(resp.usage.llmId, 22)
        @Expect(transport.calls.size, 2)
    }

    @TestCase
    func testFatalStatusStops(): Unit {
        let transport = FakeTransport(ArrayList<Int64>([400, 200]), ArrayList<String>([CHAT_OK, CHAT_OK]))
        LLM.setTransport(transport)
        var thrown = false
        try{
            LLM.chat(ArrayList<LLMConf>([facadeConf(31, 'deepseek', 'deepseek-chat'), facadeConf(32, 'zhipu', 'glm-5')]),
                     facadeParams(0.5f64))
        }catch(e: LLMException){
            thrown = true
        }
        @Expect(thrown, true)
        @Expect(transport.calls.size, 1)
    }

    @TestCase
    func testAllCandidatesFail(): Unit {
        let transport = FakeTransport(ArrayList<Int64>([500, 503]), ArrayList<String>(['{}', '{}']))
        LLM.setTransport(transport)
        var thrown = false
        try{
            LLM.chat(ArrayList<LLMConf>([facadeConf(41, 'deepseek', 'a'), facadeConf(42, 'zhipu', 'b')]),
                     facadeParams(0.5f64))
        }catch(e: LLMException){
            thrown = true
        }
        @Expect(thrown, true)
        @Expect(transport.calls.size, 2)
    }

    @TestCase
    func testRespondUsesResponsesMapper(): Unit {
        let transport = FakeTransport(ArrayList<Int64>([200]), ArrayList<String>([RESPONSES_OK]))
        LLM.setTransport(transport)
        let conf = facadeConf(51, 'openai', 'gpt-5')
        let resp = LLM.respond(ArrayList<LLMConf>([conf]), facadeParams(0.5f64))
        @Expect(resp.messages[0].content, 'responses ok')
        @Expect(resp.usage.total, 10)
        @Expect(resp.finishReason, 'completed')
        @Expect(transport.calls[0], 'https://api.openai.com/responses')
    }
}
