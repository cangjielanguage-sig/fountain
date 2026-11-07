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

import std.collection.ArrayList

import fountain::f_data.*

/**
 * 自动工具循环：模型要求调工具 → 本地执行 → 把结果回灌 → 再问一次。
 *
 * **默认关闭**（评审 15.3）：多数编排场景自己管工具轮次，框架偷偷多跑几轮会打乱
 * 计费与日志；显式 `enabled: true` 才启用，并且有硬上限（默认 8 轮）。
 *
 * 放在 tool 包而不是 llm 包：它依赖 `FunctionMediator`（tool → llm 已有单向依赖），
 * 反过来放进 llm 会形成包循环。
 */
public class LLMToolLoop {
    public static const DEFAULT_MAX_ROUNDS: Int64 = 8

    private init(){}

    public static func run(
        candidates: ArrayList<LLMConf>,
        params: LLMToolParams,
        enabled!: Bool = false,
        maxRounds!: Int64 = DEFAULT_MAX_ROUNDS
    ): LLMResp {
        if(!enabled || maxRounds <= 0){
            return LLM.chat(candidates, params)
        }
        var last = LLMResp()
        var round = 0
        while(round < maxRounds){
            round++
            last = LLM.chat(candidates, params)
            let calls = toolCallsOf(last)
            if(calls.isEmpty()){
                return last
            }
            params.messages.add(assistantEcho(last))
            for(call in calls){
                params.messages.add(toolResult(call))
            }
        }
        // 轮次用尽：保留最后一轮内容，但明确标记，调用方据此判断“还没收敛”
        last.finishReason = 'rounds_exceeded'
        last
    }

    private static func toolCallsOf(response: LLMResp): ArrayList<ToolCall> {
        let calls = ArrayList<ToolCall>()
        for(message in response.messages){
            if(let tool: ToolCallMessage <- message){
                for(call in tool.tool_calls){
                    calls.add(call)
                }
            }
        }
        calls
    }

    private static func assistantEcho(response: LLMResp): ChatMessage {
        for(message in response.messages){
            if(let tool: ToolCallMessage <- message){
                return tool
            }
        }
        AssistantMessage('')
    }

    private static func toolResult(call: ToolCall): ChatMessage {
        let message = ToolMessage()
        message.content = invoke(call)
        message.tool_call_id = call.id
        message
    }

    private static func invoke(call: ToolCall): String {
        let args = try{
            JsonValue.fromStr(call.function.arguments).asObject()
        }catch(_: Exception){
            JsonObject()
        }
        let result = try{
            FunctionMediator.call(call.function.name, args)
        }catch(e: Exception){
            return '[工具调用失败] ${call.function.name}: ${e}'
        }
        match(result.result){
            case text: JsonString => text.value
            case text: String => text
            case _ => ''
        }
    }
}
