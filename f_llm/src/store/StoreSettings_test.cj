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

@Test
public class StoreSettingsTest {

    private func clearAll(): Unit {
        Config.remove(StoreSettings.CONTENT_KEY)
        Config.remove(StoreSettings.META_KEY)
        Config.remove(StoreSettings.META_PATH_KEY)
        Config.remove(StoreSettings.CONTENT_URL_KEY)
        Config.remove('llm_memoryBackend')
        Config.remove('llm_characterBackend')
        Config.remove('llm_memoryPath')
    }

    @TestCase
    func testDefaults(): Unit {
        clearAll()
        let settings = StoreSettings.load()
        @Expect(settings.memoryStore, 'postgres')
        @Expect(settings.metaStore, 'f_store')
        @Expect(settings.metaStorePath, './data/f_llm-meta')
        @Expect(settings.contentStoreUrl, '')
        @Expect(settings.deprecated.isEmpty(), true)
    }

    @TestCase
    func testReadsNewKeys(): Unit {
        clearAll()
        Config.set<String>([
            (StoreSettings.CONTENT_KEY, 'mysql'),
            (StoreSettings.META_KEY, 'f_store'),
            (StoreSettings.META_PATH_KEY, '/tmp/meta'),
            (StoreSettings.CONTENT_URL_KEY, 'mysql://localhost/fllm')
        ])
        let settings = StoreSettings.load()
        @Expect(settings.memoryStore, 'mysql')
        @Expect(settings.metaStore, 'f_store')
        @Expect(settings.metaStorePath, '/tmp/meta')
        @Expect(settings.contentStoreUrl, 'mysql://localhost/fllm')
        clearAll()
    }

    @TestCase
    func testOldKeysAreDeprecatedNotApplied(): Unit {
        clearAll()
        Config.set<String>([
            ('llm_memoryBackend', 'file'),
            ('llm_characterBackend', 'memory'),
            ('llm_memoryPath', '/tmp/old')
        ])
        let settings = StoreSettings.load()
        // 旧键不参与选型：仍然用默认值
        @Expect(settings.memoryStore, 'postgres')
        @Expect(settings.metaStore, 'f_store')
        // 但必须被识别出来，供启动日志 warn
        @Expect(settings.deprecated.size, 3)
        clearAll()
    }
}
