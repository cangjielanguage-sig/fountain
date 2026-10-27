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

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex

import fountain::f_data.*

import fountain::f_llm.model.po.*

/** 一次调用用的是哪套 OpenAI 协议 */
public enum LLMApiKind {
    | Chat        // /chat/completions
    | Responses   // /responses
}

/**
 * 平台方言：只描述「报文长什么样、往哪发、怎么鉴权」，不描述「模型支不支持思考」。
 *
 * 所有平台都按 OpenAI 兼容处理，差异用本接口的实现补丁，不按平台继承 context。
 */
public interface ProviderDialect {
    prop provider: String

    /** 拼出完整请求地址（base 取 conf.url，路径可被 conf 覆盖） */
    func endpoint(kind: LLMApiKind, conf: LLMConf): String

    /** 鉴权与通用头 */
    func headers(conf: LLMConf): HashMap<String, String>

    /** 对标准 OpenAI 报文做平台补丁（温度、思考、额外字段）；默认什么都不做 */
    func decorate(conf: LLMConf, body: JsonObject): Unit
}

/** 未注册 provider 的回退实现：标准 OpenAI 报文，路径取 conf 或默认 */
public class StandardDialect <: ProviderDialect {
    public prop provider: String {
        get() {
            'openai'
        }
    }

    public func endpoint(kind: LLMApiKind, conf: LLMConf): String {
        let base = trimTrailingSlash(conf.url)
        match(kind){
            case LLMApiKind.Chat => base + conf.option('chatPath', '/chat/completions')
            case LLMApiKind.Responses => base + conf.option('responsesPath', '/responses')
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

    public func decorate(conf: LLMConf, body: JsonObject): Unit {}
}

func trimTrailingSlash(url: String): String {
    var text = url
    while(text.endsWith('/')){
        text = text[0 .. text.size - 1]
    }
    text
}

/** 方言注册表：同名重复注册直接失败，未知 provider 回退标准实现 */
public class DialectRegistry {
    private static let mutex = Mutex()
    private static let dialects = HashMap<String, ProviderDialect>()

    private init(){}

    public static func register(dialect: ProviderDialect): Unit {
        synchronized(mutex){
            if(dialects.contains(dialect.provider)){
                throw IllegalArgumentException('llm dialect already registered: ${dialect.provider}')
            }
            dialects[dialect.provider] = dialect
        }
    }

    public static func get(provider: String): ?ProviderDialect {
        synchronized(mutex){
            dialects.get(provider)
        }
    }

    /** 取方言，未知 provider 回退标准 OpenAI 实现 */
    public static func resolve(provider: String): ProviderDialect {
        if(let Some(dialect) <- get(provider)){
            dialect
        }else{
            StandardDialect()
        }
    }

    public static func providers(): ArrayList<String> {
        synchronized(mutex){
            let names = ArrayList<String>()
            for((name, _) in dialects){
                names.add(name)
            }
            names
        }
    }
}
