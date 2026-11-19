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
package fountain::f_llm.tool

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*
import fountain::f_data.macros.*

import fountain::f_llm.llm.*

let TOOL_CALL_RESP = '{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"loopEcho","arguments":"{}"}}]}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
let PLAIN_RESP = '{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"done"}}],"usage":{"prompt_tokens":2,"completion_tokens":2,"total_tokens":4}}'

@DataAssist[props fields]
class LoopEchoParams {
    private var nextEvent: String = ''
}

class LoopEchoFunction <: FunctionCalling<LoopEchoParams> {
    public prop name: String {
        get() {
            'loopEcho'
        }
    }
    public prop description: String {
        get() {
            'echo in loop test'
        }
    }
    public func call(params: LoopEchoParams): FunctionResult {
        FunctionResult(event: 'next', result: 'tool-output')
    }
}

class LoopTransport <: LLMTransport {
    LoopTransport(private let bodies: ArrayList<String>){}
    var calls: Int64 = 0
    public func post(url: String, headers: HashMap<String, String>, body: String): LLMHttpResponse {
        let index = calls
        calls++
        let responseBody = if(index < bodies.size){ bodies[index] }else{ bodies[bodies.size - 1] }
        LLMHttpResponse(200, responseBody)
    }
}

func loopConf(id: Int64): LLMConf {
    let conf = LLMConf()
    conf.id = id
    conf.provider = 'deepseek'
    conf.llmName = 'chat-pro'
    conf.actualLlmName = 'deepseek-chat'
    conf.url = 'https://api.deepseek.com'
    conf.auth = 'sk'
    conf.temperature = -1.0f64
    conf
}

func loopParams(): LLMToolParams {
    LLMToolParams(model: 'chat-pro', messages: ArrayList<ChatMessage>())
}

@Test
public class LLMToolLoopTest {

    @TestCase
    func testDisabledByDefault(): Unit {
        let transport = LoopTransport(ArrayList<String>([TOOL_CALL_RESP, PLAIN_RESP]))
        LLM.setTransport(transport)
        let response = LLMToolLoop.run(ArrayList<LLMConf>([loopConf(81)]), loopParams())
        @Expect(transport.calls, 1)
        @Expect(response.finishReason, 'tool_calls')
    }

    @TestCase
    func testLoopExecutesToolAndContinues(): Unit {
        try{
            FunctionMediator.register(LoopEchoFunction())
        }catch(_: Exception){}
        let transport = LoopTransport(ArrayList<String>([TOOL_CALL_RESP, PLAIN_RESP]))
        LLM.setTransport(transport)
        let params = loopParams()
        let response = LLMToolLoop.run(ArrayList<LLMConf>([loopConf(82)]), params, enabled: true)
        @Expect(transport.calls, 2)
        @Expect(response.messages[0].content, 'done')
        // 一次工具调用追加两条消息：助手（带 tool_calls）+ 工具结果
        @Expect(params.messages.size, 2)
    }

    @TestCase
    func testRoundsExceeded(): Unit {
        try{
            FunctionMediator.register(LoopEchoFunction())
        }catch(_: Exception){}
        let transport = LoopTransport(ArrayList<String>([TOOL_CALL_RESP]))
        LLM.setTransport(transport)
        let response = LLMToolLoop.run(ArrayList<LLMConf>([loopConf(83)]), loopParams(), enabled: true, maxRounds: 2)
        @Expect(transport.calls, 2)
        @Expect(response.finishReason, 'rounds_exceeded')
    }
}
