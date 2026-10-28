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
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*

import fountain::f_llm.constant.*
import fountain::f_llm.model.po.*

func mkConf(url: String, auth: String): LLMConf {
    let c = LLMConf()
    c.provider = 'deepseek'
    c.llmName = 'chat-pro'
    c.actualLlmName = 'deepseek-chat'
    c.url = url
    c.auth = auth
    c
}

class FakeDialect <: ProviderDialect {
    FakeDialect(private let name: String){}
    public prop provider: String {
        get() {
            name
        }
    }
    public func endpoint(kind: LLMApiKind, conf: LLMConf): String {
        'https://fake.example/v1/chat'
    }
    public func headers(conf: LLMConf): HashMap<String, String> {
        HashMap<String, String>()
    }
    public func decorate(conf: LLMConf, body: JsonObject, mode: ThinkingMode): Unit {}
}

@Test
public class ProviderDialectTest {

    @TestCase
    func testEndpointJoinsBaseAndDefaultPath(): Unit {
        let dialect = StandardDialect()
        let conf = mkConf('https://api.deepseek.com/', 'sk-1')
        @Expect(dialect.endpoint(LLMApiKind.Chat, conf), 'https://api.deepseek.com/chat/completions')
        @Expect(dialect.endpoint(LLMApiKind.Responses, conf), 'https://api.deepseek.com/responses')
    }

    @TestCase
    func testEndpointOverrideByConf(): Unit {
        let dialect = StandardDialect()
        let conf = mkConf('https://api.deepseek.com', 'sk-1')
        conf.setConf(HashMap<String, String>([('chatPath', '/v1/chat/completions')]))
        @Expect(dialect.endpoint(LLMApiKind.Chat, conf), 'https://api.deepseek.com/v1/chat/completions')
    }

    @TestCase
    func testHeadersCarryBearer(): Unit {
        let dialect = StandardDialect()
        let headers = dialect.headers(mkConf('https://api.deepseek.com', 'sk-abc'))
        @Expect(headers.get('Authorization') ?? '', 'Bearer sk-abc')
        @Expect(headers.get('Content-Type') ?? '', 'application/json')
    }

    @TestCase
    func testHeadersWithoutAuth(): Unit {
        let dialect = StandardDialect()
        let headers = dialect.headers(mkConf('https://api.deepseek.com', ''))
        @Expect(headers.get('Authorization').isNone(), true)
    }

    @TestCase
    func testUnknownProviderFallsBack(): Unit {
        let dialect = DialectRegistry.resolve('provider-never-registered')
        @Expect(dialect.provider, 'openai')
    }

    @TestCase
    func testRegisterAndResolve(): Unit {
        DialectRegistry.register(FakeDialect('fake-a'))
        @Expect(DialectRegistry.resolve('fake-a').provider, 'fake-a')
        @Expect(DialectRegistry.get('fake-a').isSome(), true)
    }

    @TestCase
    func testDuplicateRegisterThrows(): Unit {
        DialectRegistry.register(FakeDialect('fake-dup'))
        var thrown = false
        try{
            DialectRegistry.register(FakeDialect('fake-dup'))
        }catch(e: IllegalArgumentException){
            thrown = true
        }
        @Expect(thrown, true)
    }
}
