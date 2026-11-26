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
package fountain::f_llm.constant

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ModelNamesTest {

    @TestCase
    func testTencentDeepSeekMapsToCanonical(): Unit {
        @Expect(ModelNames.normalize('deepseek/deepseek-flash'), MODEL_NAME_DEEPSEEK_FLASH)
        @Expect(ModelNames.normalize('deepseek/deepseek-chat'), MODEL_NAME_DEEPSEEK_CHAT)
        @Expect(ModelNames.normalize('DeepSeek/DeepSeek-Flash'), MODEL_NAME_DEEPSEEK_FLASH)
        @Expect(ModelNames.normalize('  deepseek/deepseek-flash  '), MODEL_NAME_DEEPSEEK_FLASH)
        @Expect(ModelNames.isFlash('deepseek/deepseek-flash'), true)
    }

    @TestCase
    func testAggregatorsAliases(): Unit {
        @Expect(ModelNames.normalize('deepseek-ai/DeepSeek-V3'), MODEL_NAME_DEEPSEEK_CHAT)
        @Expect(ModelNames.normalize('deepseek-ai/DeepSeek-R1'), MODEL_NAME_DEEPSEEK_REASONER)
        @Expect(ModelNames.normalize('zhipu/glm-5'), MODEL_NAME_GLM5)
    }

    @TestCase
    func testUnknownAndCanonicalKeptAsIs(): Unit {
        @Expect(ModelNames.normalize('glm-5'), MODEL_NAME_GLM5)
        @Expect(ModelNames.normalize('some-custom-model'), 'some-custom-model')
        @Expect(ModelNames.isFlash('deepseek-chat'), false)
    }
}
