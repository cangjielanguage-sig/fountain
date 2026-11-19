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
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*

import fountain::f_llm.exception.*
import fountain::f_llm.llm.*
import fountain::f_llm.model.po.*
import fountain::f_llm.search.*

class CountingFetchProvider <: SearchProvider {
    CountingFetchProvider(private let name: String, private let body: String){}
    var fetchCalls: Int64 = 0
    public prop provider: String {
        get() {
            name
        }
    }
    public prop searchEndpoint: String {
        get() {
            'https://fake.example/search'
        }
    }
    public prop fetchEndpoint: String {
        get() {
            'https://fake.example/fetch'
        }
    }
    public func search(conf: LLMConf, query: String, count: Int64, needContent: Bool): ArrayList<SearchResultItem> {
        ArrayList<SearchResultItem>()
    }
    public func fetch(conf: LLMConf, url: String): FetchedPage {
        fetchCalls++
        FetchedPage(title: 'T', content: '${body} from ${url}')
    }
}

func fetchConf(provider: String): LLMConf {
    let conf = LLMConf()
    conf.id = 12
    conf.provider = provider
    conf.llmName = 'chat-pro'
    conf.actualLlmName = 'model'
    conf.url = 'https://api.example'
    conf.auth = 'sk'
    conf
}

func registerFetchProvider(provider: SearchProvider): Unit {
    try{
        SearchProviderRegistry.register(provider)
    }catch(_: Exception){}
}

func assertRejected(url: String): Bool {
    try{
        SsrfGuard.check(url)
        // 没抛异常说明放行了
        false
    }catch(_: FetchRejectedException){
        true
    }
}

@Test
public class WebFetchTest {

    @TestCase
    func testBlocksPrivateAddresses(): Unit {
        @Expect(assertRejected('http://127.0.0.1/a'), true)
        @Expect(assertRejected('http://10.1.2.3/a'), true)
        @Expect(assertRejected('http://172.16.0.9/a'), true)
        @Expect(assertRejected('http://192.168.1.1/a'), true)
        @Expect(assertRejected('http://169.254.169.254/latest/meta-data'), true)
        @Expect(assertRejected('http://localhost:8080/a'), true)
        @Expect(assertRejected('http://[::1]/a'), true)
        @Expect(assertRejected('http://2130706433/a'), true)
        @Expect(assertRejected('http://0.0.0.0/a'), true)
    }

    @TestCase
    func testBlocksNonHttpSchemes(): Unit {
        @Expect(assertRejected('file:///etc/passwd'), true)
        @Expect(assertRejected('ftp://example.com/x'), true)
        @Expect(assertRejected('gopher://example.com/x'), true)
    }

    @TestCase
    func testAllowsPublicUrls(): Unit {
        SsrfGuard.check('https://api.deepseek.com/v1/chat')
        SsrfGuard.check('http://example.com/a?b=1')
        SsrfGuard.check('https://user:pass@example.com/x')
        @Expect(SsrfGuard.hostOf('https://example.com:8443/a'), 'example.com')
    }

    @TestCase
    func testFetchSuccess(): Unit {
        registerFetchProvider(CountingFetchProvider('fake-fetch', 'hello body'))
        LLMCandidateProvider.setSupplier({=> ArrayList<LLMConf>([fetchConf('fake-fetch')])})
        let params = WebFetchParams()
        params.nextEvent = 'next'
        params.url = 'https://example.com/doc'
        let result = WebFetchFunction().call(params)
        let text = match(result.result){
            case json: JsonString => json.value
            case _ => ''
        }
        @Expect(text.contains('hello body'), true)
        @Expect(text.contains('# T'), true)
    }

    @TestCase
    func testRejectedBeforeCallingProvider(): Unit {
        let provider = CountingFetchProvider('fake-fetch-guard', 'never')
        registerFetchProvider(provider)
        LLMCandidateProvider.setSupplier({=> ArrayList<LLMConf>([fetchConf('fake-fetch-guard')])})
        var thrown = false
        try{
            let params = WebFetchParams()
            params.nextEvent = 'next'
            params.url = 'http://169.254.169.254/latest/meta-data'
            WebFetchFunction().call(params)
        }catch(_: FetchRejectedException){
            thrown = true
        }
        @Expect(thrown, true)
        @Expect(provider.fetchCalls, 0)
    }

    @TestCase
    func testRenderTruncatesOnCharBoundary(): Unit {
        let long = StringBuilder()
        for(_ in 0 .. 200){
            long.append('中文内容')
        }
        let page = FetchedPage(title: 'T', content: long.toString())
        let text = renderPage(page, 400)
        @Expect(text.contains('[已截断]'), true)
        @Expect(text.size < 500, true)
    }

    @TestCase
    func testToolNameRules(): Unit {
        ToolName.validate('currentTime')
        ToolName.validate('mcp__fs__read_file')
        @Expect(ToolName.mcp('fs', 'read file'), 'mcp__fs__read_file')
        var bad = false
        try{
            ToolName.validate('bad name!')
        }catch(_: FunctionCallingException){
            bad = true
        }
        @Expect(bad, true)
        var tooLong = false
        try{
            ToolName.mcp('a-very-long-alias-name-that-eats-the-budget', 'another-very-long-tool-name-here')
        }catch(_: FunctionCallingException){
            tooLong = true
        }
        @Expect(tooLong, true)
    }
}
