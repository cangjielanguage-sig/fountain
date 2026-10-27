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
 * 内部模型 → Responses API 报文（非流式）。
 *
 * 与 Chat 的三处结构差异都在这里消化：
 * 1. system 消息抽成顶层 `instructions`，其余消息进 `input` 数组；
 * 2. 工具定义是**扁平**的 `{type, name, description, parameters}`（不套 `function`）；
 * 3. 响应按 `output[].type` 分派：`message`（正文在 `content[].text`）/ `function_call`。
 */
public struct ResponsesMapper {
    private init(){}

    public static func build(conf: LLMConf, params: LLMParams, stream: Bool): JsonObject {
        let body = JsonObject()
        body.add('model', conf.actualLlmName)

        let instructions = StringBuilder()
        let input = ArrayList<JsonValue>()
        for(message in params.messages){
            if(message.role == ROLE_SYSTEM){
                if(instructions.size > 0){
                    instructions.append('\n')
                }
                instructions.append(message.content)
            }else{
                input.add(messageToJson(message))
            }
        }
        if(instructions.size > 0){
            body.add('instructions', instructions.toString())
        }
        body.add('input', JsonArray(list: input))

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
                let item = JsonObject()
                item.add('type', function.`type`)
                item.add('name', function.function.name)
                item.add('description', function.function.description)
                item.add('parameters', JsonValue.from(function.function.parameters.toData()))
                tools.add(item)
            }
            if(tools.size > 0){
                body.add('tools', JsonArray(list: tools))
            }else{
                body.remove('tools')
            }
        }
        body
    }

    public static func parse(resp: JsonObject): LLMResp {
        let out = LLMResp()
        out.finishReason = stringOf(resp, 'status')
        if(let Some(rawOutput) <- resp.get('output')){
            for(item in rawOutput.asArray().getItems()){
                let obj = item.asObject()
                match(stringOf(obj, 'type')){
                    case 'message' => out.messages.add(AssistantMessage(textOfMessage(obj)))
                    case 'function_call' =>
                        let toolMessage = ToolCallMessage()
                        toolMessage.addFunctionCall(
                            id: stringOf(obj, 'call_id'),
                            toolType: TOOL_TYPE_FUNCTION,
                            name: stringOf(obj, 'name'),
                            arguments: stringOf(obj, 'arguments')
                        )
                        out.messages.add(toolMessage)
                    case _ => ()
                }
            }
        }
        if(let Some(rawUsage) <- resp.get('usage')){
            let usage = rawUsage.asObject()
            out.usage.prompt = intOf(usage, 'input_tokens')
            out.usage.completion = intOf(usage, 'output_tokens')
            out.usage.total = intOf(usage, 'total_tokens')
        }
        out
    }

    private static func textOfMessage(obj: JsonObject): String {
        let text = StringBuilder()
        if(let Some(rawContent) <- obj.get('content')){
            for(part in rawContent.asArray().getItems()){
                let item = part.asObject()
                if(stringOf(item, 'type') == 'output_text'){
                    text.append(stringOf(item, 'text'))
                }
            }
        }
        text.toString()
    }

    private static func messageToJson(message: ChatMessage): JsonObject {
        let obj = JsonObject()
        obj.add('role', message.role)
        obj.add('content', message.content)
        match(message){
            case tool: ToolCallMessage =>
                let calls = ArrayList<JsonValue>()
                for(call in tool.tool_calls){
                    let item = JsonObject()
                    item.add('id', call.id)
                    item.add('type', call.`type`)
                    let function = JsonObject()
                    function.add('name', call.function.name)
                    function.add('arguments', call.function.arguments)
                    item.add('function', function)
                    calls.add(item)
                }
                obj.add('tool_calls', JsonArray(list: calls))
            case tool: ToolMessage => obj.add('tool_call_id', tool.tool_call_id)
            case _ => ()
        }
        obj
    }
}
