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

import fountain::f_data.*

import fountain::f_llm.model.po.*

/** 一个工具调用的分片累加器（`tool_calls` 会按 index 拆成多块下发） */
class ToolCallFragment {
    var id: String = ''
    var name: String = ''
    let arguments = StringBuilder()
}

/**
 * Chat Completions 流式增量的归并器。
 *
 * 只做归并，不发请求；`[DONE]` 由调用方判断后停止喂入（本类也能识别）。
 * 归并结果与非流式解析保持一致：正文 / 推理内容 / 工具调用 / usage / finish_reason。
 */
public class ChatStreamAccumulator {
    private let content = StringBuilder()
    private let reasoning = StringBuilder()
    private let fragments = HashMap<Int64, ToolCallFragment>()
    private let order = ArrayList<Int64>()
    private let usage = TokenUsage()
    private var hasUsage = false
    private var finishReason = ''
    private var done = false

    public prop finished: Bool {
        get() {
            done
        }
    }

    public func isDone(data: String): Bool {
        data.trimAscii() == '[DONE]'
    }

    /** 返回本次可展示的增量；没有正文/推理/工具片段时返回 None */
    public func feed(data: String): ?LLMDelta {
        if(isDone(data)){
            done = true
            return None<LLMDelta>
        }
        let json = JsonValue.fromStr(data).asObject()
        if(let Some(rawUsage) <- json.get('usage')){
            fillStreamUsage(usage, rawUsage.asObject())
            hasUsage = true
        }
        if(let Some(rawChoices) <- json.get('choices')){
            let choices = rawChoices.asArray().getItems()
            if(choices.size > 0){
                let choice = choices[0].asObject()
                let finish = stringOf(choice, 'finish_reason')
                if(!finish.isEmpty()){
                    finishReason = finish
                }
                if(let Some(rawDelta) <- choice.get('delta')){
                    return mergeDelta(rawDelta.asObject())
                }
            }
        }
        None<LLMDelta>
    }

    private func mergeDelta(delta: JsonObject): ?LLMDelta {
        let text = stringOf(delta, 'content')
        if(!text.isEmpty()){
            content.append(text)
            return Some(LLMDelta(LLMDeltaKind.Text, text))
        }
        var reasoningText = stringOf(delta, 'reasoning_content')
        if(reasoningText.isEmpty()){
            reasoningText = stringOf(delta, 'reasoning')
        }
        if(!reasoningText.isEmpty()){
            reasoning.append(reasoningText)
            return Some(LLMDelta(LLMDeltaKind.Reasoning, reasoningText))
        }
        if(let Some(rawCalls) <- delta.get('tool_calls')){
            var argumentsChunk = ''
            for(item in rawCalls.asArray().getItems()){
                let call = item.asObject()
                let index = intOf(call, 'index')
                let fragment = if(let Some(exist) <- fragments.get(index)){
                    exist
                }else{
                    let created = ToolCallFragment()
                    fragments[index] = created
                    order.add(index)
                    created
                }
                let id = stringOf(call, 'id')
                if(!id.isEmpty()){
                    fragment.id = id
                }
                if(let Some(rawFunction) <- call.get('function')){
                    let function = rawFunction.asObject()
                    let name = stringOf(function, 'name')
                    if(!name.isEmpty()){
                        fragment.name = name
                    }
                    let arguments = stringOf(function, 'arguments')
                    if(!arguments.isEmpty()){
                        fragment.arguments.append(arguments)
                        argumentsChunk += arguments
                    }
                }
            }
            if(!argumentsChunk.isEmpty()){
                return Some(LLMDelta(LLMDeltaKind.ToolCall, argumentsChunk))
            }
        }
        None<LLMDelta>
    }

    public func result(): LLMResp {
        let response = LLMResp()
        response.finishReason = finishReason
        if(order.isEmpty()){
            let assistant = AssistantMessage(content.toString())
            assistant.reasoningContent = reasoning.toString()
            response.messages.add(assistant)
        }else{
            let toolMessage = ToolCallMessage()
            toolMessage.content = content.toString()
            toolMessage.reasoningContent = reasoning.toString()
            for(index in order){
                if(let Some(fragment) <- fragments.get(index)){
                    toolMessage.addFunctionCall(
                        id: fragment.id,
                        toolType: 'function',
                        name: fragment.name,
                        arguments: fragment.arguments.toString()
                    )
                }
            }
            response.messages.add(toolMessage)
        }
        if(hasUsage){
            response.usage.prompt = usage.prompt
            response.usage.completion = usage.completion
            response.usage.total = usage.total
            response.usage.cached = usage.cached
        }else{
            // 上游没给 usage：按字符数粗估，并显式标记，避免被当成真实计费
            let completion = estimateTokens(content.toString() + reasoning.toString())
            response.usage.prompt = 0
            response.usage.completion = completion
            response.usage.total = completion
            response.usageEstimated = true
        }
        response
    }
}

func fillStreamUsage(usage: TokenUsage, obj: JsonObject): Unit {
    usage.prompt = intOf(obj, 'prompt_tokens')
    usage.completion = intOf(obj, 'completion_tokens')
    usage.total = intOf(obj, 'total_tokens')
    if(let Some(rawDetails) <- obj.get('prompt_tokens_details')){
        usage.cached = intOf(rawDetails.asObject(), 'cached_tokens')
    }
}

/** 粗估：UTF-8 中文约 3 字节/token，英文约 4 字符/token，统一按字节数/3 */
func estimateTokens(text: String): Int64 {
    if(text.isEmpty()){
        return 0
    }
    let value = text.size / 3
    if(value <= 0){ 1 }else{ value }
}
