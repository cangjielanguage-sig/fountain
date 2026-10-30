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

import fountain::f_bean.*

/**
 * `MemoryRepository` 适配器：对业务层只暴露接口。
 *
 * 具体实现由 `f_bean` 依据 `@BeanMeta[condition: ConfCond.Value('llm_contentStore', …)]`
 * 在容器初始化时选定，这里只做一次 `lookupOption`；没有匹配时回退到 fhydra（尚未实现）。
 */
public class MemoryRepositoryAdapter <: MemoryRepository {
    private let delegate: MemoryRepository

    public init() {
        this.delegate = lookupOption<MemoryRepository>() ?? defaultRepository()
    }

    public func upsert(write: MemoryWrite, titleVector: Array<Float64>,
                       contentVector: Array<Float64>): Int64 {
        delegate.upsert(write, titleVector, contentVector)
    }

    public func searchDense(query: MemoryQuery, vector: Array<Float64>, limit: Int64): ArrayList<MemoryHit> {
        delegate.searchDense(query, vector, limit)
    }

    public func searchSparse(query: MemoryQuery, tokens: HashMap<Int64, Float64>,
                             limit: Int64): ArrayList<MemoryHit> {
        delegate.searchSparse(query, tokens, limit)
    }

    public func upsertSparse(memoryId: Int64, userId: Int64, namespace: String,
                             tokens: HashMap<Int64, Float64>): Unit {
        delegate.upsertSparse(memoryId, userId, namespace, tokens)
    }

    public func upsertColbert(memoryId: Int64, titleVectors: Array<Array<Float64>>,
                              contentVectors: Array<Array<Float64>>): Unit {
        delegate.upsertColbert(memoryId, titleVectors, contentVectors)
    }

    public func colbert(recordId: Int64): ?ColbertVectors {
        delegate.colbert(recordId)
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        delegate.get(userId, id)
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        delegate.list(userId, namespace, offset, limit)
    }

    public func remove(userId: Int64, id: Int64): Bool {
        delegate.remove(userId, id)
    }
}

/**
 * 默认实现：按设计应由 fhydra 内容族提供；当前尚未实现，明确报错而不是静默回退。
 * 等 f_hydra / fhydra 落地后，把这里换成它们的 bean。
 */
private func defaultRepository(): MemoryRepository {
    throw IllegalStateException(
        'no MemoryRepository bean matched llm_contentStore="${StoreSettings.load().contentStore}"; '
        + 'fhydra 内容族尚未实现，请配置 llm_contentStore=postgres|mysql')
}
