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

    public func embedColbert(text: String): Array<Array<Float64>> {
        [[1.0f64]]
    }

    public func tokenize(text: String): HashMap<Int64, Float64> {
        let tokens = HashMap<Int64, Float64>()
        var index: Int64 = 0
        for(part in text.split(' ')){
            if(!part.isEmpty()){
                index++
                tokens[index] = 1.0f64
            }
        }
        tokens
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

    public var sparseHits = ArrayList<MemoryHit>()
    public var colbertCalls: Int64 = 0
    private let colbertVectors = HashMap<Int64, ColbertVectors>()

    public func searchSparse(query: MemoryQuery, limit: Int64): ArrayList<MemoryHit> {
        sparseHits
    }

    public func setColbert(id: Int64, vectors: ColbertVectors): Unit {
        colbertVectors[id] = vectors
    }

    public func colbert(recordId: Int64): ?ColbertVectors {
        colbertCalls++
        colbertVectors.get(recordId)
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
        // 两条 dense 同分 → 归一化都为 1.0；融合 0.7、再乘权重：fact=0.7，session=0.21
        @Expect(results[0].score < 0.71f64 && results[0].score > 0.69f64, true)
        @Expect(results[1].score < 0.22f64 && results[1].score > 0.20f64, true)
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
    func testSparseFusionUsesWeights(): Unit {
        let repo = FakeMemoryRepository()
        repo.hits.add(MemoryHit(memoryRecord(1, 'note'), 0.9f64))
        repo.hits.add(MemoryHit(memoryRecord(2, 'note'), 0.1f64))
        repo.sparseHits.add(MemoryHit(memoryRecord(1, 'note'), 0.6f64))
        repo.sparseHits.add(MemoryHit(memoryRecord(3, 'note'), 1.0f64))
        let store = PostgresMemoryStore(repo, FakeEmbedder())

        let results = store.search(MemoryQuery(1, ['global'], [], 'q', topK: 5))
        // dense 归一化后 A=1/B=0；sparse A=0/C=1 → A=0.7, C=0.3, B=0
        @Expect(results.size, 3)
        @Expect(results[0].record.id, 1)
        @Expect(results[1].record.id, 3)
    }

    @TestCase
    func testEmptySparseMarksDegraded(): Unit {
        let repo = FakeMemoryRepository()
        repo.hits.add(MemoryHit(memoryRecord(1, 'note'), 0.9f64))
        let store = PostgresMemoryStore(repo, FakeEmbedder())

        let results = store.search(MemoryQuery(1, ['global'], [], 'q', topK: 5))
        @Expect(results.size, 1)
        @Expect(results[0].degraded, true)
    }

    @TestCase
    func testFusionDeduplicatesById(): Unit {
        let repo = FakeMemoryRepository()
        repo.hits.add(MemoryHit(memoryRecord(1, 'note'), 0.9f64))
        repo.sparseHits.add(MemoryHit(memoryRecord(1, 'note'), 0.6f64))
        let store = PostgresMemoryStore(repo, FakeEmbedder())

        let results = store.search(MemoryQuery(1, ['global'], [], 'q', topK: 5))
        @Expect(results.size, 1)
    }

    @TestCase
    func testRerankChangesOrderNotCandidateSet(): Unit {
        let repo = FakeMemoryRepository()
        repo.hits.add(MemoryHit(memoryRecord(1, 'note'), 0.9f64))
        repo.hits.add(MemoryHit(memoryRecord(2, 'note'), 0.5f64))
        // A 的 colbert 相似度低，B 高：重排后 B 在前
        repo.setColbert(1, ColbertVectors([[0.1f64]], [[0.1f64]]))
        repo.setColbert(2, ColbertVectors([[0.9f64]], [[0.9f64]]))
        let store = PostgresMemoryStore(repo, FakeEmbedder())

        let results = store.search(MemoryQuery(1, ['global'], [], 'q', topK: 5, rerank: true))
        @Expect(results.size, 2)
        @Expect(results[0].record.id, 2)
        @Expect(results[1].record.id, 1)
        // 分数保持融合值（A = 0.7 × 0.9）
        @Expect(results[1].score < 0.64f64 && results[1].score > 0.62f64, true)
    }

    @TestCase
    func testRerankFalseSkipsColbert(): Unit {
        let repo = FakeMemoryRepository()
        repo.hits.add(MemoryHit(memoryRecord(1, 'note'), 0.9f64))
        let store = PostgresMemoryStore(repo, FakeEmbedder())
        store.search(MemoryQuery(1, ['global'], [], 'q', topK: 5))
        @Expect(repo.colbertCalls, 0)
    }

    @TestCase
    func testSearchFiltersOtherUsers(): Unit {
        let repo = FakeMemoryRepository()
        // 仓库越权返回了别人的记忆，store 必须再挡一次
        repo.hits.add(MemoryHit(memoryRecordIn(1, 2, 'global', 'note'), 0.9f64))
        let store = PostgresMemoryStore(repo, FakeEmbedder())

        let results = store.search(MemoryQuery(1, ['global'], [], 'q', topK: 5))
        @Expect(results.size, 0)
    }

    @TestCase
    func testSearchFiltersNamespaces(): Unit {
        let repo = FakeMemoryRepository()
        repo.hits.add(MemoryHit(memoryRecordIn(1, 1, 'global', 'note'), 0.9f64))
        repo.hits.add(MemoryHit(memoryRecordIn(2, 1, 'ws-1', 'note'), 0.8f64))
        repo.hits.add(MemoryHit(memoryRecordIn(3, 1, 'ws-2', 'note'), 0.7f64))
        let store = PostgresMemoryStore(repo, FakeEmbedder())

        let results = store.search(MemoryQuery(1, ['global', 'ws-1'], [], 'q', topK: 5))
        @Expect(results.size, 2)
    }

    @TestCase
    func testTokenizeReturnsTokenWeights(): Unit {
        let tokens = FakeEmbedder().tokenize('ab cd')
        @Expect(tokens.size, 2)
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
func memoryRecordIn(id: Int64, userId: Int64, namespace: String, kind: String): MemoryRecord {
    MemoryRecord(id, userId, namespace, 't${id}', 'c${id}', kind, DateTime.now())
}