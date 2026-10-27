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
package fountain::f_llm.llm.protocol

import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*

import fountain::f_llm.llm.*

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
