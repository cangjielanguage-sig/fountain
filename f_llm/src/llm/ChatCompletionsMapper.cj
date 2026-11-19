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

        // 只有显式要求 json_object 才发 response_format；纯文本请求带上它
        // 会被 DeepSeek 拒绝（"Prompt must contain the word 'json'"）
        if(let Some(rawFormat) <- body.get('response_format')){
            let kind = stringOf(rawFormat.asObject(), 'type')
            if(kind != 'json_object'){
                body.remove('response_format')
            }
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
        rewriteMultimodal(body)
        body
    }

    /**
     * 把内部 `parts` 改写成 OpenAI 的 content parts。
     *
     * 内部模型是扁平结构（`{type,text,imageUrl,detail}`），线上格式要求
     * `{"type":"image_url","image_url":{"url":…,"detail":…}}`——只在这一层转换，
     * `DataAssist` 自动生成的报文不能直接发。
     */
    private static func rewriteMultimodal(body: JsonObject): Unit {
        if(let Some(rawMessages) <- body.get('messages')){
            for(item in rawMessages.asArray().getItems()){
                let message = item.asObject()
                let rawParts = message.get('parts')
                message.remove('parts')
                if(let Some(parts) <- rawParts){
                    let content = ArrayList<JsonValue>()
                    for(part in parts.asArray().getItems()){
                        content.add(toWirePart(part.asObject()))
                    }
                    if(content.size > 0){
                        message.add('content', JsonArray(list: content))
                    }
                }
            }
        }
    }

    private static func toWirePart(part: JsonObject): JsonValue {
        let wire = JsonObject()
        if(stringOf(part, 'type') == PART_TYPE_IMAGE){
            let image = JsonObject()
            image.add('url', stringOf(part, 'imageUrl'))
            let detail = stringOf(part, 'detail')
            if(!detail.isEmpty()){
                image.add('detail', detail)
            }
            wire.add('type', PART_TYPE_IMAGE)
            wire.add('image_url', image)
        }else{
            wire.add('type', PART_TYPE_TEXT)
            wire.add('text', stringOf(part, 'text'))
        }
        wire
    }

    /** 响应里的 `content` 可能是字符串，也可能是 content parts 数组（多模态模型） */
    private static func contentTextOf(value: ?JsonValue): String {
        match(value){
            case Some(raw) =>
                match(raw){
                    case array: JsonArray =>
                        let builder = StringBuilder()
                        for(item in array.getItems()){
                            let part = item.asObject()
                            if(stringOf(part, 'type') == PART_TYPE_TEXT){
                                builder.append(stringOf(part, 'text'))
                            }
                        }
                        builder.toString()
                    case _: JsonNull => ''
                    case other => other.asString().value
                }
            case None => ''
        }
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
        let content = contentTextOf(message.get('content'))
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
