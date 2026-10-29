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
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

class FakeEmbedder <: Embedder {
    public var calls: Int64 = 0
    public var fail: Bool = false

    public func embed(text: String): Array<Float64> {
        calls++
        if(fail){
            throw IllegalArgumentException('embedding service down')
        }
        [0.1f64, 0.2f64, 0.3f64]
    }
}

class FakeMemoryRepository <: MemoryRepository {
    public var upserts: Int64 = 0
    public var lastTitleVector: Array<Float64> = []
    public var lastContentVector: Array<Float64> = []
    public var hits = ArrayList<MemoryHit>()
    public var lastLimit: Int64 = 0
    private var seq: Int64 = 0
    private let ids = HashMap<String, Int64>()

    public func upsert(write: MemoryWrite, titleVector: Array<Float64>, contentVector: Array<Float64>): Int64 {
        upserts++
        lastTitleVector = titleVector
        lastContentVector = contentVector
        let key = '${write.userId}:${write.namespace}:${write.title}'
        match(ids.get(key)){
            case Some(id) => id
            case None =>
                seq++
                ids[key] = seq
                seq
        }
    }

    public func searchDense(query: MemoryQuery, vector: Array<Float64>, limit: Int64): ArrayList<MemoryHit> {
        lastLimit = limit
        hits
    }
}

@Test
public class PostgresMemoryStoreTest {

    @TestCase
    func testAddEmbedsTitleAndContent(): Unit {
        let embedder = FakeEmbedder()
        let repo = FakeMemoryRepository()
        let store = PostgresMemoryStore(repo, embedder)

        let record = store.add(MemoryWrite(1, 'global', '标题', '正文', 'note'))
        @Expect(record.title, '标题')
        @Expect(embedder.calls, 2)
        @Expect(repo.upserts, 1)
        @Expect(repo.lastTitleVector.size, 3)
        @Expect(repo.lastContentVector.size, 3)
    }

    @TestCase
    func testSameTitleOverwrites(): Unit {
        let embedder = FakeEmbedder()
        let repo = FakeMemoryRepository()
        let store = PostgresMemoryStore(repo, embedder)

        let first = store.add(MemoryWrite(1, 'global', '标题', '正文一', 'note'))
        let second = store.add(MemoryWrite(1, 'global', '标题', '正文二', 'note'))
        @Expect(repo.upserts, 2)
        @Expect(first.id, second.id)
    }

    @TestCase
    func testDenseSearchAppliesKindWeight(): Unit {
        let repo = FakeMemoryRepository()
        repo.hits.add(MemoryHit(memoryRecord(1, 'session'), 0.5f64))
        repo.hits.add(MemoryHit(memoryRecord(2, 'fact'), 0.5f64))
        let store = PostgresMemoryStore(repo, FakeEmbedder())

        let results = store.search(MemoryQuery(1, ['global'], [], 'q', topK: 5))
        @Expect(results.size, 2)
        @Expect(results[0].record.kind, 'fact')
        @Expect(results[1].record.kind, 'session')
        // fact=1.0 → 0.5；session=0.3 → 0.15
        @Expect(results[1].score < 0.16f64 && results[1].score > 0.14f64, true)
    }

    @TestCase
    func testSearchOverFetchesBeforeTruncation(): Unit {
        let repo = FakeMemoryRepository()
        let store = PostgresMemoryStore(repo, FakeEmbedder())
        store.search(MemoryQuery(1, ['global'], [], 'q', topK: 2))
        // 先取 2 倍候选，再乘权重截断
        @Expect(repo.lastLimit, 4)
    }

    @TestCase
    func testSearchTruncatesToTopK(): Unit {
        let repo = FakeMemoryRepository()
        repo.hits.add(MemoryHit(memoryRecord(1, 'note'), 0.5f64))
        repo.hits.add(MemoryHit(memoryRecord(2, 'note'), 0.4f64))
        repo.hits.add(MemoryHit(memoryRecord(3, 'note'), 0.3f64))
        let store = PostgresMemoryStore(repo, FakeEmbedder())
        let results = store.search(MemoryQuery(1, ['global'], [], 'q', topK: 2))
        @Expect(results.size, 2)
    }

    @TestCase
    func testEmbeddingFailureRejectsWrite(): Unit {
        let embedder = FakeEmbedder()
        embedder.fail = true
        let repo = FakeMemoryRepository()
        let store = PostgresMemoryStore(repo, embedder)

        var message = ''
        try{
            store.add(MemoryWrite(1, 'global', '标题', '正文', 'note'))
        }catch(e: Exception){
            message = e.message
        }
        // 必须是向量化失败本身，而不是「未实现」之类的其它异常
        @Expect(message.contains('embedding'), true)
        @Expect(repo.upserts, 0)
    }
}

func memoryRecord(id: Int64, kind: String): MemoryRecord {
    MemoryRecord(id, 1, 'global', 't${id}', 'c${id}', kind, DateTime.now())
}