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
import fountain::f_data.macros.*

import fountain::f_llm.exception.*
import fountain::f_llm.llm.*
import fountain::f_llm.model.po.*
import fountain::f_llm.search.*

@DataAssist[props fields]
class EchoParams {
    private var nextEvent: String = ''
}

class EchoFunction <: FunctionCalling<EchoParams> {
    public prop name: String {
        get() {
            'echoTest'
        }
    }
    public prop description: String {
        get() {
            'echo for test'
        }
    }
    public func call(params: EchoParams): FunctionResult {
        FunctionResult(event: 'next', result: 'ok')
    }
}

class FakeSearchProvider <: SearchProvider {
    FakeSearchProvider(private let name: String, private let withFetch: Bool){}
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
            if(withFetch){ 'https://fake.example/fetch' }else{ '' }
        }
    }
    public func search(conf: LLMConf, query: String, count: Int64, needContent: Bool): ArrayList<SearchResultItem> {
        ArrayList<SearchResultItem>([
            SearchResultItem(title: 'T1', url: 'https://a.example', summary: 'S1 ${query}', date: '2026-10-27', score: 1.5f64)
        ])
    }
    public func fetch(conf: LLMConf, url: String): FetchedPage {
        FetchedPage(title: 'page', content: 'body of ${url}')
    }
}

func searchConf(provider: String): LLMConf {
    let conf = LLMConf()
    conf.id = 9
    conf.provider = provider
    conf.llmName = 'chat-pro'
    conf.actualLlmName = 'model'
    conf.url = 'https://api.example'
    conf.auth = 'sk'
    conf
}

/** FunctionResult.result 里装的是 JsonString，取正文要拆一层 */
func textOf(result: FunctionResult): String {
    match(result.result){
        case text: JsonString => text.value
        case text: String => text
        case _ => ''
    }
}

func registerQuietly(calling: CommonFunctionCalling): Unit {
    try{
        FunctionMediator.register(calling)
    }catch(_: Exception){}
}

func registerSearchQuietly(provider: SearchProvider): Unit {
    try{
        SearchProviderRegistry.register(provider)
    }catch(_: Exception){}
}

@Test
public class ToolFunctionsTest {

    @TestCase
    func testRegisterAndCall(): Unit {
        FunctionMediator.register(EchoFunction())
        let definitions = ArrayList<FunctionCall>()
        for(call in FunctionMediator.getDefinitions(['echoTest'])){
            definitions.add(call)
        }
        @Expect(definitions.size, 1)
        let definition = FunctionMediator.definition('echoTest')
        @Expect(definition.get('function')?.asObject().get('name')?.asString().value ?? '', 'echoTest')
        @Expect(FunctionMediator.call('echoTest', JsonObject()).event, 'next')
    }

    @TestCase
    func testDuplicateRegisterFails(): Unit {
        registerQuietly(EchoFunction())
        var thrown = false
        try{
            FunctionMediator.register(EchoFunction())
        }catch(e: FunctionCallingException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testUnknownFunctionFails(): Unit {
        registerQuietly(EchoFunction())
        var thrown = false
        try{
            FunctionMediator.call('not-registered', JsonObject())
        }catch(e: FunctionNotFoundException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testCurrentTimeIsoAndEpoch(): Unit {
        let function = CurrentTimeFunction()
        let params = CurrentTimeParams()
        params.nextEvent = 'next'
        let iso = textOf(function.call(params))
        @Expect(iso.size > 10, true)
        params.format = 'epoch'
        let epoch = textOf(function.call(params))
        @Expect(Int64.tryParse(epoch).isSome(), true)
    }

    @TestCase
    func testCurrentTimeUnsupportedTimezoneReturnsText(): Unit {
        let function = CurrentTimeFunction()
        let params = CurrentTimeParams()
        params.nextEvent = 'next'
        params.timezone = 'Mars/Base'
        let text = textOf(function.call(params))
        @Expect(text.contains('unsupported timezone'), true)
    }

    @TestCase
    func testWebSearchUsesRegisteredProvider(): Unit {
        registerSearchQuietly(FakeSearchProvider('fake-search', true))
        LLMCandidateProvider.setSupplier({=> ArrayList<LLMConf>([searchConf('fake-search')])})
        let function = WebSearchFunction()
        let params = WebSearchParams()
        params.nextEvent = 'next'
        params.query = '仓颉'
        let text = textOf(function.call(params))
        @Expect(text.contains('T1'), true)
        @Expect(text.contains('S1 仓颉'), true)
    }

    @TestCase
    func testWebSearchWithoutConfThrows(): Unit {
        registerSearchQuietly(FakeSearchProvider('fake-empty', true))
        LLMCandidateProvider.setSupplier({=> ArrayList<LLMConf>()})
        var thrown = false
        try{
            let params = WebSearchParams()
            params.nextEvent = 'next'
            params.query = 'x'
            WebSearchFunction().call(params)
        }catch(e: SearchUnavailableException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testWebSearchNoProviderFallback(): Unit {
        registerSearchQuietly(FakeSearchProvider('fake-a', true))
        LLMCandidateProvider.setSupplier({=> ArrayList<LLMConf>([searchConf('fake-a')])})
        var thrown = false
        try{
            let params = WebSearchParams()
            params.nextEvent = 'next'
            params.query = 'x'
            params.provider = 'fake-b'
            WebSearchFunction().call(params)
        }catch(e: SearchUnavailableException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testNormalizeTruncatesByWholeItem(): Unit {
        let items = ArrayList<SearchResultItem>()
        for(_ in 0 .. 10){
            items.add(SearchResultItem(title: 'T', url: 'https://a.example', summary: 'S', date: '', score: 1.0f64))
        }
        let full = normalize(items, 100000)
        @Expect(JsonValue.fromStr(full).asArray().getItems().size, 10)
        let cut = normalize(items, 120)
        @Expect(cut.contains('[已截断]'), true)
        let body = cut.split('\n')[0]
        @Expect(JsonValue.fromStr(body).asArray().getItems().size < 10, true)
    }
}
