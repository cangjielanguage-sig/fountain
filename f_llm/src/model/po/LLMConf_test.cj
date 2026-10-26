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
package fountain::f_llm.model.po

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class LLMConfTest {

    @TestCase
    func testFieldsAndOptionAccessors(): Unit {
        let conf = LLMConf()
        conf.provider = 'deepseek'
        conf.llmName = 'chat-pro'
        conf.actualLlmName = 'deepseek-chat'
        conf.url = 'https://api.deepseek.com'
        conf.auth = 'sk-test'
        conf.temperature = 0.3f64
        conf.alwaysThinking = true
        conf.enabled = true
        conf.weight = 3
        conf.setConf(HashMap<String, String>([('tokenThreshold', '80000'), ('thinking', 'toggle'), ('stream', 'false')]))

        @Expect(conf.provider, 'deepseek')
        @Expect(conf.llmName, 'chat-pro')
        @Expect(conf.actualLlmName, 'deepseek-chat')
        @Expect(conf.temperature, 0.3f64)
        @Expect(conf.alwaysThinking, true)
        @Expect(conf.weight, 3)
        @Expect(conf.option('thinking') ?? '', 'toggle')
        @Expect(conf.optionInt('tokenThreshold', 0), 80000)
        @Expect(conf.optionInt('missing', 7), 7)
        @Expect(conf.tokenThreshold, 80000)
        @Expect(conf.streamable, false)
        @Expect(conf.isPlaceholder, false)
    }

    @TestCase
    func testPlaceholderWhenRequiredFieldMissing(): Unit {
        let conf = LLMConf()
        conf.provider = 'deepseek'
        conf.llmName = 'chat-pro'
        conf.actualLlmName = 'deepseek-chat'
        @Expect(conf.isPlaceholder, true)
    }

    @TestCase
    func testCodecRoundTrip(): Unit {
        let conf = HashMap<String, String>([('tokenThreshold', '80000'), ('note', '中文\"引号\"')])
        let text = LLMConfCodec.toColumn(conf)
        let back = LLMConfCodec.fromColumn(text)
        @Expect(back.get('tokenThreshold') ?? '', '80000')
        @Expect(back.get('note') ?? '', '中文\"引号\"')
    }

    @TestCase
    func testCodecEmptyAndInvalid(): Unit {
        @Expect(LLMConfCodec.fromColumn('').size, 0)
        @Expect(LLMConfCodec.fromColumn('   ').size, 0)
        @Expect(LLMConfCodec.fromColumn('not-json').size, 0)
    }
}
