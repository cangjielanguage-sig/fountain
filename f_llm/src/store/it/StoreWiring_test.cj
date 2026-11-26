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

import fountain::f_config.Config

import fountain::f_llm.store.*
import fountain::f_llm.store.mysql.*
import fountain::f_llm.store.postgres.*
import fountain::f_llm.wiring.*

/** P0：接线后注册表非空、三个内容族可用、未知值启动失败。 */
@Test
public class StoreWiringTest {

    @TestCase
    func testWireRegistersAllContentStores(): Unit {
        StoreWiring.wire()
        @Expect(Stores.containsContent('postgres'), true)
        @Expect(Stores.containsContent('mysql'), true)
        @Expect(Stores.containsContent('inMemory'), true)
    }

    /** 注册表被清空后，`wire()` 能恢复全部实现（对应 Memory.remember 的自动接线） */
    @TestCase
    func testWireRestoresRegistryAfterReset(): Unit {
        Stores.resetForTest()
        @Expect(Stores.containsContent('postgres'), false)

        StoreWiring.wire()

        @Expect(Stores.containsContent('inMemory'), true)
        @Expect(Stores.containsContent('postgres'), true)
        @Expect(Stores.containsContent('mysql'), true)
        @Expect(Stores.containsMeta('f_store'), true)
    }

    @TestCase
    func testWireRegistersAllMetaStores(): Unit {
        StoreWiring.wire()
        @Expect(Stores.containsMeta('postgres'), true)
        @Expect(Stores.containsMeta('mysql'), true)
        @Expect(Stores.containsMeta('f_store'), true)
    }

    @TestCase
    func testUnknownMetaValueFailsThroughWiring(): Unit {
        Config.set<String>([('llm_metaStore', 'nope')])
        var message = ''
        try{
            StoreWiring.wire()
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('nope'), true)
        Config.set<String>([('llm_metaStore', 'f_store')])
    }

    @TestCase
    func testInMemoryContentStoreUsable(): Unit {
        Config.set<String>([('llm_memoryStore', 'inMemory')])
        StoreWiring.wire()
        @Expect(Stores.content() is InMemoryContentStore, true)
    }

    @TestCase
    func testPostgresContentStoreUsable(): Unit {
        Config.set<String>([('llm_memoryStore', 'postgres')])
        StoreWiring.wire()
        @Expect(Stores.content() is PostgresContentStore, true)
    }

    @TestCase
    func testUnknownValueFailsThroughWiring(): Unit {
        Config.set<String>([('llm_memoryStore', 'sqlite')])
        var message = ''
        try{
            StoreWiring.wire()
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('sqlite'), true)
        // 还原配置，避免影响其它用例
        Config.set<String>([('llm_memoryStore', 'postgres')])
    }
}
