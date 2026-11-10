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


let TEXT_RESP = '''
{
  "id": "chatcmpl-1",
  "choices": [
    {
      "index": 0,
      "finish_reason": "stop",
      "message": {"role": "assistant", "content": "你好，我是助手"}
    }
  ],
  "usage": {
    "prompt_tokens": 12,
    "completion_tokens": 7,
    "total_tokens": 19,
    "prompt_tokens_details": {"cached_tokens": 4}
  }
}'''

let TOOL_RESP = '''
{
  "id": "chatcmpl-2",
  "choices": [
    {
      "index": 0,
      "finish_reason": "tool_calls",
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          {
            "id": "call_1",
            "type": "function",
            "function": {"name": "currentTime", "arguments": "{\\"format\\":\\"iso\\"}"}
          }
        ]
      }
    }
  ],
  "usage": {"prompt_tokens": 30, "completion_tokens": 11, "total_tokens": 41}
}'''

let REASONING_RESP = '''
{
  "choices": [
    {
      "finish_reason": "stop",
      "message": {"role": "assistant", "content": "答案是 4", "reasoning_content": "先算 2+2"}
    }
  ]
}'''

@Test
public class ChatCompletionsResponseTest {

    @TestCase
    func testParseText(): Unit {
        let resp = ChatCompletionsMapper.parse(JsonValue.fromStr(TEXT_RESP).asObject())
        @Expect(resp.messages.size, 1)
        @Expect(resp.messages[0].content, '你好，我是助手')
        @Expect(resp.finishReason, 'stop')
        @Expect(resp.usage.prompt, 12)
        @Expect(resp.usage.completion, 7)
        @Expect(resp.usage.total, 19)
        @Expect(resp.usage.cached, 4)
    }

    @TestCase
    func testParseToolCalls(): Unit {
        let resp = ChatCompletionsMapper.parse(JsonValue.fromStr(TOOL_RESP).asObject())
        @Expect(resp.finishReason, 'tool_calls')
        @Expect(resp.messages.size, 1)
        if(let tool: ToolCallMessage <- resp.messages[0]){
            @Expect(tool.tool_calls.size, 1)
            @Expect(tool.tool_calls[0].id, 'call_1')
            @Expect(tool.tool_calls[0].`type`, 'function')
            @Expect(tool.tool_calls[0].function.name, 'currentTime')
            @Expect(tool.tool_calls[0].function.arguments, '{"format":"iso"}')
        }else{
            @Expect('ToolCallMessage expected', 'got other')
        }
    }

    @TestCase
    func testParseReasoningContent(): Unit {
        let resp = ChatCompletionsMapper.parse(JsonValue.fromStr(REASONING_RESP).asObject())
        if(let assistant: AssistantMessage <- resp.messages[0]){
            @Expect(assistant.content, '答案是 4')
            @Expect(assistant.reasoningContent, '先算 2+2')
        }else{
            @Expect('AssistantMessage expected', 'got other')
        }
    }

    @TestCase
    func testUsageMissingDefaultsToZero(): Unit {
        let resp = ChatCompletionsMapper.parse(JsonValue.fromStr(REASONING_RESP).asObject())
        @Expect(resp.usage.prompt, 0)
        @Expect(resp.usage.total, 0)
    }

    @TestCase
    func testResponsesBuildsMultimodalInput(): Unit {
        let params = LLMParams(model: 'chat-pro', messages: ArrayList<ChatMessage>())
        let user = UserMessage('看图')
        user.addImage('data:image/png;base64,AAA', detail: 'low')
        params.messages.add(user)
        let body = ResponsesMapper.build(facadeConf(1, 'openai', 'gpt-4o'), params, false)
        let input = body.get('input')?.asArray() ?? JsonArray()
        let content = input.getItems()[0].asObject().get('content')?.asArray() ?? JsonArray()
        @Expect(content.getItems().size, 1)
        let part = content.getItems()[0].asObject()
        @Expect(part.get('type')?.asString().value ?? '', 'input_image')
        // Responses 的 image_url 是字符串，不是 Chat 那种对象
        @Expect(part.get('image_url')?.asString().value ?? '', 'data:image/png;base64,AAA')
        @Expect(part.get('detail')?.asString().value ?? '', 'low')
    }

    @TestCase
    func testResponsesBuildsTextParts(): Unit {
        let params = LLMParams(model: 'chat-pro', messages: ArrayList<ChatMessage>())
        let user = UserMessage('说明')
        user.addText('第一段')
        user.addText('第二段')
        params.messages.add(user)
        let body = ResponsesMapper.build(facadeConf(1, 'openai', 'gpt-4o'), params, false)
        let input = body.get('input')?.asArray() ?? JsonArray()
        let content = input.getItems()[0].asObject().get('content')?.asArray() ?? JsonArray()
        @Expect(content.getItems().size, 2)
        @Expect(content.getItems()[0].asObject().get('type')?.asString().value ?? '', 'input_text')
        @Expect(content.getItems()[1].asObject().get('text')?.asString().value ?? '', '第二段')
    }

    @TestCase
    func testResponsesBuildSplitsInstructions(): Unit {
        let params = LLMParams(model: 'chat-pro', messages: ArrayList<ChatMessage>())
        params.messages.add(SystemMessage('你是助手'))
        params.messages.add(UserMessage('你好'))
        let body = ResponsesMapper.build(facadeConf(1, 'deepseek', 'deepseek-chat'), params, false)
        @Expect(body.get('instructions')?.asString().value ?? '', '你是助手')
        let input = body.get('input')?.asArray() ?? JsonArray()
        @Expect(input.getItems().size, 1)
        @Expect(input.getItems()[0].asObject().get('role')?.asString().value ?? '', 'user')
    }

    @TestCase
    func testResponsesParsesReasoning(): Unit {
        let json = JsonValue.fromStr('{"status":"completed","output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"想一下"}]},{"type":"message","content":[{"type":"output_text","text":"红色"}]}],"usage":{"input_tokens":3,"output_tokens":1,"total_tokens":4}}').asObject()
        let resp = ResponsesMapper.parse(json)
        @Expect(resp.messages.size, 1)
        @Expect(resp.messages[0].content, '红色')
        if(let assistant: AssistantMessage <- resp.messages[0]){
            @Expect(assistant.reasoningContent, '想一下')
        }else{
            @Expect('AssistantMessage expected', 'got other')
        }
    }

    @TestCase
    func testResponsesParseFunctionCall(): Unit {
        let json = JsonValue.fromStr('''
        {
          "status": "completed",
          "output": [
            {"type": "function_call", "call_id": "call_9", "name": "webSearch", "arguments": "{\\"query\\":\\"x\\"}"}
          ],
          "usage": {"input_tokens": 8, "output_tokens": 2, "total_tokens": 10}
        }''').asObject()
        let resp = ResponsesMapper.parse(json)
        @Expect(resp.finishReason, 'completed')
        if(let tool: ToolCallMessage <- resp.messages[0]){
            @Expect(tool.tool_calls.size, 1)
            @Expect(tool.tool_calls[0].id, 'call_9')
            @Expect(tool.tool_calls[0].function.name, 'webSearch')
            @Expect(tool.tool_calls[0].function.arguments, '{"query":"x"}')
        }else{
            @Expect('ToolCallMessage expected', 'got other')
        }
        @Expect(resp.usage.total, 10)
    }

    @TestCase
    func testClassifyStatusCodes(): Unit {
        @Expect(LLMErrorClassifier.isRetryable(429), true)
        @Expect(LLMErrorClassifier.isRetryable(500), true)
        @Expect(LLMErrorClassifier.isRetryable(503), true)
        @Expect(LLMErrorClassifier.isRetryable(408), true)
        @Expect(LLMErrorClassifier.isRetryable(400), false)
        @Expect(LLMErrorClassifier.isRetryable(401), false)
        @Expect(LLMErrorClassifier.isRetryable(404), false)
        @Expect(LLMErrorClassifier.isFatal(422), true)
    }
}
