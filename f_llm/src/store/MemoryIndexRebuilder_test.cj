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

/** 只关心 token 权重合并的假向量化：标题 token 权重高于正文 */
class RebuildEmbedder <: Embedder {
    public func embed(text: String): Array<Float64> {
        [0.0f64]
    }

    public func embedColbert(text: String): Array<Array<Float64>> {
        [[1.0f64, 2.0f64]]
    }

    public func tokenize(text: String): HashMap<Int64, Float64> {
        let tokens = HashMap<Int64, Float64>()
        if(text == 'title'){
            tokens[10] = 1.0f64
            tokens[11] = 0.2f64
        }else{
            tokens[10] = 0.5f64
            tokens[12] = 0.4f64
        }
        tokens
    }
}

class RebuildRepository <: MemoryRepository {
    private let records: ArrayList<MemoryRecord>
    public var listCalls: Int64 = 0
    public var sparseWrites: Int64 = 0
    public var colbertWrites: Int64 = 0
    public var lastTokens = HashMap<Int64, Float64>()

    public init(records: ArrayList<MemoryRecord>) {
        this.records = records
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        listCalls++
        let page = ArrayList<MemoryRecord>()
        var index = offset
        while(index < records.size && page.size < limit){
            page.add(records[index])
            index++
        }
        page
    }

    public func upsertSparse(memoryId: Int64, userId: Int64, namespace: String,
                             tokens: HashMap<Int64, Float64>): Unit {
        sparseWrites++
        lastTokens = tokens
    }

    public func upsertColbert(memoryId: Int64, titleVectors: Array<Array<Float64>>,
                              contentVectors: Array<Array<Float64>>): Unit {
        colbertWrites++
    }

    public func upsert(write: MemoryWrite, titleVector: Array<Float64>, contentVector: Array<Float64>): Int64 {
        throw UnsupportedException('not used by rebuilder test')
    }

    public func searchDense(query: MemoryQuery, vector: Array<Float64>, limit: Int64): ArrayList<MemoryHit> {
        ArrayList<MemoryHit>()
    }

    public func searchSparse(query: MemoryQuery, tokens: HashMap<Int64, Float64>,
                             limit: Int64): ArrayList<MemoryHit> {
        ArrayList<MemoryHit>()
    }

    public func colbert(recordId: Int64): ?ColbertVectors {
        None
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        None
    }

    public func remove(userId: Int64, id: Int64): Bool {
        false
    }
}

@Test
public class MemoryIndexRebuilderTest {

    private func records(count: Int64): ArrayList<MemoryRecord> {
        let list = ArrayList<MemoryRecord>()
        for(index in 0..count){
            list.add(MemoryRecord(index + 1, 7, 'global', 'title', 'body', 'fact', DateTime.now()))
        }
        list
    }

    @TestCase
    func testRebuildPagesThroughAllRecords(): Unit {
        let repository = RebuildRepository(records(3))
        let rebuilt = MemoryIndexRebuilder.rebuild(repository, RebuildEmbedder(), 7, 'global', batchSize: 2)
        @Expect(rebuilt, 3)
        @Expect(repository.sparseWrites, 3)
        @Expect(repository.colbertWrites, 3)
        // 2 条一页 → 2 页有数据 + 1 页空（用来终止）
        @Expect(repository.listCalls, 3)
    }

    @TestCase
    func testTokenMergeKeepsLargerWeight(): Unit {
        let repository = RebuildRepository(records(1))
        MemoryIndexRebuilder.rebuild(repository, RebuildEmbedder(), 7, 'global')
        @Expect(repository.lastTokens.get(10).getOrThrow(), 1.0f64)
        @Expect(repository.lastTokens.get(11).getOrThrow(), 0.2f64)
        @Expect(repository.lastTokens.get(12).getOrThrow(), 0.4f64)
    }

    @TestCase
    func testEmptyNamespaceDoesNotWrite(): Unit {
        let repository = RebuildRepository(ArrayList<MemoryRecord>())
        let rebuilt = MemoryIndexRebuilder.rebuild(repository, RebuildEmbedder(), 7, 'global')
        @Expect(rebuilt, 0)
        @Expect(repository.sparseWrites, 0)
        @Expect(repository.listCalls, 1)
    }

    @TestCase
    func testNonPositiveBatchSizeRejected(): Unit {
        let repository = RebuildRepository(records(1))
        var thrown = false
        try{
            MemoryIndexRebuilder.rebuild(repository, RebuildEmbedder(), 7, 'global', batchSize: 0)
        }catch(_: IllegalArgumentException){
            thrown = true
        }
        @Expect(thrown, true)
    }
}
