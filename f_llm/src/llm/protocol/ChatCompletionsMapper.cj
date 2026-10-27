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

import std.collection.ArrayList

import fountain::f_data.*

import fountain::f_llm.llm.*
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
}
