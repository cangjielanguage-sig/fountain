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

import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_store.Store

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

    @TestCase
    func testPredefinedKeysAccepted(): Unit {
        let meta = FStoreMetaStore('/tmp/fllm-meta-test')
        @Expect(PredefinedCharacters.keys().size, 13)
        for(key in PredefinedCharacters.keys()){
            meta.characters.set(Character(100, key, ''))
        }
    }

    @TestCase
    func testUnknownKeyRejected(): Unit {
        let meta = FStoreMetaStore('/tmp/fllm-meta-test')
        var thrown = false
        try{
            meta.characters.set(Character(101, 'not-exist', ''))
        }catch(_: IllegalArgumentException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testCustomPromptsPreserved(): Unit {
        let meta = FStoreMetaStore('/tmp/fllm-meta-test')
        meta.characters.set(Character(102, 'custom', '你是猫娘'))
        @Expect(meta.characters.get(102).getOrThrow().prompts, '你是猫娘')
    }

    @TestCase
    func testConfPutAndFilter(): Unit {
        // 每次跑用独立目录，避免上一轮的残留配置把候选数抬高
        let meta = FStoreMetaStore('/tmp/fllm-conf-${DateTime.now().toUnixTimeStamp().toSeconds()}')
        meta.confs.put(LLMConfView('p1', 'chat-pro', 'pro', 10, true))
        meta.confs.put(LLMConfView('p2', 'chat-pro', 'off', 10, false))
        meta.confs.put(LLMConfView('p3', 'chat-pro', 'zero', 0, true))
        @Expect(meta.confs.candidates('chat-pro').size, 1)
        @Expect(meta.confs.names().size, 1)
    }

    @TestCase
    func testSkillVersionAndList(): Unit {
        let meta = FStoreMetaStore('/tmp/fllm-skill-${DateTime.now().toUnixTimeStamp().toSeconds()}')
        meta.skills.upsert(Skill(1, 'summarize', '步骤', 'tool:webSearch'))
        @Expect(meta.skills.get(1).getOrThrow().version, 1)
        @Expect(meta.skills.get(1).getOrThrow().title, 'summarize')
        @Expect(meta.skills.list().size, 1)
    }

    @TestCase
    func testPromptLatestAndMissing(): Unit {
        let meta = FStoreMetaStore('/tmp/fllm-prompt-${DateTime.now().toUnixTimeStamp().toSeconds()}')
        meta.prompts.put(PromptEntry('memory.extract', 1, 'v1'))
        meta.prompts.put(PromptEntry('memory.extract', 2, 'v2'))
        @Expect(meta.prompts.latest('memory.extract').getOrThrow().content, 'v2')
        @Expect(meta.prompts.get('memory.extract', 1).getOrThrow().content, 'v1')
        @Expect(meta.prompts.get('not-exist', 1).isNone(), true)
    }

    @TestCase
    func testRepairRebuildsMissingIndex(): Unit {
        let path = '/tmp/fllm-conf-repair-${DateTime.now().toUnixTimeStamp().toSeconds()}'
        // 同一个 Store 实例内模拟半写：写主体 → 删掉索引 → repair 补回
        let store = Store(path)
        let confs = FStoreLLMConfStore(store)
        let id = confs.put(LLMConfView('p1', 'chat-x', 'x', 10, true))
        store.remove('f_llm:meta:conf:byname:chat-x:${id}'.toArray())
        @Expect(confs.candidates('chat-x').size, 0)
        confs.repair()
        @Expect(confs.candidates('chat-x').size, 1)
    }
}
