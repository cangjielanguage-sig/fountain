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

import fountain::f_config.*

class FakeContentStore <: ContentStore {
}

class FakeMetaStore <: MetaStore {
}

@Test
public class StoresTest {

    @TestCase
    func testUnknownContentStoreListsAvailable(): Unit {
        Stores.resetForTest()
        let factory: () -> ContentStore = { => FakeContentStore() }
        Stores.registerContent('fake', factory)
        var message = ''
        try{
            Stores.content('nope')
        }catch(e: IllegalArgumentException){
            message = e.message
        }
        // 报错必须同时带「请求的名字」与「可选列表」，否则排障只能靠猜
        @Expect(message.contains('nope'), true)
        @Expect(message.contains('fake'), true)
    }

    @TestCase
    func testRegisteredContentStoreIsReturned(): Unit {
        Stores.resetForTest()
        let factory: () -> ContentStore = { => FakeContentStore() }
        Stores.registerContent('fake', factory)
        let store = Stores.content('fake')
        @Expect(store is FakeContentStore, true)
    }

    @TestCase
    func testContentStoreFollowsConfig(): Unit {
        Stores.resetForTest()
        let factory: () -> ContentStore = { => FakeContentStore() }
        Stores.registerContent('fake', factory)
        Config.set<String>([(Stores.CONTENT_KEY, 'fake')])
        let store = Stores.content()
        @Expect(store is FakeContentStore, true)
        Config.remove(Stores.CONTENT_KEY)
    }

    @TestCase
    func testUnknownMetaStoreListsAvailable(): Unit {
        Stores.resetForTest()
        let factory: () -> MetaStore = { => FakeMetaStore() }
        Stores.registerMeta('f_store', factory)
        var message = ''
        try{
            Stores.meta('redis')
        }catch(e: IllegalArgumentException){
            message = e.message
        }
        @Expect(message.contains('redis'), true)
        @Expect(message.contains('f_store'), true)
    }
}
