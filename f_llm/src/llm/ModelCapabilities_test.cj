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
package fountain::f_llm.llm

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*

import fountain::f_llm.llm.openai.*
import fountain::f_llm.model.po.*

func capabilityConf(provider: String, model: String): LLMConf {
    let conf = LLMConf()
    conf.provider = provider
    conf.llmName = 'chat-pro'
    conf.actualLlmName = model
    conf.url = 'https://api.example'
    conf.auth = 'sk'
    conf.temperature = -1.0f64
    conf
}

@Test
public class ModelCapabilitiesTest {

    @TestCase
    func testResolveByModelTable(): Unit {
        @Expect(modeName(ModelCapabilities.resolve(capabilityConf('deepseek', 'deepseek-flash'))), 'always')
        // 平台前缀不影响判断：腾讯云的模型 ID 归一后同样是 Always
        @Expect(modeName(ModelCapabilities.resolve(capabilityConf('tokenhub', 'deepseek/deepseek-flash'))), 'always')
        @Expect(modeName(ModelCapabilities.resolve(capabilityConf('deepseek', 'deepseek-chat'))), 'toggle')
        @Expect(modeName(ModelCapabilities.resolve(capabilityConf('zhipu', 'glm-5'))), 'toggle')
        @Expect(modeName(ModelCapabilities.resolve(capabilityConf('zhipu', 'embedding-3'))), 'none')
        // 未知模型按默认可开关
        @Expect(modeName(ModelCapabilities.resolve(capabilityConf('openai', 'gpt-x'))), 'toggle')
    }

    @TestCase
    func testConfOverrideWins(): Unit {
        let conf = capabilityConf('deepseek', 'deepseek-flash')
        conf.setConf(HashMap<String, String>([('thinking', 'none')]))
        @Expect(modeName(ModelCapabilities.resolve(conf)), 'none')
        conf.setConf(HashMap<String, String>([('thinking', 'toggle')]))
        @Expect(modeName(ModelCapabilities.resolve(conf)), 'toggle')
    }

    @TestCase
    func testAlwaysModelDropsTemperature(): Unit {
        let conf = capabilityConf('deepseek', 'deepseek-flash')
        let body = JsonObject()
        body.add('temperature', 0.3f64)
        ThinkingPolicy.apply(conf, body)
        @Expect(body.get('temperature').isNone(), true)
        @Expect(ModelCapabilities.blocksTemperature(conf), true)
    }

    @TestCase
    func testAlwaysModelEnablesThinkingField(): Unit {
        // 恒思考模型：方言写 enabled，即使请求没显式要求思考
        let conf = capabilityConf('zhipu', 'deepseek/deepseek-flash')
        let body = JsonObject()
        ZhipuDialect().decorate(conf, body, ModelCapabilities.resolve(conf))
        @Expect(body.get('thinking')?.asObject().get('type')?.asString().value ?? '', 'enabled')
    }

    @TestCase
    func testNoThinkingCapabilityStripsFields(): Unit {
        let conf = capabilityConf('zhipu', 'embedding-3')
        conf.alwaysThinking = true
        let body = JsonObject()
        let thinking = JsonObject()
        thinking.add('type', 'enabled')
        body.add('thinking', thinking)
        body.add('enable_thinking', true)
        // 方言先写、策略后清：None 的最终报文里不能有任何思考字段
        ZhipuDialect().decorate(conf, body, ModelCapabilities.resolve(conf))
        ThinkingPolicy.apply(conf, body)
        @Expect(body.get('thinking').isNone(), true)
        @Expect(body.get('enable_thinking').isNone(), true)
    }

    @TestCase
    func testAliyunAlwaysUsesBooleanField(): Unit {
        let conf = capabilityConf('aliyun', 'deepseek-flash')
        let body = JsonObject()
        AliyunDialect().decorate(conf, body, ModelCapabilities.resolve(conf))
        @Expect(body.get('enable_thinking')?.asBool().value ?? false, true)
        @Expect(body.get('thinking').isNone(), true)
    }

    @TestCase
    func testToggleExplicitDisable(): Unit {
        let conf = capabilityConf('zhipu', 'glm-5')
        let body = JsonObject()
        let thinking = JsonObject()
        thinking.add('type', 'enabled')
        body.add('thinking', thinking)
        ZhipuDialect().decorate(conf, body, ModelCapabilities.resolve(conf))
        @Expect(body.get('thinking')?.asObject().get('type')?.asString().value ?? '', 'disabled')
    }
}

func modeName(mode: ThinkingMode): String {
    match(mode){
        case ThinkingMode.None => 'none'
        case ThinkingMode.Always => 'always'
        case ThinkingMode.Toggle => 'toggle'
    }
}