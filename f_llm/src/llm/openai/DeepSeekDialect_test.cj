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

import fountain::f_llm.model.po.*

@Test
public class DeepSeekDialectTest {

    @TestCase
    func testChatEndpoint(): Unit {
        let dialect = DeepSeekDialect()
        let conf = mkConf('https://api.deepseek.com/', 'sk-1')
        @Expect(dialect.provider, 'deepseek')
        @Expect(dialect.endpoint(LLMApiKind.Chat, conf), 'https://api.deepseek.com/chat/completions')
    }

    @TestCase
    func testResponsesEndpoint(): Unit {
        // 实测（2026-10-28）：DeepSeek 有 `/responses`，且支持 input_image
        let dialect = DeepSeekDialect()
        let conf = mkConf('https://api.deepseek.com', 'sk-1')
        @Expect(dialect.endpoint(LLMApiKind.Responses, conf), 'https://api.deepseek.com/responses')
        conf.setConf(HashMap<String, String>([('responsesPath', '/v1/responses')]))
        @Expect(dialect.endpoint(LLMApiKind.Responses, conf), 'https://api.deepseek.com/v1/responses')
    }

    @TestCase
    func testAuthHeader(): Unit {
        let headers = DeepSeekDialect().headers(mkConf('https://api.deepseek.com', 'sk-abc'))
        @Expect(headers.get('Authorization') ?? '', 'Bearer sk-abc')
    }

    @TestCase
    func testDecorateRemovesThinking(): Unit {
        let body = JsonObject()
        body.add('thinking', 'enabled')
        body.add('model', 'deepseek-chat')
        DeepSeekDialect().decorate(mkConf('https://api.deepseek.com', 'sk'), body)
        @Expect(body.get('thinking').isNone(), true)
        @Expect(body.get('model')?.asString().value ?? '', 'deepseek-chat')
    }
}
