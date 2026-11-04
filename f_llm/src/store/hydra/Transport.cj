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

import fountain::f_hydra.*

/**
 * 记忆仓库与「向量存储」之间的最小契约。
 *
 * 两个实现：
 * - `InProcessTransport`：直接调 f_hydra（默认，同进程）；
 * - `HttpTransport`：调 fhydra 的 JSON-RPC（跨进程/跨机器）。
 *
 * 仓库层（`HydraMemoryRepository`）只依赖本接口，两条路径共用同一份逻辑。
 */
interface HydraTransport {
    func upsert(collection: String, record: VectorRecord): Unit
    func get(collection: String, id: String): ?VectorRecord
    func remove(collection: String, id: String): Bool
    func searchDenseField(collection: String, field: String,
                          dense: Array<Float64>, limit: Int64): ArrayList<VectorHit>
    func searchSparse(collection: String, tokens: HashMap<Int64, Float64>,
                      limit: Int64): ArrayList<VectorHit>
    func ids(collection: String, offset: Int64, limit: Int64): ArrayList<String>
    /** 按元数据过滤分页：服务端走倒排索引，调用方不需要翻页自己过滤 */
    func idsFiltered(collection: String, filters: HashMap<String, String>,
                     offset: Int64, limit: Int64): ArrayList<String>
}

/** 进程内实现：直接操作 f_hydra */
class InProcessTransport <: HydraTransport {
    private let store: FStoreVectorStore

    init(store: FStoreVectorStore) {
        this.store = store
    }

    public func upsert(collection: String, record: VectorRecord): Unit {
        store.upsert(collection, record)
    }

    public func get(collection: String, id: String): ?VectorRecord {
        store.get(collection, id)
    }

    public func remove(collection: String, id: String): Bool {
        store.remove(collection, id)
    }

    public func searchDenseField(collection: String, field: String,
                                 dense: Array<Float64>, limit: Int64): ArrayList<VectorHit> {
        store.searchDenseField(VectorQuery(collection, dense, limit: limit), field)
    }

    public func searchSparse(collection: String, tokens: HashMap<Int64, Float64>,
                             limit: Int64): ArrayList<VectorHit> {
        store.searchSparse(SparseQuery(collection, tokens, limit: limit))
    }

    public func ids(collection: String, offset: Int64, limit: Int64): ArrayList<String> {
        store.ids(collection, offset, limit)
    }

    public func idsFiltered(collection: String, filters: HashMap<String, String>,
                            offset: Int64, limit: Int64): ArrayList<String> {
        store.idsFiltered(collection, filters, offset, limit)
    }
}
