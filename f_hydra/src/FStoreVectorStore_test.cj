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
package fountain::f_hydra

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/** 每个用例独立目录，避免 f_store 的单实例可见性把用例串起来 */
private var pathSeq: Int64 = 0

private func newStore(): FStoreVectorStore {
    pathSeq++
    FStoreVectorStore('/tmp/fhydra-test-${pathSeq}')
}

@Test
public class FStoreVectorStoreTest {

    @TestCase
    func testUpsertAndGet(): Unit {
        let store = newStore()
        let sparse = HashMap<Int64, Float64>()
        sparse[7] = 0.5f64
        store.upsert('u1:global', VectorRecord('r1', '{"title":"a"}', [1.0f64, 0.0f64], sparse: sparse))

        let record = store.get('u1:global', 'r1').getOrThrow()
        @Expect(record.payload, '{"title":"a"}')
        @Expect(record.dense.size, 2)
        @Expect(record.sparse.get(7).getOrThrow(), 0.5f64)
        store.close()
    }

    @TestCase
    func testSearchOrdersByCosine(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('near', 'p-near', [1.0f64, 0.0f64]))
        store.upsert('c', VectorRecord('mid', 'p-mid', [0.7f64, 0.7f64]))
        store.upsert('c', VectorRecord('far', 'p-far', [0.0f64, 1.0f64]))

        let hits = store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 2))
        @Expect(hits.size, 2)
        @Expect(hits[0].id, 'near')
        @Expect(hits[0].payload, 'p-near')
        @Expect(hits[0].score > hits[1].score, true)
        store.close()
    }

    @TestCase
    func testCollectionsAreIsolated(): Unit {
        let store = newStore()
        store.upsert('a', VectorRecord('x', 'A', [1.0f64, 0.0f64]))
        store.upsert('b', VectorRecord('x', 'B', [1.0f64, 0.0f64]))

        @Expect(store.count('a'), 1)
        @Expect(store.count('b'), 1)
        @Expect(store.get('a', 'x').getOrThrow().payload, 'A')
        @Expect(store.get('b', 'x').getOrThrow().payload, 'B')
        store.close()
    }

    @TestCase
    func testOverwriteAndRemove(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r', 'v1', [1.0f64, 0.0f64]))
        store.upsert('c', VectorRecord('r', 'v2', [0.0f64, 1.0f64]))

        @Expect(store.count('c'), 1)
        @Expect(store.get('c', 'r').getOrThrow().payload, 'v2')

        @Expect(store.remove('c', 'r'), true)
        @Expect(store.get('c', 'r').isNone(), true)
        @Expect(store.remove('c', 'r'), false)
        @Expect(store.searchDense(VectorQuery('c', [1.0f64, 0.0f64])).size, 0)
        store.close()
    }

    @TestCase
    func testLimitZeroOrEmptyQueryReturnsNothing(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r', 'p', [1.0f64, 0.0f64]))

        @Expect(store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 0)).size, 0)
        @Expect(store.searchDense(VectorQuery('c', Array<Float64>())).size, 0)
        store.close()
    }
}
