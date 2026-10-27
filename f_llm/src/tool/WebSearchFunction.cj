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
package fountain::f_llm.tool

import std.collection.ArrayList

import fountain::f_bean.macros.*
import fountain::f_data.*
import fountain::f_data.macros.*

import fountain::f_llm.config.*
import fountain::f_llm.llm.*
import fountain::f_llm.model.po.*
import fountain::f_llm.search.*

@DataAssist[props fields]
public class WebSearchParams {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'查询关键词，支持 site: / -site: / 引号等语法']
    private var query: String = ''
    @JsonStringSchema[description:'返回条数，1~50，默认 10']
    private var count: Int64 = 10
    @JsonStringSchema[description:'强制指定平台（如 zhipu / deepseek）；空串表示自动选择']
    private var provider: String = ''
    @JsonStringSchema[description:'是否返回网页正文（体积大），默认 false']
    private var needContent: Bool = false
}

/**
 * 内置函数：联网搜索。
 *
 * 凭据不单独配置——从**任意一条可用 LLMConf** 里借，平台必须已注册 `SearchProvider`。
 * 一条都没有时抛 `SearchUnavailableException`（框架没能力跑这个工具），
 * 不返回「搜索失败」的假文本让模型继续编。
 */
@Bean
public class WebSearchFunction <: FunctionCalling<WebSearchParams> {
    public prop name: String {
        get() {
            'webSearch'
        }
    }

    public prop description: String {
        get() {
            '联网搜索，返回标题、摘要与链接；只在确实需要外部事实时调用。需要正文时把 needContent 设为 true'
        }
    }

    public func call(params: WebSearchParams): FunctionResult {
        let conf = pickConf(params.provider, params.needContent)
        let provider = SearchProviderRegistry.get(conf.provider).getOrThrow()
        let items = provider.search(conf, params.query, params.count, params.needContent)
        FunctionResult(event: params.nextEvent, result: normalize(items, LLMConfig.getToolResultMaxBytes()))
    }
}

/** 取一条可用配置；显式指定 provider 时**不跨平台回退**（否则来源不可追溯） */
func pickConf(provider: String, needFetch: Bool): LLMConf {
    var candidates = LLMCandidateProvider.candidates().filter{conf =>
        match(SearchProviderRegistry.get(conf.provider)){
            case Some(providerImpl) =>
                if(needFetch){
                    !providerImpl.fetchEndpoint.isEmpty()
                }else{
                    true
                }
            case None => false
        }
    }
    if(!provider.isEmpty()){
        candidates = candidates.filter{conf => conf.provider == provider}
    }
    if(candidates.isEmpty()){
        throw SearchUnavailableException(
            'no llm conf available for search, provider: ${provider}, registered: ${SearchProviderRegistry.names()}'
        )
    }
    candidates[0]
}

/** 归一成 JSON 数组文本；按字节预算**整条**追加，超预算即停并标注，避免把 UTF-8 截断 */
public func normalize(items: ArrayList<SearchResultItem>, maxBytes: Int64): String {
    let builder = StringBuilder()
    var truncated = false
    for(item in items){
        let obj = JsonObject()
        obj.add('title', item.title)
        obj.add('url', item.url)
        obj.add('summary', item.summary)
        if(!item.date.isEmpty()){
            obj.add('date', item.date)
        }
        obj.add('score', item.score)
        let piece = obj.toString()
        if(builder.size + piece.size + 2 > maxBytes){
            truncated = true
            break
        }
        if(builder.size > 0){
            builder.append(',')
        }
        builder.append(piece)
    }
    let body = '[' + builder.toString() + ']'
    if(truncated){
        body + '\n[已截断]'
    }else{
        body
    }
}
