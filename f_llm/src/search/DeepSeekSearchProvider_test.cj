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
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.model.po.*

// 取自 2026-10-27 实测响应（裁剪到关键字段）
let SEARCH_JSON = '''
{
  "results": [
    {
      "title": "仓颉编程语言官网",
      "site_name": "cangjie-lang.cn",
      "url": "https://cangjie-lang.cn/",
      "date": "2026-10-09T16:00:00+00:00",
      "summary": "整页正文（很长）",
      "snippet": "云化场景微服务框架……",
      "content": "",
      "rerank_score": 2.289104461669922,
      "authority": 3
    },
    {
      "title": "仓颉用户手册",
      "url": "http://docs.cangjie-lang.cn/cjnative/print.html",
      "date": "2024-09-26T16:00:00+00:00",
      "summary": "只有 summary 的条目",
      "rerank_score": 2.148479461669922
    }
  ]
}'''

let SEARCH_WITH_CONTENT_JSON = '''
{"results":[{"title":"T","url":"https://a.example","snippet":"短摘要","content":"正文全文","rerank_score":1.5}]}'''

let FETCH_JSON = '''
{"content":"该域名仅用于文档示例。\\nLearn more","title":"Example Domain"}'''

class FakePoster {
    FakePoster(private let response: String){}
    var calls: Int64 = 0
    var lastUrl: String = ''
    var lastBody: String = ''
    var lastAuth: String = ''
    public func post(url: String, headers: HashMap<String, String>, body: String): String {
        calls++
        lastUrl = url
        lastBody = body
        lastAuth = headers.get('Authorization') ?? ''
        response
    }
}

func searchConf(): LLMConf {
    let conf = LLMConf()
    conf.id = 5
    conf.provider = 'deepseek'
    conf.llmName = 'search-pro'
    conf.actualLlmName = 'deepseek-flash'
    conf.url = 'https://api.deepseek.com'
    conf.auth = 'sk-test'
    conf
}

@Test
public class DeepSeekSearchProviderTest {

    @TestCase
    func testParseSearchPrefersSnippet(): Unit {
        let items = parseDeepSeekSearch(SEARCH_JSON, false)
        @Expect(items.size, 2)
        @Expect(items[0].title, '仓颉编程语言官网')
        @Expect(items[0].url, 'https://cangjie-lang.cn/')
        @Expect(items[0].summary, '云化场景微服务框架……')
        @Expect(items[0].score > 2.0f64, true)
        @Expect(items[0].date, '2026-10-09T16:00:00+00:00')
        // 没有 snippet 的条目回退到 summary
        @Expect(items[1].summary, '只有 summary 的条目')
    }

    @TestCase
    func testParseSearchUsesContentWhenRequested(): Unit {
        let withContent = parseDeepSeekSearch(SEARCH_WITH_CONTENT_JSON, true)
        @Expect(withContent[0].summary, '正文全文')
        let withoutContent = parseDeepSeekSearch(SEARCH_WITH_CONTENT_JSON, false)
        @Expect(withoutContent[0].summary, '短摘要')
    }

    @TestCase
    func testParseFetch(): Unit {
        let page = parseDeepSeekFetch(FETCH_JSON)
        @Expect(page.title, 'Example Domain')
        @Expect(page.content.startsWith('该域名仅用于文档示例'), true)
    }

    @TestCase
    func testSearchRequestShape(): Unit {
        let poster = FakePoster(SEARCH_JSON)
        let provider = DeepSeekSearchProvider(poster: {url, headers, body => poster.post(url, headers, body)})
        let items = provider.search(searchConf(), '仓颉', 3, false)
        @Expect(items.size, 2)
        @Expect(provider.searchEndpoint, 'https://api.deepseek.com/v1/tools/search')
        @Expect(poster.lastUrl, 'https://api.deepseek.com/v1/tools/search')
        @Expect(poster.lastAuth, 'Bearer sk-test')
        @Expect(poster.lastBody.contains('"query":"仓颉"'), true)
        @Expect(poster.lastBody.contains('"count":3'), true)
        @Expect(poster.lastBody.contains('"need_content":false'), true)
    }

    @TestCase
    func testSearchUrlOverride(): Unit {
        let poster = FakePoster(SEARCH_JSON)
        let provider = DeepSeekSearchProvider(poster: {url, headers, body => poster.post(url, headers, body)})
        let conf = searchConf()
        conf.setConf(HashMap<String, String>([('searchUrl', 'https://proxy.example/search')]))
        provider.search(conf, 'x', 1, false)
        @Expect(poster.lastUrl, 'https://proxy.example/search')
    }

    @TestCase
    func testFetchRequestShape(): Unit {
        let poster = FakePoster(FETCH_JSON)
        let provider = DeepSeekSearchProvider(poster: {url, headers, body => poster.post(url, headers, body)})
        let page = provider.fetch(searchConf(), 'https://example.com')
        @Expect(page.title, 'Example Domain')
        @Expect(provider.fetchEndpoint, 'https://api.deepseek.com/v1/tools/fetch')
        @Expect(poster.lastBody.contains('"url":"https://example.com"'), true)
    }
}
