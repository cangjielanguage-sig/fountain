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

import fountain::f_orm.*

/**
 * PostgreSQL 记忆仓库（2.8b）。
 *
 * 2.8b 的 Red 阶段：方法体未实现，集成用例先钉住行为。
 */
public class PostgresMemoryRepository <: MemoryRepository {
    private let executor: SqlExecutor

    public init(executor: SqlExecutor) {
        this.executor = executor
    }

    public func upsert(write: MemoryWrite, titleVector: Array<Float64>,
                       contentVector: Array<Float64>): Int64 {
        throw IllegalArgumentException('PostgresMemoryRepository.upsert not implemented')
    }

    public func searchDense(query: MemoryQuery, vector: Array<Float64>, limit: Int64): ArrayList<MemoryHit> {
        throw IllegalArgumentException('PostgresMemoryRepository.searchDense not implemented')
    }

    public func searchSparse(query: MemoryQuery, limit: Int64): ArrayList<MemoryHit> {
        ArrayList<MemoryHit>()
    }

    public func colbert(recordId: Int64): ?ColbertVectors {
        None
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        throw IllegalArgumentException('PostgresMemoryRepository.get not implemented')
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        throw IllegalArgumentException('PostgresMemoryRepository.list not implemented')
    }

    public func remove(userId: Int64, id: Int64): Bool {
        throw IllegalArgumentException('PostgresMemoryRepository.remove not implemented')
    }
}
