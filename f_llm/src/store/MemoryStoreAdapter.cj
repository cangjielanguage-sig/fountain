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
 * `MemoryStore` 适配器：业务层只依赖本类，具体实现由 `f_bean` 条件选定。
 *
 * 默认实现应为 fhydra（尚未实现），当前无匹配时抛错说明，而不是静默回退。
 */
public class MemoryStoreAdapter <: MemoryStore {
    private let delegate: MemoryStore

    public init() {
        this.delegate = lookupOption<MemoryStore>() ?? defaultMemoryStore()
    }

    public func add(write: MemoryWrite): MemoryRecord {
        delegate.add(write)
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        delegate.get(userId, id)
    }

    public func remove(userId: Int64, id: Int64): Bool {
        delegate.remove(userId, id)
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        delegate.list(userId, namespace, offset, limit)
    }

    public func search(query: MemoryQuery): ArrayList<MemoryHit> {
        delegate.search(query)
    }
}

private func defaultMemoryStore(): MemoryStore {
    throw IllegalStateException(
        'no MemoryStore bean matched llm_memoryStore="${StoreSettings.load().memoryStore}"; '
        + 'fhydra 实现尚未提供，请配置 llm_memoryStore=postgres|mysql|inMemory')
}
