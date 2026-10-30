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
package fountain::f_llm.store.it

import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.store.*

@Test
public class MemoryRepositoryAdapterTest {

    /** 默认配置（llm_contentStore=postgres）下，适配器应能取到 bean 而不是抛错 */
    @TestCase
    func testAdapterResolvesBean(): Unit {
        let adapter = MemoryRepositoryAdapter()
        @Expect(adapter is MemoryRepository, true)
    }
}
