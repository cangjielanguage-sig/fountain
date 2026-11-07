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
package fountain::f_llm.embedding

import std.collection.ArrayList
import std.sync.Mutex

import fountain::f_data.*

import fountain::f_llm.constant.*
import fountain::f_llm.llm.*
import fountain::f_llm.model.po.*

/** 向量化失败（没有可用配置、响应缺 `data[0].embedding`、全部候选失败） */
public class EmbeddingException <: Exception {
    public init(message: String) {
        super(message)
    }
}

/**
 * 向量化门面：与 `LLM.chatByName` 同构——按 `llmName` 从配置快照选平台、按权重挑起点、
 * 失败转移、可重试失败记熔断。
 *
 * 请求是 OpenAI 兼容的 `POST {url}{embeddingPath|/embeddings}`，报文 `{model, input}`；
 * 响应取 `data[0].embedding` 与 `usage`。
 */
public class Embedding {
    private static let mutex = Mutex()
    private static var transport: LLMTransport = DefaultHttpTransport()

    private init(){}

    public static func setTransport(value: LLMTransport): Unit {
        synchronized(mutex){
            transport = value
        }
    }

    public static func getTransport(): LLMTransport {
        synchronized(mutex){
            transport
        }
    }

    public static func embed(llmName: String, params: EmbeddingParam): EmbeddingResp {
        let holder = LLMConfs.holder()
        let candidates = candidatesOf(llmName)
        if(candidates.isEmpty()){
            throw EmbeddingException('no embedding conf available for: ${llmName}')
        }
        var lastError = ''
        for(conf in candidates){
            if(holder.isCircuitOpen(conf.id)){
                continue
            }
            let body = JsonObject()
            body.add('model', conf.actualLlmName)
            body.add('input', params.input)
            var response = LLMHttpResponse(0, '')
            try{
                response = getTransport().post(endpointOf(conf), headersOf(conf), body.toString())
            }catch(e: Exception){
                holder.recordRetryableFailure(conf.id)
                lastError = '${e}'
                continue
            }
            if(response.status >= 400){
                if(LLMErrorClassifier.isRetryable(response.status)){
                    holder.recordRetryableFailure(conf.id)
                    lastError = 'status ${response.status}'
                    continue
                }
                throw EmbeddingException('embedding failed, provider: ${conf.provider}, status: ${response.status}')
            }
            let result = parse(response.body)
            result.usage.llmId = conf.id
            holder.recordSuccess(conf.id)
            return result
        }
        throw EmbeddingException('all embedding confs failed for: ${llmName}, last: ${lastError}')
    }

    /** 先按 `llmName` 找；找不到再按 `actualLlmName` 兜底（兼容直接传模型名的调用方） */
    private static func candidatesOf(llmName: String): ArrayList<LLMConf> {
        let holder = LLMConfs.holder()
        let byName = ArrayList<LLMConf>()
        for(conf in holder.candidates(llmName)){
            if(isEmbedding(conf)){
                byName.add(conf)
            }
        }
        if(!byName.isEmpty()){
            return byName
        }
        for(conf in holder.all()){
            if(isEmbedding(conf) && conf.actualLlmName == llmName){
                byName.add(conf)
            }
        }
        byName
    }

    private static func isEmbedding(conf: LLMConf): Bool {
        conf.option('llmType', LLM_TYPE_TEXT) == LLM_TYPE_EMBEDDING
    }

    private static func endpointOf(conf: LLMConf): String {
        let base = if(conf.url.endsWith('/')){ conf.url[0 .. conf.url.size - 1] }else{ conf.url }
        base + conf.option('embeddingPath', '/embeddings')
    }

    private static func headersOf(conf: LLMConf): HashMap<String, String> {
        let headers = HashMap<String, String>()
        headers['Content-Type'] = 'application/json'
        headers['Accept'] = 'application/json'
        headers['Accept-Encoding'] = 'identity'
        if(!conf.auth.isEmpty()){
            headers['Authorization'] = 'Bearer ' + conf.auth
        }
        headers
    }

    public static func parse(body: String): EmbeddingResp {
        let json = JsonValue.fromStr(body).asObject()
        let embedding = ArrayList<Float64>()
        if(let Some(rawData) <- json.get('data')){
            let items = rawData.asArray().getItems()
            if(items.size > 0){
                if(let Some(rawVector) <- items[0].asObject().get('embedding')){
                    for(value in rawVector.asArray().getItems()){
                        try{
                            embedding.add(Float64.parse(value.toString()))
                        }catch(_: Exception){
                            // 单个分量异常按 0 处理，长度保持不变
                            embedding.add(0.0f64)
                        }
                    }
                }
            }
        }
        if(embedding.isEmpty()){
            throw EmbeddingException('embedding response has no data[0].embedding')
        }
        let usage = TokenUsage()
        if(let Some(rawUsage) <- json.get('usage')){
            let usageObject = rawUsage.asObject()
            usage.prompt = embeddingIntOf(usageObject, 'prompt_tokens')
            usage.total = embeddingIntOf(usageObject, 'total_tokens')
        }
        EmbeddingResp(embedding: embedding.toArray(), usage: usage)
    }
}

func embeddingIntOf(obj: JsonObject, key: String): Int64 {
    if(let Some(value) <- obj.get(key)){
        Int64.tryParse(value.toString()) ?? 0
    }else{
        0
    }
}