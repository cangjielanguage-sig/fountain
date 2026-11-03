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
 * `MemoryStore` 适配器：业务层只依赖本类。
 *
 * 取值顺序：`f_bean` 选中的实现 → `Stores.content().memory`。
 * fhydra 属于后续实现，接入后会以 bean 形式出现在第一步。
 */
public class MemoryStoreAdapter <: MemoryStore {
    private let delegate: MemoryStore

    /**
     * 优先取 `f_bean` 选中的 `MemoryStore`；没有 bean（容器未初始化）时回退到
     * `Stores.content().memory`（同一份 `llm_memoryStore` 配置、不经 bean 容器）。
     *
     * 两处都不匹配时由 `Stores.content()` 抛错并列出可选实现——不静默降级。
     */
    public init() {
        this.delegate = match(lookupOption<MemoryStore>()){
            case Some(bean) => bean
            case None => Stores.content().memory
        }
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

    public func listByKind(userId: Int64, namespace: String, kind: String,
                           offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        delegate.listByKind(userId, namespace, kind, offset, limit)
    }

    public func search(query: MemoryQuery): ArrayList<MemoryHit> {
        delegate.search(query)
    }
}
