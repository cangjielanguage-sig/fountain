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

import fountain::f_llm.constant.*
import fountain::f_llm.model.po.*

/**
 * 智谱（bigmodel）：OpenAI 兼容，`thinking` 是对象开关。
 *
 * 规则：`alwaysThinking=true` 时强制 `enabled`；否则只在调用方本来就要过思考时改成 `disabled`，
 * 没要求过就别凭空塞字段——非推理模型收到 `thinking` 会直接 400。
 */
public class ZhipuDialect <: ProviderDialect {
    public prop provider: String {
        get() {
            'zhipu'
        }
    }

    public func endpoint(kind: LLMApiKind, conf: LLMConf): String {
        let base = trimTrailingSlash(conf.url)
        match(kind){
            case LLMApiKind.Chat => base + conf.option('chatPath', '/chat/completions')
            case LLMApiKind.Responses =>
                throw IllegalArgumentException('zhipu does not support the responses api, use chat instead')
        }
    }

    public func headers(conf: LLMConf): HashMap<String, String> {
        bearerHeaders(conf)
    }

    public func decorate(conf: LLMConf, body: JsonObject): Unit {
        applyThinkingObject(conf, body)
    }
}

/** 火山方舟：端点与标准一致，`model` 允许是 `ep-` 接入点 ID（无需特殊处理），思考同样是对象开关 */
public class VolcengineDialect <: ProviderDialect {
    public prop provider: String {
        get() {
            'volcengine'
        }
    }

    public func endpoint(kind: LLMApiKind, conf: LLMConf): String {
        let base = trimTrailingSlash(conf.url)
        match(kind){
            case LLMApiKind.Chat => base + conf.option('chatPath', '/chat/completions')
            case LLMApiKind.Responses =>
                throw IllegalArgumentException('volcengine does not support the responses api yet, use chat instead')
        }
    }

    public func headers(conf: LLMConf): HashMap<String, String> {
        bearerHeaders(conf)
    }

    public func decorate(conf: LLMConf, body: JsonObject): Unit {
        applyThinkingObject(conf, body)
    }
}

/** 阿里百炼（DashScope compatible-mode）：思考是布尔字段 `enable_thinking`，且必须剥掉 `thinking` 对象 */
public class AliyunDialect <: ProviderDialect {
    public prop provider: String {
        get() {
            'aliyun'
        }
    }

    public func endpoint(kind: LLMApiKind, conf: LLMConf): String {
        let base = trimTrailingSlash(conf.url)
        match(kind){
            case LLMApiKind.Chat => base + conf.option('chatPath', '/chat/completions')
            case LLMApiKind.Responses =>
                throw IllegalArgumentException('aliyun does not support the responses api, use chat instead')
        }
    }

    public func headers(conf: LLMConf): HashMap<String, String> {
        bearerHeaders(conf)
    }

    public func decorate(conf: LLMConf, body: JsonObject): Unit {
        body.remove('thinking')
        if(conf.alwaysThinking){
            body.add('enable_thinking', true)
        }else{
            body.remove('enable_thinking')
        }
    }
}

/** 硅基流动：完全标准 OpenAI，不认任何思考字段 */
public class SiliconFlowDialect <: ProviderDialect {
    public prop provider: String {
        get() {
            'siliconflow'
        }
    }

    public func endpoint(kind: LLMApiKind, conf: LLMConf): String {
        let base = trimTrailingSlash(conf.url)
        match(kind){
            case LLMApiKind.Chat => base + conf.option('chatPath', '/chat/completions')
            case LLMApiKind.Responses =>
                throw IllegalArgumentException('siliconflow does not support the responses api, use chat instead')
        }
    }

    public func headers(conf: LLMConf): HashMap<String, String> {
        bearerHeaders(conf)
    }

    public func decorate(conf: LLMConf, body: JsonObject): Unit {
        body.remove('thinking')
        body.remove('enable_thinking')
    }
}

func bearerHeaders(conf: LLMConf): HashMap<String, String> {
    let map = HashMap<String, String>()
    map['Content-Type'] = 'application/json'
    map['Accept'] = 'application/json'
    map['Accept-Encoding'] = 'identity'
    if(!conf.auth.isEmpty()){
        map['Authorization'] = 'Bearer ${conf.auth}'
    }
    map
}

func applyThinkingObject(conf: LLMConf, body: JsonObject): Unit {
    if(conf.alwaysThinking){
        let thinking = JsonObject()
        thinking.add('type', THINGKING_ENABLED)
        body.add('thinking', thinking)
        return
    }
    if(let Some(raw) <- body.get('thinking')){
        let thinking = JsonObject()
        thinking.add('type', THINGKING_DISABLED)
        body.add('thinking', thinking)
    }
}
