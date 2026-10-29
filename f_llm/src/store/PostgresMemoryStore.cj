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

/**
 * PostgreSQL 记忆实现（2.3）。
 *
 * 2.3 的 Red 阶段：`add` 未实现；其余方法在 2.4/2.5 补。
 */
public class PostgresMemoryStore <: MemoryStore {
    private let repo: MemoryRepository
    private let embedder: Embedder

    public init(repo: MemoryRepository, embedder: Embedder) {
        this.repo = repo
        this.embedder = embedder
    }

    public func add(write: MemoryWrite): MemoryRecord {
        // 标题与正文各算一份向量；任何一次失败都拒绝写入（不能存无向量记忆）
        let titleVector = embedder.embed(write.title)
        let contentVector = embedder.embed(write.content)
        let id = repo.upsert(write, titleVector, contentVector)
        MemoryRecord(id, write.userId, write.namespace, write.title, write.content,
                     write.kind, DateTime.now())
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        throw IllegalArgumentException('not implemented')
    }

    public func remove(userId: Int64, id: Int64): Bool {
        throw IllegalArgumentException('not implemented')
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        throw IllegalArgumentException('not implemented')
    }

    public func search(query: MemoryQuery): ArrayList<MemoryHit> {
        let vector = embedder.embed(query.text)
        // 两路各取 topK 的 2 倍，融合后乘权重再截断
        let limit = query.topK * 2
        let dense = repo.searchDense(query, vector, limit)
        let sparse = repo.searchSparse(query, limit)
        // 没有倒排数据（或对方未提供 sparse）时，只由 dense 打分，并标记降级
        let degraded = sparse.isEmpty()

        let denseScores = normalize(dense)
        let sparseScores = normalize(sparse)

        let ids = ArrayList<Int64>()
        let records = HashMap<Int64, MemoryRecord>()
        collect(dense, ids, records)
        collect(sparse, ids, records)

        let scored = ArrayList<MemoryHit>()
        for(id in ids){
            let denseScore = denseScores.get(id) ?? 0.0f64
            let sparseScore = sparseScores.get(id) ?? 0.0f64
            let record = records.get(id).getOrThrow()
            let fused = 0.7f64 * denseScore + 0.3f64 * sparseScore
            scored.add(MemoryHit(record, fused * MemoryKinds.weightOf(record.kind), degraded: degraded))
        }

        // colbert 重排：只改顺序，不改候选集，也不改 hit.score
        let rerankScores = HashMap<Int64, Float64>()
        if(query.rerank){
            let queryVectors = embedder.embedColbert(query.text)
            for(hit in scored){
                match(repo.colbert(hit.record.id)){
                    case Some(vectors) =>
                        rerankScores[hit.record.id] = 0.4f64 * maxSim(queryVectors, vectors.title) +
                                                      0.6f64 * maxSim(queryVectors, vectors.content)
                    case None => rerankScores[hit.record.id] = 0.0f64
                }
            }
        }

        // 选择排序取前 topK（不依赖 ArrayList 的插入/交换 API）
        let used = ArrayList<Bool>()
        for(_ in scored){
            used.add(false)
        }
        let results = ArrayList<MemoryHit>()
        var picked = 0
        while(picked < query.topK && picked < scored.size){
            var best = -1
            for(index in 0..scored.size){
                if(used[index]){
                    continue
                }
                var better = false
                if(best < 0){
                    better = true
                }else if(query.rerank){
                    better = rerankScores.get(scored[index].record.id).getOrThrow() >
                             rerankScores.get(scored[best].record.id).getOrThrow()
                }else{
                    better = scored[index].score > scored[best].score
                }
                if(better){
                    best = index
                }
            }
            if(best < 0){
                break
            }
            used[best] = true
            results.add(scored[best])
            picked++
        }
        results
    }

    /** colbert max-sim：每个 query token 取与文档 token 的最大点积，再对 query 取平均 */
    private static func maxSim(query: Array<Array<Float64>>, doc: Array<Array<Float64>>): Float64 {
        if(query.size == 0 || doc.size == 0){
            return 0.0f64
        }
        var total = 0.0f64
        for(queryToken in query){
            var best = 0.0f64
            for(docToken in doc){
                let score = dot(queryToken, docToken)
                if(score > best){
                    best = score
                }
            }
            total += best
        }
        total / Float64(query.size)
    }

    private static func dot(left: Array<Float64>, right: Array<Float64>): Float64 {
        let size = if(left.size < right.size){ left.size } else { right.size }
        var sum = 0.0f64
        for(index in 0..size){
            sum += left[index] * right[index]
        }
        sum
    }

    private static func collect(hits: ArrayList<MemoryHit>, ids: ArrayList<Int64>,
                                records: HashMap<Int64, MemoryRecord>): Unit {
        for(hit in hits){
            let id = hit.record.id
            if(!records.contains(id)){
                records[id] = hit.record
                ids.add(id)
            }
        }
    }

    /** min-max 归一化；单条候选或全部同分时统一按 1.0 处理，避免除零 */
    private static func normalize(hits: ArrayList<MemoryHit>): HashMap<Int64, Float64> {
        let scores = HashMap<Int64, Float64>()
        if(hits.isEmpty()){
            return scores
        }
        var min = hits[0].score
        var max = min
        for(hit in hits){
            if(hit.score < min){
                min = hit.score
            }
            if(hit.score > max){
                max = hit.score
            }
        }
        let range = max - min
        for(hit in hits){
            if(range <= 0.0f64){
                scores[hit.record.id] = 1.0f64
            }else{
                scores[hit.record.id] = (hit.score - min) / range
            }
        }
        scores
    }
}
