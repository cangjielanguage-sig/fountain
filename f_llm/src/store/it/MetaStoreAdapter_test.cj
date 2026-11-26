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

/** P0′：元数据适配器按配置显式分支，未知值不静默回退。 */
@Test
public class MetaStoreAdapterTest {

    @TestCase
    func testFStoreBranchIsUsable(): Unit {
        Config.set<String>([('llm_metaStore', 'f_store')])
        Config.set<String>([('llm_metaStorePath', '/tmp/fllm-meta-adapter-test')])
        let meta = MetaStoreAdapter()
        meta.characters.set(Character(1, 'default', '默认人格'))
        @Expect(meta.characters.get(1).getOrThrow().prompts, '默认人格')
    }

    @TestCase
    func testUnknownMetaValueThrows(): Unit {
        Config.set<String>([('llm_metaStore', 'nope')])
        var message = ''
        try{
            MetaStoreAdapter()
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('nope'), true)
        Config.set<String>([('llm_metaStore', 'f_store')])
    }
}
