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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*

import fountain::f_llm.model.po.*

func mapperConf(temperature: Float64): LLMConf {
    let c = LLMConf()
    c.provider = 'deepseek'
    c.llmName = 'chat-pro'
    c.actualLlmName = 'deepseek-chat'
    c.url = 'https://api.deepseek.com'
    c.auth = 'sk'
    c.temperature = temperature
    c
}

func mapperParams(temperature: Float64): LLMParams {
    let p = LLMParams(model: 'chat-pro', messages: ArrayList<ChatMessage>())
    p.temperature = temperature
    p
}

@Test
public class ChatCompletionsMapperTest {

    @TestCase
    func testModelUsesActualLlmName(): Unit {
        let body = ChatCompletionsMapper.build(mapperConf(-1.0f64), mapperParams(0.7f64), false)
        @Expect(body.get('model')?.asString().value ?? '', 'deepseek-chat')
    }

    @TestCase
    func testTemperatureFallsBackToParams(): Unit {
        let body = ChatCompletionsMapper.build(mapperConf(-1.0f64), mapperParams(0.7f64), false)
        @Expect(body.get('temperature')?.asDecimal().value ?? Decimal(0.0f64), Decimal(0.7f64))
    }

    @TestCase
    func testConfTemperatureOverrides(): Unit {
        let body = ChatCompletionsMapper.build(mapperConf(0.2f64), mapperParams(0.7f64), false)
        @Expect(body.get('temperature')?.asDecimal().value ?? Decimal(0.0f64), Decimal(0.2f64))
    }

    @TestCase
    func testNegativeTemperatureOmitted(): Unit {
        let body = ChatCompletionsMapper.build(mapperConf(-1.0f64), mapperParams(-1.0f64), false)
        @Expect(body.get('temperature').isNone(), true)
    }

    @TestCase
    func testStreamFlag(): Unit {
        let streamed = ChatCompletionsMapper.build(mapperConf(-1.0f64), mapperParams(0.7f64), true)
        @Expect(streamed.get('stream')?.asBool().value ?? false, true)
        let plain = ChatCompletionsMapper.build(mapperConf(-1.0f64), mapperParams(0.7f64), false)
        @Expect(plain.get('stream').isNone(), true)
    }

    @TestCase
    func testResponseFormatOnlyWhenJsonRequested(): Unit {
        // 默认文本请求不带 response_format（DeepSeek 会因缺少 json 关键词直接 400）
        let plain = ChatCompletionsMapper.build(mapperConf(-1.0f64), mapperParams(0.5f64), false)
        @Expect(plain.get('response_format').isNone(), true)

        let params = mapperParams(0.5f64)
        params.response_format = ResponseFormat.json
        let json = ChatCompletionsMapper.build(mapperConf(-1.0f64), params, false)
        @Expect(json.get('response_format')?.asObject().get('type')?.asString().value ?? '', 'json_object')
    }

    @TestCase
    func testToolsFromFunctions(): Unit {
        let params = LLMToolParams(model: 'chat-pro', messages: ArrayList<ChatMessage>())
        let function = FunctionCall()
        function.function.name = 'currentTime'
        function.function.description = '返回本机当前时间'
        params.addFunction(function)

        let body = ChatCompletionsMapper.build(mapperConf(-1.0f64), params, false)
        let tools = body.get('tools')?.asArray() ?? JsonArray()
        @Expect(tools.getItems().size, 1)
        let first = tools.getItems()[0].asObject()
        @Expect(first.get('type')?.asString().value ?? '', 'function')
        @Expect(first.get('function')?.asObject().get('name')?.asString().value ?? '', 'currentTime')
    }

    @TestCase
    func testNoToolsWhenEmpty(): Unit {
        let params = LLMToolParams(model: 'chat-pro', messages: ArrayList<ChatMessage>())
        let body = ChatCompletionsMapper.build(mapperConf(-1.0f64), params, false)
        @Expect(body.get('tools').isNone(), true)
    }
}
