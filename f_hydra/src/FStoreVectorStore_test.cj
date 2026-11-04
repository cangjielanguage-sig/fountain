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
import std.sync.*
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_store.Store

/** 每个用例独立目录，避免 f_store 的单实例可见性把用例串起来 */
private var pathSeq: Int64 = 0
/** 用例并行执行：计数器必须加锁，否则两个用例会拿到同一个目录 */
private let pathSeqMutex = Mutex()

class PathSeqBox {
    public var value: Int64 = 0
}

private func newStore(): FStoreVectorStore {
    let box = PathSeqBox()
    synchronized(pathSeqMutex){
        pathSeq++
        box.value = pathSeq
    }
    // 带时间戳：跨进程重跑也不会撞到上次留下的目录
    let stamp = DateTime.now().toUnixTimeStamp().toSeconds()
    FStoreVectorStore('/tmp/fhydra-test-${stamp}-${box.value}')
}

private func kindFilters(kind: String): HashMap<String, String> {
    let filters = HashMap<String, String>()
    filters['kind'] = kind
    return filters
}

@Test
public class FStoreVectorStoreTest {

    /** 元数据过滤走倒排：只返回命中的 kind，且分页在过滤之后 */
    @TestCase
    func testIdsFilteredUsesMetadataIndex(): Unit {
        let store = newStore()
        let collection = 'u1:global'
        // 交错写入：fact / note 各三条，saveTime 递增
        let kinds = ['fact', 'note', 'fact', 'note', 'fact']
        var seq: Int64 = 0
        for(kind in kinds){
            seq++
            store.upsert(collection, VectorRecord('r${seq}', '{}', [1.0f64, 0.0f64],
                filters: kindFilters(kind), saveTime: seq))
        }

        let facts = store.idsFiltered(collection, kindFilters('fact'), 0, 10)
        @Expect(facts.size, 3)
        for(id in facts){
            @Expect(store.get(collection, id).getOrThrow().filters.get('kind').getOrThrow(), 'fact')
        }

        // 分页在过滤之后：limit=1 也必须拿到 fact
        let page = store.idsFiltered(collection, kindFilters('fact'), 0, 1)
        @Expect(page.size, 1)
        @Expect(store.get(collection, page[0]).getOrThrow().filters.get('kind').getOrThrow(), 'fact')

        // 没有命中时返回空
        @Expect(store.idsFiltered(collection, kindFilters('missing'), 0, 10).size, 0)
        store.close()
    }

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

    // ---- sparse ----

    private func tokens(items: Array<(Int64, Float64)>): HashMap<Int64, Float64> {
        let map = HashMap<Int64, Float64>()
        for((token, weight) in items){
            map[token] = weight
        }
        map
    }

    @TestCase
    func testSparseSearchAccumulatesWeights(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r1', 'p1', [1.0f64, 0.0f64],
                                       sparse: tokens([(1, 1.0f64), (2, 0.5f64)])))
        store.upsert('c', VectorRecord('r2', 'p2', [1.0f64, 0.0f64],
                                       sparse: tokens([(1, 1.0f64)])))

        let hits = store.searchSparse(SparseQuery('c', tokens([(1, 1.0f64), (2, 1.0f64)]), limit: 5))
        @Expect(hits.size, 2)
        @Expect(hits[0].id, 'r1')
        @Expect(hits[0].score, 1.5f64)
        @Expect(hits[1].score, 1.0f64)
        store.close()
    }

    @TestCase
    func testSparseOverwriteClearsStalePostings(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r', 'p1', [1.0f64], sparse: tokens([(1, 1.0f64)])))
        store.upsert('c', VectorRecord('r', 'p2', [1.0f64], sparse: tokens([(2, 1.0f64)])))

        @Expect(store.searchSparse(SparseQuery('c', tokens([(1, 1.0f64)]))).size, 0)
        @Expect(store.searchSparse(SparseQuery('c', tokens([(2, 1.0f64)]))).size, 1)
        store.close()
    }

    @TestCase
    func testSparseRemoveClearsPostings(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r', 'p', [1.0f64], sparse: tokens([(9, 0.7f64)])))
        @Expect(store.remove('c', 'r'), true)
        @Expect(store.searchSparse(SparseQuery('c', tokens([(9, 1.0f64)]))).size, 0)
        store.close()
    }

    // ---- colbert ----

    @TestCase
    func testColbertRoundtrip(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r', 'p', [1.0f64],
                                       colbert: [[1.0f64, 0.0f64], [0.0f64, 1.0f64]]))
        let record = store.get('c', 'r').getOrThrow()
        @Expect(record.colbert.size, 2)
        @Expect(record.colbert[0].size, 2)
        @Expect(record.colbert[1][0], 0.0f64)
        store.close()
    }

    @TestCase
    func testRerankOrdersByMaxSim(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('aligned', 'A', [1.0f64], colbert: [[1.0f64, 0.0f64]]))
        store.upsert('c', VectorRecord('orthogonal', 'B', [1.0f64], colbert: [[0.0f64, 1.0f64]]))

        let hits = store.rerank('c', ArrayList<String>(['orthogonal', 'aligned']), [[1.0f64, 0.0f64]])
        @Expect(hits.size, 2)
        @Expect(hits[0].id, 'aligned')
        @Expect(hits[0].score > hits[1].score, true)
        store.close()
    }

    @TestCase
    func testRerankEmptyQueryOrIds(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r', 'p', [1.0f64], colbert: [[1.0f64, 0.0f64]]))

        @Expect(store.rerank('c', ArrayList<String>(), [[1.0f64, 0.0f64]]).size, 0)
        @Expect(store.rerank('c', ArrayList<String>(['r']), Array<Array<Float64>>()).size, 0)
        store.close()
    }

    @TestCase
    func testSparseCollectionsAreIsolated(): Unit {
        let store = newStore()
        store.upsert('a', VectorRecord('r', 'A', [1.0f64], sparse: tokens([(5, 1.0f64)])))
        store.upsert('b', VectorRecord('r', 'B', [1.0f64], sparse: tokens([(5, 1.0f64)])))

        let hitsA = store.searchSparse(SparseQuery('a', tokens([(5, 1.0f64)])))
        @Expect(hitsA.size, 1)
        @Expect(hitsA[0].payload, 'A')
        store.close()
    }

    // ---- IVF（v0.4） ----

    private func seedTwoClusters(store: FStoreVectorStore, collection: String): Unit {
        store.upsert(collection, VectorRecord('a1', 'A1', [1.0f64, 0.0f64]))
        store.upsert(collection, VectorRecord('a2', 'A2', [0.9f64, 0.1f64]))
        store.upsert(collection, VectorRecord('b1', 'B1', [0.0f64, 1.0f64]))
        store.upsert(collection, VectorRecord('b2', 'B2', [0.1f64, 0.9f64]))
    }

    @TestCase
    func testBuildIndexReportsClusters(): Unit {
        let store = newStore()
        seedTwoClusters(store, 'c')
        @Expect(store.indexClusters('c'), 0)

        let clusters = store.buildIndex('c', clusters: 2)
        @Expect(clusters, 2)
        @Expect(store.indexClusters('c'), 2)
        store.close()
    }

    @TestCase
    func testIvfSearchMatchesBruteForce(): Unit {
        let store = newStore()
        seedTwoClusters(store, 'c')
        let query = VectorQuery('c', [1.0f64, 0.0f64], limit: 2)
        let before = store.searchDense(query)
        @Expect(before[0].id, 'a1')

        store.buildIndex('c', clusters: 2)
        let after = store.searchDense(query)
        @Expect(after.size, before.size)
        @Expect(after[0].id, 'a1')
        @Expect(after[1].id, 'a2')
        store.close()
    }

    @TestCase
    func testIvfSeesRecordAddedAfterBuild(): Unit {
        let store = newStore()
        seedTwoClusters(store, 'c')
        store.buildIndex('c', clusters: 2)

        // 增量挂桶：新记录应能被索引召回，无需重建
        // a3 = [1,0.05] 与查询的余弦 0.9987，低于 a1 的 1.0，但应排到第二
        store.upsert('c', VectorRecord('a3', 'A3', [1.0f64, 0.05f64]))
        let hits = store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 2))
        @Expect(hits.size, 2)
        @Expect(hits[0].id, 'a1')
        @Expect(hits[1].id, 'a3')
        store.close()
    }

    @TestCase
    func testRemoveUpdatesBuckets(): Unit {
        let store = newStore()
        seedTwoClusters(store, 'c')
        store.buildIndex('c', clusters: 2)

        @Expect(store.remove('c', 'a1'), true)
        let hits = store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 4))
        for(hit in hits){
            @Expect(hit.id != 'a1', true)
        }
        // 桶里的残留不能把已删除记录带回来
        @Expect(store.indexClusters('c'), 2)
        store.close()
    }

    @TestCase
    func testBuildEmptyCollectionReturnsZero(): Unit {
        let store = newStore()
        @Expect(store.buildIndex('empty'), 0)
        @Expect(store.indexClusters('empty'), 0)
        @Expect(store.searchDense(VectorQuery('empty', [1.0f64, 0.0f64])).size, 0)
        store.close()
    }

    @TestCase
    func testUnbuiltIndexFallsBackToFullScan(): Unit {
        let store = newStore()
        seedTwoClusters(store, 'c')
        @Expect(store.indexClusters('c'), 0)
        let hits = store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 4))
        @Expect(hits.size, 4)
        store.close()
    }

    // ---- v0.5 两阶段写 / 恢复 / TTL ----

    /** 绕过 upsert 直接写 payload + dense，模拟「写到一半崩溃」 */
    private func rawPartial(path: String, collection: String, id: String): Store {
        let raw = Store(path)
        raw.add('h:${collection}:d:${id}'.toArray(), '{"partial":true}'.toArray())
        raw.add('h:${collection}:v:d:${id}'.toArray(), VectorCodec.encodeDense([1.0f64, 0.0f64]))
        raw
    }

    @TestCase
    func testPartialWriteIsInvisibleUntilReady(): Unit {
        pathSeq++
        let raw = rawPartial('/tmp/fhydra-partial-${pathSeq}', 'c', 'half')
        let store = FStoreVectorStore(raw)

        @Expect(store.get('c', 'half').isNone(), true)
        @Expect(store.count('c'), 0)
        @Expect(store.searchDense(VectorQuery('c', [1.0f64, 0.0f64])).size, 0)
        store.close()
    }

    @TestCase
    func testRecoverPurgesHalfWrittenRecords(): Unit {
        pathSeq++
        let raw = rawPartial('/tmp/fhydra-recover-${pathSeq}', 'c', 'half')
        let store = FStoreVectorStore(raw)

        @Expect(store.recover('c'), 1)
        // 清理是物理删除，不是仅隐藏
        @Expect(raw.contains('h:c:d:half'.toArray()), false)
        @Expect(raw.contains('h:c:v:d:half'.toArray()), false)
        store.close()
    }

    @TestCase
    func testRecoverKeepsCompleteRecords(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('ok', 'p', [1.0f64, 0.0f64]))
        @Expect(store.recover('c'), 0)
        @Expect(store.get('c', 'ok').getOrThrow().payload, 'p')
        store.close()
    }

    @TestCase
    func testTtlHidesCollectionUntilCleared(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r', 'p', [1.0f64, 0.0f64]))

        store.setTtl('c', 0)   // 立即过期
        @Expect(store.ttlOf('c') > 0, true)
        @Expect(store.get('c', 'r').isNone(), true)
        @Expect(store.count('c'), 0)
        @Expect(store.searchDense(VectorQuery('c', [1.0f64, 0.0f64])).size, 0)

        store.setTtl('c', -1)  // 取消 TTL，数据仍在
        @Expect(store.ttlOf('c'), 0)
        @Expect(store.get('c', 'r').isSome(), true)
        store.close()
    }

    // ---- v0.5.1 过滤索引 ----

    private func filters(items: Array<(String, String)>): HashMap<String, String> {
        let map = HashMap<String, String>()
        for((field, value) in items){
            map[field] = value
        }
        map
    }

    @TestCase
    func testDenseSearchFiltersByKind(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('n1', 'note', [1.0f64, 0.0f64],
                                       filters: filters([('kind', 'note')])))
        store.upsert('c', VectorRecord('f1', 'fact', [1.0f64, 0.0f64],
                                       filters: filters([('kind', 'fact')])))

        let hits = store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 5,
                                                 filters: filters([('kind', 'note')])))
        @Expect(hits.size, 1)
        @Expect(hits[0].id, 'n1')
        store.close()
    }

    @TestCase
    func testTagAndSaveDayFiltersCombine(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r1', 'p', [1.0f64, 0.0f64],
                                       filters: filters([('tags', 'a,b'), ('save_day', '20261031')])))
        store.upsert('c', VectorRecord('r2', 'p', [1.0f64, 0.0f64],
                                       filters: filters([('tags', 'c'), ('save_day', '20260101')])))

        @Expect(store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 5,
                                              filters: filters([('tags', 'b')]))).size, 1)
        @Expect(store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 5,
                                              filters: filters([('tags', 'b'),
                                                                ('save_day', '20260101')]))).size, 0)
        store.close()
    }

    @TestCase
    func testOverwriteReplacesFilterEntries(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r', 'p1', [1.0f64, 0.0f64],
                                       filters: filters([('kind', 'note')])))
        store.upsert('c', VectorRecord('r', 'p2', [1.0f64, 0.0f64],
                                       filters: filters([('kind', 'fact')])))

        @Expect(store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 5,
                                              filters: filters([('kind', 'note')]))).size, 0)
        let facts = store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 5,
                                                  filters: filters([('kind', 'fact')])))
        @Expect(facts.size, 1)
        @Expect(facts[0].id, 'r')
        store.close()
    }

    @TestCase
    func testRemoveClearsFilterEntries(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r', 'p', [1.0f64, 0.0f64],
                                       filters: filters([('kind', 'note')])))
        @Expect(store.remove('c', 'r'), true)
        @Expect(store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 5,
                                              filters: filters([('kind', 'note')]))).size, 0)
        store.close()
    }

    @TestCase
    func testSparseSearchHonorsFilters(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('n1', 'n', [1.0f64], sparse: tokens([(5, 1.0f64)]),
                                       filters: filters([('kind', 'note')])))
        store.upsert('c', VectorRecord('f1', 'f', [1.0f64], sparse: tokens([(5, 1.0f64)]),
                                       filters: filters([('kind', 'fact')])))

        let hits = store.searchSparse(SparseQuery('c', tokens([(5, 1.0f64)]), limit: 5,
                                                  filters: filters([('kind', 'fact')])))
        @Expect(hits.size, 1)
        @Expect(hits[0].id, 'f1')
        store.close()
    }

    @TestCase
    func testUnknownFilterFieldMatchesNothing(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r', 'p', [1.0f64, 0.0f64],
                                       filters: filters([('kind', 'note')])))
        // 不在白名单的字段没有索引，交集为空（明确不匹配）
        @Expect(store.searchDense(VectorQuery('c', [1.0f64, 0.0f64], limit: 5,
                                              filters: filters([('author', 'x')]))).size, 0)
        store.close()
    }

    @TestCase
    func testNamedDenseFieldsAndSaveTimeOrder(): Unit {
        let store = newStore()
        let first = HashMap<String, Array<Float64>>()
        first['title'] = [1.0f64, 0.0f64]
        first['content'] = [0.0f64, 1.0f64]
        store.upsert('c', VectorRecord('r1', 'p1', [0.0f64, 0.0f64], vectors: first, saveTime: 20))

        let second = HashMap<String, Array<Float64>>()
        second['title'] = [0.0f64, 1.0f64]
        second['content'] = [1.0f64, 0.0f64]
        store.upsert('c', VectorRecord('r2', 'p2', [0.0f64, 0.0f64], vectors: second, saveTime: 10))

        // 同一查询按不同字段得到不同结果
        let byContent = store.searchDenseField(VectorQuery('c', [1.0f64, 0.0f64], limit: 1), 'content')
        @Expect(byContent.size, 1)
        @Expect(byContent[0].id, 'r2')
        let byTitle = store.searchDenseField(VectorQuery('c', [1.0f64, 0.0f64], limit: 1), 'title')
        @Expect(byTitle[0].id, 'r1')

        let record = store.get('c', 'r1').getOrThrow()
        @Expect(record.vectors['title'].size, 2)
        @Expect(record.saveTime, 20)

        // ids 按 (saveTime, id) 升序
        let ids = store.ids('c', 0, 10)
        @Expect(ids[0], 'r2')
        @Expect(ids[1], 'r1')
        store.close()
    }

    @TestCase
    func testIdsPagingSkipsPartialRecords(): Unit {
        pathSeq++
        let raw = rawPartial('/tmp/fhydra-ids-${pathSeq}', 'c', 'half')
        let store = FStoreVectorStore(raw)
        store.upsert('c', VectorRecord('b', 'B', [1.0f64]))
        store.upsert('c', VectorRecord('a', 'A', [1.0f64]))

        let first = store.ids('c', 0, 1)
        let second = store.ids('c', 1, 1)
        @Expect(first.size, 1)
        @Expect(first[0], 'a')
        @Expect(second[0], 'b')
        // 半成品（无 ready）不参与导出
        @Expect(store.ids('c', 0, 10).size, 2)
        store.close()
    }

    @TestCase
    func testExportCopiesRecordsToAnotherStore(): Unit {
        let source = newStore()
        source.upsert('c', VectorRecord('r1', 'P1', [1.0f64, 0.0f64],
                                        sparse: tokens([(7, 0.5f64)]),
                                        colbert: [[1.0f64, 0.0f64]]))
        let target = newStore()

        @Expect(source.exportTo('c', target, 'copy'), 1)
        let record = target.get('copy', 'r1').getOrThrow()
        @Expect(record.payload, 'P1')
        @Expect(record.dense.size, 2)
        @Expect(record.sparse.get(7).getOrThrow(), 0.5f64)
        @Expect(record.colbert.size, 1)
        @Expect(target.searchDense(VectorQuery('copy', [1.0f64, 0.0f64])).size, 1)
        source.close()
        target.close()
    }

    @TestCase
    func testPurgeExpiredRemovesEverything(): Unit {
        let store = newStore()
        store.upsert('c', VectorRecord('r', 'p', [1.0f64, 0.0f64]))
        store.setTtl('c', 0)

        @Expect(store.purgeExpired('c') > 0, true)
        @Expect(store.get('c', 'r').isNone(), true)
        @Expect(store.count('c'), 0)

        store.setTtl('c', -1)
        @Expect(store.get('c', 'r').isNone(), true)   // 已物理删除
        store.close()
    }
}
