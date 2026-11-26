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

import fountain::f_data.*

import fountain::f_llm.exception.*
import fountain::f_llm.model.po.*

let CHUNK_HELLO = '{"choices":[{"index":0,"delta":{"content":"你"},"finish_reason":null}]}'
let CHUNK_WORLD = '{"choices":[{"index":0,"delta":{"content":"好"},"finish_reason":"stop"}]}'
let CHUNK_REASONING = '{"choices":[{"index":0,"delta":{"reasoning_content":"想一下"},"finish_reason":null}]}'
let CHUNK_TOOL_1 = '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"webSearch","arguments":"{\\"query\\":"}}]},"finish_reason":null}]}'
let CHUNK_TOOL_2 = '{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"x\\"}"}}]},"finish_reason":"tool_calls"}]}'
let CHUNK_USAGE = '{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":3,"total_tokens":12}}'

class FakeStreamTransport <: LLMStreamTransport {
    FakeStreamTransport(private let statuses: ArrayList<Int64>, private let scripts: ArrayList<ArrayList<String>>){}
    var calls: Int64 = 0

    public func stream(
        url: String,
        headers: HashMap<String, String>,
        body: String,
        onData: (String) -> Unit
    ): Int64 {
        let index = calls
        calls++
        if(index < scripts.size){
            for(item in scripts[index]){
                onData(item)
            }
        }
        if(index < statuses.size){
            statuses[index]
        }else{
            200
        }
    }
}

func chunks(items: Array<String>): ArrayList<String> {
    let list = ArrayList<String>()
    for(item in items){
        list.add(item)
    }
    list
}

@Test
public class LLMStreamTest {

    @TestCase
    func testChatAccumulatorMergesContent(): Unit {
        let acc = ChatStreamAccumulator()
        let first = acc.feed(CHUNK_HELLO)
        @Expect(first?.content ?? '', '你')
        let second = acc.feed(CHUNK_WORLD)
        @Expect(second?.content ?? '', '好')
        acc.feed('[DONE]')
        @Expect(acc.finished, true)
        let result = acc.result()
        @Expect(result.messages[0].content, '你好')
        @Expect(result.finishReason, 'stop')
        @Expect(result.usageEstimated, true)
    }

    @TestCase
    func testChatAccumulatorReasoning(): Unit {
        let acc = ChatStreamAccumulator()
        let delta = acc.feed(CHUNK_REASONING)
        @Expect(match(delta){
            case Some(d) => match(d.kind){
                case LLMDeltaKind.Reasoning => true
                case _ => false
            }
            case None => false
        }, true)
        acc.feed(CHUNK_HELLO)
        let result = acc.result()
        if(let assistant: AssistantMessage <- result.messages[0]){
            @Expect(assistant.reasoningContent, '想一下')
            @Expect(assistant.content, '你')
        }else{
            @Expect('AssistantMessage expected', 'got other')
        }
    }

    @TestCase
    func testChatAccumulatorToolCallFragments(): Unit {
        let acc = ChatStreamAccumulator()
        acc.feed(CHUNK_TOOL_1)
        acc.feed(CHUNK_TOOL_2)
        let result = acc.result()
        if(let tool: ToolCallMessage <- result.messages[0]){
            @Expect(tool.tool_calls.size, 1)
            @Expect(tool.tool_calls[0].function.name, 'webSearch')
            @Expect(tool.tool_calls[0].function.arguments, '{"query":"x"}')
            let parsed = JsonValue.fromStr(tool.tool_calls[0].function.arguments)
            @Expect(parsed.asObject().get('query')?.asString().value ?? '', 'x')
        }else{
            @Expect('ToolCallMessage expected', 'got other')
        }
    }

    @TestCase
    func testChatAccumulatorUsage(): Unit {
        let acc = ChatStreamAccumulator()
        acc.feed(CHUNK_WORLD)
        acc.feed(CHUNK_USAGE)
        let result = acc.result()
        @Expect(result.usage.prompt, 9)
        @Expect(result.usage.completion, 3)
        @Expect(result.usage.total, 12)
        @Expect(result.usageEstimated, false)
    }

    @TestCase
    func testResponsesAccumulatorCompletedWins(): Unit {
        let acc = ResponsesStreamAccumulator()
        acc.feed('{"type":"response.output_text.delta","delta":"he"}')
        acc.feed('{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"hello"}]}],"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5}}}')
        @Expect(acc.finished, true)
        let result = acc.result()
        @Expect(result.messages[0].content, 'hello')
        @Expect(result.usage.total, 5)
    }

    @TestCase
    func testResponsesAccumulatorFailed(): Unit {
        let acc = ResponsesStreamAccumulator()
        acc.feed('{"type":"response.failed","message":"boom"}')
        var thrown = false
        try{
            acc.result()
        }catch(e: LLMException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testChatStreamFacade(): Unit {
        let scripts = ArrayList<ArrayList<String>>([chunks([CHUNK_HELLO, CHUNK_WORLD, '[DONE]'])])
        let transport = FakeStreamTransport(ArrayList<Int64>([200]), scripts)
        LLM.setStreamTransport(transport)
        let collected = ArrayList<String>()
        let result = LLM.chatStream(
            ArrayList<LLMConf>([facadeConf(61, 'deepseek', 'deepseek-chat')]),
            facadeParams(0.5f64)
        ){delta =>
            match(delta.kind){
                case LLMDeltaKind.Text => collected.add(delta.content)
                case _ => ()
            }
        }
        @Expect(collected.size, 2)
        @Expect(collected[0], '你')
        @Expect(result.messages[0].content, '你好')
        @Expect(result.usage.llmId, 61)
    }

    @TestCase
    func testChatStreamRetryableFailover(): Unit {
        let firstScript = chunks(['{"error":"boom"}'])
        let secondScript = chunks([CHUNK_HELLO, '[DONE]'])
        let scripts = ArrayList<ArrayList<String>>([firstScript, secondScript])
        let transport = FakeStreamTransport(ArrayList<Int64>([500, 200]), scripts)
        LLM.setStreamTransport(transport)
        let result = LLM.chatStream(
            ArrayList<LLMConf>([facadeConf(71, 'zhipu', 'glm-5'), facadeConf(72, 'deepseek', 'deepseek-chat')]),
            facadeParams(0.5f64)
        ){_ => ()}
        @Expect(result.usage.llmId, 72)
        @Expect(result.messages[0].content, '你')
        @Expect(transport.calls, 2)
    }
}
