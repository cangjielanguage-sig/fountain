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
package fountain::f_hydra

import std.collection.*

/**
 * 向量存储接口：`collection` 隔离，记录按 `id` 幂等覆盖。
 *
 * v0.1 只提供 dense 暴力检索；IVF/PQ、稀疏倒排、colbert 重排按设计文档分批接入。
 */
public interface VectorStore {
    func upsert(collection: String, record: VectorRecord): Unit
    func get(collection: String, id: String): ?VectorRecord
    func remove(collection: String, id: String): Bool
    func searchDense(query: VectorQuery): ArrayList<VectorHit>
    func count(collection: String): Int64
}
