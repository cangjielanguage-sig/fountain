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

import fountain::f_bean.macros.*
import fountain::f_data.macros.*

import fountain::f_llm.config.*
import fountain::f_llm.search.*

@DataAssist[props fields]
public class WebFetchParams {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'要抓取的网页地址，必须是 http/https 且指向公网']
    private var url: String = ''
    @JsonStringSchema[description:'强制指定平台；空串表示自动选择支持抓取的平台']
    private var provider: String = ''
}

/**
 * 内置函数：抓取单个网页正文。
 *
 * 与搜索的分工：搜索给「有哪些页面」，`webFetch` 给「这个页面写了什么」。
 * 模型能指定任意 URL，所以**先过 `SsrfGuard` 再发请求**——顺序不能反。
 */
@Bean
public class WebFetchFunction <: FunctionCalling<WebFetchParams> {
    public prop name: String {
        get() {
            'webFetch'
        }
    }

    public prop description: String {
        get() {
            '抓取单个网页并返回 Markdown 正文，用于已知 URL 需要读全文的场景；不要用它做探测'
        }
    }

    public func call(params: WebFetchParams): FunctionResult {
        SsrfGuard.check(params.url)
        let conf = pickConf(params.provider, true)
        let provider = SearchProviderRegistry.get(conf.provider).getOrThrow()
        let page = provider.fetch(conf, params.url)
        FunctionResult(event: params.nextEvent, result: renderPage(page, LLMConfig.getFetchMaxBytes()))
    }
}

/** 标题 + 正文；正文按字节预算截断在字符边界上，并标注 `[已截断]` */
public func renderPage(page: FetchedPage, maxBytes: Int64): String {
    let title = page.title
    let head = if(title.isEmpty()){ '' }else{ '# ${title}\n\n' }
    let budget = if(maxBytes > head.size){ maxBytes - head.size }else{ 0 }
    let content = truncateBytes(page.content, budget)
    if(content.size < page.content.size){
        head + content + '\n[已截断]'
    }else{
        head + content
    }
}

func truncateBytes(text: String, limit: Int64): String {
    if(limit <= 0){
        return ''
    }
    if(text.size <= limit){
        return text
    }
    let builder = StringBuilder()
    var used = 0
    for(rune in text.runes()){
        let piece = rune.toString()
        if(used + piece.size > limit){
            break
        }
        builder.append(rune)
        used += piece.size
    }
    builder.toString()
}
