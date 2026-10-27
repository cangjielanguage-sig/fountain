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

import fountain::f_data.*

import fountain::f_llm.constant.*
import fountain::f_llm.model.po.*

/**
 * 内部模型 → Chat Completions 报文。
 *
 * 三条规则覆盖了之前 `GLMContext` 里散落的逻辑：
 * 1. 报文里的 `model` 是 `conf.actualLlmName`（统一模型名只用于寻址）；
 * 2. `temperature` 有效值为负 ⇒ 报文里不出现该字段（用平台默认）；
 * 3. 工具定义从 `LLMToolParams.functions` 生成，空集合不写 `tools`。
 */
public struct ChatCompletionsMapper {
    private init(){}

    public static func build(conf: LLMConf, params: LLMParams, stream: Bool): JsonObject {
        let body = JsonValue.from(params.toData()).asObject()
        body.add('model', conf.actualLlmName)

        let effective = if(conf.temperature >= 0.0f64){
            conf.temperature
        }else{
            params.temperature
        }
        if(effective < 0.0f64){
            body.remove('temperature')
        }else{
            body.add('temperature', effective)
        }

        if(stream){
            body.add('stream', true)
        }else{
            body.remove('stream')
        }

        if(let tool: LLMToolParams <- params){
            let tools = ArrayList<JsonValue>()
            for(function in tool.functions){
                tools.add(JsonValue.from(function.toData()))
            }
            if(tools.size > 0){
                body.add('tools', JsonArray(list: tools))
            }else{
                body.remove('tools')
            }
        }
        body
    }

    /** Chat Completions 响应 → 内部模型（文本 / 推理内容 / 工具调用 / usage / finish_reason） */
    public static func parse(resp: JsonObject): LLMResp {
        let out = LLMResp()
        if(let Some(rawChoices) <- resp.get('choices')){
            let choices = rawChoices.asArray().getItems()
            if(choices.size > 0){
                let choice = choices[0].asObject()
                out.finishReason = stringOf(choice, 'finish_reason')
                if(let Some(rawMessage) <- choice.get('message')){
                    appendMessage(out, rawMessage.asObject())
                }
            }
        }
        if(let Some(rawUsage) <- resp.get('usage')){
            fillUsage(out.usage, rawUsage.asObject())
        }
        out
    }

    private static func appendMessage(out: LLMResp, message: JsonObject): Unit {
        let content = stringOf(message, 'content')
        let reasoning = stringOf(message, 'reasoning_content')
        if(let Some(rawCalls) <- message.get('tool_calls')){
            let toolMessage = ToolCallMessage()
            toolMessage.content = content
            toolMessage.reasoningContent = reasoning
            for(item in rawCalls.asArray().getItems()){
                let call = item.asObject()
                let function = if(let Some(raw) <- call.get('function')){
                    raw.asObject()
                }else{
                    JsonObject()
                }
                toolMessage.addFunctionCall(
                    id: stringOf(call, 'id'),
                    toolType: stringOf(call, 'type', TOOL_TYPE_FUNCTION),
                    name: stringOf(function, 'name'),
                    arguments: stringOf(function, 'arguments')
                )
            }
            out.messages.add(toolMessage)
        }else{
            let assistant = AssistantMessage(content)
            assistant.reasoningContent = reasoning
            out.messages.add(assistant)
        }
    }

    private static func fillUsage(usage: TokenUsage, obj: JsonObject): Unit {
        usage.prompt = intOf(obj, 'prompt_tokens')
        usage.completion = intOf(obj, 'completion_tokens')
        usage.total = intOf(obj, 'total_tokens')
        if(let Some(rawDetails) <- obj.get('prompt_tokens_details')){
            usage.cached = intOf(rawDetails.asObject(), 'cached_tokens')
        }
    }
}

/** `content` 可能是 JSON null（工具调用时），不能直接 asString */
func textOf(value: JsonValue): String {
    match(value){
        case _: JsonNull => ''
        case _ => value.asString().value
    }
}

func stringOf(obj: JsonObject, key: String): String {
    if(let Some(value) <- obj.get(key)){
        textOf(value)
    }else{
        ''
    }
}

func stringOf(obj: JsonObject, key: String, defaultValue: String): String {
    if(let Some(value) <- obj.get(key)){
        textOf(value)
    }else{
        defaultValue
    }
}

func intOf(obj: JsonObject, key: String): Int64 {
    if(let Some(value) <- obj.get(key)){
        Int64.tryParse(value.toString()) ?? 0
    }else{
        0
    }
}
