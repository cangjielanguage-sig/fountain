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

import std.collection.*
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

/** f_store 版 loom 存储：按字段拆键的往返与分页 */
@Test
class FStoreLoomStore_test {
    private func path(): String {
        '/tmp/fllm-loom-fstore-${DateTime.now().nanosecond}'
    }

    private func flow(name: String): LoomFlow {
        let value = LoomFlow(name, description: '抓取并汇总')
        value.planJson = '{"name":"${name}","steps":[]}'
        value.flowSource = '{ => flow.start("") }'
        value.stepSources['fetch'] = 'let fetch_out = "A"\nLoomHostApi.taskEvent(e, "fetch", fetch_out)'
        value.stepSources['sum'] = 'let sum_out = "B"'
        value.status = LoomStatus.COMPILED
        value.round = 2
        value.questionsJson = '[]'
        value.tools = 'webSearch'
        value.mcps = 'mail'
        value
    }

    @TestCase
    func testRoundtripKeepsAllFields(): Unit {
        let store = FStoreLoomStore(path())
        store.save(flow('daily'))

        let loaded = store.get('daily').getOrThrow()
        @Expect(loaded.description, '抓取并汇总')
        @Expect(loaded.planJson, '{"name":"daily","steps":[]}')
        @Expect(loaded.flowSource, '{ => flow.start("") }')
        @Expect(loaded.status, LoomStatus.COMPILED)
        @Expect(loaded.round, 2)
        @Expect(loaded.tools, 'webSearch')
        @Expect(loaded.mcps, 'mail')
        @Expect(loaded.stepSources.size, 2)
        @Expect(loaded.stepSources['fetch'], flow('daily').stepSources['fetch'])
    }

    @TestCase
    func testOverwriteAndRemove(): Unit {
        let store = FStoreLoomStore(path())
        let first = flow('daily')
        first.round = 1
        store.save(first)

        let second = flow('daily')
        second.round = 5
        second.status = LoomStatus.PENDING
        store.save(second)
        @Expect(store.get('daily').getOrThrow().round, 5)
        @Expect(store.get('daily').getOrThrow().status, LoomStatus.PENDING)

        @Expect(store.remove('daily'), true)
        @Expect(store.get('daily').isNone(), true)
        @Expect(store.remove('daily'), false)   // 已删过
    }

    @TestCase
    func testListIsSortedAndPaged(): Unit {
        let store = FStoreLoomStore(path())
        store.save(flow('b'))
        store.save(flow('a'))
        store.save(flow('c'))

        let first = store.list(0, 2)
        @Expect(first.size, 2)
        @Expect(first[0].name, 'a')
        @Expect(first[1].name, 'b')
        let second = store.list(2, 2)
        @Expect(second.size, 1)
        @Expect(second[0].name, 'c')
    }
}
