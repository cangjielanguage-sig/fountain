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

/**
 * MySQL 记忆门面（4.3）：与 PG 共用同一套融合/权重/截断逻辑，
 * 只把仓库换成 `MySqlMemoryRepository`（MyVector ANN + 倒排）。
 */
public class MySqlMemoryStore <: MemoryStore {
    private let inner: SqlMemoryStore

    public init(repo: MemoryRepository, embedder: Embedder) {
        this.inner = SqlMemoryStore(repo, embedder)
    }

    public func add(write: MemoryWrite): MemoryRecord {
        inner.add(write)
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        inner.get(userId, id)
    }

    public func remove(userId: Int64, id: Int64): Bool {
        inner.remove(userId, id)
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        inner.list(userId, namespace, offset, limit)
    }

    public func search(query: MemoryQuery): ArrayList<MemoryHit> {
        inner.search(query)
    }
}
