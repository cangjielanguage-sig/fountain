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

import std.collection.ArrayList
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
        // 先按 topK 的 2 倍召回，乘权重后再截断，避免低权重记忆被提前挤掉
        let candidates = repo.searchDense(query, vector, query.topK * 2)
        let scored = ArrayList<MemoryHit>()
        for(hit in candidates){
            scored.add(MemoryHit(hit.record, hit.score * MemoryKinds.weightOf(hit.record.kind)))
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
                if(best < 0 || scored[index].score > scored[best].score){
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
}
