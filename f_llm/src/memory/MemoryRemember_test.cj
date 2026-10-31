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
package fountain::f_llm.memory

import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_config.Config

import fountain::f_llm.store.*

/** 5.1：摘要写入走 Stores.content().memory（kind=session）。 */
@Test
public class MemoryRememberTest {

    @TestCase
    func testRememberWritesSessionMemory(): Unit {
        // 共享同一个内容族实例，保证写入后能立刻读回
        let shared = InMemoryContentStore()
        Stores.registerContent('inMemoryShared', { => shared })
        Config.set<String>([('llm_memoryStore', 'inMemoryShared')])

        Memory.remember('session-1', '用户偏好简洁回答')

        let records = shared.memory.list(0, 'global', 0, 10)
        @Expect(records.size, 1)
        @Expect(records[0].kind, 'session')
        @Expect(records[0].title, 'session-1')
        @Expect(records[0].content, '用户偏好简洁回答')
    }
}
