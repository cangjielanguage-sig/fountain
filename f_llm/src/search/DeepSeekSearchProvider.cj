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
package fountain::f_llm.search

import std.collection.{ArrayList, HashMap}
import stdx.net.tls.common.*

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_data.*
import fountain::f_httpclient.*

import fountain::f_llm.model.po.*

/**
 * 一次 POST 的抽象：返回 `(状态码, 响应体)`。
 *
 * 必须带状态码：抓取要**拒绝所有 3xx**（不跟随跳转），否则公网地址可以用 302
 * 把请求引到内网，`SsrfGuard` 只校验入口 URL 就会失效。
 */
public type SearchPoster = (String, HashMap<String, String>, String) -> (Int64, String)

func defaultSearchPost(url: String, headers: HashMap<String, String>, body: String): (Int64, String) {
    let client = HttpClient(url)
    for((key, value) in headers){
        client.header(key, value)
    }
    // 不跟随重定向：跳转目标没有经过 SSRF 校验
    client.autoRedirect(false)
    var tls = TlsClientConfig()
    tls.verifyMode = CertificateVerifyMode.TrustAll
    client.tlsConfig(tls)
    resource(client){http =>
        let response = http.post(body)
        (Int64(response.status), response.readEntire())
    }
}

/** 3xx 一律拒绝（跳转目标未经 SSRF 校验），4xx/5xx 直接失败并带状态码 */
func ensureOk(status: Int64, action: String, url: String): Unit {
    if(status >= 300 && status < 400){
        throw SearchHttpException('${action} refused redirect (${status}): ${url}')
    }
    if(status >= 400){
        throw SearchHttpException('${action} failed (${status}): ${url}')
    }
}

/**
 * DeepSeek 的搜索与抓取。
 *
 * 实测契约（2026-10-27）：
 * - `POST /v1/tools/search`，入参 `{query, count, need_content}`，
 *   响应 `{"results":[{title, site_name, url, date, summary, snippet, content, rerank_score, authority}]}`；
 * - `POST /v1/tools/fetch`，入参 `{url}`，响应 `{"title","content"}`。
 *
 * 各字段取舍：`snippet` 是摘要、`content` 是正文（仅 `need_content=true` 时非空）、
 * `summary` 可能是整页正文（实测会出现），所以**优先 snippet，其次 content，最后才用 summary**。
 */
@Bean
public class DeepSeekSearchProvider <: SearchProvider {
    private let poster: SearchPoster

    public init(poster!: SearchPoster = defaultSearchPost) {
        this.poster = poster
    }

    public prop provider: String {
        get() {
            'deepseek'
        }
    }

    public prop searchEndpoint: String {
        get() {
            'https://api.deepseek.com/v1/tools/search'
        }
    }

    public prop fetchEndpoint: String {
        get() {
            'https://api.deepseek.com/v1/tools/fetch'
        }
    }

    public func search(conf: LLMConf, query: String, count: Int64, needContent: Bool): ArrayList<SearchResultItem> {
        let url = conf.option('searchUrl', searchEndpoint)
        let body = JsonObject()
        body.add('query', query)
        body.add('count', count)
        body.add('need_content', needContent)
        let (status, response) = poster(url, headersOf(conf), body.toString())
        ensureOk(status, 'search', url)
        parseDeepSeekSearch(response, needContent)
    }

    public func fetch(conf: LLMConf, url: String): FetchedPage {
        let endpoint = conf.option('fetchUrl', fetchEndpoint)
        let body = JsonObject()
        body.add('url', url)
        let (status, response) = poster(endpoint, headersOf(conf), body.toString())
        ensureOk(status, 'fetch', url)
        parseDeepSeekFetch(response)
    }
}

func headersOf(conf: LLMConf): HashMap<String, String> {
    let headers = HashMap<String, String>()
    headers['Content-Type'] = 'application/json'
    headers['Authorization'] = 'Bearer ${conf.auth}'
    // 响应体不走 gzip：HttpClient 不会自动解压（实测 DeepSeek 搜索接口默认会压）
    headers['Accept-Encoding'] = 'identity'
    headers
}

/** 结果归一：字段一律走 `textOf`，避免 JSON null 直接 asString 抛异常 */
public func parseDeepSeekSearch(body: String, needContent: Bool): ArrayList<SearchResultItem> {
    let items = ArrayList<SearchResultItem>()
    let json = JsonValue.fromStr(body).asObject()
    if(let Some(rawResults) <- json.get('results')){
        for(element in rawResults.asArray().getItems()){
            let obj = element.asObject()
            let summary = searchSummaryOf(obj, needContent)
            items.add(SearchResultItem(
                title: searchTextOf(obj, 'title'),
                url: searchTextOf(obj, 'url'),
                summary: summary,
                date: searchTextOf(obj, 'date'),
                score: searchScoreOf(obj)
            ))
        }
    }
    items
}

func searchSummaryOf(obj: JsonObject, needContent: Bool): String {
    if(needContent){
        let content = searchTextOf(obj, 'content')
        if(!content.isEmpty()){
            return content
        }
    }
    let snippet = searchTextOf(obj, 'snippet')
    if(!snippet.isEmpty()){
        return snippet
    }
    searchTextOf(obj, 'summary')
}

func searchTextOf(obj: JsonObject, key: String): String {
    if(let Some(value) <- obj.get(key)){
        match(value){
            case _: JsonNull => ''
            case _ => value.asString().value
        }
    }else{
        ''
    }
}

func searchScoreOf(obj: JsonObject): Float64 {
    if(let Some(value) <- obj.get('rerank_score')){
        try{
            Float64.parse(value.toString())
        }catch(_: Exception){
            0.0f64
        }
    }else{
        0.0f64
    }
}

public func parseDeepSeekFetch(body: String): FetchedPage {
    let json = JsonValue.fromStr(body).asObject()
    FetchedPage(title: searchTextOf(json, 'title'), content: searchTextOf(json, 'content'))
}
