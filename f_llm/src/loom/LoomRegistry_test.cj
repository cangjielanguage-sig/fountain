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
import std.unittest.*
import std.unittest.testmacro.*

@Test
class LoomRegistry_test {
    private func flow(name: String, status!: String = LoomStatus.PENDING): LoomFlow {
        let item = LoomFlow(name, description: 'desc')
        item.status = status
        item.planJson = '{"name":"${name}"}'
        item.stepSources['s1'] = 'let s1_result = "x"'
        item
    }

    @TestCase
    func testMemoryStoreSaveGetRemove(): Unit {
        let store = MemoryLoomStore()
        store.save(flow('a'))
        @Expect(store.get('a').getOrThrow().description, 'desc')
        @Expect(store.remove('a'), true)
        @Expect(store.get('a').isNone(), true)
        @Expect(store.remove('a'), false)
    }

    @TestCase
    func testMemoryStoreListIsStableAndPaged(): Unit {
        let store = MemoryLoomStore()
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

    @TestCase
    func testRegistryKeepsFlowAndFiltersCompiled(): Unit {
        let registry = LoomRegistry()
        registry.put(flow('pending'))
        registry.put(flow('done', status: LoomStatus.COMPILED))

        @Expect(registry.size(), 2)
        @Expect(registry.get('done').getOrThrow().status, LoomStatus.COMPILED)
        let compiled = registry.compiledFlows()
        @Expect(compiled.size, 1)
        @Expect(compiled[0].name, 'done')
    }

    @TestCase
    func testRegistryPersistsAndRestores(): Unit {
        let store = MemoryLoomStore()
        let registry = LoomRegistry(store: store)
        registry.put(flow('persisted', status: LoomStatus.COMPILED))

        // 新进程：从 store 恢复
        let restarted = LoomRegistry(store: store)
        @Expect(restarted.restore(), 1)
        @Expect(restarted.get('persisted').getOrThrow().status, LoomStatus.COMPILED)
        @Expect(restarted.size(), 1)
    }

    @TestCase
    func testRegistryRemoveAlsoRemovesFromStore(): Unit {
        let store = MemoryLoomStore()
        let registry = LoomRegistry(store: store)
        registry.put(flow('gone'))

        @Expect(registry.remove('gone'), true)
        @Expect(store.get('gone').isNone(), true)
        @Expect(registry.remove('gone'), false)
    }

    @TestCase
    func testUnknownStatusRejected(): Unit {
        let item = flow('x')
        var message = ''
        try{
            item.mark('unknown')
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('unknown loom status'), true)
    }

    @TestCase
    func testBlankNameRejected(): Unit {
        var message = ''
        try{
            LoomFlow('   ')
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('must not be blank'), true)
    }
}
