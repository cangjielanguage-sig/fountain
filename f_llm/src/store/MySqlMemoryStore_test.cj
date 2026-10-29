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
public class MySqlMemoryStoreTest {

    @TestCase
    func testSearchReusesKindWeightAndTopK(): Unit {
        let repo = FakeMemoryRepository()
        repo.hits.add(MemoryHit(memoryRecord(1, 'session'), 0.5f64))
        repo.hits.add(MemoryHit(memoryRecord(2, 'fact'), 0.5f64))
        let store = MySqlMemoryStore(repo, FakeEmbedder())

        let results = store.search(MemoryQuery(1, ['global'], [], 'q', topK: 5))
        @Expect(results.size, 2)
        @Expect(results[0].record.kind, 'fact')
    }

    @TestCase
    func testVectorizationStillRejectsWrite(): Unit {
        let repo = FakeMemoryRepository()
        let embedder = FakeEmbedder()
        embedder.fail = true
        let store = MySqlMemoryStore(repo, embedder)
        var message = ''
        try{
            store.add(MemoryWrite(1, 'global', 't', 'c', 'note'))
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('embedding'), true)
        @Expect(repo.upserts, 0)
    }
}
