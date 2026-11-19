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

import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.store.*

@Test
public class StoreMetaConfSourceTest {

    @TestCase
    func testLoadsFullConfFromMetaStore(): Unit {
        let meta = InMemoryMetaStore()
        meta.confs.put(LLMConfView('p1', 'chat-pro', 'pro', 10, true,
                                   llmUrl: 'http://llm.local/v1', auth: 'sk-test',
                                   temperature: 0.3f64, alwaysThinking: true))

        let confs = StoreMetaConfSource(meta).load()
        @Expect(confs.size, 1)
        @Expect(confs[0].llmName, 'chat-pro')
        @Expect(confs[0].url, 'http://llm.local/v1')
        @Expect(confs[0].auth, 'sk-test')
        @Expect(confs[0].alwaysThinking, true)
    }

    @TestCase
    func testSkipsDisabledAndZeroWeight(): Unit {
        let meta = InMemoryMetaStore()
        meta.confs.put(LLMConfView('p1', 'chat-pro', 'pro', 0, true))
        meta.confs.put(LLMConfView('p2', 'chat-pro', 'off', 10, false))
        @Expect(StoreMetaConfSource(meta).load().size, 0)
    }
}
