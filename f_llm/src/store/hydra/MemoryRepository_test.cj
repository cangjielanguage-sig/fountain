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
package fountain::f_llm.store.hydra

import std.collection.*
import std.sync.*
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.store.*

/** 目录序号持有者（`synchronized` 块是 Unit 语义，值用持有者带出） */
class SeqBox {
    public var value: Int64 = 0
}

@Test
public class HydraMemoryRepositoryTest {
    private static var dirSeq: Int64 = 0
    /** 用例并行：计数加锁 + 时间戳，避免同一目录被两个用例或上次残留复用 */
    private static let seqMutex = Mutex()

    private func newRepo(): HydraMemoryRepository {
        let box = SeqBox()
        synchronized(seqMutex){
            dirSeq++
            box.value = dirSeq
        }
        let stamp = DateTime.now().toUnixTimeStamp().toSeconds()
        HydraMemoryRepository(path: '/tmp/fllm-hydra-mem-${stamp}-${box.value}')
    }

    private func item(kind: String, content: String): MemoryWrite {
        MemoryWrite(7, 'global', 'title-${content}', content, kind)
    }

    @TestCase
    func testUpsertGetAndList(): Unit {
        let repo = newRepo()
        let id = repo.upsert(item('fact', 'alpha'), [1.0f64, 0.0f64], [1.0f64, 0.0f64])
        @Expect(id > 0, true)

        let record = repo.get(7, id).getOrThrow()
        @Expect(record.title, 'title-alpha')
        @Expect(record.content, 'alpha')
        @Expect(record.kind, 'fact')
        @Expect(record.namespace, 'global')

        let records = repo.list(7, 'global', 0, 10)
        @Expect(records.size, 1)
        @Expect(records[0].id, id)
    }

    /** listByKind：先过滤再分页，交错写入时也不会漏 */
    @TestCase
    func testListByKindFiltersBeforePaging(): Unit {
        let repo = newRepo()
        let dense = [1.0f64, 0.0f64]
        repo.upsert(item('note', 'n1'), dense, dense)
        repo.upsert(item('fact', 'f1'), dense, dense)
        repo.upsert(item('note', 'n2'), dense, dense)
        repo.upsert(item('fact', 'f2'), dense, dense)

        let facts = repo.listByKind(7, 'global', 'fact', 0, 10)
        @Expect(facts.size, 2)
        for(record in facts){
            @Expect(record.kind, 'fact')
        }

        // 分页在过滤之后：limit=1 也必须拿到 fact（而不是本页刚好没有就返回空）
        let page = repo.listByKind(7, 'global', 'fact', 0, 1)
        @Expect(page.size, 1)
        @Expect(page[0].kind, 'fact')

        // 没有该 kind 时返回空
        @Expect(repo.listByKind(7, 'global', 'missing', 0, 10).size, 0)
    }

    @TestCase
    func testSearchDenseByContentField(): Unit {
        let repo = newRepo()
        let a = repo.upsert(item('fact', 'alpha'), [0.0f64, 1.0f64], [1.0f64, 0.0f64])
        let b = repo.upsert(item('fact', 'beta'), [1.0f64, 0.0f64], [0.0f64, 1.0f64])

        let query = MemoryQuery(7, ['global'], [], 'q', topK: 5)
        let hits = repo.searchDense(query, [1.0f64, 0.0f64], 5)
        @Expect(hits.size, 2)
        @Expect(hits[0].record.id, a)   // content 向量与查询一致
        @Expect(hits[1].record.id, b)

        // kind 过滤在仓库层做（f_hydra filters 只支持单值）
        let filtered = repo.searchDense(MemoryQuery(7, ['global'], ['none'], 'q'), [1.0f64, 0.0f64], 5)
        @Expect(filtered.size, 0)
    }

    @TestCase
    func testSearchSparseByTokens(): Unit {
        let repo = newRepo()
        let a = repo.upsert(item('fact', 'alpha'), [1.0f64], [1.0f64])
        let tokens = HashMap<Int64, Float64>()
        tokens[5] = 1.0f64
        repo.upsertSparse(a, 7, 'global', tokens)

        let hits = repo.searchSparse(MemoryQuery(7, ['global'], [], 'q'), tokens, 5)
        @Expect(hits.size, 1)
        @Expect(hits[0].record.id, a)
    }

    @TestCase
    func testColbertRoundtrip(): Unit {
        let repo = newRepo()
        let id = repo.upsert(item('fact', 'alpha'), [1.0f64], [1.0f64])
        repo.upsertColbert(id, [[1.0f64, 0.0f64]], [[0.0f64, 1.0f64]])

        let vectors = repo.colbert(id).getOrThrow()
        @Expect(vectors.content.size, 2)   // 标题 1 + 正文 1
        @Expect(vectors.content[0].size, 2)
    }

    @TestCase
    func testRemoveDeletesRecord(): Unit {
        let repo = newRepo()
        let id = repo.upsert(item('fact', 'alpha'), [1.0f64], [1.0f64])
        @Expect(repo.remove(7, id), true)
        @Expect(repo.get(7, id).isNone(), true)
        @Expect(repo.remove(7, id), false)
    }
}
