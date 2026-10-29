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
public class StoreConformanceTest {

    @TestCase
    func testMemoryAddGetRemove(): Unit {
        let memory = InMemoryContentStore().memory
        let saved = memory.add(MemoryWrite(1, 'global', '标题一', '正文一', 'note'))
        @Expect(saved.title, '标题一')
        @Expect(saved.userId, 1)

        let loaded = memory.get(1, saved.id)
        @Expect(loaded.isSome(), true)
        @Expect(loaded.getOrThrow().content, '正文一')

        @Expect(memory.remove(1, saved.id), true)
        @Expect(memory.get(1, saved.id).isNone(), true)
    }

    @TestCase
    func testMemoryListByNamespace(): Unit {
        let memory = InMemoryContentStore().memory
        memory.add(MemoryWrite(1, 'global', 'g1', 'x', 'note'))
        memory.add(MemoryWrite(1, 'ws-1', 'w1', 'y', 'note'))
        memory.add(MemoryWrite(2, 'global', 'other', 'z', 'note'))

        @Expect(memory.list(1, 'global', 0, 20).size, 1)
        @Expect(memory.list(1, 'ws-1', 0, 20).size, 1)
        @Expect(memory.list(2, 'global', 0, 20).size, 1)
    }

    @TestCase
    func testMemorySearchReturnsHit(): Unit {
        let memory = InMemoryContentStore().memory
        memory.add(MemoryWrite(1, 'global', '仓颉记忆', '仓颉是一门语言', 'note'))
        memory.add(MemoryWrite(1, 'global', '无关', '天气不错', 'note'))

        let hits = memory.search(MemoryQuery(1, ['global'], ['note'], '仓颉', topK: 5))
        @Expect(hits.size, 1)
        @Expect(hits[0].record.title, '仓颉记忆')
    }

    @TestCase
    func testCharacterSetGetReset(): Unit {
        let characters = InMemoryMetaStore().characters
        characters.set(Character(1, 'rigorous', '严谨'))
        @Expect(characters.get(1).getOrThrow().characterKey, 'rigorous')

        characters.set(Character(1, 'friendly', '亲和'))
        @Expect(characters.get(1).getOrThrow().characterKey, 'friendly')

        characters.reset(1)
        @Expect(characters.get(1).isNone(), true)
    }

    @TestCase
    func testPromptLatestVersion(): Unit {
        let prompts = InMemoryMetaStore().prompts
        prompts.put(PromptEntry('memory.extract', 1, 'v1'))
        prompts.put(PromptEntry('memory.extract', 2, 'v2'))
        @Expect(prompts.latest('memory.extract').getOrThrow().content, 'v2')
        @Expect(prompts.get('memory.extract', 1).getOrThrow().content, 'v1')
    }
}
