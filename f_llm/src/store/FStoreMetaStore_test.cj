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
package fountain::f_llm.store

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class FStoreMetaStoreTest {

    @TestCase
    func testCharacterSurvivesRestart(): Unit {
        let path = '/tmp/fllm-meta-test'
        let first = FStoreMetaStore(path)
        first.characters.set(Character(42, 'whimsical', '鬼灵精怪'))

        // 新建实例 = 模拟重启，数据必须还在
        let second = FStoreMetaStore(path)
        let loaded = second.characters.get(42)
        @Expect(loaded.isSome(), true)
        @Expect(loaded.getOrThrow().characterKey, 'whimsical')
        @Expect(loaded.getOrThrow().prompts, '鬼灵精怪')
    }

    @TestCase
    func testResetRemovesCharacter(): Unit {
        let path = '/tmp/fllm-meta-test'
        let meta = FStoreMetaStore(path)
        meta.characters.set(Character(7, 'default', ''))
        meta.characters.reset(7)
        @Expect(meta.characters.get(7).isNone(), true)
    }
}
