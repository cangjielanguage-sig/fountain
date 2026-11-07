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
package fountain::f_llm.service

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.model.po.*

let SAMPLE_CONF_JSON = '''
[
  {
    "provider": "deepseek",
    "llmName": "chat-pro",
    "actualLlmName": "deepseek-chat",
    "url": "https://api.deepseek.com",
    "auth": "sk-1",
    "temperature": 0.3,
    "alwaysThinking": false,
    "enabled": true,
    "weight": 3,
    "conf": {"tokenThreshold": "80000", "thinking": "toggle"}
  },
  {
    "provider": "zhipu",
    "llmName": "chat-pro",
    "actualLlmName": "glm-5",
    "url": "https://open.bigmodel.cn/api/paas/v4",
    "auth": "zp-1",
    "temperature": -1,
    "alwaysThinking": true,
    "enabled": true,
    "weight": 1,
    "conf": {"searchEngine": "search_pro"}
  }
]'''

@Test
public class LLMConfSourceTest {

    @TestCase
    func testParseFileJson(): Unit {
        let confs = parseConfJson(SAMPLE_CONF_JSON)
        @Expect(confs.size, 2)
        @Expect(confs[0].provider, 'deepseek')
        @Expect(confs[0].llmName, 'chat-pro')
        @Expect(confs[0].actualLlmName, 'deepseek-chat')
        @Expect(confs[0].temperature, 0.3f64)
        @Expect(confs[0].weight, 3)
        @Expect(confs[0].conf.get('tokenThreshold') ?? '', '80000')
        @Expect(confs[0].conf.get('thinking') ?? '', 'toggle')
        @Expect(confs[1].provider, 'zhipu')
        @Expect(confs[1].alwaysThinking, true)
        @Expect(confs[1].conf.get('searchEngine') ?? '', 'search_pro')
    }

    @TestCase
    func testStaticSourceReturnsCopy(): Unit {
        let c = LLMConf()
        c.provider = 'deepseek'
        c.llmName = 'chat-pro'
        c.actualLlmName = 'deepseek-chat'
        c.url = 'https://api.deepseek.com'
        c.auth = 'sk'
        let source = StaticConfSource(ArrayList<LLMConf>([c]))
        @Expect(source.load().size, 1)
        @Expect(source.load().size, 1)
    }

    @TestCase
    func testUnknownSourceName(): Unit {
        var thrown = false
        try{
            createConfSource('nope')
        }catch(e: IllegalArgumentException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testEnvSourceParsesInlineJson(): Unit {
        let source = EnvConfSource(text: SAMPLE_CONF_JSON)
        @Expect(source.name, 'env')
        let confs = source.load()
        @Expect(confs.size, 2)
        @Expect(confs[0].llmName, 'chat-pro')
        @Expect(confs[1].conf.get('searchEngine') ?? '', 'search_pro')
    }

    @TestCase
    func testEnvSourceEmptyTextThrows(): Unit {
        var thrown = false
        try{
            EnvConfSource(text: '  ').load()
        }catch(e: IllegalArgumentException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testCreateConfSourceByScheme(): Unit {
        @Expect(createConfSource('').name, 'database')
        @Expect(createConfSource('database').name, 'database')
        @Expect(createConfSource('env').name, 'env')
        @Expect(createConfSource('file:/tmp/llm.json').name, 'file')
        var thrown = false
        try{
            createConfSource('file:')
        }catch(e: IllegalArgumentException){
            thrown = true
        }
        @Expect(thrown, true)
    }
}
