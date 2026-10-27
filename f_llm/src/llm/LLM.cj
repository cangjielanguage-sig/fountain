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
import std.sync.Mutex

import fountain::f_data.*

import fountain::f_llm.exception.*
import fountain::f_llm.llm.openai.*
import fountain::f_llm.model.po.*

/**
 * 门面：把「选平台 → 建报文 → 发请求 → 解析」串起来。
 *
 * 候选列表由调用方（中介者/编排层）给定，本类只负责：
 * - 按 `ProviderDialect` 拼端点与鉴权头；
 * - 可重试状态码（408/409/425/429/5xx）或传输异常 → 换下一个候选；
 * - 其余 4xx 立即抛出（换平台也一样错）；
 * - 全部候选失败 → 抛出最后一个异常，消息里带 `tried=[provider:model, ...]`。
 */
public class LLM {
    private static let mutex = Mutex()
    private static var transport: LLMTransport = DefaultHttpTransport()
    private static var streamTransport: LLMStreamTransport = DefaultStreamTransport()
    private static var counter: Int64 = 0

    /** 测试注入用；生产不调用 */
    public static func setStreamTransport(value: LLMStreamTransport): Unit {
        synchronized(mutex){
            streamTransport = value
        }
    }

    public static func getStreamTransport(): LLMStreamTransport {
        synchronized(mutex){
            streamTransport
        }
    }

    /** 测试注入用；生产不调用 */
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

    public static func chat(candidates: ArrayList<LLMConf>, params: LLMParams): LLMResp {
        call(LLMApiKind.Chat, candidates, params, LLMHooks())
    }

    public static func chat(candidates: ArrayList<LLMConf>, params: LLMParams, hooks: LLMHooks): LLMResp {
        call(LLMApiKind.Chat, candidates, params, hooks)
    }

    public static func respond(candidates: ArrayList<LLMConf>, params: LLMParams): LLMResp {
        call(LLMApiKind.Responses, candidates, params, LLMHooks())
    }

    public static func respond(candidates: ArrayList<LLMConf>, params: LLMParams, hooks: LLMHooks): LLMResp {
        call(LLMApiKind.Responses, candidates, params, hooks)
    }

    /**
     * 按 `llmName` 从全局快照里挑候选并发请求（生产的默认入口）。
     *
     * 选号、熔断、失败转移在这里串起来：候选按权重挑起点、跳过已熔断的，
     * 成功后清失败计数，可重试失败累加——编排层不用自己维护这些状态。
     */
    public static func chatByName(llmName: String, params: LLMParams): LLMResp {
        callByName(llmName, params, LLMApiKind.Chat)
    }

    public static func respondByName(llmName: String, params: LLMParams): LLMResp {
        callByName(llmName, params, LLMApiKind.Responses)
    }

    private static func callByName(llmName: String, params: LLMParams, kind: LLMApiKind): LLMResp {
        let holder = LLMConfs.holder()
        let available = ArrayList<LLMConf>()
        let all = holder.candidates(llmName)
        // 从权重命中的位置开始，绕一圈，尽量让被熔断的排到最后
        var startId: Int64 = -1
        if(let Some(start) <- holder.peekNext(llmName)){
            available.add(start)
            startId = start.id
        }
        for(conf in all){
            if(conf.id != startId && !holder.isCircuitOpen(conf.id)){
                available.add(conf)
            }
        }
        if(available.isEmpty()){
            throw LLMException('no available llm conf for: ${llmName}')
        }
        let hooks = LLMHooks(
            onSuccess: {id => holder.recordSuccess(id)},
            onRetryableFailure: {id => holder.recordRetryableFailure(id)}
        )
        call(kind, available, params, hooks)
    }

    private static func call(kind: LLMApiKind, candidates: ArrayList<LLMConf>, params: LLMParams, hooks: LLMHooks): LLMResp {
        let tried = ArrayList<String>()
        var lastError: ?LLMException = None<LLMException>
        for(conf in candidates){
            let dialect = DialectRegistry.resolve(conf.provider)
            tried.add('${conf.provider}:${conf.actualLlmName}')
            let body = match(kind){
                case LLMApiKind.Chat => ChatCompletionsMapper.build(conf, params, false)
                case LLMApiKind.Responses => ResponsesMapper.build(conf, params, false)
            }
            dialect.decorate(conf, body)

            var response = LLMHttpResponse(0, '')
            try{
                response = getTransport().post(dialect.endpoint(kind, conf), dialect.headers(conf), body.toString())
            }catch(e: Exception){
                hooks.onRetryableFailure(conf.id)
                lastError = LLMException('llm transport failed, provider: ${conf.provider}, model: ${conf.actualLlmName}', e)
                continue
            }

            if(response.status >= 400){
                // 把上游错误体带进异常：400 的 body 才说得清是哪个参数不对
                let error = LLMException('llm call failed, provider: ${conf.provider}, model: ${conf.actualLlmName}, status: ${response.status}, body: ${previewOf(response.body)}')
                if(LLMErrorClassifier.isRetryable(response.status)){
                    hooks.onRetryableFailure(conf.id)
                    lastError = error
                    continue
                }
                throw error
            }

            let json = JsonValue.fromStr(response.body).asObject()
            let result = match(kind){
                case LLMApiKind.Chat => ChatCompletionsMapper.parse(json)
                case LLMApiKind.Responses => ResponsesMapper.parse(json)
            }
            result.usage.llmId = conf.id
            hooks.onSuccess(conf.id)
            return result
        }
        let details = StringBuilder()
        for(item in tried){
            if(details.size > 0){
                details.append(', ')
            }
            details.append(item)
        }
        if(let Some(error) <- lastError){
            throw error
        }
        throw LLMException('no llm candidate available, tried: [${details}]')
    }

    public static func chatStream(
        candidates: ArrayList<LLMConf>,
        params: LLMParams,
        onDelta: (LLMDelta) -> Unit
    ): LLMResp {
        stream(LLMApiKind.Chat, candidates, params, onDelta)
    }

    public static func respondStream(
        candidates: ArrayList<LLMConf>,
        params: LLMParams,
        onDelta: (LLMDelta) -> Unit
    ): LLMResp {
        stream(LLMApiKind.Responses, candidates, params, onDelta)
    }

    /**
     * 流式公共流程：与非流式共用「按候选转移、4xx 立即失败」的规则。
     *
     * 中途异常（连接断、`SseTimeoutException`）包成 `LLMException` 并带 `requestId` 与阶段信息，
     * 便于在日志里把「哪次请求、哪个平台、哪一步坏了」对上。
     */
    private static func stream(
        kind: LLMApiKind,
        candidates: ArrayList<LLMConf>,
        params: LLMParams,
        onDelta: (LLMDelta) -> Unit
    ): LLMResp {
        let requestId = nextRequestId()
        let tried = ArrayList<String>()
        var lastError: ?LLMException = None<LLMException>
        for(conf in candidates){
            let dialect = DialectRegistry.resolve(conf.provider)
            tried.add('${conf.provider}:${conf.actualLlmName}')
            let body = match(kind){
                case LLMApiKind.Chat => ChatCompletionsMapper.build(conf, params, true)
                case LLMApiKind.Responses => ResponsesMapper.build(conf, params, true)
            }
            dialect.decorate(conf, body)

            let chatAccumulator = ChatStreamAccumulator()
            let responsesAccumulator = ResponsesStreamAccumulator()
            var status = 0
            try{
                status = getStreamTransport().stream(
                    dialect.endpoint(kind, conf),
                    dialect.headers(conf),
                    body.toString()
                ){data =>
                    match(kind){
                        case LLMApiKind.Chat =>
                            if(let Some(delta) <- chatAccumulator.feed(data)){
                                onDelta(delta)
                            }
                        case LLMApiKind.Responses =>
                            if(let Some(delta) <- responsesAccumulator.feed(data)){
                                onDelta(delta)
                            }
                    }
                }
            }catch(e: Exception){
                lastError = LLMException(
                    'llm stream failed, requestId: ${requestId}, phase: read, provider: ${conf.provider}, model: ${conf.actualLlmName}',
                    e
                )
                continue
            }

            if(status >= 400){
                let error = LLMException(
                    'llm stream failed, requestId: ${requestId}, phase: connect, provider: ${conf.provider}, model: ${conf.actualLlmName}, status: ${status}'
                )
                if(LLMErrorClassifier.isRetryable(status)){
                    lastError = error
                    continue
                }
                throw error
            }

            let result = match(kind){
                case LLMApiKind.Chat => chatAccumulator.result()
                case LLMApiKind.Responses => responsesAccumulator.result()
            }
            result.usage.llmId = conf.id
            return result
        }
        if(let Some(error) <- lastError){
            throw error
        }
        let details = StringBuilder()
        for(item in tried){
            if(details.size > 0){
                details.append(', ')
            }
            details.append(item)
        }
        throw LLMException('no llm candidate available, requestId: ${requestId}, tried: [${details}]')
    }

    /** 错误体预览：只留前 400 字节，避免异常消息过长 */
    private static func previewOf(body: String): String {
        if(body.size <= 400){
            return body
        }
        body[0 .. 400] + '...'
    }

    private static func nextRequestId(): String {
        synchronized(mutex){
            counter++
            'llm-${counter}'
        }
    }
}
