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

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*

import fountain::f_llm.constant.*
import fountain::f_llm.model.po.*

func dialectConf(provider: String, baseUrl: String): LLMConf {
    let conf = LLMConf()
    conf.provider = provider
    conf.llmName = 'chat-pro'
    conf.actualLlmName = 'model-x'
    conf.url = baseUrl
    conf.auth = 'sk-test'
    conf.temperature = -1.0f64
    conf
}

@Test
public class ProviderDialectsTest {

    @TestCase
    func testBuiltinsAreResolvable(): Unit {
        // 内建方言必须真的注册进注册表，否则线上永远走 StandardDialect
        @Expect(DialectRegistry.resolve('deepseek').provider, 'deepseek')
        @Expect(DialectRegistry.resolve('zhipu').provider, 'zhipu')
        @Expect(DialectRegistry.resolve('volcengine').provider, 'volcengine')
        @Expect(DialectRegistry.resolve('aliyun').provider, 'aliyun')
        @Expect(DialectRegistry.resolve('siliconflow').provider, 'siliconflow')
        // 未注册的仍然回退标准实现
        @Expect(DialectRegistry.resolve('unknown-provider').provider, 'openai')
    }

    @TestCase
    func testEndpoints(): Unit {
        let zhipu = ZhipuDialect().endpoint(LLMApiKind.Chat, dialectConf('zhipu', 'https://open.bigmodel.cn/api/paas/v4/'))
        @Expect(zhipu, 'https://open.bigmodel.cn/api/paas/v4/chat/completions')
        let volc = VolcengineDialect().endpoint(LLMApiKind.Chat, dialectConf('volcengine', 'https://ark.cn-beijing.volces.com/api/v3'))
        @Expect(volc, 'https://ark.cn-beijing.volces.com/api/v3/chat/completions')
        let aliyun = AliyunDialect().endpoint(LLMApiKind.Chat, dialectConf('aliyun', 'https://dashscope.aliyuncs.com/compatible-mode/v1'))
        @Expect(aliyun, 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions')
        let silicon = SiliconFlowDialect().endpoint(LLMApiKind.Chat, dialectConf('siliconflow', 'https://api.siliconflow.cn/v1'))
        @Expect(silicon, 'https://api.siliconflow.cn/v1/chat/completions')
    }

    @TestCase
    func testChatPathOverride(): Unit {
        let conf = dialectConf('zhipu', 'https://proxy.example')
        conf.setConf(HashMapWith([('chatPath', '/custom/chat')]))
        @Expect(ZhipuDialect().endpoint(LLMApiKind.Chat, conf), 'https://proxy.example/custom/chat')
    }

    @TestCase
    func testResponsesUnsupported(): Unit {
        var thrown = 0
        for(dialect in ArrayList<ProviderDialect>([ZhipuDialect(), VolcengineDialect(), AliyunDialect(), SiliconFlowDialect()])){
            try{
                dialect.endpoint(LLMApiKind.Responses, dialectConf(dialect.provider, 'https://x.example'))
            }catch(_: IllegalArgumentException){
                thrown++
            }
        }
        @Expect(thrown, 4)
    }

    @TestCase
    func testZhipuThinkingSwitch(): Unit {
        let conf = dialectConf('zhipu', 'https://x.example')
        let body = JsonObject()
        ZhipuDialect().decorate(conf, body, ThinkingMode.Toggle)
        // 没要求思考且报文里没有该字段 ⇒ 不凭空添加
        @Expect(body.get('thinking').isNone(), true)

        conf.alwaysThinking = true
        ZhipuDialect().decorate(conf, body, ThinkingMode.Toggle)
        @Expect(body.get('thinking')?.asObject().get('type')?.asString().value ?? '', 'enabled')
    }

    @TestCase
    func testZhipuThinkingDisablesWhenRequested(): Unit {
        let conf = dialectConf('zhipu', 'https://x.example')
        let body = JsonObject()
        let requested = JsonObject()
        requested.add('type', 'enabled')
        body.add('thinking', requested)
        ZhipuDialect().decorate(conf, body, ThinkingMode.Toggle)
        @Expect(body.get('thinking')?.asObject().get('type')?.asString().value ?? '', 'disabled')
    }

    @TestCase
    func testAliyunUsesBooleanField(): Unit {
        let conf = dialectConf('aliyun', 'https://x.example')
        conf.alwaysThinking = true
        let body = JsonObject()
        let legacy = JsonObject()
        legacy.add('type', 'enabled')
        body.add('thinking', legacy)
        AliyunDialect().decorate(conf, body, ThinkingMode.Toggle)
        @Expect(body.get('thinking').isNone(), true)
        @Expect(body.get('enable_thinking')?.asBool().value ?? false, true)
    }

    @TestCase
    func testSiliconFlowDropsThinkingFields(): Unit {
        let conf = dialectConf('siliconflow', 'https://x.example')
        conf.alwaysThinking = true
        let body = JsonObject()
        let legacy = JsonObject()
        legacy.add('type', 'enabled')
        body.add('thinking', legacy)
        SiliconFlowDialect().decorate(conf, body, ThinkingMode.Toggle)
        @Expect(body.get('thinking').isNone(), true)
        @Expect(body.get('enable_thinking').isNone(), true)
    }

    @TestCase
    func testHeadersCarryBearer(): Unit {
        let headers = ZhipuDialect().headers(dialectConf('zhipu', 'https://x.example'))
        @Expect(headers.get('Authorization') ?? '', 'Bearer sk-test')
        @Expect(headers.get('Accept-Encoding') ?? '', 'identity')
    }
}

func HashMapWith(pairs: Array<(String, String)>): HashMap<String, String> {
    let map = HashMap<String, String>()
    for(pair in pairs){
        map[pair[0]] = pair[1]
    }
    map
}
