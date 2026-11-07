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

import fountain::f_llm.model.po.*
import fountain::f_llm.util.*

/**
 * token 计数策略。
 *
 * 约定：**无法精确计数时返回 -1**，不抛异常、不猜一个数当精确值——
 * 调用方（`saturated`）据此决定要不要按 0.9 折算。
 */
public interface TokenCounter {
    prop name: String
    func count(conf: LLMConf, messages: ArrayList<ChatMessage>): Int64
}

/** 兜底：UTF-8 中文约 3 字节/token，英文约 4 字符/token，统一按字节数/3，再给每条消息 4 token 的开销 */
public class HeuristicTokenCounter <: TokenCounter {
    public prop name: String {
        get() {
            'heuristic'
        }
    }

    public func count(conf: LLMConf, messages: ArrayList<ChatMessage>): Int64 {
        var total = 0
        for(message in messages){
            total += estimateTokens(message.content) + 4
        }
        total
    }
}

/** 远端计数：只认 `conf['tokenizerUrl']`；没配、请求失败、响应没有 usage 都返回 -1 */
public class RemoteTokenCounter <: TokenCounter {
    public prop name: String {
        get() {
            'remote'
        }
    }

    public func count(conf: LLMConf, messages: ArrayList<ChatMessage>): Int64 {
        let url = conf.option('tokenizerUrl', '')
        if(url.isEmpty()){
            return -1
        }
        let prompt = StringBuilder()
        for(message in messages){
            prompt.append(message.content)
            prompt.append('\n')
        }
        try{
            http(url, conf.auth){client =>
                let body = JsonObject()
                body.add('prompt', prompt.toString())
                let response = client.post('application/json', body.toString())
                let json = JsonValue.fromStr(response.readEntire()).asObject()
                if(let Some(usage) <- json.get('usage')){
                    if(let Some(tokens) <- usage.asObject().get('prompt_tokens')){
                        return Int64.tryParse(tokens.toString()) ?? -1
                    }
                }
                return -1
            }
        }catch(_: Exception){
            -1
        }
    }
}
