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
package fountain::f_llm.llm.openai

import std.collection.HashMap

import fountain::f_data.*

import fountain::f_llm.model.po.*

/**
 * DeepSeek 方言（本期优先适配的平台）。
 *
 * 报文与标准 OpenAI 基本一致，差异只有两点，都在这里表达：
 * 1. 只有 Chat Completions，没有 Responses API；
 * 2. 思考由模型自带（`deepseek-reasoner`），报文里没有开关字段。
 */
public class DeepSeekDialect <: ProviderDialect {
    public prop provider: String {
        get() {
            'deepseek'
        }
    }

    public func endpoint(kind: LLMApiKind, conf: LLMConf): String {
        let base = trimTrailingSlash(conf.url)
        match(kind){
            case LLMApiKind.Chat => base + conf.option('chatPath', '/chat/completions')
            case LLMApiKind.Responses =>
                throw IllegalArgumentException('deepseek does not support the responses api, use chat instead')
        }
    }

    public func headers(conf: LLMConf): HashMap<String, String> {
        let map = HashMap<String, String>()
        map['Content-Type'] = 'application/json'
        map['Accept'] = 'application/json'
        if(!conf.auth.isEmpty()){
            map['Authorization'] = 'Bearer ${conf.auth}'
        }
        map
    }

    /** DeepSeek 不接受思考开关：调用方传了也不写进报文 */
    public func decorate(conf: LLMConf, body: JsonObject): Unit {
        body.remove('thinking')
    }
}
