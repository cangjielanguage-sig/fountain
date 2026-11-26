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
package fountain::f_llm.config

import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_config.Config

@Test
class LLMConfig_test {
    private func reset(): Unit {
        Config.remove(LLMConfig.LLM_SUPERVISOR)
        Config.remove(LLMConfig.LLM_LOOM_ON_NO_USABLE)
    }

    @TestCase
    func testSupervisorDisabledByDefault(): Unit {
        reset()
        @Expect(LLMConfig.supervisorEnabled(), false)
        @Expect(LLMConfig.loomOnNoUsable(), false)
    }

    @TestCase
    func testSupervisorExplicitOff(): Unit {
        reset()
        Config.set<Bool>([(LLMConfig.LLM_SUPERVISOR, false)])
        @Expect(LLMConfig.supervisorEnabled(), false)
    }

    @TestCase
    func testSupervisorOn(): Unit {
        reset()
        Config.set<Bool>([(LLMConfig.LLM_SUPERVISOR, true)])
        @Expect(LLMConfig.supervisorEnabled(), true)
        // 只开 supervisor 时，自动新建仍是关闭的
        @Expect(LLMConfig.loomOnNoUsable(), false)
    }

    @TestCase
    func testLoomOnNoUsableRequiresSupervisor(): Unit {
        reset()
        Config.set<Bool>([(LLMConfig.LLM_LOOM_ON_NO_USABLE, true)])
        @Expect(LLMConfig.supervisorEnabled(), false)
        @Expect(LLMConfig.loomOnNoUsable(), false)
    }

    @TestCase
    func testLoomOnNoUsableWhenBothOn(): Unit {
        reset()
        Config.set<Bool>([
            (LLMConfig.LLM_SUPERVISOR, true),
            (LLMConfig.LLM_LOOM_ON_NO_USABLE, true)
        ])
        @Expect(LLMConfig.loomOnNoUsable(), true)
    }
}
