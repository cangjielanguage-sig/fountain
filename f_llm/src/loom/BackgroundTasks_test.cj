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
package fountain::f_llm.loom

import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.store.*

/** P4：超时包装、记忆记录、技能演进 */
@Test
class BackgroundTasks_test {
    private static func gateway(): LoomStoreGateway {
        LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
    }

    @TestCase
    func testTimeoutReturnsWhenActionIsSlow(): Unit {
        let result = LoomTimeout.call({ =>
            sleep(Duration.millisecond * 300)
            'done'
        }, 30)
        @Expect(result.contains('timeout after'), true)
    }

    @TestCase
    func testTimeoutReturnsValueWhenFast(): Unit {
        let result = LoomTimeout.call({ => 'ok' }, 1000)
        @Expect(result, 'ok')
    }

    @TestCase
    func testTimeoutReturnsErrorText(): Unit {
        let result = LoomTimeout.call({ => throw IllegalStateException('boom') }, 1000)
        @Expect(result.contains('error: boom'), true)
    }

    @TestCase
    func testMemoryRecorderWritesRecord(): Unit {
        let gateway = gateway()
        let id = MemoryRecorderTask.record(gateway, 7, 'n', 'note', 'cangjie recorder')
        @Expect(id.isEmpty(), false)
        let hits = gateway.call('memory', 'search',
            '{"userId":7,"namespace":"n","text":"cangjie","topK":5}')
        @Expect(hits.startsWith('['), true)
    }

    @TestCase
    func testSkillEvolutionBumpsVersion(): Unit {
        let store = InMemoryMetaStore().skills
        store.upsert(Skill(1, '日报助手', '旧正文', '{}', version: 1))
        let result = SkillEvolutionTask.evolve({ prompt => '新正文' }, store, '日报助手', '多用表格')
        @Expect(result.contains('v2'), true)
        @Expect(store.get(1).getOrThrow().details, '新正文')
    }

    @TestCase
    func testSkillEvolutionMissingSkill(): Unit {
        let store = InMemoryMetaStore().skills
        let result = SkillEvolutionTask.evolve({ prompt => 'x' }, store, '不存在', 'usage')
        @Expect(result.contains('skill not found'), true)
    }
}
