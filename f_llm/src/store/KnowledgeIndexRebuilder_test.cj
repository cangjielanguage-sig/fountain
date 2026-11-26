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

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/** 记录调用次数的假向量化：向量固定，仅用于验证「重建确实重算」 */
class CountingEmbedder <: Embedder {
    public var calls: Int64 = 0

    public func embed(text: String): Array<Float64> {
        calls++
        let vector = Array<Float64>(1024, repeat: 0.0f64)
        vector[0] = 1.0f64
        vector
    }

    public func embedColbert(text: String): Array<Array<Float64>> {
        Array<Array<Float64>>()
    }

    public func tokenize(text: String): HashMap<Int64, Float64> {
        HashMap<Int64, Float64>()
    }
}

@Test
public class KnowledgeIndexRebuilderTest {

    @TestCase
    func testRebuildAllPagesThroughDocuments(): Unit {
        let embedder = CountingEmbedder()
        let store = InMemoryKnowledgeStore(embedder)
        store.upsert(KnowledgeDoc('d-1', 't', '内容一'))
        store.upsert(KnowledgeDoc('d-2', 't', '内容二'))
        store.upsert(KnowledgeDoc('d-3', 't', '内容三'))

        embedder.calls = 0
        let rebuilt = KnowledgeIndexRebuilder.rebuildAll(store, batchSize: 2)

        @Expect(rebuilt, 3)
        @Expect(embedder.calls >= 3, true)   // 每篇至少重新向量化一次
    }

    @TestCase
    func testRebuildTargetedDocuments(): Unit {
        let embedder = CountingEmbedder()
        let store = InMemoryKnowledgeStore(embedder)
        store.upsert(KnowledgeDoc('d-1', 't', '内容一'))
        store.upsert(KnowledgeDoc('d-2', 't', '内容二'))

        let rebuilt = KnowledgeIndexRebuilder.rebuild(store, ArrayList<String>(['d-1', 'missing']))
        @Expect(rebuilt, 1)
    }

    @TestCase
    func testDocIdsPagingIsStable(): Unit {
        let store = InMemoryKnowledgeStore()
        store.upsert(KnowledgeDoc('b', 't', 'x'))
        store.upsert(KnowledgeDoc('a', 't', 'x'))
        store.upsert(KnowledgeDoc('c', 't', 'x'))

        let first = store.docIds(0, 2)
        let second = store.docIds(2, 2)
        @Expect(first.size, 2)
        @Expect(first[0], 'a')
        @Expect(first[1], 'b')
        @Expect(second.size, 1)
        @Expect(second[0], 'c')
    }

    @TestCase
    func testNonPositiveBatchRejected(): Unit {
        let store = InMemoryKnowledgeStore()
        var thrown = false
        try{
            KnowledgeIndexRebuilder.rebuildAll(store, batchSize: 0)
        }catch(_: IllegalArgumentException){
            thrown = true
        }
        @Expect(thrown, true)
    }
}
